import CTinyStatsTraffic
import Darwin
import Foundation

/// Injectable only within the core module/tests; application builds use the POSIX boundary.
struct TrafficSocket {
  var open: () -> Int32
  var query: (Int32, UInt64) -> Bool
  var subscribe: (Int32, UInt32, UInt64) -> Bool
  var receive: (Int32, inout [UInt8]) -> Int32
  var close: @Sendable (Int32) -> Void
  static func native(scope: TrafficCollectionScope) -> Self {
    .init(
      open: { ts_traffic_open() }, query: { ts_traffic_query($0, $1) },
      subscribe: { fd, provider, context in
        switch scope {
        case .kernelSockets: return ts_traffic_subscribe(fd, provider, context)
        case .modernConnections:
          guard provider == 9 else {
            errno = EINVAL
            return false
          }
          return ts_traffic_subscribe_modern(fd, context)
        }
      },
      receive: { fd, bytes in ts_traffic_receive(fd, &bytes, bytes.count) },
      close: { _ = Darwin.close($0) })
  }
}

/// The supplied serial sampler queue owns this object and every callback. The unchecked
/// conformance only bridges DispatchSource's Sendable closure; no state crosses that queue.
final class NetworkTrafficReader: @unchecked Sendable {
  private let queue: DispatchQueue?
  private let processID: Int32
  private let scope: TrafficCollectionScope
  private let userID: UInt32?
  private let socket: TrafficSocket
  private let clock: () -> Double
  private let continuous: () -> UInt64
  private var source: DispatchSourceRead?
  private var descriptor: Int32 = -1
  private var generation: UInt64 = 0
  private var buffer: [UInt8] = []
  private var ledger = TrafficLedger()
  private var expandedOutput = false
  private var acknowledgments = Set<UInt64>()
  private var bootstrapping = true
  private var nextContext: UInt64 = 16
  private struct Query {
    var context: UInt64, continuous: UInt64
    var started: Double
    var fragments = 0, finished = false
  }
  private var query: Query?
  private var openedAt: Double = 0, retryAt = -Double.infinity
  private(set) var latest = ProcessTrafficSnapshot()
  init(
    queue: DispatchQueue? = nil, processID: Int32 = 0,
    scope: TrafficCollectionScope = .kernelSockets, userID: UInt32? = nil,
    socket: TrafficSocket? = nil,
    clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
    continuous: @escaping () -> UInt64 = { mach_continuous_time() }
  ) {
    self.queue = queue
    self.processID = processID
    self.scope = scope
    self.userID = userID
    ledger = TrafficLedger(outputPID: processID > 0 ? processID : nil, outputUserID: userID)
    self.socket = socket ?? .native(scope: scope)
    self.clock = clock
    self.continuous = continuous
  }
  deinit { closeSocket() }
  func stop() {
    guard descriptor >= 0 || latest.availability != .inactive else { return }
    closeSocket()
    retryAt = -Double.infinity
    latest = .init()
  }
  func setExpandedOutput(_ expanded: Bool) {
    guard expandedOutput != expanded else { return }
    stop()
    expandedOutput = expanded
  }
  private func closeSocket() {
    generation &+= 1
    if let source { source.cancel() } else if descriptor >= 0 { socket.close(descriptor) }
    source = nil
    descriptor = -1
    _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    buffer = []
    query = nil
    acknowledgments = []
    ledger = TrafficLedger(outputPID: processID > 0 ? processID : nil, outputUserID: userID)
    bootstrapping = true
  }
  private func fail(_ message: String, at time: Double) {
    closeSocket()
    latest = .init()
    latest.availability = .unavailable
    latest.message = message
    retryAt = time + 60
  }
  func read(at time: Double) -> ProcessTrafficSnapshot {
    if descriptor < 0, time >= retryAt { open(at: time) }
    guard descriptor >= 0 else { return latest }
    drain()
    guard descriptor >= 0 else { return latest }
    if let query, time - query.started > 10 {
      fail("Native traffic query timed out. Retrying in one minute.", at: time)
    } else if acknowledgments.count < scope.providerCount, time - openedAt > 10 {
      fail("Native traffic subscription timed out. Retrying in one minute.", at: time)
    } else if !bootstrapping, acknowledgments.count == scope.providerCount, query == nil,
      (latest.sampledAt ?? -Double.infinity) < time
    {
      beginQuery(at: clock())
    }
    return latest
  }
  private func open(at time: Double) {
    descriptor = socket.open()
    guard descriptor >= 0 else {
      fail("Native process traffic unavailable (\(errno)). Retrying in one minute.", at: time)
      return
    }
    buffer = .init(repeating: 0, count: 65536)
    latest = .init()
    latest.availability = .starting
    latest.message =
      scope == .kernelSockets
      ? "Opening kernel TCP/UDP accounting." : "Opening modern connection accounting."
    openedAt = time
    if let queue {
      let fd = descriptor
      let token = generation
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      source.setEventHandler { [weak self] in
        guard let self, self.generation == token, self.descriptor == fd else { return }
        autoreleasepool { self.drain() }
      }
      let close = socket.close
      source.setCancelHandler { close(fd) }
      self.source = source
      source.resume()
    }
    // An empty update request enables final update messages BEFORE subscribing, so
    // a socket closing during initial discovery still sends owner + final counters.
    if !socket.query(descriptor, 1) {
      fail("Could not initialize native traffic updates.", at: time)
    }
  }
  private func beginQuery(at time: Double) {
    let context = nextContext
    nextContext &+= 1
    ledger.begin()
    query = .init(context: context, continuous: continuous(), started: time)
    if !socket.query(descriptor, context) {
      fail("Could not request native traffic counters.", at: time)
    }
  }
  private func consume(_ message: TrafficMessage, at time: Double) throws {
    switch message {
    case .failure(_, let code):
      fail("Native process traffic unavailable (\(code)). Retrying in one minute.", at: time)
    case .added(let source, let provider):
      try ledger.add(source: source, provider: provider)
    case .removed(let source, let flags): ledger.remove(source: source, flags: flags)
    case .update(let flow, let closing): try ledger.update(flow, closing: closing)
    case .success(let context, let more):
      if bootstrapping, context == 1, !more {
        bootstrapping = false
        if !scope.providers.allSatisfy({ socket.subscribe(descriptor, $0, UInt64($0)) }) {
          fail("Could not subscribe to configured traffic counters.", at: time)
        }
      } else if !bootstrapping, scope.acknowledges(context), !more {
        guard acknowledgments.insert(context).inserted else {
          throw TrafficAccountingError.invalidSource
        }
        if acknowledgments.count == scope.providerCount { beginQuery(at: time) }
      } else if query?.context == context, query?.finished == false {
        if more {
          query?.fragments += 1
          guard let query, query.fragments <= 2048 else { throw TrafficAccountingError.capacity }
          if !socket.query(descriptor, context) {
            fail("Could not continue native traffic query.", at: time)
          }
        } else {
          query?.finished = true
          ledger.sealInventory()
        }
      } else {
        throw TrafficAccountingError.invalidSource
      }
    }
  }
  private func drain() {
    guard descriptor >= 0 else { return }
    let started = clock()
    // Level-triggered dispatch resumes draining if this budget leaves data queued.
    // Queue-less explicit diagnostics pump the same decoder on their next call.
    for _ in 0..<32 {
      guard descriptor >= 0 else { return }
      let count = socket.receive(descriptor, &buffer)
      let now = clock()
      if count < 0 {
        fail("Native traffic stream was interrupted or truncated.", at: now)
        return
      }
      if count == 0 {
        if let query, query.finished {
          latest = ledger.finish(
            at: query.started, continuous: query.continuous, completedAt: now,
            maximumProcesses: expandedOutput ? 1024 : 8)
          if scope == .modernConnections, latest.availability == .ready {
            latest.message = "Ready · modern connection counters (current user)."
          }
          self.query = nil
          if latest.availability == .incomplete {
            // A lost removal can leave a source permanently absent from every later
            // query. Re-subscribe to rebuild inventory instead of retaining that ID.
            let incomplete = latest
            closeSocket()
            latest = incomplete
            latest.message += " Reopening accounting after five seconds."
            retryAt = now + 5
          }
        }
        return
      }
      do {
        // Decode in place and clear the bounded raw scratch buffer immediately. Only
        // owner identities, names and counters survive; endpoint fields never do.
        let decoded = Result {
          try buffer.withUnsafeBytes {
            try TrafficProtocol.decode(
              UnsafeRawBufferPointer(rebasing: $0.prefix(Int(count))), scope: scope)
          }
        }
        _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        let messages = try decoded.get()
        for message in messages {
          guard descriptor >= 0 else { return }
          try consume(message, at: now)
        }
      } catch {
        fail("Native traffic layout, inventory or capacity could not be verified.", at: now)
        return
      }
      if clock() - started >= 0.002 { return }
    }
  }
}
