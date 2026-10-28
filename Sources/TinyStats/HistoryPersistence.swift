import Foundation
import TinyStatsCore

/// All methods run on the collector queue. No timers or background backlog. An explicit Off choice performs no store access.
final class HistoryPersistence {
  typealias Factory = @Sendable (_ create: Bool) throws -> (any HistoryCheckpointStore)?
  private let factory: Factory
  private var store: (any HistoryCheckpointStore)?
  private var blocked = false
  private var dirty = false
  private var nextCheckpoint: Double = .infinity
  private(set) var state = HistoryStorageState()
  init(factory: @escaping Factory = { _ in nil }) { self.factory = factory }

  func begin(enabled: Bool, now: Date, uptime: Double) -> SessionHistory? {
    guard enabled else { return nil }
    state.enabled = true
    nextCheckpoint = uptime + 300
    do {
      guard let opened = try factory(true) else {
        blocked = true
        state.issue = .unavailable
        return nil
      }
      store = opened
      state.excludedFromBackup = opened.excludedFromBackup
      guard let archive = try opened.readHistory(now: now) else { return nil }
      state.restored = archive.retainedBucketCount > 0
      return archive
    } catch {
      blocked = true
      state.issue = .from(error)
      return nil
    }
  }
  func setEnabled(_ enabled: Bool, archive: inout SessionHistory, now: Date, uptime: Double) {
    if !enabled {
      // Off pauses saving without deleting a potentially valuable checkpoint.
      store = nil
      blocked = false
      dirty = false
      state = HistoryStorageState()
      return
    }
    store = nil
    blocked = false
    state = HistoryStorageState()
    if let older = begin(enabled: true, now: now, uptime: uptime) {
      state.restored = archive.mergeOlder(older, now: now)
    }
    dirty = archive.retainedBucketCount > 0
    checkpoint(archive, now: now, uptime: uptime, force: true)
  }
  func markDirty() { if state.enabled { dirty = true } }
  func checkpoint(_ archive: SessionHistory, now: Date, uptime: Double, force: Bool = false) {
    guard state.enabled, dirty, !blocked, let store,
      force || uptime >= nextCheckpoint
    else { return }
    nextCheckpoint = uptime + 300
    do {
      try store.write(archive)
      dirty = false
      state.savedAt = now
      state.issue = nil
      state.removalFailed = false
    } catch { state.issue = .from(error) }
  }
  func clear(uptime: Double) {
    removeSaved(enabled: state.enabled)
    nextCheckpoint = uptime + 300
  }
  private func removeSaved(enabled: Bool) {
    do {
      // Explicit confirmed Clear only. Never called by loading a default/corrupt settings blob.
      if let opened = try store ?? factory(enabled) {
        try opened.remove()
        store = enabled ? opened : nil
      } else if enabled {
        throw HistoryStorageIssue.unavailable
      }
      blocked = false
      dirty = false
      state = HistoryStorageState()
      state.enabled = enabled
      state.excludedFromBackup = store?.excludedFromBackup
      if !enabled { store = nil }
    } catch {
      blocked = true
      dirty = false
      state.enabled = enabled
      state.issue = .from(error)
      state.removalFailed = true
      if !enabled { store = nil }
    }
  }
}
