import Foundation

public enum AppTheme: String, Codable, CaseIterable, Sendable {
  case system, light, dark
  public var title: String { rawValue.capitalized }
}

public enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
  case text, stacked, value, label, icon, history, historyValue, bar, labeledBar, horizontal, pie,
    ring, cores,
    battery
  public var usesHistory: Bool { self == .history || self == .historyValue }
  public var usesFont: Bool { [.text, .stacked, .value, .label, .historyValue].contains(self) }
  public var title: String {
    switch self {
    case .text: "Label + value"
    case .stacked: "Stacked label + value"
    case .value: "Value only"
    case .label: "Label only"
    case .icon: "Icon only"
    case .history: "History graph"
    case .historyValue: "History + value"
    case .bar: "Vertical gauge"
    case .labeledBar: "Labeled vertical gauge"
    case .horizontal: "Labeled horizontal gauge"
    case .pie: "Pie gauge"
    case .ring: "Ring gauge"
    case .cores: "Per-core bars"
    case .battery: "Battery icon"
    }
  }
  public static func available(for module: Module, sensorKey: String = "cpu") -> [Self] {
    let basic: [Self] = [.text, .stacked, .value, .label, .icon]
    if module == .clock || module == .weather { return basic }
    let graphs = basic + [.history, .historyValue]
    if module == .network
      || (module == .sensors && sensorKey != "cpu" && !sensorKey.hasPrefix("T"))
    {
      return graphs
    }
    var result = graphs + [.bar, .labeledBar, .horizontal, .pie, .ring]
    if module == .cpu { result.append(.cores) }
    if module == .battery { result.append(.battery) }
    return result
  }
  public var showsClockTime: Bool { self == .text || self == .stacked || self == .value }
}

public enum MenuBarSize: String, Codable, CaseIterable, Sendable {
  case compact, standard, large
  public var title: String { rawValue.capitalized }
  public var pointSize: Double {
    switch self {
    case .compact: 10
    case .standard: 11
    case .large: 13
    }
  }
}

/// Semantic system colors adapt to the current appearance. Rendering follows the system accent; legacy color choices remain decodable.
public enum MenuBarColor: String, Codable, CaseIterable, Sendable {
  case automatic, blue, green, orange, pink, purple, red
  public var title: String { rawValue.capitalized }
}

public struct MenuBarAppearance: Codable, Equatable, Sendable {
  public var size: MenuBarSize = .standard
  public var color: MenuBarColor = .automatic
  public init(size: MenuBarSize = .standard, color: MenuBarColor = .automatic) {
    self.size = size
    self.color = color
  }
  private enum CodingKeys: String, CodingKey { case size, color }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    size = (try? values.decode(MenuBarSize.self, forKey: .size)) ?? .standard
    color = (try? values.decode(MenuBarColor.self, forKey: .color)) ?? .automatic
  }
}

public struct Settings: Codable, Equatable, Sendable {
  public var theme: AppTheme = .system
  public var interval: Double = 2
  public var separateItems = true
  public var readouts: [Module] = [.cpu, .memory, .network]
  public var networkInterface = "auto"
  public var networkTrafficGrouping: TrafficGrouping = .processes
  public var networkTrafficRevision = ""
  public var fahrenheit = false
  public var batteryMenu = BatteryMenuSettings()
  public var clockMenu = ClockMenuSettings()
  public var worldClocks = ["UTC", "America/Los_Angeles", "Asia/Shanghai"]
  public var worldClockNames: [String: String] = [:]
  public var worldClockFormat = WorldClockFormat.standard
  public var calendarEvents = false
  /// nil selects all discovered calendars; an empty list deliberately selects none.
  public var calendarIDs: [String]?
  /// nil follows the system locale; Foundation weekday numbers are Sunday=1 ... Saturday=7.
  public var calendarFirstWeekday: Int?
  public var sensorKey = "cpu"
  public var connectivityChecks = false, publicIPChecks = false
  public var internetRevision = ""
  public var httpsCheck = HTTPSCheckConfiguration()
  public var pingCheck = ICMPCheckConfiguration()
  public var weather = WeatherSettings()
  public var persistHistory = true
  public var monitorStorageHealth = false
  public var rules = AlertRule.defaults
  public var alerts = false
  public var styles: [String: MenuBarStyle] = [:]
  public var appearances: [String: MenuBarAppearance] = [:]
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case persistHistory, theme, interval, separateItems, readouts, networkInterface,
      networkTrafficGrouping, networkTrafficRevision, fahrenheit,
      batteryMenu,
      clockMenu,
      worldClocks,
      worldClockNames,
      worldClockFormat,
      alerts,
      styles, appearances, sensorKey, monitorStorageHealth, rules, calendarEvents, calendarIDs,
      calendarFirstWeekday,
      connectivityChecks, publicIPChecks, internetRevision, httpsCheck, pingCheck, weather
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = Settings()
    persistHistory =
      container.contains(.persistHistory)
      ? ((try? container.decode(Bool.self, forKey: .persistHistory)) ?? false) : true
    theme = (try? container.decode(AppTheme.self, forKey: .theme)) ?? .system
    interval = (try? container.decode(Double.self, forKey: .interval)) ?? fallback.interval
    // Migrate legacy combined buttons: native per-readout identity gives reliable routing.
    separateItems = true
    // Keep every recognized choice in order, even if a future/damaged entry is present.
    // An explicitly malformed list must not enable the default set of extra readouts.
    if container.contains(.readouts) {
      readouts = []
      if var entries = try? container.nestedUnkeyedContainer(forKey: .readouts) {
        while !entries.isAtEnd {
          guard let entry = try? entries.superDecoder() else { break }
          if let raw = try? String(from: entry), let module = Module(rawValue: raw),
            module != .overview, !readouts.contains(module)
          {
            readouts.append(module)
          }
        }
      }
    } else {
      readouts = fallback.readouts
    }
    networkInterface =
      (try? container.decode(String.self, forKey: .networkInterface)) ?? fallback.networkInterface
    networkTrafficRevision =
      (try? container.decode(String.self, forKey: .networkTrafficRevision)) ?? ""
    networkTrafficGrouping =
      (try? container.decode(TrafficGrouping.self, forKey: .networkTrafficGrouping)) ?? .processes
    fahrenheit = (try? container.decode(Bool.self, forKey: .fahrenheit)) ?? fallback.fahrenheit
    batteryMenu = (try? container.decode(BatteryMenuSettings.self, forKey: .batteryMenu)) ?? .init()
    clockMenu = (try? container.decode(ClockMenuSettings.self, forKey: .clockMenu)) ?? .init()
    worldClockFormat =
      (try? container.decode(String.self, forKey: .worldClockFormat))
      ?? WorldClockFormat.standard
    if WorldClockFormat.parse(worldClockFormat) == nil {
      worldClockFormat = WorldClockFormat.standard
    }
    worldClocks =
      (try? container.decode([String].self, forKey: .worldClocks)) ?? fallback.worldClocks
    worldClocks = WorldClockEntry.validatedZones(worldClocks)
    // Decode only selected zones, independently; a damaged label cannot erase other clocks.
    if let names = try? container.nestedContainer(keyedBy: ModuleKey.self, forKey: .worldClockNames)
    {
      for zone in worldClocks.prefix(6) {
        if let key = ModuleKey(stringValue: zone),
          let name = try? names.decode(String.self, forKey: key)
        {
          worldClockNames[zone] = name
        }
      }
    }
    calendarEvents = (try? container.decode(Bool.self, forKey: .calendarEvents)) ?? false
    calendarFirstWeekday = try? container.decode(Int.self, forKey: .calendarFirstWeekday)
    if container.contains(.calendarIDs), (try? container.decodeNil(forKey: .calendarIDs)) != true {
      // A malformed selection must not expand a chosen subset to all calendars.
      calendarIDs = (try? container.decode([String].self, forKey: .calendarIDs)) ?? []
    }
    sensorKey = (try? container.decode(String.self, forKey: .sensorKey)) ?? fallback.sensorKey
    monitorStorageHealth =
      (try? container.decode(Bool.self, forKey: .monitorStorageHealth))
      ?? fallback.monitorStorageHealth
    weather = (try? container.decode(WeatherSettings.self, forKey: .weather)) ?? .init()
    internetRevision = (try? container.decode(String.self, forKey: .internetRevision)) ?? ""
    connectivityChecks = (try? container.decode(Bool.self, forKey: .connectivityChecks)) ?? false
    publicIPChecks = (try? container.decode(Bool.self, forKey: .publicIPChecks)) ?? false
    pingCheck = (try? container.decode(ICMPCheckConfiguration.self, forKey: .pingCheck)) ?? .init()
    if container.contains(.httpsCheck) {
      if let check = try? container.decode(HTTPSCheckConfiguration.self, forKey: .httpsCheck),
        check.validationError == nil
      {
        httpsCheck = check
      } else {
        connectivityChecks = false
      }
    }
    alerts = (try? container.decode(Bool.self, forKey: .alerts)) ?? fallback.alerts
    if container.contains(.rules) {
      rules = []
      if var entries = try? container.nestedUnkeyedContainer(forKey: .rules) {
        for _ in 0..<AlertRule.limit where !entries.isAtEnd {
          if let decoder = try? entries.superDecoder(), let rule = try? AlertRule(from: decoder) {
            rules.append(rule)
          }
        }
      }
    }
    let rawStyles = (try? container.decode([String: String].self, forKey: .styles)) ?? [:]
    styles = rawStyles.compactMapValues(MenuBarStyle.init(rawValue:))
    // Decode each entry independently so a damaged module cannot erase other choices.
    if let entries = try? container.nestedContainer(keyedBy: ModuleKey.self, forKey: .appearances) {
      for module in Module.allCases {
        let key = ModuleKey(stringValue: module.rawValue)!
        if let appearance = try? entries.decode(MenuBarAppearance.self, forKey: key) {
          appearances[module.rawValue] = appearance
        }
      }
    }
    validate()
  }
  private struct ModuleKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  public var needsMenuBarHistory: Bool {
    readouts.contains {
      style(for: $0).usesHistory || ($0 == .battery && batteryMenu.needsHistory)
    }
  }
  public func appearance(for module: Module) -> MenuBarAppearance {
    appearances[module.rawValue] ?? .init()
  }
  public func style(for module: Module) -> MenuBarStyle {
    let style = styles[module.rawValue] ?? .stacked
    return MenuBarStyle.available(for: module, sensorKey: sensorKey).contains(style)
      ? style : .stacked
  }
  public mutating func validate() {
    if httpsCheck.validationError != nil { connectivityChecks = false }
    if pingCheck.validationError != nil { pingCheck.enabled = false }
    weather.validate()
    batteryMenu.validate()
    clockMenu.validate()
    if let day = calendarFirstWeekday, !(1...7).contains(day) { calendarFirstWeekday = nil }
    if internetRevision.utf8.count > 64
      || !internetRevision.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      })
    {
      internetRevision = ""
      connectivityChecks = false
      publicIPChecks = false
      pingCheck.enabled = false
    }
    if let ids = calendarIDs {
      var seen = Set<String>()
      calendarIDs = Array(
        ids.filter { !$0.isEmpty && $0.count <= 256 && seen.insert($0).inserted }.prefix(64))
    }
    rules = AlertRule.validated(rules)
    if !SensorReading.validKey(sensorKey) {
      sensorKey = "cpu"
    }
    if ![1.0, 2, 5, 10].contains(interval) { interval = 2 }
    var seen = Set<Module>()
    readouts = readouts.filter { $0 != .overview && seen.insert($0).inserted }
    if readouts.isEmpty { readouts = [.cpu] }
    worldClocks = WorldClockEntry.validatedZones(worldClocks)
    worldClockNames = Dictionary(
      uniqueKeysWithValues: worldClocks.compactMap { zone in
        guard let raw = worldClockNames[zone] else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorldClockEntry.validName(name) ? (zone, name) : nil
      })
    if WorldClockFormat.parse(worldClockFormat) == nil {
      worldClockFormat = WorldClockFormat.standard
    }
    if networkInterface.isEmpty || networkInterface.count > 32 { networkInterface = "auto" }
  }
  public static func load(from defaults: UserDefaults = .standard) -> Settings {
    guard let data = defaults.data(forKey: "settings"),
      var value = try? JSONDecoder().decode(Self.self, from: data)
    else { return Settings() }
    value.validate()
    return value
  }
  public func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "settings") }
  }
}

public struct AlertEvent: Sendable, Equatable {
  public var rule: AlertRule, message: String
  public var id: String { rule.id }
  public var title: String { rule.title }
  public var sound: Bool { rule.sound }
  /// A queued event must still match the user's current notification choice.
  public var internetRevision: String?
  public var httpsConfiguration: HTTPSCheckConfiguration? = nil
  public var weatherConfiguration: WeatherSettings? = nil
  public var weatherValidUntil: Double? = nil
  public func canDeliver(
    with settings: Settings, suspended: Bool = false,
    now: Double = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    guard !suspended, settings.alerts, rule.enabled, settings.rules.contains(rule) else {
      return false
    }
    if rule.metric.isWeather {
      return settings.weather.enabled && weatherConfiguration == settings.weather
        && weatherValidUntil.map { now.isFinite && now <= $0 } == true
    }
    switch rule.metric {
    case .httpsState, .httpsLatency:
      return settings.connectivityChecks && internetRevision == settings.internetRevision
        && (httpsConfiguration ?? .init()) == settings.httpsCheck
    case .publicIPChange:
      return settings.publicIPChecks && internetRevision == settings.internetRevision
    default: return true
    }
  }
}
public struct AlertGate: Sendable {
  private var since: Double?, lastFired: Double?
  private var firedThisEpisode = false
  public init() {}
  public mutating func resetHold() {
    since = nil
    firedThisEpisode = false
  }
  public mutating func suspendCondition() { since = nil }
  public mutating func evaluate(
    active: Bool, now: Double, hold: Double, cooldown: Double = 900,
    repeatWhileActive: Bool = true, canFire: Bool = true
  ) -> Bool {
    guard active, now.isFinite else {
      resetHold()
      return false
    }
    if since == nil { since = now }
    guard let since, now >= since + hold, canFire,
      repeatWhileActive || !firedThisEpisode,
      lastFired.map({ now >= $0 + cooldown }) ?? true
    else { return false }
    lastFired = now
    firedThisEpisode = true
    return true
  }
}
public struct AlertEngine: Sendable {
  private struct State: Sendable {
    var rule: AlertRule
    var gate = AlertGate()
    var source: String?, notifiedHealthDate: Date?
    var notifiedEventID: String?
  }
  private var rules: [AlertRule] = []
  private var states: [String: State] = [:]
  public init(rules: [AlertRule] = AlertRule.defaults) { configure(rules) }
  public mutating func configure(_ proposed: [AlertRule]) {
    let next = AlertRule.validated(proposed)
    guard next != rules else { return }
    var retained: [String: State] = [:]
    for rule in next {
      var state = states[rule.id] ?? State(rule: rule)
      if state.rule != rule {
        state.gate.resetHold()
        state.source = nil
      }
      state.rule = rule
      retained[rule.id] = state
    }
    rules = next
    states = retained
  }
  public mutating func resetSustainedConditions() {
    for id in states.keys {
      states[id]?.gate.resetHold()
      states[id]?.source = nil
    }
  }
  public mutating func evaluate(_ snapshot: Snapshot, now: Double) -> [AlertEvent] {
    var events: [AlertEvent] = []
    for rule in rules {
      guard var state = states[rule.id] else { continue }
      guard rule.enabled else {
        state.gate.resetHold()
        state.source = nil
        states[rule.id] = state
        continue
      }
      guard let observation = rule.observation(in: snapshot, preferredSource: state.source) else {
        state.gate.suspendCondition()
        states[rule.id] = state
        continue
      }
      if observation.identity != state.source { state.gate.resetHold() }
      state.source = observation.identity
      if let eventID = observation.eventID, eventID != state.notifiedEventID {
        state.gate.resetHold()
      }
      let active =
        observation.eligible
        && rule.comparison.matches(observation.value, threshold: rule.threshold)
      let canFire =
        (rule.metric != .storageHealth || observation.healthDate != state.notifiedHealthDate)
        && (observation.eventID == nil || observation.eventID != state.notifiedEventID)
      if state.gate.evaluate(
        active: active, now: now, hold: rule.hold, cooldown: rule.cooldown,
        repeatWhileActive: rule.repeatWhileActive, canFire: canFire)
      {
        state.notifiedHealthDate = observation.healthDate
        if let eventID = observation.eventID { state.notifiedEventID = eventID }
        let duration =
          rule.hold == 0 ? "" : " for at least \(String(format: "%g", rule.hold)) seconds"
        let message =
          "\(observation.label): \(rule.format(observation.value)). Condition: \(rule.comparison.title) \(rule.format(rule.threshold))\(duration)."
        events.append(
          .init(
            rule: rule, message: message,
            internetRevision: [.httpsState, .httpsLatency, .publicIPChange].contains(rule.metric)
              ? snapshot.internetChecks.revision : nil,
            httpsConfiguration: [.httpsState, .httpsLatency].contains(rule.metric)
              ? snapshot.internetChecks.httpsCheck : nil,
            weatherConfiguration: rule.metric.isWeather ? snapshot.weather.settings : nil,
            weatherValidUntil: rule.metric.isWeather
              ? snapshot.weather.validUntil(at: snapshot.uptime, date: snapshot.timestamp) : nil))
      }
      states[rule.id] = state
    }
    return events
  }
}
