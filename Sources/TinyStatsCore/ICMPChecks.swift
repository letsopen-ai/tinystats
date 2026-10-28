import Darwin
import Foundation

/// One explicitly chosen numeric destination. No hostname lookup or implicit provider.
public struct ICMPCheckConfiguration: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var destination: String
  public init(enabled: Bool = false, destination: String = "") {
    self.enabled = enabled
    self.destination = destination
  }
  public var validationError: String? {
    if !enabled && destination.isEmpty { return nil }
    return endpoint == nil
      ? "Enter one unicast IPv4 or IPv6 address; link-local IPv6 needs %interface." : nil
  }
  var endpoint: ICMPEndpoint? { ICMPEndpoint(destination) }
  public var canonicalDestination: String? { endpoint?.text }
}

struct ICMPEndpoint: Equatable, Sendable {
  let family: Int32
  let bytes: [UInt8]
  private(set) var scope: UInt32
  private let scopeName: String?
  let text: String
  init?(_ text: String) {
    guard !text.isEmpty, text.utf8.count <= 64,
      text.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
    else { return nil }
    let parts = text.split(separator: "%", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count) else { return nil }
    let literal = String(parts[0])
    var address = [UInt8](repeating: 0, count: 16)
    var family = AF_INET
    if literal.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 {
      guard parts.count == 1, address[0] != 0, address[0] < 224 else { return nil }
      address = Array(address.prefix(4))
    } else {
      family = AF_INET6
      guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1,
        address.contains(where: { $0 != 0 }), address[0] != 255,
        !(address.prefix(10).allSatisfy { $0 == 0 } && address[10] == 255 && address[11] == 255)
      else { return nil }
    }
    let linkLocal = family == AF_INET6 && address[0] == 254 && address[1] & 192 == 128
    if parts.count == 2 {
      guard linkLocal, !parts[1].isEmpty, parts[1].utf8.count < Int(IFNAMSIZ) else { return nil }
      let zone = String(parts[1])
      guard UInt32(zone) == nil,
        zone.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
            || $0 == 45
        })
      else { return nil }
    }
    guard !linkLocal || parts.count == 2 else { return nil }
    var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(family, address, &output, socklen_t(output.count)) != nil else { return nil }
    self.family = family
    bytes = address
    scope = 0
    scopeName = parts.count == 2 ? String(parts[1]) : nil
    self.text =
      String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      + (parts.count == 2 ? "%\(parts[1])" : "")
  }
  /// A missing VPN/dock must not erase a saved opt-in. Resolve a name only when sending.
  func resolvingScope(
    using resolve: (String) -> UInt32 = { name in name.withCString { if_nametoindex($0) } }
  ) -> Self? {
    guard let scopeName else { return self }
    let index = resolve(scopeName)
    guard index > 0 else { return nil }
    var result = self
    result.scope = index
    return result
  }
}

public struct ICMPCheckReading: Sendable, Equatable {
  public var milliseconds: Double?
  public var checkedAt: Double
  public var reason: String
  public init(milliseconds: Double?, checkedAt: Double, reason: String) {
    self.milliseconds = milliseconds
    self.checkedAt = checkedAt
    self.reason = reason
  }
}

/// Wire encoder/validator. A fresh payload token prevents another process's echo being accepted.
enum ICMPEcho {
  static let payloadBytes = 16
  static func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for index in stride(from: 0, to: bytes.count, by: 2) {
      sum += UInt32(bytes[index]) << 8
      if index + 1 < bytes.count { sum += UInt32(bytes[index + 1]) }
    }
    while sum > 65535 { sum = (sum & 65535) + (sum >> 16) }
    return ~UInt16(sum)
  }
  static func request(family: Int32, identifier: UInt16, sequence: UInt16, token: [UInt8])
    -> [UInt8]
  {
    guard token.count == payloadBytes else { return [] }
    var bytes: [UInt8] =
      [
        family == AF_INET ? 8 : 128, 0, 0, 0,
        UInt8(identifier >> 8), UInt8(identifier & 255), UInt8(sequence >> 8),
        UInt8(sequence & 255),
      ] + token
    if family == AF_INET {
      let crc = checksum(bytes)
      bytes[2] = UInt8(crc >> 8)
      bytes[3] = UInt8(crc & 255)
    }
    return bytes
  }
  static func matches(
    _ packet: [UInt8], family: Int32, identifier: UInt16, sequence: UInt16, token: [UInt8]
  ) -> Bool {
    guard family == AF_INET || family == AF_INET6, token.count == payloadBytes else { return false }
    var offset = 0
    if family == AF_INET {
      // Darwin's IPv4 datagram ICMP socket includes an IPv4 header, including options.
      guard packet.count >= 20, packet[0] >> 4 == 4, packet[9] == 1 else { return false }
      offset = Int(packet[0] & 15) * 4
      guard offset >= 20, offset <= 60, packet.count >= offset + 8 + payloadBytes else {
        return false
      }
      // Darwin rewrites these fields to host order. ip_len may describe the payload
      // (observed on the current host) or the whole datagram on another delivery path.
      let length = packet.withUnsafeBytes {
        Int($0.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
      }
      let fragments = packet.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
      }
      guard length == packet.count - offset || length == packet.count,
        fragments & 0x3fff == 0
      else { return false }
    }
    guard packet.count == offset + 8 + payloadBytes,
      packet[offset] == (family == AF_INET ? 0 : 129), packet[offset + 1] == 0,
      packet[offset + 4] == UInt8(identifier >> 8), packet[offset + 5] == UInt8(identifier & 255),
      packet[offset + 6] == UInt8(sequence >> 8), packet[offset + 7] == UInt8(sequence & 255),
      Array(packet[(offset + 8)...]) == token
    else { return false }
    // IPv6's pseudo-header checksum is verified by the kernel before delivery.
    return family != AF_INET || checksum(Array(packet[offset...])) == 0
  }
}

struct ICMPProbeReply: Sendable {
  var milliseconds: Double?
  var reason: String
}
protocol ICMPProbeTransport: AnyObject, Sendable {
  func start(_ endpoint: ICMPEndpoint, completion: @escaping @Sendable (ICMPProbeReply) -> Void)
  func cancel()
}

struct ICMPCheckLedger {
  private(set) var configuration = ICMPCheckConfiguration()
  private(set) var reading: ICMPCheckReading?
  private(set) var generation: UInt64 = 0
  private(set) var active: (token: UInt64, started: Double)?
  private var revision = ""
  private var path: [String]?
  private var lastRequest: Double?
  private var invalidated = true
  mutating func configure(_ configuration: ICMPCheckConfiguration, revision: String) -> Bool {
    guard self.configuration != configuration || self.revision != revision else { return false }
    self.configuration = configuration
    self.revision = revision
    reset()
    return true
  }
  mutating func reset() {
    generation &+= 1
    active = nil
    reading = nil
    path = nil
    invalidated = true
  }
  mutating func next(at now: Double, path: [String]) -> ICMPEndpoint? {
    guard now.isFinite else { return nil }
    if self.path != path {
      reset()
      self.path = path
    }
    guard configuration.enabled, let endpoint = configuration.endpoint else { return nil }
    if let active, now - active.started >= 5 {
      finish(.init(reason: "No echo reply within 5 seconds"), token: active.token, at: now)
    }
    guard active == nil else { return nil }
    let elapsed = lastRequest.map { now - $0 } ?? .infinity
    guard elapsed >= (invalidated ? 10 : 30) else { return nil }
    lastRequest = now
    invalidated = false
    generation &+= 1
    active = (generation, now)
    return endpoint
  }
  mutating func finish(_ reply: ICMPProbeReply, token: UInt64, at now: Double) {
    guard let active, active.token == token, generation == token,
      now.isFinite, now >= active.started
    else { return }
    self.active = nil
    let valid = reply.milliseconds.flatMap { $0.isFinite && $0 >= 0 && $0 <= 5000 ? $0 : nil }
    reading = .init(
      milliseconds: valid, checkedAt: now,
      reason: now - active.started > 5 ? "No echo reply within 5 seconds" : reply.reason)
    if now - active.started > 5 { reading?.milliseconds = nil }
  }
}

/// All ledger operations are short; socket work runs on its own serial utility queue.
final class ICMPChecksReader: @unchecked Sendable {
  private let lock = NSLock()
  private let transport: any ICMPProbeTransport
  private let clock: @Sendable () -> Double
  private var ledger = ICMPCheckLedger()
  init(
    transport: any ICMPProbeTransport = NativeICMPProbe(),
    clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.transport = transport
    self.clock = clock
  }
  deinit { transport.cancel() }
  func configure(_ configuration: ICMPCheckConfiguration, revision: String) {
    lock.lock()
    let changed = ledger.configure(configuration, revision: revision)
    lock.unlock()
    if changed { transport.cancel() }
  }
  func reset() {
    lock.lock()
    ledger.reset()
    lock.unlock()
    transport.cancel()
  }
  func read(path: [String]) -> (ICMPCheckReading?, Bool) {
    let now = clock()
    lock.lock()
    let previous = ledger.active?.token
    let endpoint = ledger.next(at: now, path: path)
    let token = ledger.active?.token
    let result = (ledger.reading, ledger.active != nil)
    lock.unlock()
    if previous != nil && previous != token { transport.cancel() }
    if let endpoint, let token {
      transport.start(endpoint) { [weak self] reply in
        guard let self else { return }
        self.lock.lock()
        self.ledger.finish(reply, token: token, at: self.clock())
        self.lock.unlock()
      }
    }
    return result
  }
}
