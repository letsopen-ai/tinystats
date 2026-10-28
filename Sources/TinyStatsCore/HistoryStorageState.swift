import Darwin
import Foundation

public enum HistoryStorageIssue: Error, Equatable, Sendable {
  case unavailable, unreadable, unsupportedSchema, inUse, unsafeFile, unsafeLock
  case io(Int32)
  public var message: String {
    switch self {
    case .unavailable: "History storage is unavailable in this profile"
    case .unreadable: "Unreadable checkpoint; Clear history to resume saving"
    case .unsupportedSchema: "Unsupported checkpoint format; Clear history to replace it"
    case .inUse: "History is in use by another TinyStats instance"
    case .unsafeLock:
      "History lock is missing or unsafe; repair the private history folder while TinyStats is closed"
    case .unsafeFile: "History path or file permissions are unsafe"
    case .io(let code):
      switch code {
      case ENOSPC: "Not enough disk space to save history"
      case EACCES, EPERM: "Permission denied for local history"
      case EROFS: "History folder is read-only"
      case ENOENT: "History folder is unavailable"
      default: "File operation failed (code \(code))"
      }
    }
  }
  public static func from(_ error: any Error) -> Self {
    switch error {
    case let issue as HistoryStorageIssue: issue
    case HistoryCheckpointError.unsupportedVersion: .unsupportedSchema
    case is HistoryCheckpointError: .unreadable
    case HistoryFileError.inUse: .inUse
    case HistoryFileError.unsafeFile: .unsafeFile
    case HistoryFileError.unsafeLock: .unsafeLock
    case HistoryFileError.invalidSize: .unreadable
    case HistoryFileError.system(let code):
      code == ELOOP || code == ENOTDIR ? .unsafeFile : .io(code)
    default: .unreadable
    }
  }
}
public struct HistoryStorageState: Equatable, Sendable {
  public var enabled = false
  public var restored = false
  public var excludedFromBackup: Bool?
  public var savedAt: Date?
  public var issue: HistoryStorageIssue?
  public var removalFailed = false
  public init() {}
}
