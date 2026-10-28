import Foundation
import TinyStatsTraffic
import TinyStatsTrafficIPC

/// Never instantiated by the main app. The standalone service checks root + its own signature
/// first; this listener additionally enforces signed peer identity on every incoming message.
public final class TrafficServiceListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let requirement: String
  private let onIdle: @Sendable () -> Void
  private let startupLeaseSeconds: Double
  private var startupDeadline: DispatchSourceTimer?
  private var occupied = false
  public init?(
    team: String, startupLeaseSeconds: Double = 30, onIdle: @escaping @Sendable () -> Void
  ) {
    precondition(
      startupLeaseSeconds.isFinite && startupLeaseSeconds > 0 && startupLeaseSeconds <= 30)
    guard
      let requirement = TrafficServiceSigning.requirement(
        identifier: TrafficServiceSigning.appIdentifier, team: team)
    else { return nil }
    self.requirement = requirement
    self.onIdle = onIdle
    self.startupLeaseSeconds = startupLeaseSeconds
  }
  deinit { startupDeadline?.cancel() }
  public func configure(_ listener: NSXPCListener) {
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = self
    lock.lock()
    if !occupied && startupDeadline == nil {
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(deadline: .now() + startupLeaseSeconds, leeway: .milliseconds(100))
      timer.setEventHandler { [weak self] in self?.expireBeforeAdmission() }
      startupDeadline = timer
      timer.resume()
    }
    lock.unlock()
  }
  private func expireBeforeAdmission() {
    lock.lock()
    guard !occupied else {
      lock.unlock()
      return
    }
    occupied = true
    let timer = startupDeadline
    startupDeadline = nil
    lock.unlock()
    timer?.cancel()
    onIdle()
  }
  public func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    lock.lock()
    guard !occupied else {
      lock.unlock()
      return false
    }
    occupied = true
    let startup = startupDeadline
    startupDeadline = nil
    lock.unlock()
    startup?.cancel()
    let peer = TrafficServicePeer(connection)
    let session = TrafficServiceSession(
      userID: connection.effectiveUserIdentifier,
      onClose: { [self] in
        peer.invalidate()
        onIdle()
      })
    connection.setCodeSigningRequirement(requirement)
    connection.exportedInterface = NSXPCInterface(with: TrafficServiceProtocol.self)
    connection.exportedObject = session
    connection.invalidationHandler = { [session] in session.end() }
    connection.interruptionHandler = { peer.invalidate() }
    connection.resume()
    return true
  }
}

/// The XPC admission gate coalesces callers before enqueueing work. The serial utility queue
/// owns the native reader, cached reply and one-shot expiry watchdog. There is no poll timer.
final class TrafficServiceSession: NSObject, TrafficServiceProtocol, @unchecked Sendable {
  private let onClose: @Sendable () -> Void
  private let leaseSeconds: Double
  private let makeSource: @Sendable (DispatchQueue, UInt32) -> any TrafficServiceSource
  private let queue = DispatchQueue(label: "app.tinystats.traffic-service", qos: .utility)
  private let lock = NSLock()
  private let userID: UInt32
  private var active = true, queued = false
  private var reader: (any TrafficServiceSource)?
  private var deadline: DispatchSourceTimer?
  private var lastSample = -Double.infinity
  private var latest = TrafficServiceReply(
    state: .starting,
    message: "Modern connections only; current user. Not combined with kernel socket totals.")
  init(
    userID: UInt32, leaseSeconds: Double = 30,
    makeSource: @escaping @Sendable (DispatchQueue, UInt32) -> any TrafficServiceSource = {
      NativeTrafficServiceSource(queue: $0, userID: $1)
    },
    onClose: @escaping @Sendable () -> Void
  ) {
    precondition(leaseSeconds.isFinite && leaseSeconds > 0 && leaseSeconds <= 30)
    self.userID = userID
    self.leaseSeconds = leaseSeconds
    self.makeSource = makeSource
    self.onClose = onClose
    super.init()
    queue.async { [self] in touchDeadline() }
  }
  private func response(_ state: TrafficServiceReply.State, _ message: String) -> Data {
    // All literal fallback responses satisfy the closed contract.
    TrafficServiceReply(state: state, message: message).encoded() ?? Data()
  }
  func snapshot(_ version: Int, withReply reply: @escaping @Sendable (Data) -> Void) {
    guard version == TrafficServiceReply.version else {
      reply(response(.unsupported, "Unsupported traffic service protocol."))
      return
    }
    lock.lock()
    guard active, !queued else {
      let state: TrafficServiceReply.State = active ? .busy : .unavailable
      lock.unlock()
      reply(response(state, "Traffic service is busy or stopping."))
      return
    }
    queued = true
    lock.unlock()
    queue.async { [self] in
      lock.lock()
      let allowed = active
      lock.unlock()
      if allowed {
        touchDeadline()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSample >= 0.5 {
          if reader == nil { reader = makeSource(queue, userID) }
          if let reader { latest = TrafficServiceReply(reader.sample()) }
          lastSample = now
        }
      }
      lock.lock()
      let stillActive = active
      queued = false
      lock.unlock()
      reply(
        stillActive
          ? latest.encoded() ?? response(.unavailable, "Invalid native reply withheld.")
          : response(.unavailable, "Traffic service stopped."))
    }
  }
  private func touchDeadline() {
    if deadline == nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.setEventHandler { [weak self] in self?.end() }
      deadline = timer
      timer.resume()
    }
    deadline?.schedule(deadline: .now() + leaseSeconds, leeway: .milliseconds(100))
  }
  func stop(withReply reply: @escaping @Sendable () -> Void) {
    end()
    reply()
  }
  func end() {
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    active = false
    lock.unlock()
    queue.async { [self] in
      reader?.stop()
      reader = nil
      deadline?.cancel()
      deadline = nil
      latest = TrafficServiceReply(state: .unavailable, message: "Traffic service stopped.")
      onClose()
    }
  }
}

/// Only invalidation crosses queues; no mutable connection configuration crosses this wrapper.
private final class TrafficServicePeer: @unchecked Sendable {
  private weak var connection: NSXPCConnection?
  init(_ connection: NSXPCConnection) { self.connection = connection }
  func invalidate() { connection?.invalidate() }
}

protocol TrafficServiceSource: AnyObject {
  func sample() -> ProcessTrafficSnapshot
  func stop()
}
private final class NativeTrafficServiceSource: TrafficServiceSource {
  private let session: ModernConnectionTrafficSession
  init(queue: DispatchQueue, userID: UInt32) {
    session = ModernConnectionTrafficSession(queue: queue, userID: userID)
  }
  func sample() -> ProcessTrafficSnapshot { session.sample() }
  func stop() { session.stop() }
}
