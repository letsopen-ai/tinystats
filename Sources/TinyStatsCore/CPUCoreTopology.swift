import Foundation
import IOKit

public enum CPUCoreKind: String, CaseIterable, Sendable {
  case efficiency = "E"
  case performance = "P"
  case unknown = "?"
  public var title: String {
    switch self {
    case .efficiency: "Efficiency"
    case .performance: "Performance"
    case .unknown: "Logical"
    }
  }
}

/// Explicit logical IDs only. Core counts alone cannot establish Mach-array ordering.
struct CPUCoreTopology {
  struct Entry { var id: Int, kind: CPUCoreKind }
  static func entry(id rawID: Any?, cluster rawCluster: Any?) -> Entry? {
    let id: Int
    if let bytes = rawID as? Data {
      guard bytes.count == 4 else { return nil }
      let value = bytes.enumerated().reduce(UInt32(0)) {
        $0 | (UInt32($1.element) << ($1.offset * 8))
      }
      guard value < 256 else { return nil }
      id = Int(value)
    } else {
      guard let number = rawID as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
        (0...255).contains(number.doubleValue),
        number.doubleValue.rounded(.towardZero) == number.doubleValue
      else { return nil }
      id = number.intValue
    }
    guard let bytes = rawCluster as? Data,
      bytes.count == 1 || (bytes.count == 2 && bytes.last == 0)
    else { return .init(id: id, kind: .unknown) }
    return .init(
      id: id,
      kind: CPUCoreKind(rawValue: String(decoding: bytes.prefix(1), as: UTF8.self)) ?? .unknown)
  }
  static func resolve(_ entries: [Entry], count: Int) -> [CPUCoreKind] {
    guard (1...256).contains(count) else { return [] }
    var result = [CPUCoreKind](repeating: .unknown, count: count)
    guard entries.count <= 256 else { return result }
    var seen = Set<Int>()
    for entry in entries where result.indices.contains(entry.id) {
      if seen.insert(entry.id).inserted {
        result[entry.id] = entry.kind
      } else {
        result[entry.id] = .unknown
      }
    }
    return result
  }
  static func read(count: Int) -> [CPUCoreKind] {
    let parent = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
    guard parent != 0 else { return resolve([], count: count) }
    defer { IOObjectRelease(parent) }
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(parent, kIODeviceTreePlane, &iterator) == KERN_SUCCESS
    else { return resolve([], count: count) }
    defer { IOObjectRelease(iterator) }
    var entries: [Entry] = []
    for index in 0...256 {
      let child = IOIteratorNext(iterator)
      if child == 0 { return resolve(entries, count: count) }
      defer { IOObjectRelease(child) }
      // An incomplete inventory cannot rule out conflicting duplicate IDs.
      guard index < 256 else { return resolve([], count: count) }
      if let record = entry(
        id: property(child, "logical-cpu-id"), cluster: property(child, "cluster-type"))
      {
        entries.append(record)
      }
    }
    return resolve([], count: count)
  }
}
