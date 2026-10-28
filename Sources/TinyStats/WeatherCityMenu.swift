import Foundation
import TinyStatsCore

/// Preserve city identity when different locations share a display name.
enum WeatherCityMenu {
  static func titles(_ cities: [WeatherLocation]) -> [String] {
    let counts = Dictionary(cities.map { ($0.displayName, 1) }, uniquingKeysWith: +)
    return cities.map { city in
      guard counts[city.displayName, default: 0] > 1 else { return city.displayName }
      let coordinates = String(
        format: "%.3f, %.3f", locale: Locale(identifier: "en_US_POSIX"),
        city.latitude, city.longitude)
      return "\(city.displayName) · \(city.timeZone) · \(coordinates)"
    }
  }
}
