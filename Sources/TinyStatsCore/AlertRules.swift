import Foundation

public enum RuleMetric: String, Codable, CaseIterable, Sendable {
  case cpuUsage, gpuUsage, memoryUsage, memoryPressure, volumeUsage, diskRead, diskWrite
  case download, upload, interfaceState, sensor, batteryLevel, batteryPower, powerSource
  case thermalState, storageHealth, httpsState, httpsLatency, publicIPChange
  case weatherTemperature, weatherWind, weatherPrecipitation

  public var title: String {
    switch self {
    case .cpuUsage: "CPU usage"
    case .gpuUsage: "GPU usage"
    case .memoryUsage: "Memory usage"
    case .memoryPressure: "Memory pressure"
    case .volumeUsage: "Volume used space"
    case .diskRead: "Disk read speed"
    case .diskWrite: "Disk write speed"
    case .download: "Download speed"
    case .upload: "Upload speed"
    case .interfaceState: "Network interface state"
    case .sensor: "Sensor reading"
    case .batteryLevel: "Battery level"
    case .batteryPower: "Battery power"
    case .powerSource: "Power source"
    case .thermalState: "Thermal state"
    case .storageHealth: "SMART warning"
    case .httpsState: "HTTPS response state"
    case .httpsLatency: "HTTPS response time"
    case .publicIPChange: "Observed public-IP change"
    case .weatherTemperature: "Forecast temperature"
    case .weatherWind: "Forecast wind speed"
    case .weatherPrecipitation: "Forecast precipitation · next hour"
    }
  }
  public var states: [String] {
    switch self {
    case .memoryPressure: ["Normal", "Warning", "Critical"]
    case .interfaceState: ["Down", "Up"]
    case .powerSource: ["On battery", "External power"]
    case .thermalState: ["Nominal", "Fair", "Serious", "Critical"]
    case .storageHealth: ["Warning reported"]
    case .httpsState: ["Request failed", "Expected response", "Unexpected response"]
    case .publicIPChange: ["Observed change"]
    default: []
    }
  }
  public var isWeather: Bool {
    [.weatherTemperature, .weatherWind, .weatherPrecipitation].contains(self)
  }
  public var equalityOnly: Bool {
    self == .interfaceState || self == .powerSource || self == .storageHealth || self == .httpsState
      || self == .publicIPChange
  }
}
public enum RuleComparison: String, Codable, CaseIterable, Sendable {
  case atLeast, atMost, equals
  public var title: String {
    switch self {
    case .atLeast: "At least (≥)"
    case .atMost: "At most (≤)"
    case .equals: "Equals (=)"
    }
  }
  public func matches(_ value: Double, threshold: Double) -> Bool {
    guard value.isFinite, threshold.isFinite else { return false }
    switch self {
    case .atLeast: return value >= threshold
    case .atMost: return value <= threshold
    case .equals: return value == threshold
    }
  }
}

public struct AlertRule: Codable, Equatable, Sendable {
  public static let limit = 32
  public var id: String
  public var metric: RuleMetric
  public var name = "", enabled = false, source = "any"
  public var sensorKind: SensorReading.Kind = .temperature
  public var comparison: RuleComparison = .atLeast
  public var threshold: Double = 90, hold: Double = 30, cooldown: Double = 900
  public var repeatWhileActive = true, sound = false, onlyOnBattery = true
  public var title: String { name.isEmpty ? metric.title : name }
  public init(id: String = UUID().uuidString, metric: RuleMetric = .cpuUsage) {
    self.id = id
    self.metric = metric
    switch metric {
    case .cpuUsage, .gpuUsage, .memoryUsage: threshold = 90
    case .memoryPressure:
      threshold = 2
      hold = 10
    case .volumeUsage:
      threshold = 95
      hold = 10
    case .diskRead, .diskWrite, .download, .upload: threshold = 10
    case .sensor:
      source = "cpu"
      threshold = 80
    case .batteryLevel:
      threshold = 20
      comparison = .atMost
      hold = 0
    case .batteryPower:
      threshold = -20
      comparison = .atMost
    case .interfaceState:
      source = "selected"
      threshold = 0
      hold = 10
    case .powerSource:
      threshold = 0
      hold = 0
    case .httpsState:
      source = "apple"
      threshold = 0
    case .httpsLatency:
      source = "apple"
      threshold = 1000
    case .publicIPChange:
      source = "ipv4"
      threshold = 0
      hold = 0
      repeatWhileActive = false
    case .weatherTemperature:
      source = "chosen-location"
      threshold = 30
      hold = 0
    case .weatherWind:
      source = "chosen-location"
      threshold = 10
      hold = 0
    case .weatherPrecipitation:
      source = "chosen-location"
      threshold = 0.1
      hold = 0
    case .thermalState: threshold = 2
    case .storageHealth:
      threshold = 0
      hold = 0
    }
    if metric == .download || metric == .upload { source = "selected" }
    if metric.equalityOnly { comparison = .equals }
  }
  private enum CodingKeys: String, CodingKey {
    case id, metric, name, enabled, source, sensorKind, comparison, threshold, hold, cooldown
    case repeatWhileActive, sound, onlyOnBattery
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(String.self, forKey: .id),
      metric: try c.decode(RuleMetric.self, forKey: .metric))
    threshold = try c.decode(Double.self, forKey: .threshold)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    source = try c.decodeIfPresent(String.self, forKey: .source) ?? source
    sensorKind = try c.decodeIfPresent(SensorReading.Kind.self, forKey: .sensorKind) ?? sensorKind
    comparison = try c.decodeIfPresent(RuleComparison.self, forKey: .comparison) ?? comparison
    hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? hold
    cooldown = try c.decodeIfPresent(Double.self, forKey: .cooldown) ?? cooldown
    repeatWhileActive =
      try c.decodeIfPresent(Bool.self, forKey: .repeatWhileActive) ?? repeatWhileActive
    sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
    onlyOnBattery = try c.decodeIfPresent(Bool.self, forKey: .onlyOnBattery) ?? onlyOnBattery
  }
  public var unit: String {
    switch metric {
    case .cpuUsage, .gpuUsage, .memoryUsage, .volumeUsage, .batteryLevel: "%"
    case .diskRead, .diskWrite, .download, .upload: "MiB/s"
    case .sensor: sensorKind.unit
    case .batteryPower: "W · negative = discharging"
    case .httpsLatency: "ms · full HTTPS response"
    case .weatherTemperature: "°C · model forecast"
    case .weatherWind: "m/s · model forecast"
    case .weatherPrecipitation: "mm · next 1h forecast"
    default: ""
    }
  }
  public var thresholdRange: ClosedRange<Double> {
    if !metric.states.isEmpty { return 0...Double(metric.states.count - 1) }
    switch metric {
    case .cpuUsage, .gpuUsage, .memoryUsage, .volumeUsage, .batteryLevel: return 0...100
    case .diskRead, .diskWrite, .download, .upload: return 0...1_000_000
    case .batteryPower: return -500...500
    case .httpsLatency: return 0...12_000
    case .weatherTemperature: return -150...100
    case .weatherWind: return 0...200
    case .weatherPrecipitation: return 0...2000
    case .sensor:
      switch sensorKind {
      case .temperature: return -100...200
      case .fan: return 0...20_000
      case .power: return 0...1_500
      case .voltage: return 0...60
      case .current: return -300...300
      }
    default: return 0...100
    }
  }
  public var validationError: String? {
    let validID =
      !id.isEmpty && id.utf8.count <= 64
      && id.utf8.allSatisfy { byte in
        switch byte {
        case 48...57, 65...90, 97...122, 45, 46, 95: return true
        default: return false
        }
      }
    if !validID { return "Rule ID is invalid." }
    if name.count > 64 { return "Use at most 64 characters for the name." }
    if source.isEmpty || source.utf8.count > 1024 { return "Choose a valid source." }
    if (metric == .httpsState || metric == .httpsLatency) && source != "apple" {
      return "Choose the configured HTTPS check as the source."
    }
    if metric == .publicIPChange && !["ipv4", "ipv6"].contains(source) {
      return "Choose IPv4 or IPv6."
    }
    if metric.isWeather && source != "chosen-location" {
      return "Choose the configured weather location."
    }
    if metric == .publicIPChange && hold != 0 {
      return "Public-IP changes are observations; duration must be zero."
    }
    if metric == .sensor && !SensorReading.validKey(source, kind: sensorKind) {
      return "Choose a valid sensor key with matching units."
    }
    if source == "cpu" && metric == .sensor && sensorKind != .temperature {
      return "CPU temperature requires temperature units."
    }
    if !threshold.isFinite || !thresholdRange.contains(threshold) {
      return
        "Threshold must be between \(thresholdRange.lowerBound) and \(thresholdRange.upperBound) \(unit)."
    }
    if !metric.states.isEmpty && threshold.rounded() != threshold { return "Choose a valid state." }
    if metric.equalityOnly && comparison != .equals { return "This state requires Equals." }
    if !hold.isFinite || !(0...86400).contains(hold) { return "Duration must be 0–86400 seconds." }
    if !cooldown.isFinite || !(30...86400).contains(cooldown) {
      return "Cooldown must be 30–86400 seconds."
    }
    return nil
  }
  public static func validated(_ rules: [Self]) -> [Self] {
    var ids = Set<String>()
    return rules.prefix(limit).filter { $0.validationError == nil && ids.insert($0.id).inserted }
  }
  public static var defaults: [Self] {
    zip(
      ["cpu", "memory", "disk", "battery", "smart"],
      [RuleMetric.cpuUsage, .memoryPressure, .volumeUsage, .batteryLevel, .storageHealth]
    ).map { id, metric in
      var rule = Self(id: id, metric: metric)
      rule.enabled = true
      return rule
    }
  }
  public func format(_ value: Double) -> String {
    if !metric.states.isEmpty, value >= 0, value < Double(metric.states.count) {
      return metric.states[Int(value)]
    }
    let unit = metric == .batteryPower ? "W" : metric == .httpsLatency ? "ms" : unit
    return String(format: "%.2f", value) + (unit.isEmpty ? "" : " " + unit)
  }
}

struct RuleObservation {
  var value: Double, identity: String, label: String
  var healthDate: Date? = nil
  var eventID: String? = nil
  var eligible = true
}
extension AlertRule {
  func observation(in s: Snapshot, preferredSource: String? = nil) -> RuleObservation? {
    func reading(_ value: Double?, _ identity: String, _ label: String) -> RuleObservation? {
      guard let value, value.isFinite else { return nil }
      return .init(value: value, identity: identity, label: label)
    }
    func choose(_ values: [RuleObservation]) -> RuleObservation? {
      let ordered = values.sorted { $0.identity < $1.identity }
      let matching = ordered.filter { comparison.matches($0.value, threshold: threshold) }
      if matching.isEmpty, let preferredSource,
        !ordered.contains(where: { $0.identity == preferredSource })
      {
        return nil
      }
      return matching.first { $0.identity == preferredSource } ?? matching.first ?? ordered.first
    }
    func fresh(_ sampledAt: Double?, maximumAge: Double) -> Bool {
      guard let sampledAt else { return false }
      let age = s.uptime - sampledAt
      return age.isFinite && age >= 0 && age <= maximumAge
    }
    switch metric {
    case .cpuUsage: return reading(s.cpu?.usage, "cpu", "CPU")
    case .gpuUsage:
      let values = s.gpus.filter { $0.id != 0 && (source == "any" || "model:\($0.name)" == source) }
        .compactMap {
          reading($0.usage, "gpu:\($0.id)", $0.name)
        }
      return choose(values)
    case .memoryUsage: return reading(s.memory?.percent, "memory", "Memory")
    case .memoryPressure:
      guard let pressure = s.memory?.pressure, let rank = [1: 0.0, 2: 1.0, 4: 2.0][pressure] else {
        return nil
      }
      return reading(rank, "memory", "Memory pressure")
    case .volumeUsage:
      guard fresh(s.volumesSampledAt, maximumAge: 60) else { return nil }
      let values = s.volumes.filter { $0.total > 0 && (source == "any" || $0.path == source) }
        .compactMap { reading($0.percent, "mount:\($0.mountID):\($0.path)", $0.name) }
      return choose(values)
    case .diskRead:
      return reading(s.diskRead.map { $0 / 1_048_576 }, "disks", "Physical disk reads")
    case .diskWrite:
      return reading(s.diskWrite.map { $0 / 1_048_576 }, "disks", "Physical disk writes")
    case .download, .upload, .interfaceState:
      let name = source == "selected" ? s.selectedInterface : source
      guard let interface = s.interfaces.first(where: { $0.name == name }) else { return nil }
      let identity = interface.index == 0 ? name : "\(name):\(interface.index)"
      if metric == .interfaceState { return reading(interface.up ? 1 : 0, identity, name) }
      guard interface.up else { return nil }
      let speed = metric == .download ? interface.download : interface.upload
      return reading(speed.map { $0 / 1_048_576 }, identity, name)
    case .sensor:
      guard fresh(s.sensorsSampledAt, maximumAge: 15) else { return nil }
      guard let sensor = s.sensor(for: source), sensor.kind == sensorKind else { return nil }
      return reading(sensor.value, source, sensor.name)
    case .batteryLevel, .batteryPower, .powerSource:
      guard fresh(s.batteriesSampledAt, maximumAge: 15) else { return nil }
      guard let battery = s.batteries.first else { return nil }
      if metric == .powerSource {
        return reading(battery.externalPower ? 1 : 0, battery.name, battery.name)
      }
      var result = reading(
        metric == .batteryLevel ? battery.percent : battery.watts, battery.name, battery.name)
      if metric == .batteryLevel && onlyOnBattery && battery.externalPower {
        result?.eligible = false
      }
      return result
    case .httpsState, .httpsLatency:
      let checks = s.internetChecks
      guard checks.connectivityEnabled, let result = checks.connectivity,
        fresh(result.checkedAt, maximumAge: 90)
      else { return nil }
      if metric == .httpsLatency && result.state != .expected { return nil }
      return reading(
        metric == .httpsState ? Double(result.state.rawValue) : result.milliseconds,
        "https:\(checks.revision):\(checks.httpsCheck.customURL):\(checks.httpsCheck.expectedStatus)",
        s.internetChecks.httpsCheck.title)
    case .publicIPChange:
      let checks = s.internetChecks
      let result = source == "ipv6" ? checks.ipv6 : checks.ipv4
      guard checks.publicIPEnabled, let result, result.address != nil,
        fresh(result.checkedAt, maximumAge: 330)
      else { return nil }
      return .init(
        value: result.changeID == nil ? -1 : 0, identity: source,
        label: source == "ipv6" ? "Public IPv6 observation" : "Public IPv4 observation",
        eventID: result.changeID)
    case .weatherTemperature, .weatherWind, .weatherPrecipitation:
      guard s.weather.settings.enabled,
        let point = s.weather.current(at: s.uptime, date: s.timestamp)
      else { return nil }
      let value: Double?
      switch metric {
      case .weatherTemperature: value = point.celsius
      case .weatherWind: value = point.windMetersPerSecond
      default: value = point.periodHours == 1 ? point.precipitationMM : nil
      }
      return reading(
        value,
        "weather:" + s.weather.settings.revision + ":"
          + (s.weather.settings.location?.requestKey ?? ""), metric.title)
    case .thermalState:
      guard
        let rank = ["Nominal": 0.0, "Fair": 1.0, "Serious": 2.0, "Critical": 3.0][s.thermalState]
      else { return nil }
      return reading(rank, "thermal", "Thermal state")
    case .storageHealth:
      guard s.storageHealth.isFresh(at: s.timestamp) else { return nil }
      let drives = s.storageHealth.drives.filter {
        $0.available
          && (source == "any" || (!$0.stableID.isEmpty && "drive:" + $0.stableID == source))
      }
      let values = drives.map { drive in
        RuleObservation(
          value: drive.warning ? 0 : -1, identity: "drive:\(drive.id)", label: drive.name,
          healthDate: s.storageHealth.checkedAt)
      }
      return choose(values)
    }
  }
}
