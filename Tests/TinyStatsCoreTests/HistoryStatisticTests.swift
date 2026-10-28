import Foundation
import Testing
import TinyStatsTestSupport

@testable import TinyStatsCore

private let statisticsEpoch = Date(timeIntervalSince1970: 1_699_999_992)
private func statisticsPoint(_ seconds: Double, cpu: Double? = nil) -> HistoryPoint {
  var p = Snapshot().historyPoint
  p.time = statisticsEpoch + seconds
  p.sampleInterval = 1
  p.cpu = cpu
  return p
}
@Test func historyStatisticsKeepValidZeroMissingNegativeAndWeightedMeans() throws {
  var h = SessionHistory()
  for (i, cpu) in [0.0, 100, 20].enumerated() {
    var p = statisticsPoint(i == 2 ? 12 : Double(i), cpu: cpu)
    p.temperature = i == 0 ? -4 : i == 1 ? -8 : nil
    p.gpu = i == 0 ? 0 : i == 1 ? nil : .infinity
    h.append(p, uptime: Double(i + 1))
  }
  let p = h.projection(.hour)
  #expect(p.buckets.count == 2 && p.value(.cpu, statistic: .peak) == 100)
  #expect(p.value(.cpu, statistic: .minimum) == 0 && p.value(.cpu, statistic: .average) == 40)
  #expect(
    p.value(.temperature, statistic: .minimum) == -8
      && p.value(.temperature, statistic: .average) == -6)
  #expect(p.value(.gpu, statistic: .minimum) == 0 && p.value(.gpu, statistic: .average) == 0)
  #expect(
    p.validSamples(.gpu, statistic: .average) == 1 && p.value(.upload, statistic: .average) == nil)
  #expect(p.buckets.first?.value(.cpu, statistic: .average) == 50)
  let restored = try SessionHistory(checkpoint: h.checkpoint(), now: statisticsEpoch + 12)
  #expect(restored.projection(.hour).csv == p.csv)
}
@Test func historyStatisticsMeanIsFiniteBoundedAndDoesNotOverflowCountArithmetic() {
  let maximum = Double.greatestFiniteMagnitude
  #expect(HistoryStatistic.average.combined(maximum, samples: 1, with: -maximum, samples: 1) == 0)
  #expect(
    HistoryStatistic.average.combined(maximum, samples: .max, with: maximum, samples: .max)
      == maximum)
  #expect(HistoryStatistic.minimum.combined(-8, samples: 1, with: -4, samples: 1) == -8)
  #expect(HistoryStatistic.peak.combined(-8, samples: 1, with: -4, samples: 1) == -4)
  #expect(HistoryStatistic.average.combined(.nan, samples: 1, with: 0, samples: 1) == nil)
  #expect(HistoryStatistic.average.combined(10, samples: 0, with: 20, samples: 1) == nil)
  var aggregate = HistoryStatistics()
  aggregate.append(-maximum)
  aggregate.append(maximum)
  #expect(aggregate.available && aggregate.mean == 0 && aggregate.minimum == -maximum)
  aggregate.append(.infinity)
  #expect(aggregate.count == 2)
  var capped = HistoryStatistics(minimum: 1, mean: 1, count: .max - 1)
  capped.append(2)
  #expect(!capped.available && capped.count == .max && capped.mean == 0 && capped.minimum == 0)
  capped.append(3)
  #expect(!capped.available)
  var merged = HistoryStatistics(minimum: 1, mean: 1, count: .max - 2)
  merged.merge(.init(minimum: 2, mean: 2, count: 2))
  #expect(!merged.available && merged.count == .max)
  #expect(MemoryLayout<HistoryStatistics>.stride == 24)
  #expect(SessionHistory.maximumBuckets * 12 * MemoryLayout<HistoryStatistics>.stride == 520_128)
  #expect(SessionHistory.maximumScalarCheckpointBytes == 758_596)
}
@Test func historyStatisticsReadsAuthenticV1WithoutInventingAggregatesAndKeepsCSVPrefix() throws {
  let data = try HistoryFixtures.data("history-v1.bin")
  let now = Date(timeIntervalSince1970: 1_700_000_002)
  var h = try SessionHistory(checkpoint: data, now: now)
  let p = h.projection(.hour)
  #expect(p.value(.cpu, statistic: .peak) == 80 && p.samples == 2)
  #expect(p.value(.cpu, statistic: .average) == nil && p.value(.cpu, statistic: .minimum) == nil)
  #expect(
    p.validSamples(.cpu, statistic: .average) == 0 && p.validSamples(.cpu, statistic: .peak) == 2)
  let csvData = try HistoryFixtures.data("history-v1-hour.csv")
  let legacyCSV = try #require(String(data: csvData, encoding: .utf8))
  let oldRows = legacyCSV.components(separatedBy: "\r\n").filter { !$0.isEmpty }
  let newRows = p.csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
  #expect(oldRows.count == newRows.count)
  for (old, new) in zip(oldRows, newRows) {
    #expect(
      new.split(separator: ",", omittingEmptySubsequences: false).prefix(29).joined(separator: ",")
        == old)
  }
  var fresh = statisticsPoint(0, cpu: 50)
  fresh.time = now
  h.append(fresh, uptime: 1)
  let mixed = h.projection(.hour)
  #expect(mixed.value(.cpu, statistic: .peak) == 80 && mixed.value(.cpu, statistic: .average) == 50)
  #expect(mixed.value(.cpu, statistic: .minimum) == 50)
  #expect(
    mixed.validSamples(.cpu, statistic: .average) == 1
      && mixed.validSamples(.cpu, statistic: .peak) == 3)
  let v2 = h.checkpoint()
  #expect(v2[8] == 2)
  let restored = try SessionHistory(checkpoint: v2, now: now)
  #expect(restored.projection(.hour).csv == mixed.csv)
}
@Test func historyStatisticsMergesDisjointSamplesWithCountsAndPreservesLegacyUnknowns() throws {
  var saved = SessionHistory()
  saved.append(statisticsPoint(0, cpu: 0), uptime: 1)
  saved.append(statisticsPoint(1, cpu: 0), uptime: 2)
  var memory = SessionHistory()
  memory.append(statisticsPoint(2, cpu: 90), uptime: 3)
  let merged = memory.mergeOlder(saved, now: statisticsEpoch + 2)
  #expect(merged)
  #expect(memory.projection(.hour).value(.cpu, statistic: .average) == 30)
  #expect(memory.projection(.hour).value(.cpu, statistic: .minimum) == 0)
  #expect(memory.projection(.hour).validSamples(.cpu, statistic: .average) == 3)
  let old = try SessionHistory(
    checkpoint: HistoryFixtures.data("history-v1.bin"),
    now: Date(timeIntervalSince1970: 1_700_000_002))
  var recent = SessionHistory()
  var point = statisticsPoint(0, cpu: 50)
  point.time = Date(timeIntervalSince1970: 1_700_000_002)
  recent.append(point, uptime: 1)
  let imported = recent.mergeOlder(old, now: point.time)
  #expect(imported)
  #expect(recent.projection(.hour).value(.cpu, statistic: .average) == 50)
  #expect(recent.projection(.hour).validSamples(.cpu, statistic: .average) == 1)
}

private func statisticsMutation<T: FixedWidthInteger>(_ data: Data, at offset: Int, value: T)
  -> Data
{
  var result = data
  var little = value.littleEndian
  withUnsafeBytes(of: &little) { result.replaceSubrange(offset..<(offset + $0.count), with: $0) }
  var crc: UInt32 = .max
  for byte in result.dropLast(4) {
    crc ^= UInt32(byte)
    for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
  }
  var checksum = (crc ^ .max).littleEndian
  withUnsafeBytes(of: &checksum) {
    result.replaceSubrange((result.count - 4)..<result.count, with: $0)
  }
  return result
}
@Test func historyStatisticsRejectsImpossibleAggregatesEvenWithValidCRC() throws {
  var h = SessionHistory()
  h.append(statisticsPoint(0, cpu: 20), uptime: 1)
  h.append(statisticsPoint(1, cpu: 80), uptime: 2)
  let data = h.checkpoint()
  // First bucket's legacy180-byte prefix is unchanged. Aggregates follow it.
  let malformed = [
    statisticsMutation(data, at: 212, value: Double.nan.bitPattern),
    statisticsMutation(data, at: 220, value: Double.infinity.bitPattern),
    statisticsMutation(data, at: 212, value: Double(60).bitPattern),
    statisticsMutation(data, at: 220, value: Double(20).bitPattern),
    statisticsMutation(data, at: 220, value: Double(101).bitPattern),
    statisticsMutation(data, at: 228, value: UInt32(3)),
    statisticsMutation(data, at: 228, value: UInt32(0)),
    statisticsMutation(data, at: 228, value: UInt32(1)),
    statisticsMutation(data, at: 228, value: UInt32.max),
    // Unknown system aggregate must stay canonical zero.
    statisticsMutation(data, at: 252, value: Double(1).bitPattern),
  ]
  for invalid in malformed {
    #expect(throws: HistoryCheckpointError.self) {
      try SessionHistory(checkpoint: invalid, now: statisticsEpoch + 1)
    }
  }
}
@Test func historyStatisticsCSVUsesIndependentComponentNamesAndBlankUnknowns() throws {
  var h = SessionHistory()
  var p = statisticsPoint(0, cpu: 80)
  p.cpuUser = 70
  p.cpuSystem = 10
  h.append(p, uptime: 1)
  p.time += 1
  p.cpu = 60
  p.cpuUser = 20
  p.cpuSystem = 40
  h.append(p, uptime: 2)
  let projection = h.projection(.hour)
  let b = try #require(projection.buckets.first)
  #expect(b[.cpuUser] == 70 && b.value(.cpuUser, statistic: .average) == 45)
  #expect(b[.cpuSystem] == 10 && b.value(.cpuSystem, statistic: .average) == 25)
  let lines = projection.csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
  let header = lines[0].split(separator: ",").map(String.init)
  let row = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
  let mean = try #require(header.firstIndex(of: "cpu_user_percent_sample_average"))
  let missing = try #require(header.firstIndex(of: "upload_bytes_per_second_sample_average"))
  #expect(row[mean] == "45.0" && row[missing] == "")
  #expect(!lines[0].contains("cpu_user_at_peak_cpu_percent_sample_average"))
  #expect(!projection.csv.contains("nan") && !projection.csv.contains("inf"))
}

@Test func historyStatisticsOverflowSentinelRoundTripsWithoutInventingCoverage() throws {
  var history = SessionHistory()
  history.append(statisticsPoint(0, cpu: 20), uptime: 1)
  var data = history.checkpoint()
  data = statisticsMutation(data, at: 56, value: UInt32.max)  // bucket observations
  data = statisticsMutation(data, at: 76, value: UInt32.max)  // CPU valid observations
  data = statisticsMutation(data, at: 212, value: Double(0).bitPattern)
  data = statisticsMutation(data, at: 220, value: Double(0).bitPattern)
  data = statisticsMutation(data, at: 228, value: UInt32.max)
  var decoded = try SessionHistory(checkpoint: data, now: statisticsEpoch)
  let bucket = try #require(decoded.projection(.tenMinutes).buckets.first)
  #expect(bucket[.cpu] == 20 && bucket.validSamples(.cpu) == .max)
  #expect(
    bucket.value(.cpu, statistic: .average) == nil
      && bucket.validSamples(.cpu, statistic: .minimum) == 0)
  decoded.append(statisticsPoint(1, cpu: 10), uptime: 1)
  let restored = try SessionHistory(checkpoint: decoded.checkpoint(), now: statisticsEpoch + 1)
  #expect(restored.projection(.tenMinutes).buckets.first?.value(.cpu, statistic: .average) == nil)
  #expect(restored.projection(.tenMinutes).buckets.first?[.cpu] == 20)
}
