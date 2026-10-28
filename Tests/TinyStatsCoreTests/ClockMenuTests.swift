import Foundation
import Testing

@testable import TinyStatsCore

@Test func clockFormatsParseNamedTokensAndEscapedLiteralsWithBoundedLines() {
  let value = ClockFormat("🇨🇳 {name} {{at}} {hour24}:{minute}:{second}")
  #expect(value?.includesSeconds == true)
  #expect(value?.parts.contains(.literal(" {at} ")) == true)
  #expect(ClockFormat("{{second}}")?.includesSeconds == false)
  #expect(ClockFormat("👩‍💻 {name}") != nil)
  #expect(ClockFormat("a\u{2028}b") == nil)
  for bad in [
    "{", "}", "{minute", "{unknown}", "{minute}}", "a\nb", String(repeating: "x", count: 97),
  ] {
    #expect(ClockFormat(bad) == nil)
  }
  #expect(ClockFormat("")?.parts.isEmpty == true)
  #expect(ClockFormat(String(repeating: "x", count: 96)) != nil)
}

@Test func clockSettingsRecoverEachFieldAndCapEntriesWithoutChangingLegacyReadouts() throws {
  let data = Data(
    #"{"theme":"dark","worldClocks":["UTC"],"worldClockNames":{"UTC":"Build server"},"clockMenu":{"custom":true,"entries":[{"name":"Work","zone":"bad/zone","firstLine":"{hour24}","secondLine":"{unknown}"},{"name":"UTC","zone":"UTC","firstLine":"{systemTimeSeconds}","secondLine":""}]}}"#
      .utf8)
  let settings = try JSONDecoder().decode(Settings.self, from: data)
  #expect(settings.readouts == [.cpu, .memory, .network])
  #expect(settings.worldClockNames["UTC"] == "Build server" && settings.theme == .dark)
  #expect(settings.clockMenu.entries[0] == .init(name: "Work", firstLine: "{hour24}"))
  #expect(
    settings.clockMenu.entries[1].zone == "UTC" && settings.clockMenu.entries[1].secondLine.isEmpty)
  #expect(settings.clockMenu.includesSeconds)
  #expect(
    !settings.alerts && !settings.calendarEvents && !settings.weather.enabled
      && !settings.connectivityChecks)
  #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
  let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
  #expect(old.clockMenu == .init() && !old.clockMenu.includesSeconds)
  var many = ClockMenuSettings(custom: true, entries: Array(repeating: .init(), count: 10))
  #expect(many.entries.count == 6)
  many.entries = [.init(firstLine: "{bad}")]
  many.validate()
  #expect(many.entries == [.init()])
}

@Test func clockTickBoundariesDoNotIncreaseHardwareCollectionOrCatchUpMissedSamples() {
  var schedule = MonitorSchedule()
  let start = Date(timeIntervalSince1970: 100.25)
  let first = schedule.next(at: 10, date: start, interval: 5, clockStep: 1)
  #expect(first.collect && first.clock && first.deadline == 10.75)
  for second in 1...4 {
    let tick = schedule.next(
      at: 10 + Double(second), date: start.addingTimeInterval(Double(second)), interval: 5,
      clockStep: 1)
    #expect(!tick.collect && tick.clock)
  }
  #expect(
    schedule.next(at: 15, date: start.addingTimeInterval(5), interval: 5, clockStep: 1).collect)
  let late = schedule.next(at: 100, date: start.addingTimeInterval(90), interval: 5, clockStep: 1)
  #expect(late.collect && late.deadline > 100)
  #expect(
    !schedule.next(at: 100.1, date: start.addingTimeInterval(90.1), interval: 5, clockStep: 1)
      .collect)
  schedule.collectionFinished(at: 110, interval: 5)
  #expect(
    !schedule.next(at: 110.1, date: start.addingTimeInterval(100.1), interval: 5, clockStep: 1)
      .collect)
  #expect(schedule.deadline(at: 110.1, date: start, clockStep: nil) == 115)
}

@Test func clockScheduleHandlesOptOutWallJumpsModeChangesAndMonotonicReset() {
  var schedule = MonitorSchedule()
  let start = Date(timeIntervalSince1970: 10.25)
  #expect(schedule.next(at: 1, date: start, interval: 10, clockStep: nil).deadline == 11)
  let enable = schedule.next(at: 2, date: start, interval: 10, clockStep: 60)
  #expect(!enable.collect && enable.clock && enable.deadline == 11)
  let second = schedule.next(
    at: 3, date: Date(timeIntervalSince1970: 0.25), interval: 10, clockStep: 1)
  #expect(second.clock && !second.collect && second.deadline == 3.75)
  let jump = schedule.next(
    at: 4, date: Date(timeIntervalSince1970: -60.5), interval: 10, clockStep: 1)
  #expect(jump.clock && jump.deadline == 4.5)
  let disable = schedule.next(at: 5, date: start, interval: 10, clockStep: nil)
  #expect(!disable.clock && !disable.collect && disable.deadline == 11)
  #expect(schedule.next(at: 0, date: start, interval: 10, clockStep: nil).collect)
  let invalid = schedule.next(at: .nan, date: start, interval: .nan, clockStep: .nan)
  #expect(!invalid.collect && !invalid.clock && invalid.deadline.isFinite)
}
