import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

private final class ClockSamplerFixture: MonitorSampling, @unchecked Sendable {
  private let lock = NSLock()
  private var times: [Double] = []
  private var demands: [(Module?, Bool)] = []
  private var clears = 0
  private var networkStops = 0
  var networkStopCount: Int { lock.withLock { networkStops } }
  private let uptime: @Sendable () -> Double
  private let date: @Sendable () -> Date
  init(
    uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
    date: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.uptime = uptime
    self.date = date
  }
  var processClearCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return clears
  }
  var processDemands: [(Module?, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return demands
  }
  var samples: Int {
    timestamps.count
  }
  var timestamps: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return times
  }
  func reset() {}
  func configureInternetChecks(_ settings: Settings) {}
  func configureWeather(_ settings: WeatherSettings) {}
  func clearProcessBaselines() {
    lock.lock()
    clears += 1
    lock.unlock()
  }
  func stopNetworkDetails() { lock.withLock { networkStops += 1 } }
  func sample(settings: Settings, includeProcesses: Bool, detailModule: Module?) -> Snapshot {
    lock.lock()
    let now = uptime()
    times.append(now)
    demands.append((detailModule, includeProcesses))
    lock.unlock()
    var snapshot = Snapshot()
    snapshot.uptime = now
    snapshot.timestamp = date()
    return snapshot
  }
}

/// Virtual time only advances on the worker queue, after the preceding tick has finished.
private final class ManualWorkerClock: @unchecked Sendable {
  typealias Tick = @Sendable (Double) async -> Void
  private let lock = NSLock()
  private var now = 100.0
  private let registered = AsyncStream<Tick>.makeStream(bufferingPolicy: .bufferingNewest(1))
  var ticks: AsyncStream<Tick> { registered.stream }
  var uptime: Double { lock.withLock { now } }
  var date: Date { Date(timeIntervalSince1970: 1_700_000_000 + uptime - 100) }

  func makeTimer(queue: DispatchQueue, tick: @escaping @Sendable () -> Void) -> (
    any DispatchSourceTimer
  )? {
    registered.continuation.yield { [weak self] offset in
      guard let self else { return }
      await withCheckedContinuation { completion in
        queue.async { [self] in
          lock.withLock { now = 100 + offset }
          tick()
          completion.resume()
        }
      }
    }
    return nil
  }
}

@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func sharedClockSecondsPreserveLowPowerSamplingAndSampleHistory(worldClocks: Bool) async throws {
  let time = ManualWorkerClock()
  let sampler = ClockSamplerFixture(uptime: { time.uptime }, date: { time.date })
  var deliveries = 0
  var clockSamples: [Int] = []
  var historyCounts: [Int] = []
  let clocks = AsyncStream<Date>.makeStream(bufferingPolicy: .bufferingNewest(1))
  defer { clocks.continuation.finish() }
  let worker = MonitorWorker(
    makeSampler: { _ in sampler }, powerState: { true },
    uptime: { time.uptime }, date: { time.date },
    makeTimer: { time.makeTimer(queue: $0, tick: $1) },
    clock: {
      clockSamples.append(sampler.samples)
      clocks.continuation.yield($0)
    },
    receive: { _, history, events in
      deliveries += 1
      historyCounts.append(history.count)
      #expect(history.allSatisfy { $0.sampleInterval == 5 })
      #expect(events.isEmpty)
    })
  defer { worker.setPaused(true) }
  var settings = Settings()
  settings.interval = 1
  settings.readouts = [.clock, .cpu]
  settings.styles["cpu"] = .history
  settings.clockMenu = .init(
    custom: true, entries: [.init(firstLine: "{hour24}:{minute}:{second}", secondLine: "")])
  if worldClocks {
    settings.readouts = [.cpu]
    settings.worldClockFormat = "{hour24}:{minute}:{second}"
    worker.setDetails(true, module: .clock)
  }
  worker.start(settings)
  var ticks = time.ticks.makeAsyncIterator()
  let tick = try #require(await ticks.next())
  var clockDates = clocks.stream.makeAsyncIterator()
  // Await each real MainActor clock delivery before advancing virtual time. Contention can
  // delay a step, but cannot coalesce it with a later sample or consume a collection interval.
  for second in 0...11 {
    await tick(Double(second))
    let delivered = try #require(await clockDates.next())
    #expect(delivered == Date(timeIntervalSince1970: 1_700_000_000 + Double(second)))
    #expect(sampler.samples == 1 + second / 5)
    #expect(deliveries == sampler.samples)
    #expect(historyCounts == Array(1...sampler.samples))
  }
  let times = sampler.timestamps
  #expect(!times.isEmpty && deliveries > 0)
  #expect(times == [100, 105, 110])
  #expect(clockSamples == [1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3])
  #expect(zip(clockSamples, clockSamples.dropFirst()).contains { $0 == $1 && $0 > 0 })
  #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 4.9 })
  #expect(historyCounts.allSatisfy { $0 > 0 && $0 <= times.count })
  #expect(zip(historyCounts, historyCounts.dropFirst()).allSatisfy { $1 > $0 })
}

@Test @MainActor func processCollectionRunsOnlyForVisibleProcessLists() async throws {
  let sampler = ClockSamplerFixture()
  let worker = MonitorWorker(
    makeSampler: { _ in sampler }, powerState: { false },
    receive: { _, _, _ in })
  defer { worker.setPaused(true) }
  var settings = Settings()
  settings.interval = 1
  worker.setDetails(true, module: .overview)
  worker.start(settings)
  for (module, expected) in [
    (Module.overview, false), (.cpu, true), (.gpu, false), (.memory, true),
  ] {
    let oldClears = sampler.processClearCount
    worker.setDetailModule(module)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !sampler.processDemands.contains(where: { $0.0 == module })
      && ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(25))
    }
    let recorded = try #require(sampler.processDemands.last { $0.0 == module })
    #expect(recorded.1 == expected)
    if module == .memory { #expect(sampler.processClearCount > oldClears) }
  }
  let oldClears = sampler.processClearCount
  worker.setDetails(false)
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while !sampler.processDemands.contains(where: { $0.0 == nil }) && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(sampler.processDemands.last?.0 == nil && sampler.processDemands.last?.1 == false)
  #expect(sampler.processClearCount > oldClears)
}

@Test @MainActor func sessionHistoryDemandReusesSamplesAndRemainsQueryableWhilePaused() async throws
{
  let sampler = ClockSamplerFixture()
  var projections: [HistoryProjection] = []
  let worker = MonitorWorker(
    makeSampler: { _ in sampler }, powerState: { true },
    history: { projections.append($0) }, receive: { _, _, _ in })
  defer { worker.setPaused(true) }
  var settings = Settings()
  settings.interval = 1
  worker.start(settings)
  var deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while sampler.samples == 0 && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(25))
  }
  worker.setPaused(true)
  worker.setHistoryRange(.hour)
  deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while projections.isEmpty && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(25))
  }
  let recordedSamples = UInt64(sampler.samples)
  #expect(
    recordedSamples > 0 && projections.last?.range == .hour
      && projections.last?.samples == recordedSamples)
  let samples = sampler.samples
  worker.setHistoryRange(.fourWeeks)
  deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while projections.last?.range != .fourWeeks && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(sampler.samples == samples && projections.last?.samples == recordedSamples)
  let count = projections.count
  worker.setHistoryRange(nil)
  worker.setPaused(false)
  deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while sampler.samples == samples && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(sampler.samples > samples && projections.count == count)
  #expect(sampler.processDemands.allSatisfy { $0.0 == nil && !$0.1 })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func groupingChangesResetOnlyTheVisibleNetworkStream() async throws {
  let time = ManualWorkerClock()
  let sampler = ClockSamplerFixture(uptime: { time.uptime }, date: { time.date })
  let worker = MonitorWorker(
    makeSampler: { _ in sampler }, powerState: { false },
    uptime: { time.uptime }, date: { time.date },
    makeTimer: { time.makeTimer(queue: $0, tick: $1) }, receive: { _, _, _ in })
  var settings = Settings()
  worker.start(settings)
  var ticks = time.ticks.makeAsyncIterator()
  let tick = try #require(await ticks.next())
  defer { worker.setPaused(true) }
  for (index, module) in [Module.cpu, .memory, .network].enumerated() {
    worker.setDetails(true, module: module)
    await tick(Double(index * 4))
    let before = sampler.networkStopCount
    settings.processGrouping = settings.processGrouping == .bundles ? .processes : .bundles
    worker.update(settings)
    await tick(Double(index * 4 + 2))
    #expect(sampler.networkStopCount == before + (module == .network ? 1 : 0))
  }
}
