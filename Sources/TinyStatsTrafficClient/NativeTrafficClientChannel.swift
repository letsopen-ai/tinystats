import Foundation
import TinyStatsTrafficIPC

enum TrafficClientFailure: Error, Sendable {
  case signature, connection, untrustedPeer, invalidReply, timeout
  var message: String {
    switch self {
    case .signature: "A validated hardened TinyStats signature is required."
    case .connection: "The traffic service connection failed."
    case .untrustedPeer: "The traffic service peer could not be trusted."
    case .invalidReply: "An invalid or stale traffic service reply was withheld."
    case .timeout: "The traffic service request timed out."
    }
  }
}
protocol TrafficClientChannel: AnyObject, Sendable {
  func request(_ completion: @escaping @Sendable (Result<Data, TrafficClientFailure>) -> Void)
  func stop()
  func invalidate()
}

/// Configuration/request methods run only on the client's utility queue. Immutable NSXPC
/// configuration is read by reply handlers; NSXPC invalidation may run on its callback queue.
final class NativeTrafficClientChannel: TrafficClientChannel, @unchecked Sendable {
  private let connection: NSXPCConnection
  static func make(
    authorized: @escaping @Sendable () -> Bool, onFailure: @escaping @Sendable () -> Void
  )
    -> Result<any TrafficClientChannel, TrafficClientFailure>
  {
    guard authorized() else { return .failure(.connection) }
    guard
      let team = TrafficServiceSigning.currentTeam(identifier: TrafficServiceSigning.appIdentifier),
      let requirement = TrafficServiceSigning.requirement(
        identifier: TrafficServiceSigning.serviceIdentifier, team: team)
    else { return .failure(.signature) }
    guard authorized() else { return .failure(.connection) }
    let connection = NSXPCConnection(
      machServiceName: TrafficServiceSigning.serviceIdentifier, options: .privileged)
    return .success(Self(connection: connection, requirement: requirement, onFailure: onFailure))
  }
  /// Internal endpoint injection supports owned native rejection fixtures. Production uses
  /// only the fixed privileged service and signature-derived requirement above. Root checks
  /// cannot be disabled by this constructor.
  init(connection: NSXPCConnection, requirement: String, onFailure: @escaping @Sendable () -> Void)
  {
    self.connection = connection
    let failed = TrafficClientCompletionGate()
    connection.remoteObjectInterface = NSXPCInterface(with: TrafficServiceProtocol.self)
    connection.setCodeSigningRequirement(requirement)
    connection.invalidationHandler = { if failed.take() { onFailure() } }
    connection.interruptionHandler = { [weak self] in self?.invalidate() }
    connection.resume()
  }
  func request(_ completion: @escaping @Sendable (Result<Data, TrafficClientFailure>) -> Void) {
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
        completion(.failure(.connection))
      }) as? TrafficServiceProtocol
    else {
      completion(.failure(.connection))
      return
    }
    proxy.snapshot(TrafficServiceReply.version) { [self] data in
      // Inspect kernel-supplied peer credentials after a reply establishes the connection.
      guard connection.processIdentifier > 0, connection.effectiveUserIdentifier == 0 else {
        completion(.failure(.untrustedPeer))
        connection.invalidate()
        return
      }
      guard data.count <= TrafficServiceReply.byteLimit else {
        completion(.failure(.invalidReply))
        connection.invalidate()
        return
      }
      completion(.success(data))
    }
  }
  func stop() {
    (connection.remoteObjectProxyWithErrorHandler { _ in } as? TrafficServiceProtocol)?.stop {}
  }
  func invalidate() { connection.invalidate() }
}

final class TrafficClientCompletionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var consumed = false
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !consumed else { return false }
    consumed = true
    return true
  }
  func cancel() { _ = take() }
}
