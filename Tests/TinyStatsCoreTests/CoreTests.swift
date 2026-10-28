import CTinyStats
import Darwin
import XCTest

@testable import TinyStatsCore

private final class RingRetentionWitness: Sendable {}

final class CoreTests: XCTestCase {
  func testHistoryIsBoundedAndOrdered() {
    var ring = RingBuffer<Int>(capacity: 3)
    XCTAssertEqual(ring.elements, [])
    for i in 1...10000 { ring.append(i) }
    XCTAssertEqual(ring.count, 3)
    XCTAssertEqual(ring.elements, [9998, 9999, 10000])
    ring.removeAll()
    XCTAssertEqual(ring.count, 0)
    ring.append(42)
    XCTAssertEqual(ring.elements, [42])
  }
  func testHistoryTrimsExpiredPrefixAcrossWrapAndReusesSlots() {
    var ring = RingBuffer<Int>(capacity: 3)
    for value in 0...4 { ring.append(value) }
    ring.removeFirst { $0 <= 2 }
    XCTAssertEqual(ring.elements, [3, 4])
    XCTAssertEqual(ring.count, 2)
    ring.append(5)
    ring.append(6)
    XCTAssertEqual(ring.elements, [4, 5, 6])
    ring.removeFirst { $0 == 5 }
    XCTAssertEqual(ring.elements, [4, 5, 6])
    ring.removeFirst { _ in true }
    XCTAssertEqual(ring.count, 0)
    ring.removeFirst { _ in true }
    ring.append(42)
    XCTAssertEqual(ring.elements, [42])
    var optional = RingBuffer<Int?>(capacity: 2)
    optional.append(nil)
    optional.append(0)
    optional.removeFirst { $0 == nil }
    XCTAssertEqual(optional.count, 1)
    XCTAssertEqual(optional.elements[0], 0)
  }
  func testHistoryTrimmingReleasesDiscardedValues() {
    var value: RingRetentionWitness? = RingRetentionWitness()
    weak var released = value
    var ring = RingBuffer<RingRetentionWitness>(capacity: 3)
    ring.append(value!)
    value = nil
    XCTAssertNotNil(released)
    ring.removeFirst { _ in true }
    XCTAssertNil(released)
    released = nil
  }
  func testRatesUseElapsedTimeAndReset() {
    var rate = RateCounter()
    XCTAssertNil(rate.sample(100, at: 1))
    XCTAssertEqual(rate.sample(400, at: 3), 150)
    XCTAssertNil(rate.sample(20, at: 4))
    XCTAssertEqual(rate.sample(30, at: 6), 5)
    rate.reset()
    XCTAssertNil(rate.sample(40, at: 7))
  }
  func testRatesRejectRepeatedOrBackwardsTimes() {
    var rate = RateCounter()
    _ = rate.sample(100, at: 2)
    XCTAssertNil(rate.sample(101, at: 2))
    XCTAssertNil(rate.sample(102, at: 1))
    XCTAssertEqual(rate.sample(104, at: 2), 2)
  }
  func testRatesRetain64BitPrecisionForLargeCounters() {
    var rate = RateCounter()
    _ = rate.sample(UInt64.max - 1000, at: 1)
    XCTAssertEqual(rate.sample(UInt64.max - 500, at: 3), 250)
  }
  func testCPUPercentageAndTickWrap() {
    let old = CPUTicks(user: 100, system: 100, idle: 200)
    XCTAssertEqual(CPUTicks(user: 120, system: 110, idle: 270).utilization(since: old), 30)
    XCTAssertNil(old.utilization(since: old))
    let wrapped = CPUTicks(user: 2, system: 0, idle: 4)
    XCTAssertEqual(wrapped.utilization(since: .init(user: UInt32.max - 1, system: 0, idle: 0)), 50)
  }
  func testSelfCPUCounterAgreesWithIndependentProcessClock() {
    func cpuSeconds() -> Double {
      var clock = timespec()
      XCTAssertEqual(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &clock), 0)
      return Double(clock.tv_sec) + Double(clock.tv_nsec) / 1e9
    }
    var before = ts_self_usage()
    var after = ts_self_usage()
    XCTAssertTrue(ts_read_self(&before))
    let start = cpuSeconds()
    while cpuSeconds() - start < 0.05 {}
    let elapsed = cpuSeconds() - start
    XCTAssertTrue(ts_read_self(&after))
    let measured = Double(after.cpu_ns - before.cpu_ns) / 1e9
    XCTAssertGreaterThan(measured / elapsed, 0.8)
    XCTAssertLessThan(measured / elapsed, 1.2)
  }
  func testMachCPUTickConversionUsesTimebaseAndCannotOverflow() {
    XCTAssertEqual(ts_ticks_to_nanoseconds(24_000_000, 125, 3), 1_000_000_000)
    XCTAssertEqual(ts_ticks_to_nanoseconds(1_000_000_000, 1, 1), 1_000_000_000)
    XCTAssertEqual(ts_ticks_to_nanoseconds(UInt64.max, 125, 3), UInt64.max)
    XCTAssertEqual(ts_ticks_to_nanoseconds(1, 0, 1), 0)
    XCTAssertEqual(ts_ticks_to_nanoseconds(1, 1, 0), 0)
  }
  func testMemoryWorkingSetDoesNotUnderflow() {
    let reading = MemoryReading(
      total: 100, active: 20, inactive: 0, wired: 10, compressed: 5, free: 0, speculative: 0,
      purgeable: 50, swapUsed: 0, swapTotal: 0, pressure: 1)
    XCTAssertEqual(reading.used, 15)
    XCTAssertEqual(reading.pressureDescription, "Normal")
    var large = reading
    large.active = 200
    XCTAssertEqual(large.used, 100)
  }
  func testSMCFloatSignedFixedAndFanDecoding() {
    func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
      let code = type.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      var value = 0.0
      return ts_smc_decode(code, bytes, bytes.count, &value) ? value : nil
    }
    XCTAssertEqual(decode("sp78", [0x2a, 0x80]), 42.5)
    XCTAssertEqual(decode("sp78", [0xff, 0x80]), -0.5)
    XCTAssertEqual(decode("fpe2", [0x1f, 0x40]), 2000)
    XCTAssertEqual(decode("flt ", [0, 0, 0x28, 0x42]), 42)
    XCTAssertEqual(decode("ui32", [0, 1, 0, 0]), 65536)
    XCTAssertEqual(decode("ui8 ", [0]), 0)
    XCTAssertNil(decode("flt ", [0, 0, 0x80, 0x7f]))
    XCTAssertNil(decode("sp78", [1]))
    XCTAssertNil(decode("bad ", [1, 2]))
    XCTAssertNil(decode("ui32", []))
  }
  func testSettingsValidateCorruptionAndPreserveReadoutOrder() {
    var settings = Settings()
    settings.interval = -1
    settings.readouts = [.memory, .memory, .overview, .cpu]
    settings.worldClocks = ["UTC", "bad-zone"]
    settings.networkInterface = ""
    settings.validate()
    XCTAssertEqual(settings.interval, 2)
    XCTAssertEqual(settings.readouts, [.memory, .cpu])
    XCTAssertEqual(settings.worldClocks, ["UTC"])
    XCTAssertEqual(settings.networkInterface, "auto")
    settings.readouts = []
    settings.validate()
    XCTAssertEqual(settings.readouts, [.cpu])
  }
  func testSettingsRoundTripAndDamagedDataFallback() {
    let suite = "TinyStatsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = Settings()
    settings.interval = 10
    settings.fahrenheit = true
    settings.save(to: defaults)
    XCTAssertEqual(Settings.load(from: defaults), settings)
    defaults.set(Data([1, 2, 3]), forKey: "settings")
    XCTAssertEqual(Settings.load(from: defaults), Settings())
  }
  func testAlertsRequireSustainedConditionAndCooldown() {
    var gate = AlertGate()
    XCTAssertFalse(gate.evaluate(active: true, now: 0, hold: 30))
    XCTAssertFalse(gate.evaluate(active: false, now: 29, hold: 30))
    XCTAssertFalse(gate.evaluate(active: true, now: 30, hold: 30))
    XCTAssertTrue(gate.evaluate(active: true, now: 60, hold: 30))
    XCTAssertFalse(gate.evaluate(active: true, now: 61, hold: 30))
    XCTAssertTrue(gate.evaluate(active: true, now: 960, hold: 30))
  }
  func testUnavailableCountersAreNotFormattedAsZero() {
    XCTAssertEqual(Display.percent(nil), "—")
    XCTAssertEqual(Display.rate(nil), "—")
    XCTAssertEqual(Display.percent(0), "0%")
    XCTAssertEqual(Display.rate(0), "0 B/s")
    XCTAssertEqual(Display.bytes(1024), "1.0 KiB")
  }
  func testSnapshotWithoutDriversDoesNotInventActivity() {
    let snapshot = Snapshot()
    XCTAssertNil(snapshot.diskRead)
    XCTAssertNil(snapshot.diskWrite)
    XCTAssertNil(snapshot.cpuTemperature)
  }
}

extension CoreTests {
  func testLegacySettingsKeepPreferencesWhenStylesAreAdded() throws {
    let data = Data(
      #"{"interval":5,"fahrenheit":true,"readouts":["cpu","memory"],"styles":{"cpu":"pie","memory":"future-style"}}"#
        .utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: data)
    XCTAssertEqual(settings.interval, 5)
    XCTAssertTrue(settings.fahrenheit)
    XCTAssertEqual(settings.style(for: .cpu), .pie)
    XCTAssertEqual(settings.style(for: .memory), .stacked)
    XCTAssertEqual(settings.worldClocks, Settings().worldClocks)
  }
  func testMenuStylesRespectMetricCapabilities() {
    var settings = Settings()
    settings.styles = ["clock": .pie, "memory": .cores, "cpu": .cores]
    XCTAssertEqual(settings.style(for: .clock), .stacked)
    XCTAssertEqual(settings.style(for: .memory), .stacked)
    XCTAssertEqual(settings.style(for: .cpu), .cores)
    XCTAssertEqual(MenuBarStyle.available(for: .clock), [.text, .stacked, .value, .label, .icon])
  }
}

extension CoreTests {
  func testBatteryCurrentSupportsSignedUnsignedEncodings() {
    XCTAssertEqual(BatteryCurrent.milliamps(raw: UInt64(bitPattern: -1500)), -1500)
    XCTAssertEqual(BatteryCurrent.milliamps(raw: UInt64(UInt32(bitPattern: -1500))), -1500)
    XCTAssertEqual(BatteryCurrent.milliamps(raw: 1200), 1200)
    XCTAssertNil(BatteryCurrent.milliamps(raw: 900_000))
  }
  func testAlertHoldResetPreservesCooldown() {
    var gate = AlertGate()
    XCTAssertTrue(gate.evaluate(active: true, now: 0, hold: 0))
    gate.resetHold()
    XCTAssertFalse(gate.evaluate(active: true, now: 30, hold: 0))
    XCTAssertTrue(gate.evaluate(active: true, now: 900, hold: 0))
  }
}

extension CoreTests {
  func testSensorNamesRespectHardwareAndUnknownKeys() {
    XCTAssertTrue(SensorCatalog.name(for: "Tp0P", appleSilicon: true).hasPrefix("CPU"))
    XCTAssertEqual(SensorCatalog.name(for: "Tp0P", appleSilicon: false), "Tp0P")
    XCTAssertEqual(SensorCatalog.name(for: "TCMz", appleSilicon: true), "TCMz")
    XCTAssertTrue(SensorCatalog.name(for: "Tf04", appleSilicon: true).hasPrefix("CPU"))
    XCTAssertTrue(SensorCatalog.name(for: "Tf14", appleSilicon: true).hasPrefix("GPU"))
    var snapshot = Snapshot()
    snapshot.sensors = [
      .init(key: "TCMz", name: "TCMz", kind: .temperature, value: 90),
      .init(key: "Tp01", name: "CPU · Tp01", kind: .temperature, value: 52),
    ]
    XCTAssertEqual(snapshot.cpuTemperature, 52)
  }
}
