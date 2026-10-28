import CTinyStats
import Darwin
import Foundation
import Testing
import TinyStatsTestSupport

@testable import TinyStatsCore

@Test func historyStatisticsPopulatedWireHasEqualPeaksAndActualAggregates() throws {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let old = try SessionHistory(
    checkpoint: HistoryFixtures.populatedCheckpoint(version: 1, now: now), now: now)
  let current = try SessionHistory(
    checkpoint: HistoryFixtures.populatedCheckpoint(version: 2, now: now), now: now)
  #expect(old.retainedBucketCount == 1800 && current.retainedBucketCount == 1800)
  for range in HistoryRange.allCases {
    let a = old.projection(range)
    let b = current.projection(range)
    #expect(a.buckets.count == b.buckets.count && a.samples == b.samples)
    for (first, second) in zip(a.buckets, b.buckets) {
      for metric in HistoryMetric.allCases {
        #expect(
          first[metric] == second[metric]
            && first.validSamples(metric) == second.validSamples(metric))
        #expect(first.value(metric, statistic: .average) == nil)
        #expect(second.value(metric, statistic: .average) == second[metric])
      }
    }
  }
}

@Test func historyStatisticsMeasuresRetainedAllocationOnlyWhenExplicitlyRequested() throws {
  guard ProcessInfo.processInfo.environment["TINYSTATS_STATISTICS_MEMORY_BENCHMARK"] == "1" else {
    return
  }
  let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 8064) * 8064 + 0.25)
  let old = HistoryFixtures.populatedCheckpoint(version: 1, now: now, maximum: true)
  let current = HistoryFixtures.populatedCheckpoint(version: 2, now: now, maximum: true)
  #expect(old.count == 325_156 && current.count == 758_596)
  #expect(try SessionHistory(checkpoint: current, now: now).retainedBucketCount == 1806)
  let copies = 16
  func allocated() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
  }
  func phase(_ data: Data) throws -> Int {
    // Independent decodes, not 16 copy-on-write references to one archive.
    var archives: [SessionHistory] = []
    archives.reserveCapacity(copies)
    let before = allocated()
    for _ in 0..<copies { archives.append(try SessionHistory(checkpoint: data, now: now)) }
    return withExtendedLifetime(archives) { allocated() - before }
  }
  _ = try phase(old)
  _ = try phase(current)  // Warm metadata/decoder, outside accepted observations.
  var observations: [(Int, Int)] = []
  for version in [1, 2, 2, 1] {
    let bytes = try autoreleasepool { try phase(version == 1 ? old : current) }
    observations.append((version, bytes))
    print(
      "STATISTICS_RETAINED version=\(version) copies=\(copies) buckets_per_copy=1806 heap_in_use_delta=\(bytes)"
    )
  }
  let baseline = Double(observations.filter { $0.0 == 1 }.map(\.1).reduce(0, +)) / 2
  let populated = Double(observations.filter { $0.0 == 2 }.map(\.1).reduce(0, +)) / 2
  let added = (populated - baseline) / Double(copies)
  #expect(added > 0 && added < 1_048_576)
  print(
    "STATISTICS_RETAINED_SUMMARY added_heap_bytes_per_1806_bucket_archive=\(added) numeric_payload_bytes=520128 wire_v1=\(old.count) wire_v2=\(current.count)"
  )
  if let path = ProcessInfo.processInfo.environment["TINYSTATS_STATISTICS_FIXTURE_DIRECTORY"] {
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try old.write(
      to: directory.appendingPathComponent("populated-v1.bin"), options: .withoutOverwriting)
    try current.write(
      to: directory.appendingPathComponent("populated-v2.bin"), options: .withoutOverwriting)
  }
}
