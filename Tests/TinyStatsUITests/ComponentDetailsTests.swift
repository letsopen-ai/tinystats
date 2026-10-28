import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func componentSnapshot() -> Snapshot {
  var snapshot = Snapshot()
  snapshot.cpu = .init(
    usage: 12, cores: [10, nil, 30, 0], load: [0.5, 0.6, 0.7],
    coreKinds: [.efficiency, .efficiency, .performance, .performance])
  snapshot.gpus = [
    .init(
      name: "Example GPU", usage: 20, memory: nil, coreCount: 10, rendererUsage: 15, tilerUsage: nil
    )
  ]
  snapshot.sensors = [
    .init(key: "Tp01", name: "CPU · Tp01", kind: .temperature, value: 52),
    .init(key: "ioreport:cpu", name: "CPU · model power", kind: .power, value: 4),
    .init(key: "Tg0G", name: "GPU · Tg0G", kind: .temperature, value: 45),
    .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1200),
    .init(key: "TH0p", name: "TH0p", kind: .temperature, value: 37),
    .init(key: "IP5l", name: "IP5l", kind: .current, value: -0.5),
  ]
  return snapshot
}

@MainActor private func detailRows(_ controller: DetailController) throws -> [(String, String)] {
  controller.showsAllReadings = true
  let table = try #require(
    controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  return (0..<table.numberOfRows).map { row in
    let label =
      (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue ?? ""
    let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true)
    let value = (cell as? NSTextField)?.stringValue ?? (cell as? UtilizationMeterCell)?.text ?? ""
    return (label, value)
  }
}

@Test @MainActor func weatherAwaitingPermissionDoesNotClaimItIsDisabled() throws {
  let controller = DetailController()
  controller.settings.weather = .currentLocationDefault
  controller.weatherSourceStatus = "Location permission needed"
  controller.selected = .weather
  let rows = try detailRows(controller)
  #expect(rows.contains { $0.0 == "Provider status" && $0.1 == "Location permission needed" })
  let chart = try #require(controller.view.subviews.compactMap { $0 as? ChartView }.first)
  #expect(chart.emptyMessage == "Location permission needed")
  controller.settings.weather.enabled = false
  controller.selected = .weather
  #expect(!(try detailRows(controller)).contains { $0.0 == "Provider status" })
  #expect(chart.emptyMessage == "Weather is off")
}

@Test @MainActor func cpuAndGPUDetailsRetainCoreIdentityAndComponentScope() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.snapshot = componentSnapshot()
  controller.selected = .cpu
  let cpu = try detailRows(controller)
  #expect(cpu.contains { $0.0 == "EFFICIENCY CORES" })
  #expect(cpu.contains { $0.0 == "PERFORMANCE CORES" })
  #expect(cpu.contains { $0.0 == "Logical core 2" && $0.1 == "—" })
  #expect(cpu.contains { $0.0 == "Logical core 4" && $0.1 == "0%" })
  #expect(cpu.contains { $0.0 == "CPU SENSORS" })
  #expect(!cpu.contains { $0.0 == "GPU SENSORS" || $0.0.contains("F0Ac") })
  controller.selected = .gpu
  let gpu = try detailRows(controller)
  #expect(gpu.contains { $0.0 == "Shader core count" && $0.1 == "10" })
  #expect(gpu.contains { $0.0 == "Per-core utilization" && $0.1 == "No verified per-core counter" })
  #expect(gpu.contains { $0.0 == "Tiler utilization" && $0.1 == "—" })
  #expect(gpu.contains { $0.0 == "GPU SENSORS" })
  #expect(!gpu.contains { $0.0 == "CPU SENSORS" })
}

@Test @MainActor func sensorsGroupByComponentWithoutDroppingUnknownOrSignedReadings() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.snapshot = componentSnapshot()
  controller.selected = .sensors
  let rows = try detailRows(controller)
  for heading in [
    "CPU", "GPU", "FANS", "STORAGE", "UNCLASSIFIED",
  ] {
    #expect(rows.filter { $0.0 == heading }.count == 1)
  }
  #expect(rows.contains { $0.0 == "IP5l" && $0.1 == "-0.50 A" })
  #expect(rows.contains { $0.0 == "Fan 1 · F0Ac" && $0.1 == "1200 rpm" })
}

@Test @MainActor func processAndBatteryMetersKeepQuantitiesSeparateFromTheirScales() throws {
  let controller = DetailController()
  var sample = componentSnapshot()
  sample.processes = [
    .init(
      pid: 42, name: "Example process", cpu: 200, memory: 25,
      read: nil, written: nil)
  ]
  sample.memory = .init(
    total: 100, active: 50, inactive: 0, wired: 0, compressed: 0,
    free: 50, speculative: 0, purgeable: 0, swapUsed: 0, swapTotal: 0, pressure: 1)
  sample.batteries = [
    .init(
      name: "Example battery", percent: 0, charging: false,
      externalPower: false, minutesRemaining: nil, cycles: nil, health: nil, watts: nil)
  ]
  controller.snapshot = sample
  controller.selected = .cpu
  let table = try #require(
    controller.view.subviews.compactMap { $0 as? NSScrollView }
      .first?.documentView as? NSTableView)
  func meter(_ name: String) throws -> UtilizationMeterCell {
    let index = try #require((try detailRows(controller)).firstIndex { $0.0 == name })
    return try #require(
      table.view(atColumn: 1, row: index, makeIfNecessary: true)
        as? UtilizationMeterCell)
  }
  let cpu = try meter("Example process · 42")
  #expect(cpu.reading == 50 && cpu.text == "200% of one core")
  controller.selected = .memory
  let memory = try meter("Example process · 42")
  #expect(memory.reading == 25 && memory.text == Display.bytes(25))
  controller.selected = .battery
  #expect(try meter("Charge").reading == 0)
  #expect(try meter("Battery health").reading == nil)
}

@Test @MainActor func wifiDetailsKeepLinkRateSeparateFromTrafficAndWithholdMissingValues() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  var sample = Snapshot()
  sample.uptime = 110
  sample.interfaces = [
    .init(name: "en0", address: "", up: true, received: 0, sent: 0, download: 0, upload: nil)
  ]
  sample.wifi.state = .ready
  sample.wifi.sampledAt = 105
  sample.wifi.interfaces = [
    .decode(
      interface: "en0", powered: true, mode: 1, rssi: -52, noise: -92,
      transmitMbps: 1200, channel: 37, band: 3, width: 3, phy: 6, security: 11)
  ]
  controller.update(sample, history: [])
  controller.selected = .network
  let values = try detailRows(controller)
  #expect(values.contains { $0.0 == "Wi-Fi interface" && $0.1 == "en0" })
  #expect(values.contains { $0.0 == "Wi-Fi signal" && $0.1 == "-52 dBm" })
  #expect(values.contains { $0.0 == "Signal / noise" && $0.1 == "40 dB" })
  #expect(values.contains { $0.0 == "Transmit link rate" && $0.1 == "1200.0 Mbps" })
  #expect(values.contains { $0.0 == "Wi-Fi band" && $0.1 == "6 GHz" })
  #expect(values.contains { $0.0 == "Radio checked" && $0.1 == "5s ago" })
  sample.wifi.interfaces = [.decode(interface: "en0", powered: true, mode: 1)]
  controller.update(sample, history: [])
  let missing = try detailRows(controller)
  #expect(missing.contains { $0.0 == "Wi-Fi signal" && $0.1 == "Unavailable" })
  #expect(missing.contains { $0.0 == "Transmit link rate" && $0.1 == "Unavailable" })
  sample.wifi.interfaces = [.decode(interface: "en0", powered: false, mode: 1, rssi: -52)]
  controller.update(sample, history: [])
  let off = try detailRows(controller)
  #expect(off.contains { $0.0 == "Wi-Fi state" && $0.1 == "Off or unavailable" })
  #expect(!off.contains { $0.0 == "Wi-Fi signal" || $0.0 == "Transmit link rate" })
  sample.wifi = .init()
  controller.update(sample, history: [])
  #expect(!(try detailRows(controller)).contains { $0.0 == "Wi-Fi state" })
}
