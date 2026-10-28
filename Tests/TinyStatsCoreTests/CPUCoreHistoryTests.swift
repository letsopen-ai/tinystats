import Foundation
import Testing
import TinyStatsTestSupport

@testable import TinyStatsCore

private let coreEpoch = Date(timeIntervalSince1970: 1_699_999_992)
private func corePoint(
  _ seconds: Double, _ values: [Double?], kinds: [CPUCoreKind] = [.efficiency, .performance]
) -> HistoryPoint {
  var point = Snapshot().historyPoint
  point.time = coreEpoch + seconds
  point.sampleInterval = 1
  point.cpuCores = CPUCoreHistorySample(
    .init(usage: nil, cores: values, load: [], coreKinds: kinds))
  return point
}

@Test func cpuCoreHistoryRejectsInvalidValuesAndBoundsLogicalCounters() throws {
  let point = corePoint(0, [0, nil, .nan, .infinity, -1, 101, 100], kinds: [])
  let cores = try #require(point.cpuCores)
  #expect(cores.count == 7 && cores.kinds == Array(repeating: .unknown, count: 7))
  #expect(cores[0] == 0 && cores[6] == 100 && cores[-1] == nil && cores[7] == nil)
  #expect((1...5).allSatisfy { cores[$0] == nil })
  #expect(corePoint(0, []).cpuCores == nil)
  #expect(corePoint(0, Array(repeating: 3, count: 257)).cpuCores == nil)
  #expect(corePoint(0, Array(repeating: 3, count: 256)).cpuCores?.count == 256)
  #expect(MemoryLayout<CPUCoreStatistics>.stride == 16)
}

@Test func cpuCoreHistoryHasIndependentPeaksValidWeightedMeansAndMissingCounts() throws {
  var archive = SessionHistory()
  for (time, values) in [(0.0, [10.0, 100.0]), (1, [30, 0]), (3, [80, .nan])] {
    archive.append(corePoint(time, values), uptime: time + 1)
  }
  let projection = archive.projection(.tenMinutes)
  let first = try #require(projection.buckets.first?.cpuCores)
  #expect(first.value(0, statistic: .peak) == 30 && first.value(1, statistic: .peak) == 100)
  #expect(first.value(0, statistic: .minimum) == 10 && first.value(1, statistic: .minimum) == 0)
  #expect(first.value(0, statistic: .average) == 20 && first.value(1, statistic: .average) == 50)
  #expect(projection.cpuCoreValidSamples(0, kinds: [.efficiency, .performance]) == 3)
  #expect(projection.cpuCoreValidSamples(1, kinds: [.efficiency, .performance]) == 2)
  #expect(
    abs(
      try #require(
        projection.cpuCoreValue(0, kinds: [.efficiency, .performance], statistic: .average)) - 40)
      < 0.0001)
  #expect(
    projection.cpuCoreValue(1, kinds: [.efficiency, .performance], statistic: .average) == 50)
}

@Test func cpuCoreHistoryDoesNotInventLegacyReadingsAndPersistsEveryRange() throws {
  var archive = try SessionHistory(
    checkpoint: HistoryFixtures.populatedCheckpoint(version: 2, now: coreEpoch), now: coreEpoch)
  #expect(archive.projection(.hour).latestCPUCoreKinds == nil)
  archive.append(corePoint(1, [0, 99.25]), uptime: 1)
  archive.append(corePoint(2, [5, nil]), uptime: 2)
  let data = archive.checkpoint()
  #expect(data[8] == 3 && data.count < SessionHistory.maximumCheckpointBytes)
  let restored = try SessionHistory(checkpoint: data, now: coreEpoch + 3)
  for range in HistoryRange.allCases {
    #expect(restored.projection(range).csv == archive.projection(range).csv)
    #expect(restored.projection(range).latestCPUCoreKinds == [.efficiency, .performance])
  }
  #expect(restored.projection(.hour).buckets.contains { $0.cpuCores == nil })
  #expect(
    restored.projection(.hour).cpuCoreValidSamples(0, kinds: [.efficiency, .performance]) == 2)
  let rows = restored.projection(.hour).csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
  #expect(
    rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 76 })
  #expect(rows[0].contains("cpu_logical_core_2_sample_average_percent"))
}

@Test func cpuCoreHistoryQuarantinesMixedLayoutsAndKeepsNewBucketAndScalars() throws {
  var archive = SessionHistory()
  var first = corePoint(0, [10, 20])
  first.cpu = 40
  archive.append(first, uptime: 1)
  archive.append(corePoint(1, [90, 80], kinds: [.performance, .efficiency]), uptime: 2)
  archive.append(corePoint(1.5, [80, 70]), uptime: 2.5)
  let mixed = try #require(archive.projection(.tenMinutes).buckets.first)
  #expect(mixed.cpuCores == nil && mixed.coreLayoutChanged && mixed[.cpu] == 40)
  #expect(archive.projection(.tenMinutes).csv.contains("cpu_core_layout_changed"))
  archive.append(corePoint(3, [4, 5, 6], kinds: [.unknown, .unknown, .unknown]), uptime: 4)
  let restored = try SessionHistory(checkpoint: archive.checkpoint(), now: coreEpoch + 4)
  #expect(restored.projection(.tenMinutes).buckets.first?.coreLayoutChanged == true)
  #expect(restored.projection(.tenMinutes).latestCPUCoreKinds == [.unknown, .unknown, .unknown])
  #expect(
    restored.projection(.tenMinutes).cpuCoreValidSamples(0, kinds: [.efficiency, .performance]) == 0
  )
}

@Test func cpuCoreHistoryMergePreservesDisjointValidWeightsAndQuarantinesConflicts() throws {
  var older = SessionHistory()
  older.append(corePoint(0, [10, nil]), uptime: 1)
  older.append(corePoint(1, [20, 60]), uptime: 2)
  var memory = SessionHistory()
  memory.append(corePoint(3, [90, 0]), uptime: 1)
  let imported = memory.mergeOlder(older, now: coreEpoch + 4)
  #expect(imported)
  let projection = memory.projection(.hour)
  #expect(projection.buckets.count == 1 && projection.buckets[0].hasGap)
  #expect(
    projection.cpuCoreValue(0, kinds: [.efficiency, .performance], statistic: .average) == 40)
  #expect(
    projection.cpuCoreValue(1, kinds: [.efficiency, .performance], statistic: .average) == 30)
  var incompatible = SessionHistory()
  incompatible.append(corePoint(3, [9], kinds: [.unknown]), uptime: 1)
  let conflicting = incompatible.mergeOlder(older, now: coreEpoch + 4)
  #expect(conflicting)
  #expect(incompatible.projection(.hour).buckets[0].coreLayoutChanged)
}

@Test func cpuCoreHistoryCounterOverflowWithholdsRatherThanInventingValues() {
  var counter = CPUCoreStatistics(peak: 100, minimum: 0, mean: 50, count: .max - 1)
  counter.append(20)
  let bucket = CPUCoreHistoryBucket(kinds: [.unknown], statistics: [counter])
  #expect(bucket.validSamples(0) == 0 && bucket.value(0, statistic: .peak) == nil)
  var merging = CPUCoreStatistics(peak: 20, minimum: 20, mean: 20, count: .max - 2)
  merging.merge(.init(peak: 80, minimum: 80, mean: 80, count: 2))
  #expect(!merging.available && merging.peak == 0 && merging.mean == 0)
}

private func coreCRC(_ input: Data) -> Data {
  var data = input
  var crc: UInt32 = .max
  for byte in data.dropLast(4) {
    crc ^= UInt32(byte)
    for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
  }
  var little = (crc ^ .max).littleEndian
  withUnsafeBytes(of: &little) { data.replaceSubrange((data.count - 4)..<data.count, with: $0) }
  return data
}

@Test func cpuCoreHistoryCheckpointRejectsMalformedRecordsEvenWithValidCRC() throws {
  var archive = SessionHistory()
  archive.append(corePoint(0, [50], kinds: [.efficiency]), uptime: 1)
  let original = archive.checkpoint()
  // Independent layout offsets: 24 header + 8 tier + 420 scalar + 2 core count.
  func changed<T: FixedWidthInteger>(_ offset: Int, _ value: T) -> Data {
    var data = original
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    return coreCRC(data)
  }
  for data in [
    changed(452, UInt16(257)), changed(454, UInt8(3)),
    changed(455, Float.nan.bitPattern), changed(459, Float(60).bitPattern),
    changed(467, UInt32(2)), coreCRC(original.dropLast(5)),
  ] {
    #expect(throws: HistoryCheckpointError.invalidData) {
      try SessionHistory(checkpoint: data, now: coreEpoch + 1)
    }
  }
}

@Test func cpuCoreHistoryMaximumWireBudgetIsExactAndAllocatesOnlyActualCoreCount() throws {
  let now = Date(timeIntervalSince1970: floor(coreEpoch.timeIntervalSince1970 / 8064) * 8064 + 0.25)
  let legacy = HistoryFixtures.populatedCheckpoint(version: 2, now: now, maximum: true)
  func fixture(cores: Int) -> Data {
    var result = Data(legacy.prefix(24))
    result[8] = 3
    var offset = 24
    func integer<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
    }
    for _ in 0..<6 {
      result.append(legacy[offset..<(offset + 8)])
      offset += 8
      for _ in 0..<301 {
        result.append(legacy[offset..<(offset + 420)])
        offset += 420
        integer(UInt16(cores))
        for _ in 0..<cores {
          integer(UInt8(0))
          for _ in 0..<3 { integer(Float(37.5).bitPattern) }
          integer(UInt32(1))
        }
      }
    }
    integer(UInt32(0))
    return coreCRC(result)
  }
  for count in [10, 256] {
    let data = fixture(cores: count)
    #expect(data.count == 758_596 + 1806 * (2 + count * 17))
    if count == 256 { #expect(data.count == SessionHistory.maximumCheckpointBytes) }
    let restored = try SessionHistory(checkpoint: data, now: now)
    #expect(restored.retainedBucketCount == 1806 && restored.checkpoint() == data)
    var streamed = Data()
    var chunks = 0
    restored.writeCheckpoint { bytes in
      #expect(!bytes.isEmpty && bytes.count <= 64 * 1024)
      streamed.append(contentsOf: bytes)
      chunks += 1
    }
    #expect(streamed == data && chunks > 1)
    for range in HistoryRange.allCases {
      #expect(restored.projection(range).latestCPUCoreKinds?.count == count)
      #expect(
        restored.projection(range).cpuCoreValue(
          count - 1, kinds: Array(repeating: .unknown, count: count), statistic: .average) == 37.5)
    }
  }
  #expect(SessionHistory.maximumCheckpointBytes == 8_621_920)
}

@Test func cpuCoreHistoryNewestConflictedLayoutIsNotRelabeledAsAnOlderLayout() throws {
  var history = SessionHistory()
  history.append(corePoint(0, [10, 20]), uptime: 1)
  history.append(corePoint(3, [10, 20]), uptime: 4)
  history.append(corePoint(3.5, [20, 10], kinds: [.performance, .efficiency]), uptime: 4.5)
  let projection = history.projection(.tenMinutes)
  #expect(projection.buckets.last?.coreLayoutChanged == true)
  #expect(projection.latestCPUCoreKinds == [.performance, .efficiency])
  let restored = try SessionHistory(checkpoint: history.checkpoint(), now: coreEpoch + 4)
  #expect(restored.projection(.tenMinutes).latestCPUCoreKinds == [.performance, .efficiency])
  #expect(restored.projection(.tenMinutes).csv == projection.csv)
}

@Test func cpuCoreHistoryRejectsImpossibleTwoSampleMeanAndAcceptsFloatRounding() throws {
  var history = SessionHistory()
  history.append(corePoint(0, [1.234567, 0]), uptime: 1)
  history.append(corePoint(1, [9.876543, 100]), uptime: 2)
  let data = history.checkpoint()
  let restored = try SessionHistory(checkpoint: data, now: coreEpoch + 2)
  #expect(restored.projection(.tenMinutes).csv == history.projection(.tenMinutes).csv)
  var invalid = data
  var little = Float(1).bitPattern.littleEndian
  // The second core follows the first 17-byte record; mean is its offset+9.
  withUnsafeBytes(of: &little) { invalid.replaceSubrange(480..<484, with: $0) }
  #expect(throws: HistoryCheckpointError.invalidData) {
    try SessionHistory(checkpoint: coreCRC(invalid), now: coreEpoch + 2)
  }
}

@Test func cpuCoreHistorySaturatedSentinelRoundTripsAndContinuedAppendStaysUnknown() throws {
  var history = SessionHistory()
  history.append(corePoint(0, [50], kinds: [.unknown]), uptime: 1)
  var data = history.checkpoint()
  func change<T: FixedWidthInteger>(_ offset: Int, _ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
  }
  change(56, UInt32.max)
  for offset in [455, 459, 463] { change(offset, UInt32(0)) }
  change(467, UInt32.max)
  var restored = try SessionHistory(checkpoint: coreCRC(data), now: coreEpoch + 1)
  restored.append(corePoint(1, [75], kinds: [.unknown]), uptime: 1)
  let reread = try SessionHistory(checkpoint: restored.checkpoint(), now: coreEpoch + 2)
  #expect(reread.projection(.tenMinutes).buckets.first?.cpuCores?.validSamples(0) == 0)
  #expect(
    reread.projection(.tenMinutes).buckets.first?.cpuCores?.value(0, statistic: .average) == nil)
}

@Test func cpuCoreHistoryRejectsMalformedQuarantinedLayoutWithValidCRC() throws {
  var history = SessionHistory()
  history.append(corePoint(0, [10, 20]), uptime: 1)
  history.append(corePoint(1, [10, 20], kinds: [.performance, .efficiency]), uptime: 2)
  let original = history.checkpoint()
  func changed<T: FixedWidthInteger>(_ offset: Int, _ value: T) -> Data {
    var data = original
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    return coreCRC(data)
  }
  let truncated = coreCRC(Data(original.prefix(457)) + Data(repeating: 0, count: 4))
  for invalid in [
    changed(454, UInt16(0)), changed(454, UInt16(257)), changed(456, UInt8(3)), truncated,
  ] {
    #expect(throws: HistoryCheckpointError.invalidData) {
      try SessionHistory(checkpoint: invalid, now: coreEpoch + 2)
    }
  }
}
