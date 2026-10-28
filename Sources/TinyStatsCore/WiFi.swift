import Foundation

public struct WiFiReading: Sendable, Equatable {
  public enum State: String, Sendable {
    case unavailable = "Unavailable"
    case offOrUnavailable = "Off or unavailable"
    case notAssociatedOrUnavailable = "Not associated or unavailable"
    case station = "Station link"
    case ibss = "Ad-hoc link"
    case accessPoint = "Access point"
  }
  public var interface: String
  public var state: State = .unavailable
  public var rssi: Int?, noise: Int?, channel: Int?, widthMHz: Int?
  public var transmitMbps: Double?
  public var band: String?, phy: String?, security: String?
  public var signalToNoise: Int? {
    guard let rssi, let noise else { return nil }
    let difference = rssi.subtractingReportingOverflow(noise)
    return difference.overflow ? nil : difference.partialValue
  }
  static func decode(
    interface: String, powered: Bool, mode: Int, rssi: Int = 0, noise: Int = 0,
    transmitMbps: Double = 0, channel: Int = 0, band: Int = 0, width: Int = 0,
    phy: Int = 0, security: Int = Int.max
  ) -> Self {
    var result = Self(interface: interface)
    guard powered else {
      result.state = .offOrUnavailable
      return result
    }
    switch mode {
    case 1: result.state = .station
    case 2: result.state = .ibss
    case 3: result.state = .accessPoint
    default:
      result.state = .notAssociatedOrUnavailable
      return result
    }
    // CoreWLAN documents zero as an error/disassociated sentinel for these fields.
    result.rssi = (-128 ... -1).contains(rssi) ? rssi : nil
    result.noise = (-128 ... -1).contains(noise) ? noise : nil
    result.transmitMbps =
      transmitMbps.isFinite && transmitMbps > 0 && transmitMbps <= 100_000 ? transmitMbps : nil
    result.channel = (1...1024).contains(channel) ? channel : nil
    result.band = [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"][band]
    result.widthMHz = [1: 20, 2: 40, 3: 80, 4: 160][width]
    result.phy =
      [
        1: "802.11a", 2: "802.11b", 3: "802.11g", 4: "802.11n",
        5: "802.11ac", 6: "802.11ax", 7: "802.11be",
      ][phy]
    result.security =
      [
        0: "Open", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal",
        4: "WPA2 Personal", 5: "Personal", 6: "Dynamic WEP",
        7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise", 9: "WPA2 Enterprise",
        10: "Enterprise", 11: "WPA3 Personal", 12: "WPA3 Enterprise",
        13: "WPA2/WPA3 Personal", 14: "OWE", 15: "OWE Transition",
      ][security]
    return result
  }
}

public struct WiFiSnapshot: Sendable, Equatable {
  public enum State: Sendable { case inactive, loading, ready, unavailable }
  public var state: State = .inactive
  public var interfaces: [WiFiReading] = []
  public var sampledAt: Double?
  public var truncated = false
  public init() {}
}

protocol WiFiSource: AnyObject {
  /// Only the reader's utility queue calls the source. Never scan or change radio state.
  func read(names: [String]) -> WiFiSnapshot
}

/// One bounded job isolates synchronous CoreWLAN IPC from the system sampler. All scheduling
/// comes from shared sample ticks; no timer, event stream, overlapping job or subprocess.
final class WiFiReader: @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.tinystats.wifi", qos: .utility)
  private let lock = NSLock()
  private let makeSource: @Sendable () -> any WiFiSource
  private var source: (any WiFiSource)?  // Worker queue only, including destruction.
  private var active = false, working = false
  private var generation: UInt64 = 0
  private var identity: [String] = []
  private var lastAttempt = -Double.infinity
  private var value = WiFiSnapshot()
  init(makeSource: @escaping @Sendable () -> any WiFiSource = { NativeWiFiSource() }) {
    self.makeSource = makeSource
  }
  func read(at time: Double, interfaces: [InterfaceReading]) -> WiFiSnapshot {
    guard time.isFinite else {
      stop()
      return .init()
    }
    let bounded = interfaces.prefix(128).filter {
      !$0.name.isEmpty && $0.name.utf8.count < 32
        && $0.name.utf8.allSatisfy {
          (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 95 || $0 == 45
        }
    }.sorted { $0.name < $1.name }
    let names = Array(Set(bounded.map(\.name))).sorted()
    let key = bounded.map { "\($0.name):\($0.index):\($0.up):\($0.running)" }
    lock.lock()
    if !active || key != identity || time < lastAttempt {
      active = true
      generation &+= 1
      identity = key
      lastAttempt = -Double.infinity
      value = .init()
      value.state = .loading
    }
    if !working && time - lastAttempt >= 5 {
      working = true
      lastAttempt = time
      let revision = generation
      queue.async { [self] in
        let result: WiFiSnapshot = autoreleasepool {
          let current = source ?? makeSource()
          source = current
          var result = current.read(names: names)
          result.interfaces = Array(
            result.interfaces.filter { names.contains($0.interface) }.prefix(8))
          result.sampledAt = time
          return result
        }
        lock.lock()
        if active && generation == revision { value = result }
        if active {
          // Publish idle under the same lock as the active check. A later stop queues cleanup.
          working = false
          lock.unlock()
        } else {
          lock.unlock()
          // Destruction may perform IPC too. Keep the job in flight outside the lock.
          source = nil
          lock.lock()
          working = false
          lock.unlock()
        }
      }
    }
    var result = value
    if let sampled = result.sampledAt, time - sampled > 15 || time < sampled {
      result = .init()
      result.state = .unavailable
    }
    lock.unlock()
    return result
  }
  func stop() {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    active = false
    generation &+= 1
    identity = []
    lastAttempt = -Double.infinity
    value = .init()
    if !working {
      working = true
      queue.async { [self] in
        source = nil
        lock.lock()
        working = false
        lock.unlock()
      }
    }
    lock.unlock()
  }
}
