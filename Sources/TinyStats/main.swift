import AppKit
import OSLog
import TinyStatsCore

if CommandLine.arguments.dropFirst().first == "--install-update" {
  do {
    guard CommandLine.arguments.count == 5, let pid = Int32(CommandLine.arguments[3]), pid > 1,
      ["0", "1"].contains(CommandLine.arguments[4])
    else {
      throw UpdateError.invalid("Invalid update helper arguments.")
    }
    try NativeUpdateInstaller.runHelper(
      planURL: URL(fileURLWithPath: CommandLine.arguments[2]),
      parentPID: pid, relaunch: CommandLine.arguments[4] == "1")
    exit(0)
  } catch {
    Logger(subsystem: UpdatePolicy.bundleID, category: "UpdateHelper")
      .updateFailure("Update helper exited", error: error)
    FileHandle.standardError.write(Data("TinyStats update installation failed.\n".utf8))
    exit(1)
  }
}

if CommandLine.arguments.contains("--diagnose") {
  let sampler = Sampler()
  let wifi = CommandLine.arguments.contains("--wifi")
  let module: Module = wifi ? .network : .disks
  _ = sampler.sample(includeProcesses: true, detailModule: module)
  Thread.sleep(forTimeInterval: (CommandLine.arguments.contains("--hardware") || wifi) ? 5.1 : 1)
  let sample = sampler.sample(includeProcesses: true, detailModule: module)
  print("TinyStats diagnostics (local only)")
  print("CPU: \(Display.percent(sample.cpu?.usage)) · \(sample.cpu?.cores.count ?? 0) cores")
  if let cpu = sample.cpu {
    for (index, usage) in cpu.cores.enumerated() {
      print("  Logical core \(index + 1) · \(cpu.kind(at: index).title): \(Display.percent(usage))")
    }
  }
  print(
    "Memory: \(sample.memory.map { Display.bytes($0.used) + " / " + Display.bytes($0.total) + " · " + $0.pressureDescription } ?? "Unavailable")"
  )
  for gpu in sample.gpus {
    print(
      "GPU: \(gpu.name) · \(Display.percent(gpu.usage)) · \(gpu.coreCount.map(String.init) ?? "unknown") shader cores"
    )
    print(
      "  Renderer: \(Display.percent(gpu.rendererUsage)) · Tiler: \(Display.percent(gpu.tilerUsage)) · individual-core counters unavailable"
    )
  }
  for frequency in sample.frequencies {
    print("Active frequency: \(frequency.name) · \(frequency.formatted)")
  }
  print(
    "Network: \(sample.selectedInterface) ↓\(Display.rate(sample.download)) ↑\(Display.rate(sample.upload))"
  )
  print(
    "Network configuration: IPv4 \(sample.networkConfiguration.ipv4?.interface ?? "none") · IPv6 \(sample.networkConfiguration.ipv6?.interface ?? "none") · \(sample.interfaces.reduce(0) { $0 + $1.addresses.count }) local addresses"
  )
  if wifi {
    print(
      "Wi-Fi: \(sample.wifi.state) · \(sample.wifi.interfaces.count) interfaces (no network identifiers collected)"
    )
    for radio in sample.wifi.interfaces {
      print(
        "  \(radio.interface): \(radio.state.rawValue) · RSSI \(radio.rssi.map(String.init) ?? "unavailable") dBm · noise \(radio.noise.map(String.init) ?? "unavailable") dBm"
      )
      print(
        "    Channel \(radio.channel.map(String.init) ?? "unavailable") · \(radio.band ?? "unavailable") · \(radio.widthMHz.map(String.init) ?? "unavailable") MHz · \(radio.phy ?? "unavailable")"
      )
      print(
        "    Transmit link \(radio.transmitMbps.map { String(format: "%.1f", $0) } ?? "unavailable") Mbps · \(radio.security ?? "unavailable")"
      )
    }
  }
  print("Volumes: \(sample.volumes.count) · physical disks: \(sample.disks.count)")
  for drive in sample.storageHealth.drives {
    print(
      "SMART: \(drive.name) \(drive.bsdName) · \(drive.status) · \(drive.temperature.map { String(format: "%.1f°C", $0) } ?? "temperature unavailable")"
    )
  }
  print("Processes: \(sample.processes.count) retained top entries")
  print(
    "Sensors: \(sample.sensors.count) · batteries: \(sample.batteries.count) · peripherals: \(sample.peripherals.count)"
  )
  for sensor in sample.sensors {
    print(
      "  [\(sensor.component.title)] \(sensor.key) \(sensor.name): \(String(format: "%.2f", sensor.value)) \(sensor.unit)"
    )
  }
  print("Sampler: \(String(format: "%.2f", sample.sampleMilliseconds))ms")
  exit(sample.cpu == nil || sample.memory == nil ? 1 : 0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
