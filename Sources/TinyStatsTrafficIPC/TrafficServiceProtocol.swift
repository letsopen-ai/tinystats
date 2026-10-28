import Foundation
import TinyStatsTraffic

@objc(TinyStatsTrafficServiceProtocol)
public protocol TrafficServiceProtocol {
  func snapshot(_ version: Int, withReply reply: @escaping @Sendable (Data) -> Void)
  func stop(withReply reply: @escaping @Sendable () -> Void)
}

/// A closed, bounded data contract. No file names, commands, providers, PIDs or user IDs
/// can be requested by a client. The server selects the authenticated connection's EUID.
public struct TrafficServiceReply: Codable, Sendable {
  public enum State: String, Codable, Sendable {
    case starting, warming, ready, incomplete, unavailable, busy, unsupported
  }
  public struct Row: Codable, Sendable {
    public var pid: Int32, uniqueID: UInt64, name: String, download: Double, upload: Double
    public init(pid: Int32, uniqueID: UInt64, name: String, download: Double, upload: Double) {
      self.pid = pid
      self.uniqueID = uniqueID
      self.name = name
      self.download = download
      self.upload = upload
    }
  }
  public static let version = 1, byteLimit = 16384
  public var version = Self.version
  public var scope = "modern-connections-current-user"
  public var state: State
  public var message: String
  public var sampledAt: Double?, intervalSeconds: Double?
  public var activeSources = 0
  public var rows: [Row] = []
  public init(state: State, message: String) {
    self.state = state
    self.message = message
  }
  public init(_ snapshot: ProcessTrafficSnapshot) {
    state = State(rawValue: snapshot.availability.rawValue) ?? .unavailable
    message = snapshot.message
    sampledAt = snapshot.sampledAt
    intervalSeconds = snapshot.intervalSeconds
    activeSources = snapshot.activeSources
    rows = snapshot.processes.map {
      .init(
        pid: $0.pid, uniqueID: $0.uniqueID, name: $0.name, download: $0.download, upload: $0.upload)
    }
  }
  private var valid: Bool {
    guard version == Self.version, scope == "modern-connections-current-user",
      message.utf8.count <= 256,
      !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      (0...8192).contains(activeSources), rows.count <= 8,
      sampledAt.map({ $0.isFinite && $0 >= 0 && $0 <= 1e12 }) ?? true,
      intervalSeconds.map({ $0.isFinite && $0 > 0 && $0 <= 120 }) ?? true
    else { return false }
    if state == .ready {
      guard sampledAt != nil, intervalSeconds != nil else { return false }
    } else if !rows.isEmpty {
      return false
    }
    let identities = Set(rows.map { "\($0.pid):\($0.uniqueID)" })
    guard identities.count == rows.count else { return false }
    return rows.allSatisfy {
      $0.pid >= 0 && ($0.pid == 0 ? $0.uniqueID == 0 : $0.uniqueID > 0)
        && !$0.name.isEmpty && $0.name.utf8.count <= 256
        && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        && $0.download.isFinite && $0.download >= 0 && $0.download <= 1e15
        && $0.upload.isFinite && $0.upload >= 0 && $0.upload <= 1e15
    }
  }
  public func encoded() -> Data? {
    guard valid, let data = try? JSONEncoder().encode(self), data.count <= Self.byteLimit else {
      return nil
    }
    return data
  }
  public static func decode(_ data: Data) -> Self? {
    guard data.count <= byteLimit, let value = try? JSONDecoder().decode(Self.self, from: data),
      value.valid
    else { return nil }
    return value
  }
}
