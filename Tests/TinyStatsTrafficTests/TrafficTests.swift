import CTinyStatsTraffic
import Darwin
import Foundation
import Testing

@testable import TinyStatsTraffic

private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, into bytes: inout Data) {
  var little = value.littleEndian
  withUnsafeBytes(of: &little) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) }
}
private func frame(_ type: UInt32, count: Int, context: UInt64 = 0, flags: UInt16 = 0) -> Data {
  var bytes = Data(repeating: 0, count: count)
  put(type, at: 8, into: &bytes)
  put(context, at: 0, into: &bytes)
  put(UInt16(count), at: 12, into: &bytes)
  put(flags, at: 14, into: &bytes)
  return bytes
}
private func added(_ source: UInt64, provider: UInt32 = 2) -> Data {
  var bytes = frame(10001, count: 32)
  put(source, at: 16, into: &bytes)
  put(provider, at: 24, into: &bytes)
  return bytes
}
private func update(
  _ source: UInt64 = 1, provider: UInt32 = 2, layout: Int = 344,
  pid: UInt32 = 42, unique: UInt64 = 100, start: UInt64 = 10, observed: UInt64 = 100,
  rx: UInt64 = 0, tx: UInt64 = 0, closing: Bool = false
) -> Data {
  var bytes = frame(10006, count: 152 + layout, flags: closing ? 4 : 0)
  put(source, at: 16, into: &bytes)
  put(provider, at: 144, into: &bytes)
  put(rx, at: 40, into: &bytes)
  put(tx, at: 56, into: &bytes)
  put(unique, at: 152, into: &bytes)
  put(start, at: 168, into: &bytes)
  put(observed, at: 176, into: &bytes)
  put(pid, at: 152 + (provider == 4 ? 128 : 116), into: &bytes)
  let name = 152 + (provider == 4 ? 132 : 196)
  bytes.replaceSubrange(name..<(name + 7), with: Data("Fixture".utf8))
  return bytes
}
private func flow(
  _ source: UInt64 = 1, pid: Int32 = 42, unique: UInt64 = 100,
  start: UInt64 = 10, observed: UInt64 = 100, rx: UInt64 = 0, tx: UInt64 = 0
) -> TrafficFlow {
  .init(
    source: source, provider: 2, owner: .init(pid: pid, uniqueID: unique), name: "Fixture",
    started: start, observed: observed, received: rx, sent: tx)
}
private func baseline(_ ledger: inout TrafficLedger) throws {
  try ledger.add(source: 1, provider: 2)
  ledger.begin()
  try ledger.update(flow(rx: 1_000_000, tx: 2_000_000), closing: false)
  let result = ledger.finish(at: 1, continuous: 100, completedAt: 1.01)
  #expect(result.availability == .warming)
  #expect(result.processes.isEmpty)
}

@Test func trafficDecoderSupportsKnownLayoutsAndAggregateFraming() throws {
  for (provider, size) in [(UInt32(2), 344), (2, 360), (4, 280)] {
    let packet =
      added(1, provider: provider) + update(provider: provider, layout: size, rx: 123, tx: 456)
      + frame(0, count: 16, context: 16, flags: 2)
    let messages = try TrafficProtocol.decode(packet)
    #expect(messages.count == 3)
    guard case .update(let record, _) = messages[1], case .success(16, true) = messages[2] else {
      Issue.record("Unexpected decoded messages")
      return
    }
    #expect(record.owner == .init(pid: 42, uniqueID: 100))
    #expect(record.name == "Fixture" && record.received == 123 && record.sent == 456)
  }
}

@Test func trafficDecoderRejectsTruncationUnknownABIAndInvalidOwnershipData() {
  let valid = update()
  for length in [0, 1, 15, 151, valid.count - 1] {
    #expect(throws: (any Error).self) { try TrafficProtocol.decode(Data(valid.prefix(length))) }
  }
  for bytes in [
    update(layout: 352), update(provider: 3), update(pid: UInt32.max),
    update(start: 200, observed: 100), valid + Data([0]),
  ] {
    #expect(throws: (any Error).self) { try TrafficProtocol.decode(bytes) }
  }
}

@Test func trafficLedgerExcludesHistoryAndIncludesFinalShortLivedSocketsExactlyOnce() throws {
  var ledger = TrafficLedger()
  try baseline(&ledger)
  try ledger.add(source: 2, provider: 2)
  try ledger.update(flow(2, start: 101, observed: 120, rx: 512, tx: 1024), closing: true)
  try ledger.update(flow(2, start: 101, observed: 120, rx: 512, tx: 1024), closing: true)
  ledger.remove(source: 2, flags: 0)
  // A pre-existing but newly observed source contributes no historical bytes.
  try ledger.add(source: 3, provider: 2)
  ledger.begin()
  try ledger.update(flow(3, start: 50, observed: 120, rx: 9_000_000), closing: false)
  try ledger.update(flow(observed: 120, rx: 1_000_100, tx: 2_000_200), closing: false)
  let result = ledger.finish(at: 3, continuous: 120, completedAt: 3.01)
  #expect(result.availability == .ready)
  #expect(result.processes.count == 1)
  #expect(result.processes.first?.download == 306)
  #expect(result.processes.first?.upload == 612)
}

@Test func trafficLedgerInvalidatesMissingDropResetAndProcessReuseIntervals() throws {
  for scenario in 0..<4 {
    var ledger = TrafficLedger()
    try baseline(&ledger)
    ledger.begin()
    if scenario == 1 {
      ledger.remove(source: 1, flags: 8)
    } else if scenario == 2 {
      try ledger.update(flow(rx: 1), closing: false)
    } else if scenario == 3 {
      try ledger.update(flow(unique: 101, rx: 9_000_000), closing: false)
    }
    let incomplete = ledger.finish(at: 3, continuous: 120, completedAt: 3)
    #expect(incomplete.availability == .incomplete)
    #expect(incomplete.processes.isEmpty)
    ledger.begin()
    if scenario != 1 { try ledger.update(flow(observed: 130, rx: 10_000_000), closing: false) }
    let recovery = ledger.finish(at: 5, continuous: 130, completedAt: 5)
    #expect(recovery.availability == .warming)
    #expect(recovery.processes.isEmpty)
  }
}

@Test func trafficLedgerRejectsUnknownSourcesAndBoundsState() throws {
  var ledger = TrafficLedger(sourceLimit: 1, ownerLimit: 1)
  #expect(throws: TrafficAccountingError.self) { try ledger.update(flow(), closing: false) }
  try ledger.add(source: 1, provider: 2)
  #expect(throws: TrafficAccountingError.self) { try ledger.add(source: 2, provider: 2) }
  #expect(throws: TrafficAccountingError.self) { try ledger.add(source: 1, provider: 2) }
  let rejected = ledger.finish(at: 1, continuous: 100, completedAt: 1)
  #expect(rejected.availability == .incomplete && rejected.processes.isEmpty)
  ledger = TrafficLedger()
  try baseline(&ledger)
  ledger.begin()
  try ledger.update(flow(observed: 120, rx: 1_000_000, tx: 2_000_000), closing: false)
  let idle = ledger.finish(at: 3, continuous: 120, completedAt: 3)
  #expect(idle.availability == .ready)
  #expect(idle.processes.first?.download == 0 && idle.processes.first?.upload == 0)
}

/// A queue-less transport drives protocol/session failures without real sockets or sleeps.
private final class TrafficTransportFixture: @unchecked Sendable {
  var now = 1.0
  var packets: [Data] = []
  var queries: [UInt64] = [], subscriptions: [UInt32] = []
  var closes = 0, opens = 0
  var socket: TrafficSocket {
    .init(
      open: {
        self.opens += 1
        return 12345
      },
      query: { _, context in
        self.queries.append(context)
        return true
      },
      subscribe: { _, provider, _ in
        self.subscriptions.append(provider)
        return true
      },
      receive: { _, bytes in
        guard !self.packets.isEmpty else { return 0 }
        let packet = self.packets.removeFirst()
        bytes.replaceSubrange(0..<packet.count, with: packet)
        return Int32(packet.count)
      }, close: { _ in self.closes += 1 })
  }
  func makeReader(scope: TrafficCollectionScope = .kernelSockets, userID: UInt32? = nil)
    -> NetworkTrafficReader
  {
    .init(
      scope: scope, userID: userID, socket: socket, clock: { self.now },
      continuous: { UInt64(self.now * 100) })
  }
}

@Test func trafficSessionRequiresAcknowledgmentsAndAllQueryFragments() throws {
  let transport = TrafficTransportFixture()
  let reader = TrafficTransportFixture()  // Independent fixtures must never share a queue.
  _ = reader
  let collector = transport.makeReader()
  #expect(collector.read(at: 1).availability == .starting)
  #expect(transport.queries == [1])
  transport.packets = [
    frame(0, count: 16, context: 1), added(1), frame(0, count: 16, context: 2),
    frame(0, count: 16, context: 4),
  ]
  _ = collector.read(at: 1)
  #expect(transport.subscriptions == [2, 4])
  #expect(transport.queries == [1, 16])
  transport.packets = [update(), frame(0, count: 16, context: 16, flags: 2)]
  #expect(collector.read(at: 1).availability == .starting)
  #expect(transport.queries == [1, 16, 16])
  transport.packets = [frame(0, count: 16, context: 16)]
  #expect(collector.read(at: 1).availability == .warming)
  transport.now = 3
  _ = collector.read(at: 3)
  transport.packets = [update(observed: 300, rx: 100, tx: 200), frame(0, count: 16, context: 17)]
  let result = collector.read(at: 3)
  #expect(result.availability == .ready)
  #expect(result.processes.first?.download == 50 && result.processes.first?.upload == 100)
  collector.stop()
  #expect(transport.closes == 1 && collector.latest.availability == .inactive)
}

@Test func trafficSessionTimesOutBacksOffAndFailsClosedOnUnsupportedFrames() {
  let transport = TrafficTransportFixture()
  let collector = TrafficTransportFixture()
  _ = collector
  let reader = transport.makeReader()
  _ = reader.read(at: 1)
  transport.now = 12
  #expect(reader.read(at: 12).availability == .unavailable)
  #expect(transport.closes == 1)
  _ = reader.read(at: 20)
  #expect(transport.opens == 1)
  transport.now = 73
  _ = reader.read(at: 73)
  #expect(transport.opens == 2)
  transport.packets = [frame(99999, count: 16)]
  #expect(reader.read(at: 73).availability == .unavailable)
  #expect(transport.closes == 2)
  reader.stop()
  transport.now = 74
  #expect(reader.read(at: 74).availability == .starting)
}

private final class LocalTrafficPair {
  private var listener: Int32 = -1, client: Int32 = -1, peer: Int32 = -1
  init() throws {
    listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else {
      throw TrafficAccountingError.invalidSource
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.getsockname(listener, $0, &length)
      }
    }
    guard named == 0 else {
      throw TrafficAccountingError.invalidSource
    }
    client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, length) }
    }
    guard connected == 0 else {
      throw TrafficAccountingError.invalidSource
    }
    peer = Darwin.accept(listener, nil, nil)
    guard peer >= 0 else {
      throw TrafficAccountingError.invalidSource
    }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    for descriptor in [client, peer] {
      _ = setsockopt(
        descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      _ = setsockopt(
        descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
  }
  deinit {
    Darwin.close(client)
    Darwin.close(peer)
    Darwin.close(listener)
  }
  func transfer(_ count: Int) throws {
    var bytes = [UInt8](repeating: 7, count: count)
    #expect(Darwin.send(client, &bytes, count, 0) == count)
    #expect(Darwin.recv(peer, &bytes, count, MSG_WAITALL) == count)
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TINYSTATS_VALIDATE_TRAFFIC"] == "1"))
func liveKernelTrafficAccountsOnlyOwnedLoopbackPayloadAndFinalCounters() throws {
  let pair = try LocalTrafficPair()
  try pair.transfer(4096)  // Pre-existing cumulative counters must be excluded from rates.
  let reader = NetworkTrafficReader(processID: getpid())
  defer { reader.stop() }
  func wait(_ predicate: (ProcessTrafficSnapshot) -> Bool) throws -> ProcessTrafficSnapshot {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var latest = ProcessTrafficSnapshot()
    while ProcessInfo.processInfo.systemUptime < deadline {
      latest = reader.read(at: ProcessInfo.processInfo.systemUptime)
      if predicate(latest) { return latest }
      if latest.availability == .unavailable {
        Issue.record("Native stream unavailable: \(latest.message)")
        return latest
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    Issue.record(
      "Timed out waiting for owned local traffic: \(latest.availability) · \(latest.message)")
    return latest
  }
  _ = try wait { $0.availability == .ready }
  try pair.transfer(2048)
  let active = try wait { $0.availability == .ready && $0.processes.contains { $0.upload > 0 } }
  let own = try #require(active.processes.first { $0.pid == getpid() })
  let interval = try #require(active.intervalSeconds)
  #expect(abs(own.download * interval - 2048) < 0.01)
  #expect(abs(own.upload * interval - 2048) < 0.01)
  #expect(own.uniqueID > 0)
  // Entire lifetime occurs between query requests; final updates must retain these bytes.
  do {
    let short = try LocalTrafficPair()
    try short.transfer(1024)
  }
  let closed = try wait {
    $0.sampledAt != active.sampledAt && $0.availability == .ready
      && $0.processes.contains { $0.upload > 0 }
  }
  let final = try #require(closed.processes.first { $0.pid == getpid() })
  let finalInterval = try #require(closed.intervalSeconds)
  #expect(abs(final.download * finalInterval - 1024) < 0.01)
  #expect(abs(final.upload * finalInterval - 1024) < 0.01)
  try localUDPTransfer(256)
  let datagram = try wait {
    $0.sampledAt != closed.sampledAt && $0.availability == .ready
      && $0.processes.contains { $0.upload > 0 }
  }
  let udp = try #require(datagram.processes.first { $0.pid == getpid() })
  let udpInterval = try #require(datagram.intervalSeconds)
  #expect(abs(udp.download * udpInterval - 256) < 0.01)
  #expect(abs(udp.upload * udpInterval - 256) < 0.01)
}

@Test func trafficInventoryTracksAdditionsUntilTerminalSuccess() throws {
  var ledger = TrafficLedger()
  try baseline(&ledger)
  ledger.begin()
  try ledger.add(source: 2, provider: 2)
  try ledger.update(flow(observed: 120, rx: 1_000_010, tx: 2_000_020), closing: false)
  ledger.sealInventory()
  // A source after the terminal boundary belongs to the next query's inventory.
  try ledger.add(source: 3, provider: 2)
  let missing = ledger.finish(at: 3, continuous: 120, completedAt: 3)
  #expect(missing.availability == .incomplete)
  #expect(missing.message.hasPrefix("Missing 1 socket updates"))
  #expect(missing.processes.isEmpty)
}

@Test func trafficOwnerCapacityAndOverflowCannotEmitPartialOrWrappedRates() throws {
  var bounded = TrafficLedger(sourceLimit: 8, ownerLimit: 1)
  try baseline(&bounded)
  bounded.begin()
  try bounded.update(flow(observed: 120, rx: 1_000_001, tx: 2_000_000), closing: false)
  try bounded.add(source: 2, provider: 2)
  #expect(throws: TrafficAccountingError.self) {
    try bounded.update(
      flow(2, pid: 43, unique: 101, start: 101, observed: 120, rx: 100), closing: false)
  }
  let unavailable = bounded.finish(at: 3, continuous: 120, completedAt: 3)
  #expect(unavailable.availability == .incomplete && unavailable.processes.isEmpty)

  var ledger = TrafficLedger()
  try baseline(&ledger)
  for source in UInt64(2)...3 {
    try ledger.add(source: source, provider: 2)
    try ledger.update(
      flow(
        source, start: 101, observed: 120,
        rx: source == 2 ? UInt64.max : 1), closing: true)
    ledger.remove(source: source, flags: 0)
  }
  ledger.begin()
  try ledger.update(flow(observed: 120, rx: 1_000_000, tx: 2_000_000), closing: false)
  let overflow = ledger.finish(at: 3, continuous: 120, completedAt: 3)
  #expect(overflow.availability == .incomplete && overflow.processes.isEmpty)
}

private func localUDPTransfer(_ count: Int) throws {
  let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
  try #require(descriptor >= 0)
  defer { Darwin.close(descriptor) }
  var timeout = timeval(tv_sec: 1, tv_usec: 0)
  try #require(
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      == 0)
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  try #require(bound == 0)
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let named = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.getsockname(descriptor, $0, &length)
    }
  }
  try #require(named == 0)
  var bytes = [UInt8](repeating: 7, count: count)
  let sent = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.sendto(descriptor, &bytes, count, 0, $0, length)
    }
  }
  try #require(sent == count)
  #expect(Darwin.recv(descriptor, &bytes, count, 0) == count)
}

@Test func missingTrafficReplyReopensInventoryInsteadOfRetainingVanishedIDs() {
  let transport = TrafficTransportFixture()
  let reader = transport.makeReader()
  _ = reader.read(at: 1)
  transport.packets = [
    frame(0, count: 16, context: 1), added(1), frame(0, count: 16, context: 2),
    frame(0, count: 16, context: 4), update(), frame(0, count: 16, context: 16),
  ]
  #expect(reader.read(at: 1).availability == .warming)
  transport.now = 3
  _ = reader.read(at: 3)
  transport.packets = [frame(0, count: 16, context: 17)]
  #expect(reader.read(at: 3).availability == .incomplete)
  #expect(transport.closes == 1)
  transport.now = 4
  _ = reader.read(at: 4)
  #expect(transport.opens == 1)
  transport.now = 9
  #expect(reader.read(at: 9).availability == .starting)
  #expect(transport.opens == 2 && transport.queries.last == 1)
  reader.stop()
}

private func modernUpdate(
  _ source: UInt64 = 1, pid: UInt32 = 42, unique: UInt64 = 9001, uid: UInt32 = 501,
  start: UInt64 = 10, observed: UInt64 = 100, rx: UInt64 = 0, tx: UInt64 = 0
) -> Data {
  var bytes = frame(10006, count: 352)
  put(source, at: 16, into: &bytes)
  put(UInt32(9), at: 144, into: &bytes)
  put(rx, at: 40, into: &bytes)
  put(tx, at: 56, into: &bytes)
  put(start, at: 152, into: &bytes)
  put(observed, at: 160, into: &bytes)
  put(unique, at: 168, into: &bytes)
  put(pid, at: 184, into: &bytes)
  put(uid, at: 344, into: &bytes)
  bytes.replaceSubrange(196..<202, with: Data("Modern".utf8))
  return bytes
}

@Test func modernTrafficLayoutRequiresExplicitScopeAndUsesItsDistinctIdentityOffsets() throws {
  let bytes = modernUpdate(rx: 1024, tx: 2048)
  #expect(throws: TrafficProtocolError.self) { try TrafficProtocol.decode(bytes) }
  let messages = try TrafficProtocol.decode(
    added(1, provider: 9) + bytes, scope: .modernConnections)
  guard case .update(let value, _) = messages.last else {
    Issue.record("No modern update")
    return
  }
  #expect(value.provider == 9 && value.owner.pid == 42 && value.owner.uniqueID == 9001)
  #expect(value.owner.userID == 501 && value.started == 10 && value.observed == 100)
  #expect(value.name == "Modern" && value.received == 1024 && value.sent == 2048)
  #expect(throws: TrafficProtocolError.self) {
    try TrafficProtocol.decode(added(1), scope: .modernConnections)
  }
  #expect(throws: TrafficProtocolError.self) {
    try TrafficProtocol.decode(added(1, provider: 10), scope: .modernConnections)
  }
  var unknown = bytes
  put(UInt16(351), at: 12, into: &unknown)
  #expect(throws: TrafficProtocolError.self) {
    try TrafficProtocol.decode(unknown, scope: .modernConnections)
  }
}

@Test func modernTrafficSessionSelectsOnlyLogicalConnectionsAndDoesNotFallBackOnPrivilegeFailure() {
  let transport = TrafficTransportFixture()
  let reader = transport.makeReader(scope: .modernConnections, userID: 501)
  _ = reader.read(at: 1)
  transport.packets = [
    frame(0, count: 16, context: 1), added(1, provider: 9), frame(0, count: 16, context: 9),
  ]
  _ = reader.read(at: 1)
  #expect(transport.subscriptions == [9] && transport.queries == [1, 16])
  transport.packets = [modernUpdate(), frame(0, count: 16, context: 16)]
  #expect(reader.read(at: 1).availability == .warming)
  transport.now = 3
  _ = reader.read(at: 3)
  transport.packets = [
    modernUpdate(observed: 300, rx: 200, tx: 400), frame(0, count: 16, context: 17),
  ]
  let result = reader.read(at: 3)
  #expect(result.availability == .ready && result.processes.first?.download == 100)
  #expect(result.processes.first?.upload == 200 && result.message.contains("modern"))
  reader.stop()
  let denied = TrafficTransportFixture()
  let restricted = denied.makeReader(scope: .modernConnections, userID: 501)
  _ = restricted.read(at: 1)
  denied.packets = [frame(0, count: 16, context: 1)]
  _ = restricted.read(at: 1)
  var error = frame(1, count: 24, context: 9)
  put(UInt32(EPERM), at: 16, into: &error)
  denied.packets = [error]
  #expect(restricted.read(at: 1).availability == .unavailable)
  _ = restricted.read(at: 30)
  #expect(denied.subscriptions == [9] && denied.opens == 1 && denied.closes == 1)
}

@Test func modernUserFilteringHappensBeforeTheTopEightAndRejectsChangedUserIdentity() throws {
  var ledger = TrafficLedger(outputUserID: 501)
  func owned(_ id: UInt64, observed: UInt64, rx: UInt64) -> TrafficFlow {
    .init(
      source: id, provider: 9,
      owner: .init(pid: Int32(id), uniqueID: id + 100, userID: id == 12 ? 501 : 502),
      name: "Modern",
      started: 1, observed: observed, received: rx, sent: 0)
  }
  for id in UInt64(1)...12 { try ledger.add(source: id, provider: 9) }
  ledger.begin()
  for id in UInt64(1)...12 { try ledger.update(owned(id, observed: 100, rx: 1000), closing: false) }
  #expect(ledger.finish(at: 1, continuous: 100, completedAt: 1).availability == .warming)
  ledger.begin()
  for id in UInt64(1)...12 {
    try ledger.update(owned(id, observed: 300, rx: id == 12 ? 1020 : 1_000_000), closing: false)
  }
  let result = ledger.finish(at: 3, continuous: 300, completedAt: 3)
  #expect(result.processes.count == 1 && result.processes.first?.pid == 12)
  #expect(result.processes.first?.download == 10)
  ledger.begin()
  for id in UInt64(1)...12 {
    var value = owned(id, observed: 500, rx: 2_000_000)
    if id == 12 { value.owner.userID = 502 }
    try ledger.update(value, closing: false)
  }
  let changed = ledger.finish(at: 5, continuous: 500, completedAt: 5)
  #expect(changed.availability == .incomplete && changed.processes.isEmpty)
}

@Test func nativeTrafficBoundaryKeepsKernelAndModernSubscriptionScopesSeparate() throws {
  var descriptors = [Int32](repeating: -1, count: 2)
  let created = socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors)
  try #require(created == 0)
  defer {
    Darwin.close(descriptors[0])
    Darwin.close(descriptors[1])
  }
  func receive() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 56)
    let count = Darwin.recv(descriptors[1], &bytes, bytes.count, MSG_DONTWAIT)
    try #require(count == 56)
    return Data(bytes)
  }
  let kernel = TrafficSocket.native(scope: .kernelSockets)
  for provider: UInt32 in [2, 4] {
    #expect(kernel.subscribe(descriptors[0], provider, UInt64(provider)))
    let bytes = try receive()
    let sentProvider = bytes.withUnsafeBytes {
      UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self))
    }
    #expect(sentProvider == provider)
  }
  for provider: UInt32 in [0, 3, 5, 8, 9, 10, UInt32.max] {
    #expect(!kernel.subscribe(descriptors[0], provider, 99))
    #expect(errno == EINVAL)
  }
  let modern = TrafficSocket.native(scope: .modernConnections)
  #expect(modern.subscribe(descriptors[0], 9, 0x1234))
  let bytes = try receive()
  bytes.withUnsafeBytes {
    #expect(UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) == 0x1234)
    #expect(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == 1002)
    #expect(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self)) == 9)
  }
  for provider: UInt32 in [2, 4, 10] { #expect(!modern.subscribe(descriptors[0], provider, 1)) }
  var unexpected: UInt8 = 0
  #expect(Darwin.recv(descriptors[1], &unexpected, 1, MSG_DONTWAIT) == -1)
  #expect(errno == EAGAIN || errno == EWOULDBLOCK)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TINYSTATS_VALIDATE_MODERN_TRAFFIC"] == "1"))
func liveModernSubscriptionReachesTheKernelAndReportsTheUnprivilegedDenial() {
  guard geteuid() != 0 else {
    Issue.record("This fixture requires an unprivileged caller.")
    return
  }
  let reader = NetworkTrafficReader(scope: .modernConnections, userID: geteuid())
  defer { reader.stop() }
  let deadline = ProcessInfo.processInfo.systemUptime + 5
  var latest = ProcessTrafficSnapshot()
  repeat {
    latest = reader.read(at: ProcessInfo.processInfo.systemUptime)
    if latest.availability == .unavailable { break }
    Thread.sleep(forTimeInterval: 0.01)
  } while ProcessInfo.processInfo.systemUptime < deadline
  #expect(latest.availability == .unavailable)
  #expect(latest.message.contains("(1)"))  // Kernel EPERM, not a local subscription guard failure.
  #expect(latest.processes.isEmpty)
}

@Test func trafficErrorsConsumeOpaqueRequestEchoesWithoutDecodingThemAsCounterFrames() throws {
  for length in [24, 48, 80] {
    var error = frame(1, count: length, context: 9)
    put(UInt32(EPERM), at: 16, into: &error)
    if length > 24 {
      error.replaceSubrange(24..<length, with: Data(repeating: 0xff, count: length - 24))
    }
    let result = try TrafficProtocol.decode(
      error + frame(0, count: 16, context: 23), scope: .modernConnections)
    #expect(result.count == 2)
    guard case .failure(let context, let code) = result[0],
      case .success(let following, _) = result[1]
    else {
      Issue.record("Error echo was not treated as opaque")
      return
    }
    #expect(context == 9 && code == UInt32(EPERM) && following == 23)
  }
  #expect(throws: TrafficProtocolError.self) { try TrafficProtocol.decode(frame(1, count: 20)) }
}

@Test func trafficExpandedProjectionKeepsAllOwnersBeforeGroupingAndDefaultOutputStaysEight() throws
{
  func ready(_ maximum: Int) throws -> ProcessTrafficSnapshot {
    var ledger = TrafficLedger()
    for i in 1...12 { try ledger.add(source: UInt64(i), provider: 2) }
    for step in 1...2 {
      ledger.begin()
      for i in 1...12 {
        try ledger.update(
          flow(
            UInt64(i), pid: Int32(i), unique: UInt64(i), observed: UInt64(step * 100),
            rx: UInt64(step * i)), closing: false)
      }
      let result = ledger.finish(
        at: Double(step), continuous: UInt64(step * 100), completedAt: Double(step),
        maximumProcesses: maximum)
      if step == 2 { return result }
    }
    return .init()
  }
  #expect(try ready(8).processes.count == 8)
  #expect(try ready(1024).processes.count == 12)
  #expect(try ready(Int.max).processes.count == 12)
  #expect(try ready(0).processes.count == 1)
  var overCapacity = TrafficLedger(ownerLimit: 1)
  try overCapacity.add(source: 1, provider: 2)
  try overCapacity.add(source: 2, provider: 2)
  overCapacity.begin()
  try overCapacity.update(flow(1, pid: 1, unique: 1), closing: false)
  #expect(throws: TrafficAccountingError.self) {
    try overCapacity.update(flow(2, pid: 2, unique: 2), closing: false)
  }
  #expect(overCapacity.finish(at: 1, continuous: 100, completedAt: 1).availability == .incomplete)
}
@Test func changingTrafficProjectionClosesStreamDropsCachedRowsAndRestartsBaselines() {
  let transport = TrafficTransportFixture()
  let reader = transport.makeReader()
  _ = reader.read(at: 1)
  reader.setExpandedOutput(true)
  #expect(transport.closes == 1 && reader.latest.availability == .inactive)
  _ = reader.read(at: 1)
  #expect(transport.opens == 2 && reader.latest.availability == .starting)
  reader.setExpandedOutput(true)
  #expect(transport.closes == 1)
  reader.setExpandedOutput(false)
  #expect(transport.closes == 2 && reader.latest.processes.isEmpty)
  _ = reader.read(at: 1)
  #expect(transport.opens == 3 && reader.latest.availability == .starting)
}

@Test func defaultTrafficOwnerBoundRejects1025BeforeExpandedProjectionCanUnderCount() throws {
  var ledger = TrafficLedger()
  for i in 1...1025 { try ledger.add(source: UInt64(i), provider: 2) }
  ledger.begin()
  for i in 1...1024 {
    try ledger.update(flow(UInt64(i), pid: Int32(i), unique: UInt64(i), rx: 1), closing: false)
  }
  #expect(throws: TrafficAccountingError.self) {
    try ledger.update(flow(1025, pid: 1025, unique: 1025, rx: 1), closing: false)
  }
  let rejected = ledger.finish(at: 1, continuous: 100, completedAt: 1, maximumProcesses: 1024)
  #expect(rejected.availability == .incomplete && rejected.processes.isEmpty)
}
