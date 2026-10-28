import Foundation
import Testing

@testable import TinyStatsCore

@Test func legacyAndMalformedWeekStartFollowTheSystemWithoutEnablingEvents() throws {
  #expect(
    try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).calendarFirstWeekday == nil)
  for raw in ["null", "0", "8", "-1", "true", "\"Monday\"", "{}"] {
    let data = Data("{\"calendarFirstWeekday\":\(raw),\"calendarIDs\":[]}".utf8)
    let value = try JSONDecoder().decode(Settings.self, from: data)
    #expect(value.calendarFirstWeekday == nil && !value.calendarEvents && value.calendarIDs == [])
  }
}

@Test(arguments: 1...7) func validWeekStartRoundTripsWithoutChangingAccountSelection(_ day: Int)
  throws
{
  var settings = Settings()
  settings.calendarFirstWeekday = day
  settings.calendarEvents = false
  settings.calendarIDs = ["chosen"]
  let saved = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  #expect(
    saved.calendarFirstWeekday == day && !saved.calendarEvents && saved.calendarIDs == ["chosen"])
  settings.calendarFirstWeekday = 0
  settings.validate()
  #expect(settings.calendarFirstWeekday == nil && settings.calendarIDs == ["chosen"])
}
