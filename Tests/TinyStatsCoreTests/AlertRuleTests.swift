import CTinyStats
import Foundation
import XCTest

@testable import TinyStatsCore

final class AlertRuleTests: XCTestCase {
  private func snapshot(at time: Double = 10) -> Snapshot {
    var s = Snapshot()
    s.uptime = time
    s.cpu = .init(usage: 90, cores: [90], load: [])
    s.gpus = [
      .init(name: "GPU", usage: 10, memory: nil, id: 1),
      .init(name: "GPU", usage: 90, memory: nil, id: 2),
    ]
    s.memory = .init(
      total: 100, active: 80, inactive: 0, wired: 0, compressed: 0, free: 20, speculative: 0,
      purgeable: 0, swapUsed: 0, swapTotal: 0, pressure: 2)
    s.volumes = [
      .init(name: "A", path: "/", total: 100, available: 10, mountID: 1),
      .init(name: "B", path: "/Volumes/B", total: 100, available: 90, mountID: 2),
    ]
    s.disks = [.init(id: 1, name: "SSD", read: 5.0 * 1_048_576, written: 2.0 * 1_048_576)]
    s.interfaces = [
      .init(
        name: "en0", address: "", up: true, received: 0, sent: 0, download: 4.0 * 1_048_576,
        upload: 2.0 * 1_048_576),
      .init(
        name: "utun0", address: "", up: false, received: 0, sent: 0, download: nil, upload: nil),
    ]
    s.selectedInterface = "en0"
    s.sensors = [
      .init(key: "Tp01", name: "CPU · Tp01", kind: .temperature, value: 65),
      .init(key: "IC0C", name: "Current", kind: .current, value: -2),
    ]
    s.batteries = [
      .init(
        name: "Battery", percent: 20, charging: false, externalPower: false, minutesRemaining: nil,
        cycles: nil, health: nil, watts: -25)
    ]
    s.sensorsSampledAt = time
    s.batteriesSampledAt = time
    s.volumesSampledAt = time
    s.thermalState = "Serious"
    var health = ts_storage_health()
    health.id = 1
    health.available = true
    health.warning = true
    s.storageHealth.drives = [.init(raw: health)]
    s.storageHealth.checkedAt = s.timestamp
    s.internetChecks.connectivityEnabled = true
    s.internetChecks.publicIPEnabled = true
    s.internetChecks.connectivity = .init(
      state: .expected, milliseconds: 1200, checkedAt: time, reason: "Fixture")
    s.internetChecks.ipv4 = .init(
      address: "192.0.2.1", checkedAt: time, reason: "Fixture", changeID: "change-1")
    s.weather.settings.enabled = true
    s.weather.settings.location = .init(
      latitude: 60, longitude: 10, name: "Fixture", timeZone: "UTC")
    s.weather.settings.revision = "fixture"
    s.weather.receivedAt = time
    s.weather.forecast = .init(
      generatedAt: s.timestamp,
      points: [
        .init(
          date: s.timestamp, celsius: 30, windMetersPerSecond: 10, precipitationMM: 1,
          periodHours: 1)
      ])
    return s
  }
  private func enabled(_ metric: RuleMetric = .cpuUsage, threshold: Double? = nil) -> AlertRule {
    var rule = AlertRule(id: metric.rawValue, metric: metric)
    rule.enabled = true
    rule.hold = 0
    rule.cooldown = 30
    if let threshold { rule.threshold = threshold }
    return rule
  }
  func testEveryMetricUsesExistingSnapshotAndCanonicalUnits() {
    let thresholds: [RuleMetric: Double] = [
      .cpuUsage: 90, .gpuUsage: 80, .memoryUsage: 80, .memoryPressure: 1, .volumeUsage: 90,
      .diskRead: 5, .diskWrite: 2, .download: 4, .upload: 2, .interfaceState: 0, .sensor: 65,
      .batteryLevel: 20, .batteryPower: -25, .powerSource: 0, .thermalState: 2, .storageHealth: 0,
      .httpsState: 1, .httpsLatency: 1000, .publicIPChange: 0,
    ]
    for metric in RuleMetric.allCases {
      var rule = enabled(metric, threshold: thresholds[metric])
      if metric == .interfaceState { rule.source = "utun0" }
      rule.sound = true
      var engine = AlertEngine(rules: [rule])
      let result = engine.evaluate(snapshot(), now: 10)
      XCTAssertEqual(result.map(\.id), [rule.id], metric.rawValue)
      XCTAssertEqual(result.first?.sound, true)
      XCTAssertFalse(result.first?.message.isEmpty ?? true)
    }
  }
  func testMissingAndStaleReadingsCannotTrigger() {
    var empty = Snapshot()
    empty.thermalState = "Unavailable"
    for metric in RuleMetric.allCases {
      let rule = enabled(metric, threshold: 0)
      var engine = AlertEngine(rules: [rule])
      XCTAssertTrue(engine.evaluate(empty, now: 0).isEmpty, metric.rawValue)
    }
    for metric in [RuleMetric.sensor, .batteryLevel, .volumeUsage] {
      var stale = snapshot()
      stale.uptime += 61
      var engine = AlertEngine(rules: [enabled(metric, threshold: metric == .batteryLevel ? 20 : 1)]
      )
      XCTAssertTrue(engine.evaluate(stale, now: stale.uptime).isEmpty)
    }
    var unknown = snapshot()
    unknown.memory?.pressure = 3
    var engine = AlertEngine(rules: [enabled(.memoryPressure, threshold: 0)])
    XCTAssertTrue(engine.evaluate(unknown, now: 10).isEmpty)
  }
  func testAnySourceComparisonsAndPreferredIdentity() {
    var low = enabled(.gpuUsage, threshold: 20)
    low.comparison = .atMost
    XCTAssertEqual(low.observation(in: snapshot())?.identity, "gpu:1")
    var equal = enabled(.gpuUsage, threshold: 90)
    equal.comparison = .equals
    XCTAssertEqual(equal.observation(in: snapshot())?.identity, "gpu:2")
    let high = enabled(.gpuUsage, threshold: 5)
    XCTAssertEqual(high.observation(in: snapshot(), preferredSource: "gpu:2")?.identity, "gpu:2")
    var volume = enabled(.volumeUsage, threshold: 20)
    volume.comparison = .atMost
    XCTAssertEqual(volume.observation(in: snapshot())?.label, "B")
  }
  func testSourceSwitchAndHardwareReplacementRestartPendingDuration() {
    var rule = enabled(.gpuUsage, threshold: 80)
    rule.hold = 10
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    XCTAssertTrue(engine.evaluate(s, now: 0).isEmpty)
    s.gpus[1].id = 3  // Same model name, different hardware.
    XCTAssertTrue(engine.evaluate(s, now: 9).isEmpty)
    XCTAssertTrue(engine.evaluate(s, now: 10).isEmpty)
    XCTAssertEqual(engine.evaluate(s, now: 19).map(\.id), [rule.id])
    rule = enabled(.volumeUsage, threshold: 80)
    rule.hold = 10
    engine = AlertEngine(rules: [rule])
    XCTAssertTrue(engine.evaluate(s, now: 0).isEmpty)
    s.volumes[0].mountID = 9  // Replacement at the same path.
    XCTAssertTrue(engine.evaluate(s, now: 9).isEmpty)
    XCTAssertTrue(engine.evaluate(s, now: 10).isEmpty)
    XCTAssertEqual(engine.evaluate(s, now: 19).map(\.id), [rule.id])
  }
  func testSelectedInterfaceSwitchAndMissingRatesRestartHold() {
    var rule = enabled(.download, threshold: 1)
    rule.hold = 10
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    _ = engine.evaluate(s, now: 0)
    s.interfaces[0].download = nil
    XCTAssertTrue(engine.evaluate(s, now: 9).isEmpty)
    s.interfaces[0].download = 2.0 * 1_048_576
    XCTAssertTrue(engine.evaluate(s, now: 10).isEmpty)
    s.interfaces.append(
      .init(
        name: "en1", address: "", up: true, received: 0, sent: 0, download: 2.0 * 1_048_576,
        upload: 0
      ))
    s.selectedInterface = "en1"
    XCTAssertTrue(engine.evaluate(s, now: 19).isEmpty)
    XCTAssertTrue(engine.evaluate(s, now: 20).isEmpty)
    XCTAssertEqual(engine.evaluate(s, now: 29).map(\.id), [rule.id])
  }
  func testOncePerEpisodeMissingDataDoesNotRearmButRecoveryDoes() {
    var rule = enabled()
    rule.repeatWhileActive = false
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    XCTAssertEqual(engine.evaluate(s, now: 0).count, 1)
    s.cpu = nil
    XCTAssertTrue(engine.evaluate(s, now: 31).isEmpty)
    s.cpu = .init(usage: 95, cores: [], load: [])
    XCTAssertTrue(engine.evaluate(s, now: 32).isEmpty)
    s.cpu?.usage = 10
    XCTAssertTrue(engine.evaluate(s, now: 33).isEmpty)
    s.cpu?.usage = 95
    XCTAssertEqual(engine.evaluate(s, now: 34).count, 1)
  }
  func testEditingDisablingAndLifecycleResetsPreserveCooldown() {
    var rule = enabled()
    rule.repeatWhileActive = false
    var engine = AlertEngine(rules: [rule])
    let s = snapshot()
    XCTAssertEqual(engine.evaluate(s, now: 0).count, 1)
    rule.threshold = 80
    engine.configure([rule])
    XCTAssertTrue(engine.evaluate(s, now: 1).isEmpty)
    rule.enabled = false
    engine.configure([rule])
    XCTAssertTrue(engine.evaluate(s, now: 2).isEmpty)
    rule.enabled = true
    engine.configure([rule])
    engine.resetSustainedConditions()
    XCTAssertTrue(engine.evaluate(s, now: 29).isEmpty)
    XCTAssertEqual(engine.evaluate(s, now: 30).count, 1)
    engine.configure([])
    XCTAssertTrue(engine.evaluate(s, now: 100).isEmpty)
  }
  func testIndependentRulesHaveIndependentHoldsAndCooldowns() {
    var cpu = enabled()
    cpu.hold = 10
    cpu.cooldown = 30
    var gpu = enabled(.gpuUsage, threshold: 80)
    gpu.hold = 20
    gpu.cooldown = 60
    var engine = AlertEngine(rules: [cpu, gpu])
    let s = snapshot()
    XCTAssertTrue(engine.evaluate(s, now: 0).isEmpty)
    XCTAssertEqual(engine.evaluate(s, now: 10).map(\.id), [cpu.id])
    XCTAssertEqual(engine.evaluate(s, now: 20).map(\.id), [gpu.id])
    XCTAssertEqual(engine.evaluate(s, now: 40).map(\.id), [cpu.id])
    XCTAssertEqual(engine.evaluate(s, now: 80).map(\.id), [cpu.id, gpu.id])
  }
  func testSensorTypeMismatchAndNegativeCurrentThreshold() {
    var rule = enabled(.sensor, threshold: -1)
    rule.source = "IC0C"
    rule.sensorKind = .current
    rule.comparison = .atMost
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    XCTAssertEqual(engine.evaluate(s, now: 0).count, 1)
    s.sensors[1].kind = .voltage
    XCTAssertTrue(engine.evaluate(s, now: 31).isEmpty)
  }
  func testBatteryExternalPowerIsObservedRecovery() {
    var rule = enabled(.batteryLevel)
    rule.repeatWhileActive = false
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    XCTAssertEqual(engine.evaluate(s, now: 0).count, 1)
    s.batteries[0].externalPower = true
    XCTAssertTrue(engine.evaluate(s, now: 31).isEmpty)
    s.batteries[0].externalPower = false
    XCTAssertEqual(engine.evaluate(s, now: 32).count, 1)
  }
  func testSMARTObservationSurvivesPendingDurationAndCannotRepeatFromCache() {
    var rule = enabled(.storageHealth)
    rule.hold = 10
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    XCTAssertTrue(engine.evaluate(s, now: 0).isEmpty)
    XCTAssertEqual(engine.evaluate(s, now: 10).count, 1)
    XCTAssertTrue(engine.evaluate(s, now: 50).isEmpty)
    s.storageHealth.checkedAt = s.timestamp.addingTimeInterval(0.01)
    XCTAssertTrue(engine.evaluate(s, now: 51).isEmpty)
    s.timestamp = s.timestamp.addingTimeInterval(2)
    // The future observation reset the pending hold.
    XCTAssertTrue(engine.evaluate(s, now: 52).isEmpty)
    XCTAssertEqual(engine.evaluate(s, now: 62).count, 1)
  }
  func testMigrationLossyDecodeAndExplicitEmptyRules() throws {
    let legacy = try JSONDecoder().decode(
      Settings.self, from: Data(#"{"alerts":true,"interval":5}"#.utf8))
    XCTAssertEqual(legacy.rules, AlertRule.defaults)
    let damaged = Data(
      #"{"interval":10,"rules":[{"id":"good","metric":"cpuUsage","threshold":50,"enabled":true},{"id":"future","metric":"futureMetric","threshold":1},123,{"id":"bad","metric":"cpuUsage","threshold":80,"hold":"bad"},{"id":"good","metric":"gpuUsage","threshold":50},{"id":"second","metric":"gpuUsage","threshold":70}]}"#
        .utf8)
    let restored = try JSONDecoder().decode(Settings.self, from: damaged)
    XCTAssertEqual(restored.interval, 10)
    XCTAssertEqual(restored.rules.map(\.id), ["good", "second"])
    XCTAssertEqual(
      try JSONDecoder().decode(Settings.self, from: Data(#"{"rules":[]}"#.utf8)).rules, [])
    XCTAssertEqual(
      try JSONDecoder().decode(Settings.self, from: Data(#"{"rules":"bad"}"#.utf8)).rules, [])
    XCTAssertEqual(
      try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(restored)), restored)
  }
  func testValidationBoundsAndDiscreteStates() throws {
    var rule = enabled()
    for invalid in [Double.nan, .infinity, -1, 101] {
      rule.threshold = invalid
      XCTAssertNotNil(rule.validationError)
    }
    rule = enabled()
    rule.cooldown = 29
    XCTAssertNotNil(rule.validationError)
    rule = enabled()
    rule.hold = -1
    XCTAssertNotNil(rule.validationError)
    rule = enabled(.memoryPressure, threshold: 1.5)
    XCTAssertNotNil(rule.validationError)
    rule = enabled(.powerSource)
    rule.comparison = .atLeast
    XCTAssertNotNil(rule.validationError)
    rule = enabled(.sensor)
    rule.source = "cpu"
    rule.sensorKind = .power
    XCTAssertNotNil(rule.validationError)
    let many = (0..<100).map { AlertRule(id: "r\($0)") }
    var settings = Settings()
    settings.rules = many
    settings.validate()
    XCTAssertEqual(settings.rules.count, AlertRule.limit)
    let data = try JSONEncoder().encode(["rules": many])
    XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data).rules.count, AlertRule.limit)
  }
}

extension AlertRuleTests {
  func testPartialMissingAnyGPUDoesNotInventRecovery() {
    var rule = enabled(.gpuUsage, threshold: 80)
    rule.repeatWhileActive = false
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    XCTAssertEqual(engine.evaluate(s, now: 0).count, 1)
    s.gpus[1].usage = nil
    XCTAssertTrue(engine.evaluate(s, now: 31).isEmpty)
    s.gpus[1].usage = 90
    XCTAssertTrue(engine.evaluate(s, now: 32).isEmpty)
    s.gpus[1].usage = 10
    XCTAssertTrue(engine.evaluate(s, now: 33).isEmpty)
    s.gpus[1].usage = 90
    XCTAssertEqual(engine.evaluate(s, now: 34).count, 1)
  }
  func testDurableSelectorsSurviveRuntimeIdentifierChanges() {
    var gpu = enabled(.gpuUsage, threshold: 80)
    gpu.source = "model:GPU"
    var s = snapshot()
    XCTAssertNotNil(gpu.observation(in: s))
    s.gpus[1].id = 999
    XCTAssertEqual(gpu.observation(in: s)?.identity, "gpu:999")
    var drive = enabled(.storageHealth)
    let stable = String(repeating: "a", count: 64)
    drive.source = "drive:" + stable
    s.storageHealth.drives[0].stableID = stable
    s.storageHealth.drives[0].bsdName = "disk0"
    XCTAssertNotNil(drive.observation(in: s))
    s.storageHealth.drives[0].bsdName = "disk9"
    s.storageHealth.drives[0].id = 999
    XCTAssertEqual(drive.observation(in: s)?.identity, "drive:999")
    s.storageHealth.drives[0].stableID = String(repeating: "b", count: 64)
    XCTAssertNil(drive.observation(in: s))
  }
  func testPartialMissingSMARTDoesNotInventRecovery() {
    var rule = enabled(.storageHealth)
    rule.repeatWhileActive = false
    var engine = AlertEngine(rules: [rule])
    var s = snapshot()
    let warning = s.storageHealth.drives[0]
    var healthy = warning
    healthy.id = 2
    healthy.warning = false
    s.storageHealth.drives.append(healthy)
    XCTAssertEqual(engine.evaluate(s, now: 0).count, 1)
    s.storageHealth.drives = [healthy]
    s.timestamp = s.timestamp.addingTimeInterval(2)
    s.storageHealth.checkedAt = s.timestamp
    XCTAssertTrue(engine.evaluate(s, now: 31).isEmpty)
    s.storageHealth.drives = [warning, healthy]
    XCTAssertTrue(engine.evaluate(s, now: 32).isEmpty)
    s.storageHealth.drives[0].warning = false
    XCTAssertTrue(engine.evaluate(s, now: 33).isEmpty)
    s.storageHealth.drives[0].warning = true
    XCTAssertEqual(engine.evaluate(s, now: 34).count, 1)
  }
}

extension AlertRuleTests {
  func testQueuedEventsRespectCurrentOptInAndExactRuleConfiguration() throws {
    let rule = enabled()
    var engine = AlertEngine(rules: [rule])
    let event = try XCTUnwrap(engine.evaluate(snapshot(), now: 0).first)
    var settings = Settings()
    settings.rules = [rule]
    XCTAssertFalse(event.canDeliver(with: settings))
    settings.alerts = true
    XCTAssertTrue(event.canDeliver(with: settings))
    settings.fahrenheit = true  // An unrelated display edit doesn't invalidate it.
    XCTAssertTrue(event.canDeliver(with: settings))
    settings.rules[0].threshold = 95
    XCTAssertFalse(event.canDeliver(with: settings))
    settings.rules = [rule]
    settings.rules[0].enabled = false
    XCTAssertFalse(event.canDeliver(with: settings))
    settings.rules = []
    XCTAssertFalse(event.canDeliver(with: settings))
  }
  func testFractionalDurationIsNotTruncatedInNotification() throws {
    var rule = enabled()
    rule.hold = 0.5
    var engine = AlertEngine(rules: [rule])
    let s = snapshot()
    XCTAssertTrue(engine.evaluate(s, now: 0).isEmpty)
    let event = try XCTUnwrap(engine.evaluate(s, now: 1).first)
    XCTAssertTrue(event.message.contains("0.5 seconds"))
  }
}

extension AlertRuleTests {
  func testMinimalBenchmarkConfigurationEnablesAll32Rules() throws {
    let metrics = RuleMetric.allCases.filter {
      ![.httpsState, .httpsLatency, .publicIPChange].contains($0)
    }
    let rules: [[String: Any]] = (0..<32).map { index in
      [
        "id": "benchmark-\(index)", "metric": metrics[index % metrics.count].rawValue,
        "threshold": 0, "hold": 86400, "enabled": true,
      ]
    }
    let data = try JSONSerialization.data(withJSONObject: ["alerts": true, "rules": rules])
    let settings = try JSONDecoder().decode(Settings.self, from: data)
    XCTAssertTrue(settings.alerts)
    XCTAssertEqual(settings.rules.count, 32)
    XCTAssertTrue(settings.rules.allSatisfy { $0.enabled && $0.hold == 86400 })
    XCTAssertEqual(Set(settings.rules.map(\.metric)), Set(metrics))
  }
}
