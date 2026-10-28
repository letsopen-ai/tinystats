import Foundation
import Testing

@testable import TinyStatsCore

@Test func worldClockFormatsMigrateRejectMalformedValuesAndPreserveOptIns() throws {
  for raw in [
    "{}", #"{"worldClockFormat":17}"#, #"{"worldClockFormat":"{unknown}"}"#,
    #"{"worldClockFormat":"{analog}"}"#, #"{"worldClockFormat":"   "}"#,
  ] {
    let value = try JSONDecoder().decode(Settings.self, from: Data(raw.utf8))
    #expect(value.worldClockFormat == WorldClockFormat.standard)
    #expect(!value.worldClockIncludesSeconds)
    #expect(!value.calendarEvents && !value.weather.enabled && !value.alerts)
  }
  for invalid in ["{calendar}", "{analogSeconds}", "a\nb", String(repeating: "x", count: 97)] {
    #expect(WorldClockFormat.parse(invalid) == nil)
    var value = Settings()
    value.worldClockFormat = invalid
    value.validate()
    #expect(value.worldClockFormat == WorldClockFormat.standard)
  }
  var value = Settings()
  value.worldClockFormat = "团队 {{clock}} {hour24}:{minute}:{second} {localOffset}"
  #expect(value.worldClockIncludesSeconds)
  let encoded = try JSONEncoder().encode(value)
  #expect(try JSONDecoder().decode(Settings.self, from: encoded) == value)
  value.worldClocks = []
  #expect(!value.worldClockIncludesSeconds)
  #expect(WorldClockFormat.parse("{{second}}")?.includesSeconds == false)
  for separator in ["\u{2028}", "\u{2029}"] {
    let data = try JSONSerialization.data(withJSONObject: [
      "worldClocks": ["UTC"], "worldClockNames": ["UTC": "A\(separator)B"],
    ])
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.worldClocks == ["UTC"] && decoded.worldClockNames.isEmpty)
    #expect(WorldClockEntry.parse("A\(separator)B=UTC") == nil)
  }
}

@Test func namedWorldClocksParseLegacyMixedUnicodeAndEmptyListsWithoutLosingZones() throws {
  let entries = try #require(
    WorldClockEntry.parse("UTC, London office=Europe/London, 团队=Asia/Shanghai"))
  #expect(entries.map(\.zone) == ["UTC", "Europe/London", "Asia/Shanghai"])
  #expect(entries.map(\.name) == [nil, "London office", "团队"])
  #expect(entries[0].title == "UTC" && entries[1].title == "London office")
  #expect(WorldClockEntry.parse(entries.map(\.input).joined(separator: ", ")) == entries)
  #expect(WorldClockEntry.parse(" , , ") == [])
  #expect(WorldClockEntry.parse("=UTC")?.first?.name == nil)
  #expect(WorldClockEntry.parse("Work = Europe/London, ")?.first?.name == "Work")
}

@Test func namedWorldClocksRejectAmbiguousDuplicateInvalidAndUnboundedDraftsAtomically() {
  for bad in [
    "UTC,not/a/zone", "Office=", "A=B=UTC", "UTC, UTC", "A=UTC, B=UTC",
    "A\nB=UTC", String(repeating: "x", count: 41) + "=UTC",
    Array(repeating: "UTC", count: 7).joined(separator: ","), String(repeating: ",", count: 1025),
  ] {
    #expect(WorldClockEntry.parse(bad) == nil)
  }
  #expect(WorldClockEntry(zone: "UTC", name: String(repeating: "🌍", count: 32)) != nil)
  #expect(WorldClockEntry(zone: "UTC", name: String(repeating: "🌍", count: 33)) == nil)
  #expect(WorldClockEntry(zone: "UTC", name: "A,B") == nil)
}

@Test func worldClockLabelsMigrateIndependentlyRoundTripAndNeverExpandOtherOptIns() throws {
  let legacy = try JSONDecoder().decode(
    Settings.self, from: Data(#"{"worldClocks":["UTC","America/Los_Angeles"]}"#.utf8))
  #expect(legacy.worldClockNames.isEmpty)
  #expect(legacy.worldClockEntries.map(\.title) == ["UTC", "America/Los Angeles"])
  let damaged = Data(
    #"{"worldClocks":["bad/zone","UTC","Europe/London","Asia/Shanghai"],"worldClockNames":{"UTC":"Build server","Europe/London":7,"Asia/Shanghai":"团队","Europe/Paris":"Unused"}}"#
      .utf8)
  var value = try JSONDecoder().decode(Settings.self, from: damaged)
  #expect(value.worldClocks == ["UTC", "Europe/London", "Asia/Shanghai"])
  #expect(value.worldClockNames == ["UTC": "Build server", "Asia/Shanghai": "团队"])
  #expect(value.worldClockEntries.map(\.title) == ["Build server", "Europe/London", "团队"])
  #expect(
    !value.calendarEvents && !value.weather.enabled && !value.connectivityChecks
      && !value.publicIPChecks)
  let encoded = try JSONEncoder().encode(value)
  #expect(try JSONDecoder().decode(Settings.self, from: encoded) == value)
  value.worldClocks = []
  value.validate()
  #expect(value.worldClockNames.isEmpty && value.worldClockEntries.isEmpty)
}

@Test
func worldClockValidationBoundsVisibleRowsAndFallsBackFromDamagedNamesWithoutDroppingTimeZones() {
  var value = Settings()
  value.worldClocks = [
    "UTC", "UTC", "Europe/London", "Europe/Paris", "Asia/Shanghai", "Asia/Tokyo",
    "America/New_York", "Australia/Sydney",
  ]
  value.worldClockNames = [
    "UTC": "bad=name", "Europe/London": " London office ", "bad/zone": "Orphan",
  ]
  #expect(value.worldClockEntries.first?.title == "UTC")
  #expect(value.worldClockEntries.count == 6)
  value.validate()
  #expect(value.worldClocks.count == 6 && Set(value.worldClocks).count == 6)
  #expect(value.worldClockNames == ["Europe/London": "London office"])
  #expect(value.worldClockInput.hasPrefix("UTC, London office=Europe/London"))
}
