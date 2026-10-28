import Foundation

/// Provider bearings point clockwise from north toward the source of the wind.
struct WindDirectionPresentation {
  let degrees: Double
  let cardinal: String
  private static let names = [
    "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW",
    "NNW",
  ]
  init?(_ value: Double?) {
    guard let value, value.isFinite, (0...360).contains(value) else { return nil }
    degrees = value
    cardinal = Self.names[Int(floor((value + 11.25) / 22.5)) % Self.names.count]
  }
  var value: String { cardinal + " · " + String(format: "%.0f°", degrees) }
  var description: String {
    String(format: "Wind from %.0f° clockwise from north (%@)", degrees, cardinal)
  }
}

/// One formatter and at most seven patterns; never retains dates or forecast values.
@MainActor final class WeatherDateLabels {
  enum Style: CaseIterable, Hashable {
    case clock, clockZone, forecast, modelTime, day, longDay, shortDay
    var template: String {
      switch self {
      case .clock: "jm"
      case .clockZone: "jmz"
      case .forecast: "EEEjmz"
      case .modelTime: "EEEjm"
      case .day: "EEEdMMM"
      case .longDay: "EEEEdMMMz"
      case .shortDay: "EEEd"
      }
    }
  }
  private let formatter = DateFormatter()
  private var patterns: [Style: String] = [:]
  private var invalidated = false
  private(set) var locale: Locale
  private(set) var timeZone: TimeZone
  var patternCount: Int { patterns.count }
  init(locale: Locale = .current, timeZone: TimeZone = .current) {
    self.locale = locale
    self.timeZone = timeZone
    formatter.locale = locale
    formatter.timeZone = timeZone
  }
  func invalidate() {
    patterns.removeAll(keepingCapacity: true)
    invalidated = true
  }
  func configure(locale: Locale, timeZone: TimeZone, force: Bool = false) {
    if force || invalidated || locale != self.locale {
      self.locale = locale
      formatter.locale = locale
      patterns.removeAll(keepingCapacity: true)
      invalidated = false
    }
    if timeZone != self.timeZone {
      self.timeZone = timeZone
      formatter.timeZone = timeZone
    }
  }
  func string(_ date: Date, as style: Style) -> String {
    if let pattern = patterns[style] {
      formatter.dateFormat = pattern
    } else {
      formatter.setLocalizedDateFormatFromTemplate(style.template)
      if let pattern = formatter.dateFormat { patterns[style] = pattern }
    }
    return formatter.string(from: date)
  }
  func compactTime(_ date: Date) -> String {
    // Permit wrapping before a day-period marker without dropping minutes or AM/PM.
    string(date, as: .clock).replacingOccurrences(of: "\u{202F}", with: " ")
      .replacingOccurrences(of: "\u{00A0}", with: " ")
  }
}
