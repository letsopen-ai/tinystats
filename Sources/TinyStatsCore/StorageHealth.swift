import CTinyStats
import Foundation

public struct StorageHealthReading: Sendable {
  public enum Transport: UInt8, Sendable {
    case unsupported = 0
    case nvme = 1
    case ata = 2
  }
  public var id: UInt64
  public var name: String, bsdName: String, stableID: String
  public var transport: Transport
  public var capable: Bool, available: Bool, warning: Bool
  public var temperature: Double?
  public var criticalWarning: UInt8, enduranceUsed: UInt8, spare: UInt8?, spareThreshold: UInt8?
  public var totalRead: UInt64?, totalWritten: UInt64?
  public var powerCycles: UInt64, powerOnHours: UInt64
  public var unsafeShutdowns: UInt64, mediaErrors: UInt64, errorEntries: UInt64
  public var overflowMask: UInt32, error: Int32
  public var status: String {
    if !capable { return "SMART not exposed by this connection" }
    if !available {
      return error == 0
        ? "Read unavailable"
        : String(format: "Read unavailable (0x%08X)", UInt32(bitPattern: error))
    }
    if warning {
      return transport == .nvme
        ? String(format: "Critical warning flags 0x%02X", criticalWarning)
        : "SMART threshold exceeded"
    }
    return transport == .nvme ? "No critical warnings" : "No SMART threshold exceeded"
  }
  public func counter(_ value: UInt64?, bit: UInt32, bytes: Bool = false) -> String {
    guard let value else { return "Unavailable" }
    let prefix = overflowMask & (1 << bit) == 0 ? "" : "≥ "
    return prefix + (bytes ? Display.bytes(value) : String(value))
  }
  init(raw: ts_storage_health) {
    id = raw.id
    name = cString(raw.name)
    bsdName = cString(raw.bsd_name)
    stableID = cString(raw.stable_id)
    transport = Transport(rawValue: raw.protocol) ?? .unsupported
    capable = raw.capable
    available = raw.available
    warning = raw.warning
    temperature = raw.temperature_valid ? raw.temperature_celsius : nil
    criticalWarning = raw.critical_warning
    enduranceUsed = raw.endurance_used
    spare = raw.spare_valid ? raw.available_spare : nil
    spareThreshold = raw.spare_valid ? raw.spare_threshold : nil
    // NVMe specifies zero Data Units Read/Written as not reported.
    totalRead = raw.total_read > 0 ? raw.total_read : nil
    totalWritten = raw.total_written > 0 ? raw.total_written : nil
    powerCycles = raw.power_cycles
    powerOnHours = raw.power_on_hours
    unsafeShutdowns = raw.unsafe_shutdowns
    mediaErrors = raw.media_errors
    errorEntries = raw.error_entries
    overflowMask = raw.overflow_mask
    error = raw.error
  }
}

public struct StorageHealthCache: Sendable {
  public static let maximumAlertAge: TimeInterval = 330
  public var drives: [StorageHealthReading] = []
  public var checkedAt: Date?
  public var refreshing = false
  public init() {}
  public func isFresh(at date: Date) -> Bool {
    guard let checkedAt else { return false }
    let age = date.timeIntervalSince(checkedAt)
    return age >= 0 && age <= Self.maximumAlertAge
  }
}

/// One bounded slow-I/O request at a time. A stalled drive cannot block fast metrics.
final class StorageHealthReader: @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.tinystats.storage-health", qos: .utility)
  private let lock = NSLock()
  private let interval: Double
  private let read: @Sendable () -> [StorageHealthReading]
  private var state = StorageHealthCache()
  private var requestedAt = -Double.infinity
  init(
    interval: Double = 300,
    read: @escaping @Sendable () -> [StorageHealthReading] = StorageHealthReader.readHardware
  ) {
    precondition(interval > 0)
    self.interval = interval
    self.read = read
  }
  func requestIfDue(at time: Double) {
    lock.lock()
    guard time.isFinite, !state.refreshing, time - requestedAt >= interval else {
      lock.unlock()
      return
    }
    state.refreshing = true
    requestedAt = time
    lock.unlock()
    queue.async { [self] in
      let drives = autoreleasepool { Array(read().prefix(32)) }
      lock.lock()
      state.drives = drives
      state.checkedAt = Date()
      state.refreshing = false
      lock.unlock()
    }
  }
  func cached() -> StorageHealthCache {
    lock.lock()
    defer { lock.unlock() }
    return state
  }
  static func readHardware() -> [StorageHealthReading] {
    var rows = [ts_storage_health](repeating: ts_storage_health(), count: 32)
    let count = ts_read_storage_health(&rows, rows.count)
    return rows.prefix(count).map(StorageHealthReading.init(raw:))
  }
}
