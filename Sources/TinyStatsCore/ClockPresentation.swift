import Foundation

/// Clockwise degrees from twelve. A minute-only dial never invents a seconds reading.
public struct ClockDialReading: Equatable, Sendable {
  public let hour: Int, minute: Int, second: Int?
  public init?(hour: Int?, minute: Int?, second: Int? = nil) {
    guard let hour, let minute, (0..<24).contains(hour), (0..<60).contains(minute),
      second.map({ (0..<60).contains($0) }) ?? true
    else { return nil }
    self.hour = hour
    self.minute = minute
    self.second = second
  }
  public var hourDegrees: Double {
    Double(hour % 12) * 30 + Double(minute) / 2 + Double(second ?? 0) / 120
  }
  public var minuteDegrees: Double { Double(minute) * 6 + Double(second ?? 0) / 10 }
  public var secondDegrees: Double? { second.map { Double($0) * 6 } }
  public var accessibleTime: String {
    String(format: "%02d:%02d", hour, minute) + (second.map { String(format: ":%02d", $0) } ?? "")
  }
}

public enum ClockPresentation {
  private static let hourNames = [
    "twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "eleven",
  ]
  /// App UI is English. Rounding changes only at minute boundaries, with no extra visual ticks.
  public static func fuzzy(hour: Int?, minute: Int?) -> String? {
    guard let hour, let minute, (0..<24).contains(hour), (0..<60).contains(minute) else {
      return nil
    }
    let rounded = (minute + 2) / 5 * 5
    let current = hourNames[hour % 12]
    let next = hourNames[(hour + 1) % 12]
    switch rounded {
    case 0: return current + " o’clock"
    case 5: return "five past " + current
    case 10: return "ten past " + current
    case 15: return "quarter past " + current
    case 20: return "twenty past " + current
    case 25: return "twenty-five past " + current
    case 30: return "half past " + current
    case 35: return "twenty-five to " + next
    case 40: return "twenty to " + next
    case 45: return "quarter to " + next
    case 50: return "ten to " + next
    case 55: return "five to " + next
    default: return next + " o’clock"
    }
  }
  /// Includes historical second offsets; also accepts differences across the date line.
  public static func offset(seconds: Int) -> String {
    guard (-172_800...172_800).contains(seconds) else { return "—" }
    let magnitude = abs(seconds)
    return String(
      format: "%@%02d:%02d", seconds < 0 ? "-" : "+", magnitude / 3600, (magnitude / 60) % 60)
      + (magnitude % 60 == 0 ? "" : String(format: ":%02d", magnitude % 60))
  }
}
