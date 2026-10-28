import Darwin
import Foundation
import Testing

@testable import TinyStatsCore

func checkpointFixtureRoot() throws -> URL {
  let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
  defer { free(pointer) }
  // Foundation resolves /private/var back to /var; the store deliberately rejects that alias.
  let root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  return root
}
private func checkpointFixtureData() -> Data {
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.time = Date(timeIntervalSinceReferenceDate: 1000)
  point.sampleInterval = 2
  point.cpu = 42
  archive.append(point, uptime: 1)
  return archive.checkpoint()
}

@Test func historyStorePathIsolationRequiresExplicitDirectoryAndNeverFallsBackToOwner() {
  let support = URL(fileURLWithPath: "/fixture/support", isDirectory: true)
  let owner = support.appendingPathComponent("TinyStatsHistory", isDirectory: true)
  #expect(HistoryStoreLocation.directory(environment: [:], applicationSupport: support) == owner)
  for domain in ["", "isolated.example"] {
    var environment = ["TINYSTATS_PREFERENCES_DOMAIN": domain]
    #expect(
      HistoryStoreLocation.directory(environment: environment, applicationSupport: support) == nil)
    for invalid in ["relative", "", "/bad\0path", owner.path, owner.path + "/../TinyStatsHistory"] {
      environment["TINYSTATS_HISTORY_DIRECTORY"] = invalid
      #expect(
        HistoryStoreLocation.directory(environment: environment, applicationSupport: support) == nil
      )
    }
    environment["TINYSTATS_HISTORY_DIRECTORY"] = "/fixture/isolated-history"
    #expect(
      HistoryStoreLocation.directory(environment: environment, applicationSupport: support)?.path
        == "/fixture/isolated-history")
  }
}

@Test func historyStoreUsesPrivateFilesAndAtomicBoundedRoundTrip() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history", isDirectory: true)
  let store = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  #expect(try store.read() == nil)
  let data = checkpointFixtureData()
  try store.write(data)
  #expect(try store.read() == data)
  let restored = try SessionHistory(
    checkpoint: #require(try store.read()), now: Date(timeIntervalSinceReferenceDate: 1000))
  #expect(restored.projection(.hour).samples == 1)
  let fm = FileManager.default
  #expect(try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
  for file in [LocalHistoryCheckpointStore.fileName, LocalHistoryCheckpointStore.lockName] {
    #expect(
      try fm.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[
        .posixPermissions] as? Int == 0o600)
  }
  #expect(
    !fm.fileExists(
      atPath: directory.appendingPathComponent(LocalHistoryCheckpointStore.temporaryName).path))
  for invalid in [Data(), Data(repeating: 0, count: SessionHistory.maximumCheckpointBytes + 1)] {
    #expect(throws: HistoryFileError.invalidSize) { try store.write(invalid) }
    #expect(try store.read() == data)
  }
  try store.remove()
  #expect(try store.read() == nil)
}

@Test func historyStoreLockContentionFailsWithoutBlockingAndReleasesWithOwner() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  var first = try LocalHistoryCheckpointStore(directory: directory, create: true)
  #expect(first != nil)
  #expect(throws: HistoryFileError.inUse) {
    try LocalHistoryCheckpointStore(directory: directory, create: true)
  }
  first = nil
  let second = try LocalHistoryCheckpointStore(directory: directory, create: false)
  #expect(second != nil)
}

@Test func historyStoreExistingOnlyClearDoesNotCreateDirectoryAndRejectsSymlinkDirectory() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let absent = root.appendingPathComponent("absent")
  #expect(try LocalHistoryCheckpointStore(directory: absent, create: false) == nil)
  #expect(!FileManager.default.fileExists(atPath: absent.path))
  let link = root.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
  #expect(throws: HistoryFileError.self) {
    try LocalHistoryCheckpointStore(directory: link, create: true)
  }
}

@Test func historyStoreRejectsSymlinkAndHardlinkCheckpointWithoutReadingOrChangingTarget() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  let store = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  let target = root.appendingPathComponent("canary")
  let bytes = checkpointFixtureData()
  try bytes.write(to: target)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  let path = directory.appendingPathComponent(LocalHistoryCheckpointStore.fileName)
  try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
  #expect(throws: HistoryFileError.self) { try store.read() }
  #expect(throws: HistoryFileError.self) { try store.remove() }
  #expect(throws: HistoryFileError.self) { try store.write(bytes) }
  #expect(try Data(contentsOf: target) == bytes)
  try FileManager.default.removeItem(at: path)
  try FileManager.default.linkItem(at: target, to: path)
  #expect(throws: HistoryFileError.unsafeFile) { try store.read() }
  #expect(throws: HistoryFileError.unsafeFile) { try store.write(bytes) }
  #expect(try Data(contentsOf: target) == bytes)
}

@Test func historyStoreFailedReplacementKeepsPreviousCheckpointAndCleansOwnTemporary() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  let store = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  let previous = checkpointFixtureData()
  try store.write(previous)
  let path = directory.appendingPathComponent(LocalHistoryCheckpointStore.fileName)
  try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
  #expect(throws: HistoryFileError.unsafeFile) { try store.write(SessionHistory().checkpoint()) }
  #expect(try Data(contentsOf: path) == previous)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(LocalHistoryCheckpointStore.temporaryName).path))
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  #expect(try store.read() == previous)
}

@Test func historyStoreRecoversOnlyOwnedStaleTemporaryAndRejectsUnsafeTemporary() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  let store = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  let data = checkpointFixtureData()
  let temporary = directory.appendingPathComponent(LocalHistoryCheckpointStore.temporaryName)
  try data.write(to: temporary)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
  try store.write(data)
  #expect(try store.read() == data)
  let target = root.appendingPathComponent("canary")
  try data.write(to: target)
  try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: target)
  #expect(throws: HistoryFileError.unsafeFile) { try store.write(data) }
  #expect(try store.read() == data && Data(contentsOf: target) == data)
}

@Test func historyStoreRejectsSymlinkParentBeforeCreatingAnyDirectory() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let parent = root.appendingPathComponent("parent-link")
  try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
  #expect(throws: HistoryFileError.self) {
    try LocalHistoryCheckpointStore(
      directory: parent.appendingPathComponent("unexpected"), create: true)
  }
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
}

@Test func historyStoreRejectsFIFOWithoutOpeningItInBlockingMode() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  let store = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  let fifo = directory.appendingPathComponent(LocalHistoryCheckpointStore.fileName)
  #expect(mkfifo(fifo.path, 0o600) == 0)
  #expect(throws: HistoryFileError.unsafeFile) { try store.read() }
  #expect(throws: HistoryFileError.unsafeFile) { try store.write(checkpointFixtureData()) }
  #expect(throws: HistoryFileError.unsafeFile) { try store.remove() }
}

@Test func historyStoreFreshPathResolutionAfterDirectoryExistsStillReopensTheSameCheckpoint() throws
{
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let path = root.appendingPathComponent("records", isDirectory: true).path
  let environment = [
    "TINYSTATS_PREFERENCES_DOMAIN": "test-only", "TINYSTATS_HISTORY_DIRECTORY": path,
  ]
  let firstDirectory = try #require(
    HistoryStoreLocation.directory(environment: environment, applicationSupport: nil))
  var first = try LocalHistoryCheckpointStore(directory: firstDirectory, create: true)
  let data = checkpointFixtureData()
  try first?.write(data)
  first = nil
  let secondDirectory = try #require(
    HistoryStoreLocation.directory(environment: environment, applicationSupport: nil))
  #expect(firstDirectory.path == secondDirectory.path)
  let second = try #require(
    try LocalHistoryCheckpointStore(directory: secondDirectory, create: true))
  #expect(try second.read() == data)
}

@Test func historyStoreOversizeCheckpointIsNotReadButExplicitClearCanRecover() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  let store = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  let path = directory.appendingPathComponent(LocalHistoryCheckpointStore.fileName)
  try Data(repeating: 0, count: SessionHistory.maximumCheckpointBytes + 1).write(to: path)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  #expect(throws: HistoryFileError.invalidSize) { try store.read() }
  try store.remove()
  #expect(try store.read() == nil)
  let data = checkpointFixtureData()
  try store.write(data)
  #expect(try store.read() == data)
}

@Test func historyStoreIsolationRejectsExcludedPhysicalFolderAndCaseVariantsBeforeCreation() throws
{
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let owner = root.appendingPathComponent("OwnerHistory")
  let alias = root.appendingPathComponent("ownerhistory")
  #expect(throws: HistoryFileError.unsafeFile) {
    try LocalHistoryCheckpointStore(directory: alias, create: true, excludingDirectory: owner)
  }
  #expect(!FileManager.default.fileExists(atPath: alias.path))
  let store = try #require(try LocalHistoryCheckpointStore(directory: owner, create: true))
  try store.write(checkpointFixtureData())
  #expect(throws: HistoryFileError.unsafeFile) {
    try LocalHistoryCheckpointStore(directory: owner, create: true, excludingDirectory: owner)
  }
  #expect(try store.read() == checkpointFixtureData())
  #expect(
    try LocalHistoryCheckpointStore(
      directory: root.appendingPathComponent("isolated"), create: true, excludingDirectory: owner)
      != nil)
}

@Test func historyStoreUnsafeLockDoesNotSuggestDestructiveCheckpointRecovery() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  var store = try LocalHistoryCheckpointStore(directory: directory, create: true)
  #expect(store != nil)
  store = nil
  try Data([1]).write(to: directory.appendingPathComponent(LocalHistoryCheckpointStore.lockName))
  #expect(throws: HistoryFileError.unsafeLock) {
    try LocalHistoryCheckpointStore(directory: directory, create: true)
  }
  #expect(!HistoryStorageIssue.from(HistoryFileError.unsafeLock).message.contains("Clear"))
}
