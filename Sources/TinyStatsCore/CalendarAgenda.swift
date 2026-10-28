import Foundation

public enum CalendarAccess: String, Sendable, Equatable {
  case off, notDetermined, denied, restricted, writeOnly, fullAccess, unavailable
  public var message: String {
    switch self {
    case .off: "Calendar events are off · enable in Calendar settings"
    case .notDetermined: "Calendar access has not been requested"
    case .denied: "Calendar access denied · change in System Settings"
    case .restricted: "Calendar access is restricted by macOS"
    case .writeOnly: "Full calendar access is needed to read events"
    case .fullAccess: "Read-only agenda · macOS Calendar accounts"
    case .unavailable: "Calendar access is unavailable"
    }
  }
}

public struct AgendaCalendar: Sendable, Equatable {
  public var id: String, title: String, source: String
  public init(id: String, title: String, source: String) {
    self.id = id
    self.title = AgendaText.clean(title, limit: 80, fallback: "Untitled calendar")
    self.source = AgendaText.clean(source, limit: 80, fallback: "Calendar")
  }
}

public struct AgendaEvent: Sendable, Equatable {
  public var id: String, title: String, calendarTitle: String
  public var start: Date, end: Date, allDay: Bool
  public init(
    id: String, title: String, calendarTitle: String, start: Date, end: Date, allDay: Bool
  ) {
    self.id = String(id.prefix(256))
    self.title = AgendaText.clean(title, limit: 160, fallback: "Untitled event")
    self.calendarTitle = AgendaText.clean(calendarTitle, limit: 80, fallback: "Calendar")
    self.start = start
    self.end = end
    self.allDay = allDay
  }
  /// Half-open day boundaries exclude events ending at midnight from the following day.
  public func overlaps(_ day: DateInterval) -> Bool {
    guard start.timeIntervalSinceReferenceDate.isFinite,
      end.timeIntervalSinceReferenceDate.isFinite, end >= start
    else { return false }
    return start < day.end && (end > day.start || (end == start && start >= day.start))
  }
  public func timeLabel(in day: DateInterval, formatter: DateFormatter) -> String {
    if allDay { return "All day" }
    let startText = start < day.start ? "←" : formatter.string(from: start)
    let endText = end >= day.end ? "→" : formatter.string(from: end)
    return startText + "–" + endText
  }
  static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.allDay != rhs.allDay { return lhs.allDay }
    if lhs.start != rhs.start { return lhs.start < rhs.start }
    if lhs.end != rhs.end { return lhs.end < rhs.end }
    if lhs.title != rhs.title { return lhs.title < rhs.title }
    return lhs.id < rhs.id
  }
}

enum AgendaText {
  static func clean(_ text: String, limit: Int, fallback: String) -> String {
    let result = String(
      text.prefix(limit).unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) ? " " : String($0)
      }.joined()
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? fallback : result
  }
}

public struct CalendarAgendaSnapshot: Sendable, Equatable {
  public var access: CalendarAccess = .off
  public var calendars: [AgendaCalendar] = []
  public var events: [AgendaEvent] = []
  public var day: DateInterval?
  public var checkedAt: Date?
  public var refreshing = false
  public var calendarsTruncated = false, eventsTruncated = false
  public var selectedCalendarCount = 0
  public init() {}
}

struct AgendaEventBuffer {
  private(set) var events: [AgendaEvent] = []
  private(set) var truncated = false
  mutating func append(_ event: AgendaEvent, in day: DateInterval) {
    guard event.overlaps(day) else { return }
    // Repeated occurrences have distinct starts; never deduplicate on identifier alone.
    if !event.id.isEmpty && events.contains(where: { $0.id == event.id && $0.start == event.start })
    {
      return
    }
    events.append(event)
    events.sort(by: AgendaEvent.precedes)
    if events.count > 128 {
      events.removeLast()
      truncated = true
    }
  }
}

struct CalendarAgendaRequest: Sendable, Equatable {
  var day: DateInterval?
  var selectedIDs: [String]?
}

/// Native objects stay on a single utility queue; only bounded value snapshots cross it.
protocol CalendarAgendaSource: AnyObject, Sendable {
  func read(_ request: CalendarAgendaRequest) -> CalendarAgendaSnapshot
  func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void)
  func releaseStore()
}

final class CalendarChangeFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false
  func mark() {
    lock.lock()
    changed = true
    lock.unlock()
  }
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = changed
    changed = false
    return value
  }
}

/// No timer. The app's existing deliveries drive refreshes only for visible calendar UI.
/// At most one slow operation, with latest-demand coalescing and stale-result rejection.
@MainActor public final class CalendarAgendaReader {
  public private(set) var snapshot = CalendarAgendaSnapshot()
  public var onChange: (() -> Void)?
  public private(set) var requestingAccess = false
  private let queue = DispatchQueue(label: "app.tinystats.calendar", qos: .utility)
  private let source: any CalendarAgendaSource
  private let changes: CalendarChangeFlag
  private var wanted: CalendarAgendaRequest?
  private var generation: UInt64 = 0
  private var busy = false, releaseNeeded = false, storeUsed = false
  private var lastRequest = -Double.infinity
  private var invalidated = true
  public convenience init() {
    let changes = CalendarChangeFlag()
    self.init(source: NativeCalendarAgendaSource(changes: changes), changes: changes)
  }
  init(source: any CalendarAgendaSource, changes: CalendarChangeFlag = .init()) {
    self.source = source
    self.changes = changes
  }
  public func configure(
    enabled: Bool, selectedIDs: [String]?, day: Date?, configurationVisible: Bool,
    suspended: Bool = false, calendar: Calendar = .current
  ) {
    let interval = enabled ? day.flatMap { calendar.dateInterval(of: .day, for: $0) } : nil
    let next: CalendarAgendaRequest? =
      !suspended && (interval != nil || configurationVisible)
      ? .init(day: interval, selectedIDs: selectedIDs) : nil
    guard next != wanted else { return }
    generation &+= 1
    let retainCatalog = wanted != nil && next != nil
    wanted = next
    invalidated = true
    if retainCatalog {
      snapshot.events = []
      snapshot.checkedAt = nil
    } else {
      snapshot = .init()
    }
    snapshot.day = interval
    snapshot.refreshing = next != nil
    onChange?()
    if next == nil {
      releaseNeeded = storeUsed || busy
      releaseIfIdle()
    }
  }
  public func tick(at time: Double, date: Date = Date()) {
    guard time.isFinite, let request = wanted, !busy else { return }
    if changes.take() { invalidated = true }
    guard invalidated || time < lastRequest || time - lastRequest >= 60 else { return }
    if releaseNeeded {
      releaseIfIdle()
      return
    }
    busy = true
    storeUsed = true
    invalidated = false
    lastRequest = time
    let token = generation
    let source = source
    queue.async { [weak self] in
      let result = autoreleasepool { source.read(request) }
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.busy = false
        if self.generation == token, self.wanted == request {
          self.snapshot = result
          self.snapshot.day = request.day
          self.snapshot.checkedAt = date
          self.snapshot.refreshing = false
          self.onChange?()
        }
        self.releaseIfIdle()
      }
    }
  }
  /// Call only from the user's explicit Allow Calendar Access action.
  public func requestAccess() {
    guard wanted != nil, !busy, !requestingAccess else { return }
    requestingAccess = true
    busy = true
    storeUsed = true
    let source = source
    queue.async { [self] in
      source.requestAccess { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.busy = false
          self.requestingAccess = false
          self.generation &+= 1
          self.invalidated = true
          self.snapshot = .init()
          self.onChange?()
          self.releaseIfIdle()
        }
      }
    }
    onChange?()
  }
  private func releaseIfIdle() {
    guard releaseNeeded, !busy else { return }
    busy = true
    releaseNeeded = false
    storeUsed = false
    let source = source
    queue.async { [weak self] in
      autoreleasepool { source.releaseStore() }
      Task { @MainActor [weak self] in self?.busy = false }
    }
  }
}
