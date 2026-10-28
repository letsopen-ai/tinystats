import Darwin
import Foundation
import Testing

@testable import TinyStatsCore

@Test func icmpConfigurationIsExplicitUnicastAndFailsClosedIndependently() throws {
  #expect(Settings().pingCheck == .init())
  #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).pingCheck == .init())
  for value in [
    "0.0.0.0", "224.0.0.1", "255.255.255.255", "::", "ff02::1", "::ffff:127.0.0.1", "fe80::1",
    "fe80::1%1", "::1%lo0", "example.com", "https://127.0.0.1", "127.0.0.1:80", "127.0.0.1\n",
    "1.2.3.999", "127.0.0.1\0other",
  ] {
    #expect(ICMPEndpoint(value) == nil, "Rejected: \(value)")
  }
  #expect(ICMPEndpoint("127.0.0.1")?.family == AF_INET)
  #expect(ICMPEndpoint("2001:0DB8::1")?.text == "2001:db8::1")
  #expect(ICMPEndpoint("fe80::1%lo0")?.resolvingScope()?.scope == if_nametoindex("lo0"))
  #expect(ICMPEndpoint("fe80::1%lo0")?.text == "fe80::1%lo0")
  var settings = try JSONDecoder().decode(
    Settings.self,
    from: Data(
      #"{"publicIPChecks":true,"pingCheck":{"enabled":true,"destination":"bad.invalid"}}"#.utf8))
  #expect(!settings.pingCheck.enabled && settings.pingCheck.destination == "bad.invalid")
  #expect(settings.publicIPChecks)
  settings.pingCheck = .init(enabled: true, destination: "::1")
  settings.internetRevision = "invalid/revision"
  settings.validate()
  #expect(!settings.pingCheck.enabled)
  let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  #expect(roundTrip.pingCheck == settings.pingCheck)
}

private let echoToken = Array(UInt8(0)...UInt8(15))
private func reply4(options: Bool = false) -> [UInt8] {
  var bytes: [UInt8] = [0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78] + echoToken
  let crc = ICMPEcho.checksum(bytes)
  bytes[2] = UInt8(crc >> 8)
  bytes[3] = UInt8(crc & 255)
  var ip = [UInt8](repeating: 0, count: options ? 24 : 20)
  ip[0] = options ? 0x46 : 0x45
  ip[2] = 24
  ip[9] = 1
  return ip + bytes
}
private func matches4(_ bytes: [UInt8]) -> Bool {
  ICMPEcho.matches(bytes, family: AF_INET, identifier: 0x1234, sequence: 0x5678, token: echoToken)
}
@Test func icmpWirePacketsVerifyHeaderChecksumIdentitySequenceAndOpaquePayload() {
  // Independent eight-byte one's-complement checksum vector (0x1234 + 0x5678).
  #expect(ICMPEcho.checksum([0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78]) == 0x9753)
  #expect(ICMPEcho.checksum([1, 2, 3]) == 0xfbfd)
  let request = ICMPEcho.request(
    family: AF_INET, identifier: 0x1234, sequence: 0x5678, token: echoToken)
  #expect(request.count == 24 && request[0] == 8 && ICMPEcho.checksum(request) == 0)
  #expect(matches4(reply4()) && matches4(reply4(options: true)))
  for index in [0, 2, 9, 20, 21, 22, 24, 26, 30, 43] {
    var corrupted = reply4()
    corrupted[index] ^= 1
    #expect(!matches4(corrupted), "Offset \(index)")
  }
  #expect(!matches4(Array(reply4().dropLast())))
  #expect(!matches4(reply4() + [0]))
  var fragmented = reply4()
  fragmented[7] = 0x20
  #expect(!matches4(fragmented))
  var malformedHeader = reply4()
  malformedHeader[0] = 0x4f
  #expect(!matches4(malformedHeader))
  let v6: [UInt8] = [129, 0, 0, 0, 0x12, 0x34, 0x56, 0x78] + echoToken
  #expect(
    ICMPEcho.matches(v6, family: AF_INET6, identifier: 0x1234, sequence: 0x5678, token: echoToken))
  #expect(
    !ICMPEcho.matches(v6, family: AF_INET6, identifier: 0x1235, sequence: 0x5678, token: echoToken))
  #expect(
    !ICMPEcho.matches(v6, family: AF_INET6, identifier: 0x1234, sequence: 0x5679, token: echoToken))
  #expect(
    !ICMPEcho.matches(
      v6, family: AF_INET6, identifier: 0x1234, sequence: 0x5678, token: Array(echoToken.reversed())
    ))
  #expect(
    !ICMPEcho.matches(v6, family: AF_UNSPEC, identifier: 0x1234, sequence: 0x5678, token: echoToken)
  )
}

@Test func icmpReplySourceChecksFamilyBytesLengthAndScope() throws {
  let endpoint = try #require(ICMPEndpoint("127.0.0.1"))
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
  var storage = sockaddr_storage()
  withUnsafeMutableBytes(of: &storage) { dst in
    withUnsafeBytes(of: &address) { dst.copyBytes(from: $0) }
  }
  #expect(
    NativeICMPProbe.matchesSource(
      storage, length: socklen_t(MemoryLayout<sockaddr_in>.size), endpoint: endpoint))
  #expect(!NativeICMPProbe.matchesSource(storage, length: 2, endpoint: endpoint))
  #expect(
    !NativeICMPProbe.matchesSource(
      storage, length: 128, endpoint: try #require(ICMPEndpoint("127.0.0.2"))))
  #expect(
    !NativeICMPProbe.matchesSource(
      storage, length: 128, endpoint: try #require(ICMPEndpoint("::1"))))
}

@Test func icmpLedgerKeepsRateFloorAcrossPathConfigurationPauseAndLateReplies() throws {
  var ledger = ICMPCheckLedger()
  #expect(ledger.next(at: 0, path: []) == nil)
  let configuration = ICMPCheckConfiguration(enabled: true, destination: "127.0.0.1")
  _ = ledger.configure(configuration, revision: "one")
  #expect(ledger.next(at: 0, path: ["en0"]) != nil)
  let first = try #require(ledger.active)
  ledger.finish(.init(milliseconds: 2, reason: "Echo reply"), token: first.token, at: 0.002)
  #expect(ledger.reading?.milliseconds == 2)
  #expect(ledger.next(at: 29, path: ["en0"]) == nil)
  #expect(ledger.next(at: 30, path: ["en0"]) != nil)
  let second = try #require(ledger.active)
  ledger.finish(.init(milliseconds: 3, reason: "Old"), token: first.token, at: 30.1)
  #expect(ledger.active?.token == second.token)
  #expect(ledger.next(at: 35, path: ["en0"]) == nil)
  #expect(
    ledger.reading?.milliseconds == nil && ledger.reading?.reason.contains("5 seconds") == true)
  ledger.finish(.init(milliseconds: 1, reason: "Late"), token: second.token, at: 35.1)
  #expect(ledger.reading?.milliseconds == nil)
  #expect(ledger.next(at: 36, path: ["vpn"]) == nil)
  #expect(ledger.reading == nil)
  _ = ledger.configure(.init(), revision: "off")
  _ = ledger.configure(configuration, revision: "on")
  #expect(ledger.next(at: 39, path: ["vpn"]) == nil)
  #expect(ledger.next(at: 40, path: ["vpn"]) != nil)
  ledger.reset()
  #expect(ledger.next(at: 49, path: ["vpn"]) == nil)
  #expect(ledger.next(at: 50, path: ["vpn"]) != nil)
  #expect(ledger.next(at: .nan, path: []) == nil)
}

private final class EchoSpy: ICMPProbeTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [@Sendable (ICMPProbeReply) -> Void] = []
  private var cancelled = 0
  private var endpoints: [ICMPEndpoint] = []
  func start(_ endpoint: ICMPEndpoint, completion: @escaping @Sendable (ICMPProbeReply) -> Void) {
    lock.lock()
    callbacks.append(completion)
    endpoints.append(endpoint)
    lock.unlock()
  }
  func cancel() {
    lock.lock()
    cancelled += 1
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return callbacks.count
  }
  var cancels: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func requested(_ index: Int) -> ICMPEndpoint? {
    lock.lock()
    defer { lock.unlock() }
    return endpoints.indices.contains(index) ? endpoints[index] : nil
  }
  func finish(_ index: Int, _ reply: ICMPProbeReply) {
    lock.lock()
    let callback = callbacks[index]
    lock.unlock()
    callback(reply)
  }
}
private final class EchoClock: @unchecked Sendable {
  let lock = NSLock()
  private var now = 0.0
  func set(_ value: Double) {
    lock.lock()
    now = value
    lock.unlock()
  }
  func read() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return now
  }
}
@Test func icmpReaderCancelsTimeoutAndOldWorkWithoutNewTimer() {
  let transport = EchoSpy()
  let clock = EchoClock()
  let reader = ICMPChecksReader(transport: transport, clock: { clock.read() })
  let configuration = ICMPCheckConfiguration(enabled: true, destination: "127.0.0.1")
  #expect(reader.read(path: []).0 == nil && transport.count == 0)
  reader.configure(configuration, revision: "one")
  #expect(reader.read(path: []).1 && transport.count == 1)
  clock.set(6)
  #expect(reader.read(path: []).0?.milliseconds == nil && transport.cancels >= 2)
  transport.finish(0, .init(milliseconds: 1, reason: "Late"))
  #expect(reader.read(path: []).0?.milliseconds == nil)
  clock.set(30)
  _ = reader.read(path: [])
  #expect(transport.count == 2)
  reader.configure(.init(), revision: "off")
  transport.finish(1, .init(milliseconds: 1, reason: "Off"))
  #expect(reader.read(path: []).0 == nil)
  reader.reset()
}

@Test func icmpSnapshotFilteringRejectsQueuedOptOutAndChangedDestinations() {
  let configuration = ICMPCheckConfiguration(enabled: true, destination: "127.0.0.1")
  var snapshot = InternetChecksSnapshot()
  snapshot.revision = "one"
  snapshot.pingCheck = configuration
  snapshot.ping = .init(milliseconds: 0.4, checkedAt: 1, reason: "Echo reply")
  #expect(
    snapshot.filtered(
      connectivity: false, publicIP: false, revision: "one", pingCheck: configuration
    ).ping?.milliseconds == 0.4)
  #expect(snapshot.filtered(connectivity: false, publicIP: false, revision: "one").ping == nil)
  #expect(
    snapshot.filtered(
      connectivity: false, publicIP: false, revision: "two", pingCheck: configuration
    ).ping == nil)
  #expect(
    snapshot.filtered(
      connectivity: false, publicIP: false, revision: "one", suspended: true,
      pingCheck: configuration
    ).ping == nil)
  #expect(
    snapshot.filtered(
      connectivity: false, publicIP: false, revision: "one",
      pingCheck: .init(enabled: true, destination: "::1")
    ).ping == nil)
}

/// Opt-in localhost only: no external provider, LAN access, DNS or permission request.
@Suite(.serialized) struct ICMPLoopbackTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["TINYSTATS_VALIDATE_ICMP_LOOPBACK"] == "1"))
  func nativeIPv4AndIPv6Echo() async throws {
    for destination in ["127.0.0.1", "::1"] {
      let probe = NativeICMPProbe()
      let endpoint = try #require(ICMPEndpoint(destination))
      let box = EchoResult()
      probe.start(endpoint) { box.set($0) }
      for _ in 0..<200 {
        if box.read() != nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      probe.cancel()
      let result = try #require(box.read(), "No matched native loopback reply: \(destination)")
      #expect(
        result.milliseconds.map { $0 >= 0 && $0 < 5000 } == true, "\(destination): \(result.reason)"
      )
      probe.cancel()
    }
  }
}

private final class EchoResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: ICMPProbeReply?
  func set(_ value: ICMPProbeReply) {
    lock.lock()
    result = value
    lock.unlock()
  }
  func read() -> ICMPProbeReply? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

private final class ICMPSendSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var sends = 0
  func send(_ descriptor: Int32, _ packet: [UInt8]) -> Int {
    lock.lock()
    sends += 1
    lock.unlock()
    // Exercise native setup/ownership, but never transmit even a loopback packet.
    return packet.count
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return sends
  }
}

@Test func icmpNativeCancellationInvalidatesQueuedSendsWithoutCancelingANewerStart() throws {
  let queue = DispatchQueue(label: "TinyStats.ICMP.QueuedCancellation")
  let spy = ICMPSendSpy()
  let probe = NativeICMPProbe(queue: queue, sendPacket: { spy.send($0, $1) })
  let endpoint = try #require(ICMPEndpoint("127.0.0.1"))
  defer { probe.cancel() }
  // Admission is held until both operations have returned. Ignoring a callback would
  // not satisfy this assertion: the injected native-send boundary must never be reached.
  queue.suspend()
  probe.start(endpoint) { _ in }
  probe.cancel()
  queue.resume()
  queue.sync {}
  #expect(spy.count == 0)

  queue.suspend()
  probe.cancel()
  probe.start(endpoint) { _ in }
  queue.resume()
  queue.sync {}
  #expect(spy.count == 1)
  probe.cancel()
  queue.sync {}
  queue.sync {}  // Drain source cancellation's independently owned close handler.
  #expect(spy.count == 1)
}

@Test func icmpScopedOptInSurvivesAbsentInterfaceAndResolvesNewIndexWhenSending() throws {
  let settings = try JSONDecoder().decode(
    Settings.self,
    from: Data(#"{"pingCheck":{"enabled":true,"destination":"fe80::1%utun999999"}}"#.utf8))
  #expect(settings.pingCheck.enabled && settings.pingCheck.validationError == nil)
  let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  #expect(decoded.pingCheck == settings.pingCheck)
  let endpoint = try #require(decoded.pingCheck.endpoint)
  #expect(endpoint.resolvingScope(using: { _ in 0 }) == nil)
  #expect(endpoint.resolvingScope(using: { _ in 12 })?.scope == 12)
  #expect(endpoint.resolvingScope(using: { _ in 37 })?.scope == 37)
  #expect(endpoint.text == "fe80::1%utun999999")
}
private final class NoHTTPProbe: HTTPProbeTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var starts = 0
  func start(
    _ endpoint: InternetEndpoint, check: HTTPSCheckConfiguration,
    completion: @escaping @Sendable (HTTPProbeReply) -> Void
  ) {
    lock.lock()
    starts += 1
    lock.unlock()
  }
  func cancel() {}
  func shutdown() {}
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return starts
  }
}
@Test func icmpAggregateReaderPublishesPingOnlyAndRejectsOldRevisionResetAndOff() throws {
  let transport = EchoSpy()
  let http = NoHTTPProbe()
  let clock = EchoClock()
  let ping = ICMPChecksReader(transport: transport, clock: { clock.read() })
  let reader = InternetChecksReader(transport: http, ping: ping, clock: { clock.read() })
  let config = ICMPCheckConfiguration(enabled: true, destination: "127.0.0.1")
  reader.configure(connectivity: false, publicIP: false, revision: "one", pingCheck: config)
  let waiting = reader.read(path: [])
  #expect(transport.requested(0)?.text == "127.0.0.1")
  #expect(waiting.pingChecking && waiting.ping == nil && transport.count == 1 && http.count == 0)
  clock.set(0.001)
  transport.finish(0, .init(milliseconds: 1, reason: "Echo reply"))
  let completed = reader.read(path: [])
  #expect(
    completed.revision == "one" && completed.pingCheck == config
      && completed.ping?.milliseconds == 1)
  #expect(
    !completed.pingChecking && !completed.connectivityEnabled && !completed.publicIPEnabled
      && http.count == 0)
  clock.set(30)
  _ = reader.read(path: [])
  let changedDestination = ICMPCheckConfiguration(enabled: true, destination: "::1")
  reader.configure(
    connectivity: false, publicIP: false, revision: "two", pingCheck: changedDestination)
  transport.finish(1, .init(milliseconds: 2, reason: "Old"))
  #expect(reader.read(path: []).ping == nil)
  clock.set(40)
  let changed = reader.read(path: [])
  #expect(transport.requested(2)?.text == "::1" && changed.pingCheck == changedDestination)
  reader.reset()
  transport.finish(2, .init(milliseconds: 3, reason: "Before reset"))
  #expect(reader.read(path: []).ping == nil)
  clock.set(50)
  _ = reader.read(path: [])
  reader.configure(connectivity: false, publicIP: false, revision: "off")
  transport.finish(3, .init(milliseconds: 4, reason: "After Off"))
  clock.set(80)
  #expect(reader.read(path: []).ping == nil && transport.count == 4 && http.count == 0)
}
