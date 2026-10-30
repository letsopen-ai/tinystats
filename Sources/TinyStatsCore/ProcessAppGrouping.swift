import Foundation
import TinyStatsTraffic

public struct ProcessAppReading: Sendable, Equatable {
  public var name: String, bundlePath: String?
  public var pid: Int32?, processCount: Int
  public var cpu: Double?, memory: UInt64?
  public var cpuIncomplete: Int
  public init(
    name: String, bundlePath: String? = nil, pid: Int32? = nil, processCount: Int,
    cpu: Double?, memory: UInt64?, cpuIncomplete: Int = 0
  ) {
    self.name = name
    self.bundlePath = bundlePath
    self.pid = pid
    self.processCount = processCount
    self.cpu = cpu
    self.memory = memory
    self.cpuIncomplete = cpuIncomplete
  }
  public var label: String {
    if let pid { return "\(name) · \(pid)" }
    return "\(name) · \(processCount) \(processCount == 1 ? "process" : "processes")"
  }
}

/// Worker-local, bounded lexical cache. No stat/Bundle/NSWorkspace work in collection.
/// Admission cache, not LRU: first 256 paths win until pruning frees slots.
/// Keep only paths observed in the latest scan, including cached non-bundle results.
struct ProcessBundleCache {
  private struct Entry { var bundle: ExecutableBundle.Bundle? }
  private var entries: [String: Entry] = [:]
  private var used = Set<String>()
  static let capacity = 256
  var count: Int { entries.count }
  mutating func beginScan() { used.removeAll(keepingCapacity: true) }
  mutating func resolve(_ path: String) -> ExecutableBundle.Bundle? {
    guard path.utf8.count < 4096 else { return nil }
    used.insert(path)
    if let entry = entries[path] { return entry.bundle }
    let bundle = ExecutableBundle.bundle(for: path)
    if entries.count < Self.capacity { entries[path] = Entry(bundle: bundle) }
    return bundle
  }
  mutating func endScan() {
    entries = entries.filter { used.contains($0.key) }
    used.removeAll(keepingCapacity: true)
  }
}

/// Aggregate the complete existing scan, never the truncated display union.
/// CPU sums measured members; unmeasured members are counted separately. Overflow stays nil.
public enum ProcessAppGrouping {
  public static func rows(
    _ processes: [ProcessReading], bundles: [ExecutableBundle.Bundle?]
  ) -> (cpu: [ProcessAppReading], memory: [ProcessAppReading]) {
    guard processes.count == bundles.count, processes.count <= 8192 else { return ([], []) }
    enum Key: Hashable {
      case bundle(String)
      case process(Int32)
    }
    var groups: [Key: ProcessAppReading] = [:]
    var cpuOverflow = Set<Key>()
    for (process, bundle) in zip(processes, bundles) {
      let key = bundle.map { Key.bundle($0.path) } ?? .process(process.pid)
      var row =
        groups[key]
        ?? ProcessAppReading(
          name: bundle?.name ?? process.name, bundlePath: bundle?.path,
          pid: bundle == nil ? process.pid : nil, processCount: 0, cpu: nil, memory: 0)
      row.processCount += 1
      if let cpu = process.cpu, cpu.isFinite, cpu >= 0 {
        if !cpuOverflow.contains(key) {
          let sum = (row.cpu ?? 0) + cpu
          row.cpu = sum.isFinite ? sum : nil
          if !sum.isFinite { cpuOverflow.insert(key) }
        }
      } else {
        row.cpuIncomplete += 1
      }
      if let previous = row.memory {
        let sum = previous.addingReportingOverflow(process.memory)
        row.memory = sum.overflow ? nil : sum.partialValue
      }
      groups[key] = row
    }
    func tied(_ a: ProcessAppReading, _ b: ProcessAppReading) -> Bool {
      if a.name != b.name { return a.name < b.name }
      if a.bundlePath != b.bundlePath { return (a.bundlePath ?? "") < (b.bundlePath ?? "") }
      return (a.pid ?? 0) < (b.pid ?? 0)
    }
    let values = Array(groups.values)
    let cpu = values.sorted {
      if $0.cpu != $1.cpu { return ($0.cpu ?? -1) > ($1.cpu ?? -1) }
      return tied($0, $1)
    }
    let memory = values.sorted {
      if $0.memory != $1.memory {
        if let a = $0.memory, let b = $1.memory { return a > b }
        return $0.memory != nil
      }
      return tied($0, $1)
    }
    return (Array(cpu.prefix(8)), Array(memory.prefix(8)))
  }
}
