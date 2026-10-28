import CTinyStats
import Foundation
import XCTest

@testable import TinyStatsCore

final class StorageHealthTests: XCTestCase {
  private func decode(_ data: [UInt8]) -> ts_storage_health {
    var raw = ts_storage_health()
    XCTAssertTrue(ts_decode_nvme_health(data, data.count, &raw))
    return raw
  }
  func testNVMeLogUsesLittleEndianAndFullWidthCounters() {
    var log = [UInt8](repeating: 0, count: 512)
    log[1] = 0x2b
    log[2] = 1  // 299 K
    log[3] = 99
    log[4] = 10
    log[5] = 7
    log[32] = 1
    log[48] = 2
    log[112] = 0x56
    log[113] = 0x34
    log[114] = 0x12
    log[116] = 1
    log[128] = 0x34
    log[129] = 0x12
    let raw = decode(log)
    XCTAssertEqual(raw.temperature_celsius, 25.85, accuracy: 0.001)
    XCTAssertEqual(raw.total_read, 512000)
    XCTAssertEqual(raw.total_written, 1_024_000)
    XCTAssertEqual(raw.power_cycles, 0x1_0012_3456)
    XCTAssertEqual(raw.power_on_hours, 0x1234)
    XCTAssertEqual(raw.endurance_used, 7)
    XCTAssertEqual(raw.overflow_mask, 0)
    XCTAssertTrue(raw.available)
    XCTAssertFalse(raw.warning)
  }
  func testNVMeCounterOverflowSaturatesAndIsExplicit() {
    var log = [UInt8](repeating: 0, count: 512)
    log[40] = 1  // high 64 bits of data units read
    for index in 48..<56 { log[index] = 255 }  // low value overflows scaling to bytes
    log[168] = 1  // high 64 bits of media errors
    let raw = decode(log)
    XCTAssertEqual(raw.total_read, UInt64.max)
    XCTAssertEqual(raw.total_written, UInt64.max)
    XCTAssertEqual(raw.media_errors, UInt64.max)
    XCTAssertEqual(raw.overflow_mask, (1 << 0) | (1 << 1) | (1 << 5))
    let reading = StorageHealthReading(raw: raw)
    XCTAssertTrue(reading.counter(reading.totalRead, bit: 0, bytes: true).hasPrefix("≥"))
    XCTAssertFalse(reading.counter(reading.powerCycles, bit: 2).hasPrefix("≥"))
  }
  func testNVMeUnavailableTemperatureAndWarningsAreNotInvented() {
    var log = [UInt8](repeating: 0, count: 512)
    log[0] = 4
    log[3] = 255
    log[4] = 255
    log[5] = 105
    let reading = StorageHealthReading(raw: decode(log))
    XCTAssertNil(reading.temperature)
    XCTAssertNil(reading.spare)
    XCTAssertEqual(reading.enduranceUsed, 105)
    XCTAssertTrue(reading.warning)
    XCTAssertTrue(reading.status.contains("0x04"))
    var short = ts_storage_health()
    XCTAssertFalse(ts_decode_nvme_health(log, 511, &short))
    XCTAssertFalse(short.available)
    XCTAssertFalse(ts_decode_nvme_health(nil, 512, &short))
  }
  func testUnsupportedAndFailedReadsNeverClaimHealthy() {
    var raw = ts_storage_health()
    XCTAssertTrue(StorageHealthReading(raw: raw).status.contains("not exposed"))
    raw.capable = true
    raw.protocol = 1
    raw.error = -1
    let failed = StorageHealthReading(raw: raw)
    XCTAssertFalse(failed.available)
    XCTAssertTrue(failed.status.contains("unavailable"))
  }
  func testSMARTAlertNeedsActualWarningAndKeepsCooldown() {
    var snapshot = Snapshot()
    var engine = AlertEngine()
    var raw = ts_storage_health()
    raw.capable = true
    raw.warning = true
    snapshot.storageHealth.drives = [StorageHealthReading(raw: raw)]
    XCTAssertTrue(engine.evaluate(snapshot, now: 0).isEmpty)
    raw.available = true
    snapshot.storageHealth.checkedAt = snapshot.timestamp
    snapshot.storageHealth.drives = [StorageHealthReading(raw: raw)]
    XCTAssertEqual(engine.evaluate(snapshot, now: 1).map(\.id), ["smart"])
    engine.resetSustainedConditions()
    XCTAssertTrue(engine.evaluate(snapshot, now: 30).isEmpty)
  }
  func testUnreportedLifetimeCountersAreUnavailable() {
    let reading = StorageHealthReading(raw: decode([UInt8](repeating: 0, count: 512)))
    XCTAssertNil(reading.totalRead)
    XCTAssertNil(reading.totalWritten)
    XCTAssertEqual(reading.counter(reading.totalRead, bit: 0, bytes: true), "Unavailable")
    XCTAssertEqual(reading.counter(reading.mediaErrors, bit: 5), "0")
  }
  func testSMARTNotificationsRequireFreshDistinctObservations() {
    var snapshot = Snapshot()
    let start = Date(timeIntervalSince1970: 1000)
    snapshot.timestamp = start
    snapshot.storageHealth.checkedAt = start
    var raw = ts_storage_health()
    raw.available = true
    raw.warning = true
    snapshot.storageHealth.drives = [StorageHealthReading(raw: raw)]
    var engine = AlertEngine()
    XCTAssertEqual(engine.evaluate(snapshot, now: 0).map(\.id), ["smart"])
    // No new observation after closing disk details with background polling off.
    snapshot.timestamp = start.addingTimeInterval(900)
    XCTAssertTrue(engine.evaluate(snapshot, now: 900).isEmpty)
    // Reopening with an aged cached warning must not notify either.
    var restarted = AlertEngine()
    XCTAssertTrue(restarted.evaluate(snapshot, now: 900).isEmpty)
    snapshot.storageHealth.checkedAt = snapshot.timestamp
    XCTAssertEqual(engine.evaluate(snapshot, now: 901).map(\.id), ["smart"])
    snapshot.timestamp = start.addingTimeInterval(1801)
    XCTAssertTrue(engine.evaluate(snapshot, now: 1801).isEmpty)
  }
  func testHealthFinishingDuringSampleIsEligibleOnNextSnapshot() {
    var snapshot = Snapshot()
    let started = Date(timeIntervalSince1970: 1000)
    snapshot.timestamp = started
    snapshot.storageHealth.checkedAt = started.addingTimeInterval(0.01)
    var raw = ts_storage_health()
    raw.available = true
    raw.warning = true
    snapshot.storageHealth.drives = [StorageHealthReading(raw: raw)]
    var engine = AlertEngine()
    XCTAssertTrue(engine.evaluate(snapshot, now: 0).isEmpty)
    snapshot.timestamp = started.addingTimeInterval(2)
    XCTAssertEqual(engine.evaluate(snapshot, now: 2).map(\.id), ["smart"])
  }
  func testSlowReaderCoalescesAndNeverBlocksCaller() {
    let probe = SlowProbe()
    let reader = StorageHealthReader(read: { probe.read() })
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      reader.requestIfDue(at: 0)
      returned.signal()
    }
    XCTAssertEqual(probe.started.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(reader.cached().refreshing)
    for time in 1...100 { reader.requestIfDue(at: Double(time)) }
    XCTAssertEqual(probe.count, 1)
    probe.release.signal()
    eventually { reader.cached().checkedAt != nil }
    XCTAssertFalse(reader.cached().refreshing)
    XCTAssertEqual(reader.cached().drives.count, 32)
    reader.requestIfDue(at: 299)
    XCTAssertEqual(probe.count, 1)
    reader.requestIfDue(at: 300)
    eventually { probe.count == 2 }
  }
  private func eventually(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}

private final class SlowProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
  func read() -> [StorageHealthReading] {
    lock.lock()
    calls += 1
    let first = calls == 1
    lock.unlock()
    started.signal()
    if first { _ = release.wait(timeout: .now() + 3) }
    return (0..<100).map { _ in StorageHealthReading(raw: ts_storage_health()) }
  }
}
