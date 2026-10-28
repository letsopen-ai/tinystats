import CTinyStats
import Foundation
import Testing

@testable import TinyStatsCore

private func client(_ id: UInt64, _ counter: UInt64?) -> GPUClientTime {
  client(id, 10, counter)
}
private func client(_ id: UInt64, _ pid: Int32, _ counter: UInt64?) -> GPUClientTime {
  .init(id: id, pid: pid, nanoseconds: counter)
}
private func owner(_ pid: Int32) -> GPUProcessIdentity? { .init(started: 7, name: "Owner \(pid)") }

@Test func gpuProcessTimeUsesDriverMillisecondsWithoutUtilizationClamping() throws {
  var collector = GPUProcessTimeCollector()
  let first = collector.sample(
    visible: true, at: 10, read: { .ready([client(1, 1_000_000_000), client(2, 2_000_000_000)]) },
    identity: owner)
  #expect(first.status == .collecting && first.rows.first?.millisecondsPerSecond == nil)
  let second = collector.sample(
    visible: true, at: 12, read: { .ready([client(2, 8_000_000_000), client(1, 5_000_000_000)]) },
    identity: owner)
  #expect(second.status == .ready && second.rows.count == 1)
  #expect(second.message == "Driver-reported Metal GPU time")
  #expect(try #require(second.rows.first?.millisecondsPerSecond) == 5000)
  #expect(GPUProcessTimeSnapshot.formatted(5000) == "5000 ms/s")
  let zero = collector.sample(
    visible: true, at: 14, read: { .ready([client(1, 5_000_000_000), client(2, 8_000_000_000)]) },
    identity: owner)
  #expect(zero.rows.first?.millisecondsPerSecond == 0)
  #expect(zero.message == "No reported Metal GPU time this interval")
  #expect(GPUProcessTimeSnapshot.formatted(nil) == "—")
  #expect(GPUProcessTimeSnapshot.formatted(.nan) == "—")
}

@Test func gpuProcessTimeWithholdsChangedClientSetsWithoutDroppingOtherOwners() throws {
  var collector = GPUProcessTimeCollector()
  func sample(_ time: Double, _ clients: [GPUClientTime]) -> GPUProcessTimeSnapshot {
    collector.sample(visible: true, at: time, read: { .ready(clients) }, identity: owner)
  }
  _ = sample(1, [client(1, 10, 0), client(2, 20, 0)])
  let added = sample(
    2, [client(1, 10, 1_000_000), client(2, 20, 2_000_000), client(3, 10, 900_000_000)])
  #expect(added.rows.first { $0.pid == 10 }?.millisecondsPerSecond == nil)
  #expect(added.rows.first { $0.pid == 20 }?.millisecondsPerSecond == 2)
  let stable = sample(
    3, [client(1, 10, 3_000_000), client(2, 20, 4_000_000), client(3, 10, 904_000_000)])
  #expect(stable.rows.first { $0.pid == 10 }?.millisecondsPerSecond == 6)
  let removed = sample(4, [client(1, 10, 4_000_000), client(2, 20, 6_000_000)])
  #expect(removed.rows.first { $0.pid == 10 }?.millisecondsPerSecond == nil)
  #expect(removed.rows.first { $0.pid == 20 }?.millisecondsPerSecond == 2)
  let unreadable = sample(5, [client(1, 10, nil), client(2, 20, 8_000_000)])
  #expect(unreadable.rows.first { $0.pid == 10 }?.millisecondsPerSecond == nil)
  #expect(unreadable.rows.first { $0.pid == 20 }?.millisecondsPerSecond == 2)
}

@Test func gpuProcessTimeResetsCountersIdentityMissingAndLongIntervals() throws {
  var collector = GPUProcessTimeCollector()
  func sample(_ time: Double, _ value: UInt64?, start: UInt64 = 7, id: UInt64 = 1) -> Double? {
    collector.sample(
      visible: true, at: time, maximumInterval: 15,
      read: { .ready([client(id, value)]) }, identity: { _ in .init(started: start, name: "Owner") }
    ).rows.first?.millisecondsPerSecond
  }
  #expect(sample(1, 5_000_000_000) == nil)
  #expect(sample(2, 0) == nil)
  #expect(sample(4, 2_000_000_000) == 1000)
  #expect(sample(5, 3_000_000_000, start: 8) == nil)
  #expect(sample(6, 4_000_000_000, start: 8) == nil)
  #expect(sample(7, 4_000_000_000, start: 8, id: 2) == nil)
  #expect(sample(8, 5_000_000_000, start: 8, id: 2) == 1000)
  #expect(sample(9, nil, start: 8, id: 2) == nil)
  #expect(sample(10, 6_000_000_000, start: 8, id: 2) == nil)
  #expect(sample(30, 10_000_000_000, start: 8, id: 2) == nil)
  #expect(sample(32, 12_000_000_000, start: 8, id: 2) == 1000)
  #expect(sample(32, 13_000_000_000, start: 8, id: 2) == nil)
  #expect(sample(31, 14_000_000_000, start: 8, id: 2) == nil)
}

@Test func gpuProcessTimeDemandAndFailuresNeverKeepStaleRowsOrUnboundedState() throws {
  var collector = GPUProcessTimeCollector()
  var reads = 0
  var identities = 0
  func read() -> GPUClientScan {
    reads += 1
    return .ready([client(1, 0)])
  }
  func identify(_ pid: Int32) -> GPUProcessIdentity? {
    identities += 1
    return owner(pid)
  }
  _ = collector.sample(visible: true, at: 1, read: read, identity: identify)
  #expect(collector.retainedClientCount == 1)
  let hidden = collector.sample(visible: false, at: 2, read: read, identity: identify)
  #expect(hidden.status == .inactive && hidden.rows.isEmpty)
  #expect(collector.retainedClientCount == 0 && reads == 1 && identities == 1)
  let again = collector.sample(visible: true, at: 3, read: read, identity: identify)
  #expect(again.status == .collecting)
  for failure in [GPUClientScan.incomplete, .tooMany, .unsupported] {
    let result = collector.sample(visible: true, at: 4, read: { failure }, identity: identify)
    #expect(result.rows.isEmpty && collector.retainedClientCount == 1)
  }
  _ = collector.sample(visible: true, at: 5, read: read, identity: identify)
  collector.reset()
  #expect(collector.retainedClientCount == 0)
  let invalidTime = collector.sample(visible: true, at: .infinity, read: read, identity: identify)
  #expect(invalidTime.status == .incomplete && reads == 3)
}

@Test func gpuProcessTimeQuarantinesReusedOwnersAcrossUnreadableIntervals() throws {
  var collector = GPUProcessTimeCollector()
  var start: UInt64 = 7
  func identify(_ pid: Int32) -> GPUProcessIdentity? { .init(started: start, name: "Owner") }
  _ = collector.sample(visible: true, at: 1, read: { .ready([client(1, 0)]) }, identity: identify)
  _ = collector.sample(visible: true, at: 2, read: { .incomplete }, identity: identify)
  start = 8
  let reused = collector.sample(
    visible: true, at: 3, read: { .ready([client(1, 9_000_000_000)]) }, identity: identify)
  #expect(reused.rows.first?.millisecondsPerSecond == nil)
  let stillReused = collector.sample(
    visible: true, at: 4, read: { .ready([client(1, 10_000_000_000)]) }, identity: identify)
  #expect(stillReused.rows.first?.millisecondsPerSecond == nil)
  _ = collector.sample(
    visible: true, at: 5, read: { .ready([client(1, nil)]) }, identity: { _ in nil })
  let recovered = collector.sample(
    visible: true, at: 6, read: { .ready([client(1, 12_000_000_000)]) }, identity: identify)
  #expect(recovered.rows.first?.millisecondsPerSecond == nil)
  _ = collector.sample(visible: true, at: 7, read: { .ready([client(2, 0)]) }, identity: identify)
  let newClient = collector.sample(
    visible: true, at: 8, read: { .ready([client(2, 2_000_000_000)]) }, identity: identify)
  #expect(newClient.rows.first?.millisecondsPerSecond == 2000)
}

@Test func gpuProcessTimeKeepsProvenanceWhilePresentClientsReportNoMetal() throws {
  var collector = GPUProcessTimeCollector()
  var start: UInt64 = 7
  func sample(_ time: Double, _ rows: [GPUClientTime]) -> GPUProcessTimeSnapshot {
    collector.sample(
      visible: true, at: time, read: { .ready(rows) },
      identity: { _ in .init(started: start, name: "Owner") })
  }
  let nonMetal = GPUClientTime(id: 1, pid: 10, nanoseconds: nil, reportsMetal: false)
  #expect(sample(1, [nonMetal]).status == .noClients)
  #expect(collector.retainedClientCount == 1)
  #expect(sample(2, [client(1, 1_000_000_000)]).rows.first?.millisecondsPerSecond == nil)
  #expect(sample(3, [client(1, 2_000_000_000)]).rows.first?.millisecondsPerSecond == 1000)
  start = 8
  #expect(sample(4, [nonMetal]).rows.isEmpty)
  #expect(collector.retainedClientCount == 1)
  #expect(sample(5, [client(1, 3_000_000_000)]).rows.first?.millisecondsPerSecond == nil)
  #expect(sample(6, [client(1, 4_000_000_000)]).rows.first?.millisecondsPerSecond == nil)
  _ = sample(7, [nonMetal])
  #expect(sample(8, [client(1, 5_000_000_000)]).rows.first?.millisecondsPerSecond == nil)
  _ = sample(9, [nonMetal, client(2, 0)])
  #expect(
    sample(10, [nonMetal, client(2, 1_000_000_000)]).rows.first?.millisecondsPerSecond == 1000)
  #expect(
    sample(11, [nonMetal, client(2, 2_000_000_000)]).rows.first?.millisecondsPerSecond == 1000)
  #expect(!GPUClientSchema.reportsMetal([] as [Any]))
  #expect(!GPUClientSchema.reportsMetal([["API": "OpenGL"]]))
  #expect(GPUClientSchema.reportsMetal([["API": "Metal"]]))
  #expect(GPUClientSchema.reportsMetal([["unknown": "value"]]))
  #expect(GPUClientSchema.reportsMetal(nil))
}

@Test func gpuProcessTimeBoundsDuplicatesAbsentOwnersAndEmptySourcesStayDistinct() throws {
  var collector = GPUProcessTimeCollector()
  func sample(_ rows: [GPUClientTime], identity: (Int32) -> GPUProcessIdentity? = owner)
    -> GPUProcessTimeSnapshot
  {
    collector.sample(visible: true, at: 1, read: { .ready(rows) }, identity: identity)
  }
  #expect(sample([]).status == .noClients)
  #expect(sample([client(1, 0), client(1, 0)]).status == .incomplete)
  #expect(sample([client(1, 0, 0)]).status == .incomplete)
  let missing = sample([client(1, 0)], identity: { _ in nil })
  #expect(missing.rows.isEmpty && missing.status == .incomplete)
  #expect(sample((1...513).map { client(UInt64($0), 0) }).status == .tooMany)
  #expect(sample((1...65).map { client(UInt64($0), Int32($0), 0) }).status == .tooMany)
  #expect(collector.retainedClientCount == 0)
  let bounded = (1...512).map { client(UInt64($0), 0) }
  _ = sample(bounded)
  #expect(collector.retainedClientCount == 512)
  _ = collector.sample(visible: false, at: 2, read: { .ready(bounded) }, identity: owner)
  #expect(collector.retainedClientCount == 0)
}

@Test func gpuProcessTimeRetainsBoundedBaselinesAndRanksOnlyTwelveRows() throws {
  var collector = GPUProcessTimeCollector()
  let first = (1...64).map { client(UInt64($0), Int32($0), 0) }
  _ = collector.sample(visible: true, at: 1, read: { .ready(first) }, identity: owner)
  let second = (1...64).map { client(UInt64($0), Int32($0), UInt64($0) * 1_000_000) }
  let snapshot = collector.sample(visible: true, at: 2, read: { .ready(second) }, identity: owner)
  #expect(snapshot.rows.count == 12 && collector.retainedClientCount == 64)
  #expect(snapshot.rows.map(\.pid) == Array((53...64).reversed()).map(Int32.init))
}

@Test func gpuClientSchemaKeepsIdentityAndIntegerCounterContracts() throws {
  for valid in ["pid 12", "pid 12, x", "pid 012, x"] { #expect(GPUClientSchema.pid(valid) == 12) }
  for invalid in [
    "", "pid12", "pid -1", "pid 0", "pid 12 x", "pid 99999999999", "pid １２", "pid 12 ",
  ] {
    #expect(GPUClientSchema.pid(invalid) == nil)
  }
  func usage(_ number: Any) -> Any { [["API": "Metal", "accumulatedGPUTime": number]] }
  #expect(GPUClientSchema.metalNanoseconds(usage(NSNumber(value: 0))) == 0)
  #expect(GPUClientSchema.metalNanoseconds(usage(NSNumber(value: UInt64.max))) == UInt64.max)
  for invalid: Any in [
    NSNumber(value: true), NSNumber(value: -1), NSNumber(value: 1.5), "1", NSNull(),
  ] {
    #expect(GPUClientSchema.metalNanoseconds(usage(invalid)) == nil)
  }
  #expect(GPUClientSchema.metalNanoseconds([["API": "OpenGL", "accumulatedGPUTime": 1]]) == nil)
  #expect(
    GPUClientSchema.metalNanoseconds([
      ["API": "Metal", "accumulatedGPUTime": 1], ["API": "Metal", "accumulatedGPUTime": 2],
    ]) == nil)
  #expect(GPUClientSchema.metalNanoseconds(["API": "Metal"]) == nil)
  #expect(GPUClientSchema.metalNanoseconds([NSNull()]) == nil)
}

@Test func gpuTargetedIdentityReadsOnlyTheRequestedLiveProcess() throws {
  var raw = ts_process()
  #expect(!ts_read_process_identity(0, &raw))
  #expect(!ts_read_process_identity(-1, &raw))
  #expect(ts_read_process_identity(getpid(), &raw))
  #expect(raw.pid == getpid() && raw.started > 0)
}
