import Darwin
import Foundation
import Testing

@testable import TinyStatsCore

private let applePage = Data(
  "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n".utf8)
private let goodPage = HTTPProbeReply(status: 200, data: applePage)

@Test func internetChecksDefaultOffAndDecodeIndependently() throws {
  let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
  #expect(!legacy.connectivityChecks && !legacy.publicIPChecks)
  let malformed = try JSONDecoder().decode(
    Settings.self, from: Data(#"{"connectivityChecks":"yes","publicIPChecks":true}"#.utf8))
  #expect(!malformed.connectivityChecks && malformed.publicIPChecks)
  let copy = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(malformed))
  #expect(copy.publicIPChecks && !copy.connectivityChecks)
}

@Test func internetPayloadsRejectContentMismatchAndCanonicalizeAddressFamilies() {
  #expect(InternetEndpoint.ipv4.accepts(URL(string: "https://api.ipify.org/")))
  #expect(InternetEndpoint.ipv4.accepts(URL(string: "https://api.ipify.org:443")))
  #expect(!InternetEndpoint.ipv4.accepts(URL(string: "https://api.ipify.org/other")))
  #expect(!InternetEndpoint.ipv4.accepts(URL(string: "http://api.ipify.org/")))
  #expect(!InternetEndpoint.ipv4.accepts(URL(string: "https://other.invalid/")))
  #expect(InternetCheckLedger.validAppleResponse(applePage))
  #expect(!InternetCheckLedger.validAppleResponse(Data("Success".utf8)))
  #expect(!InternetCheckLedger.validAppleResponse(Data(repeating: 32, count: 1025)))
  #expect(
    InternetCheckLedger.address(Data(" 2001:0DB8:0:0::1\n".utf8), family: AF_INET6) == "2001:db8::1"
  )
  #expect(InternetCheckLedger.address(Data("192.0.2.1\n".utf8), family: AF_INET) == "192.0.2.1")
  for value in [
    "192.0.2.1:80", "127.0.0.1\0extra", "example.com", "1.2.3.999", "fe80::1%en0",
    "2001:db8::1\nsecond",
  ] {
    #expect(InternetCheckLedger.address(Data(value.utf8), family: AF_INET6) == nil)
    #expect(InternetCheckLedger.address(Data(value.utf8), family: AF_INET) == nil)
  }
  #expect(InternetCheckLedger.address(Data("192.0.2.1".utf8), family: AF_INET6) == nil)
}

@Test func internetLedgerGatesOptInCadenceAndInvalidationStorms() throws {
  var ledger = InternetCheckLedger()
  #expect(ledger.next(at: 0, path: []) == nil)
  ledger.configure(connectivity: true, publicIP: true)
  #expect(ledger.next(at: 0, path: ["en0"]) == .connectivity)
  let initial = try #require(ledger.active)
  #expect(ledger.next(at: 1, path: ["en0"]) == nil)
  ledger.finish(goodPage, token: initial.token, at: 0.1)
  #expect(ledger.snapshot.connectivity?.state == .expected)
  #expect(ledger.next(at: 2, path: ["en0"]) == .ipv4)
  let v4 = try #require(ledger.active)
  // A duplicate callback from the previous request must not complete the next one.
  ledger.finish(goodPage, token: initial.token, at: 2.1)
  #expect(ledger.active?.endpoint == .ipv4)
  ledger.finish(.init(status: 200, data: Data("192.0.2.1".utf8)), token: v4.token, at: 2.2)
  #expect(ledger.snapshot.ipv4?.changeID == nil)
  #expect(ledger.next(at: 4, path: ["en0"]) == .ipv6)
  let v6 = try #require(ledger.active)
  ledger.finish(.init(failure: .connection), token: v6.token, at: 4.1)
  #expect(ledger.next(at: 6, path: ["en0"]) == nil)
  // Path changes clear current values and cancel stale work without removing rate limits.
  #expect(ledger.next(at: 7, path: ["vpn"]) == nil)
  #expect(ledger.snapshot.ipv4 == nil && ledger.snapshot.connectivity == nil)
  #expect(ledger.next(at: 10, path: ["vpn"]) == .connectivity)
  let retry = try #require(ledger.active)
  ledger.finish(.init(failure: .timeout), token: retry.token, at: 11)
  #expect(ledger.snapshot.connectivity?.state == .failed)
  #expect(ledger.snapshot.connectivity?.milliseconds == nil)
}

@Test func internetLedgerPublicIPChangesNeedTwoSuccessfulResponses() throws {
  var ledger = InternetCheckLedger()
  ledger.configure(connectivity: false, publicIP: true)
  func reply(_ address: String) -> HTTPProbeReply { .init(status: 200, data: Data(address.utf8)) }
  #expect(ledger.next(at: 0, path: ["first"]) == .ipv4)
  ledger.finish(reply("192.0.2.1"), token: try #require(ledger.active).token, at: 1)
  #expect(ledger.snapshot.ipv4?.changeID == nil)
  #expect(ledger.next(at: 2, path: ["first"]) == .ipv6)
  ledger.finish(.init(failure: .dns), token: try #require(ledger.active).token, at: 3)
  #expect(ledger.next(at: 300, path: ["first"]) == .ipv4)
  ledger.finish(.init(failure: .timeout), token: try #require(ledger.active).token, at: 301)
  #expect(ledger.snapshot.ipv4?.address == nil)
  #expect(ledger.next(at: 302, path: ["first"]) == .ipv6)
  ledger.finish(.init(failure: .connection), token: try #require(ledger.active).token, at: 303)
  #expect(ledger.next(at: 600, path: ["new-route"]) == .ipv4)
  ledger.finish(reply("192.0.2.2"), token: try #require(ledger.active).token, at: 601)
  #expect(ledger.snapshot.ipv4?.changeID != nil)
  ledger.reset()
  #expect(ledger.snapshot.ipv4 == nil)
  #expect(ledger.next(at: 602, path: ["new-route"]) == .ipv6)
  ledger.finish(.init(failure: .connection), token: try #require(ledger.active).token, at: 603)
  #expect(ledger.next(at: 610, path: ["new-route"]) == .ipv4)
  ledger.finish(reply("192.0.2.3"), token: try #require(ledger.active).token, at: 611)
  #expect(ledger.snapshot.ipv4?.changeID == nil)
}

private final class ProbeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Double = 0
  func set(_ value: Double) {
    lock.lock()
    self.value = value
    lock.unlock()
  }
  func now() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
private final class ProbeFixture: HTTPProbeTransport, @unchecked Sendable {
  private(set) var requests: [InternetEndpoint] = []
  private(set) var requestedChecks: [HTTPSCheckConfiguration] = []
  private var completions: [@Sendable (HTTPProbeReply) -> Void] = []
  private(set) var cancellations = 0, shutdowns = 0
  func start(
    _ endpoint: InternetEndpoint, check: HTTPSCheckConfiguration,
    completion: @escaping @Sendable (HTTPProbeReply) -> Void
  ) {
    requests.append(endpoint)
    requestedChecks.append(check)
    completions.append(completion)
  }
  func complete(_ index: Int, _ reply: HTTPProbeReply) { completions[index](reply) }
  func cancel() { cancellations += 1 }
  func shutdown() { shutdowns += 1 }
}
@Test func internetReaderRejectsLateDisabledAndTimedOutCallbacks() {
  let transport = ProbeFixture()
  let clock = ProbeClock()
  let reader = InternetChecksReader(transport: transport, clock: clock.now)
  func read(_ time: Double, path: [String]) -> InternetChecksSnapshot {
    clock.set(time)
    return reader.read(path: path)
  }
  #expect(read(0, path: []).connectivity == nil)
  #expect(transport.requests.isEmpty)
  reader.configure(connectivity: true, publicIP: false)
  _ = read(0, path: ["en0"])
  #expect(transport.requests == [.connectivity])
  clock.set(1)
  transport.complete(0, goodPage)
  #expect(read(2, path: ["en0"]).connectivity?.state == .expected)
  reader.configure(connectivity: false, publicIP: false)
  transport.complete(0, goodPage)
  #expect(read(3, path: ["en0"]).connectivity == nil)
  #expect(transport.shutdowns == 1)
  reader.configure(connectivity: true, publicIP: false)
  _ = read(10, path: ["en0"])
  #expect(transport.requests.count == 2)
  let timeout = read(22, path: ["en0"])
  #expect(timeout.connectivity?.state == .failed)
  clock.set(23)
  transport.complete(1, goodPage)
  #expect(read(24, path: ["en0"]).connectivity?.state == .failed)
  reader.reset()
  #expect(read(25, path: ["en0"]).connectivity == nil)
}

@Test func internetRulesRequireFreshOptInAndNeverRepeatAnObservedChange() {
  var rule = AlertRule(id: "ip", metric: .publicIPChange)
  rule.enabled = true
  rule.cooldown = 30
  var engine = AlertEngine(rules: [rule])
  var snapshot = Snapshot()
  snapshot.uptime = 1
  snapshot.internetChecks.publicIPEnabled = true
  snapshot.internetChecks.ipv4 = .init(address: "192.0.2.1", checkedAt: 1, reason: "Fixture")
  #expect(engine.evaluate(snapshot, now: 1).isEmpty)
  snapshot.internetChecks.ipv4?.changeID = "observed-1"
  let notification = engine.evaluate(snapshot, now: 2)
  #expect(notification.count == 1)
  #expect(!notification[0].message.contains("192.0.2.1"))
  #expect(engine.evaluate(snapshot, now: 40).isEmpty)
  snapshot.uptime = 60
  snapshot.internetChecks.ipv4?.checkedAt = 60
  snapshot.internetChecks.ipv4?.changeID = "observed-2"
  #expect(engine.evaluate(snapshot, now: 60).count == 1)
  snapshot.internetChecks.publicIPEnabled = false
  #expect(engine.evaluate(snapshot, now: 100).isEmpty)
  snapshot.internetChecks.publicIPEnabled = true
  snapshot.uptime = 500
  #expect(engine.evaluate(snapshot, now: 500).isEmpty)
  var latency = AlertRule(id: "latency", metric: .httpsLatency)
  latency.enabled = true
  latency.hold = 0
  snapshot.internetChecks.connectivityEnabled = true
  snapshot.internetChecks.connectivity = .init(
    state: .expected, milliseconds: 1100, checkedAt: 500, reason: "Fixture")
  var latencyEngine = AlertEngine(rules: [latency])
  #expect(latencyEngine.evaluate(snapshot, now: snapshot.uptime).count == 1)
}

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    let body: Data
    switch url.host {
    case "www.apple.com": body = applePage
    case "health.invalid": body = Data("ok".utf8)
    case "large.invalid": body = Data(repeating: 65, count: 1025)
    case "api.ipify.org": body = Data(repeating: 120, count: 129)
    case "api6.ipify.org":
      let redirected = URLRequest(url: URL(string: "https://redirect.invalid/")!)
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirected.url!.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
      client?.urlProtocolDidFinishLoading(self)
      return
    default:
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    // Exercise the transport boundary's canonical root-slash response, not only
    // the pure allowlist helper; this caught a previously disconnected validator.
    let responseURL = url.host == "api.ipify.org" ? URL(string: "https://api.ipify.org/")! : url
    let response = HTTPURLResponse(
      url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
@Test func nativeHTTPTransportUsesBoundedDelegatePathWithoutExternalRequests() async {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ProbeURLProtocol.self]
  let transport = NativeHTTPProbe(configuration: configuration)
  defer { transport.shutdown() }
  let success = await withCheckedContinuation { continuation in
    transport.start(.connectivity) { continuation.resume(returning: $0) }
  }
  #expect(success.status == 200 && success.failure == nil && success.data == applePage)
  let oversized = await withCheckedContinuation { continuation in
    transport.start(.ipv4) { continuation.resume(returning: $0) }
  }
  #expect(oversized.failure == .oversized && oversized.data.isEmpty)
  let failed = await withCheckedContinuation { continuation in
    transport.start(.ipv6) { continuation.resume(returning: $0) }
  }
  #expect(failed.failure == .redirect)
}

@Test func queuedInternetResultsAndAlertsRequireCurrentOptInRevision() throws {
  var snapshot = InternetChecksSnapshot()
  snapshot.connectivityEnabled = true
  snapshot.publicIPEnabled = true
  snapshot.revision = "old"
  snapshot.connectivity = .init(state: .failed, milliseconds: nil, checkedAt: 10, reason: "Fixture")
  snapshot.ipv4 = .init(address: "192.0.2.1", checkedAt: 10, reason: "Fixture")
  let off = snapshot.filtered(connectivity: false, publicIP: false, revision: "old")
  #expect(off.connectivity == nil && off.ipv4 == nil)
  let reenabled = off.filtered(connectivity: true, publicIP: true, revision: "new")
  #expect(reenabled.ipv4 == nil)
  #expect(
    snapshot.filtered(connectivity: true, publicIP: true, revision: "new").connectivity == nil)
  #expect(
    snapshot.filtered(connectivity: true, publicIP: true, revision: "old", suspended: true).ipv4
      == nil)
  for metric in [RuleMetric.httpsState, .httpsLatency, .publicIPChange] {
    var rule = AlertRule(id: metric.rawValue, metric: metric)
    rule.enabled = true
    var settings = Settings()
    settings.alerts = true
    settings.rules = [rule]
    settings.internetRevision = "old"
    let event = AlertEvent(rule: rule, message: "Fixture", internetRevision: "old")
    #expect(!event.canDeliver(with: settings))
    settings.connectivityChecks = true
    settings.publicIPChecks = true
    #expect(event.canDeliver(with: settings))
    #expect(!event.canDeliver(with: settings, suspended: true))
    settings.internetRevision = "new"
    #expect(!event.canDeliver(with: settings))
  }
}

@Test func internetReaderTimesLaunchWithItsFreshMonotonicClock() {
  let transport = ProbeFixture()
  let clock = ProbeClock()
  let reader = InternetChecksReader(transport: transport, clock: clock.now)
  reader.configure(connectivity: true, publicIP: false)
  clock.set(5)  // Earlier sampler work may have started five seconds before this call.
  _ = reader.read(path: ["en0"])
  clock.set(5.1)
  transport.complete(0, goodPage)
  let reading = reader.read(path: ["en0"]).connectivity
  #expect(abs((reading?.milliseconds ?? 0) - 100) < 0.0001)
  clock.set(14.9)
  _ = reader.read(path: ["vpn"])
  #expect(transport.requests.count == 1)
  clock.set(15)
  _ = reader.read(path: ["vpn"])
  #expect(transport.requests.count == 2)
}

@Test func ownedOptInInternetEndpointValidation() async {
  guard ProcessInfo.processInfo.environment["TINYSTATS_VALIDATE_INTERNET"] == "1" else { return }
  let transport = NativeHTTPProbe()
  defer { transport.shutdown() }
  let check = await withCheckedContinuation { continuation in
    transport.start(.connectivity) { continuation.resume(returning: $0) }
  }
  let appleExpected =
    check.status == 200 && check.failure == nil
    && InternetCheckLedger.validAppleResponse(check.data)
  #expect(appleExpected)
  let v4 = await withCheckedContinuation { continuation in
    transport.start(.ipv4) { continuation.resume(returning: $0) }
  }
  let v4Valid =
    v4.status == 200 && v4.failure == nil
    && InternetCheckLedger.address(v4.data, family: AF_INET) != nil
  print(
    "Live IPv4 metadata: HTTP \(v4.status ?? 0), \(v4.failure?.rawValue ?? "no transport error"), \(v4.data.count) bytes"
  )
  #expect(v4Valid)
  let v6 = await withCheckedContinuation { continuation in
    transport.start(.ipv6) { continuation.resume(returning: $0) }
  }
  // This host need not have IPv6. Check the successful response when one exists;
  // a failed family remains unavailable rather than being synthesized from IPv4.
  if v6.failure == nil && v6.status == 200 {
    let v6Valid = InternetCheckLedger.address(v6.data, family: AF_INET6) != nil
    #expect(v6Valid)
  }
}

@Test func nativeCustomHTTPSUsesOnlyConfiguredDestinationAndKeepsTransportBounds() async {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ProbeURLProtocol.self]
  let transport = NativeHTTPProbe(configuration: configuration)
  defer { transport.shutdown() }
  let custom = HTTPSCheckConfiguration(customURL: "https://health.invalid/ready")
  let success = await withCheckedContinuation { continuation in
    transport.start(.connectivity, check: custom) { continuation.resume(returning: $0) }
  }
  #expect(success.failure == nil && success.data == Data("ok".utf8))
  let oversized = await withCheckedContinuation { continuation in
    transport.start(.connectivity, check: .init(customURL: "https://api.ipify.org")) {
      continuation.resume(returning: $0)
    }
  }
  // 129 bytes fit the custom-check 1024-byte cap, unlike the IP-provider 128-byte cap.
  #expect(oversized.failure == nil && oversized.data.count == 129)
  let tooLarge = await withCheckedContinuation { continuation in
    transport.start(.connectivity, check: .init(customURL: "https://large.invalid/")) {
      continuation.resume(returning: $0)
    }
  }
  #expect(tooLarge.failure == .oversized && tooLarge.data.isEmpty)
  let redirect = await withCheckedContinuation { continuation in
    transport.start(.connectivity, check: .init(customURL: "https://api6.ipify.org")) {
      continuation.resume(returning: $0)
    }
  }
  #expect(redirect.failure == .redirect)
  let invalid = await withCheckedContinuation { continuation in
    transport.start(.connectivity, check: .init(customURL: "http://health.invalid")) {
      continuation.resume(returning: $0)
    }
  }
  #expect(invalid.failure == .invalid)
}

@Test func internetReaderForwardsCustomConfigurationAndReplacesItAfterEdits() {
  let transport = ProbeFixture()
  let clock = ProbeClock()
  let reader = InternetChecksReader(transport: transport, clock: clock.now)
  let first = HTTPSCheckConfiguration(customURL: "https://first.invalid/ready", expectedStatus: 204)
  let second = HTTPSCheckConfiguration(
    customURL: "https://second.invalid/health", expectedStatus: 201)
  reader.configure(connectivity: true, publicIP: false, httpsCheck: first)
  _ = reader.read(path: [])
  #expect(transport.requestedChecks == [first])
  clock.set(1)
  transport.complete(0, .init(status: 204))
  #expect(reader.read(path: []).connectivity?.state == .expected)
  clock.set(60)
  _ = reader.read(path: [])
  #expect(transport.requestedChecks == [first, first])
  reader.configure(connectivity: true, publicIP: false, httpsCheck: second)
  clock.set(61)
  transport.complete(1, .init(status: 204))
  #expect(reader.read(path: []).connectivity == nil)
  #expect(transport.requestedChecks.count == 2)
  clock.set(70)
  _ = reader.read(path: [])
  #expect(transport.requestedChecks == [first, first, second])
  clock.set(70.25)
  transport.complete(2, .init(status: 201))
  let reading = reader.read(path: [])
  #expect(reading.httpsCheck == second && reading.connectivity?.state == .expected)
  #expect(reading.connectivity?.milliseconds == 250)
}
