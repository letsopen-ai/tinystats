import Foundation
import Testing

@testable import TinyStatsCore

@Test func menuBarWeightDefaultsAndInvalidSavedValuesUseRegular() throws {
  #expect(Settings().menuBarWeight == .regular)
  for json in [
    "{}", #"{"menuBarWeight":"future"}"#, #"{"menuBarWeight":null}"#,
    #"{"menuBarWeight":42}"#,
  ] {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.menuBarWeight == .regular)
  }
}

@Test(arguments: MenuBarWeight.allCases)
func menuBarWeightPersistsInSettings(weight: MenuBarWeight) throws {
  var settings = Settings()
  settings.menuBarWeight = weight
  let encoded = try JSONEncoder().encode(settings)
  let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect(object["menuBarWeight"] as? String == weight.rawValue)
  #expect(try JSONDecoder().decode(Settings.self, from: encoded).menuBarWeight == weight)
  let suite = "TinyStats.WeightTests." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  settings.save(to: defaults)
  #expect(Settings.load(from: defaults).menuBarWeight == weight)
}
