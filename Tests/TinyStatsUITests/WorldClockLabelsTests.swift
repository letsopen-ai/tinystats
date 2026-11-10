import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

@MainActor private func clockDescendants(_ root: NSView) -> [NSView] {
  var result = root.subviews
  for child in root.subviews { result.append(contentsOf: clockDescendants(child)) }
  return result
}

@Test @MainActor func worldClockDraftSavesNamesAtomicallyAndSurvivesUnrelatedSettingsEdits() throws
{
  var initial = Settings()
  initial.worldClocks = ["UTC"]
  initial.worldClockNames = ["UTC": "Build server"]
  let preferences = PreferencesController(
    settings: initial, interfaces: [], snapshot: Snapshot(), history: [])
  let content = try #require(preferences.window?.contentView)
  let controls = clockDescendants(content)
  let input = try #require(
    controls.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "World clock time zones"
    })
  let save = try #require(
    controls.compactMap { $0 as? NSButton }.first { $0.title == "Save clocks" })
  #expect(input.stringValue == "Build server=UTC")
  var saved: [Settings] = []
  preferences.onChange = { saved.append($0) }
  input.stringValue = "London office=Europe/London, Team=Asia/Shanghai"
  preferences.selectMenuBarTab()
  let tabs = try #require(controls.compactMap { $0 as? NSTabView }.first)
  tabs.selectTabViewItem(withIdentifier: "general")
  #expect(
    input.stringValue == "London office=Europe/London, Team=Asia/Shanghai" && saved.isEmpty
  )
  let action = try #require(save.action)
  #expect(NSApplication.shared.sendAction(action, to: save.target, from: save))
  #expect(saved.last?.worldClocks == ["Europe/London", "Asia/Shanghai"])
  #expect(
    saved.last?.worldClockNames == [
      "Europe/London": "London office", "Asia/Shanghai": "Team",
    ])
  input.stringValue = "New=UTC, broken/zone"
  #expect(NSApplication.shared.sendAction(action, to: save.target, from: save))
  #expect(saved.count == 1)
  let fahrenheit = try #require(
    controls.compactMap { $0 as? SystemSettingSwitch }.first { $0.title == "Use Fahrenheit" })
  let unitAction = try #require(fahrenheit.action)
  fahrenheit.state = .on
  #expect(NSApplication.shared.sendAction(unitAction, to: fahrenheit.target, from: fahrenheit))
  #expect(
    saved.last?.worldClockNames == [
      "Europe/London": "London office", "Asia/Shanghai": "Team",
    ])
  #expect(input.stringValue == "New=UTC, broken/zone")
}

@Test @MainActor func namedWorldClockRowsKeepTheirActualZonesAcrossDSTAndFallbackToDefaultNames()
  throws
{
  let controller = DetailController()
  controller.settings.worldClocks = ["America/Los_Angeles", "UTC"]
  controller.settings.worldClockNames = ["America/Los_Angeles": "LA team", "UTC": "bad=name"]
  controller.selected = .clock
  let view = controller.view
  let table = try #require(
    view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  let date = try #require(ISO8601DateFormatter().date(from: "2026-03-08T09:30:00Z"))
  func value(for label: String, at date: Date) throws -> String {
    var snapshot = Snapshot()
    snapshot.timestamp = date
    controller.update(snapshot, history: [])
    for index in 0..<controller.numberOfRows(in: table) {
      let left =
        controller.tableView(table, viewFor: table.tableColumns[0], row: index) as? NSTextField
      if left?.stringValue == label {
        return try #require(
          (controller.tableView(table, viewFor: table.tableColumns[1], row: index) as? NSTextField)?
            .stringValue)
      }
    }
    Issue.record("Missing world-clock row: \(label)")
    return ""
  }
  #expect(try value(for: "LA team", at: date).contains("01:30"))
  #expect(try value(for: "LA team", at: date.addingTimeInterval(3600)).contains("03:30"))
  #expect(try value(for: "UTC", at: date).contains("09:30"))
}
