import Foundation
import Testing
import TinyStatsTraffic
import TinyStatsTrafficIPC

@testable import TinyStatsTrafficServiceCore

@Test func serviceSigningRequirementsPinBothIdentityFieldsAndRejectUntrustedInputs() {
  let team = "ABCD123456"
  let requirement = TrafficServiceSigning.requirement(
    identifier: TrafficServiceSigning.appIdentifier, team: team)
  #expect(requirement?.contains("anchor apple generic") == true)
  #expect(requirement?.contains("get-task-allow") == true)
  #expect(TrafficServiceSigning.requirement(identifier: "com.other.app", team: team) == nil)
  for value in ["", "short", "abcd123456", "ABCD12345\"", "ABCD123456 or true", "ABCD12345\n"] {
    #expect(
      TrafficServiceSigning.requirement(
        identifier: TrafficServiceSigning.appIdentifier, team: value) == nil)
  }
  #expect(
    TrafficServiceSigning.currentTeam(identifier: TrafficServiceSigning.serviceIdentifier) == nil)
}

private func validReply() -> TrafficServiceReply {
  var reply = TrafficServiceReply(state: .ready, message: "Modern connections only")
  reply.sampledAt = 100
  reply.intervalSeconds = 2
  reply.activeSources = 1
  reply.rows = [.init(pid: 42, uniqueID: 9001, name: "Example", download: 0, upload: 2048)]
  return reply
}
@Test func serviceWireContractBoundsBodiesOwnersRatesAndVersionBeforeDecoding() throws {
  let reply = validReply()
  let data = try #require(reply.encoded())
  #expect(TrafficServiceReply.decode(data)?.rows.first?.download == 0)
  #expect(TrafficServiceReply.decode(data)?.rows.first?.upload == 2048)
  #expect(TrafficServiceReply.decode(Data(repeating: 32, count: 16385)) == nil)
  #expect(TrafficServiceReply.decode(Data("{}".utf8)) == nil)
  for change in 0..<11 {
    var invalid = reply
    switch change {
    case 0: invalid.version = 2
    case 1: invalid.scope = "kernel-sockets"
    case 2: invalid.rows = Array(repeating: reply.rows[0], count: 9)
    case 3: invalid.rows[0].download = -.infinity
    case 4: invalid.rows[0].upload = -1
    case 5: invalid.rows[0].name = String(repeating: "a", count: 257)
    case 6: invalid.rows[0].name = "line\nbreak"
    case 7: invalid.rows[0].pid = -1
    case 8: invalid.rows[0].uniqueID = 0
    case 9: invalid.sampledAt = nil
    default: invalid.intervalSeconds = 0
    }
    #expect(invalid.encoded() == nil)
    if let badData = try? JSONEncoder().encode(invalid) {
      #expect(TrafficServiceReply.decode(badData) == nil)
    }
  }
}

private final class ServiceProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var counts = (made: 0, sampled: 0, stopped: 0, closed: 0, uid: UInt32(0))
  let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0),
    closed = DispatchSemaphore(value: 0)
  let blocking: Bool
  init(blocking: Bool = false) { self.blocking = blocking }
  var current: (made: Int, sampled: Int, stopped: Int, closed: Int, uid: UInt32) {
    lock.lock()
    defer { lock.unlock() }
    return counts
  }
  func made(_ uid: UInt32) {
    lock.lock()
    counts.made += 1
    counts.uid = uid
    lock.unlock()
  }
  func sample() -> ProcessTrafficSnapshot {
    lock.lock()
    counts.sampled += 1
    lock.unlock()
    began.signal()
    if blocking { _ = release.wait(timeout: .now() + 3) }
    var snapshot = ProcessTrafficSnapshot()
    snapshot.availability = .ready
    snapshot.sampledAt = 100
    snapshot.intervalSeconds = 2
    return snapshot
  }
  func stopped() {
    lock.lock()
    counts.stopped += 1
    lock.unlock()
  }
  func didClose() {
    lock.lock()
    counts.closed += 1
    lock.unlock()
    closed.signal()
  }
}
private final class ServiceSource: TrafficServiceSource {
  let probe: ServiceProbe
  init(_ probe: ServiceProbe, _ uid: UInt32) {
    self.probe = probe
    probe.made(uid)
  }
  func sample() -> ProcessTrafficSnapshot { probe.sample() }
  func stop() { probe.stopped() }
}
private final class ReplyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  let done = DispatchSemaphore(value: 0)
  func receive(_ value: Data) {
    lock.lock()
    data = value
    lock.unlock()
    done.signal()
  }
  var value: TrafficServiceReply? {
    lock.lock()
    defer { lock.unlock() }
    return data.flatMap(TrafficServiceReply.decode)
  }
  func wait() async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
      if received { return true }
      try? await Task.sleep(for: .milliseconds(1))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return received
  }
  private var received: Bool {
    lock.lock()
    defer { lock.unlock() }
    return data != nil
  }
}

@Test func serviceSessionCoalescesCallsBindsTheCallerAndWithholdsPendingDataAfterStop() {
  let probe = ServiceProbe(blocking: true)
  let session = TrafficServiceSession(
    userID: 501, leaseSeconds: 2, makeSource: { _, uid in ServiceSource(probe, uid) },
    onClose: { probe.didClose() })
  let unsupported = ReplyBox()
  session.snapshot(2) { unsupported.receive($0) }
  #expect(unsupported.value?.state == .unsupported && probe.current.made == 0)
  let initial = ReplyBox()
  session.snapshot(1) { initial.receive($0) }
  #expect(probe.began.wait(timeout: .now() + 2) == .success)
  for _ in 0..<32 {
    let busy = ReplyBox()
    session.snapshot(1) { busy.receive($0) }
    #expect(busy.value?.state == .busy)
  }
  session.stop {}
  probe.release.signal()
  #expect(initial.done.wait(timeout: .now() + 2) == .success)
  #expect(initial.value?.state == .unavailable && initial.value?.rows.isEmpty == true)
  #expect(probe.closed.wait(timeout: .now() + 2) == .success)
  session.end()
  #expect(probe.current.made == 1 && probe.current.sampled == 1 && probe.current.uid == 501)
  #expect(probe.current.stopped == 1 && probe.current.closed == 1)
}

@Test func serviceLeaseExpiresEvenWhenTheClientConnectsWithoutSendingARequest() {
  let probe = ServiceProbe()
  let session = TrafficServiceSession(
    userID: 501, leaseSeconds: 0.05, makeSource: { _, uid in ServiceSource(probe, uid) },
    onClose: { probe.didClose() })
  #expect(probe.closed.wait(timeout: .now() + 2) == .success)
  let reply = ReplyBox()
  session.snapshot(1) { reply.receive($0) }
  #expect(reply.value?.state == .unavailable && probe.current.made == 0)
  #expect(probe.current.closed == 1)
}

private final class XPCTestService: NSObject, TrafficServiceProtocol {
  func snapshot(_ version: Int, withReply reply: @escaping @Sendable (Data) -> Void) {
    reply(validReply().encoded() ?? Data())
  }
  func stop(withReply reply: @escaping @Sendable () -> Void) { reply() }
}
private final class XPCTestDelegate: NSObject, NSXPCListenerDelegate {
  private let lock = NSLock()
  private var accepted = false
  var wasAccepted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return accepted
  }
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    lock.lock()
    accepted = true
    lock.unlock()
    connection.exportedInterface = NSXPCInterface(with: TrafficServiceProtocol.self)
    connection.exportedObject = XPCTestService()
    connection.resume()
    return true
  }
}
@Test func nativeXPCContractRoundTripsOnlyTheOwnedMockService() async throws {
  let listener = NSXPCListener.anonymous()
  let delegate = XPCTestDelegate()
  listener.delegate = delegate
  listener.resume()
  let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
  defer {
    connection.invalidate()
    listener.invalidate()
    withExtendedLifetime(delegate) {}
  }
  connection.remoteObjectInterface = NSXPCInterface(with: TrafficServiceProtocol.self)
  connection.resume()
  let reply = ReplyBox()
  let proxy = try #require(
    connection.remoteObjectProxyWithErrorHandler { _ in reply.receive(Data()) }
      as? TrafficServiceProtocol)
  proxy.snapshot(1) { reply.receive($0) }
  // Native IPC must make progress without blocking Swift's cooperative executor.
  #expect(await reply.wait())
  #expect(reply.value?.state == .ready && reply.value?.rows.first?.upload == 2048)
}
@Test func nativeXPCRejectsAWrongSigningIdentityBeforeTheExportDelegateRuns() async throws {
  let listener = NSXPCListener.anonymous()
  let delegate = XPCTestDelegate()
  listener.setConnectionCodeSigningRequirement(
    "identifier \"com.niechen.tinystats.deliberately-wrong-identity\"")
  listener.delegate = delegate
  listener.resume()
  let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
  defer {
    connection.invalidate()
    listener.invalidate()
    withExtendedLifetime(delegate) {}
  }
  connection.remoteObjectInterface = NSXPCInterface(with: TrafficServiceProtocol.self)
  connection.resume()
  let reply = ReplyBox()
  let proxy = try #require(
    connection.remoteObjectProxyWithErrorHandler { _ in reply.receive(Data()) }
      as? TrafficServiceProtocol)
  proxy.snapshot(1) { reply.receive($0) }
  #expect(await reply.wait())
  #expect(reply.value == nil)
  #expect(!delegate.wasAccepted)
}

@Test func serviceStartupExpiresWithoutAnAdmittedPeer() throws {
  let closed = DispatchSemaphore(value: 0)
  let candidate = TrafficServiceListener(
    team: "ABCD123456", startupLeaseSeconds: 0.05, onIdle: { closed.signal() })
  let delegate = try #require(candidate)
  let listener = NSXPCListener.anonymous()
  defer {
    listener.invalidate()
    withExtendedLifetime(delegate) {}
  }
  delegate.configure(listener)
  listener.resume()
  #expect(closed.wait(timeout: .now() + 2) == .success)
  #expect(closed.wait(timeout: .now()) == .timedOut)
}

@Test func trafficWireContractRejectsDuplicateOwnerRows() throws {
  var reply = validReply()
  reply.rows.append(reply.rows[0])
  #expect(reply.encoded() == nil)
  let data = try JSONEncoder().encode(reply)
  #expect(TrafficServiceReply.decode(data) == nil)
}
