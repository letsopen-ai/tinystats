import Darwin
import Foundation

public protocol UpdateFileSystem: Sendable {
  func createPrivateDirectory(_ url: URL) throws
  func write(_ data: Data, to url: URL) throws
  func contents(_ url: URL) throws -> [URL]
  func isDirectory(_ url: URL) -> Bool
  func validateBundleTree(_ url: URL) throws
  func move(_ source: URL, to destination: URL) throws
  func remove(_ url: URL) throws
}

public struct NativeUpdateFileSystem: UpdateFileSystem {
  public init() {}
  public func createPrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
      throw UpdateError.invalid("The update staging path contains a symbolic link.")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
  public func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.withoutOverwriting])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public func contents(_ url: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
  }
  public func isDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
      == .typeDirectory
  }
  public func validateBundleTree(_ url: URL) throws {
    var enumerationFailure: (any Error)?
    guard isDirectory(url), url.lastPathComponent == "TinyStats.app",
      let entries = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isSymbolicLinkKey],
        errorHandler: { _, error in
          enumerationFailure = error
          return false
        })
    else { throw UpdateError.invalid("The archive does not contain a TinyStats app directory.") }
    var count = 0
    var bytes: UInt64 = 0
    for case let entry as URL in entries {
      count += 1
      let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
      guard let type = attributes[.type] as? FileAttributeType,
        [.typeDirectory, .typeRegular, .typeSymbolicLink].contains(type), count <= 20_000
      else { throw UpdateError.invalid("Unsupported update bundle layout.") }
      let resolved = entry.resolvingSymlinksInPath().standardizedFileURL.path
      guard resolved.hasPrefix(url.standardizedFileURL.path + "/") else {
        throw UpdateError.invalid("An update symbolic link escapes the app bundle.")
      }
      bytes += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
      guard bytes <= 512 * 1_048_576 else {
        throw UpdateError.invalid("The extracted update is too large.")
      }
    }
    if let enumerationFailure { throw enumerationFailure }
  }
  /// rename(2) never falls back to a cross-volume copy and never merges bundle contents.
  public func move(_ source: URL, to destination: URL) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw UpdateError.invalid("An update destination already exists.")
    }
    guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw UpdateError.invalid("Could not atomically move the app (errno \(errno)).")
    }
  }
  public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

public protocol UpdateProcessRunner: Sendable {
  func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws
}
public protocol UpdateCodeVerifier: Sendable {
  func verify(_ app: URL, manifest: UpdateManifest, runningTeam: String) throws
}
public protocol UpdateExitWaiter: Sendable {
  func waitForExit(pid: Int32, timeout: TimeInterval) throws
}

public protocol UpdateRunningApplicationChecking: Sendable {
  /// The installer helper itself must be excluded by the native implementation.
  func isRunning(from original: URL) throws -> Bool
}

public enum UpdateInstallQuiescence {
  /// One bounded retry lets an exiting instance finish without ever replacing a
  /// bundle used by a reopened app. Call after verification, just before renames.
  public static func requireIdle(
    original: URL, checker: any UpdateRunningApplicationChecking,
    retryDelay: () -> Void
  ) throws {
    if try !checker.isRunning(from: original) { return }
    retryDelay()
    guard try !checker.isRunning(from: original) else {
      throw UpdateError.invalid(
        "Another TinyStats instance is running from this app. Quit it and try again.")
    }
  }
}

public protocol UpdateInstallLocationChecking: Sendable {
  func canInstall(_ original: URL) -> Bool
}

public struct PreparedUpdate: Sendable {
  public let manifest: UpdateManifest
  public let directory: URL
  public var app: URL { directory.appendingPathComponent("Extracted/TinyStats.app") }
  public init(manifest: UpdateManifest, directory: URL) {
    self.manifest = manifest
    self.directory = directory
  }
}

public protocol UpdatePreparing: Sendable {
  var files: any UpdateFileSystem { get }
  func prepare(archive: Data, manifest: UpdateManifest, root: URL, team: String) throws
    -> PreparedUpdate
  func recoveryNeedsAttention(root: URL) throws -> Bool
}

extension UpdatePreparing {
  public func recoveryNeedsAttention(root: URL) throws -> Bool { false }
}

public protocol UpdateRecoveryChecking: Sendable {
  func canDiscard(backup: URL) throws -> Bool
}

public enum UpdateRecoveryVersion {
  public static func canDiscard(
    installedVersion: String, installedBuild: String,
    backupVersion: String, backupBuild: String, installedVerified: Bool
  ) throws -> Bool {
    guard installedVerified else { return false }
    return try UpdateVersion(installedVersion) >= UpdateVersion(backupVersion)
      && UpdatePolicy.build(installedBuild) >= UpdatePolicy.build(backupBuild)
  }
}

public struct UpdateStager: UpdatePreparing {
  public let files: any UpdateFileSystem
  public let processes: any UpdateProcessRunner
  public let verifier: any UpdateCodeVerifier
  public let recovery: (any UpdateRecoveryChecking)?
  public init(
    files: any UpdateFileSystem, processes: any UpdateProcessRunner,
    verifier: any UpdateCodeVerifier, recovery: (any UpdateRecoveryChecking)? = nil
  ) {
    self.files = files
    self.processes = processes
    self.verifier = verifier
    self.recovery = recovery
  }
  public func recoveryNeedsAttention(root: URL) throws -> Bool {
    guard files.isDirectory(root) else { return false }
    for previous in try files.contents(root) where files.isDirectory(previous) {
      let backup = previous.appendingPathComponent("Previous.app")
      if try files.contents(previous).contains(where: { $0.lastPathComponent == "Previous.app" }),
        (try? recovery?.canDiscard(backup: backup)) != true
      {
        return true
      }
    }
    return false
  }
  public func prepare(archive: Data, manifest: UpdateManifest, root: URL, team: String) throws
    -> PreparedUpdate
  {
    try manifest.validate()
    try UpdatePolicy.verifyArchive(archive, manifest: manifest, sums: nil)
    try UpdateArchiveLayout.validate(archive)
    try files.createPrivateDirectory(root)
    // Retain at most one prepared candidate. Preserve interrupted-install backups
    // unless an authenticated installed app is at least as new as the backup.
    for previous in try files.contents(root) {
      let needsRecovery: Bool
      if files.isDirectory(previous) {
        needsRecovery = try files.contents(previous).contains {
          $0.lastPathComponent == "Previous.app"
        }
      } else {
        needsRecovery = false
      }
      if needsRecovery,
        (try? recovery?.canDiscard(backup: previous.appendingPathComponent("Previous.app"))) != true
      {
        throw UpdateError.needsAttention
      }
      do { try files.remove(previous) } catch {
        if needsRecovery { throw UpdateError.needsAttention }
        throw error
      }
    }
    let directory = root.appendingPathComponent(manifest.build + "-" + UUID().uuidString)
    do {
      try files.createPrivateDirectory(directory)
      let zip = directory.appendingPathComponent("update.zip")
      try files.write(archive, to: zip)
      let extracted = directory.appendingPathComponent("Extracted")
      try files.createPrivateDirectory(extracted)
      try processes.run(
        "/usr/bin/ditto", arguments: ["-x", "-k", zip.path, extracted.path], timeout: 60)
      let prepared = PreparedUpdate(manifest: manifest, directory: directory)
      guard try files.contents(extracted).map(\.lastPathComponent) == ["TinyStats.app"] else {
        throw UpdateError.invalid("The archive must contain exactly one TinyStats.app.")
      }
      try files.validateBundleTree(prepared.app)
      try verifier.verify(prepared.app, manifest: manifest, runningTeam: team)
      try files.remove(zip)
      return prepared
    } catch {
      try? files.remove(directory)
      throw error
    }
  }
}

/// Inspect the central directory before ditto: no path traversal, encryption, ZIP64 or bombs.
public enum UpdateArchiveLayout {
  public static func validate(_ data: Data) throws {
    func fail() -> UpdateError { .invalid("Unsafe or unsupported update ZIP layout.") }
    func number(_ offset: Int, _ count: Int) throws -> Int {
      guard offset >= 0, offset <= data.count - count else { throw fail() }
      return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }
    func validateExtra(_ start: Int, _ length: Int) throws {
      let end = start + length
      guard end <= data.count else { throw fail() }
      var cursor = start
      while cursor < end {
        guard cursor + 4 <= end else { throw fail() }
        let kind = try number(cursor, 2)
        let size = try number(cursor + 2, 2)
        // ditto timestamps/UIDs only. Reject Unicode path overrides, ZIP64,
        // extended Unix link/device records and all unknown extraction metadata.
        guard cursor + 4 + size <= end,
          (kind == 0x5855 && (size == 8 || size == 12))
            || (kind == 0x5455 && (1...13).contains(size))
            || (kind == 0x7875 && (3...32).contains(size))
        else { throw fail() }
        cursor += 4 + size
      }
      guard cursor == end else { throw fail() }
    }
    guard data.count >= 22, data.count <= UpdatePolicy.archiveLimit else { throw fail() }
    var end: Int?
    for index in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
      if try number(index, 4) == 0x0605_4b50, index + 22 + (try number(index + 20, 2)) == data.count
      {
        end = index
        break
      }
    }
    guard let end, try number(end + 4, 4) == 0 else { throw fail() }
    let count = try number(end + 10, 2)
    guard count > 0, count <= 20_000, try number(end + 8, 2) == count else { throw fail() }
    var offset = try number(end + 16, 4)
    let centralStart = offset
    let directoryEnd = offset + (try number(end + 12, 4))
    guard directoryEnd == end else { throw fail() }
    var total = 0
    var paths = Set<String>()
    var records: [(start: Int, end: Int)] = []
    for _ in 0..<count {
      guard try number(offset, 4) == 0x0201_4b50, try number(offset + 8, 2) & 1 == 0 else {
        throw fail()
      }
      guard try number(offset + 34, 2) == 0 else { throw fail() }
      let flags = try number(offset + 8, 2)
      let method = try number(offset + 10, 2)
      guard try number(offset + 6, 2) <= 20, flags & ~0x080e == 0, method == 0 || method == 8 else {
        throw fail()
      }
      let type = (try number(offset + 38, 4)) >> 16 & 0o170000
      guard type == 0 || type == 0o100000 || type == 0o040000 else { throw fail() }
      let size = try number(offset + 24, 4)
      let length = try number(offset + 28, 2)
      let compressed = try number(offset + 20, 4)
      let crc = try number(offset + 16, 4)
      let extra = try number(offset + 30, 2)
      let comment = try number(offset + 32, 2)
      guard length > 0, offset + 46 + length <= directoryEnd,
        let name = String(
          data: data.subdata(in: offset + 46..<offset + 46 + length), encoding: .utf8)
      else { throw fail() }
      try validateExtra(offset + 46 + length, extra)
      let parts = name.split(separator: "/", omittingEmptySubsequences: false)
      guard !name.contains("\\"), !name.contains("\0"), !name.hasPrefix("/"),
        parts.first == "TinyStats.app", !parts.contains(".."), !parts.contains("."),
        !parts.dropLast().contains(""),
        paths.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted
      else { throw fail() }
      // Match local-header path as well, so extraction cannot use a different filename.
      let local = try number(offset + 42, 4)
      guard try number(local, 4) == 0x0403_4b50, try number(local + 26, 2) == length,
        local + 30 + length <= data.count,
        data.subdata(in: local + 30..<local + 30 + length)
          == data.subdata(in: offset + 46..<offset + 46 + length)
      else { throw fail() }
      guard try number(local + 4, 2) <= 20, try number(local + 6, 2) == flags,
        try number(local + 8, 2) == method
      else { throw fail() }
      let localExtra = try number(local + 28, 2)
      try validateExtra(local + 30 + length, localExtra)
      var recordEnd = local + 30 + length + localExtra + compressed
      if flags & 8 != 0 {
        if try number(recordEnd, 4) == 0x0807_4b50 { recordEnd += 4 }
        guard try number(recordEnd, 4) == crc, try number(recordEnd + 4, 4) == compressed,
          try number(recordEnd + 8, 4) == size
        else { throw fail() }
        recordEnd += 12
      } else {
        guard try number(local + 14, 4) == crc, try number(local + 18, 4) == compressed,
          try number(local + 22, 4) == size
        else { throw fail() }
      }
      guard recordEnd <= centralStart else { throw fail() }
      records.append((local, recordEnd))
      total += size
      guard total <= 512 * 1_048_576 else { throw fail() }
      offset += 46 + length + extra + comment
      guard offset <= directoryEnd else { throw fail() }
    }
    guard offset == directoryEnd else { throw fail() }
    var previousEnd = 0
    for record in records.sorted(by: { $0.start < $1.start }) {
      guard record.start == previousEnd else { throw fail() }
      previousEnd = record.end
    }
    guard previousEnd == centralStart else { throw fail() }
  }
}

/// Shared by the detached helper and temp-directory regression tests. A failed restore
/// retains the backup and reports failure; it must never be deleted by failure cleanup.
public enum UpdateInstallTransaction {
  public static func install(
    original: URL, staged: URL, backup: URL, pid: Int32,
    files: any UpdateFileSystem, waiter: any UpdateExitWaiter,
    verify: () throws -> Void
  ) throws {
    try waiter.waitForExit(pid: pid, timeout: 120)
    try verify()
    guard files.isDirectory(original), files.isDirectory(staged) else {
      throw UpdateError.invalid("An app bundle moved before installation.")
    }
    try files.move(original, to: backup)
    do {
      try files.move(staged, to: original)
    } catch {
      try files.move(backup, to: original)
      throw error
    }
    // Both renames committed. Cleanup failure must not turn a successful install
    // into a failed one; a later signed-version recovery check can remove it.
    try? files.remove(backup)
  }
}

/// Relaunch belongs after the filesystem transaction. A launch-services error must
/// never roll back (or delete) a successfully installed, potentially running app.
public enum UpdateInstallRecovery {
  public static func perform(
    relaunch: Bool, recoverOnFailure: (() -> Bool)? = nil, install: () throws -> Void,
    reopen: () throws -> Void, report: (any Error) -> Void
  ) throws {
    do { try install() } catch {
      report(error)
      if recoverOnFailure?() ?? relaunch {
        do { try reopen() } catch { report(error) }
      }
      throw error
    }
    if relaunch {
      do { try reopen() } catch { report(error) }
    }
  }
}

public enum UpdateInstallAccess {
  public static func allows(
    bundleWritable: Bool, parentWritable: Bool, owner: UInt32,
    user: UInt32, sameVolume: Bool
  ) -> Bool {
    bundleWritable && parentWritable && owner == user && sameVolume
  }
}
