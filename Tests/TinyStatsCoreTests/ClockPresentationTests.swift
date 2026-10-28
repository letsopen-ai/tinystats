import Foundation
import Testing

@testable import TinyStatsCore

@Test func clockDialsUseClockwiseHandsAndNeverInventMissingComponents() throws {
  let minute = try #require(ClockDialReading(hour: 3, minute: 30))
  #expect(minute.hourDegrees == 105 && minute.minuteDegrees == 180 && minute.secondDegrees == nil)
  let second = try #require(ClockDialReading(hour: 15, minute: 30, second: 30))
  #expect(
    second.hourDegrees == 105.25 && second.minuteDegrees == 183 && second.secondDegrees == 180)
  #expect(second.accessibleTime == "15:30:30" && minute.accessibleTime == "03:30")
  let midnight = try #require(ClockDialReading(hour: 0, minute: 0, second: 0))
  #expect(midnight.hourDegrees == 0 && midnight.minuteDegrees == 0 && midnight.secondDegrees == 0)
  for reading in [
    ClockDialReading(hour: nil, minute: 0), ClockDialReading(hour: 24, minute: 0),
    ClockDialReading(hour: 1, minute: 60), ClockDialReading(hour: 1, minute: 0, second: -1),
    ClockDialReading(hour: 1, minute: 0, second: 60),
  ] {
    #expect(reading == nil)
  }
}

@Test func fuzzyClockRoundsAcrossHoursAndMidnightAndOffsetsRetainFractionalZones() {
  let examples: [(Int, Int, String)] = [
    (0, 0, "twelve o’clock"), (11, 58, "twelve o’clock"), (23, 59, "twelve o’clock"),
    (12, 2, "twelve o’clock"), (12, 3, "five past twelve"), (12, 15, "quarter past twelve"),
    (12, 32, "half past twelve"), (12, 33, "twenty-five to one"), (12, 45, "quarter to one"),
    (12, 57, "five to one"),
  ]
  for (hour, minute, expected) in examples {
    #expect(ClockPresentation.fuzzy(hour: hour, minute: minute) == expected)
  }
  #expect(ClockPresentation.fuzzy(hour: nil, minute: 0) == nil)
  #expect(ClockPresentation.fuzzy(hour: 24, minute: 0) == nil)
  #expect(ClockPresentation.fuzzy(hour: 0, minute: -1) == nil)
  #expect(ClockPresentation.offset(seconds: 0) == "+00:00")
  #expect(ClockPresentation.offset(seconds: -8100) == "-02:15")
  #expect(ClockPresentation.offset(seconds: 20700) == "+05:45")
  #expect(ClockPresentation.offset(seconds: 93600) == "+26:00")
  #expect(ClockPresentation.offset(seconds: -20701) == "-05:45:01")
  #expect(ClockPresentation.offset(seconds: .min) == "—")
}

@Test func graphicClockTokensRoundTripAndOnlySecondsDialsRequestSecondTicks() throws {
  let entry = ClockMenuEntry(
    zone: "Asia/Kathmandu", firstLine: "{calendar} {analogSeconds}",
    secondLine: "{fuzzy} {localOffset}")
  let settings = ClockMenuSettings(custom: true, entries: [entry])
  #expect(entry.isValid && settings.includesSeconds)
  #expect(
    try JSONDecoder().decode(ClockMenuSettings.self, from: JSONEncoder().encode(settings))
      == settings)
  #expect(
    !ClockMenuEntry(firstLine: "{analog} {calendar} {fuzzy}", secondLine: "{localOffset}")
      .includesSeconds)
  #expect(ClockFormat("{{analogSeconds}}")?.includesSeconds == false)
  #expect(ClockFormat("{analogSeconds}")?.parts == [.token(.analogSeconds)])
}
