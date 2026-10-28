import Foundation

/// Intended for the separately authorized traffic service. The supplied serial queue owns
/// every call and callback. Unprivileged subscriptions fail closed; this never elevates access.
/// Modern connection bytes are separate from kernel socket and subflow bytes, not additive.
public final class ModernConnectionTrafficSession {
  private let reader: NetworkTrafficReader
  public init(queue: DispatchQueue, userID: UInt32) {
    reader = NetworkTrafficReader(queue: queue, scope: .modernConnections, userID: userID)
  }
  public func sample() -> ProcessTrafficSnapshot {
    reader.read(at: ProcessInfo.processInfo.systemUptime)
  }
  public func stop() { reader.stop() }
}
