import CTinyStats
import Foundation
import Testing

@testable import TinyStatsCore

private let checkpointEpoch = Date(timeIntervalSince1970: 1_700_000_000)
private func checkpointPoint(_ seconds: Double) -> HistoryPoint {
  var point = Snapshot().historyPoint
  point.time = checkpointEpoch.addingTimeInterval(seconds)
  point.sampleInterval = 2
  point.cpu = 80
  point.cpuUser = 60
  point.cpuSystem = 20
  point.gpu = 0
  point.memory = 45
  point.diskUsed = 70
  point.download = 42
  point.upload = nil
  point.temperature = -4
  return point
}
private func checkpointRepairCRC(_ data: Data) -> Data {
  var result = data
  var checksum: UInt32 = .max
  for byte in result.dropLast(4) {
    checksum ^= UInt32(byte)
    for _ in 0..<8 { checksum = (checksum >> 1) ^ (checksum & 1 == 0 ? 0 : 0xEDB8_8320) }
  }
  var little = (checksum ^ .max).littleEndian
  withUnsafeBytes(of: &little) {
    result.replaceSubrange((result.count - 4)..<result.count, with: $0)
  }
  return result
}
private func checkpointMutate<T: FixedWidthInteger>(
  _ data: Data, offset: Int, value: T
) -> Data {
  var result = data
  var little = value.littleEndian
  withUnsafeBytes(of: &little) {
    result.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0)
  }
  return checkpointRepairCRC(result)
}

@Test func historyCheckpointPreservesEveryRangePairedPeaksMissingCountsAndZero() throws {
  var archive = SessionHistory()
  for index in 0..<200 {
    var point = checkpointPoint(Double(index) * 2)
    if index == 1 {
      point.cpu = 90
      point.cpuUser = nil
      point.cpuSystem = nil
    }
    archive.append(point, uptime: Double(index) * 2 + 1)
  }
  let data = archive.checkpoint()
  #expect(Array(data.prefix(16)) == [84, 78, 89, 72, 73, 83, 84, 0, 2, 0, 12, 0, 6, 0, 0, 0])
  let restored = try SessionHistory(checkpoint: data, now: checkpointEpoch + 399)
  for range in HistoryRange.allCases {
    #expect(restored.projection(range).csv == archive.projection(range).csv)
  }
  let bucket = try #require(restored.projection(.hour).buckets.first)
  #expect(bucket[.gpu] == 0 && bucket[.upload] == nil && bucket[.temperature] == -4)
  #expect(bucket[.cpu] == 90 && bucket[.cpuUser] == nil && bucket.validSamples(.cpuUser) > 0)
}

@Test func historyCheckpointHasExactFixedMaximumAndRestoresOnlyRetainedTime() throws {
  var archive = SessionHistory()
  let end = floor(checkpointEpoch.timeIntervalSince1970 / 8064) * 8064 + 0.25
  var times: Set<Double> = [end]
  // Exercise all 301 slots per tier, including a genuinely observed boundary bucket.
  for range in [HistoryRange.tenMinutes, .hour, .sixHours, .day, .week, .fourWeeks] {
    let start = floor(end / range.resolution) * range.resolution
    for offset in 1...300 {
      times.insert(start - Double(offset) * range.resolution + range.resolution - 0.25)
    }
  }
  for (index, time) in times.sorted().enumerated() {
    var point = checkpointPoint(0)
    point.time = Date(timeIntervalSince1970: time)
    archive.append(point, uptime: Double(index + 1))
  }
  #expect(archive.retainedBucketCount == 1806)
  let data = archive.checkpoint()
  #expect(data.count == 758596 && data.count == SessionHistory.maximumScalarCheckpointBytes)
  let restored = try SessionHistory(checkpoint: data, now: Date(timeIntervalSince1970: end))
  for range in HistoryRange.allCases {
    #expect(restored.projection(range).csv == archive.projection(range).csv)
  }
  let expired = try SessionHistory(
    checkpoint: data,
    now: Date(timeIntervalSince1970: end + Double(HistoryRange.fourWeeks.rawValue) + 1))
  #expect(expired.retainedBucketCount == 0)
}

@Test func historyCheckpointRestartPreservesPastAndMarksGapWithoutReusingUptime() throws {
  var archive = SessionHistory()
  archive.append(checkpointPoint(0), uptime: 10000)
  archive.append(checkpointPoint(2), uptime: 10002)
  var restored = try SessionHistory(checkpoint: archive.checkpoint(), now: checkpointEpoch + 3)
  let firstAccepted = restored.append(checkpointPoint(4), uptime: 0.5)
  #expect(firstAccepted)
  let projection = restored.projection(.hour)
  #expect(projection.samples == 3 && projection.gapBuckets == 1 && projection.resets == 0)
  let nextAccepted = restored.append(checkpointPoint(6), uptime: 2.5)
  #expect(nextAccepted)
  #expect(restored.projection(.hour).samples == 4)
  // Normal same-process reboot/reset protection still applies after restoration.
  let resetAccepted = restored.append(checkpointPoint(8), uptime: 0.1)
  #expect(resetAccepted)
  #expect(restored.projection(.hour).samples == 1 && restored.resets == 1)
}

@Test func historyCheckpointDoesNotRelabelFuturePeaksOrKeepEmptyRestartGaps() throws {
  var archive = SessionHistory()
  for seconds in [0.0, 86400, 172800] {
    archive.append(checkpointPoint(seconds), uptime: seconds + 1)
  }
  let now = checkpointEpoch + 100000
  let restored = try SessionHistory(checkpoint: archive.checkpoint(), now: now)
  #expect(restored.projection(.fourWeeks).samples == 2)
  #expect(restored.projection(.fourWeeks).buckets.allSatisfy { $0.last <= now })
  var empty = try SessionHistory(checkpoint: SessionHistory().checkpoint(), now: now)
  empty.append(checkpointPoint(100000), uptime: 1)
  #expect(empty.projection(.hour).gapBuckets == 0)
}

@Test func historyCheckpointRejectsTruncationOversizeChecksumAndTrailingData() throws {
  var archive = SessionHistory()
  archive.append(checkpointPoint(0), uptime: 1)
  let data = archive.checkpoint()
  for length in [0, 1, 23, 75, data.count - 1] {
    #expect(throws: HistoryCheckpointError.self) {
      try SessionHistory(checkpoint: Data(data.prefix(length)), now: checkpointEpoch)
    }
  }
  var corrupt = data
  corrupt[70] ^= 1
  var trailing = data
  trailing.insert(0, at: trailing.count - 4)
  for invalid in [
    corrupt, checkpointRepairCRC(trailing),
    Data(repeating: 0, count: SessionHistory.maximumCheckpointBytes + 1),
  ] {
    #expect(throws: HistoryCheckpointError.self) {
      try SessionHistory(checkpoint: invalid, now: checkpointEpoch)
    }
  }
  #expect(throws: HistoryCheckpointError.unsupportedVersion) {
    try SessionHistory(
      checkpoint: checkpointMutate(data, offset: 8, value: UInt16(4)), now: checkpointEpoch)
  }
}

@Test func historyCheckpointValidChecksumDoesNotBypassStructuralAndNumericValidation() throws {
  var archive = SessionHistory()
  archive.append(checkpointPoint(0), uptime: 1)
  let data = archive.checkpoint()
  let invalid = [
    checkpointMutate(data, offset: 10, value: UInt16(13)),  // Wrong metric schema.
    checkpointMutate(data, offset: 12, value: UInt16(7)),  // Wrong level count.
    checkpointMutate(data, offset: 14, value: UInt16(1)),  // Nonzero reserved header.
    checkpointMutate(data, offset: 24, value: UInt32(3600)),  // Reordered tier.
    checkpointMutate(data, offset: 28, value: UInt16(302)),  // Allocation bound.
    checkpointMutate(data, offset: 32, value: Double.nan.bitPattern),
    checkpointMutate(
      data, offset: 40, value: (checkpointEpoch.timeIntervalSinceReferenceDate - 1).bitPattern),
    checkpointMutate(data, offset: 48, value: Double(0).bitPattern),
    checkpointMutate(data, offset: 56, value: UInt32(0)),  // Empty bucket.
    checkpointMutate(data, offset: 60, value: UInt32(2)),  // Unknown gap flags.
    checkpointMutate(data, offset: 64, value: UInt16(0xFFFF)),
    checkpointMutate(data, offset: 66, value: UInt16(1)),
    checkpointMutate(data, offset: 68, value: Double.infinity.bitPattern),
    checkpointMutate(data, offset: 68, value: Double(101).bitPattern),
    checkpointMutate(data, offset: 76, value: UInt32(2)),  // More valid values than observations.
    checkpointMutate(data, offset: 80, value: Double(50).bitPattern),  // Wrong paired CPU sum.
  ]
  for bytes in invalid {
    #expect(throws: HistoryCheckpointError.self) {
      try SessionHistory(checkpoint: bytes, now: checkpointEpoch)
    }
  }
}

@Test func historyCheckpointKeepsExactReferenceDatesAndContinuesInEveryActiveSlot() throws {
  var archive = SessionHistory()
  for index in 0..<200 {
    var point = checkpointPoint(0)
    point.time = Date(timeIntervalSinceReferenceDate: 0.123456789 + Double(index) * 1.23456789)
    archive.append(point, uptime: Double(index + 1))
  }
  let now = Date(timeIntervalSinceReferenceDate: 250)
  let data = archive.checkpoint()
  var restored = try SessionHistory(checkpoint: data, now: now)
  #expect(restored.checkpoint() == data)
  var next = checkpointPoint(0)
  next.time = Date(timeIntervalSinceReferenceDate: 251.123456789)
  restored.append(next, uptime: 1)
  // Every newest bucket was restored as active, not duplicated in the same slot.
  let again = try SessionHistory(checkpoint: restored.checkpoint(), now: next.time)
  for range in HistoryRange.allCases {
    #expect(again.projection(range).csv == restored.projection(range).csv)
    let bucket = try #require(again.projection(range).buckets.last)
    #expect(bucket.hasGap)
  }
}

@Test func historyCheckpointPersistentClockResetKeepsOlderObservationsAndDropsFutureBuckets() throws
{
  var archive = SessionHistory()
  for seconds in [0.0, 86400, 172800] {
    archive.append(checkpointPoint(seconds), uptime: seconds + 1)
  }
  let point = checkpointPoint(100000)
  archive.append(point, uptime: 172802, preservingPastOnReset: true)
  let projection = archive.projection(.fourWeeks)
  #expect(projection.samples == 3 && projection.resets == 1 && projection.gapBuckets > 0)
  #expect(projection.buckets.allSatisfy { $0.last <= point.time })
  let restored = try SessionHistory(checkpoint: archive.checkpoint(), now: point.time)
  #expect(restored.projection(.fourWeeks).csv == projection.csv)
}

@Test func historyCheckpointDeterministicMixedReadingsRemainCanonicalThroughRepeatedRestoration()
  throws
{
  var archive = SessionHistory()
  var random: UInt64 = 0xACA5_713F
  for index in 0..<1500 {
    random = random &* 6_364_136_223_846_793_005 &+ 1
    var point = checkpointPoint(0)
    point.time = Date(timeIntervalSinceReferenceDate: 0.123456789 + Double(index) * 0.25)
    point.sampleInterval = index % 3 == 0 ? 5 : 1
    point.cpu = index % 17 == 0 ? nil : Double(random % 101)
    point.cpuUser = point.cpu.map { $0 * 0.7 }
    point.cpuSystem = point.cpu.flatMap { cpu in point.cpuUser.map { cpu - $0 } }
    if index % 7 == 0 { point.cpuUser = nil }
    if index % 13 == 0 { point.cpuSystem = nil }
    point.download = index % 11 == 0 ? .nan : Double(random % 1_000_000)
    point.upload = index % 19 == 0 ? -1 : nil
    point.gpu = index % 23 == 0 ? .infinity : Double(random % 101)
    archive.append(point, uptime: Double(index + 1))
    if index % 64 == 0 {
      let data = archive.checkpoint()
      let restored = try SessionHistory(checkpoint: data, now: point.time)
      #expect(restored.checkpoint() == data)
      for range in HistoryRange.allCases {
        #expect(restored.projection(range).csv == archive.projection(range).csv)
      }
    }
  }
}

@Test func historyCheckpointDocumentsFullRetentionCodecAndFileCostWhenExplicitlyRequested() throws {
  guard ProcessInfo.processInfo.environment["TINYSTATS_PERSISTENCE_BENCHMARK"] == "1" else {
    return
  }
  var before = ts_self_usage()
  let beforeRead = ts_read_self(&before)
  try #require(beforeRead && before.rss > 0 && before.footprint > 0)
  let end = Date()
  var archive = SessionHistory()
  var point = checkpointPoint(0)
  let started = ContinuousClock.now
  for index in 0..<1_300_000 {
    point.time = end - Double(1_299_999 - index) * 2
    point.cpu = Double(index % 101)
    point.cpuUser = point.cpu.map { $0 * 0.7 }
    point.cpuSystem = point.cpu.map { $0 * 0.3 }
    point.download = Double(index % 1_000_000)
    archive.append(point, uptime: Double(index * 2 + 1))
  }
  let appendTime = started.duration(to: .now)
  #expect((1800...1806).contains(archive.retainedBucketCount))
  var populated = ts_self_usage()
  let populatedRead = ts_read_self(&populated)
  try #require(populatedRead && populated.rss > 0)
  let encodeStarted = ContinuousClock.now
  var data = Data()
  for _ in 0..<20 { data = archive.checkpoint() }
  let encodeTime = encodeStarted.duration(to: .now)
  let decodeStarted = ContinuousClock.now
  var restored = SessionHistory()
  for _ in 0..<20 { restored = try SessionHistory(checkpoint: data, now: end) }
  let decodeTime = decodeStarted.duration(to: .now)
  var codec = ts_self_usage()
  let codecRead = ts_read_self(&codec)
  try #require(codecRead && codec.rss > 0)
  for range in HistoryRange.allCases {
    #expect(restored.projection(range).csv == archive.projection(range).csv)
  }
  let root = try checkpointFixtureRoot()
  let keepFixture = ProcessInfo.processInfo.environment["TINYSTATS_PERSISTENCE_FIXTURE"] == "1"
  defer { if !keepFixture { try? FileManager.default.removeItem(at: root) } }
  let store = try #require(
    try LocalHistoryCheckpointStore(directory: root.appendingPathComponent("history"), create: true)
  )
  let writeStarted = ContinuousClock.now
  try store.write(data)
  let writeTime = writeStarted.duration(to: .now)
  let readStarted = ContinuousClock.now
  let read = try store.read()
  let readTime = readStarted.duration(to: .now)
  #expect(read == data && data.count == 76 + archive.retainedBucketCount * 420)
  if keepFixture {
    print("PERSISTENCE_FIXTURE " + root.appendingPathComponent("history/history-v1.bin").path)
  }
  var after = ts_self_usage()
  let afterRead = ts_read_self(&after)
  try #require(afterRead && after.rss > 0 && after.footprint > 0)
  print(
    "PERSISTENCE_COST synthetic_samples=1300000 interval=2 retained=\(archive.retainedBucketCount) encoded_bytes=\(data.count) append=\(appendTime) encode20=\(encodeTime) decode20=\(decodeTime) write_fsync=\(writeTime) read=\(readTime) rss_before=\(before.rss) rss_after=\(after.rss) footprint_before=\(before.footprint) footprint_after=\(after.footprint) populated_rss=\(populated.rss) populated_footprint=\(populated.footprint) codec_before_csv_rss=\(codec.rss) codec_before_csv_footprint=\(codec.footprint)"
  )
}

@Test func historyCheckpointMergePreservesDisjointPeaksAndAvoidsDuplicateReenable() throws {
  var saved = SessionHistory()
  var first = checkpointPoint(0)
  first.cpu = 95
  first.cpuUser = nil
  first.cpuSystem = nil
  saved.append(first, uptime: 1)
  var current = SessionHistory()
  current.append(checkpointPoint(10), uptime: 50)
  let imported = current.mergeOlder(saved, now: checkpointEpoch + 10)
  #expect(imported)
  for range in HistoryRange.allCases {
    #expect(current.projection(range).samples == 2)
  }
  let joined = try #require(current.projection(.fourWeeks).buckets.first)
  #expect(joined[.cpu] == 95 && joined[.cpuUser] == nil && joined[.cpuSystem] == nil)
  #expect(joined.validSamples(.cpuUser) == 1 && joined.hasGap)
  let roundtrip = try SessionHistory(checkpoint: current.checkpoint(), now: checkpointEpoch + 10)
  let duplicated = current.mergeOlder(roundtrip, now: checkpointEpoch + 10)
  #expect(!duplicated)
  for range in HistoryRange.allCases {
    #expect(current.projection(range).csv == roundtrip.projection(range).csv)
  }
  current.append(checkpointPoint(12), uptime: 52)
  #expect(current.projection(.hour).samples == 3 && current.resets == 0)
}

@Test func historyCheckpointFirstSampleAfterRestorationHandlesBackwardClockAndRoundTrips() throws {
  var history = SessionHistory()
  for seconds in [0.0, 20, 40] { history.append(checkpointPoint(seconds), uptime: seconds + 1) }
  var restored = try SessionHistory(checkpoint: history.checkpoint(), now: checkpointEpoch + 40)
  restored.append(checkpointPoint(30), uptime: 1)
  #expect(restored.resets == 1)
  #expect(restored.projection(.tenMinutes).buckets.allSatisfy { $0.last <= checkpointEpoch + 30 })
  let decoded = try SessionHistory(checkpoint: restored.checkpoint(), now: checkpointEpoch + 30)
  for range in HistoryRange.allCases {
    #expect(decoded.projection(range).csv == restored.projection(range).csv)
  }
}

@Test func historyCheckpointMergePartialOverlapKeepsMemoryCountsAndPairedCPUPeaks() throws {
  // Align all six tiers so both histories have genuinely overlapping aggregate bounds,
  // rather than separate fine-resolution buckets that can safely be imported.
  let start = Date(
    timeIntervalSince1970: floor(checkpointEpoch.timeIntervalSince1970 / 8064) * 8064)
  var saved = SessionHistory()
  for offset in [0.1, 0.8] {
    var point = checkpointPoint(0)
    point.time = start + offset
    point.cpu = 99
    point.cpuUser = nil
    point.cpuSystem = nil
    saved.append(point, uptime: offset + 1)
  }
  var memory = SessionHistory()
  for (offset, cpu, user, system) in [(0.5, 30.0, 20.0, 10.0), (1.0, 80.0, 50.0, 30.0)] {
    var point = checkpointPoint(0)
    point.time = start + offset
    point.cpu = cpu
    point.cpuUser = user
    point.cpuSystem = system
    memory.append(point, uptime: offset + 100)
  }
  let before = HistoryRange.allCases.map { memory.projection($0).csv }
  let imported = memory.mergeOlder(saved, now: start + 1)
  #expect(!imported)
  for (index, range) in HistoryRange.allCases.enumerated() {
    let projection = memory.projection(range)
    #expect(projection.csv == before[index] && projection.samples == 2)
    let bucket = try #require(projection.buckets.first)
    #expect(bucket[.cpu] == 80 && bucket[.cpuUser] == 50 && bucket[.cpuSystem] == 30)
    #expect(bucket.validSamples(.cpu) == 2 && bucket.validSamples(.cpuUser) == 2)
  }
  let repeated = memory.mergeOlder(saved, now: start + 1)
  #expect(!repeated)
  let restored = try SessionHistory(checkpoint: memory.checkpoint(), now: start + 1)
  for (index, range) in HistoryRange.allCases.enumerated() {
    #expect(restored.projection(range).csv == before[index])
  }
}

@Test func historyCheckpointForwardGapReleasesExpiredBucketsBeforeWriting() throws {
  var archive = SessionHistory()
  for seconds in [0.0, 2, 4] { archive.append(checkpointPoint(seconds), uptime: seconds + 1) }
  var latest = checkpointPoint(4_000_000)
  latest.cpu = 5
  latest.cpuUser = 3
  latest.cpuSystem = 2
  archive.append(latest, uptime: 4_000_001)
  #expect(archive.retainedBucketCount == 6)
  let data = archive.checkpoint()
  #expect(data.count == 76 + 6 * 420)
  let restored = try SessionHistory(checkpoint: data, now: latest.time)
  #expect(restored.checkpoint() == data)
  for range in HistoryRange.allCases {
    let projection = archive.projection(range)
    #expect(projection.samples == 1 && projection.gapBuckets == 1)
    #expect(projection.buckets.first?[.cpu] == 5)
  }
}

@Test func historyCheckpointExpiryKeepsPartiallyObservedBoundaryBucket() throws {
  let start = floor(checkpointEpoch.timeIntervalSince1970 / 8064) * 8064
  var archive = SessionHistory()
  for (index, offset) in [0.25, 1.5, 600.5].enumerated() {
    var point = checkpointPoint(0)
    point.time = Date(timeIntervalSince1970: start + offset)
    archive.append(point, uptime: Double(index + 1))
  }
  let projection = archive.projection(.tenMinutes)
  let first = try #require(projection.buckets.first)
  #expect(projection.samples == 3 && projection.buckets.count == 2)
  #expect(first.first == Date(timeIntervalSince1970: start + 0.25))
  #expect(first.last == Date(timeIntervalSince1970: start + 1.5))
  let data = archive.checkpoint()
  let restored = try SessionHistory(
    checkpoint: data, now: Date(timeIntervalSince1970: start + 600.5))
  #expect(restored.checkpoint() == data)
}

@Test func historyCheckpointForwardClockJumpExpiryIsNotUndoneByClockCorrection() throws {
  var archive = SessionHistory()
  archive.append(checkpointPoint(0), uptime: 1)
  archive.append(checkpointPoint(2), uptime: 3)
  archive.append(checkpointPoint(4_000_000), uptime: 5, preservingPastOnReset: true)
  var corrected = checkpointPoint(4)
  corrected.cpu = 5
  corrected.cpuUser = 3
  corrected.cpuSystem = 2
  archive.append(corrected, uptime: 7, preservingPastOnReset: true)
  #expect(archive.retainedBucketCount == 6 && archive.resets == 1)
  for range in HistoryRange.allCases {
    let projection = archive.projection(range)
    #expect(projection.samples == 1 && projection.buckets.first?[.cpu] == 5)
  }
  let data = archive.checkpoint()
  let restored = try SessionHistory(checkpoint: data, now: corrected.time)
  #expect(restored.checkpoint() == data)
}
