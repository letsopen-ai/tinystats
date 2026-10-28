import Foundation

public enum SensorComponent: CaseIterable, Sendable {
  case cpu, gpu, fans, memory, storage, battery, neuralEngine, system, other
  public var title: String {
    switch self {
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .fans: "Fans"
    case .memory: "Memory"
    case .storage: "Storage"
    case .battery: "Battery"
    case .neuralEngine: "Neural Engine"
    case .system: "System"
    case .other: "Unclassified"
    }
  }
}

/// Known protocol conventions, not a claim that every key exists on every Mac.
public enum SensorCatalog {
  public static let hottestCPULabel = "CPU · hottest recognized sensor"
  public static let hottestGPULabel = "GPU · hottest recognized sensor"

  // Established SMC conventions: VirtualSMC Docs/SMCSensorKeys.txt (see COMPONENTS.md).
  // These names describe protocol conventions, not verified physical core placement.
  private static let names = [
    "TC0P": "CPU proximity", "TC0D": "CPU diode", "TC0E": "CPU virtual diode",
    "TC0F": "CPU filtered diode", "TC0H": "CPU heatsink", "TCAD": "CPU package",
    "TCGC": "GPU temperature", "TB0T": "Battery temperature", "Tm0P": "Memory proximity",
    "TA0P": "Ambient", "PSTR": "System total power", "PCPC": "CPU package power",
    "F0Ac": "Fan 1", "F1Ac": "Fan 2",
  ]
  // Stats (MIT) M3 group conventions only; deliberately no per-key physical names.
  private static let m3CPU: Set<String> = [
    "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
  ]
  private static let m3GPU: Set<String> = [
    "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
  ]
  public static func component(for sensor: SensorReading) -> SensorComponent {
    if sensor.kind == .fan { return .fans }
    switch sensor.key {
    case "ioreport:cpu", "PCPC", "PCPR", "VC0C", "IC0C": return .cpu
    case "ioreport:gpu", "TCGC", "TCGc", "PGTR", "VG0C", "IG0C": return .gpu
    case "ioreport:ane": return .neuralEngine
    case "ioreport:dram", "Tm0P", "TM0P", "VM0R", "IM0R": return .memory
    case "TH0P", "TH0p", "TH0x", "VH1R", "IH1R": return .storage
    case "TB0T", "TB1T", "TB2T", "TB3T": return .battery
    case "PSTR", "TA0P": return .system
    default: break
    }
    // These names come from platform-aware recognition above. In particular, Intel Tp/Te
    // keys must not inherit Apple Silicon CPU labels, nor may an unknown TC key be guessed.
    if sensor.name.hasPrefix("CPU") { return .cpu }
    if sensor.name.hasPrefix("GPU") { return .gpu }
    return .other
  }
  /// A name backed by a specific catalog entry, never a group-prefix guess.
  public static func friendlyName(for key: String, appleSilicon: Bool) -> String? {
    if let name = names[key] { return name }
    // IOReport model-power channels are explicitly identified by our adapter.
    switch key {
    case "ioreport:cpu": return "CPU model power"
    case "ioreport:gpu": return "GPU model power"
    case "ioreport:ane": return "Neural Engine model power"
    case "ioreport:dram": return "DRAM model power"
    default: return nil
    }
  }
  public static func name(for key: String, appleSilicon: Bool) -> String {
    if let name = names[key] { return name }
    if appleSilicon {
      if key.hasPrefix("Tp") || key.hasPrefix("Te") || m3CPU.contains(key) { return "CPU · \(key)" }
      if key.hasPrefix("Tg") || m3GPU.contains(key) { return "GPU · \(key)" }
    } else if key.hasPrefix("TC"), key.hasSuffix("C"), key.count == 4,
      let digit = key.dropFirst(2).first, digit.isHexDigit
    {
      return "CPU core · \(key)"
    }
    return key
  }
  /// Reserve room for every measured quantity before filling remaining slots.
  /// A long temperature list must not crowd out all power, voltage or current readings.
  public static func selectForMonitoring(_ candidates: [SensorReading]) -> [SensorReading] {
    func group(_ item: SensorReading) -> Int {
      switch item.kind {
      case .temperature: return item.name.hasPrefix("CPU") ? 0 : item.name.hasPrefix("GPU") ? 1 : 2
      case .fan: return 3
      case .power: return 4
      case .voltage: return 5
      case .current: return 6
      }
    }
    let sorted = candidates.sorted { left, right in
      let leftKnown = names[left.key] != nil || m3CPU.contains(left.key) || m3GPU.contains(left.key)
      let rightKnown =
        names[right.key] != nil || m3CPU.contains(right.key) || m3GPU.contains(right.key)
      if leftKnown != rightKnown { return leftKnown }
      return left.key < right.key
    }
    let quotas = [32, 16, 16, 8, 24, 16, 16]
    var selected: [SensorReading] = []
    var seen = Set<String>()
    for index in quotas.indices {
      for item in sorted.filter({ group($0) == index }).prefix(quotas[index]) {
        if seen.insert(item.key).inserted { selected.append(item) }
      }
    }
    for item in sorted where selected.count < 128 && seen.insert(item.key).inserted {
      selected.append(item)
    }
    return selected
  }

}
