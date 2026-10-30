import CTinyStats
import Foundation
import TinyStatsTraffic

/// Own on a single serial queue. Hardware handles and all rate baselines stay on that queue.
public final class Sampler {
  private let hardware = Hardware()
  private let device = DeviceIdentity.read()
  private let silicon = SiliconTelemetry()
  private let healthReader = StorageHealthReader()
  private var wifiReader: WiFiReader?
  private let networkTraffic: KernelTrafficSession
  private let networkConfiguration: NetworkConfigurationReader
  private var internetChecks: InternetChecksReader?
  private var weatherReader: WeatherReader?
  private var ticks: [CPUTicks] = []
  private var coreKinds: [CPUCoreKind] = []
  private var topologyReadAt = -Double.infinity
  private var networkRates: [String: (RateCounter, RateCounter)] = [:]
  private var diskRates: [UInt64: (RateCounter, RateCounter)] = [:]
  private struct ProcessState {
    var started: UInt64
    var cpu = RateCounter(), read = RateCounter(), written = RateCounter()
  }
  private var processRates: [Int32: ProcessState] = [:]
  private var gpuProcessTime = GPUProcessTimeCollector()
  private var lastSlow = -Double.infinity, lastSensors = -Double.infinity
  private var cached = Snapshot()
  public init(queue: DispatchQueue? = nil) {
    networkConfiguration = NetworkConfigurationReader(queue: queue)
    networkTraffic = KernelTrafficSession(queue: queue)
  }
  deinit { wifiReader?.stop() }
  public func reset() {
    ticks = []
    coreKinds = []
    topologyReadAt = -Double.infinity
    networkRates = [:]
    diskRates = [:]
    processRates = [:]
    gpuProcessTime.reset()
    cached.gpuTime = .init()
    lastSlow = -Double.infinity
    lastSensors = -Double.infinity
    hardware.reset()
    silicon.reset()
    networkConfiguration.reset()
    stopNetworkDetails()
    internetChecks?.reset()
    cached.internetChecks = .init()
    weatherReader?.suspend()
    cached.weather = .init()
  }
  public func configureInternetChecks(_ settings: Settings) {
    if internetChecks == nil
      && (settings.connectivityChecks || settings.publicIPChecks || settings.pingCheck.enabled)
    {
      internetChecks = InternetChecksReader()
    }
    internetChecks?.configure(
      connectivity: settings.connectivityChecks, publicIP: settings.publicIPChecks,
      revision: settings.internetRevision, httpsCheck: settings.httpsCheck,
      pingCheck: settings.pingCheck)
    if !settings.connectivityChecks && !settings.publicIPChecks && !settings.pingCheck.enabled {
      cached.internetChecks = .init()
    }
  }
  public func configureWeather(_ settings: WeatherSettings) {
    if weatherReader == nil && settings.enabled && settings.location != nil {
      weatherReader = WeatherReader()
    }
    weatherReader?.configure(settings)
    if !settings.enabled { cached.weather = .init() }
  }
  public func stopNetworkTraffic() {
    networkTraffic.stop()
    cached.networkTraffic = .init()
  }
  public func stopNetworkDetails() {
    stopNetworkTraffic()
    wifiReader?.stop()
    cached.wifi = .init()
  }
  public func clearProcessBaselines() {
    processRates = [:]
    gpuProcessTime.reset()
    cached.gpuTime = .init()
    cached.processes = []
    cached.processTimestamp = nil
  }
  public func sample(
    settings: Settings = Settings(), includeProcesses: Bool = false, detailModule: Module? = nil
  ) -> Snapshot {
    let started = ProcessInfo.processInfo.systemUptime
    var snapshot = cached
    snapshot.device = device
    snapshot.timestamp = Date()
    snapshot.uptime = started
    snapshot.cpu = readCPU(at: started)
    snapshot.memory = readMemory()
    snapshot.gpus = hardware.gpu(at: started)
    snapshot.interfaces = readNetwork(at: started)
    snapshot.networkConfiguration = networkConfiguration.read(
      at: started, interfaces: &snapshot.interfaces)
    snapshot.networkDetailsSampledAt = networkConfiguration.sampledAt
    configureInternetChecks(settings)
    configureWeather(settings.weather)
    snapshot.weather =
      settings.weather.enabled ? weatherReader?.read(at: started) ?? .init() : .init()
    if settings.connectivityChecks || settings.publicIPChecks || settings.pingCheck.enabled {
      // Keep intermediate types explicit for the supported Swift 6.1 toolchain.
      var path: [String] = []
      for interface in snapshot.interfaces.sorted(by: { $0.name < $1.name }) {
        path.append("\(interface.name):\(interface.index):\(interface.up):\(interface.running)")
        let addresses: [String] = interface.addresses.map { $0.formatted }.sorted()
        path.append(contentsOf: addresses)
      }
      if let route = snapshot.networkConfiguration.ipv4 {
        path.append("v4:\(route.interface):\(route.router ?? "")")
      } else {
        path.append("")
      }
      if let route = snapshot.networkConfiguration.ipv6 {
        path.append("v6:\(route.interface):\(route.router ?? "")")
      } else {
        path.append("")
      }
      path.append(contentsOf: snapshot.networkConfiguration.dns)
      snapshot.internetChecks = internetChecks?.read(path: path) ?? .init()
    } else {
      snapshot.internetChecks = .init()
    }
    if detailModule == .network {
      snapshot.networkTraffic = networkTraffic.read(
        at: started, grouping: settings.networkTrafficGrouping)
      snapshot.networkTraffic.revision = settings.networkTrafficRevision
      let radio = wifiReader ?? WiFiReader()
      wifiReader = radio
      snapshot.wifi = radio.read(at: started, interfaces: snapshot.interfaces)
    } else {
      stopNetworkDetails()
      snapshot.networkTraffic = .init()
      snapshot.wifi = .init()
    }
    if started - lastSlow >= 30 {
      snapshot.volumes = readVolumes()
      snapshot.volumesSampledAt = started
      snapshot.peripherals = hardware.peripherals()
      lastSlow = started
    }
    if started - lastSensors >= 5 {
      let telemetry = silicon.read(at: started)
      snapshot.frequencies = telemetry.frequencies
      snapshot.sensors = hardware.sensors() + telemetry.power
      snapshot.sensorsSampledAt = started
      snapshot.batteries = hardware.batteries()
      snapshot.batteriesSampledAt = started
      lastSensors = started
    }
    snapshot.disks = readDisks(at: started)
    if settings.monitorStorageHealth || detailModule == .disks {
      healthReader.requestIfDue(at: started)
    }
    snapshot.storageHealth = healthReader.cached()
    snapshot.selectedSensor = snapshot.sensor(for: settings.sensorKey)
    // Auto follows the default route; no interface means unavailable, not an invented connection.
    snapshot.selectedInterface =
      settings.networkInterface == "auto"
      ? snapshot.networkConfiguration.preferredInterface(in: snapshot.interfaces) ?? ""
      : settings.networkInterface
    let selected = snapshot.interfaces.first { $0.name == snapshot.selectedInterface && $0.up }
    snapshot.download = selected?.download
    snapshot.upload = selected?.upload
    if includeProcesses {
      snapshot.processes = readProcesses(at: started)
      snapshot.processTimestamp = snapshot.timestamp
    } else {
      processRates = [:]
      snapshot.processes = []
      snapshot.processTimestamp = nil
    }
    snapshot.gpuTime = gpuProcessTime.sample(
      visible: detailModule == .gpu, at: ProcessInfo.processInfo.systemUptime,
      maximumInterval: max(15, settings.interval * 3), read: { hardware.gpuProcessTimes() },
      identity: { pid in
        var raw = ts_process()
        guard ts_read_process_identity(pid, &raw) else { return nil }
        return .init(started: raw.started, name: cString(raw.name))
      })
    snapshot.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    snapshot.thermalState =
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: "Nominal"
      case .fair: "Fair"
      case .serious: "Serious"
      case .critical: "Critical"
      @unknown default: "Unknown"
      }
    snapshot.sampleMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
    cached = snapshot
    return snapshot
  }
  private func readCPU(at time: Double) -> CPUReading? {
    var raw = ts_cpu()
    guard ts_read_cpu(&raw) else {
      ticks = []
      return nil
    }
    let current = withUnsafeBytes(of: raw.cores) { buffer in
      buffer.bindMemory(to: ts_ticks.self).prefix(Int(raw.count)).map {
        CPUTicks(user: $0.user, system: $0.system, idle: $0.idle, nice: $0.nice)
      }
    }
    var user = 0.0
    var system = 0.0
    var measured = 0.0
    let usage: [Double?] = current.enumerated().map { index, item in
      guard ticks.count == current.count, let parts = item.components(since: ticks[index]) else {
        return nil
      }
      user += parts.user
      system += parts.system
      measured += 1
      return min(100, parts.user + parts.system)
    }
    ticks = current
    if coreKinds.count != current.count || time - topologyReadAt >= 60 {
      coreKinds = CPUCoreTopology.read(count: current.count)
      topologyReadAt = time
    }
    return CPUReading(
      usage: measured > 0 ? min(100, (user + system) / measured) : nil, cores: usage,
      load: [raw.load.0, raw.load.1, raw.load.2], coreKinds: coreKinds,
      user: measured > 0 ? user / measured : nil, system: measured > 0 ? system / measured : nil)
  }
  private func readMemory() -> MemoryReading? {
    var raw = ts_memory()
    guard ts_read_memory(&raw) else { return nil }
    return .init(
      total: raw.total, active: raw.active, inactive: raw.inactive, wired: raw.wired,
      compressed: raw.compressed, free: raw.free, speculative: raw.speculative,
      purgeable: raw.purgeable, swapUsed: raw.swap_used, swapTotal: raw.swap_total,
      pressure: Int(raw.pressure))
  }
  private func readNetwork(at time: Double) -> [InterfaceReading] {
    var raw = [ts_interface](repeating: ts_interface(), count: 128)
    let count = ts_read_interfaces(&raw, raw.count)
    var alive = Set<String>()
    let result = raw.prefix(count).map { row in
      let name = cString(row.name)
      let key = "\(name):\(row.index)"
      alive.insert(key)
      var rates = networkRates[key] ?? (RateCounter(), RateCounter())
      if !row.up { rates = (RateCounter(), RateCounter()) }
      let download = row.up ? rates.0.sample(row.received, at: time) : nil
      let upload = row.up ? rates.1.sample(row.sent, at: time) : nil
      networkRates[key] = rates
      return InterfaceReading(
        name: name, address: "", up: row.up, received: row.received,
        sent: row.sent, download: download, upload: upload, index: row.index, mtu: row.mtu,
        running: row.running)
    }
    networkRates = networkRates.filter { alive.contains($0.key) }
    return result
  }
  private func readDisks(at time: Double) -> [DiskReading] {
    var raw = [ts_disk_io](repeating: ts_disk_io(), count: 64)
    let count = ts_read_disks(&raw, raw.count)
    var alive = Set<UInt64>()
    let result = raw.prefix(count).map { row in
      alive.insert(row.id)
      var rates = diskRates[row.id] ?? (RateCounter(), RateCounter())
      let read = rates.0.sample(row.read, at: time)
      let written = rates.1.sample(row.written, at: time)
      diskRates[row.id] = rates
      return DiskReading(id: row.id, name: cString(row.name), read: read, written: written)
    }
    diskRates = diskRates.filter { alive.contains($0.key) }
    return result
  }
  private func readVolumes() -> [VolumeReading] {
    var raw = [ts_volume](repeating: ts_volume(), count: 64)
    let count = ts_read_volumes(&raw, raw.count)
    return raw.prefix(count).map {
      .init(
        name: cString($0.name), path: cString($0.path), total: $0.total, available: $0.available,
        mountID: $0.mount_id)
    }
  }
  private func readProcesses(at time: Double) -> [ProcessReading] {
    let raw = ProcessSampleBuffer.read(estimatedCount: Int(ts_process_count_hint())) { output in
      ts_read_processes(&output, output.count)
    }
    var alive = Set<Int32>()
    let result = raw.map { row in
      alive.insert(row.pid)
      var rates =
        processRates[row.pid].flatMap { $0.started == row.started ? $0 : nil }
        ?? ProcessState(started: row.started)
      let cpu = rates.cpu.sample(row.cpu_ns, at: time).map { $0 / 1e9 * 100 }
      let read = rates.read.sample(row.read, at: time)
      let written = rates.written.sample(row.written, at: time)
      processRates[row.pid] = rates
      let name = cString(row.name)
      return ProcessReading(
        pid: row.pid, name: name.isEmpty ? "PID \(row.pid)" : name, cpu: cpu, memory: row.footprint,
        read: read, written: written)
    }
    processRates = processRates.filter { alive.contains($0.key) }
    // Retain baselines for all visible processes; carry only top lists to the UI.
    let cpu = result.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(8)
    let memory = result.sorted { $0.memory > $1.memory }.prefix(8)
    let io = result.sorted {
      ($0.diskActivity ?? 0) > ($1.diskActivity ?? 0)
    }.prefix(8)
    var seen = Set<Int32>()
    return (Array(cpu) + Array(memory) + Array(io)).filter { seen.insert($0.pid).inserted }
  }
}

public struct ResourceUsage: Sendable {
  public let rss: UInt64, footprint: UInt64, cpuNanoseconds: UInt64
  public static func current() -> Self? {
    var raw = ts_self_usage()
    guard ts_read_self(&raw) else { return nil }
    return .init(rss: raw.rss, footprint: raw.footprint, cpuNanoseconds: raw.cpu_ns)
  }
}
