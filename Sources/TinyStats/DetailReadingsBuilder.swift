import AppKit
import TinyStatsCore

struct DetailRow: Equatable {
  struct Meter: Equatable {
    var value: Double?
    var color: NSColor
  }
  var label: String, value: String
  var heading = false
  var meter: Meter?
  var sensorIdentity: SensorBrowserIdentity?
  var processGroupingHeader = false
  var bundlePath: String?
  var processCount: Int = 1
  var appName: String?
  var accessibilityLabel: String?
  var compactValue: String?
  var help: String?
  var sampleSection = false
}

/// Formats existing local observations; never collects, persists, or requests permission.
@MainActor
enum DetailReadingsBuilder {
  struct Presentation {
    var value = ""
    var subtitle = ""
    var rows: [DetailRow] = []
    var series: [ChartView.Series] = []
    var upperBound: Double? = 100
  }

  struct Headline {
    var value = "", subtitle = ""
  }
  /// Summary dropdowns need only the headline; never build the hidden diagnostic table.
  static func headline(module: Module, snapshot s: Snapshot) -> Headline? {
    var result = Headline()
    switch module {
    case .overview:
      result.value = "Your Mac, at a glance."
      result.subtitle =
        "\(s.thermalState) thermal state · up \(Display.duration(s.uptime))"
    case .cpu:
      result.value = Display.percent(s.cpu?.usage)
      result.subtitle = "Of total capacity"
    case .gpu:
      result.value = Display.percent(s.gpus.compactMap(\.usage).max())
      result.subtitle = s.gpus.map(\.name).joined(separator: " · ")
    case .memory:
      result.value = s.memory.map { Display.bytes($0.used) } ?? "—"
      result.subtitle =
        s.memory.map {
          "of \(Display.bytes($0.total)) · pressure \($0.pressureDescription.lowercased())"
        } ?? "Memory telemetry unavailable"
    case .disks:
      result.value =
        s.startupVolume.map { Display.bytes($0.available) + " free" }
        ?? "Startup volume unavailable"
      result.subtitle = "Startup volume · Refreshes every 30s"
    case .network:
      result.value = "↓ " + Display.rate(s.download)
      result.subtitle =
        "↑ \(Display.rate(s.upload)) · \(s.selectedInterface.isEmpty ? "No primary route" : s.selectedInterface)"
    case .battery:
      result.value = s.batteries.first.map { Display.percent($0.percent) } ?? "Plugged in"
      result.subtitle =
        s.batteries.first.map {
          BatteryMenuState.state(for: $0).title
        } ?? "This Mac has no internal battery"
    case .sensors, .weather, .clock: return nil
    }
    return result
  }

  /// Existing observations only; available as table rows and footer action help.
  static func sampleRows(snapshot: Snapshot, settings: Settings, paused: Bool) -> [DetailRow] {
    let privacy =
      settings.connectivityChecks || settings.publicIPChecks || settings.weather.enabled
      ? "Internet requests enabled"
      : settings.pingCheck.enabled ? "Network checks enabled" : "Local only"
    let cost = snapshot.sampleMilliseconds
    var rows: [DetailRow] = [
      .init(label: "ABOUT THIS SAMPLE", value: "", heading: true, sampleSection: true),
      .init(
        label: "Privacy", value: privacy,
        compactValue: privacy == "Internet requests enabled"
          ? "Internet enabled"
          : privacy == "Network checks enabled" ? "Network checks" : nil),
      .init(
        label: "Monitoring", value: paused ? "Paused · readings are frozen" : "Running",
        compactValue: paused ? "Paused" : nil),
      .init(label: "Configured cadence", value: "\(Int(settings.interval))s"),
      .init(
        label: "Last sample cost",
        value: cost.isFinite && cost >= 0
          ? String(format: "%.1f ms", cost) : "Unavailable"),
    ]
    if snapshot.sensors.filter({ !$0.key.hasPrefix("ioreport:") }).count >= 128 {
      rows.append(.init(label: "SMC scan limit", value: "128 · some sensors may be missing"))
    }
    return rows
  }

  static func build(
    module: Module, snapshot s: Snapshot, history: [HistoryPoint], settings: Settings, paused: Bool
  ) -> Presentation? {
    guard let headline = headline(module: module, snapshot: s) else { return nil }
    var result = Presentation(value: headline.value, subtitle: headline.subtitle)
    func row(_ label: String, _ value: String) {
      result.rows.append(.init(label: label, value: value))
    }
    func section(_ title: String) {
      result.rows.append(.init(label: title, value: "", heading: true))
    }
    func utilization(_ label: String, _ reading: Double?, _ color: NSColor, text: String? = nil) {
      let reading = UtilizationMeterCell.normalized(reading)
      result.rows.append(
        .init(
          label: label, value: reading == nil ? "—" : text ?? Display.percent(reading),
          meter: .init(value: reading, color: color))
      )
    }
    func memoryAmount(_ label: String, _ bytes: UInt64, _ total: UInt64, _ color: NSColor) {
      utilization(
        label, total > 0 ? Double(bytes) / Double(total) * 100 : nil, color,
        text: Display.bytes(bytes))
    }
    func componentSensors(_ component: SensorComponent) {
      let sensors = s.sensors.filter { $0.component == component }.sorted { $0.key < $1.key }
      guard !sensors.isEmpty else { return }
      section(component.title.uppercased() + (component == .fans ? "" : " SENSORS"))
      for sensor in sensors {
        let includesKey = sensor.name == sensor.key || sensor.name.hasSuffix("· \(sensor.key)")
        row(
          includesKey ? sensor.name : "\(sensor.name) · \(sensor.key)",
          sensor.formatted(fahrenheit: settings.fahrenheit))
      }
    }
    func series(
      _ name: String, _ key: KeyPath<HistoryPoint, Double?>, _ color: NSColor,
      role: ChartSeriesRole = .primary
    ) {
      result.series.append(
        .init(name: name, color: color, values: history.map { $0[keyPath: key] }, role: role))
    }
    func processes(_ type: Module) {
      let apps = type != .disks && settings.processGrouping == .bundles
      section(
        apps
          ? "TOP APPS"
          : type == .cpu
            ? "TOP CPU"
            : type == .memory ? "TOP MEMORY" : "TOP DISK I/O")
      result.rows[result.rows.count - 1].processGroupingHeader = type != .disks
      if type == .cpu && !apps {
        result.rows[result.rows.count - 1].accessibilityLabel = "TOP CPU · BARS = MAC CAPACITY"
        result.rows[result.rows.count - 1].help = "Bars show Mac capacity"
      } else if type == .disks {
        result.rows[result.rows.count - 1].accessibilityLabel = "TOP DISK I/O · READ + WRITE"
        result.rows[result.rows.count - 1].help = "Disk read and write"
      }
      if type == .memory && !apps {
        result.rows[result.rows.count - 1].accessibilityLabel = "Top memory · physical footprint"
        result.rows[result.rows.count - 1].help = "Physical footprint"
      }
      if apps {
        let groups = type == .cpu ? s.cpuApps : s.memoryApps
        if groups.isEmpty { row("Waiting for next process scan", "—") }
        for app in groups.prefix(7) {
          if type == .cpu {
            let count = s.cpu?.cores.count ?? 0
            if count > 0 {
              utilization(
                app.label, app.cpu.map { min(100, $0 / Double(count)) },
                SystemStyle.moduleAccent(module),
                text: app.cpuDisplayValue + " of one core")
            } else {
              row(app.label, app.cpuDisplayValue + " of one core")
            }
          } else {
            row(app.label, app.memory.map(Display.bytes) ?? "—")
          }
          result.rows[result.rows.count - 1].bundlePath = app.bundlePath
          result.rows[result.rows.count - 1].appName = app.name
          result.rows[result.rows.count - 1].processCount = app.processCount
          if type == .cpu, app.cpuIncomplete > 0 {
            result.rows[result.rows.count - 1].help =
              app.cpuMeasurementHelp
          }
          result.rows[result.rows.count - 1].accessibilityLabel =
            app.label + (app.bundlePath.map { " · " + $0 } ?? "")
        }
        if type == .memory {
          row("Shared pages", "May be counted twice")
          result.rows[result.rows.count - 1].accessibilityLabel =
            "Sum of per-process physical footprints · shared pages may be counted twice"
        }
        return
      }
      let list = s.processes.sorted { a, b in
        switch type {
        case .cpu: return (a.cpu ?? 0) > (b.cpu ?? 0)
        case .memory: return a.memory > b.memory
        default: return (a.diskActivity ?? 0) > (b.diskActivity ?? 0)
        }
      }
      if list.isEmpty { row("Waiting for accessible processes", "—") }
      for item in list.prefix(7) {
        let label = "\(item.name) · \(item.pid)"
        if type == .cpu {
          let count = s.cpu?.cores.count ?? 0
          if count > 0 {
            utilization(
              label, item.cpu.map { min(100, $0 / Double(count)) },
              SystemStyle.moduleAccent(module),
              text: Display.processPercent(item.cpu) + " of one core")
          } else {
            row(label, Display.processPercent(item.cpu) + " of one core")
          }
        } else if type == .memory, let memory = s.memory {
          memoryAmount(label, item.memory, memory.total, SystemStyle.moduleAccent(module))
        } else {
          row(
            label,
            type == .memory
              ? Display.bytes(item.memory)
              : Display.rate(
                (item.read == nil && item.written == nil)
                  ? nil : (item.read ?? 0) + (item.written ?? 0)))
        }
      }
    }
    switch module {
    case .overview:
      series("CPU", \.cpu, SystemStyle.moduleAccent(.cpu))
      series("Memory", \.memory, SystemStyle.moduleAccent(.memory), role: .secondary)
      utilization("CPU", s.cpu?.usage, SystemStyle.moduleAccent(.cpu))
      utilization("GPU", s.gpus.compactMap(\.usage).max(), SystemStyle.moduleAccent(.gpu))
      utilization(
        "Memory", s.memory?.percent, SystemStyle.moduleAccent(.memory),
        text: s.memory.map { "\(Display.bytes($0.used)) / \(Display.bytes($0.total))" })
      row(
        "Network · \(s.selectedInterface.isEmpty ? "disconnected" : s.selectedInterface)",
        "↓ \(Display.rate(s.download))  ↑ \(Display.rate(s.upload))")
      row("Disk activity", "R \(Display.rate(s.diskRead))  W \(Display.rate(s.diskWrite))")
      row(
        "CPU temperature",
        s.cpuTemperature.map { temperature($0, settings: settings) } ?? "Unavailable")
      if let battery = s.batteries.first {
        utilization("Battery", battery.percent, SystemStyle.moduleAccent(.battery))
      } else {
        row("Battery", "No internal battery")
      }
      row("Energy mode", s.lowPower ? "Low Power Mode" : "Standard")
    case .cpu:
      series("CPU", \.cpu, SystemStyle.moduleAccent(module))
      row(
        "Load · 1 / 5 / 15 minutes",
        s.cpu?.load.map { String(format: "%.2f", $0) }.joined(separator: " / ") ?? "—")
      row("Uptime", Display.duration(s.uptime))
      for frequency in s.frequencies where frequency.name != "GPU" {
        row("\(frequency.name) · active frequency", frequency.formatted)
      }
      if let cpu = s.cpu {
        for kind in CPUCoreKind.allCases {
          let indices = cpu.cores.indices.filter { cpu.kind(at: $0) == kind }
          if indices.isEmpty { continue }
          section("\(kind.title.uppercased()) CORES")
          for index in indices {
            let color = kind.chartColor
            utilization("Logical core \(index + 1)", cpu.cores[index], color)
          }
        }
      }
      componentSensors(.cpu)
      section("CPU COOLING")
      result.rows[result.rows.count - 1].help = "Shared / unassigned fans included"
      result.rows[result.rows.count - 1].accessibilityLabel =
        "CPU cooling · shared / unassigned fans included"
      for fan in s.sensors where fan.kind == .fan && (fan.fanOwner == .cpu || fan.fanOwner == nil) {
        row(fan.name, fan.formatted(fahrenheit: false))
      }
      processes(.cpu)
    case .gpu:
      series("GPU", \.gpu, SystemStyle.moduleAccent(module))
      if s.gpus.isEmpty { row("Driver does not expose GPU telemetry", "Unavailable") }
      for gpu in s.gpus {
        section(gpu.name)
        utilization("Driver utilization", gpu.usage, SystemStyle.moduleAccent(module))
        row("Shader core count", gpu.coreCount.map(String.init) ?? "Unavailable")
        row("Per-core utilization", "No verified per-core counter")
        utilization("Renderer utilization", gpu.rendererUsage, SystemStyle.moduleAccent(module))
        utilization("Tiler utilization", gpu.tilerUsage, SystemStyle.moduleSecondary(module))
        row("Allocated GPU memory", gpu.memory.map(Display.bytes) ?? "Unavailable")
      }
      row("Counter source", "IOAccelerator driver")
      if let frequency = s.frequencies.first(where: { $0.name == "GPU" }) {
        row("Apple GPU · active frequency", frequency.formatted)
      }
      componentSensors(.gpu)
      section("REPORTED METAL GPU TIME · MS / SECOND")
      for process in s.gpuTime.rows {
        row(
          "\(process.name) · \(process.pid)",
          GPUProcessTimeSnapshot.formatted(process.millisecondsPerSecond))
      }
      row(s.gpuTime.message, "")
      row("Accessible creating processes · helpers separate", "Not GPU/core utilization")
      section("GPU COOLING")
      result.rows[result.rows.count - 1].help = "Shared / unassigned fans included"
      result.rows[result.rows.count - 1].accessibilityLabel =
        "GPU cooling · shared / unassigned fans included"
      for fan in s.sensors where fan.kind == .fan && (fan.fanOwner == .gpu || fan.fanOwner == nil) {
        row(fan.name, fan.formatted(fahrenheit: false))
      }
      if s.frequencies.contains(where: { $0.name == "GPU" }) {
        row("Frequency / power source", "IOReport · model estimate")
      }
    case .memory:
      series("Working set %", \.memory, SystemStyle.moduleAccent(module))
      if let m = s.memory {
        memoryAmount("Active", m.active, m.total, SystemStyle.moduleAccent(module))
        memoryAmount("Wired", m.wired, m.total, SystemStyle.moduleSecondary(module))
        memoryAmount("Compressed", m.compressed, m.total, SystemStyle.neutralSeries)
        memoryAmount(
          "Inactive · reclaimable", m.inactive, m.total, SystemStyle.moduleSecondary(module))
        memoryAmount("Purgeable · reclaimable", m.purgeable, m.total, .systemGray)
        memoryAmount(
          "Free (includes speculative)", m.free, m.total, SystemStyle.moduleAccent(module))
        row("Swap used / allocated", "\(Display.bytes(m.swapUsed)) / \(Display.bytes(m.swapTotal))")
      }
      componentSensors(.memory)
      processes(.memory)
    case .disks:
      series("Read B/s", \.diskRead, SystemStyle.moduleAccent(module))
      series("Write B/s", \.diskWrite, SystemStyle.moduleSecondary(module), role: .secondary)
      result.upperBound = nil
      for volume in s.volumes {
        section(volume.name)
        utilization(
          "\(volume.path) · used", volume.total > 0 ? volume.percent : nil,
          SystemStyle.moduleAccent(module))
        row(
          "Available / total", "\(Display.bytes(volume.available)) / \(Display.bytes(volume.total))"
        )
      }
      if s.disks.isEmpty { row("Physical I/O counters", "Unavailable") }
      for disk in s.disks {
        row(disk.name, "R \(Display.rate(disk.read))  W \(Display.rate(disk.written))")
      }
      section("DRIVE HEALTH · READ-ONLY")
      if s.storageHealth.checkedAt == nil {
        row(
          s.storageHealth.refreshing ? "Reading SMART health…" : "Open disk details to read SMART",
          "—")
      }
      if let checkedAt = s.storageHealth.checkedAt {
        row(
          "Last checked",
          DateFormatter.localizedString(from: checkedAt, dateStyle: .none, timeStyle: .short))
        if s.storageHealth.drives.isEmpty {
          row("No physical storage health devices found", "Unavailable")
        }
      }
      for drive in s.storageHealth.drives {
        section(drive.name + (drive.bsdName.isEmpty ? "" : " · " + drive.bsdName))
        row("SMART status", drive.status)
        if drive.available && drive.transport == .nvme {
          row(
            "Drive temperature",
            drive.temperature.map { temperature($0, settings: settings) } ?? "Unavailable")
          row("Rated endurance used · estimate", "\(drive.enduranceUsed)%")
          row(
            "Available spare / threshold",
            drive.spare.map { "\($0)% / \(drive.spareThreshold ?? 0)%" } ?? "Unavailable")
          row("Lifetime read", drive.counter(drive.totalRead, bit: 0, bytes: true))
          row("Lifetime written", drive.counter(drive.totalWritten, bit: 1, bytes: true))
          row("Power cycles", drive.counter(drive.powerCycles, bit: 2))
          row("Power-on hours", drive.counter(drive.powerOnHours, bit: 3))
          row("Unsafe shutdowns", drive.counter(drive.unsafeShutdowns, bit: 4))
          row("Media errors", drive.counter(drive.mediaErrors, bit: 5))
          row("Error log entries", drive.counter(drive.errorEntries, bit: 6))
        }
      }
      componentSensors(.storage)
      processes(.disks)
    case .network:
      series("Download B/s", \.download, SystemStyle.moduleAccent(module))
      series("Upload B/s", \.upload, SystemStyle.moduleSecondary(module), role: .secondary)
      result.upperBound = nil
      row("Counting", "One selected interface")
      if let checked = s.networkDetailsSampledAt {
        row("Details checked", "\(Int(max(0, s.uptime - checked)))s ago")
      }
      let configuration = s.networkConfiguration
      row(
        "IPv4 primary route",
        configuration.ipv4?.interface ?? (configuration.available ? "None" : "Unavailable"))
      row(
        "IPv6 primary route",
        configuration.ipv6?.interface ?? (configuration.available ? "None" : "Unavailable"))
      if let router = configuration.ipv4?.router { row("IPv4 primary router", router) }
      if let router = configuration.ipv6?.router { row("IPv6 primary router", router) }
      if !configuration.dns.isEmpty {
        row("Global DNS configuration", configuration.dns.joined(separator: ", "))
      }
      section("OPTIONAL INTERNET CHECKS")
      let checks = s.internetChecks
      row("HTTPS destination", settings.httpsCheck.url?.absoluteString ?? "Invalid configuration")
      if settings.connectivityChecks {
        if let result = checks.connectivity {
          row(settings.httpsCheck.title, result.state.title)
          row("Check result", result.reason)
          if let milliseconds = result.milliseconds {
            row("HTTPS response time", String(format: "%.0f ms", milliseconds))
          }
          row("HTTPS check age", "\(Int(max(0, s.uptime - result.checkedAt)))s ago")
        } else {
          row(settings.httpsCheck.title, paused ? "Paused" : "Waiting for check")
        }
      } else {
        row(settings.httpsCheck.title, "Off · enable in Settings")
      }
      row(
        "Ping destination",
        settings.pingCheck.canonicalDestination
          ?? (settings.pingCheck.destination.isEmpty ? "Not configured" : "Invalid configuration"))
      if let error = settings.pingCheck.validationError {
        row("ICMP ping", "Off · " + error)
      } else if settings.pingCheck.enabled {
        if let result = checks.ping {
          row("ICMP ping", result.reason)
          if let milliseconds = result.milliseconds {
            row("ICMP round-trip time", String(format: "%.1f ms", milliseconds))
          }
          row("Ping check age", "\(Int(max(0, s.uptime - result.checkedAt)))s ago")
        } else {
          row("ICMP ping", paused ? "Paused" : "Waiting for echo")
        }
        row("Ping route", "System / VPN · bypasses HTTP proxies")
      } else {
        row("ICMP ping", "Off · enable in Settings")
      }
      if settings.publicIPChecks {
        for (label, result) in [("Public IPv4", checks.ipv4), ("Public IPv6", checks.ipv6)] {
          row(
            label, result?.address ?? (result?.reason ?? (paused ? "Paused" : "Waiting for check")))
          if let result { row("\(label) age", "\(Int(max(0, s.uptime - result.checkedAt)))s ago") }
        }
        row("Public-IP source", "ipify · OS-selected route")
      } else {
        row("Public IP", "Off · enable in Settings")
      }
      section(
        settings.processGrouping == .bundles
          ? "APP TRAFFIC · PARTIAL" : "PROCESS TRAFFIC · PARTIAL")
      result.rows[result.rows.count - 1].processGroupingHeader = true
      let traffic = s.networkTraffic
      if traffic.availability == .ready && settings.processGrouping == .bundles {
        if traffic.bundles.isEmpty { row("Active kernel TCP/UDP traffic", "None") }
        for bundle in traffic.bundles {
          row(
            bundle.label, "↓ \(Display.rate(bundle.download))  ↑ \(Display.rate(bundle.upload))")
          result.rows[result.rows.count - 1].bundlePath = bundle.bundlePath
          result.rows[result.rows.count - 1].appName = bundle.name
          result.rows[result.rows.count - 1].processCount = bundle.processCount
          result.rows[result.rows.count - 1].accessibilityLabel =
            bundle.label + (bundle.bundlePath.map { " · " + $0 } ?? "")
        }
      }
      row("Scope", "All interfaces + loopback")
      row("Coverage", "Kernel TCP/UDP only")
      row("Modern / QUIC", "Not fully covered")
      row("Accounting", traffic.message)
      if settings.processGrouping == .bundles {
        row("Grouping", "Current outermost executable bundle path")
        row("Active members", "Owners with bytes in this interval")
        row("Shared services / WebKit", "Separate processes · not attributed to apps")
        row("Unresolved paths / exited owners", "Separate process rows · no guessed app")
        row("Paths / nested apps", "Distinct paths separate · outer bundle wins")
      }
      if let checked = traffic.sampledAt {
        row(
          "Process counters checked",
          "\(Int(max(0, s.uptime - checked)))s ago · \(traffic.activeSources) sockets")
      }
      if traffic.availability == .ready && settings.processGrouping == .processes {
        if traffic.processes.isEmpty { row("Accessible kernel sockets", "None") }
        for process in traffic.processes {
          row(
            process.pid == 0 ? process.name : "\(process.name) · \(process.pid)",
            "↓ \(Display.rate(process.download))  ↑ \(Display.rate(process.upload))")
        }
      }
      section("WI-FI RADIO")
      switch s.wifi.state {
      case .inactive, .loading: row("Wi-Fi details", paused ? "Paused" : "Waiting for reading")
      case .unavailable: row("Wi-Fi details", "Unavailable")
      case .ready:
        if s.wifi.interfaces.isEmpty { row("Wi-Fi details", "None in sampled interfaces") }
      }
      if let checked = s.wifi.sampledAt {
        row("Radio checked", "\(Int(max(0, s.uptime - checked)))s ago")
      }
      if s.wifi.truncated { row("Radio limit", "Showing first 8 Wi-Fi interfaces") }
      for radio in s.wifi.interfaces {
        row("Wi-Fi interface", radio.interface)
        row("Wi-Fi state", radio.state.rawValue)
        if radio.state == .station || radio.state == .ibss || radio.state == .accessPoint {
          row("Wi-Fi signal", radio.rssi.map { "\($0) dBm" } ?? "Unavailable")
          row("Wi-Fi noise", radio.noise.map { "\($0) dBm" } ?? "Unavailable")
          row("Signal / noise", radio.signalToNoise.map { "\($0) dB" } ?? "Unavailable")
          row(
            "Transmit link rate",
            radio.transmitMbps.map { String(format: "%.1f Mbps", $0) } ?? "Unavailable")
          row("Wi-Fi PHY", radio.phy ?? "Unavailable")
          row("Wi-Fi channel", radio.channel.map(String.init) ?? "Unavailable")
          row("Wi-Fi band", radio.band ?? "Unavailable")
          row("Channel width", radio.widthMHz.map { "\($0) MHz" } ?? "Unavailable")
          row("Wi-Fi security", radio.security ?? "Unavailable")
        }
      }
      for interface in s.interfaces.sorted(by: {
        if ($0.name == s.selectedInterface) != ($1.name == s.selectedInterface) {
          return $0.name == s.selectedInterface
        }
        return $0.name < $1.name
      }) {
        let info = configuration.interfaces[interface.name]
        section(interface.name + (info?.name.map { " · \($0)" } ?? ""))
        row(
          "Interface flags",
          interface.up ? (interface.running ? "Up · running" : "Up · not running") : "Down")
        if let hardware = info?.hardware {
          row("Connection type", hardware == "AirPort" ? "Wi-Fi" : hardware)
        }
        if interface.mtu > 0 { row("MTU", "\(interface.mtu) bytes") }
        if interface.addresses.isEmpty {
          row("Local addresses", interface.addressesAvailable ? "None assigned" : "Unavailable")
        }
        for address in interface.addresses {
          row(address.label, address.formatted)
          if let destination = address.destination { row("Point-to-point peer", destination) }
        }
        if interface.addressesTruncated { row("Address limit", "Showing first 8 addresses") }
        if let info {
          if !info.routers.isEmpty {
            row("Configured routers", info.routers.joined(separator: ", "))
          }
          if !info.dns.isEmpty {
            row("Service DNS configuration", info.dns.joined(separator: ", "))
          }
        }
        row(
          "Throughput", "↓ \(Display.rate(interface.download))  ↑ \(Display.rate(interface.upload))"
        )
        row(
          "Since interface creation",
          "↓ \(Display.bytes(interface.received))  ↑ \(Display.bytes(interface.sent))")
      }
    case .battery:
      series("Battery %", \.battery, SystemStyle.moduleAccent(module))
      for battery in s.batteries {
        section(battery.name)
        row(
          "Time estimate",
          battery.minutesRemaining.map { "\($0/60)h \($0%60)m" } ?? "Calculating / unavailable")
        utilization("Charge", battery.percent, SystemStyle.moduleAccent(module))
        utilization("Battery health", battery.health, SystemStyle.moduleSecondary(module))
        row("Cycle count", battery.cycles.map(String.init) ?? "—")
        row("Battery power · signed", battery.watts.map { String(format: "%.1f W", $0) } ?? "—")
      }
      section("ACCESSORY BATTERIES")
      if s.peripherals.isEmpty { row("No HID battery readings available", "—") }
      for device in s.peripherals {
        utilization(device.name, device.percent, SystemStyle.moduleAccent(module))
      }
      componentSensors(.battery)
      section("POWER / VOLTAGE / CURRENT · SCOPES MAY OVERLAP")
      row("Energy mode", s.lowPower ? "Low Power Mode" : "Standard")
      for sensor in s.sensors where [.power, .voltage, .current].contains(sensor.kind) {
        row(sensor.name, sensor.formatted(fahrenheit: settings.fahrenheit))
      }
    case .sensors, .weather, .clock:
      return nil
    }
    return result
  }
  static func temperature(_ celsius: Double, settings: Settings) -> String {
    String(
      format: "%.1f°%@", settings.fahrenheit ? celsius * 1.8 + 32 : celsius,
      settings.fahrenheit ? "F" : "C")
  }
}
