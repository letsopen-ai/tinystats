import CTinyStats
import Foundation
import IOKit

public struct FrequencyReading: Sendable {
  public var name: String
  /// Residency-weighted frequency while active; excludes powered-down and idle time.
  public var megahertz: Double
  public var formatted: String { String(format: "%.2f GHz", megahertz / 1000) }
}

struct ResidencyState: Equatable {
  var name: String
  var ticks: UInt64
}

struct EnergyModelCounter {
  private var unit: String?
  private var counter = RateCounter()
  private var advanced = false
  mutating func sample(_ value: Int64, unit: String, at time: Double) -> Double? {
    guard value >= 0, let scale = SiliconDecoder.joulesPerUnit(unit) else {
      self = EnergyModelCounter()
      return nil
    }
    if self.unit != unit {
      counter.reset()
      advanced = false
    }
    self.unit = unit
    let rate = counter.sample(UInt64(value), at: time)
    guard let rate else {
      advanced = false
      return nil
    }
    guard rate.isFinite, (0...1500).contains(rate * scale) else {
      advanced = false
      return nil
    }
    if rate > 0 { advanced = true }
    // Some dormant channels export a fixed positive placeholder. Observe an
    // actual increment before allowing zero watts, and re-prove it after reset.
    guard advanced else { return nil }
    return rate * scale
  }
}

/// Pure, fail-closed decoders for the hardware-dependent IOReport / pmgr protocol.
enum SiliconDecoder {
  static func frequencies(_ data: Data, gpu: Bool = false) -> [Double]? {
    guard !data.isEmpty, data.count % 8 == 0, data.count <= 64 * 8 else { return nil }
    let bytes = Array(data)
    let words = stride(from: 0, to: bytes.count, by: 8).map { offset in
      (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    let positive = words.filter { $0 > 0 }
    guard !positive.isEmpty, gpu || positive.count == words.count else { return nil }
    if gpu, words.dropFirst().contains(0) { return nil }
    // Older CPU tables use Hz; M4 CPU tables use kHz. Require the entire table
    // to fit one plausible MHz domain instead of guessing a processor generation.
    let divisors: [Double] = gpu ? [1_000_000] : [1_000_000, 1000]
    let valid = divisors.filter { divisor in
      positive.allSatisfy { (100...10_000).contains(Double($0) / divisor) }
    }
    guard valid.count == 1, let divisor = valid.first else { return nil }
    return words.map { Double($0) / divisor }
  }

  static func frequency(
    current: [ResidencyState], previous: [ResidencyState], table: [Double], gpu: Bool
  ) -> Double? {
    guard !table.isEmpty, current.count == previous.count, !current.isEmpty,
      Set(current.map(\.name)).count == current.count
    else { return nil }
    let old = Dictionary(previous.map { ($0.name, $0.ticks) }, uniquingKeysWith: { a, _ in a })
    var weighted = 0.0
    var active = 0.0
    var indices = Set<Int>()
    for item in current {
      guard let before = old[item.name], item.ticks >= before else { return nil }
      if ["IDLE", "DOWN", "OFF"].contains(item.name) { continue }
      let index: Int?
      if gpu, item.name.first == "P" {
        index = Int(item.name.dropFirst()).map { $0 - (table.first == 0 ? 0 : 1) }
      } else if !gpu, item.name.first == "V", let p = item.name.firstIndex(of: "P") {
        index = Int(item.name[item.name.index(after: item.name.startIndex)..<p])
        guard let index, Int(item.name[item.name.index(after: p)...]) == table.count - 1 - index
        else { return nil }
      } else {
        return nil
      }
      guard let index, table.indices.contains(index), table[index] > 0,
        indices.insert(index).inserted
      else { return nil }
      let elapsed = Double(item.ticks - before)
      active += elapsed
      weighted += elapsed * table[index]
    }
    let expected = Set(table.indices.filter { table[$0] > 0 })
    guard indices == expected, active > 0, weighted.isFinite else { return nil }
    return weighted / active
  }

  static func joulesPerUnit(_ unit: String) -> Double? {
    switch unit {
    case "J": 1
    case "mJ": 1e-3
    case "uJ": 1e-6
    case "nJ": 1e-9
    default: nil
    }
  }
}

/// One subscription, read only on the sampler's existing slow-hardware cadence.
/// Missing symbols, unknown tables and counters that have never advanced remain unavailable.
final class SiliconTelemetry {
  private var handle: OpaquePointer?
  private var tables: [String: [Double]] = [:]
  private var states: [String: [ResidencyState]] = [:]
  private var energy: [String: EnergyModelCounter] = [:]
  init() {
    handle = ts_report_open()
    guard handle != nil else { return }
    let entries = servicesNamed("pmgr")
    defer { for entry in entries { IOObjectRelease(entry) } }
    // Multiple power managers need an explicit topology mapping; do not combine heuristically.
    guard entries.count == 1, let entry = entries.first else { return }
    func table(_ key: String, gpu: Bool = false) -> [Double]? {
      (property(entry, key) as? Data).flatMap { SiliconDecoder.frequencies($0, gpu: gpu) }
    }
    tables["ECPU"] = table("voltage-states1-sram")
    if let middle = table("voltage-states22-sram") {
      tables["MCPU"] = middle
      tables["PCPU"] = table("voltage-states5-sram")
    } else {
      tables["PCPU"] = table("voltage-states5-sram")
    }
    tables["GPUPH"] = table("voltage-states9-sram", gpu: true)
  }
  deinit { ts_report_close(handle) }
  func reset() {
    ts_report_close(handle)
    handle = ts_report_open()
    states.removeAll(keepingCapacity: true)
    energy.removeAll(keepingCapacity: true)
  }
  func read(at time: Double) -> (frequencies: [FrequencyReading], power: [SensorReading]) {
    var raw = [ts_report_row](repeating: ts_report_row(), count: Int(TS_REPORT_ROWS))
    let count = ts_report_read(handle, &raw, raw.count)
    var nextStates: [String: [ResidencyState]] = [:]
    var nextEnergy: [String: EnergyModelCounter] = [:]
    var frequencies: [FrequencyReading] = []
    var power: [SensorReading] = []
    let energyNames = [
      "CPU Energy": "CPU", "GPU Energy": "GPU", "ANE Energy": "Neural Engine",
      "ANE0": "Neural Engine",
      "DRAM Energy": "DRAM", "DRAM0": "DRAM", "DRAM": "DRAM", "ANE": "Neural Engine",
    ]
    for row in raw.prefix(count) {
      let name = cString(row.name)
      if row.format == 2 {
        let current = withUnsafeBytes(of: row.states) { bytes in
          bytes.bindMemory(to: ts_report_state.self).prefix(Int(row.count)).map {
            ResidencyState(name: cString($0.name), ticks: $0.residency)
          }
        }
        nextStates[name] = current
        let key = ["ECPU", "PCPU", "MCPU", "GPUPH"].first { prefix in
          name == prefix
            || (name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy(\.isNumber))
        }
        guard let key, let table = tables[key], let previous = states[name],
          let value = SiliconDecoder.frequency(
            current: current, previous: previous, table: table, gpu: key == "GPUPH")
        else { continue }
        let labels = [
          "ECPU": "Efficiency", "PCPU": tables["MCPU"] == nil ? "Performance" : "Super",
          "MCPU": "Performance", "GPUPH": "GPU",
        ]
        let suffix = name.dropFirst(key.count)
        frequencies.append(
          .init(
            name: "\(labels[key] ?? key)\(suffix.isEmpty ? "" : " \(suffix)")", megahertz: value))
      } else if row.format == 1, let label = energyNames[name] {
        let unit = cString(row.unit)
        var counter = energy[name] ?? EnergyModelCounter()
        let watts = counter.sample(row.energy, unit: unit, at: time)
        nextEnergy[name] = counter
        guard let watts else { continue }
        power.append(
          .init(
            key: "ioreport:\(label == "Neural Engine" ? "ane" : label.lowercased())",
            name: "\(label) model power", kind: .power, value: watts
          ))
      }
    }
    states = nextStates
    energy = nextEnergy
    // Alias channels, if both are present, must not appear twice as independent rails.
    var labels = Set<String>()
    power = power.filter { labels.insert($0.name).inserted }
    return (frequencies, power)
  }
}

private func servicesNamed(_ name: String) -> [io_service_t] {
  var iterator: io_iterator_t = 0
  guard
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching(name), &iterator)
      == KERN_SUCCESS
  else { return [] }
  defer { IOObjectRelease(iterator) }
  var entries: [io_service_t] = []
  while entries.count < 8 {
    let entry = IOIteratorNext(iterator)
    if entry == 0 { break }
    entries.append(entry)
  }
  return entries
}
