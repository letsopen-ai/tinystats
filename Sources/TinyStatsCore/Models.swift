import Foundation

public enum Module: String, Codable, CaseIterable, Sendable {
  case overview, cpu, gpu, memory, disks, network, sensors, battery, clock, weather
  public var title: String {
    switch self {
    case .overview: "Overview"
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .memory: "Memory"
    case .disks: "Disks"
    case .network: "Network"
    case .sensors: "Sensors"
    case .battery: "Power"
    case .clock: "Time"
    case .weather: "Weather"
    }
  }
  public var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .cpu: "cpu"
    case .gpu: "square.3.layers.3d"
    case .memory: "memorychip"
    case .disks: "internaldrive"
    case .network: "network"
    case .sensors: "thermometer.medium"
    case .battery: "battery.75percent"
    case .clock: "clock"
    case .weather: "cloud.sun"
    }
  }
}
public struct RingBuffer<Element: Sendable>: Sendable {
  private var storage: [Element?]
  private var next = 0
  public private(set) var count = 0
  public var capacity: Int { storage.count }
  public init(capacity: Int) {
    precondition(capacity > 0)
    storage = .init(repeating: nil, count: capacity)
  }
  public mutating func append(_ value: Element) {
    storage[next] = value
    next = (next + 1) % capacity
    count = min(count + 1, capacity)
  }
  public var elements: [Element] {
    (0..<count).compactMap { storage[(next - count + $0 + capacity) % capacity] }
  }
  /// Drop an ordered expired prefix and release its values without reallocating the ring.
  public mutating func removeFirst(while predicate: (Element) -> Bool) {
    while count > 0 {
      let first = (next - count + capacity) % capacity
      guard let value = storage[first], predicate(value) else { break }
      storage[first] = nil
      count -= 1
    }
  }
  public mutating func removeAll() {
    storage = .init(repeating: nil, count: capacity)
    next = 0
    count = 0
  }
}
/// A reset or first observation is unavailable, never a fabricated zero or spike.
public struct RateCounter: Sendable {
  private var previous: (value: UInt64, time: Double)?
  public init() {}
  public mutating func sample(_ value: UInt64, at time: Double) -> Double? {
    defer { previous = (value, time) }
    guard let previous, time.isFinite, time > previous.time, value >= previous.value else {
      return nil
    }
    return Double(value - previous.value) / (time - previous.time)
  }
  public mutating func reset() { previous = nil }
}
public struct CPUTicks: Sendable, Equatable {
  public var user, system, idle, nice: UInt32
  public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) {
    self.user = user
    self.system = system
    self.idle = idle
    self.nice = nice
  }
  public func utilization(since old: CPUTicks) -> Double? {
    components(since: old).map { min(100, $0.user + $0.system) }
  }
  public func components(since old: CPUTicks) -> (user: Double, system: Double)? {
    // Mach exports wrapping UInt32 tick counters. Modular subtraction handles wrap.
    let userTicks = UInt64(user &- old.user) + UInt64(nice &- old.nice)
    let systemTicks = UInt64(system &- old.system)
    let total = userTicks + systemTicks + UInt64(idle &- old.idle)
    return total > 0
      ? (
        Double(userTicks) / Double(total) * 100,
        Double(systemTicks) / Double(total) * 100
      ) : nil
  }
}
public struct CPUReading: Sendable {
  public var usage: Double?
  public var cores: [Double?]
  public var load: [Double]
  public var coreKinds: [CPUCoreKind] = []
  public var user: Double? = nil, system: Double? = nil
  public func kind(at index: Int) -> CPUCoreKind {
    coreKinds.count == cores.count && coreKinds.indices.contains(index)
      ? coreKinds[index] : .unknown
  }
}
public struct MemoryReading: Sendable {
  public var total, active, inactive, wired, compressed, free, speculative, purgeable, swapUsed,
    swapTotal: UInt64
  public var pressure: Int
  /// Activity Monitor-style working set; file cache and purgeable pages are reclaimable.
  public var used: UInt64 {
    total - composition.available
  }
  /// Bounded physical-RAM estimate. Inactive/cache/purgeable counters overlap;
  /// keep them out of the sum. The remainder includes cache and free memory.
  public var composition: (app: UInt64, wired: UInt64, compressed: UInt64, available: UInt64) {
    let pinned = min(total, wired)
    let packed = min(total - pinned, compressed)
    let app = min(total - pinned - packed, active > purgeable ? active - purgeable : 0)
    return (app, pinned, packed, total - pinned - packed - app)
  }
  public var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
  public var pressureDescription: String {
    switch pressure {
    case 1: "Normal"
    case 2: "Warning"
    case 4: "Critical"
    default: "Unavailable"
    }
  }
}
public struct GPUReading: Sendable {
  public var name: String, usage: Double?, memory: UInt64?
  public var id: UInt64 = 0
  public var coreCount: Int?
  public var rendererUsage: Double?, tilerUsage: Double?
}
public struct InterfaceReading: Sendable {
  public var name: String, address: String, up: Bool, received: UInt64, sent: UInt64,
    download: Double?, upload: Double?
  public var index: UInt32 = 0, mtu: UInt32 = 0
  public var running = false
  public var addresses: [NetworkAddress] = []
  public var addressesAvailable = false, addressesTruncated = false
}
public struct VolumeReading: Sendable {
  public var name: String, path: String, total: UInt64, available: UInt64
  public var mountID: UInt64 = 0
  public var percent: Double {
    total > 0 ? (1 - Double(min(available, total)) / Double(total)) * 100 : 0
  }
}
public struct DiskReading: Sendable {
  public var id: UInt64, name: String, read: Double?, written: Double?
}
public struct ProcessReading: Sendable {
  public var diskActivity: Double? {
    guard read != nil || written != nil else { return nil }
    return (read ?? 0) + (written ?? 0)
  }
  public var pid: Int32, name: String, cpu: Double?, memory: UInt64, read: Double?, written: Double?
}
public struct SensorReading: Sendable {
  /// Generic F0/F1 numbering does not identify a CPU or GPU fan on every Mac.
  public var fanOwner: SensorComponent? {
    guard kind == .fan else { return nil }
    let cpu = name.localizedCaseInsensitiveContains("CPU")
    let gpu = name.localizedCaseInsensitiveContains("GPU")
    if cpu && !gpu { return .cpu }
    if gpu && !cpu { return .gpu }
    return nil
  }

  public static func validKey(_ key: String, kind: Kind? = nil) -> Bool {
    if key == "cpu" { return kind == nil || kind == .temperature }
    if ["ioreport:cpu", "ioreport:gpu", "ioreport:ane", "ioreport:dram"].contains(key) {
      return kind == nil || kind == .power
    }
    return key.utf8.count == 4 && key.utf8.allSatisfy { (32...126).contains($0) }
  }
  public enum Kind: String, Codable, Sendable {
    case temperature, fan, power, voltage, current
    public var unit: String {
      switch self {
      case .temperature: "°C"
      case .fan: "RPM"
      case .power: "W"
      case .voltage: "V"
      case .current: "A"
      }
    }
  }
  public var key: String, name: String, kind: Kind, value: Double
  public var component: SensorComponent { SensorCatalog.component(for: self) }
  public var menuLabel: String {
    switch kind {
    case .temperature: return name.hasPrefix("CPU") ? "CPU" : name.hasPrefix("GPU") ? "GPU" : "TEMP"
    case .fan: return "FAN"
    case .power: return "PWR"
    case .voltage: return "VOLT"
    case .current: return "AMP"
    }
  }
  public func formatted(fahrenheit: Bool, compact: Bool = false) -> String {
    switch kind {
    case .temperature:
      let degrees = fahrenheit ? value * 1.8 + 32 : value
      return compact
        ? String(format: "%.0f°", degrees)
        : String(format: "%.1f°%@", degrees, fahrenheit ? "F" : "C")
    case .fan: return String(format: "%.0f rpm", value)
    default: return String(format: compact ? "%.1f%@" : "%.2f %@", value, unit)
    }
  }
  public var unit: String { kind.unit }
}
public struct BatteryReading: Sendable {
  public var name: String, percent: Double, charging: Bool, externalPower: Bool,
    minutesRemaining: Int?, cycles: Int?, health: Double?, watts: Double?
  /// OS charge-completion state. A held/paused charge must not be inferred as full from percent.
  public var fullyCharged: Bool? = nil
  public init(
    name: String, percent: Double, charging: Bool, externalPower: Bool,
    minutesRemaining: Int?, cycles: Int?, health: Double?, watts: Double?, fullyCharged: Bool? = nil
  ) {
    self.name = name
    self.percent = percent
    self.charging = charging
    self.externalPower = externalPower
    self.minutesRemaining = minutesRemaining
    self.cycles = cycles
    self.health = health
    self.watts = watts
    self.fullyCharged = fullyCharged
  }
}
public struct PeripheralBattery: Sendable { public var name: String, percent: Double }
public struct HistoryPoint: Sendable {
  public var time: Date, cpu: Double?, gpu: Double?, memory: Double?, download: Double?,
    upload: Double?, sensorValue: Double?, sensorKey: String?, diskRead: Double?,
    diskWrite: Double?, diskUsed: Double?, temperature: Double?,
    battery: Double?
  public var sensorKind: SensorReading.Kind? = nil
  public var cpuUser: Double? = nil, cpuSystem: Double? = nil
  public var cpuCores: CPUCoreHistorySample? = nil
  /// Nominal collection cadence at this sample, not an inferred elapsed duration.
  public var sampleInterval: Double? = nil
}
public struct Snapshot: Sendable {
  public var timestamp = Date(), uptime: Double = 0
  public var device = DeviceIdentity()
  public var cpu: CPUReading?, memory: MemoryReading?
  public var frequencies: [FrequencyReading] = []
  public var gpus: [GPUReading] = [], interfaces: [InterfaceReading] = [],
    volumes: [VolumeReading] = [], disks: [DiskReading] = []
  public var processes: [ProcessReading] = [], sensors: [SensorReading] = [],
    batteries: [BatteryReading] = [], peripherals: [PeripheralBattery] = []
  public var sensorsSampledAt: Double?, batteriesSampledAt: Double?, volumesSampledAt: Double?
  public var storageHealth = StorageHealthCache()
  public var selectedSensor: SensorReading?
  public var thermalState = "Nominal", lowPower = false, sampleMilliseconds: Double = 0
  public var download: Double?, upload: Double?
  public var cpuApps: [ProcessAppReading] = [], memoryApps: [ProcessAppReading] = []
  public var selectedInterface = "", processTimestamp: Date?
  public var networkConfiguration = NetworkConfiguration()
  public var networkDetailsSampledAt: Double?
  public var networkTraffic = ProcessTrafficSnapshot()
  public var gpuTime = GPUProcessTimeSnapshot()
  public var wifi = WiFiSnapshot()
  public var internetChecks = InternetChecksSnapshot()
  public var weather = WeatherSnapshot()
  public init() {}
  /// The startup filesystem is identified by its mount path, never enumeration order.
  public var startupVolume: VolumeReading? {
    volumes.first { $0.path == "/" && $0.total > 0 }
  }
  public var cpuTemperature: Double? {
    sensors.filter {
      $0.kind == .temperature
        && $0.name.hasPrefix("CPU")
    }.map(\.value).max()
  }
  public func sensor(for key: String) -> SensorReading? {
    if key == "cpu" {
      return cpuTemperature.map {
        SensorReading(
          key: "cpu", name: SensorCatalog.hottestCPULabel, kind: .temperature, value: $0)
      }
    }
    return sensors.first { $0.key == key }
  }
  public var diskRead: Double? {
    let values = disks.compactMap(\.read)
    return values.isEmpty ? nil : values.reduce(0, +)
  }
  public var diskWrite: Double? {
    let values = disks.compactMap(\.written)
    return values.isEmpty ? nil : values.reduce(0, +)
  }
  public var historyPoint: HistoryPoint {
    .init(
      time: timestamp, cpu: cpu?.usage, gpu: gpus.compactMap(\.usage).max(),
      memory: memory?.percent, download: download, upload: upload,
      sensorValue: selectedSensor?.value, sensorKey: selectedSensor?.key, diskRead: diskRead,
      diskWrite: diskWrite,
      diskUsed: startupVolume?.percent,
      temperature: cpuTemperature,
      battery: batteries.first?.percent, sensorKind: selectedSensor?.kind,
      cpuUser: cpu?.user, cpuSystem: cpu?.system, cpuCores: cpu.flatMap(CPUCoreHistorySample.init))
  }
}
public enum Display {
  public static func processPercent(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
  }
  public static func percent(_ value: Double?) -> String {
    value.map { String(format: "%.0f%%", $0) } ?? "—"
  }
  public static func bytes(_ value: UInt64) -> String { bytes(value, precise: false) }
  public static func bytes(_ value: UInt64, precise: Bool) -> String {
    scaled(Double(value), units: ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"], precise: precise)
  }
  public static func rate(_ value: Double?) -> String {
    value.map { scaled($0, units: ["B/s", "KiB/s", "MiB/s", "GiB/s"]) } ?? "—"
  }
  private static func scaled(_ value: Double, units: [String], precise: Bool = false) -> String {
    var value = max(0, value)
    var index = 0
    while value >= 1024 && index < units.count - 1 {
      value /= 1024
      index += 1
    }
    return String(
      format: (precise || value < 10) && index > 0 ? "%.1f %@" : "%.0f %@", value, units[index])
  }
  public static func duration(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds)) / 60
    return minutes >= 1440
      ? "\(minutes/1440)d \(minutes%1440/60)h" : "\(minutes/60)h \(minutes%60)m"
  }
}

public enum BatteryCurrent {
  /// AppleSmartBattery may box a negative current as an unsigned 32- or 64-bit number.
  public static func milliamps(raw: UInt64) -> Double? {
    let signed =
      raw > UInt64(UInt32.max) ? Int64(bitPattern: raw) : Int64(Int32(bitPattern: UInt32(raw)))
    guard (-300_000...300_000).contains(signed) else { return nil }
    return Double(signed)
  }
}
