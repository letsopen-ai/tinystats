import CoreFoundation
import Foundation

public struct GPUProcessTimeReading: Sendable {
  public var pid: Int32, name: String, millisecondsPerSecond: Double?
  public init(pid: Int32, name: String, millisecondsPerSecond: Double?) {
    self.pid = pid
    self.name = name
    self.millisecondsPerSecond = millisecondsPerSecond
  }
}

public struct GPUProcessTimeSnapshot: Sendable {
  public static let explanation =
    "Driver-reported Metal GPU time is shown for accessible creating processes, summed across reported supported GPU clients. Inaccessible owners are omitted; helpers and WindowServer, when accessible, remain separate. Milliseconds per wall second are not device or core utilization; completion bursts and overlapping work can exceed 1000 ms/s. Bars compare with the leading row."
  public enum Status: Sendable {
    case inactive, collecting, unsupported, noClients, incomplete, tooMany, ready
  }
  public var rows: [GPUProcessTimeReading] = []
  public var status: Status = .inactive
  public init() {}
  public var message: String {
    switch status {
    case .inactive, .collecting: "Collecting first Metal interval…"
    case .unsupported: "No supported Metal time counters"
    case .noClients: "No Metal clients reported"
    case .incomplete: "Partial · changing or unreadable GPU clients"
    case .tooMany: "Too many GPU clients to summarize"
    case .ready:
      rows.allSatisfy { $0.millisecondsPerSecond == 0 }
        ? "No reported Metal GPU time this interval" : "Driver-reported Metal GPU time"
    }
  }
  public static func formatted(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return String(format: value < 10 ? "%.1f ms/s" : "%.0f ms/s", value)
  }
}

struct GPUClientTime: Sendable, Equatable {
  let id: UInt64, pid: Int32
  let nanoseconds: UInt64?
  // A known non-Metal client still proves registry-ID presence and ownership.
  var reportsMetal = true
}
struct GPUProcessIdentity: Sendable {
  let started: UInt64, name: String
}
enum GPUClientScan {
  case ready([GPUClientTime])
  case unsupported, incomplete, tooMany
}

enum GPUClientSchema {
  static func reportsMetal(_ raw: Any?) -> Bool {
    guard let entries = raw as? [[String: Any]], entries.count <= 64,
      entries.allSatisfy({ ($0["API"] as? String).map { $0 != "Metal" } == true })
    else { return true }  // Unknown schemas withhold a rate rather than implying absence.
    return false
  }
  static func pid(_ creator: Any?) -> Int32? {
    guard let creator = creator as? String, creator.utf8.count <= 1024,
      creator.hasPrefix("pid ")
    else { return nil }
    let digits = creator.dropFirst(4).prefix { $0 != "," }
    guard !digits.isEmpty, digits.count <= 10,
      digits.utf8.allSatisfy({ (48...57).contains($0) }),
      let pid = Int32(digits), pid > 0
    else { return nil }
    return pid
  }
  static func metalNanoseconds(_ raw: Any?) -> UInt64? {
    guard let entries = raw as? [Any], entries.count <= 64 else { return nil }
    var found: UInt64?
    for entry in entries {
      guard let entry = entry as? [String: Any], let api = entry["API"] as? String else {
        return nil
      }
      guard api == "Metal" else { continue }
      guard found == nil, let number = entry["accumulatedGPUTime"] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
      else { return nil }
      switch String(cString: number.objCType) {
      case "C", "S", "I", "L", "Q": found = number.uint64Value
      case "c", "s", "i", "l", "q":
        guard number.int64Value >= 0 else { return nil }
        found = number.uint64Value
      default: return nil
      }
    }
    return found
  }
}

/// Client lifetimes and process-start identity must agree before a delta is shown.
/// This is driver Metal time per wall second, never normalized GPU/core utilization.
struct GPUProcessTimeCollector {
  static let maximumClients = 512, maximumProcesses = 64
  private struct Baseline {
    let pid: Int32, started: UInt64, time: Double
    var nanoseconds: UInt64?
    var reportsMetal: Bool
    var quarantined = false
  }
  private var previous: [UInt64: Baseline] = [:]
  var retainedClientCount: Int { previous.count }
  mutating func reset() { previous = [:] }
  private mutating func invalidateRates() {
    for id in previous.keys { previous[id]?.nanoseconds = nil }
  }
  mutating func sample(
    visible: Bool, at time: Double, maximumInterval: Double = 180,
    read: () -> GPUClientScan, identity: (Int32) -> GPUProcessIdentity?
  ) -> GPUProcessTimeSnapshot {
    guard visible else {
      reset()
      return .init()
    }
    var output = GPUProcessTimeSnapshot()
    guard time.isFinite, time >= 0, maximumInterval.isFinite, maximumInterval > 0 else {
      invalidateRates()
      output.status = .incomplete
      return output
    }
    let clients: [GPUClientTime]
    switch read() {
    case .ready(let rows): clients = rows
    case .unsupported:
      invalidateRates()
      output.status = .unsupported
      return output
    case .incomplete:
      invalidateRates()
      output.status = .incomplete
      return output
    case .tooMany:
      invalidateRates()
      output.status = .tooMany
      return output
    }
    guard clients.count <= Self.maximumClients else {
      invalidateRates()
      output.status = .tooMany
      return output
    }
    let owners = Set(clients.map(\.pid))
    guard owners.count <= Self.maximumProcesses else {
      invalidateRates()
      output.status = .tooMany
      return output
    }
    guard clients.allSatisfy({ $0.pid > 0 && $0.id != 0 }),
      Set(clients.map(\.id)).count == clients.count
    else {
      invalidateRates()
      output.status = .incomplete
      return output
    }
    guard !clients.isEmpty else {
      reset()
      output.status = .noClients
      return output
    }
    let groups = Dictionary(grouping: clients, by: \.pid)
    var next: [UInt64: Baseline] = [:]
    var rows: [GPUProcessTimeReading] = []
    var partial = false
    for (pid, group) in groups {
      guard let process = identity(pid), process.started > 0 else {
        partial = true
        // An unreadable owner is not evidence that its client ID changed ownership.
        for client in group {
          if let old = previous[client.id] {
            next[client.id] = old
            next[client.id]?.nanoseconds = nil
          }
        }
        continue
      }
      let oldIDs = Set(
        previous.filter {
          $0.value.pid == pid && $0.value.started == process.started && $0.value.reportsMetal
        }.keys)
      let metalClients = group.filter(\.reportsMetal)
      var valid = oldIDs == Set(metalClients.map(\.id))
      var seconds = 0.0
      for client in group {
        if var old = previous[client.id],
          old.quarantined || old.pid != pid || old.started != process.started
        {
          old.quarantined = true
          old.nanoseconds = nil
          old.reportsMetal = client.reportsMetal
          next[client.id] = old
          if client.reportsMetal { valid = false }
          continue
        }
        next[client.id] = Baseline(
          pid: pid, started: process.started, time: time,
          nanoseconds: client.reportsMetal ? client.nanoseconds : nil,
          reportsMetal: client.reportsMetal)
        guard client.reportsMetal else { continue }
        guard let old = previous[client.id], old.pid == pid, old.started == process.started,
          old.reportsMetal,
          let counter = client.nanoseconds, let before = old.nanoseconds,
          counter >= before, time > old.time, time - old.time <= maximumInterval
        else {
          valid = false
          continue
        }
        seconds += Double(counter - before) / 1e6 / (time - old.time)
      }
      guard !metalClients.isEmpty else { continue }
      let value = valid && seconds.isFinite ? seconds : nil
      if value == nil { partial = true }
      rows.append(
        .init(
          pid: pid, name: process.name.isEmpty ? "PID \(pid)" : process.name,
          millisecondsPerSecond: value))
    }
    let wasEmpty = previous.isEmpty
    previous = next
    rows.sort {
      let a = $0.millisecondsPerSecond ?? -1
      let b = $1.millisecondsPerSecond ?? -1
      return a == b ? $0.pid < $1.pid : a > b
    }
    output.rows = Array(rows.prefix(12))
    output.status =
      partial
      ? (wasEmpty && !rows.isEmpty ? .collecting : .incomplete)
      : (rows.isEmpty ? .noClients : .ready)
    return output
  }
}
