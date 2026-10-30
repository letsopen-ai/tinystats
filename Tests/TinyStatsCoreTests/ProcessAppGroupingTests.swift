import CTinyStats
import Darwin
import Testing
import TinyStatsTraffic

@testable import TinyStatsCore

private func appProcess(_ pid: Int32, cpu: Double? = 10, memory: UInt64 = 10) -> ProcessReading {
  .init(pid: pid, name: "worker", cpu: cpu, memory: memory, read: nil, written: nil)
}

@Test func processAppsAggregateTheFullScanBeforeBothTopLists() throws {
  // The individually busiest eight all beat every helper. Truncating first loses the winner.
  let input = (1...28).map {
    appProcess(Int32($0), cpu: $0 <= 8 ? 100 : 10, memory: $0 <= 8 ? 100 : 10)
  }
  let bundles = input.map {
    $0.pid <= 8
      ? nil
      : ExecutableBundle.bundle(
        for: "/Applications/Many.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
  }
  let rows = ProcessAppGrouping.rows(input, bundles: bundles)
  for list in [rows.cpu, rows.memory] {
    #expect(list.count == 8)
    let first = try #require(list.first)
    #expect(first.name == "Many" && first.bundlePath == "/Applications/Many.app")
    #expect(first.processCount == 20 && first.cpu == 200 && first.memory == 200)
    #expect(first.pid == nil)
  }
}

@Test func processAppsKeepBrokersAndDistinctPathsSeparateAndSortTiesStably() {
  let input = (1...5).map { appProcess(Int32($0)) }
  let paths = [
    "/A/Same.app/Contents/MacOS/Same", "/B/Same.app/Contents/MacOS/Same", "/usr/bin/tool", "",
    "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator",
  ]
  let bundles = paths.map { ExecutableBundle.bundle(for: $0) }
  let a = ProcessAppGrouping.rows(input, bundles: bundles)
  let b = ProcessAppGrouping.rows(input.reversed(), bundles: bundles.reversed())
  #expect(a.cpu == b.cpu && a.memory == b.memory)
  #expect(a.cpu.filter { $0.pid != nil }.map(\.pid) == [3, 4])
  #expect(a.cpu.filter { $0.name == "Same" }.map(\.bundlePath) == ["/A/Same.app", "/B/Same.app"])
  #expect(a.cpu.contains { $0.name == "Xcode" })
}

@Test func processAppsPreserveUnavailableCPUAndMemoryOverflowAndValidZero() throws {
  let bundle = ExecutableBundle.bundle(for: "/App.app/Contents/MacOS/App")
  let rows = ProcessAppGrouping.rows(
    [
      appProcess(1, cpu: 10, memory: .max), appProcess(2, cpu: nil, memory: 1),
      appProcess(3, cpu: 0, memory: 0),
    ], bundles: [bundle, bundle, nil])
  let app = try #require(rows.cpu.first { $0.pid == nil })
  #expect(app.cpu == nil && app.memory == nil && app.processCount == 2)
  #expect(rows.cpu.first?.pid == 3 && rows.cpu.first?.cpu == 0)
  #expect(rows.memory.first?.pid == 3 && rows.memory.first?.memory == 0)
  #expect(ProcessAppGrouping.rows([appProcess(1)], bundles: []).cpu.isEmpty)
}

@Test func processBundleCacheIsBoundedPrunesDeadPathsAndCachesNonBundles() {
  var cache = ProcessBundleCache()
  cache.beginScan()
  for i in 0..<8192 { _ = cache.resolve("/Applications/App\(i).app/Contents/MacOS/App") }
  #expect(cache.count == ProcessBundleCache.capacity)
  cache.endScan()
  cache.beginScan()
  #expect(cache.resolve("/Applications/App0.app/Contents/MacOS/App")?.name == "App0")
  cache.endScan()
  #expect(cache.count == 1)
  cache.beginScan()
  #expect(cache.resolve("/usr/bin/tool") == nil)
  cache.endScan()
  #expect(cache.count == 1)
  cache.beginScan()
  cache.endScan()
  #expect(cache.count == 0)
}

@Test func nativeGeneralProcessPathRejectsReusedOrMissingIdentity() {
  var identity = ts_process()
  #expect(ts_read_process_identity(getpid(), &identity))
  var buffer = [CChar](repeating: 0, count: 4096)
  #expect(ts_read_process_path(getpid(), identity.started, &buffer, buffer.count))
  #expect(buffer.first == 47)
  #expect(!ts_read_process_path(getpid(), identity.started &+ 1, &buffer, buffer.count))
  #expect(buffer.allSatisfy { $0 == 0 })
  #expect(!ts_read_process_path(-1, identity.started, &buffer, buffer.count))
  #expect(!ts_read_process_path(getpid(), 0, &buffer, buffer.count))
  #expect(!ts_read_process_path(getpid(), identity.started, &buffer, 10))
}
