import Foundation
import Testing

@testable import TinyStatsCore

private func gregorian(_ zone: String = "America/Los_Angeles") -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: zone)!
  return calendar
}
private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
  gregorian().date(from: .init(year: year, month: month, day: day, hour: hour))!
}
private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> AgendaEvent {
  .init(id: id, title: id, calendarTitle: "Work", start: start, end: end, allDay: allDay)
}

@Test func calendarPreferencesPreserveOptInAndNoneVersusAll() throws {
  let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
  #expect(!legacy.calendarEvents && legacy.calendarIDs == nil)
  var settings = Settings()
  settings.calendarEvents = true
  settings.calendarIDs = []
  let copy = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  #expect(copy.calendarEvents && copy.calendarIDs == [])
  settings.calendarIDs =
    ["", "same", "same", String(repeating: "x", count: 257)] + (0..<100).map(String.init)
  settings.validate()
  #expect(settings.calendarIDs?.count == 64)
  #expect(settings.calendarIDs?.first == "same")
  let invalid = try JSONDecoder().decode(
    Settings.self, from: Data(#"{"calendarEvents":"true","calendarIDs":4}"#.utf8))
  #expect(!invalid.calendarEvents && invalid.calendarIDs == [])
  let enabledInvalid = try JSONDecoder().decode(
    Settings.self, from: Data(#"{"calendarEvents":true,"calendarIDs":["work",123]}"#.utf8))
  #expect(enabledInvalid.calendarEvents && enabledInvalid.calendarIDs == [])
}

@Test func calendarDayBoundariesHandleDSTMidnightAndZeroDuration() throws {
  let calendar = gregorian()
  let spring = try #require(calendar.dateInterval(of: .day, for: date(2026, 3, 8)))
  let fall = try #require(calendar.dateInterval(of: .day, for: date(2026, 11, 1)))
  #expect(spring.duration == 23 * 3600)
  #expect(fall.duration == 25 * 3600)
  #expect(!event("previous", spring.start.addingTimeInterval(-3600), spring.start).overlaps(spring))
  #expect(!event("next", spring.end, spring.end.addingTimeInterval(3600)).overlaps(spring))
  #expect(event("ongoing", spring.start.addingTimeInterval(-3600), spring.end).overlaps(spring))
  #expect(event("instant", spring.start, spring.start).overlaps(spring))
  #expect(!event("reversed", spring.end, spring.start).overlaps(spring))
  #expect(
    !event("infinite", Date(timeIntervalSinceReferenceDate: .infinity), spring.end).overlaps(spring)
  )
}

@Test func calendarRowsAreBoundedSortedAndRetainRecurringOccurrences() throws {
  let day = try #require(gregorian().dateInterval(of: .day, for: date(2026, 10, 22)))
  var buffer = AgendaEventBuffer()
  for index in (0..<140).reversed() {
    let start = day.start.addingTimeInterval(Double(index + 1) * 60)
    buffer.append(event(String(index), start, start.addingTimeInterval(30)), in: day)
  }
  #expect(buffer.events.count == 128 && buffer.truncated)
  #expect(buffer.events.first?.id == "0")
  #expect(buffer.events.last?.id == "127")
  let allDay = event("all", day.start, day.end, allDay: true)
  buffer.append(allDay, in: day)
  buffer.append(allDay, in: day)
  #expect(buffer.events.first?.allDay == true)
  #expect(buffer.events.filter { $0.id == "all" }.count == 1)
  let recurring = event("all", day.start.addingTimeInterval(1), day.end, allDay: true)
  buffer.append(recurring, in: day)
  #expect(buffer.events.filter { $0.id == "all" }.count == 2)
  let hostile = AgendaEvent(
    id: "a", title: "\n\t", calendarTitle: String(repeating: "z", count: 200), start: day.start,
    end: day.end, allDay: false)
  #expect(hostile.title == "Untitled event" && hostile.calendarTitle.count == 80)
}

@Test func calendarTimeLabelsIdentifySpanningEvents() throws {
  let day = try #require(gregorian().dateInterval(of: .day, for: date(2026, 10, 22)))
  let formatter = DateFormatter()
  formatter.timeZone = gregorian().timeZone
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "HH:mm"
  #expect(
    event("overnight", day.start.addingTimeInterval(-60), day.end.addingTimeInterval(60)).timeLabel(
      in: day, formatter: formatter) == "←–→")
  #expect(
    event("meeting", date(2026, 10, 22, 10), date(2026, 10, 22, 11)).timeLabel(
      in: day, formatter: formatter) == "10:00–11:00")
  #expect(
    event("all", day.start, day.end, allDay: true).timeLabel(in: day, formatter: formatter)
      == "All day")
}

private final class CalendarFixture: CalendarAgendaSource, @unchecked Sendable {
  private let lock = NSLock()
  private var reads: [CalendarAgendaRequest] = []
  private var releases = 0, permissions = 0
  var gate: DispatchSemaphore?
  var result = CalendarAgendaSnapshot()
  func read(_ request: CalendarAgendaRequest) -> CalendarAgendaSnapshot {
    lock.lock()
    reads.append(request)
    lock.unlock()
    gate?.wait()
    return result
  }
  func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
    lock.lock()
    permissions += 1
    lock.unlock()
    completion(false)
  }
  func releaseStore() {
    lock.lock()
    releases += 1
    lock.unlock()
  }
  func counts() -> (reads: Int, releases: Int, permissions: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (reads.count, releases, permissions)
  }
  func lastRequest() -> CalendarAgendaRequest? {
    lock.lock()
    defer { lock.unlock() }
    return reads.last
  }
}
@MainActor private func waitFor(_ condition: () -> Bool) async throws {
  for _ in 0..<2000 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(condition(), "Calendar fixture did not finish")
}

@Test @MainActor func calendarReaderOptInVisibilityAndCoalescing() async throws {
  let source = CalendarFixture()
  source.result.access = .fullAccess
  source.result.calendars = [.init(id: "work", title: "Work", source: "Local")]
  let changes = CalendarChangeFlag()
  let reader = CalendarAgendaReader(source: source, changes: changes)
  reader.configure(
    enabled: false, selectedIDs: nil, day: date(2026, 10, 22), configurationVisible: false)
  reader.tick(at: 0)
  reader.requestAccess()
  #expect(source.counts().reads == 0 && source.counts().permissions == 0)
  reader.configure(enabled: true, selectedIDs: nil, day: nil, configurationVisible: false)
  reader.tick(at: 0)
  #expect(source.counts().reads == 0)
  reader.configure(enabled: false, selectedIDs: [], day: nil, configurationVisible: true)
  reader.tick(at: 1)
  try await waitFor { reader.snapshot.checkedAt != nil }
  #expect(source.lastRequest()?.day == nil && source.lastRequest()?.selectedIDs == [])
  reader.tick(at: 2)
  #expect(source.counts().reads == 1)
  changes.mark()
  let changedAt = Date(timeIntervalSince1970: 3)
  reader.tick(at: 3, date: changedAt)
  try await waitFor { reader.snapshot.checkedAt == changedAt }
  let refreshedAt = Date(timeIntervalSince1970: 63)
  reader.tick(at: 63, date: refreshedAt)
  try await waitFor { reader.snapshot.checkedAt == refreshedAt }
  #expect(source.counts().reads == 3)
  #expect(source.counts().permissions == 0)
  reader.configure(
    enabled: true, selectedIDs: ["work"], day: date(2026, 10, 23), configurationVisible: true)
  #expect(reader.snapshot.calendars.map(\.id) == ["work"])
  #expect(reader.snapshot.events.isEmpty && reader.snapshot.refreshing)
}

@Test @MainActor func calendarReaderRejectsStaleResultsAndReleasesAfterDisable() async throws {
  let source = CalendarFixture()
  source.gate = DispatchSemaphore(value: 0)
  source.result.access = .fullAccess
  source.result.events = [event("private", date(2026, 10, 22, 10), date(2026, 10, 22, 11))]
  let reader = CalendarAgendaReader(source: source)
  reader.configure(
    enabled: true, selectedIDs: nil, day: date(2026, 10, 22), configurationVisible: false)
  reader.tick(at: 0)
  try await waitFor { source.counts().reads == 1 }
  for index in 1...50 {
    reader.configure(
      enabled: true, selectedIDs: [], day: date(2026, 10, 23), configurationVisible: false)
    reader.tick(at: Double(index))
  }
  reader.configure(enabled: false, selectedIDs: nil, day: nil, configurationVisible: false)
  #expect(reader.snapshot.events.isEmpty)
  source.gate?.signal()
  try await waitFor { source.counts().releases == 1 }
  #expect(source.counts().reads == 1)
  #expect(reader.snapshot.events.isEmpty && reader.snapshot.access == .off)
}

@Test @MainActor func calendarPermissionRequiresExplicitActionAndSuspensionPurges() async throws {
  let source = CalendarFixture()
  source.result.access = .denied
  let reader = CalendarAgendaReader(source: source)
  reader.configure(
    enabled: true, selectedIDs: nil, day: date(2026, 10, 22), configurationVisible: true)
  reader.tick(at: 0)
  try await waitFor { reader.snapshot.access == .denied }
  #expect(source.counts().permissions == 0)
  reader.requestAccess()
  try await waitFor { !reader.requestingAccess }
  #expect(source.counts().permissions == 1)
  reader.configure(
    enabled: true, selectedIDs: nil, day: date(2026, 10, 22), configurationVisible: true,
    suspended: true)
  try await waitFor { source.counts().releases == 1 }
  #expect(reader.snapshot.events.isEmpty && reader.snapshot.calendars.isEmpty)
}
