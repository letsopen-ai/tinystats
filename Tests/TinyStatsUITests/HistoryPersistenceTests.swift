import Darwin
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

private final class PersistenceStoreFixture: HistoryCheckpointStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Data?
  private var requests: [String] = []
  private var archiveWriteCount = 0
  private var writeFailure: HistoryFileError?
  private var removeFailure: HistoryFileError?
  private let writeGate: DispatchSemaphore?
  init(_ data: Data? = nil, writeGate: DispatchSemaphore? = nil) {
    value = data
    self.writeGate = writeGate
  }
  var calls: [String] { lock.withLock { requests } }
  var archiveWrites: Int { lock.withLock { archiveWriteCount } }
  var data: Data? { lock.withLock { value } }
  func failWrites(_ failure: HistoryFileError?) { lock.withLock { writeFailure = failure } }
  func failRemoves(_ failure: HistoryFileError?) { lock.withLock { removeFailure = failure } }
  func opened(_ create: Bool) { lock.withLock { requests.append(create ? "create" : "existing") } }
  func read() throws -> Data? {
    lock.withLock {
      requests.append("read")
      return value
    }
  }
  func write(_ history: SessionHistory) throws {
    lock.withLock { archiveWriteCount += 1 }
    try write(history.checkpoint())
  }
  func write(_ data: Data) throws {
    let failure = lock.withLock {
      requests.append("write")
      return writeFailure
    }
    if let failure { throw failure }
    writeGate?.wait()
    lock.withLock { value = data }
  }
  func remove() throws {
    try lock.withLock {
      requests.append("remove")
      if let removeFailure { throw removeFailure }
      value = nil
    }
  }
}
private func persistenceArchive(at now: Date, cpu: Double = 42) -> SessionHistory {
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.time = now
  point.sampleInterval = 2
  point.cpu = cpu
  archive.append(point, uptime: 1)
  return archive
}

@Test func historyPersistenceExplicitOffAndMalformedSettingsPerformZeroStoreCalls() throws {
  let store = PersistenceStoreFixture()
  let persistence = HistoryPersistence { create in
    store.opened(create)
    return store
  }
  let settings = try JSONDecoder().decode(
    Settings.self, from: Data("{\"persistHistory\":\"bad\"}".utf8))
  #expect(!settings.persistHistory)
  let now = Date()
  let loaded = persistence.begin(enabled: settings.persistHistory, now: now, uptime: 0)
  let archive = persistenceArchive(at: now)
  persistence.markDirty()
  for tick in [1.0, 300, 600, 10000] {
    persistence.checkpoint(archive, now: now, uptime: tick)
    persistence.checkpoint(archive, now: now, uptime: tick, force: true)
  }
  #expect(loaded == nil && store.calls.isEmpty && !persistence.state.enabled)
}

@Test func historyPersistenceCheckpointsOnOneCadenceRetriesAndFlushesOnlyDirtyData() throws {
  let now = Date()
  let archive = persistenceArchive(at: now)
  let store = PersistenceStoreFixture(archive.checkpoint())
  let persistence = HistoryPersistence { create in
    store.opened(create)
    return store
  }
  let loaded = persistence.begin(enabled: true, now: now, uptime: 0)
  #expect(loaded?.projection(.hour).samples == 1 && persistence.state.restored)
  persistence.markDirty()
  persistence.checkpoint(archive, now: now, uptime: 299)
  #expect(store.calls == ["create", "read"])
  store.failWrites(.system(28))
  persistence.checkpoint(archive, now: now, uptime: 300)
  #expect(persistence.state.issue == .io(28))
  store.failWrites(nil)
  persistence.checkpoint(archive, now: now, uptime: 599)
  #expect(store.calls.filter { $0 == "write" }.count == 1)
  persistence.checkpoint(archive, now: now, uptime: 600)
  #expect(persistence.state.issue == nil && persistence.state.savedAt == now)
  persistence.checkpoint(archive, now: now, uptime: 10000, force: true)
  #expect(store.calls.filter { $0 == "write" }.count == 2)
  persistence.markDirty()
  persistence.checkpoint(archive, now: now, uptime: 10001, force: true)
  #expect(store.calls.filter { $0 == "write" }.count == 3 && store.archiveWrites == 3)
}

@Test func historyPersistenceUnreadableCheckpointBlocksOverwriteUntilExplicitClear() throws {
  let now = Date()
  let archive = persistenceArchive(at: now)
  var corrupt = archive.checkpoint()
  corrupt[30] ^= 1
  let store = PersistenceStoreFixture(corrupt)
  let persistence = HistoryPersistence { create in
    store.opened(create)
    return store
  }
  #expect(persistence.begin(enabled: true, now: now, uptime: 0) == nil)
  #expect(persistence.state.issue == .unreadable)
  persistence.markDirty()
  persistence.checkpoint(archive, now: now, uptime: 1000, force: true)
  #expect(store.data == corrupt && !store.calls.contains("write"))
  persistence.clear(uptime: 1001)
  #expect(store.data == nil && persistence.state.issue == nil && persistence.state.enabled)
  persistence.markDirty()
  persistence.checkpoint(archive, now: now, uptime: 1301)
  #expect(store.data == archive.checkpoint())
}

@Test func historyPersistenceEnableMergesOlderAndDisableKeepsCheckpoint()
  throws
{
  let now = Date()
  var memory = persistenceArchive(at: now, cpu: 42)
  let old = persistenceArchive(at: now - 10, cpu: 95)
  let store = PersistenceStoreFixture(old.checkpoint())
  let persistence = HistoryPersistence { create in
    store.opened(create)
    return store
  }
  persistence.setEnabled(true, archive: &memory, now: now, uptime: 1)
  let saved = try SessionHistory(checkpoint: #require(store.data), now: now)
  #expect(saved.projection(.hour).csv == memory.projection(.hour).csv)
  #expect(saved.projection(.hour).samples == 2)
  persistence.setEnabled(false, archive: &memory, now: now, uptime: 2)
  persistence.markDirty()
  persistence.checkpoint(memory, now: now, uptime: 1000, force: true)
  #expect(!store.calls.contains("remove") && store.data != nil)
  #expect(!persistence.state.enabled && memory.projection(.hour).samples == 2)
}

@Test func historyPersistenceClearWhileOffUsesExistingOnlyAndUnavailableNeverCreatesFallback() {
  let now = Date()
  let store = PersistenceStoreFixture()
  let persistence = HistoryPersistence { create in
    store.opened(create)
    return store
  }
  persistence.clear(uptime: 1)
  #expect(store.calls == ["existing", "remove"] && !persistence.state.enabled)
  let unavailable = HistoryPersistence()
  var archive = persistenceArchive(at: now)
  unavailable.setEnabled(true, archive: &archive, now: now, uptime: 1)
  #expect(unavailable.state.issue == .unavailable)
  unavailable.clear(uptime: 2)
  #expect(unavailable.state.removalFailed && unavailable.state.issue == .unavailable)
}

@Test @MainActor func historyQuitRepliesOnceAfterFlushOrDeadlineWithoutTerminatingTestHost() {
  var replies = 0
  var complete: (@MainActor @Sendable () -> Void)?
  let quit = HistoryQuitCoordinator { replies += 1 }
  quit.begin { complete = $0 }
  #expect(quit.waiting && !quit.replied && replies == 0)
  complete?()
  complete?()
  quit.begin { _ in Issue.record("Must not start a second flush") }
  #expect(!quit.waiting && quit.replied && replies == 1)

  var timeoutReplies = 0
  var lateCompletion: (@MainActor @Sendable () -> Void)?
  let timeout = HistoryQuitCoordinator { timeoutReplies += 1 }
  timeout.begin { lateCompletion = $0 }
  // Task.sleep yields to other main-actor tests, whose synchronous work can outlast
  // the assertion window before the run loop services this timer. Pump the same
  // termination mode as AppKit instead, with the existing shorter three-second bound.
  runHistoryTerminationMode { timeout.replied }
  #expect(timeout.replied && !timeout.waiting && timeoutReplies == 1)
  lateCompletion?()
  #expect(timeoutReplies == 1)
}

@MainActor private final class HistoryQuitBacklogState {
  var waiting = true
  var interleaved = false
}

// Guards the wait helper against main-actor interleaving, not production code.
@Test @MainActor func historyQuitDeadlineWaitDoesNotYieldToMainActorBacklog() throws {
  let state = HistoryQuitBacklogState()
  Task { @MainActor in
    if state.waiting { state.interleaved = true }
  }
  defer {
    state.waiting = false
  }
  var repliedAt: ContinuousClock.Instant?
  let quit = HistoryQuitCoordinator { repliedAt = .now }
  let started = ContinuousClock.now
  quit.begin { _ in }
  runHistoryTerminationMode { quit.replied }
  state.waiting = false
  let elapsed = started.duration(to: try #require(repliedAt))
  #expect(quit.replied && !quit.waiting)
  #expect(elapsed >= .seconds(2) && elapsed < .seconds(4))
  #expect(!state.interleaved)
}

private final class PersistenceSamplerFixture: MonitorSampling, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var samples: Int { lock.withLock { count } }
  func reset() {}
  func configureInternetChecks(_ settings: Settings) {}
  func configureWeather(_ settings: WeatherSettings) {}
  func clearProcessBaselines() {}
  func stopNetworkDetails() {}
  func sample(settings: Settings, includeProcesses: Bool, detailModule: Module?) -> Snapshot {
    lock.withLock { count += 1 }
    var snapshot = Snapshot()
    snapshot.uptime = ProcessInfo.processInfo.systemUptime
    return snapshot
  }
}
@MainActor private func waitForPersistence(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(6))
  while !condition(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(condition())
}

@Test @MainActor func historyPersistenceWorkerDefaultOffHasNoIOAndCannotRearmAfterFinish()
  async throws
{
  let sampler = PersistenceSamplerFixture()
  let store = PersistenceStoreFixture()
  var deliveries = 0
  let worker = MonitorWorker(
    makeSampler: { _ in sampler },
    historyStore: { create in
      store.opened(create)
      return store
    },
    powerState: { false }, receive: { _, _, _ in deliveries += 1 })
  defer { worker.setPaused(true) }
  var settings = Settings()
  settings.persistHistory = false
  settings.interval = 1
  worker.start(settings)
  try await waitForPersistence { deliveries > 0 }
  worker.setSleeping(true)
  var finished = false
  worker.finishHistory { finished = true }
  try await waitForPersistence { finished }
  let before = sampler.samples
  worker.setSleeping(false)
  worker.powerChanged()
  worker.update(settings)
  worker.setPaused(false)
  try await Task.sleep(for: .milliseconds(150))
  #expect(sampler.samples == before && store.calls.isEmpty)
}

@Test @MainActor
func historyPersistenceWorkerRestoresThenSavesOnSleepAndClearPreservesRecentLiveRing() async throws
{
  let sampler = PersistenceSamplerFixture()
  let store = PersistenceStoreFixture(persistenceArchive(at: Date() - 10).checkpoint())
  var latest: HistoryProjection?
  var liveCount = 0
  let worker = MonitorWorker(
    makeSampler: { _ in sampler },
    historyStore: { create in
      store.opened(create)
      return store
    },
    powerState: { false }, history: { latest = $0 },
    receive: { _, points, _ in liveCount = points.count })
  defer { worker.setPaused(true) }
  var settings = Settings()
  settings.persistHistory = true
  settings.interval = 1
  settings.readouts = [.cpu]
  settings.styles[Module.cpu.rawValue] = .history
  worker.setHistoryRange(.fourWeeks)
  worker.start(settings)
  try await waitForPersistence {
    latest?.storage.restored == true && (latest?.samples ?? 0) >= 2 && liveCount > 0
  }
  #expect(!store.calls.contains("write"))
  worker.setSleeping(true)
  worker.setHistoryRange(.fourWeeks)
  try await waitForPersistence { latest?.storage.savedAt != nil }
  #expect(store.calls.filter { $0 == "write" }.count == 1)
  let saved = try SessionHistory(checkpoint: #require(store.data), now: Date())
  #expect(saved.projection(.fourWeeks).samples >= 2)
  var cleared = false
  worker.clearHistory { cleared = true }
  try await waitForPersistence { cleared && latest?.samples == 0 }
  worker.setSleeping(false)
  try await waitForPersistence { liveCount >= 2 && latest?.samples == 1 }
  var finished = false
  worker.finishHistory { finished = true }
  try await waitForPersistence { finished }
  #expect(store.calls.filter { $0 == "remove" }.count == 1)
}

@Test @MainActor
func historyPersistenceWorkerFailedClearPublishesFailureBlocksWritesAndRecoversOnRetry()
  async throws
{
  let saved = persistenceArchive(at: Date() - 10).checkpoint()
  let store = PersistenceStoreFixture(saved)
  store.failRemoves(.system(13))
  let sampler = PersistenceSamplerFixture()
  var latest: HistoryProjection?
  let worker = MonitorWorker(
    makeSampler: { _ in sampler },
    historyStore: { create in
      store.opened(create)
      return store
    },
    powerState: { false }, history: { latest = $0 }, receive: { _, _, _ in })
  defer { worker.setPaused(true) }
  var settings = Settings()
  settings.persistHistory = true
  settings.interval = 1
  worker.setPaused(true)
  worker.start(settings)
  worker.setHistoryRange(.fourWeeks)
  try await waitForPersistence { latest?.storage.restored == true && latest?.samples == 1 }

  var failedClearFinished = false
  worker.clearHistory { failedClearFinished = true }
  try await waitForPersistence {
    failedClearFinished && latest?.samples == 0 && latest?.storage.removalFailed == true
  }
  #expect(latest?.storage.issue == .io(13) && latest?.storage.enabled == true)
  #expect(store.data == saved && !store.calls.contains("write"))

  worker.setPaused(false)
  try await waitForPersistence { (latest?.samples ?? 0) > 0 }
  worker.setPaused(true)
  worker.setSleeping(true)
  // A different requested range is an observable queue barrier after the forced sleep save.
  worker.setHistoryRange(.hour)
  try await waitForPersistence { latest?.range == .hour }
  #expect(store.data == saved && !store.calls.contains("write"))
  #expect(latest?.storage.removalFailed == true && latest?.storage.issue == .io(13))

  store.failRemoves(nil)
  var retryFinished = false
  worker.clearHistory { retryFinished = true }
  try await waitForPersistence {
    retryFinished && latest?.samples == 0 && latest?.storage.removalFailed == false
  }
  #expect(store.data == nil && latest?.storage.issue == nil && latest?.storage.enabled == true)

  worker.setPaused(false)
  worker.setSleeping(false)
  try await waitForPersistence { (latest?.samples ?? 0) > 0 }
  var finished = false
  worker.finishHistory { finished = true }
  try await waitForPersistence { finished }
  #expect(store.calls.filter { $0 == "remove" }.count == 2)
  #expect(store.calls.filter { $0 == "write" }.count == 1)
  let recovered = try SessionHistory(checkpoint: #require(store.data), now: Date())
  #expect(recovered.projection(.hour).samples > 0)
}

@Test @MainActor func historyQuitDeadlineRepliesDuringStalledFlushAndLateCompletionDoesNotRearm()
  async throws
{
  let gate = DispatchSemaphore(value: 0)
  defer { gate.signal() }
  let store = PersistenceStoreFixture(writeGate: gate)
  let sampler = PersistenceSamplerFixture()
  var deliveries = 0
  let worker = MonitorWorker(
    makeSampler: { _ in sampler },
    historyStore: { create in
      store.opened(create)
      return store
    },
    powerState: { false }, receive: { _, _, _ in deliveries += 1 })
  var settings = Settings()
  settings.persistHistory = true
  worker.start(settings)
  try await waitForPersistence { deliveries > 0 }
  var replies = 0
  let quit = HistoryQuitCoordinator { replies += 1 }
  quit.begin { worker.finishHistory(completion: $0) }
  try await waitForPersistence { store.calls.contains("write") }
  runHistoryTerminationMode { quit.replied }
  #expect(replies == 1)
  let before = sampler.samples
  worker.update(settings)
  worker.setSleeping(false)
  worker.powerChanged()
  var drained = false
  worker.finishHistory { drained = true }
  gate.signal()
  try await waitForPersistence { drained }
  #expect(replies == 1 && sampler.samples == before)
  #expect(store.calls.filter { $0 == "write" }.count == 1)
  let recovered = try SessionHistory(checkpoint: #require(store.data), now: Date())
  #expect(recovered.projection(.hour).samples > 0)
}

private final class ArchiveReadStore: HistoryCheckpointStore, @unchecked Sendable {
  private let lock = NSLock()
  private let archive: SessionHistory
  private var counts = (archive: 0, data: 0)
  var archiveReads: Int { lock.withLock { counts.archive } }
  var dataReads: Int { lock.withLock { counts.data } }
  init(_ archive: SessionHistory) { self.archive = archive }
  func read() throws -> Data? {
    lock.withLock { counts.data += 1 }
    throw HistoryFileError.invalidSize
  }
  func readHistory(now: Date) throws -> SessionHistory? {
    lock.withLock { counts.archive += 1 }
    return archive
  }
  func write(_ data: Data) throws {}
  func remove() throws {}
}
@Test func historyPersistenceRestoresThroughArchiveProtocolWithoutMaterializingData() throws {
  let now = Date()
  let original = persistenceArchive(at: now)
  let store = ArchiveReadStore(original)
  let persistence = HistoryPersistence { _ in store }
  let loaded = persistence.begin(enabled: true, now: now, uptime: 0)
  #expect(loaded?.checkpoint() == original.checkpoint() && persistence.state.restored)
  #expect(store.archiveReads == 1 && store.dataReads == 0)
}

@Test func historyPersistenceLocalRejectedArchiveBlocksForcedSavesUntilExplicitClear() throws {
  let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
  defer { free(pointer) }
  let root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let now = Date()
  for unsupported in [false, true] {
    let directory = root.appendingPathComponent(unsupported ? "unsupported" : "corrupt")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var archive = persistenceArchive(at: now)
    var invalid = archive.checkpoint()
    if unsupported {
      invalid[8] = 4
      var crc: UInt32 = .max
      for byte in invalid.dropLast(4) {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
      }
      var little = (crc ^ .max).littleEndian
      withUnsafeBytes(of: &little) {
        invalid.replaceSubrange((invalid.count - 4)..<invalid.count, with: $0)
      }
    } else {
      invalid[invalid.count - 1] ^= 1
    }
    let file = directory.appendingPathComponent("history-v1.bin")
    try invalid.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let persistence = HistoryPersistence { create in
      try LocalHistoryCheckpointStore(directory: directory, create: create)
    }
    let expected: HistoryStorageIssue = unsupported ? .unsupportedSchema : .unreadable
    #expect(persistence.begin(enabled: true, now: now, uptime: 0) == nil)
    #expect(persistence.state.issue == expected)
    persistence.markDirty()
    persistence.checkpoint(archive, now: now, uptime: 1000, force: true)
    #expect(try Data(contentsOf: file) == invalid)
    persistence.setEnabled(false, archive: &archive, now: now, uptime: 1001)
    persistence.setEnabled(true, archive: &archive, now: now, uptime: 1002)
    #expect(try persistence.state.issue == expected && Data(contentsOf: file) == invalid)
    persistence.clear(uptime: 1003)
    persistence.markDirty()
    persistence.checkpoint(archive, now: now, uptime: 1004, force: true)
    let restored = try SessionHistory(checkpoint: Data(contentsOf: file), now: now)
    #expect(restored.checkpoint() == archive.checkpoint() && persistence.state.issue == nil)
    #expect(persistence.state.savedAt == now)
  }
  #expect(HistoryStorageIssue.from(HistoryFileError.invalidSize) == .unreadable)
  #expect(HistoryStorageIssue.from(HistoryCheckpointError.invalidData) == .unreadable)
}
