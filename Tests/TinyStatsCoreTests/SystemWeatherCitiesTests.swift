import Foundation
import Testing

@testable import TinyStatsCore

@Test func weatherDefaultsOffAndPreservesExplicitChoices() throws {
  let name = "TinyStats.WeatherDefaults.\(UUID().uuidString)"
  let store = try #require(UserDefaults(suiteName: name))
  defer { store.removePersistentDomain(forName: name) }
  let fresh = Settings.load(from: store)
  #expect(!fresh.weather.enabled)
  #expect(fresh.weather.location == nil && !fresh.readouts.contains(.weather))
  #expect(
    !fresh.connectivityChecks && !fresh.publicIPChecks && !fresh.calendarEvents && !fresh.alerts)
  var old = Settings()
  old.weather.enabled = false
  old.save(to: store)
  #expect(!Settings.load(from: store).weather.enabled)
  old.weather = .currentLocationDefault
  old.save(to: store)
  #expect(Settings.load(from: store).weather.enabled)
  old.weather.location = .init(
    latitude: 60, longitude: 10, name: "Old fix", timeZone: "Europe/Oslo")
  old.weather.prepareForSession()
  #expect(old.weather.enabled && old.weather.location == nil)
  var manual = WeatherSettings()
  manual.location = .init(latitude: 60, longitude: 10, name: "Chosen", timeZone: "Europe/Oslo")
  manual.enabled = true
  old.weather = manual
  old.save(to: store)
  #expect(Settings.load(from: store).weather == manual)
  manual.prepareForSession()
  #expect(manual.location?.name == "Chosen")
  let encoded = try JSONEncoder().encode(old)
  #expect(try JSONDecoder().decode(Settings.self, from: encoded).weather == old.weather)
  store.set("damaged", forKey: "settings")
  #expect(!Settings.load(from: store).weather.enabled)
}

@Test func systemWeatherCitiesDecodeOnlyValidatedBoundedSavedCities() throws {
  let oslo: [String: Any] = [
    "Name": "Oslo", "Lat": 59.9139, "Lon": 10.7522, "TimeZone": "Europe/Oslo",
  ]
  let london: [String: Any] = [
    "Name": "London", "Lat": 51.5074, "Lon": -0.1278, "TimeZone": "Europe/London",
  ]
  let data = try PropertyListSerialization.data(
    fromPropertyList: [
      "Cities": [oslo, ["Name": "broken"], london, oslo], "verificationData": "ignored",
    ], format: .binary, options: 0)
  let value = try SystemWeatherCities.decode(data)
  #expect(value.locations.map(\.name) == ["Oslo", "London"])
  #expect(value.locations.first?.latitude == 59.914)
  #expect(!value.truncated)
  let empty = try PropertyListSerialization.data(
    fromPropertyList: ["Cities": []], format: .xml, options: 0)
  #expect(try SystemWeatherCities.decode(empty).locations.isEmpty)
  let missing = try PropertyListSerialization.data(
    fromPropertyList: ["Other": "value"], format: .binary, options: 0)
  #expect(throws: SystemWeatherCities.Failure.self) { try SystemWeatherCities.decode(missing) }
  #expect(throws: SystemWeatherCities.Failure.self) {
    try SystemWeatherCities.decode(Data(repeating: 0, count: SystemWeatherCities.byteLimit + 1))
  }
  let many = try PropertyListSerialization.data(
    fromPropertyList: ["Cities": Array(repeating: oslo, count: SystemWeatherCities.cityLimit + 1)],
    format: .binary, options: 0)
  let bounded = try SystemWeatherCities.decode(many)
  #expect(bounded.truncated && bounded.locations.count == 1)
}

@Test func weatherMigrationAndReenableCannotReuseUnverifiedCurrentCoordinates() throws {
  let location = WeatherLocation(
    latitude: 60, longitude: 10, name: "Old fix", timeZone: "Europe/Oslo")
  var previous = WeatherSettings.currentLocationDefault
  previous.location = location
  var next = previous
  next.prepareForChange(from: previous)
  #expect(next.location == location)
  previous.enabled = false
  next.prepareForChange(from: previous)
  #expect(next.enabled && next.location == nil)
  previous.enabled = true
  previous.prepareForSession()  // The same scrub runs before the pause/sleep worker handoff.
  next.location = location
  next.prepareForChange(from: previous)
  #expect(next.location == nil)
  previous.source = .manual
  previous.location = location
  next.location = location
  next.prepareForChange(from: previous)
  #expect(next.location == nil)
  let encodedLocation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(location))
  let legacy: [String: Any] = ["enabled": true, "location": encodedLocation]
  let legacyData = try JSONSerialization.data(withJSONObject: legacy)
  let decoded = try JSONDecoder().decode(WeatherSettings.self, from: legacyData)
  #expect(decoded.enabled && decoded.source == .manual && decoded.location == location)
  for source in ["future-source", NSNull(), 7, ["unexpected": true]] as [Any] {
    var invalid = legacy
    invalid["source"] = source
    let data = try JSONSerialization.data(withJSONObject: invalid)
    let result = try JSONDecoder().decode(WeatherSettings.self, from: data)
    #expect(!result.enabled && result.location == nil)
  }
}
