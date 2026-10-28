import Foundation

/// The detail table uses text tokens; vector menu-bar tokens are deliberately excluded.
public enum WorldClockFormat {
  public static let standard = "{weekday} {hour24}:{minute} · {zone}"
  public static let tokens = ClockToken.allCases.filter {
    $0 != .analog && $0 != .analogSeconds && $0 != .calendar
  }
  public static func parse(_ text: String) -> ClockFormat? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let format = ClockFormat(text),
      format.parts.allSatisfy({ part in
        if case .token(let token) = part { return tokens.contains(token) }
        return true
      })
    else { return nil }
    return format
  }
}

public struct WorldClockEntry: Equatable, Sendable {
  public let zone: String
  public let name: String?
  public var title: String { name ?? zone.replacingOccurrences(of: "_", with: " ") }
  public init?(zone: String, name: String? = nil) {
    let zone = zone.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !zone.isEmpty, zone.utf8.count <= 128, TimeZone(identifier: zone) != nil else {
      return nil
    }
    let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard label.isEmpty || Self.validName(label) else { return nil }
    self.zone = zone
    self.name = label.isEmpty ? nil : label
  }
  public static func validName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.count <= 40
      && !value.contains(",") && !value.contains("=")
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && !value.unicodeScalars.contains(where: CharacterSet.newlines.contains)
  }
  /// Empty input deliberately removes world clocks. Legacy zone-only lists remain valid.
  public static func parse(_ text: String) -> [Self]? {
    guard text.utf8.count <= 1024 else { return nil }
    let fields = text.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard fields.count <= 6 else { return nil }
    var result: [Self] = []
    var zones = Set<String>()
    for field in fields {
      let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let zone = String(parts.last ?? "")
      let name = parts.count == 2 ? String(parts[0]) : nil
      guard let entry = Self(zone: zone, name: name), zones.insert(entry.zone).inserted else {
        return nil
      }
      result.append(entry)
    }
    return result
  }
  public var input: String { name.map { "\($0)=\(zone)" } ?? zone }
  static func validatedZones(_ input: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for zone in input {
      guard zone.utf8.count <= 128, TimeZone(identifier: zone) != nil,
        seen.insert(zone).inserted
      else { continue }
      result.append(zone)
      if result.count == 6 { break }
    }
    return result
  }
}

extension Settings {
  public var worldClockIncludesSeconds: Bool {
    !worldClockEntries.isEmpty && WorldClockFormat.parse(worldClockFormat)?.includesSeconds == true
  }
  public var worldClockEntries: [WorldClockEntry] {
    var result: [WorldClockEntry] = []
    var seen = Set<String>()
    for zone in worldClocks {
      guard
        let entry = WorldClockEntry(zone: zone, name: worldClockNames[zone])
          ?? WorldClockEntry(zone: zone), seen.insert(entry.zone).inserted
      else { continue }
      result.append(entry)
      if result.count == 6 { break }
    }
    return result
  }
  public var worldClockInput: String { worldClockEntries.map(\.input).joined(separator: ", ") }
}
