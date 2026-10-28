import Darwin
import Foundation
import Testing
import TinyStatsTraffic
import TinyStatsTrafficIPC

@testable import TinyStatsTrafficClient

private final class ClientClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time = 1.0
  var now: Double {
    get {
      lock.lock()
      defer { lock.unlock() }
      return time
    }
    set {
      lock.lock()
      time = newValue
      lock.unlock()
    }
  }
}
private final class ClientChannel: TrafficClientChannel, @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [@Sendable (Result<Data, TrafficClientFailure>) -> Void] = []
  private var stopCount = 0, invalidations = 0
  let failure: @Sendable () -> Void
  let requested = DispatchSemaphore(value: 0)
  init(_ failure: @escaping @Sendable () -> Void) { self.failure = failure }
  var counts: (requests: Int, stops: Int, invalidations: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (callbacks.count, stopCount, invalidations)
  }
  func request(_ completion: @escaping @Sendable (Result<Data, TrafficClientFailure>) -> Void) {
    lock.lock()
    callbacks.append(completion)
    lock.unlock()
    requested.signal()
  }
  func stop() {
    lock.lock()
    stopCount += 1
    lock.unlock()
  }
  func invalidate() {
    lock.lock()
    invalidations += 1
    lock.unlock()
  }
  func reply(_ data: Data, at index: Int = 0) {
    lock.lock()
    let callback = callbacks[index]
    lock.unlock()
    callback(.success(data))
  }
}
private final class ClientFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ClientChannel] = []
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  let blocked: Bool
  init(blocked: Bool = false) { self.blocked = blocked }
  var channels: [ClientChannel] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
  func make(_ failure: @escaping @Sendable () -> Void) -> Result<
    any TrafficClientChannel, TrafficClientFailure
  > {
    let channel = ClientChannel(failure)
    lock.lock()
    values.append(channel)
    lock.unlock()
    entered.signal()
    if blocked { _ = release.wait(timeout: .now() + 3) }
    return .success(channel)
  }
}
private func ready(_ time: Double = 1, upload: Double = 2048) -> Data {
  var reply = TrafficServiceReply(state: .ready, message: "Current-user modern connections")
  reply.sampledAt = time
  reply.intervalSeconds = 2
  reply.activeSources = 1
  reply.rows = [.init(pid: 42, uniqueID: 9001, name: "Example", download: 0, upload: upload)]
  return reply.encoded() ?? Data()
}
private func eventually(_ condition: () -> Bool) -> Bool {
  let until = ProcessInfo.processInfo.systemUptime + 2
  while ProcessInfo.processInfo.systemUptime < until {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.001)
  }
  return condition()
}
private func reading(_ client: ModernTrafficClient, _ clock: ClientClock) -> ProcessTrafficSnapshot
{
  client.read(at: clock.now, enabled: true, serviceAvailable: true)
}

@Test func clientIsIdleUntilBothOptInAndServiceAvailabilityAndNativeIdentityFailsClosed() {
  let factory = ClientFactory()
  let clock = ClientClock()
  let client = ModernTrafficClient(
    clock: { clock.now }, makeChannel: { _, failure in factory.make(failure) })
  #expect(client.read(at: 1, enabled: false, serviceAvailable: false).availability == .inactive)
  #expect(client.read(at: 1, enabled: true, serviceAvailable: false).availability == .unavailable)
  client.stop()
  #expect(factory.channels.isEmpty)
  switch NativeTrafficClientChannel.make(authorized: { true }, onFailure: {}) {
  case .failure(let error): #expect(error == .signature)
  case .success(let channel):
    channel.invalidate()
    Issue.record("Test runner must not identify as the signed TinyStats app")
  }
}

@Test func clientCoalescesTicksLimitsCadenceAndIgnoresDuplicateReplies() throws {
  let factory = ClientFactory()
  let clock = ClientClock()
  let client = ModernTrafficClient(
    clock: { clock.now }, makeChannel: { _, failure in factory.make(failure) })
  defer { client.stop() }
  _ = reading(client, clock)
  #expect(eventually { factory.channels.first?.counts.requests == 1 })
  let channel = try #require(factory.channels.first)
  for _ in 0..<200 { _ = reading(client, clock) }
  #expect(channel.counts.requests == 1)
  channel.reply(ready())
  #expect(eventually { reading(client, clock).processes.first?.upload == 2048 })
  channel.reply(ready(upload: 9999))
  clock.now = 1.5
  #expect(reading(client, clock).processes.first?.upload == 2048)
  #expect(channel.counts.requests == 1)
  clock.now = 2
  _ = reading(client, clock)
  #expect(eventually { channel.counts.requests == 2 })
  channel.reply(ready(2, upload: 4096), at: 1)
  #expect(eventually { reading(client, clock).processes.first?.upload == 4096 })
}

@Test func clientOptOutAndReplacedSessionsRejectLateRepliesImmediately() throws {
  let factory = ClientFactory()
  let clock = ClientClock()
  let client = ModernTrafficClient(
    clock: { clock.now }, makeChannel: { _, failure in factory.make(failure) })
  _ = reading(client, clock)
  #expect(eventually { factory.channels.first?.counts.requests == 1 })
  let old = try #require(factory.channels.first)
  client.stop()
  #expect(client.read(at: 1, enabled: false, serviceAvailable: false).processes.isEmpty)
  clock.now = 2
  _ = reading(client, clock)
  #expect(eventually { factory.channels.count == 2 && factory.channels[1].counts.requests == 1 })
  old.reply(ready())
  #expect(reading(client, clock).processes.isEmpty)
  factory.channels[1].reply(ready(2))
  #expect(eventually { reading(client, clock).availability == .ready })
  let unavailable = client.read(at: 2, enabled: true, serviceAvailable: false)
  #expect(unavailable.availability == .unavailable && unavailable.processes.isEmpty)
  #expect(eventually { factory.channels[1].counts.invalidations == 1 })
  client.stop()
}

@Test func clientTimeoutBackoffAndInvalidationDoNotProduceRetryStorms() throws {
  let factory = ClientFactory()
  let clock = ClientClock()
  let client = ModernTrafficClient(
    clock: { clock.now }, makeChannel: { _, failure in factory.make(failure) })
  defer { client.stop() }
  _ = reading(client, clock)
  #expect(eventually { factory.channels.first?.counts.requests == 1 })
  let first = try #require(factory.channels.first)
  clock.now = 7
  #expect(eventually { reading(client, clock).availability == .unavailable })
  #expect(first.counts.invalidations == 1)
  first.reply(ready(7))
  clock.now = 60
  for _ in 0..<100 { _ = reading(client, clock) }
  #expect(factory.channels.count == 1 && reading(client, clock).processes.isEmpty)
  clock.now = 67
  _ = reading(client, clock)
  #expect(eventually { factory.channels.count == 2 && factory.channels[1].counts.requests == 1 })
  factory.channels[1].reply(ready(67))
  #expect(eventually { reading(client, clock).availability == .ready })
  factory.channels[1].failure()
  #expect(eventually { reading(client, clock).availability == .unavailable })
  #expect(reading(client, clock).processes.isEmpty)
}

@Test func clientWithholdsOversizedMalformedForeignScopeAndStaleReplies() throws {
  for variant in 0..<6 {
    let factory = ClientFactory()
    let clock = ClientClock()
    let client = ModernTrafficClient(
      clock: { clock.now }, makeChannel: { _, failure in factory.make(failure) })
    _ = reading(client, clock)
    #expect(eventually { factory.channels.first?.counts.requests == 1 })
    let channel = try #require(factory.channels.first)
    var data = ready()
    switch variant {
    case 0: data = Data(repeating: 0, count: 16385)
    case 1: data = Data("{}".utf8)
    case 2:
      var value = try #require(TrafficServiceReply.decode(data))
      value.scope = "kernel-sockets"
      data = try JSONEncoder().encode(value)
    case 3: data = ready(0.5)
    case 4: data = ready(2)
    default:
      var value = try #require(TrafficServiceReply.decode(data))
      value.version = 2
      data = try JSONEncoder().encode(value)
    }
    channel.reply(data)
    #expect(eventually { reading(client, clock).availability == .unavailable })
    #expect(reading(client, clock).processes.isEmpty && channel.counts.invalidations == 1)
    client.stop()
  }
}

@Test func clientExpiresCachedValuesAndClearsThemBeforeABackwardsClockReset() throws {
  let factory = ClientFactory()
  let clock = ClientClock()
  let client = ModernTrafficClient(
    clock: { clock.now }, makeChannel: { _, failure in factory.make(failure) })
  defer { client.stop() }
  _ = reading(client, clock)
  #expect(eventually { factory.channels.first?.counts.requests == 1 })
  let channel = try #require(factory.channels.first)
  channel.reply(ready())
  #expect(eventually { reading(client, clock).availability == .ready })
  clock.now = 0.5
  #expect(reading(client, clock).processes.isEmpty)
  #expect(eventually { factory.channels.count == 2 && factory.channels[1].counts.requests == 1 })
  factory.channels[1].reply(ready(0.5))
  #expect(eventually { reading(client, clock).availability == .ready })
  clock.now = 20
  let stale = reading(client, clock)
  #expect(stale.availability == .unavailable && stale.processes.isEmpty)
}

@Test func clientNeverSendsAfterOptOutDuringADeferredConnectionAndReleasesOnDeinit() throws {
  let factory = ClientFactory(blocked: true)
  let clock = ClientClock()
  var client: ModernTrafficClient? = ModernTrafficClient(
    clock: { clock.now }, makeChannel: { _, failure in factory.make(failure) })
  _ = reading(try #require(client), clock)
  #expect(factory.entered.wait(timeout: .now() + 2) == .success)
  client?.stop()
  factory.release.signal()
  #expect(eventually { factory.channels.first?.counts.invalidations == 1 })
  #expect(factory.channels.first?.counts.requests == 0)
  client = nil
  let secondFactory = ClientFactory()
  var second: ModernTrafficClient? = ModernTrafficClient(
    clock: { clock.now }, makeChannel: { _, failure in secondFactory.make(failure) })
  _ = reading(try #require(second), clock)
  #expect(eventually { secondFactory.channels.first?.counts.requests == 1 })
  let weakClient = WeakClientRef(second)
  second = nil
  #expect(
    eventually {
      weakClient.value == nil && secondFactory.channels.first?.counts.invalidations == 1
    })
}

private final class NativeReplyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Data, TrafficClientFailure>?
  func put(_ result: Result<Data, TrafficClientFailure>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }
  var failure: TrafficClientFailure? {
    lock.lock()
    defer { lock.unlock() }
    if case .failure(let error) = result { return error }
    return nil
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
    return result != nil
  }
}
private final class NonrootService: NSObject, TrafficServiceProtocol {
  func snapshot(_ version: Int, withReply reply: @escaping @Sendable (Data) -> Void) {
    reply(ready(ProcessInfo.processInfo.systemUptime))
  }
  func stop(withReply reply: @escaping @Sendable () -> Void) { reply() }
}
private final class NonrootDelegate: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.exportedInterface = NSXPCInterface(with: TrafficServiceProtocol.self)
    connection.exportedObject = NonrootService()
    connection.resume()
    return true
  }
}
@Test func nativeClientRejectsAnOwnedNonrootPeerEvenWhenItsReplyIsWellFormed() async {
  #expect(geteuid() != 0)
  let listener = NSXPCListener.anonymous()
  let delegate = NonrootDelegate()
  listener.delegate = delegate
  listener.resume()
  let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
  // Only this owned mock uses a permissive requirement. Production derives an exact helper
  // requirement and privileged namespace after validating its own app signature.
  let channel = NativeTrafficClientChannel(
    connection: connection, requirement: "always", onFailure: {})
  defer {
    channel.invalidate()
    listener.invalidate()
    withExtendedLifetime(delegate) {}
  }
  let box = NativeReplyBox()
  channel.request { box.put($0) }
  // Yield the cooperative executor while native IPC/signature callbacks are pending.
  #expect(await box.wait())
  #expect(box.failure == .untrustedPeer)
}

private final class WeakClientRef {
  weak var value: ModernTrafficClient?
  init(_ value: ModernTrafficClient?) { self.value = value }
}

@Test func clientCancellationIsRecheckedBeforeADelayedFactoryMayConnect() {
  let factory = ClientFactory()
  let clock = ClientClock()
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  let client = ModernTrafficClient(
    clock: { clock.now },
    makeChannel: { authorized, failure in
      defer { finished.signal() }
      entered.signal()
      _ = release.wait(timeout: .now() + 3)
      guard authorized() else { return .failure(.connection) }
      return factory.make(failure)
    })
  _ = reading(client, clock)
  #expect(entered.wait(timeout: .now() + 2) == .success)
  client.stop()
  release.signal()
  #expect(client.read(at: 1, enabled: false, serviceAvailable: false).availability == .inactive)
  #expect(finished.wait(timeout: .now() + 2) == .success)
  #expect(factory.channels.isEmpty)
}

@Test func clientCadenceStartsAfterDelayedSetupRatherThanTheOldSamplerTick() throws {
  let factory = ClientFactory()
  let clock = ClientClock()
  let client = ModernTrafficClient(
    clock: { clock.now },
    makeChannel: { _, failure in
      clock.now = 100
      return factory.make(failure)
    })
  defer { client.stop() }
  _ = reading(client, clock)
  #expect(eventually { factory.channels.first?.counts.requests == 1 })
  let channel = try #require(factory.channels.first)
  #expect(channel.requested.wait(timeout: .now()) == .success)
  channel.reply(ready(100))
  #expect(eventually { reading(client, clock).availability == .ready })
  clock.now = 100.5
  _ = reading(client, clock)
  #expect(channel.requested.wait(timeout: .now() + 0.05) == .timedOut)
  clock.now = 101
  _ = reading(client, clock)
  #expect(channel.requested.wait(timeout: .now() + 2) == .success)
  #expect(channel.counts.requests == 2)
}

@Test func clientFailureBackoffStartsAfterDelayedSetupRatherThanTheOldSamplerTick() {
  let attempts = DispatchSemaphore(value: 0)
  let clock = ClientClock()
  let client = ModernTrafficClient(
    clock: { clock.now },
    makeChannel: { _, _ in
      clock.now = 100
      attempts.signal()
      return .failure(.signature)
    })
  defer { client.stop() }
  _ = reading(client, clock)
  #expect(attempts.wait(timeout: .now() + 2) == .success)
  #expect(eventually { reading(client, clock).availability == .unavailable })
  clock.now = 159
  _ = reading(client, clock)
  #expect(attempts.wait(timeout: .now() + 0.05) == .timedOut)
  clock.now = 160
  _ = reading(client, clock)
  #expect(attempts.wait(timeout: .now() + 2) == .success)
}
