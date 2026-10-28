import CTinyStats
import Foundation
import IOKit
import IOKit.ps

func cString<T>(_ tuple: T) -> String {
  withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
}
func property(_ entry: io_registry_entry_t, _ name: String) -> Any? {
  IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue()
}
func services(_ name: String) -> [io_service_t] {
  var iterator: io_iterator_t = 0
  guard
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
      == KERN_SUCCESS
  else { return [] }
  defer { IOObjectRelease(iterator) }
  var result: [io_service_t] = []
  while case let entry = IOIteratorNext(iterator), entry != 0 { result.append(entry) }
  return result
}

final class Hardware {
  #if arch(arm64)
    private static let appleSilicon = true
  #else
    private static let appleSilicon = false
  #endif
  private struct Accelerator {
    var entry: io_service_t, id: UInt64, name: String, cores: Int?
  }
  private var accelerators: [Accelerator] = []
  private var smc: OpaquePointer?
  private var sensorKeys: [(key: String, kind: SensorReading.Kind)] = []
  private var gpuDiscovery = -Double.infinity
  init() {
    smc = ts_smc_open()
    discoverSensors()
  }
  deinit {
    for accelerator in accelerators { IOObjectRelease(accelerator.entry) }
    ts_smc_close(smc)
  }
  func reset() { gpuDiscovery = -Double.infinity }
  func gpu(at time: Double) -> [GPUReading] {
    if time - gpuDiscovery > 60 {
      for accelerator in accelerators { IOObjectRelease(accelerator.entry) }
      accelerators = services("IOAccelerator").map { entry in
        let model = property(entry, "model")
        let name: String
        if let string = model as? String {
          name = string
        } else if let data = model as? Data {
          name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        } else {
          name = "GPU"
        }
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &registryID)
        return Accelerator(
          entry: entry, id: registryID, name: name,
          cores: Self.gpuCoreCount(property(entry, "gpu-core-count")))
      }
      gpuDiscovery = time
    }
    return accelerators.map { accelerator in
      let stats = property(accelerator.entry, "PerformanceStatistics") as? [String: Any] ?? [:]
      let usage =
        (stats["Device Utilization %"] as? NSNumber)?.doubleValue
        ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue
      func percent(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
      }
      let memory =
        (stats["In use system memory"] as? NSNumber)?.uint64Value
        ?? (stats["vramUsedBytes"] as? NSNumber)?.uint64Value
      return GPUReading(
        name: accelerator.name, usage: percent(usage), memory: memory, id: accelerator.id,
        coreCount: accelerator.cores,
        rendererUsage: percent((stats["Renderer Utilization %"] as? NSNumber)?.doubleValue),
        tilerUsage: percent((stats["Tiler Utilization %"] as? NSNumber)?.doubleValue))
    }
  }
  static func gpuCoreCount(_ raw: Any?) -> Int? {
    guard let number = raw as? NSNumber else { return nil }
    let value = number.doubleValue
    guard CFGetTypeID(number) != CFBooleanGetTypeID(), value.isFinite,
      (1...65536).contains(value), value.rounded(.towardZero) == value
    else { return nil }
    return Int(value)
  }
  /// Driver schema verified by an owned Metal workload on M4; other clients stay unavailable.
  /// Use the existing discovery handles, on the sampler queue, only for visible GPU details.
  func gpuProcessTimes() -> GPUClientScan {
    guard accelerators.count <= 16 else { return .tooMany }
    guard !accelerators.isEmpty else { return .unsupported }
    func attempt() -> (GPUClientScan, retry: Bool) {
      var rows: [GPUClientTime] = []
      var ids = Set<UInt64>()
      var scanned = 0
      var recognized = 0
      for accelerator in accelerators {
        var iterator: io_iterator_t = 0
        guard
          IORegistryEntryCreateIterator(
            accelerator.entry, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else {
          return (.incomplete, false)
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
          defer { IOObjectRelease(entry) }
          scanned += 1
          guard scanned <= 4096 else { return (.tooMany, false) }
          guard IOObjectCopyClass(entry).takeRetainedValue() as String == "AGXDeviceUserClient"
          else { continue }
          recognized += 1
          guard recognized <= GPUProcessTimeCollector.maximumClients else {
            return (.tooMany, false)
          }
          var id: UInt64 = 0
          guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS, id != 0,
            ids.insert(id).inserted,
            let pid = GPUClientSchema.pid(property(entry, "IOUserClientCreator"))
          else {
            return (.incomplete, false)
          }
          let usage = property(entry, "AppUsage")
          rows.append(
            .init(
              id: id, pid: pid, nanoseconds: GPUClientSchema.metalNanoseconds(usage),
              reportsMetal: GPUClientSchema.reportsMetal(usage)))
        }
        guard IOIteratorIsValid(iterator) != 0 else {
          IOIteratorReset(iterator)
          return (.incomplete, true)
        }
      }
      return (recognized == 0 ? .unsupported : .ready(rows), false)
    }
    let first = attempt()
    return first.retry ? attempt().0 : first.0
  }
  private func discoverSensors() {
    guard let smc else { return }
    var candidates: [SensorReading] = []
    let count = ts_smc_key_count(smc)
    for index in 0..<count {
      var chars = [CChar](repeating: 0, count: 5)
      guard ts_smc_key_at(smc, index, &chars) else { continue }
      let key = String(decoding: chars.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      let kind: SensorReading.Kind?
      switch key.first {
      case "T": kind = .temperature
      case "P": kind = .power
      case "V": kind = .voltage
      case "I": kind = .current
      case "F" where key.hasSuffix("Ac"): kind = .fan
      default: kind = nil
      }
      guard let kind else { continue }
      var value = 0.0
      if ts_smc_read(smc, key, &value), valid(value, kind: kind) {
        candidates.append(
          SensorReading(
            key: key, name: SensorCatalog.name(for: key, appleSilicon: Self.appleSilicon),
            kind: kind, value: value))
      }

    }
    sensorKeys = SensorCatalog.selectForMonitoring(candidates).map { ($0.key, $0.kind) }
  }
  private func valid(_ value: Double, kind: SensorReading.Kind) -> Bool {
    guard value.isFinite else { return false }
    switch kind {
    case .temperature: return value > 0 && value < 125
    case .fan: return value >= 0 && value < 20000
    case .power: return value >= 0 && value < 1500
    case .voltage: return value > 0 && value < 60
    case .current: return abs(value) < 300
    }
  }
  func sensors() -> [SensorReading] {
    guard let smc else { return [] }
    return sensorKeys.compactMap { item in
      var value = 0.0
      guard ts_smc_read(smc, item.key, &value), valid(value, kind: item.kind) else { return nil }
      let name = SensorCatalog.name(for: item.key, appleSilicon: Self.appleSilicon)
      return SensorReading(key: item.key, name: name, kind: item.kind, value: value)
    }
  }
  func batteries() -> [BatteryReading] {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return [] }
    let smart = services("AppleSmartBattery")
    defer { for battery in smart { IOObjectRelease(battery) } }
    let entry = smart.first
    func number(_ key: String) -> Double? {
      entry.flatMap { property($0, key) as? NSNumber }?.doubleValue
    }
    return sources.compactMap { source -> BatteryReading? in
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? [String: Any],
        let capacity = description[kIOPSCurrentCapacityKey] as? Double,
        let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0,
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else { return nil }
      let charging = description[kIOPSIsChargingKey] as? Bool ?? false
      let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
      let health: Double? = {
        let legacyFull = number("MaxCapacity").flatMap { $0 > 100 ? $0 : nil }
        guard
          let full = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") ?? legacyFull,
          let design = number("DesignCapacity"), design > 0
        else { return nil }
        return min(100, full / design * 100)
      }()
      let watts: Double? = {
        guard let volts = number("Voltage"),
          let raw = entry.flatMap({ property($0, "Amperage") as? NSNumber }),
          let amps = BatteryCurrent.milliamps(raw: raw.uint64Value)
        else { return nil }
        return volts * amps / 1_000_000
      }()
      return BatteryReading(
        name: description[kIOPSNameKey] as? String ?? "Internal battery",
        percent: min(100, max(0, capacity / maximum * 100)), charging: charging,
        externalPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
        minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil },
        cycles: number("CycleCount").map(Int.init), health: health, watts: watts,
        fullyCharged: description[kIOPSIsChargedKey] as? Bool)
    }
  }
  func peripherals() -> [PeripheralBattery] {
    let devices = services("IOHIDDevice")
    defer { for device in devices { IOObjectRelease(device) } }
    var seen = Set<String>()
    return devices.compactMap { entry in
      guard let percent = property(entry, "BatteryPercent") as? NSNumber,
        let name = property(entry, "Product") as? String, seen.insert(name).inserted
      else { return nil }
      return PeripheralBattery(name: name, percent: min(100, max(0, percent.doubleValue)))
    }
  }
}
