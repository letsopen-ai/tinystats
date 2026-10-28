import CTinyStatsTraffic
import Darwin
import Foundation
import Testing

@testable import TinyStatsTraffic

private func owner(_ pid: Int32, _ rate: Double = 10, unique: UInt64? = nil)
  -> ProcessTrafficReading
{
  .init(
    pid: pid, uniqueID: unique ?? UInt64(max(0, pid)), name: "Process \(pid)", download: rate,
    upload: rate)
}
@Test func bundlePathsRequireAnExactConventionalComponentAndUseTheOutermostApp() {
  let valid = [
    "/Applications/Browser.app/Contents/MacOS/Browser": ("/Applications/Browser.app", "Browser"),
    "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper": (
      "/Applications/Browser.app", "Browser"
    ),
    "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator":
      ("/Applications/Xcode.app", "Xcode"),
    "/private/Translocation/Example.app/Contents/MacOS/App": (
      "/private/Translocation/Example.app", "Example"
    ),
    "/Users/test/应用 Test.app/Contents/MacOS/Test": ("/Users/test/应用 Test.app", "应用 Test"),
  ]
  for (path, expected) in valid {
    #expect(TrafficBundleGrouping.bundle(for: path) == .init(path: expected.0, name: expected.1))
  }
  for path in [
    "", "/", "relative/App.app/Contents/MacOS/App", "/App.app", "/App.app/Contents",
    "/App.app/Contents/", "/App.app.bak/Contents/MacOS/App", "/App.APP/Contents/MacOS/App",
    "/.app/Contents/bin", "/usr/bin/curl",
    "/System/Library/Frameworks/WebKit.framework/XPCServices/Network.xpc/Contents/MacOS/Network",
    "/App.app//Contents/App", "/App.app/Contents/../Other", "/App.app/Contents/./App",
    "/App.app/Contents/a\nb", "/App.app/Contents/" + String(repeating: "a", count: 4096),
  ] {
    #expect(TrafficBundleGrouping.bundle(for: path) == nil)
  }
}
@Test func bundleGroupingAggregatesBeforeRankingAndCountsOnlyActiveOwnerRates() throws {
  let owners = (1...1024).map { owner(Int32($0), $0 <= 8 ? 100 : 2) }
  var resolutions = 0
  let rows = try #require(
    TrafficBundleGrouping.rows(owners) { process in
      resolutions += 1
      return process.pid <= 8
        ? nil : "/Applications/Many.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
    })
  #expect(resolutions == 1024 && rows.count == 8)
  #expect(rows[0].name == "Many" && rows[0].processCount == 1016 && rows[0].pid == nil)
  #expect(rows[0].download == 2032 && rows[0].upload == 2032)
  var lookups = 0
  let idle = try #require(
    TrafficBundleGrouping.rows([owner(1, 0), owner(2), owner(3, 0)]) { _ in
      lookups += 1
      return "/Applications/App.app/Contents/MacOS/App"
    })
  #expect(lookups == 1 && idle.count == 1 && idle[0].processCount == 1)
}
@Test func bundleGroupingKeepsDistinctPathsAndUnresolvedIdentitiesSeparateAndNeverCachesPaths()
  throws
{
  let input = [owner(1), owner(2), owner(3), owner(4), owner(0), owner(5, unique: 0)]
  let paths = [
    Int32(1): "/A/Same.app/Contents/MacOS/App", 2: "/B/Same.app/Contents/MacOS/App",
    3: "/usr/bin/curl",
  ]
  var lookups: [Int32] = []
  let first = try #require(
    TrafficBundleGrouping.rows(input) { process in
      lookups.append(process.pid)
      return paths[process.pid]
    })
  #expect(lookups == [1, 2, 3, 4] && first.count == 6)
  #expect(first.filter { $0.name == "Same" }.count == 2)
  #expect(first.filter { $0.pid != nil }.count == 4)
  let second = try #require(TrafficBundleGrouping.rows([owner(1, unique: 9)]) { _ in nil })
  #expect(second.count == 1 && second[0].pid == 1 && second[0].name == "Process 1")
  let changed = try #require(
    TrafficBundleGrouping.rows([owner(1)]) { _ in "/C/New.app/Contents/MacOS/New" })
  #expect(changed[0].name == "New")
  let reversed = try #require(TrafficBundleGrouping.rows(Array(input.reversed())) { paths[$0.pid] })
  #expect(first.map(\.label) == reversed.map(\.label))
}
@Test func bundleGroupingInvalidProjectionCannotMasqueradeAsNoTraffic() {
  #expect(TrafficBundleGrouping.rows([owner(1, -.infinity)]) { _ in nil } == nil)
  #expect(TrafficBundleGrouping.rows([owner(1, .nan)]) { _ in nil } == nil)
  #expect(TrafficBundleGrouping.rows([owner(1, -1)]) { _ in nil } == nil)
  #expect(TrafficBundleGrouping.rows([owner(1), owner(1)]) { _ in nil } == nil)
  #expect(TrafficBundleGrouping.rows((1...1025).map { owner(Int32($0)) }) { _ in nil } == nil)
  #expect(TrafficBundleGrouping.rows([owner(1, .greatestFiniteMagnitude)]) { _ in nil } == nil)
  #expect(TrafficBundleGrouping.rows([]) { _ in nil }?.isEmpty == true)
}
@Test func nativeBundlePathRequiresExactLiveIdentityAndSafeOutputBuffer() throws {
  var unique: UInt64 = 0
  var version: Int32 = 0
  #expect(ts_traffic_process_identity(getpid(), &unique, &version))
  #expect(unique > 0)
  var buffer = [CChar](repeating: 0, count: 4096)
  #expect(ts_traffic_process_path(getpid(), unique, &buffer, buffer.count))
  #expect(buffer[0] == 47)
  #expect(!ts_traffic_process_path(getpid(), unique &+ 1, &buffer, buffer.count))
  #expect(buffer.allSatisfy { $0 == 0 })
  #expect(!ts_traffic_process_path(getpid(), 0, &buffer, buffer.count))
  #expect(!ts_traffic_process_path(-1, unique, &buffer, buffer.count))
  #expect(!ts_traffic_process_path(getpid(), unique, &buffer, 10))
  #expect(!ts_traffic_process_identity(-1, &unique, &version))
  #expect(unique == 0 && version == 0)
}
