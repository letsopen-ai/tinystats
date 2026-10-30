import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

@Test @MainActor func calendarSelectionHandlesLeapMonthAndNativeDayButtons() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let january = try #require(calendar.date(from: .init(year: 2028, month: 1, day: 31)))
  let view = MonthCalendarView(
    frame: .init(x: 0, y: 0, width: 300, height: 130), calendar: calendar, date: january)
  var selections: [Date] = []
  view.onSelect = { selections.append($0) }
  view.moveMonth(by: 1)
  #expect(calendar.component(.month, from: view.selectedDate) == 2)
  #expect(calendar.component(.day, from: view.selectedDate) == 29)
  let days = view.subviews.compactMap { $0 as? NSButton }.filter {
    !$0.isHidden && $0.controlSize == .mini
  }
  #expect(days.count == 29)
  let first = try #require(days.first { $0.title == "1" })
  // Exercise native target/action without an offscreen button's animation/run-loop delay.
  let action = try #require(first.action)
  #expect(NSApplication.shared.sendAction(action, to: first.target, from: first))
  #expect(calendar.component(.day, from: view.selectedDate) == 1)
  #expect(first.accessibilityLabel()?.contains("2028") == true)
  #expect(selections.count == 2)
  view.moveMonth(by: -1)
  #expect(calendar.component(.month, from: view.selectedDate) == 1)
  #expect(calendar.component(.day, from: view.selectedDate) == 1)
}

@Test @MainActor func calendarChildChangesSurviveUnrelatedParentPreferenceEdits() throws {
  let preferences = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  preferences.updateCalendarSettings(enabled: true, selectedIDs: ["selected"])
  preferences.updateCalendarFirstWeekday(2)
  var saved: Settings?
  preferences.onChange = { saved = $0 }
  func descendants(_ root: NSView) -> [NSView] {
    var result = root.subviews
    for child in root.subviews { result.append(contentsOf: descendants(child)) }
    return result
  }
  let content = try #require(preferences.window?.contentView)
  let fahrenheit = try #require(
    descendants(content).compactMap { $0 as? SystemSettingSwitch }.first {
      $0.title == "Use Fahrenheit"
    })
  let action = try #require(fahrenheit.action)
  fahrenheit.state = .on
  #expect(NSApplication.shared.sendAction(action, to: fahrenheit.target, from: fahrenheit))
  #expect(saved?.calendarEvents == true && saved?.calendarIDs == ["selected"])
  #expect(saved?.calendarFirstWeekday == 2)
  preferences.updateCalendarSettings(enabled: false, selectedIDs: [])
  preferences.updateCalendarFirstWeekday(nil)
  fahrenheit.state = .off
  #expect(NSApplication.shared.sendAction(action, to: fahrenheit.target, from: fahrenheit))
  #expect(saved?.calendarEvents == false && saved?.calendarIDs == [])
  #expect(saved?.calendarFirstWeekday == nil)
}

@Test @MainActor func pinnedCalendarDaySurvivesTimeZoneChangesWhileTodayFollows() throws {
  var shanghai = Calendar(identifier: .gregorian)
  shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  var losAngeles = shanghai
  losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  let now = try #require(shanghai.date(from: .init(year: 2026, month: 10, day: 22, hour: 12)))
  let pinned = try #require(shanghai.date(from: .init(year: 2026, month: 10, day: 23)))
  let view = MonthCalendarView(frame: .zero, calendar: shanghai, date: now)
  view.selectDate(pinned)
  view.updateToday(now, calendar: losAngeles)
  #expect(losAngeles.component(.day, from: view.selectedDate) == 23)
  view.updateToday(now, calendar: shanghai)
  #expect(shanghai.component(.day, from: view.selectedDate) == 23)
  let following = MonthCalendarView(frame: .zero, calendar: shanghai, date: now)
  following.updateToday(now, calendar: losAngeles)
  #expect(losAngeles.isDate(following.selectedDate, inSameDayAs: now))
  let tomorrow = now.addingTimeInterval(86400)
  following.updateToday(tomorrow, calendar: losAngeles)
  #expect(losAngeles.isDate(following.selectedDate, inSameDayAs: tomorrow))
}

@Test @MainActor func agendaRendersSyntheticEventsAndSelectionUpdatesImmediately() throws {
  let calendar = Calendar.current
  let date = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 22, hour: 12)))
  let day = try #require(calendar.dateInterval(of: .day, for: date))
  let controller = DetailController()
  controller.settings.calendarEvents = true
  controller.snapshot.timestamp = date
  controller.calendarSnapshot.access = .fullAccess
  controller.calendarSnapshot.day = day
  controller.calendarSnapshot.selectedCalendarCount = 1
  controller.calendarSnapshot.events = [
    .init(
      id: "holiday", title: "Release day", calendarTitle: "Team", start: day.start, end: day.end,
      allDay: true),
    .init(
      id: "meeting", title: "Engineering review", calendarTitle: "Team",
      start: day.start.addingTimeInterval(36000), end: day.start.addingTimeInterval(39600),
      allDay: false),
  ]
  controller.selected = .clock
  let view = controller.view
  let picker = try #require(view.subviews.compactMap { $0 as? MonthCalendarView }.first)
  picker.selectDate(date)
  let table = try #require(
    view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  func texts() -> [String] {
    (0..<table.numberOfRows).flatMap { row in
      (0..<2).compactMap { column in
        (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
      }
    }
  }
  #expect(texts().contains("Release day"))
  #expect(texts().contains("Engineering review"))
  #expect(texts().contains("All day · Team"))
  if let path = ProcessInfo.processInfo.environment["TINYSTATS_CALENDAR_GALLERY"] {
    let gallery = AgendaGallery(frame: view.bounds)
    gallery.appearance = NSAppearance(named: .aqua)
    gallery.addSubview(view)
    let image = try #require(gallery.bitmapImageRepForCachingDisplay(in: gallery.bounds))
    gallery.cacheDisplay(in: gallery.bounds, to: image)
    let data = try #require(image.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
  controller.settings.calendarEvents = false
  picker.selectDate(day.end)
  #expect(texts().contains { $0.hasPrefix("Agenda") && $0.contains("23") })
  #expect(!texts().contains("Engineering review"))
}

@MainActor private final class AgendaGallery: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}
