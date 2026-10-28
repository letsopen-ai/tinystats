import AppKit
import TinyStatsCore

/// Main-actor-only, bounded native formatter reuse. Literal/user text never becomes an ICU pattern.
@MainActor enum ClockMenuRenderer {
  private final class Formats {
    enum Pattern { case names, time, seconds }
    let locale: Locale
    let calendar: Calendar
    private(set) var formatters: [Pattern: DateFormatter] = [:]
    init(locale: Locale, calendar: Calendar, zone: TimeZone) {
      self.locale = locale
      var calendar = calendar
      calendar.timeZone = zone
      self.calendar = calendar
    }
    func formatter(_ pattern: Pattern) -> DateFormatter {
      if let formatter = formatters[pattern] { return formatter }
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      switch pattern {
      case .names: formatter.dateFormat = "EEE\u{1F}EEEE\u{1F}MMM\u{1F}MMMM\u{1F}a"
      case .time: formatter.setLocalizedDateFormatFromTemplate("jmm")
      case .seconds: formatter.setLocalizedDateFormatFromTemplate("jmmss")
      }
      formatters[pattern] = formatter
      return formatter
    }
  }
  private static var cache: [String: Formats] = [:]
  private static var order: [String] = []
  static var cachedCount: Int { cache.count }
  static var cachedFormatterCount: Int { cache.values.reduce(0) { $0 + $1.formatters.count } }
  static func invalidate() {
    cache.removeAll()
    order.removeAll()
  }
  private static func formats(locale: Locale, calendar: Calendar, zone: TimeZone) -> Formats {
    let key = "\(locale.identifier)|\(calendar.identifier)|\(zone.identifier)"
    if let value = cache[key] {
      order.removeAll { $0 == key }
      order.append(key)
      return value
    }
    if order.count >= 12, let oldest = order.first {
      cache.removeValue(forKey: oldest)
      order.removeFirst()
    }
    let value = Formats(locale: locale, calendar: calendar, zone: zone)
    cache[key] = value
    order.append(key)
    return value
  }
  static func lines(
    _ entry: ClockMenuEntry, at date: Date, locale: Locale = .current,
    calendar: Calendar = .current, localZone: TimeZone = .current, displayName: String? = nil
  ) -> (String, String?) {
    let value = content(
      entry, at: date, locale: locale, calendar: calendar, localZone: localZone,
      displayName: displayName)
    return (value.first.text, value.second?.text)
  }
  static func content(
    _ entry: ClockMenuEntry, at date: Date, locale: Locale = .current,
    calendar: Calendar = .current, localZone: TimeZone = .current, displayName: String? = nil
  ) -> ClockMenuContent {
    guard entry.isValid,
      displayName.map({ ClockFormat.validSingleLine($0, limit: 128) }) ?? true,
      date.timeIntervalSince1970.isFinite,
      abs(date.timeIntervalSince1970) < 253_402_300_800,
      let first = ClockFormat(entry.firstLine), let second = ClockFormat(entry.secondLine)
    else { return .init(first: .init([.text("—")]), second: nil) }
    let zone = entry.zone == "local" ? localZone : TimeZone(identifier: entry.zone) ?? localZone
    let formats = formats(locale: locale, calendar: calendar, zone: zone)
    let components = formats.calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    var names: [String]?
    func name(_ index: Int) -> String {
      if names == nil {
        names = formats.formatter(.names).string(from: date).components(separatedBy: "\u{1F}")
      }
      guard let names, names.indices.contains(index) else { return "—" }
      return names[index]
    }
    func number(_ value: Int?, width: Int = 2) -> String {
      value.map { String(format: "%0*d", width, $0) } ?? "—"
    }
    func token(_ token: ClockToken) -> String {
      switch token {
      case .name: return displayName ?? entry.title
      case .systemTime: return formats.formatter(.time).string(from: date)
      case .systemTimeSeconds: return formats.formatter(.seconds).string(from: date)
      case .weekday: return name(0)
      case .weekdayUpper: return name(0).uppercased(with: locale)
      case .weekdayLong: return name(1)
      case .monthName: return name(2)
      case .monthLong: return name(3)
      case .period: return name(4)
      case .year: return number(components.year, width: 4)
      case .month: return number(components.month)
      case .day: return number(components.day)
      case .hour24: return number(components.hour)
      case .hour12: return components.hour.map { String(($0 + 11) % 12 + 1) } ?? "—"
      case .minute: return number(components.minute)
      case .second: return number(components.second)
      case .zone: return zone.abbreviation(for: date) ?? zone.identifier
      case .offset: return ClockPresentation.offset(seconds: zone.secondsFromGMT(for: date))
      case .localOffset:
        return ClockPresentation.offset(
          seconds: zone.secondsFromGMT(for: date) - localZone.secondsFromGMT(for: date))
      case .fuzzy:
        return ClockPresentation.fuzzy(hour: components.hour, minute: components.minute) ?? "—"
      case .analog, .analogSeconds, .calendar: return "—"  // Handled as vector atoms below.
      }
    }
    func render(_ format: ClockFormat) -> ClockMenuLine {
      ClockMenuLine(
        format.parts.map { part in
          switch part {
          case .literal(let value): return .text(value)
          case .token(.analog), .token(.analogSeconds):
            if part == .token(.analogSeconds) && components.second == nil { return .text("—") }
            let seconds: Int? = part == .token(.analogSeconds) ? components.second : nil
            return ClockDialReading(
              hour: components.hour, minute: components.minute, second: seconds
            ).map { .dial($0) } ?? .text("—")
          case .token(.calendar):
            guard let day = components.day, (1...31).contains(day) else { return .text("—") }
            return .calendar(day)
          case .token(let value): return .text(token(value))
          }
        })
    }
    let top = render(first)
    let bottom = render(second)
    return .init(first: top, second: bottom.isEmpty ? nil : bottom)
  }
  static func readouts(settings: Settings, at date: Date) -> [MenuBarReadout] {
    settings.clockMenu.entries.prefix(ClockMenuSettings.limit).map { entry in
      var style = settings.style(for: .clock)
      let content = style.showsClockTime ? content(entry, at: date) : nil
      if style == .stacked && content?.second == nil { style = .value }
      return .init(
        label: entry.title, value: content?.first.text ?? "", secondary: content?.second?.text,
        style: style,
        appearance: settings.appearance(for: .clock), symbol: Module.clock.symbol, clock: content)
    }
  }
  /// Shared by the detail table and its settings preview, including output bounds and locale rules.
  static func worldClockRows(settings: Settings, at date: Date) -> [(label: String, value: String)]
  {
    let format =
      WorldClockFormat.parse(settings.worldClockFormat) == nil
      ? WorldClockFormat.standard : settings.worldClockFormat
    return settings.worldClockEntries.map { clock in
      let entry = ClockMenuEntry(
        zone: clock.zone, firstLine: format, secondLine: "")
      return (clock.title, lines(entry, at: date, displayName: clock.title).0)
    }
  }
}

extension MenuBarReadout {
  @MainActor static func makeAll(
    module: Module, snapshot: Snapshot, settings: Settings, history: [HistoryPoint],
    clockDate: Date? = nil
  ) -> [Self] {
    if module == .clock && settings.clockMenu.custom {
      return ClockMenuRenderer.readouts(settings: settings, at: clockDate ?? snapshot.timestamp).map
      {
        var readout = $0
        readout.module = .clock
        return readout
      }
    }
    return [
      .make(
        module: module, snapshot: snapshot, settings: settings, history: history,
        clockDate: clockDate)
    ]
  }
}
