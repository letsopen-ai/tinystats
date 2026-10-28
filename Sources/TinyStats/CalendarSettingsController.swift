import AppKit
import TinyStatsCore

@MainActor final class CalendarSettingsController: NSWindowController, NSWindowDelegate {
  var onClose: (() -> Void)?
  var onChange: ((Bool, [String]?) -> Void)?
  var onPermission: (() -> Void)?
  var onFirstWeekday: ((Int?) -> Void)?
  private var firstWeekday: Int?
  private var previewBase = Calendar.current
  private let weekStart = NSPopUpButton()
  private let preview: MonthCalendarView
  private var enabled: Bool
  private var selectedIDs: [String]?
  private var snapshot = CalendarAgendaSnapshot()
  private var checks: [String: NSButton] = [:]
  private let toggle = NSButton(
    checkboxWithTitle: "Show calendar events in Date & Time", target: nil, action: nil)
  private let status = NSTextField(wrappingLabelWithString: "")
  private let permission = NSButton(title: "Allow Calendar Access…", target: nil, action: nil)
  private let all = NSButton(
    checkboxWithTitle: "All calendars (including newly added)", target: nil, action: nil)
  private let list = NSView()
  private let summary = NSTextField(wrappingLabelWithString: "")
  private var calendarScroll: NSScrollView?
  private var showsCalendarList = true
  init(enabled: Bool, selectedIDs: [String]?, firstWeekday: Int? = nil) {
    self.enabled = enabled
    self.selectedIDs = selectedIDs
    self.firstWeekday = firstWeekday.flatMap { (1...7).contains($0) ? $0 : nil }
    preview = MonthCalendarView(
      frame: .zero, firstWeekday: self.firstWeekday)
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 530, height: 640), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "TinyStats Calendar"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    guard let content = window.contentView else { return }
    func add(_ view: NSView, _ frame: NSRect) {
      view.frame = frame
      content.addSubview(view)
    }
    let weekLabel = NSTextField(labelWithString: "First day of week")
    add(weekLabel, .init(x: 22, y: 603, width: 152, height: 20))
    weekStart.target = self
    weekStart.action = #selector(changeWeekStart)
    weekStart.setAccessibilityLabel("First day of week")
    add(weekStart, .init(x: 180, y: 598, width: 326, height: 26))
    rebuildWeekdayChoices()
    add(preview, .init(x: 22, y: 454, width: 300, height: 130))
    let previewNote = NSTextField(
      wrappingLabelWithString:
        "Week layout preview\nUpdates Time immediately.\n\nNo Calendar access needed."
    )
    previewNote.font = .systemFont(ofSize: 11)
    previewNote.textColor = .secondaryLabelColor
    add(previewNote, .init(x: 338, y: 478, width: 168, height: 98))
    let divider = NSBox()
    divider.boxType = .separator
    add(divider, .init(x: 20, y: 443, width: 490, height: 1))
    toggle.target = self
    toggle.action = #selector(toggleEvents)
    toggle.state = enabled ? .on : .off
    add(toggle, .init(x: 20, y: 402, width: 490, height: 26))
    let privacy = NSTextField(
      wrappingLabelWithString:
        "Optional advanced agenda · off by default. Reads macOS Calendar events only while Date & Time is open. Titles stay in memory; TinyStats never edits or uploads events."
    )
    privacy.font = .systemFont(ofSize: 12)
    privacy.textColor = .secondaryLabelColor
    add(privacy, .init(x: 22, y: 347, width: 484, height: 50))
    status.font = .systemFont(ofSize: 12)
    add(status, .init(x: 22, y: 307, width: 484, height: 35))
    permission.target = self
    permission.action = #selector(allowAccess)
    permission.bezelStyle = .rounded
    add(permission, .init(x: 20, y: 271, width: 235, height: 30))
    all.target = self
    all.action = #selector(selectAllCalendars)
    add(all, .init(x: 20, y: 235, width: 490, height: 26))
    let scroll = NSScrollView(frame: .init(x: 20, y: 65, width: 490, height: 160))
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = list
    calendarScroll = scroll
    content.addSubview(scroll)
    summary.font = .systemFont(ofSize: 11)
    summary.textColor = .secondaryLabelColor
    add(summary, .init(x: 22, y: 15, width: 484, height: 43))
    update(.init(), requesting: false)
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func selectPreviewDate(_ date: Date) { preview.selectDate(date) }
  private func rebuildWeekdayChoices() {
    weekStart.removeAllItems()
    let symbols = previewBase.weekdaySymbols
    let systemDay =
      symbols.indices.contains(previewBase.firstWeekday - 1)
      ? " (\(symbols[previewBase.firstWeekday - 1]))" : ""
    weekStart.addItem(withTitle: "System default" + systemDay)
    weekStart.lastItem?.tag = 0
    for (index, symbol) in symbols.prefix(7).enumerated() {
      weekStart.addItem(withTitle: symbol)
      weekStart.lastItem?.tag = index + 1
    }
    weekStart.selectItem(withTag: firstWeekday ?? 0)
  }
  func updateClock(_ date: Date) {
    guard window?.isVisible == true else { return }
    let current = Calendar.current
    if current != previewBase {
      previewBase = current
      rebuildWeekdayChoices()
    }
    preview.updateToday(date, calendar: current, firstWeekday: firstWeekday)
  }
  @objc private func changeWeekStart() {
    guard let day = weekStart.selectedItem?.tag, (0...7).contains(day) else { return }
    firstWeekday = day == 0 ? nil : day
    preview.updateToday(Date(), calendar: .current, firstWeekday: firstWeekday)
    onFirstWeekday?(firstWeekday)
  }
  func windowWillClose(_ notification: Notification) { onClose?() }
  func update(_ state: CalendarAgendaSnapshot, requesting: Bool) {
    let changed = state.calendars != snapshot.calendars
    snapshot = state
    updateListVisibility(!state.calendars.isEmpty)
    status.stringValue =
      requesting
      ? "Waiting for your Calendar permission decision…"
      : state.refreshing ? "Checking calendar access…" : state.access.message
    permission.isEnabled =
      !requesting && !state.refreshing && state.access != .restricted && state.access != .fullAccess
    permission.title =
      state.access == .denied ? "Open Calendar Privacy Settings…" : "Allow Calendar Access…"
    all.state = selectedIDs == nil ? .on : .off
    all.isEnabled = state.access == .fullAccess
    if changed { rebuildCalendars() }
    for (id, check) in checks {
      check.state = selectedIDs?.contains(id) ?? true ? .on : .off
      check.isEnabled = state.access == .fullAccess && selectedIDs != nil
    }
    let missing = selectedIDs?.filter { id in !state.calendars.contains { $0.id == id } }.count ?? 0
    summary.stringValue =
      state.calendarsTruncated
      ? "Showing the first 64 calendars. Calendar and event results may be partial."
      : missing > 0
        ? "\(missing) selected calendars are currently unavailable; choices are retained."
        : "macOS calls reading permission Full Access. TinyStats uses it only to read events. Changes apply immediately."
  }
  private func updateListVisibility(_ visible: Bool) {
    guard visible != showsCalendarList, let window, let root = window.contentView,
      let calendarScroll
    else { return }
    showsCalendarList = visible
    calendarScroll.isHidden = !visible
    // Keep the layout controls in place on screen; grow downward only when there
    // are calendars to choose, rather than reserving an empty permission-gated list.
    let delta: CGFloat = visible ? 160 : -160
    for child in root.subviews where child !== calendarScroll && child !== summary {
      child.frame.origin.y += delta
    }
    let top = window.frame.maxY
    window.setContentSize(.init(width: 530, height: visible ? 640 : 480))
    var bottom = top - window.frame.height
    if let visibleFrame = window.screen?.visibleFrame,
      window.frame.height <= visibleFrame.height
    {
      bottom = min(max(bottom, visibleFrame.minY), visibleFrame.maxY - window.frame.height)
    }
    window.setFrameOrigin(.init(x: window.frame.minX, y: bottom))
  }
  private func rebuildCalendars() {
    for view in list.subviews { view.removeFromSuperview() }
    checks = [:]
    let calendars = snapshot.calendars
    list.frame = .init(x: 0, y: 0, width: 470, height: max(160, calendars.count * 28))
    for (index, calendar) in calendars.enumerated() {
      let button = NSButton(
        checkboxWithTitle: "\(calendar.title) · \(calendar.source)", target: self,
        action: #selector(selectCalendar(_:)))
      button.identifier = .init(calendar.id)
      button.frame = .init(
        x: 4, y: Int(list.bounds.height) - (index + 1) * 28, width: 460, height: 26)
      button.lineBreakMode = .byTruncatingTail
      button.toolTip = button.title
      list.addSubview(button)
      checks[calendar.id] = button
    }
  }
  private func publish() {
    onChange?(enabled, selectedIDs)
    update(snapshot, requesting: false)
  }
  @objc private func toggleEvents() {
    enabled = toggle.state == .on
    publish()
  }
  @objc private func selectAllCalendars() {
    selectedIDs = all.state == .on ? nil : snapshot.calendars.map(\.id)
    publish()
  }
  @objc private func selectCalendar(_ button: NSButton) {
    guard let id = button.identifier?.rawValue, var ids = selectedIDs else { return }
    ids.removeAll { $0 == id }
    if button.state == .on { ids.append(id) }
    selectedIDs = ids
    publish()
  }
  @objc private func allowAccess() {
    if snapshot.access == .denied {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
      {
        NSWorkspace.shared.open(url)
      }
    } else {
      onPermission?()
    }
  }
}
