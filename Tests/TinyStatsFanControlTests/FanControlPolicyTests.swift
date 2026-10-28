import Foundation
import Testing
import TinyStatsFanControl

private let limits = FanLimits(id: 0, minimumRPM: 1000, maximumRPM: 4900)
private func curve() throws -> FanCurve {
  try #require(
    FanCurve(points: [
      .init(celsius: 40, fraction: 0), .init(celsius: 60, fraction: 0.5),
      .init(celsius: 80, fraction: 1),
    ]))
}
private func frame(
  at time: Double = 1, token: UInt64 = 7,
  capability: FanControlFrame.Capability = .raisedMinimumPreservesSystemControl,
  thermal: FanControlFrame.ThermalState = .nominal,
  fans: [FanLimits] = [limits], temperatures: [FanTemperature]? = nil
) -> FanControlFrame {
  .init(
    capability: capability, thermalState: thermal, deviceToken: token, sampledAt: time,
    fans: fans, temperatures: temperatures ?? [.init(key: "CPU", celsius: 60, sampledAt: time)])
}
private func custom(_ rpm: Int = 2000) -> FanConfiguration {
  .custom([.init(fanID: 0, mode: .manual(minimumRPM: rpm))])
}
private func curved(_ curve: FanCurve) -> FanConfiguration {
  .custom([.init(fanID: 0, mode: .curve(sensorKeys: ["CPU", "GPU"], curve))])
}

@Test func fanCurveInterpolatesAndRoundsUpInsideReportedBounds() throws {
  let value = try curve()
  #expect(value.minimumRPM(celsius: 0, limits: limits) == 1000)
  #expect(value.minimumRPM(celsius: 40, limits: limits) == 1000)
  #expect(value.minimumRPM(celsius: 50, limits: limits) == 1975)
  #expect(value.minimumRPM(celsius: 60, limits: limits) == 2950)
  #expect(value.minimumRPM(celsius: 80, limits: limits) == 4900)
  #expect(value.minimumRPM(celsius: 120, limits: limits) == 4900)
  let fractional = FanLimits(id: 0, minimumRPM: 1000, maximumRPM: 1001)
  #expect(value.minimumRPM(celsius: 50, limits: fractional) == 1001)
  for temperature in stride(from: -20.0, through: 125, by: 0.5) {
    let rpm = try #require(value.minimumRPM(celsius: temperature, limits: limits))
    #expect((1000...4900).contains(rpm))
  }
}

@Test func fanCurveRejectsUnboundedNonmonotonicAndNonfiniteInputs() throws {
  #expect(FanCurve(points: []) == nil)
  #expect(FanCurve(points: Array(repeating: .init(celsius: 40, fraction: 0), count: 9)) == nil)
  for bad in [Double.nan, .infinity, -.infinity, -21, 126] {
    #expect(
      FanCurve(points: [.init(celsius: bad, fraction: 0), .init(celsius: 80, fraction: 1)]) == nil)
    #expect(try curve().minimumRPM(celsius: bad, limits: limits) == nil)
  }
  for bad in [Double.nan, .infinity, -0.1, 1.1] {
    #expect(
      FanCurve(points: [.init(celsius: 40, fraction: bad), .init(celsius: 80, fraction: 1)]) == nil)
  }
  #expect(
    FanCurve(points: [.init(celsius: 40, fraction: 0), .init(celsius: 40, fraction: 1)]) == nil)
  #expect(
    FanCurve(points: [.init(celsius: 80, fraction: 0), .init(celsius: 40, fraction: 1)]) == nil)
  #expect(
    FanCurve(points: [.init(celsius: 40, fraction: 1), .init(celsius: 80, fraction: 0)]) == nil)
  for bad in [
    FanLimits(id: 8, minimumRPM: 0, maximumRPM: 5000),
    FanLimits(id: 0, minimumRPM: 4900, maximumRPM: 1000),
    FanLimits(id: 0, minimumRPM: Int.min, maximumRPM: Int.max),
  ] {
    #expect(try curve().minimumRPM(celsius: 60, limits: bad) == nil)
  }
}

@Test func fanPolicyDefaultsToSystemAndRejectsInvalidArmingWithoutRetainingOldPolicy() throws {
  let policy = FanControlPolicy()
  #expect(policy.evaluate(frame(), at: 1) == .restoreSystem(.automatic))
  let c = try curve()
  let invalid: [FanConfiguration] = [
    .custom([]),
    .custom(Array(repeating: .init(fanID: 0, mode: .manual(minimumRPM: 2000)), count: 9)),
    .custom([.init(fanID: -1, mode: .manual(minimumRPM: 2000))]),
    .custom([.init(fanID: 0, mode: .manual(minimumRPM: -1))]),
    .custom([
      .init(fanID: 0, mode: .manual(minimumRPM: 2001)),
      .init(fanID: 0, mode: .manual(minimumRPM: 3000)),
    ]),
    .custom([.init(fanID: 0, mode: .curve(sensorKeys: [], c))]),
    .custom([.init(fanID: 0, mode: .curve(sensorKeys: ["CPU", "CPU"], c))]),
    .custom([.init(fanID: 0, mode: .curve(sensorKeys: [String(repeating: "x", count: 65)], c))]),
    .custom([.init(fanID: 0, mode: .curve(sensorKeys: ["CPU\n"], c))]),
  ]
  for candidate in invalid {
    #expect(policy.configure(custom(), deviceToken: 7, at: 1))
    #expect(!policy.configure(candidate, deviceToken: 7, at: 1))
    #expect(policy.evaluate(frame(), at: 1) == .restoreSystem(.invalidConfiguration))
  }
  #expect(!policy.configure(custom(), deviceToken: 0, at: 1))
  #expect(!policy.configure(custom(), deviceToken: 7, at: .nan))
}

@Test func fanPolicyRequiresVerifiedSystemPreservingCapabilityAndKnownThermalState() {
  let policy = FanControlPolicy()
  #expect(policy.configure(custom(), deviceToken: 7, at: 1))
  #expect(
    policy.evaluate(frame(capability: .unverified), at: 1) == .restoreSystem(.unverifiedBackend))
  for thermal in [FanControlFrame.ThermalState.unknown, .serious, .critical] {
    #expect(policy.evaluate(frame(thermal: thermal), at: 1) == .restoreSystem(.thermalPressure))
  }
  #expect(
    policy.evaluate(frame(thermal: .fair), at: 1) == .raiseMinimum([.init(fanID: 0, rpm: 2000)]))
}

@Test func fanPolicyNeverExtendsTheLeaseMerelyByEvaluatingAndCannotReviveExpiredSessions() {
  let policy = FanControlPolicy()
  #expect(policy.configure(custom(), deviceToken: 7, at: 1))
  for time in [1.0, 5, 9, 10.99] {
    #expect(
      policy.evaluate(frame(at: time), at: time) == .raiseMinimum([.init(fanID: 0, rpm: 2000)]))
  }
  #expect(policy.evaluate(frame(at: 11), at: 11) == .restoreSystem(.leaseExpired))
  #expect(!policy.keepAlive(at: 11))
  #expect(policy.evaluate(frame(at: 12), at: 12) == .restoreSystem(.leaseExpired))
  #expect(policy.configure(custom(), deviceToken: 7, at: 20))
  #expect(policy.keepAlive(at: 29))
  #expect(policy.evaluate(frame(at: 30), at: 30) == .raiseMinimum([.init(fanID: 0, rpm: 2000)]))
  #expect(!policy.keepAlive(at: 39))
  #expect(policy.evaluate(frame(at: 39), at: 39) == .restoreSystem(.leaseExpired))
}

@Test func fanPolicyRejectsBackwardAndInvalidClocksAndLatchesDeviceChanges() {
  let policy = FanControlPolicy()
  for bad in [Double.nan, .infinity, -1, 0.5] {
    #expect(policy.configure(custom(), deviceToken: 7, at: 1))
    #expect(policy.evaluate(frame(at: bad), at: bad) == .restoreSystem(.clockReset))
  }
  #expect(policy.configure(custom(), deviceToken: 7, at: 1))
  #expect(policy.keepAlive(at: 5))
  #expect(policy.evaluate(frame(at: 4), at: 4) == .restoreSystem(.clockReset))
  #expect(policy.configure(custom(), deviceToken: 7, at: 1))
  #expect(policy.evaluate(frame(token: 8), at: 1) == .restoreSystem(.deviceChanged))
  #expect(policy.evaluate(frame(), at: 1) == .restoreSystem(.deviceChanged))
}

@Test func fanPolicyValidatesWholeInventoriesAndManualLimitsBeforeReturningAnyCommand() {
  let policy = FanControlPolicy()
  #expect(policy.configure(custom(), deviceToken: 7, at: 1))
  for fans in [
    [], [limits, limits], [FanLimits(id: 0, minimumRPM: 5000, maximumRPM: 4000)],
    [FanLimits(id: 1, minimumRPM: 1000, maximumRPM: 4900)], Array(repeating: limits, count: 9),
  ] {
    #expect(policy.evaluate(frame(fans: fans), at: 1) == .restoreSystem(.invalidInventory))
  }
  for bad in [0.0, 7, .nan, .infinity] {
    #expect(policy.evaluate(frame(at: bad), at: 6) == .restoreSystem(.staleInventory))
  }
  #expect(policy.configure(custom(999), deviceToken: 7, at: 1))
  #expect(policy.evaluate(frame(), at: 1) == .restoreSystem(.invalidConfiguration))
  #expect(policy.configure(custom(4901), deviceToken: 7, at: 1))
  #expect(policy.evaluate(frame(), at: 1) == .restoreSystem(.invalidConfiguration))
  let rules = [
    FanRule(fanID: 0, mode: .manual(minimumRPM: 2000)),
    .init(fanID: 1, mode: .manual(minimumRPM: 9999)),
  ]
  #expect(policy.configure(.custom(rules), deviceToken: 7, at: 1))
  #expect(
    policy.evaluate(frame(fans: [limits, .init(id: 1, minimumRPM: 1000, maximumRPM: 4000)]), at: 1)
      == .restoreSystem(.invalidConfiguration))
}

@Test func fanPolicyUsesOnlyAllSelectedFreshSensorsWithoutInventingMissingTemperatures() throws {
  let policy = FanControlPolicy()
  #expect(policy.configure(curved(try curve()), deviceToken: 7, at: 1))
  let cpu = FanTemperature(key: "CPU", celsius: 40, sampledAt: 1)
  let gpu = FanTemperature(key: "GPU", celsius: 80, sampledAt: 1)
  #expect(
    policy.evaluate(frame(temperatures: [cpu, gpu]), at: 1)
      == .raiseMinimum([.init(fanID: 0, rpm: 4900)]))
  #expect(policy.evaluate(frame(temperatures: [cpu]), at: 1) == .restoreSystem(.missingSensor))
  #expect(
    policy.evaluate(frame(temperatures: [cpu, gpu, cpu]), at: 1) == .restoreSystem(.missingSensor))
  for sampled in [Double.nan, .infinity, -1, 2] {
    let bad = FanTemperature(key: "GPU", celsius: 60, sampledAt: sampled)
    #expect(
      policy.evaluate(frame(temperatures: [cpu, bad]), at: 1) == .restoreSystem(.staleSensor))
  }
  for celsius in [Double.nan, .infinity, -21, 126] {
    let bad = FanTemperature(key: "GPU", celsius: celsius, sampledAt: 1)
    #expect(
      policy.evaluate(frame(temperatures: [cpu, bad]), at: 1) == .restoreSystem(.invalidSensor))
  }
  #expect(
    policy.evaluate(frame(at: 7, temperatures: [cpu, gpu]), at: 7) == .restoreSystem(.staleSensor))
}

@Test func fanPolicyRaisesImmediatelyAndDelaysLoweringWithoutCarryingHistoryAcrossFallback() throws
{
  let policy = FanControlPolicy()
  let c = try curve()
  #expect(
    policy.configure(
      .custom([.init(fanID: 0, mode: .curve(sensorKeys: ["CPU"], c))]), deviceToken: 7, at: 1))
  func sample(_ time: Double, _ celsius: Double) -> FanControlFrame {
    frame(at: time, temperatures: [.init(key: "CPU", celsius: celsius, sampledAt: time)])
  }
  #expect(policy.evaluate(sample(1, 40), at: 1) == .raiseMinimum([.init(fanID: 0, rpm: 1000)]))
  #expect(policy.evaluate(sample(2, 80), at: 2) == .raiseMinimum([.init(fanID: 0, rpm: 4900)]))
  #expect(policy.evaluate(sample(3, 40), at: 3) == .raiseMinimum([.init(fanID: 0, rpm: 4900)]))
  #expect(policy.evaluate(sample(7, 40), at: 7) == .raiseMinimum([.init(fanID: 0, rpm: 4900)]))
  #expect(policy.evaluate(sample(8, 40), at: 8) == .raiseMinimum([.init(fanID: 0, rpm: 1000)]))
  #expect(policy.evaluate(sample(9, 80), at: 9) == .raiseMinimum([.init(fanID: 0, rpm: 4900)]))
  #expect(
    policy.evaluate(frame(at: 9, capability: .unverified), at: 9)
      == .restoreSystem(.unverifiedBackend))
  #expect(policy.evaluate(sample(9, 40), at: 9) == .raiseMinimum([.init(fanID: 0, rpm: 1000)]))
  policy.stop()
  #expect(policy.evaluate(sample(9, 80), at: 9) == .restoreSystem(.automatic))
}

@Test func fanPolicyCannotRetainAHysteresisValueAboveChangedHardwareBounds() throws {
  let policy = FanControlPolicy()
  let c = try curve()
  #expect(
    policy.configure(
      .custom([.init(fanID: 0, mode: .curve(sensorKeys: ["CPU"], c))]), deviceToken: 7, at: 1))
  let hot = FanTemperature(key: "CPU", celsius: 80, sampledAt: 1)
  #expect(
    policy.evaluate(frame(temperatures: [hot]), at: 1)
      == .raiseMinimum([.init(fanID: 0, rpm: 4900)]))
  let lower = frame(
    at: 2, fans: [.init(id: 0, minimumRPM: 1000, maximumRPM: 4000)],
    temperatures: [.init(key: "CPU", celsius: 40, sampledAt: 2)])
  #expect(policy.evaluate(lower, at: 2) == .restoreSystem(.boundsChanged))
  #expect(policy.evaluate(lower, at: 2) == .raiseMinimum([.init(fanID: 0, rpm: 1000)]))
}

@Test func fanPolicyReturnsDeterministicPerFanDecisionsAndDoesNotLeakUnselectedSensors() throws {
  let policy = FanControlPolicy()
  let c = try curve()
  let config = FanConfiguration.custom([
    .init(fanID: 1, mode: .curve(sensorKeys: ["GPU"], c)),
    .init(fanID: 0, mode: .manual(minimumRPM: 2000)),
  ])
  #expect(policy.configure(config, deviceToken: 7, at: 1))
  let two = frame(
    fans: [.init(id: 1, minimumRPM: 500, maximumRPM: 3500), limits],
    temperatures: [
      .init(key: "GPU", celsius: 60, sampledAt: 1),
      .init(key: "Other", celsius: .nan, sampledAt: .nan),
    ])
  #expect(
    policy.evaluate(two, at: 1)
      == .raiseMinimum([.init(fanID: 0, rpm: 2000), .init(fanID: 1, rpm: 2000)]))
}

@Test func fanPolicyCoolingRestartsAfterReheatingAndRunsIndependentlyForEachFan() throws {
  let policy = FanControlPolicy()
  let c = try curve()
  let config = FanConfiguration.custom([
    .init(fanID: 0, mode: .curve(sensorKeys: ["CPU"], c)),
    .init(fanID: 1, mode: .curve(sensorKeys: ["GPU"], c)),
  ])
  #expect(policy.configure(config, deviceToken: 7, at: 1))
  func evaluate(_ time: Double, cpu: Double, gpu: Double) -> FanDecision {
    let two = frame(
      at: time, fans: [limits, .init(id: 1, minimumRPM: 1000, maximumRPM: 4900)],
      temperatures: [
        .init(key: "CPU", celsius: cpu, sampledAt: time),
        .init(key: "GPU", celsius: gpu, sampledAt: time),
      ])
    return policy.evaluate(two, at: time)
  }
  func output(_ cpu: Int, _ gpu: Int) -> FanDecision {
    .raiseMinimum([.init(fanID: 0, rpm: cpu), .init(fanID: 1, rpm: gpu)])
  }
  #expect(evaluate(1, cpu: 80, gpu: 80) == output(4900, 4900))
  #expect(evaluate(2, cpu: 40, gpu: 80) == output(4900, 4900))
  #expect(evaluate(4, cpu: 80, gpu: 40) == output(4900, 4900))
  #expect(evaluate(5, cpu: 40, gpu: 40) == output(4900, 4900))
  #expect(evaluate(7, cpu: 40, gpu: 40) == output(4900, 4900))
  #expect(evaluate(9, cpu: 40, gpu: 40) == output(4900, 1000))
  #expect(evaluate(10, cpu: 40, gpu: 40) == output(1000, 1000))
}

@Test func fanPolicyFreshnessIncludesTheBoundaryButNeverFutureOrOlderObservations() throws {
  let policy = FanControlPolicy()
  #expect(policy.configure(custom(), deviceToken: 7, at: 1))
  #expect(policy.evaluate(frame(), at: 6) == .raiseMinimum([.init(fanID: 0, rpm: 2000)]))
  #expect(policy.evaluate(frame(), at: 6.001) == .restoreSystem(.staleInventory))
  let c = try curve()
  #expect(
    policy.configure(
      .custom([.init(fanID: 0, mode: .curve(sensorKeys: ["CPU"], c))]), deviceToken: 7, at: 1))
  let old = FanTemperature(key: "CPU", celsius: 60, sampledAt: 1)
  #expect(
    policy.evaluate(frame(at: 6, temperatures: [old]), at: 6)
      == .raiseMinimum([.init(fanID: 0, rpm: 2950)]))
  #expect(
    policy.evaluate(frame(at: 6.001, temperatures: [old]), at: 6.001)
      == .restoreSystem(.staleSensor))
}
