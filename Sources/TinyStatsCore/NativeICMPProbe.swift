import Darwin
import Dispatch
import Foundation

/// A nonblocking socket exists only while an explicitly enabled echo is pending.
/// Read events add no polling timer. Replies older than five seconds are rejected; a silent
/// socket is canceled at the next shared sample (up to the configured ten-second cadence).
final class NativeICMPProbe: ICMPProbeTransport, @unchecked Sendable {
  private let queue: DispatchQueue
  private let sendPacket: @Sendable (Int32, [UInt8]) -> Int
  // Admission and enqueue order cross queues; socket/source ownership stays on queue.
  // The final nonblocking send is atomic with cancellation, so cancel's return also
  // excludes sends from work that was queued but had not yet reached that boundary.
  private let admissionLock = NSLock()
  private var epoch: UInt64 = 0
  private struct Pending {
    let descriptor: Int32
    let source: any DispatchSourceRead
    let endpoint: ICMPEndpoint
    let identifier: UInt16
    let sequence: UInt16
    let token: [UInt8]
    let started: Double
    let completion: @Sendable (ICMPProbeReply) -> Void
    var received = 0
  }
  private var pending: Pending?
  private var sequence: UInt16 = 0
  init(
    queue: DispatchQueue = DispatchQueue(label: "app.tinystats.icmp", qos: .utility),
    sendPacket: @escaping @Sendable (Int32, [UInt8]) -> Int = { descriptor, packet in
      packet.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    }
  ) {
    self.queue = queue
    self.sendPacket = sendPacket
  }
  func start(_ endpoint: ICMPEndpoint, completion: @escaping @Sendable (ICMPProbeReply) -> Void) {
    admissionLock.lock()
    let token = epoch
    queue.async { [weak self] in self?.begin(endpoint, epoch: token, completion: completion) }
    admissionLock.unlock()
  }
  func cancel() {
    admissionLock.lock()
    epoch &+= 1
    queue.async { [weak self] in self?.stop() }
    admissionLock.unlock()
  }
  deinit {
    // Event handlers never own the probe. Cancel owns descriptor cleanup independently.
    pending?.source.cancel()
  }
  private func stop() {
    pending?.source.cancel()
    pending = nil
  }
  private func complete(_ reply: ICMPProbeReply) {
    let callback = pending?.completion
    stop()
    callback?(reply)
  }
  private static func failure(_ fallback: String) -> ICMPProbeReply {
    .init(
      reason: errno == EACCES || errno == EPERM
        ? "Network access restricted · check Local Network permission or firewall" : fallback)
  }
  private func begin(
    _ endpoint: ICMPEndpoint, epoch admissionEpoch: UInt64,
    completion: @escaping @Sendable (ICMPProbeReply) -> Void
  ) {
    admissionLock.lock()
    let admitted = epoch == admissionEpoch
    admissionLock.unlock()
    guard admitted else { return }
    stop()
    guard let endpoint = endpoint.resolvingScope() else {
      completion(.init(reason: "IPv6 interface unavailable"))
      return
    }
    let descriptor = socket(
      endpoint.family, SOCK_DGRAM, endpoint.family == AF_INET ? IPPROTO_ICMP : IPPROTO_ICMPV6)
    guard descriptor >= 0 else {
      completion(Self.failure("ICMP socket unavailable"))
      return
    }
    var receiveBytes: Int32 = 4096
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
      setsockopt(
        descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBytes,
        socklen_t(MemoryLayout.size(ofValue: receiveBytes))) == 0
    else {
      let failure = Self.failure("ICMP socket unavailable")
      close(descriptor)
      completion(failure)
      return
    }
    let connected: Int32
    if endpoint.family == AF_INET {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: endpoint.bytes) }
      connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    } else {
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_scope_id = endpoint.scope
      withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: endpoint.bytes) }
      connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
    }
    guard connected == 0 else {
      let failure = Self.failure("ICMP destination unavailable")
      close(descriptor)
      completion(failure)
      return
    }
    let identifier = UInt16.random(in: .min ... .max)
    sequence &+= 1
    let token = (0..<ICMPEcho.payloadBytes).map { _ in UInt8.random(in: .min ... .max) }
    let packet = ICMPEcho.request(
      family: endpoint.family, identifier: identifier, sequence: sequence, token: token)
    let started = ProcessInfo.processInfo.systemUptime
    admissionLock.lock()
    guard epoch == admissionEpoch else {
      admissionLock.unlock()
      close(descriptor)
      return
    }
    let sent = sendPacket(descriptor, packet)
    let sendFailure = sent == packet.count ? nil : Self.failure("ICMP echo could not be sent")
    admissionLock.unlock()
    guard sent == packet.count else {
      close(descriptor)
      if let sendFailure { completion(sendFailure) }
      return
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setCancelHandler { close(descriptor) }
    source.setEventHandler { [weak self] in self?.receive() }
    pending = .init(
      descriptor: descriptor, source: source, endpoint: endpoint,
      identifier: identifier, sequence: sequence, token: token, started: started,
      completion: completion)
    source.resume()
  }
  private func receive() {
    guard var request = pending else { return }
    var buffer = [UInt8](repeating: 0, count: 1024)
    for _ in 0..<16 {
      var address = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let count = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(request.descriptor, &buffer, buffer.count, MSG_DONTWAIT, $0, &length)
        }
      }
      if count < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        if errno == EINTR { continue }
        complete(.init(reason: "ICMP reply unavailable"))
        return
      }
      request.received += 1
      pending?.received = request.received
      if count <= buffer.count,
        Self.matchesSource(address, length: length, endpoint: request.endpoint),
        ICMPEcho.matches(
          Array(buffer.prefix(count)), family: request.endpoint.family,
          identifier: request.identifier, sequence: request.sequence, token: request.token)
      {
        let elapsed = ProcessInfo.processInfo.systemUptime - request.started
        complete(
          .init(
            milliseconds: elapsed >= 0 && elapsed <= 5 ? elapsed * 1000 : nil,
            reason: elapsed >= 0 && elapsed <= 5 ? "Echo reply" : "No echo reply within 5 seconds"))
        return
      }
      if request.received >= 64 {
        complete(.init(reason: "ICMP receive limit reached"))
        return
      }
    }
  }
  static func matchesSource(_ address: sockaddr_storage, length: socklen_t, endpoint: ICMPEndpoint)
    -> Bool
  {
    guard Int32(address.ss_family) == endpoint.family else { return false }
    var copy = address
    return withUnsafePointer(to: &copy) { pointer in
      if endpoint.family == AF_INET {
        guard length >= MemoryLayout<sockaddr_in>.size else { return false }
        return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          var value = $0.pointee.sin_addr
          return withUnsafeBytes(of: &value) { Array($0) == endpoint.bytes }
        }
      }
      guard length >= MemoryLayout<sockaddr_in6>.size else { return false }
      return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        guard endpoint.scope == 0 || $0.pointee.sin6_scope_id == endpoint.scope else {
          return false
        }
        var value = $0.pointee.sin6_addr
        return withUnsafeBytes(of: &value) { Array($0) == endpoint.bytes }
      }
    }
  }
}
