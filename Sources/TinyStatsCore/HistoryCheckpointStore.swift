import Darwin
import Foundation

/// Sole ownership stays on MonitorWorker's queue. Tests inject a store, never the default user path.
public protocol HistoryCheckpointStore: AnyObject {
  var excludedFromBackup: Bool? { get }
  func read() throws -> Data?
  func readHistory(now: Date) throws -> SessionHistory?
  func write(_ data: Data) throws
  func write(_ history: SessionHistory) throws
  func remove() throws
}
extension HistoryCheckpointStore {
  public var excludedFromBackup: Bool? { nil }
  public func readHistory(now: Date) throws -> SessionHistory? {
    try read().map { try SessionHistory(checkpoint: $0, now: now) }
  }
  public func write(_ history: SessionHistory) throws { try write(history.checkpoint()) }
}
public enum HistoryFileError: Error, Equatable, Sendable {
  case unsafeFile, unsafeLock, inUse, invalidSize
  case system(Int32)
}

public enum HistoryStoreLocation {
  private static func lexicalPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { return nil }
    var components: [Substring] = []
    for component in path.split(separator: "/") {
      if component == "." { continue }
      if component == ".." {
        if !components.isEmpty { components.removeLast() }
      } else {
        components.append(component)
      }
    }
    return "/" + components.joined(separator: "/")
  }
  /// Pure lexical selection. Foundation standardization can rewrite /private/tmp to /tmp
  /// after a directory exists, introducing a symlink into an otherwise safe path.
  public static func directory(environment: [String: String], applicationSupport: URL?) -> URL? {
    let owner = applicationSupport.flatMap { lexicalPath($0.path + "/TinyStatsHistory") }
    guard environment["TINYSTATS_PREFERENCES_DOMAIN"] != nil else {
      return owner.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    guard let path = environment["TINYSTATS_HISTORY_DIRECTORY"], let isolated = lexicalPath(path),
      isolated != "/", isolated != owner
    else { return nil }
    return URL(fileURLWithPath: isolated, isDirectory: true)
  }
}

/// A private directory, a process-lifetime nonblocking lock, and at most two bounded data files.
/// Atomic replacement preserves the last checkpoint on a failed write; this is not a power-loss guarantee.
public final class LocalHistoryCheckpointStore: HistoryCheckpointStore {
  static let fileName = "history-v1.bin"
  static let temporaryName = ".history-checkpoint.tmp"
  static let lockName = ".history.lock"
  private var directory: Int32 = -1
  private var lock: Int32 = -1
  public private(set) var excludedFromBackup: Bool?
  public init?(directory url: URL, create: Bool, excludingDirectory excluded: URL? = nil) throws {
    let path = url.path
    guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else {
      throw HistoryFileError.unsafeFile
    }
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw HistoryFileError.unsafeFile
    }
    // Validate/pin the entire parent path before creating anything under it.
    let parent = open(
      url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard parent >= 0 else {
      if !create && errno == ENOENT { return nil }
      throw HistoryFileError.system(errno)
    }
    defer { close(parent) }
    if let excluded {
      var candidateParent = stat()
      var excludedParent = stat()
      if fstat(parent, &candidateParent) != 0 { throw HistoryFileError.system(errno) }
      if stat(excluded.deletingLastPathComponent().path, &excludedParent) == 0,
        candidateParent.st_dev == excludedParent.st_dev,
        candidateParent.st_ino == excludedParent.st_ino,
        name.lowercased() == excluded.lastPathComponent.lowercased()
      {
        throw HistoryFileError.unsafeFile
      }
    }
    if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
      throw HistoryFileError.system(errno)
    }
    directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if directory < 0 {
      if !create && errno == ENOENT { return nil }
      throw HistoryFileError.system(errno)
    }
    do {
      var info = stat()
      guard fstat(directory, &info) == 0 else { throw HistoryFileError.system(errno) }
      guard info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
        throw HistoryFileError.unsafeFile
      }
      if let excluded {
        var owner = stat()
        if stat(excluded.path, &owner) == 0,
          owner.st_dev == info.st_dev, owner.st_ino == info.st_ino
        {
          throw HistoryFileError.unsafeFile
        }
      }
      lock = openat(
        directory, Self.lockName,
        O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
      guard lock >= 0 else {
        if errno == ENOENT || errno == ELOOP { throw HistoryFileError.unsafeLock }
        throw HistoryFileError.system(errno)
      }
      do { try validate(lock, maximum: 0) } catch { throw HistoryFileError.unsafeLock }
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK { throw HistoryFileError.inUse }
        throw HistoryFileError.system(errno)
      }
      if create {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var destination = url
        try? destination.setResourceValues(values)
        excludedFromBackup =
          (try? destination.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
          .isExcludedFromBackup == true
      }
    } catch {
      if lock >= 0 {
        close(lock)
        lock = -1
      }
      close(directory)
      directory = -1
      throw error
    }
  }
  deinit {
    if lock >= 0 { close(lock) }
    if directory >= 0 { close(directory) }
  }
  @discardableResult private func validate(_ descriptor: Int32, maximum: Int) throws -> stat {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw HistoryFileError.system(errno) }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
      info.st_nlink == 1, info.st_mode & 0o777 == 0o600
    else { throw HistoryFileError.unsafeFile }
    guard info.st_size >= 0, info.st_size <= maximum else { throw HistoryFileError.invalidSize }
    return info
  }
  private func withCheckpointFile<T>(_ body: (Int32, Int) throws -> T) throws -> T? {
    let descriptor = openat(
      directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw HistoryFileError.system(errno)
    }
    defer { close(descriptor) }
    let info = try validate(descriptor, maximum: SessionHistory.maximumCheckpointBytes)
    guard info.st_size >= 76 else { throw HistoryFileError.invalidSize }
    return try body(descriptor, Int(info.st_size))
  }
  public func readHistory(now: Date) throws -> SessionHistory? {
    try withCheckpointFile { descriptor, count in
      try SessionHistory(checkpointByteCount: count, now: now) { bytes in
        var received: Int
        repeat {
          received = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        } while received < 0 && errno == EINTR
        guard received >= 0 else { throw HistoryFileError.invalidSize }
        return received
      }
    }
  }
  public func read() throws -> Data? {
    try withCheckpointFile { descriptor, count in
      var data = Data(count: count)
      try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.read(
            descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw HistoryFileError.invalidSize }
          offset += count
        }
      }
      var extra: UInt8 = 0
      var count: Int
      repeat { count = Darwin.read(descriptor, &extra, 1) } while count < 0 && errno == EINTR
      guard count == 0 else { throw HistoryFileError.invalidSize }
      return data
    }
  }
  private func removeOwned(_ name: String) throws {
    var info = stat()
    if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return }
      throw HistoryFileError.system(errno)
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
      info.st_nlink == 1, info.st_mode & 0o777 == 0o600
    else { throw HistoryFileError.unsafeFile }
    // Explicit Clear can unlink an oversized corrupt checkpoint without ever reading it.
    guard unlinkat(directory, name, 0) == 0 else { throw HistoryFileError.system(errno) }
  }
  public func write(_ data: Data) throws {
    guard (76...SessionHistory.maximumCheckpointBytes).contains(data.count) else {
      throw HistoryFileError.invalidSize
    }
    try writeCheckpoint { sink in try data.withUnsafeBytes(sink) }
  }
  public func write(_ history: SessionHistory) throws {
    try writeCheckpoint { sink in try history.writeCheckpoint(to: sink) }
  }

  /// The producer is synchronous, and only this owned temporary file is ever partially written.
  /// A producer or write failure leaves the previous checkpoint intact and removes the temporary.
  func writeCheckpoint(_ produce: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws {
    try removeOwned(Self.temporaryName)
    let descriptor = openat(
      directory, Self.temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw HistoryFileError.system(errno) }
    defer {
      close(descriptor)
      // Only the file we exclusively created; no dynamic path or directory traversal.
      _ = unlinkat(directory, Self.temporaryName, 0)
    }
    var total = 0
    try produce { bytes in
      guard bytes.count <= SessionHistory.maximumCheckpointBytes - total else {
        throw HistoryFileError.invalidSize
      }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw HistoryFileError.system(count < 0 ? errno : EIO) }
        offset += count
      }
      total += bytes.count
    }
    guard total >= 76 else { throw HistoryFileError.invalidSize }
    guard fsync(descriptor) == 0 else { throw HistoryFileError.system(errno) }
    // Never replace an unsafe existing entry, even though rename itself would not follow it.
    let existing = openat(directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if existing >= 0 {
      defer { close(existing) }
      try validate(existing, maximum: SessionHistory.maximumCheckpointBytes)
    } else if errno != ENOENT {
      throw HistoryFileError.system(errno)
    }
    guard renameat(directory, Self.temporaryName, directory, Self.fileName) == 0 else {
      throw HistoryFileError.system(errno)
    }
  }
  public func remove() throws {
    try removeOwned(Self.temporaryName)
    try removeOwned(Self.fileName)
  }
}
