import Foundation

/// Read only Weather's cached city projection. Never launch Weather, use its credentials,
/// or infer the current location from a saved/home/search city.
public struct SystemWeatherCities: Sendable {
  public static let byteLimit = 262_144
  public static let cityLimit = 64
  public let locations: [WeatherLocation]
  public let truncated: Bool
  public enum Failure: Error { case tooLarge, unsupported }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= byteLimit else { throw Failure.tooLarge }
    let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
    var seen = Set<String>()
    return Self(
      locations: envelope.cities.filter { seen.insert($0.requestKey).inserted },
      truncated: envelope.truncated)
  }
  public static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> Self
  {
    let url = home.appendingPathComponent(
      "Library/Group Containers/group.com.apple.weather/Library/Preferences/group.com.apple.weather.plist"
    )
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: byteLimit + 1) ?? Data()
    return try decode(data)
  }
  private struct City: Decodable {
    let latitude: Double, longitude: Double, name: String, timeZone: String
    enum CodingKeys: String, CodingKey {
      case latitude = "Lat"
      case longitude = "Lon"
      case name = "Name"
      case timeZone = "TimeZone"
    }
    var location: WeatherLocation? {
      WeatherLocation(latitude: latitude, longitude: longitude, name: name, timeZone: timeZone)
        .validated
    }
  }
  private struct Envelope: Decodable {
    let cities: [WeatherLocation]
    let truncated: Bool
    enum CodingKeys: String, CodingKey { case cities = "Cities" }
    init(from decoder: Decoder) throws {
      let root = try decoder.container(keyedBy: CodingKeys.self)
      guard var rows = try? root.nestedUnkeyedContainer(forKey: .cities) else {
        throw Failure.unsupported
      }
      var result: [WeatherLocation] = []
      for _ in 0..<cityLimit where !rows.isAtEnd {
        let row = try rows.superDecoder()
        if let value = try? City(from: row).location { result.append(value) }
      }
      cities = result
      truncated = !rows.isAtEnd
    }
  }
}
