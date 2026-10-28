import Foundation

/// A small clock-specific language: literal text plus named tokens, never arbitrary ICU patterns.
public enum ClockToken: String, CaseIterable, Sendable {
  case name, systemTime, systemTimeSeconds, weekday, weekdayUpper, weekdayLong
  case year, month, monthName, monthLong, day, hour24, hour12, minute, second, period, zone, offset
  case analog, analogSeconds, calendar, fuzzy, localOffset
  public var title: String {
    switch self {
    case .name: "Clock name"
    case .systemTime: "System time"
    case .systemTimeSeconds: "System time with seconds"
    case .weekday: "Weekday · short"
    case .weekdayUpper: "WEEKDAY · short"
    case .weekdayLong: "Weekday · full"
    case .year: "Year"
    case .month: "Month · number"
    case .monthName: "Month · short"
    case .monthLong: "Month · full"
    case .day: "Day of month"
    case .hour24: "Hour · 24-hour"
    case .hour12: "Hour · 12-hour"
    case .minute: "Minute"
    case .second: "Second"
    case .period: "AM / PM"
    case .zone: "Time zone abbreviation"
    case .offset: "UTC offset"
    case .analog: "Analogue clock"
    case .analogSeconds: "Analogue clock with seconds"
    case .calendar: "Mini calendar · day of month"
    case .fuzzy: "Fuzzy time · English, nearest five minutes"
    case .localOffset: "Offset from this Mac"
    }
  }
  public var text: String { "{\(rawValue)}" }
  public var includesSeconds: Bool {
    self == .second || self == .systemTimeSeconds || self == .analogSeconds
  }
}

public enum ClockFormatPart: Equatable, Sendable {
  case literal(String)
  case token(ClockToken)
}

public struct ClockFormat: Equatable, Sendable {
  public static let limit = 96
  public let parts: [ClockFormatPart]
  public var includesSeconds: Bool {
    parts.contains {
      if case .token(let token) = $0 { return token.includesSeconds }
      return false
    }
  }
  public init?(_ text: String) {
    guard Self.validSingleLine(text, limit: Self.limit)
    else { return nil }
    var parts: [ClockFormatPart] = []
    var literal = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if character == "{" {
        if next < text.endIndex && text[next] == "{" {
          literal.append("{")
          index = text.index(after: next)
          continue
        }
        guard let end = text[next...].firstIndex(of: "}"),
          let token = ClockToken(rawValue: String(text[next..<end]))
        else { return nil }
        if !literal.isEmpty {
          parts.append(.literal(literal))
          literal = ""
        }
        parts.append(.token(token))
        index = text.index(after: end)
      } else if character == "}" {
        guard next < text.endIndex && text[next] == "}" else { return nil }
        literal.append("}")
        index = text.index(after: next)
      } else {
        literal.append(character)
        index = next
      }
    }
    if !literal.isEmpty { parts.append(.literal(literal)) }
    self.parts = parts
  }
  public static func validSingleLine(_ value: String, limit: Int) -> Bool {
    // Joiners are needed for ordinary Persian/Indic text and compound emoji.
    let forbidden = CharacterSet.controlCharacters.union(.newlines)
      .subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))
    return value.utf16.count <= limit && !value.unicodeScalars.contains(where: forbidden.contains)
  }
}

public struct ClockMenuEntry: Codable, Equatable, Sendable {
  public var name = ""
  /// "local" tracks the system; other values are validated IANA identifiers.
  public var zone = "local"
  public var firstLine = "{weekdayUpper}"
  public var secondLine = "{hour24}:{minute}"
  public init(
    name: String = "", zone: String = "local", firstLine: String = "{weekdayUpper}",
    secondLine: String = "{hour24}:{minute}"
  ) {
    self.name = name
    self.zone = zone
    self.firstLine = firstLine
    self.secondLine = secondLine
  }
  private enum CodingKeys: String, CodingKey { case name, zone, firstLine, secondLine }
  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    name = (try? fields.decode(String.self, forKey: .name)) ?? ""
    zone = (try? fields.decode(String.self, forKey: .zone)) ?? "local"
    firstLine = (try? fields.decode(String.self, forKey: .firstLine)) ?? "{weekdayUpper}"
    secondLine = (try? fields.decode(String.self, forKey: .secondLine)) ?? "{hour24}:{minute}"
    if !ClockFormat.validSingleLine(name, limit: 48) { name = "" }
    if !Self.validZone(zone) { zone = "local" }
    if ClockFormat(firstLine) == nil || firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
      firstLine = "{weekdayUpper}"
    }
    if ClockFormat(secondLine) == nil { secondLine = "{hour24}:{minute}" }
  }
  public static func validZone(_ value: String) -> Bool {
    value == "local"
      || (!value.isEmpty && value.utf8.count <= 128 && TimeZone(identifier: value) != nil)
  }
  public var isValid: Bool {
    ClockFormat.validSingleLine(name, limit: 48)
      && Self.validZone(zone) && ClockFormat(firstLine) != nil && ClockFormat(secondLine) != nil
      && !firstLine.trimmingCharacters(in: .whitespaces).isEmpty
  }
  public var includesSeconds: Bool {
    [firstLine, secondLine].contains { ClockFormat($0)?.includesSeconds == true }
  }
  public var title: String {
    if !name.isEmpty { return name }
    return zone == "local" ? "Local" : zone
  }
}

public struct ClockMenuSettings: Codable, Equatable, Sendable {
  public static let limit = 6
  public var custom = false
  public var entries: [ClockMenuEntry] = [.init()]
  public init(custom: Bool = false, entries: [ClockMenuEntry] = [.init()]) {
    self.custom = custom
    self.entries = entries
    validate()
  }
  private enum CodingKeys: String, CodingKey { case custom, entries }
  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    custom = (try? fields.decode(Bool.self, forKey: .custom)) ?? false
    entries = []
    if var array = try? fields.nestedUnkeyedContainer(forKey: .entries) {
      for _ in 0..<Self.limit where !array.isAtEnd {
        if let decoder = try? array.superDecoder(), let entry = try? ClockMenuEntry(from: decoder) {
          entries.append(entry)
        }
      }
    }
    validate()
  }
  public mutating func validate() {
    entries = Array(entries.prefix(Self.limit)).filter(\.isValid)
    if entries.isEmpty { entries = [.init()] }
  }
  public var includesSeconds: Bool {
    custom && entries.prefix(Self.limit).contains(where: \.includesSeconds)
  }
}
