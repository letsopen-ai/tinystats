import CTinyStats
import Darwin
import Foundation

public struct NetworkAddress: Sendable, Equatable {
  public enum Family: Int, Sendable {
    case ipv4 = 4
    case ipv6 = 6
  }
  public var value: String, family: Family, prefix: Int?, destination: String?
  public var temporary = false, deprecated = false, notReady = false
  public var flagsAvailable = false
  public var label: String {
    guard family == .ipv6, let bytes = NetworkIP.bytes(value) else { return "IPv4" }
    if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return "IPv6 · link-local" }
    if bytes[0] & 0xfe == 0xfc { return "IPv6 · unique-local" }
    if bytes[0] == 0xff { return "IPv6 · multicast" }
    return "IPv6"
  }
  public var formatted: String {
    let cidr = value + (prefix.map { "/\($0)" } ?? "")
    let state = notReady ? "not ready" : deprecated ? "deprecated" : temporary ? "temporary" : ""
    return cidr + (state.isEmpty ? "" : " · \(state)")
  }
}

enum NetworkIP {
  static func bytes(_ value: String) -> [UInt8]? {
    guard value.utf8.count <= 80, !value.utf8.contains(0) else { return nil }
    let parts = value.split(separator: "%", omittingEmptySubsequences: false)
    guard parts.count <= 2, let base = parts.first, !base.isEmpty,
      parts.count == 1
        || (!parts[1].isEmpty
          && parts[1].utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
              || $0 == 45
          })
    else { return nil }
    let family = base.contains(":") ? AF_INET6 : AF_INET
    if family == AF_INET && parts.count != 1 { return nil }
    var bytes = [UInt8](repeating: 0, count: family == AF_INET6 ? 16 : 4)
    guard String(base).withCString({ inet_pton(family, $0, &bytes) }) == 1 else { return nil }
    return bytes
  }
  static func valid(_ value: String) -> String? { bytes(value) == nil ? nil : value }
}

public struct NetworkRoute: Sendable, Equatable {
  public var interface: String, router: String?
}
public struct InterfaceConfiguration: Sendable, Equatable {
  public var name: String?, hardware: String?, routers: [String] = [], dns: [String] = []
}
public struct NetworkConfiguration: Sendable, Equatable {
  public var available = false
  public var ipv4: NetworkRoute?, ipv6: NetworkRoute?
  public var dns: [String] = []
  public var interfaces: [String: InterfaceConfiguration] = [:]
  public init() {}
  public func preferredInterface(in readings: [InterfaceReading]) -> String? {
    for route in [ipv4, ipv6].compactMap({ $0 }) {
      if readings.contains(where: { $0.name == route.interface && $0.up }) {
        return route.interface
      }
    }
    return nil
  }
  static func decode(_ state: [String: [String: Any]]) -> Self {
    func text(_ object: [String: Any], _ key: String) -> String? {
      (object[key] as? String).flatMap { !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil }
    }
    func addresses(_ object: [String: Any], _ key: String) -> [String] {
      var seen = Set<String>()
      return Array(
        ((object[key] as? [String]) ?? []).prefix(64).compactMap(NetworkIP.valid)
          .filter { seen.insert($0).inserted }.prefix(8))
    }
    var result = Self()
    result.available = true
    func route(_ family: String) -> NetworkRoute? {
      let global = state["State:/Network/Global/\(family)"] ?? [:]
      guard let interface = text(global, "PrimaryInterface"), interface.utf8.count < 32 else {
        return nil
      }
      let service =
        text(global, "PrimaryService").flatMap { state["State:/Network/Service/\($0)/\(family)"] }
        ?? [:]
      return NetworkRoute(
        interface: interface,
        router: (text(global, "Router") ?? text(service, "Router")).flatMap(NetworkIP.valid))
    }
    result.ipv4 = route("IPv4")
    result.ipv6 = route("IPv6")
    result.dns = addresses(state["State:/Network/Global/DNS"] ?? [:], "ServerAddresses")
    let serviceIDs = Set(
      state.keys.sorted().prefix(1024).compactMap { key -> String? in
        let parts = key.split(separator: "/")
        return parts.count >= 4 && parts[1] == "Network" && parts[2] == "Service"
          ? String(parts[3]) : nil
      })
    for id in serviceIDs.sorted().prefix(128) {
      let base = "State:/Network/Service/\(id)"
      let v4 = state[base + "/IPv4"] ?? [:]
      let v6 = state[base + "/IPv6"] ?? [:]
      let setup = state["Setup:/Network/Service/\(id)/Interface"] ?? [:]
      guard
        let interface = text(v4, "InterfaceName") ?? text(v6, "InterfaceName")
          ?? text(setup, "DeviceName"),
        interface.utf8.count < 32
      else { continue }
      var info = result.interfaces[interface] ?? InterfaceConfiguration()
      info.name = info.name ?? text(state["Setup:/Network/Service/\(id)"] ?? [:], "UserDefinedName")
      info.hardware = info.hardware ?? text(setup, "Hardware")
      let routers = [text(v4, "Router"), text(v6, "Router")].compactMap { $0 }.compactMap(
        NetworkIP.valid)
      info.routers = Array(Set(info.routers + routers).sorted().prefix(8))
      var seenDNS = Set(info.dns)
      info.dns = Array(
        (info.dns
          + addresses(state[base + "/DNS"] ?? [:], "ServerAddresses")
          .filter { seenDNS.insert($0).inserted }).prefix(8))
      result.interfaces[interface] = info
    }
    return result
  }
}

struct NetworkDiscoverySchedule {
  private var last = -Double.infinity
  private var topology: [String] = []
  mutating func reset() {
    last = -Double.infinity
    topology = []
  }
  mutating func shouldRefresh(at time: Double, interfaces: [InterfaceReading], changed: Bool)
    -> Bool
  {
    let current = interfaces.map { "\($0.name):\($0.index):\($0.up):\($0.running)" }.sorted()
    guard changed || current != topology || time - last >= 30 else { return false }
    last = time
    topology = current
    return true
  }
}

struct NetworkInterfaceDetails {
  var index: UInt32, addresses: [NetworkAddress], truncated = false
}
struct NetworkDiscovery {
  var configuration = NetworkConfiguration()
  /// nil means discovery failed; an empty dictionary is a successful empty result.
  var details: [String: NetworkInterfaceDetails]?
}

/// Confined to the sampler queue. Store notifications invalidate only; discovery
/// coalesces into the next existing tick, with a 30-second fallback refresh.
final class NetworkConfigurationReader {
  private let watch: OpaquePointer?
  private let injectedRead: (() -> NetworkDiscovery)?
  private let injectedChanged: (() -> Bool)?
  private var schedule = NetworkDiscoverySchedule()
  private var configuration = NetworkConfiguration()
  private var details: [String: NetworkInterfaceDetails] = [:]
  private var addressesAvailable = false
  private(set) var sampledAt: Double?
  init(queue: DispatchQueue?) {
    watch = ts_network_open(queue)
    injectedRead = nil
    injectedChanged = nil
  }
  init(read: @escaping () -> NetworkDiscovery, changed: @escaping () -> Bool = { false }) {
    watch = nil
    injectedRead = read
    injectedChanged = changed
  }
  deinit { ts_network_close(watch) }
  func reset() { schedule.reset() }
  func read(at time: Double, interfaces: inout [InterfaceReading]) -> NetworkConfiguration {
    let changed = injectedChanged?() ?? ts_network_changed(watch)
    if schedule.shouldRefresh(at: time, interfaces: interfaces, changed: changed) {
      let discovery = injectedRead?() ?? discover()
      configuration = discovery.configuration
      addressesAvailable = discovery.details != nil
      details = discovery.details ?? [:]
      sampledAt = time
    }
    for index in interfaces.indices {
      let info = details[interfaces[index].name].flatMap {
        $0.index == interfaces[index].index ? $0 : nil
      }
      interfaces[index].addresses = info?.addresses ?? []
      interfaces[index].address = info?.addresses.first { $0.family == .ipv4 }?.value ?? ""
      interfaces[index].addressesAvailable = addressesAvailable && info != nil
      interfaces[index].addressesTruncated = info?.truncated ?? false
    }
    return configuration
  }
  private func discover() -> NetworkDiscovery {
    let state = ts_network_copy_state(watch)?.takeRetainedValue() as? [String: [String: Any]]
    var result = NetworkDiscovery(
      configuration: state.map(NetworkConfiguration.decode) ?? NetworkConfiguration())
    var raw = [ts_network_details](repeating: ts_network_details(), count: 128)
    let count = ts_read_network_details(&raw, raw.count)
    guard count >= 0 else { return result }
    result.details = [:]
    for row in raw.prefix(Int(count)) {
      let addresses = withUnsafeBytes(of: row.addresses) { bytes in
        bytes.bindMemory(to: ts_network_address.self).prefix(Int(row.count)).compactMap {
          item -> NetworkAddress? in
          guard let family = NetworkAddress.Family(rawValue: Int(item.family)),
            let value = NetworkIP.valid(cString(item.address))
          else { return nil }
          return NetworkAddress(
            value: value, family: family, prefix: item.prefix >= 0 ? Int(item.prefix) : nil,
            destination: NetworkIP.valid(cString(item.destination)), temporary: item.temporary,
            deprecated: item.deprecated, notReady: item.not_ready,
            flagsAvailable: item.flags_valid)
        }
      }
      result.details?[cString(row.name)] = .init(
        index: row.index, addresses: addresses, truncated: row.truncated)
    }
    return result
  }
}
