import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

@MainActor private func worldViews(_ root: NSView) -> [NSView] {
  var result = root.subviews
  for view in root.subviews { result.append(contentsOf: worldViews(view)) }
  return result
}
@MainActor private func worldAction(_ control: NSControl) throws {
  let action = try #require(control.action)
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
}

@Test @MainActor func worldClockPreviewMatchesDetailsAndSavesOnlyValidDrafts() throws {
  var settings = Settings()
  settings.worldClocks = ["UTC", "America/Los_Angeles"]
  settings.worldClockNames = ["UTC": String(repeating: "🌍", count: 32)]
  settings.worldClockFormat = "{name} {hour24}:{minute}:{second} {offset}"
  let date = try #require(ISO8601DateFormatter().date(from: "2026-11-01T09:30:09Z"))
  let controller = WorldClockController(settings: settings, date: date)
  defer { controller.close() }
  var saved: [String] = []
  var demands: [Bool?] = []
  controller.onChange = { saved.append($0) }
  controller.onPreviewDemand = { demands.append($0) }
  controller.showWindow(nil)
  let views = worldViews(try #require(controller.window?.contentView))
  let field = try #require(
    views.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "World clock format"
    })
  let save = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Save format" })
  let table = try #require(views.compactMap { $0 as? NSTableView }.first)
  #expect(demands.last == true)
  let actual = ClockMenuRenderer.worldClockRows(settings: settings, at: date)
  #expect(actual[0].value.hasPrefix(String(repeating: "🌍", count: 32)))
  #expect(actual[1].value.hasSuffix("01:30:09 -08:00"))
  var damaged = settings
  damaged.worldClockNames = ["UTC": "A\u{2028}B"]
  let repaired = ClockMenuRenderer.worldClockRows(settings: damaged, at: date)
  #expect(repaired[0].label == "UTC" && repaired[0].value == "UTC 09:30:09 +00:00")
  let detail = DetailController()
  detail.settings = settings
  detail.selected = .clock
  let detailTable = try #require(worldViews(detail.view).compactMap { $0 as? NSTableView }.first)
  var snapshot = Snapshot()
  snapshot.timestamp = date
  detail.update(snapshot, history: [])
  for index in actual.indices {
    let preview = try #require(
      controller.tableView(table, viewFor: table.tableColumns[1], row: index) as? NSTextField)
    #expect(preview.stringValue == actual[index].value)
    let detailIndex = try #require(
      (0..<detail.numberOfRows(in: detailTable)).first { row in
        (detail.tableView(detailTable, viewFor: detailTable.tableColumns[0], row: row)
          as? NSTextField)?.stringValue == actual[index].label
      })
    let cell = try #require(
      detail.tableView(detailTable, viewFor: detailTable.tableColumns[1], row: detailIndex)
        as? NSTextField)
    #expect(preview.stringValue == cell.stringValue && preview.font == cell.font)
    #expect(preview.alignment == cell.alignment && preview.lineBreakMode == cell.lineBreakMode)
    // Responsive detail and compact preview windows have different available value widths.
    #expect(table.tableColumns[0].width == detailTable.tableColumns[0].width)
    #expect(table.tableColumns[1].width > 0 && detailTable.tableColumns[1].width > 0)
  }
  #expect(detail.updateClock(date.addingTimeInterval(1)))
  detail.settings.worldClockFormat = WorldClockFormat.standard
  #expect(!detail.updateClock(date.addingTimeInterval(2)))
  field.stringValue = "{bad}"
  controller.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: field))
  #expect(!save.isEnabled && controller.numberOfRows(in: table) == 0)
  try worldAction(save)
  #expect(saved.isEmpty && demands.last! == nil)
  field.stringValue = "时钟 {hour24}:{minute} {{ok}}"
  controller.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: field))
  #expect(save.isEnabled && demands.last == false)
  settings.theme = .dark
  controller.updateSettings(settings)
  #expect(field.stringValue == "时钟 {hour24}:{minute} {{ok}}")
  try worldAction(save)
  #expect(saved == [field.stringValue])
  let window = try #require(controller.window)
  let editor = try #require(
    controller.windowWillReturnFieldEditor(window, to: field) as? NSTextView)
  #expect(!editor.isAutomaticQuoteSubstitutionEnabled && !editor.isContinuousSpellCheckingEnabled)
  controller.close()
  #expect(demands.last! == nil)
}

@Test @MainActor func clockPreviewDemandsKeepSecondsUntilTheLastSecondsPreviewCloses() {
  for menu in [nil, false, true] as [Bool?] {
    for world in [nil, false, true] as [Bool?] {
      let value = PreferencesController.combinedClockDemand(menu, world)
      if menu == true || world == true {
        #expect(value == true)
      } else if menu != nil || world != nil {
        #expect(value == false)
      } else {
        #expect(value == nil)
      }
    }
  }
}

@Test @MainActor func worldClockFormatSavesThroughParentAndClosesWithSettings() throws {
  let parent = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { parent.close() }
  parent.showWindow(nil)
  var saved: Settings?
  var demand: Bool?
  parent.onChange = { saved = $0 }
  parent.onClockPreview = { demand = $0 }
  let controls = worldViews(try #require(parent.window?.contentView))
  let open = try #require(
    controls.compactMap { $0 as? NSButton }.first { $0.title == "World clock format…" })
  try worldAction(open)
  let editor = try #require(
    NSApp.windows.first { $0.title == "World Clock Format" && $0.isVisible }?.windowController
      as? WorldClockController)
  let child = worldViews(try #require(editor.window?.contentView))
  let field = try #require(
    child.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "World clock format"
    })
  let save = try #require(child.compactMap { $0 as? NSButton }.first { $0.title == "Save format" })
  field.stringValue = "{hour24}:{minute}:{second}"
  editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
  #expect(demand == true)
  try worldAction(save)
  let units = try #require(
    controls.compactMap { $0 as? NSButton }.first { $0.title == "Use Fahrenheit" })
  units.state = .on
  try worldAction(units)
  #expect(saved?.worldClockFormat == field.stringValue && saved?.fahrenheit == true)
  #expect(saved?.readouts == Settings().readouts && saved?.calendarEvents == false)
  parent.close()
  #expect(editor.window?.isVisible == false && demand == nil)
}
