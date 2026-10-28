import Foundation
import Testing

@testable import TinyStatsCore

@Test func cpuUserSystemBreakdownSharesTheRealBusyTickDenominator() throws {
  let old = CPUTicks(user: 100, system: 100, idle: 200, nice: 50)
  let next = CPUTicks(user: 120, system: 110, idle: 260, nice: 60)
  let parts = try #require(next.components(since: old))
  #expect(abs(parts.user - 30) < 0.00001 && abs(parts.system - 10) < 0.00001)
  #expect(next.utilization(since: old) == 40)
  #expect(old.components(since: old) == nil)
  let wrapped = try #require(
    CPUTicks(user: 2, system: 4, idle: 4).components(
      since: .init(user: UInt32.max, system: 2, idle: 1)))
  #expect(abs(wrapped.user - 37.5) < 0.00001 && abs(wrapped.system - 25) < 0.00001)
  var sample = Snapshot()
  sample.cpu = .init(usage: 40, cores: [40], load: [], user: parts.user, system: parts.system)
  #expect(sample.historyPoint.cpuUser == 30 && sample.historyPoint.cpuSystem == 10)
  sample.cpu = nil
  #expect(sample.historyPoint.cpuUser == nil && sample.historyPoint.cpuSystem == nil)
}

@Test func processCPUFormattingRetainsSmallWorkAndWithholdsInvalidReadings() {
  #expect(Display.processPercent(0.4) == "0.4%")
  #expect(Display.processPercent(0) == "0.0%")
  #expect(Display.processPercent(200) == "200%")
  for invalid in [nil, Double.nan, .infinity, -1] as [Double?] {
    #expect(Display.processPercent(invalid) == "—")
  }
}
