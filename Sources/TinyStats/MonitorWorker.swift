import Foundation
import TinyStatsCore

protocol MonitorSampling: AnyObject {
  func reset()
  func configureInternetChecks(_ settings: Settings)
  func configureWeather(_ settings: WeatherSettings)
  func clearProcessBaselines()
  func stopNetworkDetails()
  func sample(settings: Settings, includeProcesses: Bool, detailModule: Module?) -> Snapshot
}
extension Sampler: MonitorSampling {}

/// The queue is the sole owner of mutable sampling state. UI calls enqueue work.
final class MonitorWorker: @unchecked Sendable {
  /// Tests may retain the tick and return nil to drive the same serial-queue work manually.
  typealias TimerFactory =
    @Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any DispatchSourceTimer)?
  private let queue = DispatchQueue(label: "app.tinystats.sampler", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var sampler: (any MonitorSampling)?
  private let makeSampler: @Sendable (DispatchQueue) -> any MonitorSampling
  private let powerState: @Sendable () -> Bool
  private let uptime: @Sendable () -> Double
  private let date: @Sendable () -> Date
  private let makeTimer: TimerFactory
  private var schedule = MonitorSchedule()
  private var clockPreviewSeconds: Bool?
  private var settings = Settings()
  private var history = RingBuffer<HistoryPoint>(capacity: 300)
  private var archive = SessionHistory()
  private let persistence: HistoryPersistence
  private var terminating = false
  private var started = false
  private var historyRange: HistoryRange?
  private var alerts = AlertEngine()
  private var detailModule: Module = .overview
  private var details = false, paused = false, sleeping = false, lowPower = false
  private let mailbox: DeliveryMailbox
  init(
    makeSampler: @escaping @Sendable (DispatchQueue) -> any MonitorSampling = {
      Sampler(queue: $0)
    },
    historyStore: @escaping HistoryPersistence.Factory = { _ in nil },
    powerState: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
    uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
    date: @escaping @Sendable () -> Date = { Date() },
    makeTimer: @escaping TimerFactory = { queue, tick in
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.setEventHandler(handler: tick)
      return timer
    },
    clock: @escaping @MainActor @Sendable (Date) -> Void = { _ in },
    history: @escaping @MainActor @Sendable (HistoryProjection) -> Void = { _ in },
    receive: @escaping @MainActor @Sendable (Snapshot, [HistoryPoint], [AlertEvent]) -> Void
  ) {
    self.persistence = HistoryPersistence(factory: historyStore)
    self.makeSampler = makeSampler
    self.powerState = powerState
    self.uptime = uptime
    self.date = date
    self.makeTimer = makeTimer
    self.mailbox = DeliveryMailbox(receive: receive, clock: clock, history: history)
  }
  func start(_ settings: Settings) {
    queue.async {
      guard !self.terminating, !self.started else { return }
      self.started = true
      self.settings = settings
      if let restored = self.persistence.begin(
        enabled: settings.persistHistory, now: self.date(), uptime: self.uptime())
      {
        self.archive = restored
      }
      self.alerts.configure(settings.rules)
      autoreleasepool { self.sampler = self.makeSampler(self.queue) }
      self.arm()
    }
  }
  func update(_ settings: Settings) {
    queue.async {
      guard !self.terminating else { return }
      var settings = settings
      settings.persistHistory = self.persistence.state.enabled
      let cadenceChanged = self.settings.interval != settings.interval
      if self.settings.processGrouping != settings.processGrouping
        || self.settings.networkTrafficRevision != settings.networkTrafficRevision
      {
        self.sampler?.stopNetworkDetails()
      }
      let oldClockStep = self.clockStep
      if self.settings.alerts != settings.alerts { self.alerts.resetSustainedConditions() }
      self.settings = settings
      self.sampler?.configureInternetChecks(settings)
      self.sampler?.configureWeather(settings.weather)
      self.alerts.configure(settings.rules)
      if cadenceChanged {
        self.arm()
      } else if oldClockStep != self.clockStep {
        self.arm(resetSchedule: false)
      }
    }
  }
  func setDetails(_ visible: Bool, module: Module = .overview) {
    queue.async {
      guard !self.terminating else { return }
      let oldClockStep = self.clockStep
      let leavingGPU = self.detailModule == .gpu && module != .gpu
      self.details = visible
      self.detailModule = module
      if !visible || !Self.showsProcesses(module) || leavingGPU {
        self.sampler?.clearProcessBaselines()
      }
      if !visible || module != .network { self.sampler?.stopNetworkDetails() }
      if oldClockStep != self.clockStep { self.arm(resetSchedule: false) }
    }
  }
  func setHistoryRange(_ range: HistoryRange?) {
    queue.async {
      guard !self.terminating else { return }
      self.historyRange = range
      if let range { self.mailbox.submitHistory(self.projection(range)) }
    }
  }
  private func projection(_ range: HistoryRange) -> HistoryProjection {
    var value = archive.projection(range)
    value.storage = persistence.state
    return value
  }
  private func publishHistory() {
    if let historyRange { mailbox.submitHistory(projection(historyRange)) }
  }
  func setHistoryPersistence(_ enabled: Bool, completion: @escaping @MainActor @Sendable () -> Void)
  {
    queue.async {
      guard !self.terminating else {
        Task { @MainActor in completion() }
        return
      }
      self.settings.persistHistory = enabled
      self.persistence.setEnabled(
        enabled, archive: &self.archive, now: self.date(), uptime: self.uptime())
      self.publishHistory()
      Task { @MainActor in completion() }
    }
  }
  func clearHistory(completion: @escaping @MainActor @Sendable () -> Void) {
    queue.async {
      guard !self.terminating else {
        Task { @MainActor in completion() }
        return
      }
      self.persistence.clear(uptime: self.uptime())
      self.archive = SessionHistory()
      self.publishHistory()
      Task { @MainActor in completion() }
    }
  }
  func finishHistory(completion: @escaping @MainActor @Sendable () -> Void) {
    queue.async {
      if !self.terminating {
        self.terminating = true
        self.timer?.cancel()
        self.timer = nil
        self.persistence.checkpoint(
          self.archive, now: self.date(), uptime: self.uptime(), force: true)
      }
      HistoryQuitCoordinator.deliver(completion)
    }
  }
  func setDetailModule(_ module: Module) {
    queue.async {
      guard !self.terminating else { return }
      let oldClockStep = self.clockStep
      let leavingGPU = self.detailModule == .gpu && module != .gpu
      self.detailModule = module
      if module != .network {
        self.sampler?.stopNetworkDetails()
      }
      if !Self.showsProcesses(module) || leavingGPU {
        self.sampler?.clearProcessBaselines()
      }
      if oldClockStep != self.clockStep { self.arm(resetSchedule: false) }
    }
  }
  func setPaused(_ paused: Bool, settings: Settings? = nil) {
    queue.async {
      guard !self.terminating else { return }
      self.paused = paused
      if var settings {
        settings.persistHistory = self.persistence.state.enabled
        self.settings = settings
      }
      self.resetAndArm()
    }
  }
  func setSleeping(_ sleeping: Bool, settings: Settings? = nil) {
    queue.async {
      guard !self.terminating else { return }
      if sleeping {
        self.persistence.checkpoint(
          self.archive, now: self.date(), uptime: self.uptime(), force: true)
      }
      self.sleeping = sleeping
      if var settings {
        settings.persistHistory = self.persistence.state.enabled
        self.settings = settings
      }
      self.resetAndArm()
    }
  }
  func powerChanged() { queue.async { self.arm() } }
  func setClockPreview(seconds: Bool?) {
    queue.async {
      guard !self.terminating else { return }
      let old = self.clockStep
      self.clockPreviewSeconds = seconds
      if old != self.clockStep { self.arm(resetSchedule: false) }
    }
  }
  func invalidateClock() { queue.async { self.arm(resetSchedule: false) } }
  private static func showsProcesses(_ module: Module) -> Bool {
    module == .cpu || module == .memory || module == .disks
  }
  private var clockStep: Double? {
    let style = settings.style(for: .clock)
    let visible =
      settings.readouts.contains(.clock)
      && (style.showsClockTime || (!settings.clockMenu.custom && style == .label))
    if clockPreviewSeconds == true || (visible && settings.clockMenu.includesSeconds)
      || (details && detailModule == .clock && settings.worldClockIncludesSeconds)
    {
      return 1
    }
    return visible || clockPreviewSeconds != nil || (details && detailModule == .clock) ? 60 : nil
  }
  private var collectionInterval: Double { max(settings.interval, lowPower ? 5 : 1) }
  private func resetAndArm() {
    sampler?.reset()
    alerts.resetSustainedConditions()
    arm()
  }
  private func arm(resetSchedule: Bool = true) {
    timer?.cancel()
    timer = nil
    if resetSchedule { schedule.reset() } else { schedule.invalidateClock() }
    guard !terminating && !paused && !sleeping else { return }
    lowPower = powerState()
    let timer = makeTimer(queue) { [weak self] in self?.tick() }
    timer?.schedule(deadline: .now())
    self.timer = timer
    timer?.resume()
  }
  private func tick() {
    autoreleasepool {
      guard !terminating, let sampler else { return }
      let decision = schedule.next(
        at: uptime(), date: date(), interval: collectionInterval,
        clockStep: clockStep)
      if decision.collect {
        let snapshot = sampler.sample(
          settings: settings,
          includeProcesses: details && Self.showsProcesses(detailModule),
          detailModule: details ? detailModule : nil)
        var point = snapshot.historyPoint
        point.sampleInterval = collectionInterval
        history.append(point)
        if archive.append(
          point, uptime: snapshot.uptime, preservingPastOnReset: persistence.state.enabled)
        {
          persistence.markDirty()
        }
        persistence.checkpoint(archive, now: date(), uptime: uptime())
        if let historyRange { mailbox.submitHistory(projection(historyRange)) }
        let points = details || settings.needsMenuBarHistory ? history.elements : []
        let events = settings.alerts ? alerts.evaluate(snapshot, now: snapshot.uptime) : []
        mailbox.submit(snapshot, history: points, events: events)
        schedule.collectionFinished(
          at: uptime(), interval: collectionInterval)
      }
      if decision.clock || (decision.collect && clockStep != nil) { mailbox.submitClock(date()) }
      let now = uptime()
      let delay = max(0.001, schedule.deadline(at: now, date: date(), clockStep: clockStep) - now)
      timer?.schedule(
        deadline: .now() + delay,
        leeway: .milliseconds(clockStep == 1 ? 20 : min(1000, Int(delay * 100))))
    }
  }
}

/// At most one queued main-actor delivery; slow UI work never grows a snapshot queue.
private final class DeliveryMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: (Snapshot, [HistoryPoint])?
  private var events: [String: AlertEvent] = [:]
  private var scheduled = false
  private var clockDate: Date?
  private var archive: HistoryProjection?
  private let history: @MainActor @Sendable (HistoryProjection) -> Void
  private let receive: @MainActor @Sendable (Snapshot, [HistoryPoint], [AlertEvent]) -> Void
  private let clock: @MainActor @Sendable (Date) -> Void
  init(
    receive: @escaping @MainActor @Sendable (Snapshot, [HistoryPoint], [AlertEvent]) -> Void,
    clock: @escaping @MainActor @Sendable (Date) -> Void,
    history: @escaping @MainActor @Sendable (HistoryProjection) -> Void
  ) {
    self.receive = receive
    self.clock = clock
    self.history = history
  }
  func submit(_ snapshot: Snapshot, history: [HistoryPoint], events: [AlertEvent]) {
    lock.lock()
    latest = (snapshot, history)
    for event in events { self.events[event.id] = event }
    let shouldSchedule = !scheduled
    scheduled = true
    lock.unlock()
    if shouldSchedule { deliver() }
  }
  func submitHistory(_ projection: HistoryProjection) {
    lock.lock()
    archive = projection
    let shouldSchedule = !scheduled
    scheduled = true
    lock.unlock()
    if shouldSchedule { deliver() }
  }
  func submitClock(_ date: Date) {
    lock.lock()
    clockDate = date
    let shouldSchedule = !scheduled
    scheduled = true
    lock.unlock()
    if shouldSchedule { deliver() }
  }
  private func deliver() {
    Task { @MainActor [self] in
      let (sample, events, date, projection) = take()
      if let sample { receive(sample.0, sample.1, events) }
      if let date { clock(date) }
      if let projection { history(projection) }
    }
  }
  private func take() -> ((Snapshot, [HistoryPoint])?, [AlertEvent], Date?, HistoryProjection?) {
    lock.lock()
    defer { lock.unlock() }
    let result = (latest, Array(events.values), clockDate, archive)
    latest = nil
    clockDate = nil
    archive = nil
    events.removeAll(keepingCapacity: true)
    scheduled = false
    return result
  }
}
