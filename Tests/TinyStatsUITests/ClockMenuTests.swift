import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func clockViews(_ root: NSView) -> [NSView] {
  var result = root.subviews
  for view in root.subviews { result.append(contentsOf: clockViews(view)) }
  return result
}
@MainActor private func clockControl<T: NSView>(_ root: NSView, _ label: String, as type: T.Type)
  throws -> T
{
  try #require(clockViews(root).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label })
}
@MainActor private func clockAction(_ control: NSControl) throws {
  #expect(
    NSApplication.shared.sendAction(try #require(control.action), to: control.target, from: control)
  )
}
private func clockDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Test @MainActor func clockRendererHonorsZonesDSTExplicitHoursAndLiteralEscapes() {
  let locale = Locale(identifier: "en_US_POSIX")
  let calendar = Calendar(identifier: .gregorian)
  let entry = ClockMenuEntry(
    name: "LA team", zone: "America/Los_Angeles", firstLine: "{name} {weekday} {{ok}}",
    secondLine: "{hour12}:{minute}:{second} {period} {offset}")
  let first = ClockMenuRenderer.lines(
    entry, at: clockDate("2026-11-01T08:30:09Z"), locale: locale, calendar: calendar)
  let second = ClockMenuRenderer.lines(
    entry, at: clockDate("2026-11-01T09:30:09Z"), locale: locale, calendar: calendar)
  #expect(first.0 == "LA team Sun {ok}" && first.1 == "1:30:09 AM -07:00")
  #expect(second.1 == "1:30:09 AM -08:00")
  let midnight = ClockMenuRenderer.lines(
    .init(zone: "UTC", firstLine: "{year}-{month}-{day}", secondLine: "{hour24}:{minute}:{second}"),
    at: clockDate("2026-01-01T00:05:09Z"), locale: locale, calendar: calendar)
  #expect(midnight.0 == "2026-01-01" && midnight.1 == "00:05:09")
  let quarter = ClockMenuRenderer.lines(
    .init(zone: "Asia/Kathmandu", firstLine: "{hour24}:{minute} {offset}", secondLine: ""),
    at: clockDate("2026-01-01T00:00:00Z"), locale: locale, calendar: calendar)
  #expect(quarter.0 == "05:45 +05:45" && quarter.1 == nil)
}

@Test @MainActor func clockRendererBoundsNativeCachesOutputAndInvalidDates() {
  ClockMenuRenderer.invalidate()
  let date = clockDate("2026-01-01T12:00:00Z")
  for value in TimeZone.knownTimeZoneIdentifiers.prefix(20) {
    _ = ClockMenuRenderer.lines(.init(zone: value), at: date)
    #expect(ClockMenuRenderer.cachedCount <= 12)
  }
  let repeated = ClockMenuRenderer.lines(
    .init(
      name: String(repeating: "x", count: 48), firstLine: String(repeating: "{name}", count: 16),
      secondLine: ""), at: date)
  #expect(repeated.0.count == 128 && repeated.0.hasSuffix("…"))
  #expect(ClockMenuRenderer.lines(.init(), at: Date(timeIntervalSince1970: .nan)).0 == "—")
  ClockMenuRenderer.invalidate()
  #expect(ClockMenuRenderer.cachedCount == 0)
  var settings = Settings()
  settings.clockMenu.custom = true
  for style in [MenuBarStyle.icon, .label] {
    settings.styles["clock"] = style
    _ = MenuBarReadout.makeAll(
      module: .clock, snapshot: Snapshot(), settings: settings, history: [])
    #expect(ClockMenuRenderer.cachedCount == 0)
  }
}

@Test @MainActor func explicitClockTokensAvoidUnusedNativeFormatters() {
  ClockMenuRenderer.invalidate()
  let date = clockDate("2026-01-01T00:05:09Z")
  let locale = Locale(identifier: "en_US_POSIX")
  let calendar = Calendar(identifier: .gregorian)
  func render(_ first: String, _ second: String = "") -> (String, String?) {
    ClockMenuRenderer.lines(
      .init(name: "Build", zone: "UTC", firstLine: first, secondLine: second), at: date,
      locale: locale, calendar: calendar)
  }
  let numeric = render("{name} {year}-{month}-{day}", "{hour24}:{minute}:{second} {offset}")
  #expect(numeric.0 == "Build 2026-01-01" && numeric.1 == "00:05:09 +00:00")
  #expect(ClockMenuRenderer.cachedCount == 1 && ClockMenuRenderer.cachedFormatterCount == 0)
  #expect(render("{weekday} {monthName}").0 == "Thu Jan")
  #expect(ClockMenuRenderer.cachedFormatterCount == 1)
  #expect(render("{weekdayLong} {monthLong} {period}").0 == "Thursday January AM")
  #expect(ClockMenuRenderer.cachedFormatterCount == 1)
  #expect(!render("{systemTime}").0.isEmpty)
  #expect(ClockMenuRenderer.cachedFormatterCount == 2)
  #expect(!render("{systemTimeSeconds}").0.isEmpty)
  #expect(ClockMenuRenderer.cachedFormatterCount == 3)
  ClockMenuRenderer.invalidate()
  #expect(ClockMenuRenderer.cachedCount == 0 && ClockMenuRenderer.cachedFormatterCount == 0)
}

@Test @MainActor func multipleClockReadoutsUseTheActualStylesAndNeverAlterSampleDates() {
  var settings = Settings()
  var snapshot = Snapshot()
  snapshot.timestamp = clockDate("2026-01-01T00:00:00Z")
  settings.clockMenu = .init(
    custom: true,
    entries: [
      .init(zone: "UTC", firstLine: "UTC", secondLine: "{hour24}:{minute}:{second}"),
      .init(zone: "Asia/Kathmandu", firstLine: "{hour24}:{minute}", secondLine: ""),
    ])
  let date = snapshot.timestamp.addingTimeInterval(1)
  let readouts = MenuBarReadout.makeAll(
    module: .clock, snapshot: snapshot, settings: settings, history: [], clockDate: date)
  #expect(readouts.count == 2 && readouts[0].secondary == "00:00:01")
  #expect(readouts[0].style == .stacked && readouts[1].style == .value)
  #expect(readouts[1].value == "05:45" && snapshot.timestamp != date)
  #expect(
    MenuBarReadout.make(
      module: .clock, snapshot: snapshot, settings: settings, history: [], clockDate: date
    ).secondary == readouts[0].secondary)
}

@Test @MainActor func clockEditorKeepsDraftsAtomicAndUsesOnlySharedClockDemand() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.theme = .dark
  settings.clockMenu.entries[0].zone = "UTC"
  let editor = ClockMenuController(settings: settings, date: clockDate("2026-01-01T00:00:00Z"))
  defer { editor.close() }
  var saved: ClockMenuSettings?
  var demands: [Bool?] = []
  editor.onChange = { saved = $0 }
  editor.onPreviewDemand = { demands.append($0) }
  editor.updateMenuBarContext(appearance: NSAppearance(named: .aqua), height: 22, paused: false)
  editor.showWindow(nil)
  let root = try #require(editor.window?.contentView)
  let checkbox = try #require(
    clockViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Use custom clock formats" }
  )
  checkbox.state = .on
  try clockAction(checkbox)
  let preset: NSPopUpButton = try clockControl(root, "Clock format preset", as: NSPopUpButton.self)
  preset.selectItem(withTitle: "Time with seconds")
  try clockAction(preset)
  #expect(saved == nil && demands.last! == true)
  let preview = try #require(clockViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(preview.appearance?.name == .aqua && editor.window?.appearance?.name == .darkAqua)
  #expect(preview.renderers.first?.readouts.first?.secondary == "00:00:00")
  let zone: NSTextField = try clockControl(root, "Time zone", as: NSTextField.self)
  zone.stringValue = "UTC"
  editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: zone))
  editor.updateClock(clockDate("2026-01-01T00:00:01Z"))
  #expect(preview.renderers.first?.readouts.first?.secondary == "00:00:01")
  let save = try #require(
    clockViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Save clocks" })
  try clockAction(save)
  #expect(saved?.custom == true && saved?.entries.first?.zone == "UTC")
  zone.stringValue = "bad/zone"
  editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: zone))
  #expect(!save.isEnabled && preview.renderers.first?.readouts.isEmpty == true)
  #expect(saved?.entries.first?.zone == "UTC")
  #expect(settings.readouts == [.cpu, .memory, .network])
  editor.close()
  #expect(demands.last! == nil)
}

@Test @MainActor func graphicClockPresetsUseTheRealPreviewAndReleaseSecondDemand() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.clockMenu.entries[0].zone = "UTC"
  let editor = ClockMenuController(settings: settings, date: clockDate("2026-01-01T03:30:30Z"))
  defer { editor.close() }
  var demands: [Bool?] = []
  var saved: ClockMenuSettings?
  editor.onPreviewDemand = { demands.append($0) }
  editor.onChange = { saved = $0 }
  editor.showWindow(nil)
  let root = try #require(editor.window?.contentView)
  let custom = try #require(
    clockViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Use custom clock formats" }
  )
  custom.state = .on
  try clockAction(custom)
  let preset: NSPopUpButton = try clockControl(root, "Clock format preset", as: NSPopUpButton.self)
  let preview = try #require(clockViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
  preset.selectItem(withTitle: "Analogue with seconds")
  try clockAction(preset)
  let reading = try #require(preview.renderers.first?.readouts.first)
  let expectedDial = try #require(ClockDialReading(hour: 3, minute: 30, second: 30))
  #expect(reading.clock?.first.parts == [.dial(expectedDial)])
  #expect(reading.style == .value && demands.last! == true && saved == nil)
  preset.selectItem(withTitle: "Calendar + analogue")
  try clockAction(preset)
  #expect(demands.last! == false)
  #expect(preview.renderers.first?.readouts.first?.clock?.first.parts.first == .calendar(1))
  preset.selectItem(withTitle: "Fuzzy time")
  try clockAction(preset)
  #expect(preview.renderers.first?.readouts.first?.value == "half past three")
  settings.styles["clock"] = .icon
  editor.updateSettings(settings)
  #expect(demands.last! == nil && preview.renderers.first?.readouts.first?.clock == nil)
  #expect(settings.readouts == [.cpu, .memory, .network] && saved == nil)
}

@Test @MainActor func clockTickAdvancesCalendarAcrossMidnightWithoutChangingHardwareHistory() throws
{
  let calendar = Calendar.current
  let noon = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 22, hour: 12)))
  let nextDay = try #require(
    calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: noon)))
  var snapshot = Snapshot()
  snapshot.timestamp = nextDay.addingTimeInterval(-1)
  let detail = DetailController()
  detail.selected = .clock
  detail.update(snapshot, history: [snapshot.historyPoint])
  let picker = try #require(clockViews(detail.view).compactMap { $0 as? MonthCalendarView }.first)
  #expect(calendar.isDate(picker.selectedDate, inSameDayAs: snapshot.timestamp))
  #expect(detail.updateClock(nextDay.addingTimeInterval(1)))
  #expect(calendar.isDate(picker.selectedDate, inSameDayAs: nextDay))
  #expect(detail.snapshot.timestamp == snapshot.timestamp)
  #expect(detail.history.count == 1 && detail.history.first?.time == snapshot.timestamp)
  picker.selectDate(snapshot.timestamp)
  let anotherDay = try #require(calendar.date(byAdding: .day, value: 1, to: nextDay))
  #expect(detail.updateClock(anotherDay))
  #expect(calendar.isDate(picker.selectedDate, inSameDayAs: snapshot.timestamp))
}

@Test @MainActor func clockDraftOrderLimitsRevertAndUnrelatedSettingsChanges() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.clockMenu = .init(custom: true, entries: [.init(name: "Home", zone: "UTC")])
  let editor = ClockMenuController(settings: settings, date: clockDate("2026-01-01T00:00:00Z"))
  defer { editor.close() }
  var saved: ClockMenuSettings?
  editor.onChange = { saved = $0 }
  editor.showWindow(nil)
  let root = try #require(editor.window?.contentView)
  let name: NSTextField = try clockControl(root, "Clock name", as: NSTextField.self)
  let add: NSButton = try clockControl(root, "Add clock", as: NSButton.self)
  let remove: NSButton = try clockControl(root, "Remove clock", as: NSButton.self)
  let left: NSButton = try clockControl(root, "Move clock left", as: NSButton.self)
  let choices: NSPopUpButton = try clockControl(root, "Clock to edit", as: NSPopUpButton.self)
  let save = try #require(
    clockViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Save clocks" })
  #expect(!remove.isEnabled)
  name.stringValue = "Unsaved Home"
  editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: name))
  settings.theme = .dark
  settings.appearances["clock"] = .init(size: .large)
  editor.updateSettings(settings)
  #expect(name.stringValue == "Unsaved Home" && saved == nil)
  #expect(editor.window?.appearance?.name == .darkAqua)
  try clockAction(add)
  name.stringValue = "Team"
  editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: name))
  try clockAction(left)
  #expect(choices.indexOfSelectedItem == 0 && name.stringValue == "Team")
  choices.selectItem(at: 1)
  try clockAction(choices)
  #expect(name.stringValue == "Unsaved Home")
  try clockAction(save)
  #expect(saved?.entries.map(\.name) == ["Team", "Unsaved Home"])
  for _ in 0..<4 { try clockAction(add) }
  #expect(choices.numberOfItems == 6 && !add.isEnabled)
  try clockAction(remove)
  #expect(choices.numberOfItems == 5 && add.isEnabled)
  let revert = try #require(
    clockViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Revert draft" })
  try clockAction(revert)
  #expect(choices.numberOfItems == 2 && name.stringValue == "Unsaved Home")
  #expect(saved?.entries.count == 2)
}

@Test @MainActor func clockEditorSaveReachesMenuBarPreviewWithoutEnablingTimeAndClosesWithParent()
  throws
{
  _ = NSApplication.shared
  var settings = Settings()
  settings.calendarEvents = false
  let parent = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { parent.close() }
  var saved: Settings?
  var demands: [Bool?] = []
  parent.onChange = { saved = $0 }
  parent.onClockPreview = { demands.append($0) }
  let root = try #require(parent.window?.contentView)
  let formats: NSButton = try clockControl(root, "Clock menu bar formats", as: NSButton.self)
  try clockAction(formats)
  let editor = try #require(
    NSApp.windows.first { $0.title == "Clock Menu Bar Formats" && $0.isVisible }?.windowController
      as? ClockMenuController)
  let child = try #require(editor.window?.contentView)
  let checkbox = try #require(
    clockViews(child).compactMap { $0 as? NSButton }.first {
      $0.title == "Use custom clock formats"
    })
  checkbox.state = .on
  try clockAction(checkbox)
  let first: NSTextField = try clockControl(child, "First line", as: NSTextField.self)
  first.stringValue = "Team {hour24}:{minute}:{second}"
  editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: first))
  let save = try #require(
    clockViews(child).compactMap { $0 as? NSButton }.first { $0.title == "Save clocks" })
  try clockAction(save)
  let actual = try #require(saved)
  #expect(actual.clockMenu.custom && actual.clockMenu.entries[0].firstLine == first.stringValue)
  #expect(actual.readouts == settings.readouts && !actual.readouts.contains(.clock))
  #expect(
    !actual.calendarEvents && !actual.connectivityChecks && !actual.publicIPChecks
      && !actual.weather.enabled)
  #expect(demands.last! == true)
  let preview = try #require(clockViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(preview.renderers.flatMap(\.readouts).count == settings.readouts.count)
  parent.close()
  #expect(editor.window?.isVisible == false && demands.last! == nil)
}
