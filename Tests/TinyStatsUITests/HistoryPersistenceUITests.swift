import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func persistenceControls<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
  (root as? T).map { [$0] } ?? root.subviews.flatMap { persistenceControls(type, in: $0) }
}

@Test @MainActor func historyPersistenceControlsDiscloseScopeBusyStateAndExplicitActions() throws {
  _ = NSApplication.shared
  let controller = HistoryController(module: .network, settings: Settings())
  defer { controller.window?.close() }
  let root = try #require(controller.window?.contentView)
  let buttons = persistenceControls(NSButton.self, in: root)
  let keep = try #require(buttons.first { $0.title == "Keep history between launches" })
  let clear = try #require(buttons.first { $0.title == "Clear history…" })
  #expect(keep.state == .on && keep.isEnabled && clear.isEnabled)
  #expect(keep.toolTip?.contains("pauses saving") == true)
  var changes: [Bool] = []
  var clears = 0
  controller.onPersistence = { changes.append($0) }
  controller.onClear = { clears += 1 }
  keep.performClick(nil)
  #expect(changes == [false] && clears == 0)
  controller.setStorageBusy(true)
  #expect(!keep.isEnabled && !clear.isEnabled)
  NSApp.sendAction(keep.action!, to: keep.target, from: keep)
  NSApp.sendAction(clear.action!, to: clear.target, from: clear)
  #expect(changes == [false] && clears == 0)
  controller.setStorageBusy(false)
  #expect(keep.isEnabled && clear.isEnabled)
  var projection = HistoryProjection(range: .tenMinutes)
  projection.storage.enabled = true
  projection.storage.removalFailed = true
  projection.storage.issue = .io(13)
  controller.update(projection)
  let fields = persistenceControls(NSTextField.self, in: root)
  #expect(fields.contains { $0.stringValue.contains("Could not remove saved history") })
  projection.storage.issue = .unsupportedSchema
  projection.storage.removalFailed = false
  controller.update(projection)
  #expect(fields.contains { $0.stringValue.contains("Unsupported checkpoint format") })
}

@Test @MainActor func historyPersistenceUnavailableProfileDoesNotOfferOwnerStoreFallback() throws {
  let controller = HistoryController(
    module: .cpu, settings: Settings(), persistenceAvailable: false)
  defer { controller.window?.close() }
  let root = try #require(controller.window?.contentView)
  let keep = try #require(
    persistenceControls(NSButton.self, in: root).first {
      $0.title == "Keep history between launches"
    })
  #expect(!keep.isEnabled)
  let fields = persistenceControls(NSTextField.self, in: root)
  #expect(
    fields.contains { $0.stringValue.contains("Saving history is unavailable") })
}

@Test @MainActor func historyPersistenceSurvivesUnrelatedSettingsDrafts() throws {
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { controller.window?.close() }
  var saved: Settings?
  controller.onChange = { saved = $0 }
  let root = try #require(controller.window?.contentView)
  let fahrenheit = try #require(
    persistenceControls(NSButton.self, in: root).first { $0.title == "Use Fahrenheit" })
  controller.updateHistoryPersistence(true)
  fahrenheit.state = .on
  #expect(
    NSApp.sendAction(try #require(fahrenheit.action), to: fahrenheit.target, from: fahrenheit))
  #expect(saved?.persistHistory == true && saved?.fahrenheit == true)
  controller.updateHistoryPersistence(false)
  fahrenheit.state = .off
  #expect(
    NSApp.sendAction(try #require(fahrenheit.action), to: fahrenheit.target, from: fahrenheit))
  #expect(saved?.persistHistory == false && saved?.fahrenheit == false)
}

@Test @MainActor func historyPersistenceRangeChangeRetainsStorageStateAndClearRequiresConfirmation()
  async throws
{
  _ = NSApplication.shared
  let controller = HistoryController(module: .network, settings: Settings())
  defer { controller.window?.close() }
  controller.showWindow(nil)
  let root = try #require(controller.window?.contentView)
  var projection = HistoryProjection(range: .tenMinutes)
  projection.storage.enabled = true
  projection.storage.issue = .unsupportedSchema
  controller.update(projection)
  let range = try #require(
    persistenceControls(NSPopUpButton.self, in: root).first {
      $0.accessibilityLabel() == "History range"
    })
  range.selectItem(at: 1)
  NSApp.sendAction(try #require(range.action), to: range.target, from: range)
  #expect(
    persistenceControls(NSTextField.self, in: root).contains {
      $0.stringValue.contains("Unsupported checkpoint format")
    })
  let clear = try #require(
    persistenceControls(NSButton.self, in: root).first { $0.title == "Clear history…" })
  var clears = 0
  controller.onClear = { clears += 1 }
  for response: NSApplication.ModalResponse in [.alertFirstButtonReturn, .alertSecondButtonReturn] {
    clear.performClick(nil)
    #expect(clears == 0 && !clear.isEnabled)
    let prompt = try #require(controller.clearPrompt)
    controller.window?.endSheet(prompt.window, returnCode: response)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.clearPrompt != nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(controller.clearPrompt == nil && clear.isEnabled)
  }
  #expect(clears == 1)
}
