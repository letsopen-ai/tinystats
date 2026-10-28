import Foundation
import Testing

@testable import TinyStatsCore

@Test func httpsConfigurationValidatesDestinationAndStatus() {
  for raw in [
    "https://example.com/health", "https://example.com:443", "https://127.0.0.1/status",
    "https://[::1]/ready", "https://example.com/a%2Fb",
  ] {
    #expect(HTTPSCheckConfiguration(customURL: raw, expectedStatus: 204).validationError == nil)
  }
  for raw in [
    "https://example.com/a/../b", "https://example.com/a/./b", "https://example.com/a/%2E%2e/b",
    "http://example.com/", "https://", "https://u:p@example.com/", "https://example.com/?token=x",
    "https://example.com/#x", "https://example.com:8443/", "https://example.com/a b",
    "https://example.com/\n", "https://éxample.com/", String(repeating: "x", count: 513),
  ] {
    #expect(HTTPSCheckConfiguration(customURL: raw).url == nil)
  }
  #expect(
    HTTPSCheckConfiguration(customURL: "https://example.com/", expectedStatus: 302).url == nil)
  #expect(HTTPSCheckConfiguration(expectedStatus: 204).url == nil)
  let check = HTTPSCheckConfiguration(customURL: "https://example.com/a%2Fb")
  #expect(check.accepts(URL(string: "https://example.com:443/a%2Fb")))
  #expect(!check.accepts(URL(string: "https://example.com/a/b")))
  #expect(!check.accepts(URL(string: "https://example.com/a%2Fb?x=1")))
  #expect(!check.accepts(URL(string: "https://other.invalid/a%2Fb")))
}

@Test func malformedSavedHTTPSConfigurationNeverEnablesDefaultDestination() throws {
  for value in [
    "null", "{}", "42", #"{"customURL":"http://example.com","expectedStatus":200}"#,
    #"{"customURL":"https://example.com","expectedStatus":999}"#,
  ] {
    let data = Data(
      "{\"connectivityChecks\":true,\"publicIPChecks\":true,\"httpsCheck\":\(value)}".utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: data)
    #expect(!settings.connectivityChecks)
    #expect(settings.publicIPChecks)
  }
  let old = try JSONDecoder().decode(
    Settings.self, from: Data(#"{"connectivityChecks":true}"#.utf8))
  #expect(old.connectivityChecks && !old.httpsCheck.isCustom)
  var custom = old
  custom.httpsCheck = .init(customURL: "https://health.invalid/", expectedStatus: 204)
  let copy = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(custom))
  #expect(copy.httpsCheck == custom.httpsCheck && copy.connectivityChecks)
}

@Test func customHTTPSStatusIsDistinctFromAppleContentAndChangeInvalidatesInFlight() throws {
  var ledger = InternetCheckLedger()
  let custom = HTTPSCheckConfiguration(customURL: "https://health.invalid/", expectedStatus: 204)
  ledger.configure(connectivity: true, publicIP: false, httpsCheck: custom)
  #expect(ledger.next(at: 0, path: []) == .connectivity)
  let token = try #require(ledger.active).token
  ledger.finish(.init(status: 200, data: Data("ok".utf8)), token: token, at: 1)
  #expect(ledger.snapshot.connectivity?.state == .unexpected)
  #expect(ledger.snapshot.connectivity?.milliseconds == nil)
  #expect(ledger.next(at: 59, path: []) == nil)
  #expect(ledger.next(at: 60, path: []) == .connectivity)
  ledger.finish(.init(status: 204), token: try #require(ledger.active).token, at: 60.25)
  #expect(ledger.snapshot.connectivity?.state == .expected)
  #expect(ledger.snapshot.connectivity?.milliseconds == 250)
  #expect(ledger.next(at: 120, path: []) == .connectivity)
  let stale = try #require(ledger.active).token
  ledger.configure(connectivity: true, publicIP: false)
  ledger.finish(.init(status: 204), token: stale, at: 121)
  #expect(ledger.snapshot.connectivity == nil)
  #expect(ledger.next(at: 121, path: []) == nil)
  #expect(ledger.next(at: 130, path: []) == .connectivity)
  ledger.finish(
    .init(status: 200, data: Data("ok".utf8)), token: try #require(ledger.active).token, at: 131)
  #expect(ledger.snapshot.connectivity?.state == .unexpected)
}

@Test func destinationChangesRejectQueuedResultsAndAlertsWithoutDependingOnRevision() {
  let old = HTTPSCheckConfiguration(customURL: "https://first.invalid/")
  let next = HTTPSCheckConfiguration(customURL: "https://second.invalid/")
  var snapshot = InternetChecksSnapshot()
  snapshot.connectivityEnabled = true
  snapshot.httpsCheck = old
  snapshot.connectivity = .init(state: .expected, milliseconds: 5, checkedAt: 1, reason: "Fixture")
  #expect(
    snapshot.filtered(connectivity: true, publicIP: false, revision: "", httpsCheck: next)
      .connectivity == nil)
  var rule = AlertRule(id: "https", metric: .httpsLatency)
  rule.enabled = true
  var settings = Settings()
  settings.alerts = true
  settings.rules = [rule]
  settings.connectivityChecks = true
  settings.httpsCheck = next
  let event = AlertEvent(
    rule: rule, message: "Fixture", internetRevision: "", httpsConfiguration: old)
  #expect(!event.canDeliver(with: settings))
  settings.httpsCheck = old
  #expect(event.canDeliver(with: settings))
}

@Test func sustainedHTTPSRuleRestartsForDifferentEndpoint() {
  var rule = AlertRule(id: "https", metric: .httpsState)
  rule.enabled = true
  rule.comparison = .equals
  rule.threshold = 0
  rule.hold = 10
  var engine = AlertEngine(rules: [rule])
  var s = Snapshot()
  s.internetChecks.connectivityEnabled = true
  s.internetChecks.httpsCheck = .init(customURL: "https://first.invalid/")
  func failure(_ at: Double) -> HTTPSCheckReading {
    .init(state: .failed, milliseconds: nil, checkedAt: at, reason: "Fixture")
  }
  s.uptime = 0
  s.internetChecks.connectivity = failure(0)
  #expect(engine.evaluate(s, now: 0).isEmpty)
  s.uptime = 9
  s.internetChecks.connectivity = failure(9)
  #expect(engine.evaluate(s, now: 9).isEmpty)
  s.uptime = 10
  s.internetChecks.httpsCheck = .init(customURL: "https://second.invalid/")
  s.internetChecks.connectivity = failure(10)
  #expect(engine.evaluate(s, now: 10).isEmpty)
  s.uptime = 20
  s.internetChecks.connectivity = failure(20)
  #expect(engine.evaluate(s, now: 20).count == 1)
}
