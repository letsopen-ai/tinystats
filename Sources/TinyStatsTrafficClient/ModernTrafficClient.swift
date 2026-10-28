import Foundation
import TinyStatsTraffic
import TinyStatsTrafficIPC

/// Experimental client, not linked into the preview. Shared sampler ticks drive all requests,
/// timeouts and retries. Default construction performs no signature check or Mach lookup.
public final class ModernTrafficClient: @unchecked Sendable {
  typealias Factory =
    @Sendable (@escaping @Sendable () -> Bool, @escaping @Sendable () -> Void) -> Result<
      any TrafficClientChannel, TrafficClientFailure
    >
  private let queue = DispatchQueue(label: "app.tinystats.traffic-client", qos: .utility)
  private let lock = NSLock()
  private let makeChannel: Factory
  private let clock: @Sendable () -> Double
  // Locked mailbox/publication; read() never waits for signature validation or IPC.
  private var enabled = false, available = false, scheduled = false
  private var epoch: UInt64 = 0, revision: UInt64 = 0
  private var tick: Double = 0, inputTime = -Double.infinity
  private var latest = ProcessTrafficSnapshot()
  // Utility queue only.
  private var workerEpoch: UInt64 = 0
  private var channel: (any TrafficClientChannel)?
  private var channelID = UUID(), openedAt: Double = 0
  private var retryAt = -Double.infinity, nextRequest = -Double.infinity,
    lastTick = -Double.infinity
  private struct Pending {
    var id: UUID, started: Double, gate: TrafficClientCompletionGate
  }
  private var pending: Pending?
  public convenience init() {
    self.init(
      clock: { ProcessInfo.processInfo.systemUptime }, makeChannel: NativeTrafficClientChannel.make)
  }
  init(clock: @escaping @Sendable () -> Double, makeChannel: @escaping Factory) {
    self.clock = clock
    self.makeChannel = makeChannel
    latest.message = "Modern traffic is off."
  }
  deinit {
    pending?.gate.cancel()
    if let closing = channel {
      queue.async {
        closing.stop()
        closing.invalidate()
      }
    }
  }
  public func stop() { _ = read(at: clock(), enabled: false, serviceAvailable: false) }
  public func read(at time: Double, enabled requested: Bool, serviceAvailable: Bool)
    -> ProcessTrafficSnapshot
  {
    let valid = time.isFinite && time >= 0
    let active = requested && valid
    let ready = serviceAvailable && valid
    lock.lock()
    let changed = active != enabled || ready != available || valid && time < inputTime
    if changed {
      enabled = active
      available = ready
      epoch &+= 1
      latest = .init()
      latest.availability = active ? (ready ? .starting : .unavailable) : .inactive
      latest.message =
        active
        ? (ready
          ? "Connecting to modern traffic service."
          : "Traffic service is not installed or approved.") : "Modern traffic is off."
    }
    tick = valid ? time : 0
    inputTime = tick
    revision &+= 1
    if let sampled = latest.sampledAt, time < sampled || time - sampled > 15 {
      latest = .init()
      latest.availability = .unavailable
      latest.message = "Stale modern traffic values withheld."
    }
    if changed || active && ready, !scheduled {
      scheduled = true
      queue.async { [self] in step() }
    }
    let result = latest
    lock.unlock()
    return result
  }
  private func current(_ token: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled && available && epoch == token
  }
  private func publish(_ value: ProcessTrafficSnapshot, token: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    if enabled && available && epoch == token { latest = value }
  }
  private func close() {
    pending?.gate.cancel()
    pending = nil
    channel?.stop()
    channel?.invalidate()
    channel = nil
    channelID = UUID()
  }
  private func fail(_ failure: TrafficClientFailure, token: UInt64, at time: Double) {
    close()
    retryAt = time + 60
    var value = ProcessTrafficSnapshot()
    value.availability = .unavailable
    value.message = failure.message
    publish(value, token: token)
  }
  private func step() {
    lock.lock()
    let token = epoch
    let consumed = revision
    let time = tick
    let allowed = enabled && available
    lock.unlock()
    defer {
      lock.lock()
      if revision != consumed {
        queue.async { [self] in step() }
      } else {
        scheduled = false
      }
      lock.unlock()
    }
    if workerEpoch != token || time < lastTick {
      close()
      retryAt = -Double.infinity
      nextRequest = -Double.infinity
      workerEpoch = token
    }
    lastTick = time
    guard allowed, current(token) else {
      close()
      return
    }
    if let pending, time - pending.started > 5 {
      fail(.timeout, token: token, at: time)
      return
    }
    guard time >= retryAt else { return }
    if channel == nil {
      let identity = UUID()
      channelID = identity
      openedAt = clock()
      let failed = TrafficClientCompletionGate()
      let result = makeChannel(
        { [weak self] in self?.current(token) == true },
        { [weak self] in
          guard failed.take(), let self else { return }
          self.queue.async { [self] in
            if channelID == identity, current(token) {
              fail(.connection, token: token, at: clock())
            }
          }
        })
      switch result {
      case .failure(let failure):
        let now = clock()
        fail(failure, token: token, at: now.isFinite && now >= time ? now : time)
        return
      case .success(let transport): channel = transport
      }
    }
    guard current(token) else {
      close()
      return
    }
    guard pending == nil, time >= nextRequest, let channel else { return }
    let request = Pending(id: UUID(), started: clock(), gate: TrafficClientCompletionGate())
    pending = request
    nextRequest = request.started + 1
    let identity = channelID
    channel.request { [weak self] result in
      guard request.gate.take(), let self else { return }
      // Do not enqueue an oversized data object on the worker queue.
      let bounded: Result<Data, TrafficClientFailure>
      if case .success(let data) = result, data.count > TrafficServiceReply.byteLimit {
        bounded = .failure(.invalidReply)
      } else {
        bounded = result
      }
      self.queue.async { [self] in
        handle(bounded, request: request, identity: identity, token: token)
      }
    }
  }
  private func handle(
    _ result: Result<Data, TrafficClientFailure>, request: Pending, identity: UUID, token: UInt64
  ) {
    guard current(token), channelID == identity, pending?.id == request.id else { return }
    let now = clock()
    guard now.isFinite, now >= request.started, now - request.started <= 5 else {
      fail(.timeout, token: token, at: now.isFinite ? now : lastTick)
      return
    }
    pending = nil
    switch result {
    case .failure(let failure): fail(failure, token: token, at: now)
    case .success(let data):
      guard let reply = TrafficServiceReply.decode(data),
        reply.sampledAt.map({ $0 >= openedAt && $0 <= now && now - $0 <= 15 }) ?? true
      else {
        fail(.invalidReply, token: token, at: now)
        return
      }
      guard reply.state != .unsupported else {
        fail(.invalidReply, token: token, at: now)
        return
      }
      var value = ProcessTrafficSnapshot()
      value.availability = TrafficAvailability(rawValue: reply.state.rawValue) ?? .warming
      value.message = reply.message
      value.sampledAt = reply.sampledAt
      value.intervalSeconds = reply.intervalSeconds
      value.activeSources = reply.activeSources
      value.processes = reply.rows.map {
        .init(
          pid: $0.pid, uniqueID: $0.uniqueID, name: $0.name, download: $0.download,
          upload: $0.upload)
      }
      publish(value, token: token)
    }
  }
}
