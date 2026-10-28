import EventKit
import Foundation

/// Only CalendarAgendaReader's utility queue calls this adapter. It never writes events.
final class NativeCalendarAgendaSource: CalendarAgendaSource, @unchecked Sendable {
  private var store: EKEventStore?
  private var observer: NSObjectProtocol?
  private let changes: CalendarChangeFlag
  init(changes: CalendarChangeFlag) { self.changes = changes }
  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }
  private func eventStore() -> EKEventStore {
    if let store { return store }
    let store = EKEventStore()
    self.store = store
    let changes = changes
    observer = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: store, queue: nil
    ) { _ in changes.mark() }
    return store
  }
  func releaseStore() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    store = nil
  }
  func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
    eventStore().requestFullAccessToEvents { allowed, _ in completion(allowed) }
  }
  func read(_ request: CalendarAgendaRequest) -> CalendarAgendaSnapshot {
    var result = CalendarAgendaSnapshot()
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined: result.access = .notDetermined
    case .denied: result.access = .denied
    case .restricted: result.access = .restricted
    case .writeOnly: result.access = .writeOnly
    case .fullAccess: result.access = .fullAccess
    @unknown default: result.access = .unavailable
    }
    guard result.access == .fullAccess else {
      releaseStore()
      return result
    }
    let store = eventStore()
    // The framework supplies this catalog as an array; our retained catalog is bounded.
    let available = store.calendars(for: .event)
    result.calendarsTruncated = available.count > 64
    let calendars = Array(available.prefix(64))
    result.calendars = calendars.compactMap { calendar in
      let id = calendar.calendarIdentifier
      guard !id.isEmpty, id.count <= 256 else { return nil }
      return AgendaCalendar(id: id, title: calendar.title, source: calendar.source.title)
    }
    let ids = request.selectedIDs.map(Set.init)
    let selected = calendars.filter { ids?.contains($0.calendarIdentifier) ?? true }
    result.selectedCalendarCount = selected.count
    guard let day = request.day, !selected.isEmpty else { return result }
    let predicate = store.predicateForEvents(
      withStart: day.start, end: day.end, calendars: selected)
    var visited = 0
    var buffer = AgendaEventBuffer()
    // EventKit enumeration order is unspecified. Keep bounded earliest rows among all
    // examined candidates and explicitly report truncation if the scan limit is hit.
    store.enumerateEvents(matching: predicate) { event, stop in
      visited += 1
      if visited > 2048 {
        result.eventsTruncated = true
        stop.pointee = true
        return
      }
      guard event.status != .canceled, let start = event.startDate, let end = event.endDate else {
        return
      }
      let value = AgendaEvent(
        id: event.eventIdentifier ?? "", title: event.title ?? "",
        calendarTitle: event.calendar.title, start: start, end: end, allDay: event.isAllDay)
      buffer.append(value, in: day)
    }
    result.events = buffer.events
    result.eventsTruncated = result.eventsTruncated || buffer.truncated
    // An access revocation during a query must not leave private rows on screen.
    if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
      result = .init()
      result.access = .denied
      releaseStore()
    }
    return result
  }
}
