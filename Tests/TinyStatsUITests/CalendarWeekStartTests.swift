import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func changingWeekStartReflowsDaysWithoutChangingPinnedSelection() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = Locale(identifier: "en_US")
  calendar.timeZone = TimeZone(identifier: "UTC")!
  calendar.firstWeekday = 1
  let today = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 22)))
  let pinned = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 17)))
  let view = MonthCalendarView(frame: .zero, calendar: calendar, date: today)
  view.selectDate(pinned)
  var selectionChanges = 0
  view.onSelect = { _ in selectionChanges += 1 }
  let expectedColumns: [Int: CGFloat] = [1: 168, 2: 126, 3: 84, 4: 42, 5: 0, 6: 252, 7: 210]
  for first in 1...7 {
    view.updateToday(today, calendar: calendar, firstWeekday: first)
    let day = try #require(
      view.subviews.compactMap { $0 as? NSButton }.first {
        $0.controlSize == .mini && !$0.isHidden && $0.title == "1"
      })
    // October 1, 2026 is Thursday.
    #expect(day.frame.minX == expectedColumns[first])
    let header = try #require(
      view.subviews.compactMap { $0 as? NSTextField }.first {
        $0.frame.minX == 0 && $0.frame.minY == 89
      })
    #expect(header.stringValue == calendar.veryShortStandaloneWeekdaySymbols[first - 1])
    #expect(view.selectedDate == pinned)
  }
  // System/default base must replace the last override.
  view.updateToday(today, calendar: calendar)
  let first = try #require(
    view.subviews.compactMap { $0 as? NSButton }.first {
      $0.controlSize == .mini && !$0.isHidden && $0.title == "1"
    })
  #expect(first.frame.minX == 168 && selectionChanges == 0)
  view.updateToday(today, calendar: calendar, firstWeekday: 99)
  #expect(first.frame.minX == 168)
}

@Test @MainActor func calendarLayoutControlWorksWithoutEventsOrPermission() throws {
  _ = NSApplication.shared
  let controller = CalendarSettingsController(enabled: false, selectedIDs: [])
  let root = try #require(controller.window?.contentView)
  let picker = try #require(root.subviews.compactMap { $0 as? NSPopUpButton }.first)
  let preview = try #require(root.subviews.compactMap { $0 as? MonthCalendarView }.first)
  var days: [Int?] = []
  var eventEdits = 0
  var permissionRequests = 0
  controller.onFirstWeekday = { days.append($0) }
  controller.onChange = { _, _ in eventEdits += 1 }
  controller.onPermission = { permissionRequests += 1 }
  var denied = CalendarAgendaSnapshot()
  denied.access = .denied
  controller.update(denied, requesting: false)
  #expect(picker.isEnabled && picker.numberOfItems == 8)
  let scroll = try #require(root.subviews.compactMap { $0 as? NSScrollView }.first)
  #expect(scroll.isHidden && root.frame.height == 480)
  let headingY = picker.frame.minY
  let screenY = try #require(controller.window).frame.minY + headingY
  var available = CalendarAgendaSnapshot()
  available.access = .fullAccess
  available.calendars = [.init(id: "example", title: "Example calendar", source: "Example account")]
  controller.update(available, requesting: false)
  #expect(!scroll.isHidden && root.frame.height == 640)
  #expect(picker.frame.minY == headingY + 160)
  #expect(try #require(controller.window).frame.minY + picker.frame.minY == screenY)
  controller.update(denied, requesting: false)
  #expect(scroll.isHidden && root.frame.height == 480 && picker.frame.minY == headingY)
  #expect(root.subviews.allSatisfy { $0.isHidden || root.bounds.contains($0.frame) })
  let chosen = try #require(Calendar.current.date(from: .init(year: 2026, month: 11, day: 17)))
  controller.selectPreviewDate(chosen)
  let action = try #require(picker.action)
  for day in [2, 7, 0] {
    picker.selectItem(withTag: day)
    #expect(NSApp.sendAction(action, to: picker.target, from: picker))
    let header = try #require(
      preview.subviews.compactMap { $0 as? NSTextField }.first {
        $0.frame.minX == 0 && $0.frame.minY == 89
      })
    let first = day == 0 ? Calendar.current.firstWeekday : day
    #expect(header.stringValue == Calendar.current.veryShortStandaloneWeekdaySymbols[first - 1])
  }
  #expect(days == [2, 7, nil])
  #expect(Calendar.current.isDate(preview.selectedDate, inSameDayAs: chosen))
  #expect(eventEdits == 0 && permissionRequests == 0)
  #expect(
    root.subviews.compactMap { $0 as? NSButton }.first {
      $0.title == "Show calendar events in Date & Time"
    }?.state == .off)
}

@Test @MainActor func timePageUsesSavedWeekLayoutAndOffersCalendarSettings() throws {
  let controller = DetailController()
  controller.settings.calendarFirstWeekday = 2
  controller.selected = .clock
  let root = controller.view
  let calendar = try #require(root.subviews.compactMap { $0 as? MonthCalendarView }.first)
  func firstLabel() throws -> String {
    try #require(
      calendar.subviews.compactMap { $0 as? NSTextField }.first {
        $0.frame.minX == 0 && $0.frame.minY == 89
      }
    ).stringValue
  }
  #expect(try firstLabel() == Calendar.current.veryShortStandaloneWeekdaySymbols[1])
  let button = try #require(
    root.subviews.compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel() == "Calendar settings"
    })
  var opened = 0
  controller.onCalendarSettings = { opened += 1 }
  #expect(!button.isHidden && button.title == "Calendar…")
  #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
  #expect(opened == 1 && !controller.showsAllReadings)
  controller.settings.calendarFirstWeekday = 7
  controller.update(Snapshot(), history: [])
  #expect(try firstLabel() == Calendar.current.veryShortStandaloneWeekdaySymbols[6])
}

@Test @MainActor func closingCalendarSettingsReleasesItsPreview() {
  _ = NSApplication.shared
  weak var owner: CalendarSettingsController?
  weak var preview: MonthCalendarView?
  autoreleasepool {
    let controller = CalendarSettingsController(enabled: false, selectedIDs: nil, firstWeekday: 2)
    owner = controller
    preview = controller.window?.contentView?.subviews.compactMap { $0 as? MonthCalendarView }.first
    controller.showWindow(nil)
    controller.close()
  }
  #expect(owner == nil && preview == nil)
}

@Test @MainActor func expandedCalendarListStaysOnScreenWhenOpenedNearBottom() throws {
  _ = NSApplication.shared
  let controller = CalendarSettingsController(enabled: false, selectedIDs: nil)
  let window = try #require(controller.window)
  let screen = try #require(window.screen ?? NSScreen.main)
  guard screen.visibleFrame.height >= 700 else { return }
  window.setFrameOrigin(.init(x: screen.visibleFrame.midX - 265, y: screen.visibleFrame.minY + 8))
  var available = CalendarAgendaSnapshot()
  available.access = .fullAccess
  available.calendars = [.init(id: "example", title: "Example calendar", source: "Example account")]
  controller.update(available, requesting: false)
  #expect(window.frame.minY >= screen.visibleFrame.minY)
  #expect(window.frame.maxY <= screen.visibleFrame.maxY)
}
