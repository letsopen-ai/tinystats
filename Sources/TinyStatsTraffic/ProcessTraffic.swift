import Foundation

public enum TrafficAvailability: String, Sendable {
  case inactive, starting, warming, ready, incomplete, unavailable
}
public struct ProcessTrafficReading: Sendable {
  public var pid: Int32, uniqueID: UInt64
  public var name: String
  public var download: Double, upload: Double
  public init(pid: Int32, uniqueID: UInt64, name: String, download: Double, upload: Double) {
    self.pid = pid
    self.uniqueID = uniqueID
    self.name = name
    self.download = download
    self.upload = upload
  }
}
public enum TrafficGrouping: String, Codable, CaseIterable, Sendable {
  case processes, bundles
}
public struct TrafficBundleReading: Sendable {
  public var name: String
  /// Only owners with bytes in this interval are counted. nil pid means a bundle group.
  public var processCount: Int
  public var pid: Int32?
  public var bundlePath: String?
  public var download: Double, upload: Double
  public init(
    name: String, processCount: Int, pid: Int32?, download: Double, upload: Double,
    bundlePath: String? = nil
  ) {
    self.bundlePath = bundlePath
    self.name = name
    self.processCount = processCount
    self.pid = pid
    self.download = download
    self.upload = upload
  }
  public var label: String {
    if let pid { return pid > 0 ? "\(name) · \(pid)" : name }
    return "\(name) · \(processCount) \(processCount == 1 ? "process" : "processes")"
  }
}
public struct ProcessTrafficSnapshot: Sendable {
  public var revision = ""
  public var grouping: TrafficGrouping = .processes
  public var bundles: [TrafficBundleReading] = []
  public var availability: TrafficAvailability = .inactive
  public var message = "Open Network details to collect process traffic."
  public var processes: [ProcessTrafficReading] = []
  public var sampledAt: Double?
  public var intervalSeconds: Double?
  public var activeSources = 0
  public init() {}
}

enum TrafficAccountingError: Error { case capacity, invalidSource }

/// Queue-independent accounting for socket inventory, final counters and completed query
/// windows. Incomplete delivery invalidates the entire interval, including rate baselines.
struct TrafficLedger {
  private struct State {
    var provider: UInt32
    var flow: TrafficFlow?
    var closed = false
  }
  private struct Delta {
    var name: String
    var received: UInt64 = 0, sent: UInt64 = 0
  }
  private var sources: [UInt64: State] = [:]
  private var pending: [TrafficOwner: Delta] = [:]
  private var expected = Set<UInt64>(), seen = Set<UInt64>()
  private var previousTime: Double?, cutoff: UInt64 = 0
  private var damaged = false, querying = false
  private let sourceLimit: Int, ownerLimit: Int
  private let outputPID: Int32?
  private let outputUserID: UInt32?
  init(
    sourceLimit: Int = 8192, ownerLimit: Int = 1024, outputPID: Int32? = nil,
    outputUserID: UInt32? = nil
  ) {
    self.sourceLimit = sourceLimit
    self.ownerLimit = ownerLimit
    self.outputPID = outputPID
    self.outputUserID = outputUserID
  }
  mutating func add(source: UInt64, provider: UInt32) throws {
    guard source > 0, source != UInt64.max, sources[source] == nil else {
      damaged = true
      throw TrafficAccountingError.invalidSource
    }
    guard sources.count < sourceLimit else {
      damaged = true
      throw TrafficAccountingError.capacity
    }
    sources[source] = .init(provider: provider)
    if querying { expected.insert(source) }
  }
  mutating func begin() {
    expected = Set(sources.keys)
    seen.removeAll(keepingCapacity: true)
    querying = true
  }
  mutating func sealInventory() { querying = false }
  mutating func update(_ flow: TrafficFlow, closing: Bool) throws {
    guard var state = sources[flow.source], state.provider == flow.provider else {
      damaged = true
      throw TrafficAccountingError.invalidSource
    }
    if let old = state.flow, flow.observed < old.observed { return }
    if expected.contains(flow.source) { seen.insert(flow.source) }
    var received: UInt64 = 0
    var sent: UInt64 = 0
    if let old = state.flow {
      if old.owner != flow.owner || old.started != flow.started
        || flow.received < old.received || flow.sent < old.sent
      {
        damaged = true
      } else {
        received = flow.received - old.received
        sent = flow.sent - old.sent
      }
    } else if previousTime != nil, flow.started > 0, flow.started >= cutoff {
      // A genuinely new socket can close entirely between polls. Its birth timestamp
      // prevents its final cumulative counters from becoming a historical rate spike.
      received = flow.received
      sent = flow.sent
    }
    if !state.closed || received > 0 || sent > 0 {
      if pending[flow.owner] == nil {
        guard pending.count < ownerLimit else {
          damaged = true
          throw TrafficAccountingError.capacity
        }
        pending[flow.owner] = .init(name: flow.name)
      }
      var delta = pending[flow.owner]!
      let rx = delta.received.addingReportingOverflow(received)
      let tx = delta.sent.addingReportingOverflow(sent)
      if rx.overflow || tx.overflow {
        damaged = true
      } else {
        delta.received = rx.partialValue
        delta.sent = tx.partialValue
      }
      delta.name = flow.name
      pending[flow.owner] = delta
    }
    state.flow = flow
    state.closed = state.closed || closing
    sources[flow.source] = state
  }
  mutating func remove(source: UInt64, flags: UInt16) {
    // A clean final update must precede removal. Gone/drop/filter removals cannot
    // prove that the bytes in the vanished socket were delivered to this client.
    if sources[source]?.closed != true || flags & (8 | 16 | 64) != 0 { damaged = true }
    sources.removeValue(forKey: source)
    expected.remove(source)
    seen.remove(source)
  }
  mutating func finish(
    at time: Double, continuous: UInt64, completedAt: Double, maximumProcesses: Int = 8
  )
    -> ProcessTrafficSnapshot
  {
    var result = ProcessTrafficSnapshot()
    result.activeSources = sources.count
    result.sampledAt = completedAt
    let complete = !damaged && expected.isSubset(of: seen)
    if !complete || !time.isFinite || previousTime.map({ time <= $0 }) == true {
      result.availability = .incomplete
      let missing = expected.subtracting(seen).count
      result.message =
        missing > 0
        ? "Missing \(missing) socket updates. Rebuilding rate baselines."
        : "Socket counters closed incompletely or changed identity. Rebuilding rate baselines."
      previousTime = nil
      for key in sources.keys { sources[key]?.flow = nil }
    } else if let previousTime {
      let elapsed = time - previousTime
      result.availability = .ready
      result.intervalSeconds = elapsed
      result.message = "Ready · socket byte counters"
      result.processes = pending.compactMap { owner, delta -> ProcessTrafficReading? in
        guard outputUserID == nil || owner.userID == outputUserID else { return nil }
        return .init(
          pid: owner.pid, uniqueID: owner.uniqueID, name: delta.name,
          download: Double(delta.received) / elapsed, upload: Double(delta.sent) / elapsed)
      }.filter { outputPID == nil || $0.pid == outputPID }.sorted {
        let a = $0.download + $0.upload
        let b = $1.download + $1.upload
        if a != b { return a > b }
        if $0.name != $1.name { return $0.name < $1.name }
        if $0.pid != $1.pid { return $0.pid < $1.pid }
        return $0.uniqueID < $1.uniqueID
      }.prefix(max(1, min(ownerLimit, maximumProcesses))).map { $0 }
      self.previousTime = time
    } else {
      result.availability = .warming
      result.message = "Collecting a second complete query for rates."
      previousTime = time
    }
    cutoff = continuous
    pending.removeAll(keepingCapacity: true)
    expected.removeAll(keepingCapacity: true)
    seen.removeAll(keepingCapacity: true)
    damaged = false
    querying = false
    return result
  }
}
