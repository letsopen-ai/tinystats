import CTinyStats
import Testing

@testable import TinyStatsCore

private func processFixture(_ pid: Int32, serial: UInt64 = 1) -> ts_process {
  var row = ts_process()
  row.pid = pid
  row.started = serial
  row.cpu_ns = UInt64(max(0, pid)) * 1000
  row.footprint = UInt64(max(0, pid)) * 1024
  return row
}

@Test func processScratchUsesTheHintWithoutReservingTheWholeLimit() {
  var capacities: [Int] = []
  let result = ProcessSampleBuffer.read(estimatedCount: 372) { rows in
    capacities.append(rows.count)
    for index in 0..<372 { rows[index] = processFixture(Int32(index + 1)) }
    return 372
  }
  #expect(capacities == [500])
  #expect(result.count == 372 && result.last?.pid == 372)
  #expect(capacities[0] * MemoryLayout<ts_process>.stride < 160 * 1024)
}

@Test func growingProcessInventoryRecollectsWithoutMixingEarlierCounters() {
  var capacities: [Int] = []
  let result = ProcessSampleBuffer.read(estimatedCount: 1) { rows in
    capacities.append(rows.count)
    if capacities.count == 1 {
      for index in rows.indices { rows[index] = processFixture(Int32(index + 1), serial: 7) }
      return rows.count
    }
    for index in 0..<200 { rows[index] = processFixture(Int32(index + 500), serial: 9) }
    return 200
  }
  #expect(capacities == [129, 258])
  #expect(result.count == 200 && result.first?.pid == 500 && result.last?.pid == 699)
  #expect(result.allSatisfy { $0.started == 9 })
  #expect(result.last?.cpu_ns == 699_000 && result.last?.footprint == 699 * 1024)
}

@Test func processScratchRetainsTheExistingLimitAndBoundsRetries() {
  var capacities: [Int] = []
  let result = ProcessSampleBuffer.read(estimatedCount: Int.min) { rows in
    capacities.append(rows.count)
    rows[rows.count - 1] = processFixture(8192)
    return rows.count
  }
  #expect(capacities == [128, 256, 512, 1024, 2048, 4096, 8192])
  #expect(result.count == 8192 && result.last?.pid == 8192)
  var maximumCalls = 0
  let clamped = ProcessSampleBuffer.read(estimatedCount: Int.max) { rows in
    maximumCalls += 1
    return rows.count
  }
  #expect(maximumCalls == 1 && clamped.count == 8192)
}

@Test func processScratchDropsInvalidCountsAndDoesNotPublishUnusedSlots() {
  for invalid in [-1, 129, Int.max] {
    var calls = 0
    let result = ProcessSampleBuffer.read(estimatedCount: 0) { _ in
      calls += 1
      return invalid
    }
    #expect(result.isEmpty && calls == 1)
  }
  let empty = ProcessSampleBuffer.read(estimatedCount: 0) { _ in 0 }
  #expect(empty.isEmpty)
  let result = ProcessSampleBuffer.read(estimatedCount: 0) { rows in
    rows[0] = processFixture(42)
    return 1
  }
  #expect(result.count == 1 && result[0].pid == 42)
}
