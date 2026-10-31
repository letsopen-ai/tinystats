import AppKit

/// Native day buttons keep date selection keyboard- and accessibility-operable.
@MainActor final class MonthCalendarView: NSView {
  var onSelect: ((Date) -> Void)?
  private(set) var selectedDate = Date()
  private(set) var month = Date()
  private var today = Date()
  private var followsToday = true
  private var days: [NSButton] = []
  private var weekdayLabels: [NSTextField] = []
  private var dates: [Date?] = Array(repeating: nil, count: 42)
  private let heading = NSTextField(labelWithString: "")
  private let formatter = DateFormatter()
  private var designFrames: [NSRect] = []
  private var calendar: Calendar
  init(
    frame: NSRect, calendar: Calendar = .current, date: Date = Date(), firstWeekday: Int? = nil
  ) {
    self.calendar = Self.configured(calendar, firstWeekday: firstWeekday)
    selectedDate = date
    month = date
    today = date
    super.init(frame: frame)
    for (title, action, x) in [
      ("‹", #selector(previousMonth), 0), ("›", #selector(nextMonth), 221),
      ("Today", #selector(currentMonth), 248),
    ] {
      let button = NSButton(title: title, target: self, action: action)
      button.isBordered = false
      button.font = .systemFont(ofSize: 12)
      button.frame = .init(x: x, y: 105, width: title == "Today" ? 45 : 24, height: 24)
      button.setAccessibilityLabel(
        title == "‹" ? "Previous month" : title == "›" ? "Next month" : "Select today")
      button.toolTip = button.accessibilityLabel()
      addSubview(button)
    }
    heading.frame = .init(x: 34, y: 109, width: 185, height: 19)
    heading.font = .systemFont(ofSize: 12, weight: .semibold)
    addSubview(heading)
    let weekdays = self.calendar.veryShortStandaloneWeekdaySymbols
    for index in 0..<7 {
      let label = NSTextField(
        labelWithString: weekdays[(index + self.calendar.firstWeekday - 1) % 7])
      label.frame = .init(x: CGFloat(index) * 42, y: 89, width: 38, height: 16)
      label.alignment = .center
      label.font = .systemFont(ofSize: 10)
      label.textColor = .secondaryLabelColor
      addSubview(label)
      weekdayLabels.append(label)
    }
    for index in 0..<42 {
      let button = NSButton(title: "", target: self, action: #selector(chooseDay(_:)))
      button.frame = .init(
        x: CGFloat(index % 7) * 42, y: CGFloat(74 - index / 7 * 14), width: 38, height: 16)
      button.bezelStyle = .recessed
      button.setButtonType(.toggle)
      button.controlSize = .mini
      button.tag = index
      days.append(button)
      addSubview(button)
    }
    setAccessibilityRole(.group)
    designFrames = subviews.map(\.frame)
    rebuild()
  }
  private func layoutGrid() {
    guard designFrames.count == subviews.count else { return }
    let scale = min(2, max(1, min(bounds.width / 300, bounds.height / 130)))
    for (child, frame) in zip(subviews, designFrames) {
      child.frame = .init(
        x: frame.minX * scale, y: frame.minY * scale,
        width: frame.width * scale, height: frame.height * scale)
      if let button = child as? NSButton {
        button.font = .monospacedDigitSystemFont(
          ofSize: (days.contains(button) ? 10 : 12) * scale,
          weight: button.font?.fontDescriptor.symbolicTraits.contains(.bold) == true
            ? .bold : .regular)
      } else if let label = child as? NSTextField {
        label.font = .systemFont(
          ofSize: (label === heading ? 12 : 10) * scale,
          weight: label === heading ? .semibold : .regular)
      }
    }
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutGrid()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private static func configured(_ base: Calendar, firstWeekday: Int?) -> Calendar {
    var calendar = base
    if let day = firstWeekday, (1...7).contains(day) { calendar.firstWeekday = day }
    return calendar
  }
  func updateToday(
    _ date: Date, calendar base: Calendar = .current, firstWeekday: Int? = nil
  ) {
    let nextCalendar = Self.configured(base, firstWeekday: firstWeekday)
    let calendarChanged = calendar != nextCalendar
    let changed = !calendar.isDate(today, inSameDayAs: date) || calendarChanged
    today = date
    guard changed else { return }
    let previousSelection = selectedDate
    let components = calendar.dateComponents([.era, .year, .month, .day], from: selectedDate)
    let sameIdentifier = calendar.identifier == nextCalendar.identifier
    calendar = nextCalendar
    if followsToday {
      selectedDate = date
      month = date
    } else if calendarChanged && sameIdentifier, let selected = calendar.date(from: components) {
      // A pinned civil day must stay selected when the system time zone changes.
      selectedDate = selected
      month = selected
    }
    rebuild()
    if selectedDate != previousSelection { onSelect?(selectedDate) }
  }
  func selectDate(_ date: Date) {
    selectedDate = calendar.startOfDay(for: date)
    month = selectedDate
    followsToday = calendar.isDate(selectedDate, inSameDayAs: today)
    rebuild()
    onSelect?(selectedDate)
  }
  func moveMonth(by count: Int) {
    guard let start = calendar.dateInterval(of: .month, for: month)?.start,
      let next = calendar.date(byAdding: .month, value: count, to: start),
      let range = calendar.range(of: .day, in: .month, for: next),
      let selected = calendar.date(
        byAdding: .day, value: min(calendar.component(.day, from: selectedDate), range.count) - 1,
        to: next)
    else { return }
    selectDate(selected)
  }
  @objc private func previousMonth() { moveMonth(by: -1) }
  @objc private func nextMonth() { moveMonth(by: 1) }
  @objc private func currentMonth() { selectDate(today) }
  @objc private func chooseDay(_ sender: NSButton) {
    if let date = dates[sender.tag] { selectDate(date) }
  }
  private func rebuild() {
    let weekdays = calendar.veryShortStandaloneWeekdaySymbols
    for (index, label) in weekdayLabels.enumerated() {
      label.stringValue = weekdays[(index + calendar.firstWeekday - 1) % 7]
    }
    formatter.locale = calendar.locale ?? .current
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "LLLL yyyy"
    heading.stringValue = formatter.string(from: month)
    guard let start = calendar.dateInterval(of: .month, for: month)?.start,
      let range = calendar.range(of: .day, in: .month, for: start)
    else { return }
    let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    for index in 0..<42 {
      let day = index - offset + 1
      let date =
        range.contains(day) ? calendar.date(byAdding: .day, value: day - 1, to: start) : nil
      dates[index] = date
      let button = days[index]
      button.isHidden = date == nil
      guard let date else { continue }
      let isToday = calendar.isDate(date, inSameDayAs: today)
      let selected = calendar.isDate(date, inSameDayAs: selectedDate)
      button.title = String(day)
      button.state = selected ? .on : .off
      button.isBordered = selected
      button.font = .monospacedDigitSystemFont(ofSize: 10, weight: isToday ? .bold : .regular)
      button.contentTintColor = isToday ? .controlAccentColor : .labelColor
      formatter.dateStyle = .full
      formatter.timeStyle = .none
      button.setAccessibilityLabel(formatter.string(from: date) + (isToday ? ", today" : ""))
      button.toolTip = button.accessibilityLabel()
    }
    layoutGrid()
    setAccessibilityLabel("\(heading.stringValue) calendar")
  }
}
