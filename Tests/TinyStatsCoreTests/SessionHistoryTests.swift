import CTinyStats
import Foundation
import Testing

@testable import TinyStatsCore

private func historySample(_ seconds: Double, cpu: Double? = nil) -> HistoryPoint {
  var sample = Snapshot().historyPoint
  sample.time = Date(timeIntervalSince1970: 1_700_000_000 + seconds)
  sample.sampleInterval = 1
  sample.cpu = cpu
  return sample
}

@Test func sessionHistoryRetainsPairedCPUPeaksAndIndependentRatePeaks() throws {
  var archive = SessionHistory()
  var a = historySample(0, cpu: 80)
  a.cpuUser = 70
  a.cpuSystem = 10
  a.download = 100
  a.upload = 10
  var b = historySample(1, cpu: 60)
  b.cpuUser = 20
  b.cpuSystem = 40
  b.download = 10
  b.upload = 200
  archive.append(a, uptime: 1)
  archive.append(b, uptime: 2)
  let bucket = try #require(archive.projection(.hour).buckets.first)
  #expect(bucket.samples == 2)
  #expect(bucket[.cpu] == 80 && bucket[.cpuUser] == 70 && bucket[.cpuSystem] == 10)
  #expect(bucket[.download] == 100 && bucket[.upload] == 200)
  #expect(bucket.validSamples(.cpu) == 2 && bucket.validSamples(.gpu) == 0)
}

@Test func sessionHistoryWithholdsInvalidValuesAndDistinguishesIdleFromMissing() throws {
  var archive = SessionHistory()
  var a = historySample(0, cpu: 0)
  a.gpu = .nan
  a.memory = 101
  a.download = -1
  a.temperature = -4
  a.cpuUser = 0
  a.cpuSystem = 0
  archive.append(a, uptime: 1)
  let bucket = try #require(archive.projection(.hour).buckets.first)
  #expect(bucket[.cpu] == 0 && bucket[.gpu] == nil && bucket[.memory] == nil)
  #expect(bucket[.download] == nil && bucket[.temperature] == -4)
  #expect(bucket.validSamples(.cpu) == 1 && bucket.validSamples(.download) == 0)
  a.time += 1
  a.cpu = 90
  a.cpuUser = nil
  a.cpuSystem = nil
  archive.append(a, uptime: 2)
  let next = try #require(archive.projection(.hour).buckets.first)
  #expect(next[.cpu] == 90 && next[.cpuUser] == nil && next[.cpuSystem] == nil)
  #expect(next.validSamples(.cpuUser) == 1)
}

@Test func sessionHistoryBoundsAllRangesAndExpiresOldDataWithoutFillingGaps() {
  var archive = SessionHistory()
  for index in 0..<1000 {
    archive.append(
      historySample(Double(index) * 8064, cpu: Double(index % 101)), uptime: Double(index + 1))
  }
  // Sparse observations leave 1+1+3+11+75+300 eligible buckets across the six tiers.
  #expect(archive.retainedBucketCount == 391)
  for range in HistoryRange.allCases {
    let projection = archive.projection(range)
    #expect(projection.buckets.count <= 300)
    #expect(
      projection.buckets.allSatisfy {
        $0.last > historySample(999 * 8064 - Double(range.rawValue)).time
      })
    #expect(projection.buckets.last?[.cpu] == Double(999 % 101))
  }
  #expect(archive.projection(.tenMinutes).buckets.count == 1)
  #expect(archive.projection(.fourWeeks).gapBuckets > 0)
}

@Test func sessionHistoryResetsAmbiguousTimelinesAndRejectsMalformedInputs() throws {
  var archive = SessionHistory()
  archive.append(historySample(100), uptime: 100)
  archive.append(historySample(101), uptime: 101)
  #expect(archive.resets == 0)
  archive.append(historySample(-500), uptime: 102)
  #expect(archive.resets == 1 && archive.projection(.hour).samples == 1)
  archive.append(historySample(-499), uptime: 1)
  #expect(archive.resets == 2 && archive.projection(.hour).samples == 1)
  for invalid in [Double.nan, .infinity, -1] {
    let accepted = archive.append(historySample(92), uptime: invalid)
    #expect(!accepted)
  }
  var invalid = historySample(.nan)
  let accepted = archive.append(invalid, uptime: 2)
  #expect(!accepted)
  invalid = historySample(92)
  invalid.sampleInterval = nil
  let acceptedMissingInterval = archive.append(invalid, uptime: 2)
  #expect(!acceptedMissingInterval)
  invalid.sampleInterval = .infinity
  let acceptedInfiniteInterval = archive.append(invalid, uptime: 2)
  #expect(!acceptedInfiniteInterval)
  #expect(archive.projection(.hour).samples == 1 && archive.resets == 2)
  archive.append(historySample(1000), uptime: 2)
  #expect(archive.projection(.hour).gapBuckets >= 1)
}

@Test func sessionHistoryCSVRetainsUnitsValidityBoundsAndFrozenSnapshot() throws {
  var archive = SessionHistory()
  archive.append(historySample(0, cpu: 0), uptime: 1)
  let frozen = archive.projection(.hour)
  let before = frozen.csv
  archive.append(historySample(1, cpu: 90), uptime: 2)
  #expect(frozen.csv == before && archive.projection(.hour).csv != before)
  let rows = before.components(separatedBy: "\r\n").filter { !$0.isEmpty }
  #expect(rows.count == 2)
  let header = rows[0].split(separator: ",")
  let data = rows[1].split(separator: ",", omittingEmptySubsequences: false)
  #expect(header.count == data.count && header.contains("download_bytes_per_second_valid_samples"))
  #expect(data[5] == "0.0" && data[6] == "1")
  #expect(data[11] == "" && data[12] == "0")
  #expect(data[0].hasSuffix("Z") && data[0] == data[1])
  #expect(!before.contains("sensorKey") && !before.contains("process"))
}

@Test func sessionHistoryDocumentsFullRetentionSyntheticCost() {
  guard ProcessInfo.processInfo.environment["TINYSTATS_HISTORY_BENCHMARK"] == "1" else { return }
  var before = ts_self_usage()
  _ = ts_read_self(&before)
  var archive = SessionHistory()
  let started = ContinuousClock.now
  for index in 0..<500_000 {
    archive.append(
      historySample(Double(index) * 6, cpu: Double(index % 101)), uptime: Double(index * 6 + 1))
  }
  let elapsed = started.duration(to: .now)
  var after = ts_self_usage()
  _ = ts_read_self(&after)
  let queryStarted = ContinuousClock.now
  var bytes = 0
  for range in HistoryRange.allCases { bytes += archive.projection(range).csv.utf8.count }
  print(
    "HISTORY_COST appends=500000 retained=\(archive.retainedBucketCount) elapsed=\(elapsed) query_and_csv=\(queryStarted.duration(to: .now)) csv_bytes_all_ranges=\(bytes) rss_before=\(before.rss) rss_after=\(after.rss) footprint_before=\(before.footprint) footprint_after=\(after.footprint)"
  )
  // Six-second samples occupy 100 fine buckets and 300–301 in each coarser tier.
  #expect((1600...1605).contains(archive.retainedBucketCount))
}

@Test func sessionHistoryPreservesLongRetentionThroughSmallBackwardClockCorrections() throws {
  var archive = SessionHistory()
  archive.append(historySample(100, cpu: 80), uptime: 1)
  archive.append(historySample(90, cpu: 100), uptime: 2)
  archive.append(historySample(95, cpu: 100), uptime: 7)
  #expect(archive.resets == 0 && archive.projection(.hour).samples == 1)
  archive.append(historySample(101, cpu: 20), uptime: 13)
  let result = archive.projection(.hour)
  #expect(result.resets == 0 && result.samples == 2 && result.gapBuckets > 0)
  #expect(result.buckets.first?[.cpu] == 80)
}

@Test func sessionHistoryPrefersKnownCPUPartsOnTiesAndTrimsBoundaryBucket() throws {
  var archive = SessionHistory()
  var point = historySample(0, cpu: 80)
  point.cpuUser = 60
  point.cpuSystem = 20
  archive.append(point, uptime: 1)
  point.time += 1
  point.cpuUser = nil
  point.cpuSystem = nil
  archive.append(point, uptime: 2)
  #expect(archive.projection(.hour).buckets.first?[.cpuUser] == 60)
  for index in 1...300 {
    archive.append(
      historySample(Double(index) * 2, cpu: Double(index % 100)), uptime: Double(index * 2 + 1))
  }
  let result = archive.projection(.tenMinutes)
  #expect(result.buckets.count == 300)
  let rows = result.csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
  #expect(rows.count == 301)
  #expect(
    rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 65 })
  for row in rows.dropFirst() {
    let cells = row.split(separator: ",", omittingEmptySubsequences: false)
    for value in cells.dropFirst(5) where !value.isEmpty { #expect(Double(value) != nil) }
  }
}

@Test func sessionHistoryStartupCapacityIsIndependentOfMountEnumerationOrder() {
  var snapshot = Snapshot()
  let external = VolumeReading(
    name: "External", path: "/Volumes/Example", total: 1000, available: 900)
  let startup = VolumeReading(name: "Startup disk", path: "/", total: 100, available: 50)
  snapshot.volumes = [external, startup]
  #expect(snapshot.historyPoint.diskUsed == 50)
  snapshot.volumes = [startup, external]
  #expect(snapshot.historyPoint.diskUsed == 50)
  snapshot.volumes = [external]
  #expect(snapshot.historyPoint.diskUsed == nil)
  snapshot.volumes = [.init(name: "Startup disk", path: "/", total: 0, available: 0)]
  #expect(snapshot.historyPoint.diskUsed == nil)
}
