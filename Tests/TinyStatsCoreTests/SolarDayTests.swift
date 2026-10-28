import Foundation
import Testing

@testable import TinyStatsCore

private func solarDate(_ value: String) -> Date {
  ISO8601DateFormatter().date(from: value)!
}
private func solarLocation(_ latitude: Double, _ longitude: Double, _ zone: String)
  -> WeatherLocation
{
  .init(latitude: latitude, longitude: longitude, name: "Public test location", timeZone: zone)
}

@Test func solarDayMatchesIndependentUSNOApparentHorizonReferences() throws {
  // USNO API v4.0.1 responses captured 2026-10-25; minute-rounded times,
  // independent ephemeris/refraction model. Full responses/provenance in research.
  let cases: [(String, Double, Double, String, String, String)] = [
    (
      "2026-10-25T16:00:00Z", 40.713, -74.006, "America/New_York",
      "2026-10-25T11:18:00Z", "2026-10-25T22:01:00Z"
    ),
    (
      "2026-03-29T12:00:00Z", 59.914, 10.752, "Europe/Oslo",
      "2026-03-29T04:52:00Z", "2026-03-29T17:53:00Z"
    ),
    (
      "2026-12-21T01:00:00Z", -33.869, 151.209, "Australia/Sydney",
      "2026-12-20T18:41:00Z", "2026-12-21T09:05:00Z"
    ),
    (
      "2026-12-21T00:00:00Z", -43.95, -176.55, "Pacific/Chatham",
      "2026-12-20T15:59:00Z", "2026-12-21T07:29:00Z"
    ),
  ]
  for (now, latitude, longitude, zone, rise, set) in cases {
    let day = try #require(
      SolarDay.calculate(on: solarDate(now), location: solarLocation(latitude, longitude, zone)))
    #expect(day.state == .crossings && day.events.count == 2)
    let sunrise = try #require(day.events.first { $0.kind == .sunrise })
    let sunset = try #require(day.events.first { $0.kind == .sunset })
    #expect(abs(sunrise.date.timeIntervalSince(solarDate(rise))) < 90, "USNO sunrise: \(zone)")
    #expect(abs(sunset.date.timeIntervalSince(solarDate(set))) < 90, "USNO sunset: \(zone)")
    #expect(abs(day.daylightDuration - solarDate(set).timeIntervalSince(solarDate(rise))) < 120)
    #expect(day.isDaylight(at: sunrise.date.addingTimeInterval(1)))
    #expect(!day.isDaylight(at: sunset.date.addingTimeInterval(1)))
  }
}

@Test func solarDayUsesActualCivilDurationAcrossDSTAndFractionalOffsets() throws {
  for (date, zone, hours) in [
    ("2026-03-08T16:00:00Z", "America/New_York", 23.0),
    ("2026-11-01T16:00:00Z", "America/New_York", 25.0),
    ("2026-03-29T12:00:00Z", "Europe/Oslo", 23.0),
    ("2026-10-25T12:00:00Z", "Europe/Oslo", 25.0),
    ("2026-10-04T05:00:00Z", "Australia/Lord_Howe", 23.5),
    ("2026-12-21T00:00:00Z", "Pacific/Chatham", 24.0),
  ] {
    let day = try #require(
      SolarDay.calculate(on: solarDate(date), location: solarLocation(40, -74, zone)))
    #expect(day.interval.duration == hours * 3600)
    #expect(day.events.allSatisfy { $0.date >= day.interval.start && $0.date < day.interval.end })
    #expect(
      day.daylight.allSatisfy { $0.start >= day.interval.start && $0.end <= day.interval.end })
    #expect(day.daylightDuration >= 0 && day.daylightDuration <= day.interval.duration)
  }
}

@Test func solarDayDistinguishesPolarDayNightAndExactPolesFromUnavailable() throws {
  for latitude in [69.649, 90.0, -90.0] {
    let location = solarLocation(latitude, 18.955, "Europe/Oslo")
    let summer = try #require(
      SolarDay.calculate(on: solarDate("2026-06-21T12:00:00Z"), location: location))
    let winter = try #require(
      SolarDay.calculate(on: solarDate("2026-12-21T12:00:00Z"), location: location))
    let light = latitude > 0 ? summer : winter
    let dark = latitude > 0 ? winter : summer
    #expect(light.events.isEmpty && light.state == .sunUpAllDay)
    #expect(light.daylightDuration == light.interval.duration)
    #expect(light.isDaylight(at: light.interval.start))
    #expect(!light.isDaylight(at: light.interval.end))
    #expect(dark.events.isEmpty && dark.state == .sunDownAllDay)
    #expect(dark.daylightDuration == 0)
  }
}

@Test func solarDayRefinesShortPolarIntervalsBetweenCoarseSamples() throws {
  let day = try #require(
    SolarDay.calculate(
      on: solarDate("2026-12-21T12:00:00Z"), location: solarLocation(67.395, 0, "UTC")))
  #expect(day.events.count == 2 && day.state == .crossings)
  #expect(day.daylightDuration > 0 && day.daylightDuration < 600)
  // The model's independently sampled ten-minute grid never sees the sun up.
  // Crossing-only scans therefore fail this case; an extremum must be examined.
  let horizon = sin(-0.833 * Double.pi / 180)
  #expect(
    (0...144).allSatisfy {
      SolarDay.elevationSine(
        unixSeconds: day.interval.start.timeIntervalSince1970 + Double($0) * 600,
        latitude: 67.395, longitude: 0) < horizon
    })
}

@Test func solarDayKeepsAbsoluteEventsAcrossZonesAndClipsMidnightDaylight() throws {
  let now = solarDate("2026-10-25T16:00:00Z")
  let local = try #require(
    SolarDay.calculate(on: now, location: solarLocation(40.713, -74.006, "America/New_York")))
  let utc = try #require(
    SolarDay.calculate(on: now, location: solarLocation(40.713, -74.006, "UTC")))
  for (a, b) in zip(local.events, utc.events) {
    #expect(a.kind == b.kind && abs(a.date.timeIntervalSince(b.date)) < 0.1)
  }
  let split = try #require(SolarDay.calculate(on: now, location: solarLocation(40.713, 120, "UTC")))
  #expect(split.daylight.count == 2)
  #expect(split.daylight.first?.start == split.interval.start)
  #expect(split.daylight.last?.end == split.interval.end)
  #expect(split.events.first?.kind == .sunset && split.events.last?.kind == .sunrise)
}

@Test func solarDayFindsShortDaylightInsideTheFirstCivilDayInterval() throws {
  let day = try #require(
    SolarDay.calculate(
      on: solarDate("2026-12-21T12:00:00Z"),
      location: solarLocation(67.398, 179, "UTC")))
  let peak = day.interval.start.addingTimeInterval(109)
  #expect(
    SolarDay.elevationSine(
      unixSeconds: peak.timeIntervalSince1970,
      latitude: 67.398, longitude: 179) > sin(-0.833 * Double.pi / 180))
  #expect(
    day.events.count == 2
      && day.events.allSatisfy {
        $0.date.timeIntervalSince(day.interval.start) < 600
      })
  #expect(day.daylightDuration > 0 && day.daylightDuration < 600)
  #expect(day.isDaylight(at: peak))
}

@Test func solarDayFindsShortDaylightInsideTheLastCivilDayInterval() throws {
  let day = try #require(
    SolarDay.calculate(
      on: solarDate("2026-12-21T12:00:00Z"),
      location: solarLocation(67.395, -179.5, "UTC")))
  #expect(
    day.events.count == 2
      && day.events.allSatisfy {
        $0.date.timeIntervalSince(day.interval.start) > day.interval.duration - 600
          && $0.date < day.interval.end
      })
  #expect(day.daylightDuration > 0 && day.daylightDuration < 600)
  #expect(day.isDaylight(at: day.interval.start.addingTimeInterval(86180)))
}

@Test func solarDayAcceptsBothSupportedDateEndpoints() throws {
  for date in ["1901-01-01T12:00:00Z", "2099-12-31T12:00:00Z"] {
    let day = try #require(
      SolarDay.calculate(on: solarDate(date), location: solarLocation(0, 0, "UTC")))
    #expect(day.events.count == 2 && day.state == .crossings)
    #expect(day.daylightDuration > 11 * 3600 && day.daylightDuration < 13 * 3600)
  }
}

@Test func solarDayFindsShortNightBetweenCoarseSamples() throws {
  let day = try #require(
    SolarDay.calculate(
      on: solarDate("2026-06-21T12:00:00Z"),
      location: solarLocation(65.729, 90, "UTC")))
  #expect(
    day.events.count == 2 && day.events.first?.kind == .sunset && day.events.last?.kind == .sunrise)
  let night = day.interval.duration - day.daylightDuration
  #expect(night > 0 && night < 600 && day.daylight.count == 2)
  #expect(!day.isDaylight(at: day.interval.start.addingTimeInterval(64913)))
  let horizon = sin(-0.833 * Double.pi / 180)
  #expect(
    (0...144).allSatisfy {
      SolarDay.elevationSine(
        unixSeconds: day.interval.start.timeIntervalSince1970 + Double($0) * 600,
        latitude: 65.729, longitude: 90) > horizon
    })
}

@Test func solarDayKeepsASingleSeasonalPoleCrossingAndClippedDuration() throws {
  let day = try #require(
    SolarDay.calculate(
      on: solarDate("2026-03-18T12:00:00Z"),
      location: solarLocation(90, 0, "UTC")))
  #expect(day.events.count == 1 && day.events.first?.kind == .sunrise)
  #expect(day.state == .crossings && day.daylight.count == 1)
  #expect(
    day.daylight.first?.start == day.events.first?.date
      && day.daylight.last?.end == day.interval.end)
  #expect(
    !day.isDaylight(at: day.interval.start)
      && day.isDaylight(at: day.interval.end.addingTimeInterval(-1)))
}

@Test func solarDayRejectsInvalidInputsAndUnsupportedDates() {
  let now = solarDate("2026-10-25T12:00:00Z")
  for location in [
    solarLocation(.nan, 0, "UTC"), solarLocation(91, 0, "UTC"),
    solarLocation(0, .infinity, "UTC"), solarLocation(0, 181, "UTC"),
    solarLocation(0, 0, "Not/AZone"),
  ] {
    #expect(SolarDay.calculate(on: now, location: location) == nil)
  }
  let location = solarLocation(0, 0, "UTC")
  for date in [
    Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
    Date(timeIntervalSince1970: .greatestFiniteMagnitude),
    solarDate("1900-06-21T12:00:00Z"), solarDate("2100-06-21T12:00:00Z"),
  ] {
    #expect(SolarDay.calculate(on: date, location: location) == nil)
  }
}

@Test func solarDayCacheInvalidatesDayCoordinateZoneAndMissingLocation() throws {
  let calculator = SolarDayCalculator()
  let now = solarDate("2026-10-25T16:00:00Z")
  var location = solarLocation(40.713, -74.006, "America/New_York")
  let first = try #require(calculator.day(on: now, location: location))
  #expect(calculator.day(on: now.addingTimeInterval(10), location: location) == first)
  location.name = "A name change does not change solar geometry"
  #expect(calculator.day(on: now, location: location) == first)
  let next = try #require(calculator.day(on: now.addingTimeInterval(86400), location: location))
  #expect(next.interval != first.interval)
  location.longitude = 10
  #expect(calculator.day(on: now, location: location)?.events != first.events)
  location.timeZone = "UTC"
  #expect(calculator.day(on: now, location: location)?.timeZone == "GMT")
  #expect(calculator.day(on: now, location: nil) == nil && calculator.value == nil)
  #expect(
    calculator.day(on: Date(timeIntervalSince1970: .greatestFiniteMagnitude), location: location)
      == nil)
}
