import Foundation
import Testing

@testable import TinyStatsCore

private let updateVersion = "0.37.6"
private let updateFilename = "TinyStats-0.37.6-macOS-universal.zip"
private let updateHash = String(repeating: "a", count: 64)
private func manifestData(
  version: String = updateVersion, build: String = "78", file: String = updateFilename,
  sha: String = updateHash
) throws -> Data {
  try JSONEncoder().encode(UpdateManifest(version: version, build: build, sha256: sha, file: file))
}
private func releaseData(
  tag: String = "v0.37.6", draft: Bool = false, prerelease: Bool = false,
  names: [String] = ["release.json", updateFilename, "SHA256SUMS.txt"], host: String = "github.com",
  size: Int = 1024
) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "tag_name": tag, "draft": draft, "prerelease": prerelease,
    "html_url": "https://github.com/letsopen-ai/tinystats/releases/tag/\(tag)",
    "assets": names.map {
      [
        "name": $0, "size": size,
        "browser_download_url":
          "https://\(host)/letsopen-ai/tinystats/releases/download/\(tag)/\($0)",
      ]
    },
  ])
}

@Test func updateReleaseContractAcceptsOnlyNewerVersionAndBuild() throws {
  let release = try UpdateRelease.parse(releaseData())
  let candidate = try #require(
    try release.candidate(manifest: manifestData(), runningVersion: "0.37.5", runningBuild: "77"))
  #expect(candidate.manifest.build == "78")
  for pair in [("0.37.6", "77"), ("0.37.7", "77"), ("0.37.5", "78"), ("0.37.5", "79")] {
    #expect(
      try release.candidate(manifest: manifestData(), runningVersion: pair.0, runningBuild: pair.1)
        == nil)
  }
}
@Test(arguments: [
  "0.37", "v0.37.6", "0.37.6-beta", "0.37.6+1", "00.37.6", "0.-1.0", "0.37.999999999999999999999",
  "0.37.6.",
])
func updateVersionRejectsMalformed(_ value: String) {
  #expect(throws: (any Error).self) { try UpdateVersion(value) }
}
@Test func updateVersionsCompareNumerically() throws {
  #expect(try UpdateVersion("0.37.10") > UpdateVersion("0.37.9"))
  #expect(try UpdateVersion("1.0.0") > UpdateVersion("0.99.99"))
}
@Test(arguments: ["0", "-1", "1.0", " 78", "078", "9999999999999999999999"])
func updateBuildRejectsMalformed(_ value: String) {
  #expect(throws: (any Error).self) { try UpdatePolicy.build(value) }
}
@Test func updateReleaseRejectsDraftPrereleaseWrongTagDuplicateAndOversize() throws {
  for data in [
    try releaseData(draft: true), try releaseData(prerelease: true), try releaseData(tag: "0.37.6"),
    try releaseData(names: ["release.json", "release.json"]),
    Data(repeating: 32, count: UpdatePolicy.jsonLimit + 1),
  ] {
    #expect(throws: (any Error).self) { try UpdateRelease.parse(data) }
  }
}
@Test func updateManifestAndAssetsFailClosed() throws {
  let release = try UpdateRelease.parse(releaseData())
  for data in [
    try manifestData(version: "0.37.7"), try manifestData(file: "../../evil.zip"),
    try manifestData(build: "no"), try manifestData(sha: "a"), Data("{}".utf8),
  ] {
    #expect(throws: (any Error).self) {
      try release.candidate(manifest: data, runningVersion: "0.37.5", runningBuild: "77")
    }
  }
  for data in [
    try releaseData(names: ["release.json"]), try releaseData(host: "evil.example"),
    try releaseData(size: UpdatePolicy.archiveLimit + 1), try releaseData(size: -1),
  ] {
    let release = try UpdateRelease.parse(data)
    #expect(throws: (any Error).self) {
      try release.candidate(manifest: manifestData(), runningVersion: "0.37.5", runningBuild: "77")
    }
  }
}
@Test(arguments: [
  "http://github.com/a", "https://github.com.evil.example/a", "https://evil.example/a",
  "https://github.com:444/a", "https://user@github.com/a", "file:///tmp/a",
  "https://github.com/a#fragment",
])
func updateRejectsUnsafeDestinations(_ text: String) throws {
  #expect(!UpdatePolicy.allows(try #require(URL(string: text))))
}
@Test func updateAllowsOnlyDocumentedHTTPSHostsAndReleasePages() {
  for host in UpdatePolicy.hosts {
    #expect(UpdatePolicy.allows(URL(string: "https://\(host)/asset")!))
  }
  #expect(
    UpdatePolicy.releasePage(
      URL(string: "https://github.com/letsopen-ai/tinystats/releases/tag/v0.37.6")!))
  #expect(!UpdatePolicy.releasePage(URL(string: "https://github.com/other/repo/releases/tag/v1")!))
  #expect(
    UpdatePolicy.userAgent(version: "0.37.5")
      == "TinyStats/0.37.5 (https://github.com/letsopen-ai/tinystats)")
}
@Test func updateChecksumsRequireAgreementAndSizeBounds() throws {
  let data = Data("test archive".utf8)
  let hash = UpdatePolicy.digest(data)
  let manifest = UpdateManifest(
    version: updateVersion, build: "78", sha256: hash, file: updateFilename)
  try UpdatePolicy.verifyArchive(
    data, manifest: manifest, sums: Data("\(hash)  \(updateFilename)\n".utf8))
  #expect(throws: (any Error).self) {
    try UpdatePolicy.verifyArchive(Data("tampered".utf8), manifest: manifest, sums: nil)
  }
  for sums in [
    "\(updateHash)  \(updateFilename)", "\(hash)  other.zip",
    "\(hash)  \(updateFilename)\n\(hash)  \(updateFilename)",
  ] {
    #expect(throws: (any Error).self) {
      try UpdatePolicy.verifyArchive(data, manifest: manifest, sums: Data(sums.utf8))
    }
  }
  #expect(throws: (any Error).self) {
    try UpdatePolicy.verifyArchive(
      Data(repeating: 0, count: UpdatePolicy.archiveLimit + 1), manifest: manifest, sums: nil)
  }
}
@Test func updatePreferencesDefaultOnPersistOffAndRejectMalformed() throws {
  let name = "TinyStats.UpdateTests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  var value = UpdatePreferences(defaults: defaults)
  #expect(value.automaticallyCheck && value.automaticallyDownload)
  value.automaticallyCheck = false
  value.automaticallyDownload = false
  value.lastCheck = Date(timeIntervalSince1970: 123)
  value.retryAfter = Date(timeIntervalSince1970: 456)
  value.save(to: defaults)
  #expect(UpdatePreferences(defaults: defaults) == value)
  defaults.set("true", forKey: "updates.automaticallyCheck")
  #expect(!UpdatePreferences(defaults: defaults).automaticallyCheck)
}
@Test func updateScheduleWaitsForLaunchTourAnd24HoursAndRespectsOffAndBackoff() {
  let launch = Date(timeIntervalSince1970: 1000)
  var preferences = UpdatePreferences()
  func due(_ seconds: Double, tour: Bool = false) -> Bool {
    preferences.due(
      now: launch.addingTimeInterval(seconds), launch: launch, delay: 180, welcomeVisible: tour)
  }
  #expect(!due(179) && due(180) && !due(180, tour: true))
  preferences.lastCheck = launch
  #expect(!due(86_399) && due(86_400) && due(100_000))  // overdue wake
  preferences.automaticallyCheck = false
  #expect(!due(100_000))
  preferences.automaticallyCheck = true
  preferences.retryAfter = launch.addingTimeInterval(110_000)
  #expect(!due(100_000) && due(110_000))
}
@Test func updateEligibilityRejectsDevelopmentWrongTeamTranslocationAndReadOnly() {
  var value = UpdateEligibility(
    bundleID: UpdatePolicy.bundleID, teamID: UpdatePolicy.teamID, developerID: true,
    translocated: false, readOnly: false)
  #expect(value.eligible)
  value.teamID = nil
  #expect(!value.eligible)
  value.teamID = "OTHER"
  #expect(!value.eligible)
  value.teamID = UpdatePolicy.teamID
  value.developerID = false
  #expect(!value.eligible)
  value.developerID = true
  value.translocated = true
  #expect(!value.eligible)
  value.translocated = false
  value.readOnly = true
  #expect(!value.eligible)
  value.readOnly = false
  value.bundleID = "other"
  #expect(!value.eligible)
}
@Test func updateRateLimitsRespectBothHeadersAndFallback() {
  let now = Date(timeIntervalSince1970: 1000)
  #expect(UpdateRateLimit.retryDate(headers: [:], now: now) == now.addingTimeInterval(3600))
  #expect(
    UpdateRateLimit.retryDate(
      headers: ["retry-after": "7200", "x-ratelimit-reset": "10000"], now: now)
      == Date(timeIntervalSince1970: 10000))
  #expect(UpdateRateLimit.retryDate(headers: ["retry-after": "nonsense"], now: now) > now)
}

private struct UpdateFakeTransport: UpdateTransport {
  let replies: [URL: Data]
  func get(_ url: URL, limit: Int) async throws -> Data {
    guard let reply = replies[url] else {
      throw UpdateError.invalid("Unexpected network request in test.")
    }
    return reply
  }
}
@Test func updateClientUsesOnlyReleaseAssetsWithInjectedTransport() async throws {
  let release = try UpdateRelease.parse(releaseData())
  let manifestURL = try release.asset("release.json", limit: UpdatePolicy.jsonLimit)
    .downloadURL
  let client = UpdateClient(
    transport: UpdateFakeTransport(replies: [
      UpdatePolicy.latestURL: try releaseData(), manifestURL: try manifestData(),
    ]))
  let candidate = try await client.check(version: "0.37.5", build: "77")
  #expect(candidate?.manifest.build == "78")
}

// Minimal uncompressed ZIP directory for preflight tests; extraction itself is injected.
private func updateZIP(
  path: String = "TinyStats.app/Contents/Info.plist", expanded: Int = 1, metadata: Data = Data()
)
  -> Data
{
  var data = Data()
  func append(_ value: Int, _ size: Int) {
    for index in 0..<size { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
  }
  let name = Data(path.utf8)
  append(0x0403_4b50, 4)
  append(20, 2)
  append(0, 2)
  append(0, 2)
  append(0, 4)
  append(0, 4)
  append(1, 4)
  append(expanded, 4)
  append(name.count, 2)
  append(metadata.count, 2)
  data.append(name)
  data.append(metadata)
  data.append(0)
  let central = data.count
  append(0x0201_4b50, 4)
  append(20, 2)
  append(20, 2)
  append(0, 2)
  append(0, 2)
  append(0, 4)
  append(0, 4)
  append(1, 4)
  append(expanded, 4)
  append(name.count, 2)
  append(metadata.count, 2)
  append(0, 2)
  append(0, 2)
  append(0, 2)
  append(0, 4)
  append(0, 4)
  data.append(name)
  data.append(metadata)
  let centralSize = data.count - central
  append(0x0605_4b50, 4)
  append(0, 2)
  append(0, 2)
  append(1, 2)
  append(1, 2)
  append(centralSize, 4)
  append(central, 4)
  append(0, 2)
  return data
}
@Test func updateZIPPreflightRejectsTraversalExtraRootsAndBombs() throws {
  try UpdateArchiveLayout.validate(updateZIP())
  for path in [
    "evil.app/Contents/a", "/TinyStats.app/a", "TinyStats.app/../outside", "TinyStats.app/./a",
    "TinyStats.app//a", "TinyStats.app\\outside",
  ] {
    #expect(throws: (any Error).self) { try UpdateArchiveLayout.validate(updateZIP(path: path)) }
  }
  #expect(throws: (any Error).self) {
    try UpdateArchiveLayout.validate(updateZIP(expanded: 512 * 1_048_576 + 1))
  }
  #expect(throws: (any Error).self) { try UpdateArchiveLayout.validate(Data("invalid".utf8)) }
}
private struct UpdateFakeVerifier: UpdateCodeVerifier {
  var failure: String?
  func verify(_ app: URL, manifest: UpdateManifest, runningTeam: String) throws {
    if let failure { throw UpdateError.invalid(failure) }
  }
}
private struct UpdateFakeExtractor: UpdateProcessRunner {
  var extra = false
  func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws {
    let root = URL(fileURLWithPath: arguments.last!)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("TinyStats.app"), withIntermediateDirectories: true)
    if extra { try Data().write(to: root.appendingPathComponent("extra")) }
  }
}
@Test(arguments: ["signature", "team", "notarization", "Gatekeeper", "metadata"])
func updateStagingCleansUpAllVerificationFailures(_ reason: String) throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = updateZIP()
  let manifest = UpdateManifest(
    version: updateVersion, build: "78", sha256: UpdatePolicy.digest(archive), file: updateFilename)
  let stager = UpdateStager(
    files: NativeUpdateFileSystem(), processes: UpdateFakeExtractor(),
    verifier: UpdateFakeVerifier(failure: reason))
  #expect(throws: (any Error).self) {
    try stager.prepare(archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}
@Test func updateStagingRejectsExtraEntriesAndEscapingSymlinksAndUsesPrivateDirectory() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = updateZIP()
  let manifest = UpdateManifest(
    version: updateVersion, build: "78", sha256: UpdatePolicy.digest(archive), file: updateFilename)
  let bad = UpdateStager(
    files: NativeUpdateFileSystem(), processes: UpdateFakeExtractor(extra: true),
    verifier: UpdateFakeVerifier())
  #expect(throws: (any Error).self) {
    try bad.prepare(archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
  }
  let good = UpdateStager(
    files: NativeUpdateFileSystem(), processes: UpdateFakeExtractor(),
    verifier: UpdateFakeVerifier())
  let prepared = try good.prepare(
    archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
  #expect(
    (try FileManager.default.attributesOfItem(atPath: prepared.directory.path)[.posixPermissions]
      as? NSNumber)?.intValue == 0o700)
  try FileManager.default.createSymbolicLink(
    at: prepared.app.appendingPathComponent("escape"), withDestinationURL: root)
  #expect(throws: (any Error).self) {
    try NativeUpdateFileSystem().validateBundleTree(prepared.app)
  }
}

private struct UpdateFakeWaiter: UpdateExitWaiter {
  var fail = false
  func waitForExit(pid: Int32, timeout: TimeInterval) throws {
    #expect(pid == 42 && timeout == 120)
    if fail { throw UpdateError.invalid("wait timeout") }
  }
}
@Test(arguments: ["success", "wait", "verify", "move"])
func updateInstallMovesOrRestoresRealTempBundles(_ scenario: String) throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  let original = root.appendingPathComponent("Installed/TinyStats.app")
  let staged = root.appendingPathComponent("Staged/TinyStats.app")
  let backup = root.appendingPathComponent("Backup.app")
  defer { try? FileManager.default.removeItem(at: root) }
  for app in [original, staged] {
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  }
  try Data("old".utf8).write(to: original.appendingPathComponent("marker"))
  try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
  func install() throws {
    try UpdateInstallTransaction.install(
      original: original, staged: staged, backup: backup, pid: 42,
      files: NativeUpdateFileSystem(), waiter: UpdateFakeWaiter(fail: scenario == "wait"),
      verify: {
        if scenario == "verify" { throw UpdateError.invalid("signature changed") }
        if scenario == "move" { try FileManager.default.removeItem(at: staged) }
      })
  }
  if scenario == "success" {
    try install()
  } else {
    #expect(throws: (any Error).self) { try install() }
  }
  #expect(
    try String(contentsOf: original.appendingPathComponent("marker"), encoding: .utf8)
      == (scenario == "success" ? "new" : "old"))
  #expect(!FileManager.default.fileExists(atPath: backup.path))
}

private struct UpdateFailingMoveFiles: UpdateFileSystem {
  let base = NativeUpdateFileSystem()
  let staged: URL
  let original: URL
  let failRestore: Bool
  var failStagedMove = true
  var failBackupRemoval = false
  func createPrivateDirectory(_ url: URL) throws { try base.createPrivateDirectory(url) }
  func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
  func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
  func isDirectory(_ url: URL) -> Bool { base.isDirectory(url) }
  func validateBundleTree(_ url: URL) throws { try base.validateBundleTree(url) }
  func remove(_ url: URL) throws {
    if failBackupRemoval && url.lastPathComponent == "Previous.app" {
      throw UpdateError.invalid("Injected backup cleanup failure")
    }
    try base.remove(url)
  }
  func move(_ source: URL, to destination: URL) throws {
    if (failStagedMove && source == staged) || (failRestore && destination == original) {
      throw UpdateError.invalid("Injected rename failure")
    }
    try base.move(source, to: destination)
  }
}
@Test(arguments: [false, true])
func updateInstallRestoresOnSecondRenameFailureAndPreservesFailedRollback(_ failRestore: Bool)
  throws
{
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let original = root.appendingPathComponent("Installed/TinyStats.app")
  let staged = root.appendingPathComponent("Staged/TinyStats.app")
  let backup = root.appendingPathComponent("Previous.app")
  for app in [original, staged] {
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  }
  try Data("old".utf8).write(to: original.appendingPathComponent("marker"))
  let files = UpdateFailingMoveFiles(staged: staged, original: original, failRestore: failRestore)
  #expect(throws: (any Error).self) {
    try UpdateInstallTransaction.install(
      original: original, staged: staged, backup: backup, pid: 42,
      files: files, waiter: UpdateFakeWaiter(), verify: {})
  }
  let recovered = failRestore ? backup : original
  #expect(
    try String(contentsOf: recovered.appendingPathComponent("marker"), encoding: .utf8) == "old")
  #expect(FileManager.default.fileExists(atPath: staged.path))
  #expect(FileManager.default.fileExists(atPath: backup.path) == failRestore)
}

@Test func updateZIPRejectsHeaderDisagreementUnknownMetadataAndHiddenRecords() {
  let path = "TinyStats.app/Contents/Info.plist"
  let central = 31 + path.utf8.count
  var mismatchedFlags = updateZIP(path: path)
  mismatchedFlags[6] = 8
  var unsupportedMethod = updateZIP(path: path)
  unsupportedMethod[central + 10] = 99
  var wrongDisk = updateZIP(path: path)
  wrongDisk[central + 34] = 1
  var specialFile = updateZIP(path: path)
  specialFile[central + 41] = 0xa1  // Unix symlink type
  var wrongLocalOffset = updateZIP(path: path)
  wrongLocalOffset[central + 42] = 1
  // A Unicode path extra could override a safe central-directory name in an extractor.
  let pathOverride = updateZIP(metadata: Data([0x75, 0x70, 0x01, 0x00, 0x00]))
  for data in [
    mismatchedFlags, unsupportedMethod, wrongDisk, specialFile, wrongLocalOffset, pathOverride,
  ] {
    #expect(throws: (any Error).self) { try UpdateArchiveLayout.validate(data) }
  }
}

@Test func updateStagingBoundsOldCandidatesAndPreservesRecoveryBackups() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = updateZIP()
  let manifest = UpdateManifest(
    version: updateVersion, build: "78", sha256: UpdatePolicy.digest(archive), file: updateFilename)
  let stager = UpdateStager(
    files: NativeUpdateFileSystem(), processes: UpdateFakeExtractor(),
    verifier: UpdateFakeVerifier())
  let old = try stager.prepare(
    archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
  try Data("stray".utf8).write(to: root.appendingPathComponent(".DS_Store"))
  let latest = try stager.prepare(
    archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
  #expect(!FileManager.default.fileExists(atPath: old.directory.path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
  let backup = latest.directory.appendingPathComponent("Previous.app")
  try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
  #expect(throws: (any Error).self) {
    try stager.prepare(archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
  }
  #expect(FileManager.default.fileExists(atPath: backup.path))
}

@Test(arguments: ["wait", "verify", "move"])
func updateFailedRestartReopensUntouchedOrRestoredTempApp(_ reason: String) throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let original = root.appendingPathComponent("Installed/TinyStats.app")
  let staged = root.appendingPathComponent("Staged/TinyStats.app")
  for app in [original, staged] {
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  }
  try Data("old".utf8).write(to: original.appendingPathComponent("marker"))
  let files: any UpdateFileSystem =
    reason == "move"
    ? UpdateFailingMoveFiles(staged: staged, original: original, failRestore: false)
    : NativeUpdateFileSystem()
  var reopened = 0
  var reported = 0
  var reopenedMarker: String?
  #expect(throws: (any Error).self) {
    try UpdateInstallRecovery.perform(
      relaunch: true,
      install: {
        try UpdateInstallTransaction.install(
          original: original, staged: staged,
          backup: root.appendingPathComponent("Previous.app"), pid: 42, files: files,
          waiter: UpdateFakeWaiter(fail: reason == "wait"),
          verify: {
            if reason == "verify" { throw UpdateError.invalid("changed signature") }
          })
      },
      reopen: {
        reopenedMarker = try? String(
          contentsOf: original.appendingPathComponent("marker"), encoding: .utf8)
        reopened += 1
      }, report: { _ in reported += 1 })
  }
  #expect(reopened == 1 && reported == 1 && reopenedMarker == "old")
}

@Test func updateRelaunchFailureKeepsSuccessfulInstallAndNormalQuitFailureStaysClosed() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let original = root.appendingPathComponent("Installed/TinyStats.app")
  let staged = root.appendingPathComponent("Staged/TinyStats.app")
  for app in [original, staged] {
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  }
  try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
  var reported = 0
  try UpdateInstallRecovery.perform(
    relaunch: true,
    install: {
      try UpdateInstallTransaction.install(
        original: original, staged: staged,
        backup: root.appendingPathComponent("Previous.app"), pid: 42,
        files: NativeUpdateFileSystem(), waiter: UpdateFakeWaiter(), verify: {})
    }, reopen: { throw UpdateError.invalid("open timed out after launching") },
    report: { _ in reported += 1 })
  #expect(reported == 1)
  #expect(
    try String(contentsOf: original.appendingPathComponent("marker"), encoding: .utf8) == "new")
  var reopened = false
  #expect(throws: (any Error).self) {
    try UpdateInstallRecovery.perform(
      relaunch: false, install: { throw UpdateError.invalid("failed") },
      reopen: { reopened = true }, report: { _ in })
  }
  #expect(!reopened)
}

@Test func updateInstallAccessRequiresOwnedWritableBundleAndParent() {
  #expect(
    UpdateInstallAccess.allows(
      bundleWritable: true, parentWritable: true, owner: 501, user: 501, sameVolume: true))
  #expect(
    !UpdateInstallAccess.allows(
      bundleWritable: false, parentWritable: true, owner: 501, user: 501, sameVolume: true))
  #expect(
    !UpdateInstallAccess.allows(
      bundleWritable: true, parentWritable: false, owner: 501, user: 501, sameVolume: true))
  #expect(
    !UpdateInstallAccess.allows(
      bundleWritable: true, parentWritable: true, owner: 0, user: 501, sameVolume: true))
}

@Test func updateHTTPDistinguishesExpiredAssetsFromRateLimitsAndCapsBackoff() throws {
  let now = Date(timeIntervalSince1970: 1000)
  let headers = [
    "x-ratelimit-remaining": "0", "x-ratelimit-reset": "999999999999999",
    "retry-after": "999999999999999",
  ]
  let asset = URL(string: "https://release-assets.githubusercontent.com/asset")!
  #expect(
    UpdateHTTPPolicy.failure(
      status: 403, url: asset, headers: headers, length: 0, limit: 100, now: now)
      == .invalid("GitHub returned HTTP 403."))
  #expect(
    UpdateHTTPPolicy.failure(
      status: 403, url: UpdatePolicy.latestURL, headers: headers, length: 0, limit: 100, now: now)
      == .rateLimited(now.addingTimeInterval(86_400)))
  #expect(
    UpdateHTTPPolicy.failure(
      status: 403, url: UpdatePolicy.latestURL, headers: [:], length: 0, limit: 100, now: now)
      == .invalid("GitHub returned HTTP 403."))
  #expect(
    UpdateHTTPPolicy.failure(status: 429, url: asset, headers: [:], length: 0, limit: 100, now: now)
      == .rateLimited(now.addingTimeInterval(3600)))
  #expect(
    UpdateHTTPPolicy.failure(
      status: 200, url: asset, headers: [:], length: 101, limit: 100, now: now) != nil)
  #expect(
    UpdateHTTPPolicy.failure(
      status: 200, url: asset, headers: [:], length: -1, limit: 100, now: now) == nil)
}

private struct UpdateRecoveryFixture: UpdateRecoveryChecking {
  let verified: Bool
  let installedVersion: String
  let installedBuild: String
  func canDiscard(backup: URL) throws -> Bool {
    try UpdateRecoveryVersion.canDiscard(
      installedVersion: installedVersion,
      installedBuild: installedBuild, backupVersion: "0.37.5", backupBuild: "77",
      installedVerified: verified)
  }
}

@Test func updateStaleRecoveryDiscardsOnlyAuthenticEqualOrNewerInstalledApp() throws {
  for scenario in ["equal", "newer", "olderVersion", "olderBuild", "unverified", "malformed"] {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stale = root.appendingPathComponent("stale")
    let backup = stale.appendingPathComponent("Previous.app")
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    let recovery = UpdateRecoveryFixture(
      verified: scenario != "unverified",
      installedVersion: scenario == "olderVersion"
        ? "0.37.4"
        : scenario == "malformed" ? "invalid" : scenario == "equal" ? "0.37.5" : "0.37.6",
      installedBuild: scenario == "olderBuild" ? "76" : scenario == "equal" ? "77" : "78")
    let stager = UpdateStager(
      files: NativeUpdateFileSystem(), processes: UpdateFakeExtractor(),
      verifier: UpdateFakeVerifier(), recovery: recovery)
    let safe = scenario == "equal" || scenario == "newer"
    #expect(try stager.recoveryNeedsAttention(root: root) == !safe)
    let archive = updateZIP()
    let manifest = UpdateManifest(
      version: updateVersion, build: "78",
      sha256: UpdatePolicy.digest(archive), file: updateFilename)
    if safe {
      _ = try stager.prepare(
        archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
      #expect(!FileManager.default.fileExists(atPath: stale.path))
    } else {
      #expect(throws: UpdateError.needsAttention) {
        try stager.prepare(
          archive: archive, manifest: manifest, root: root, team: UpdatePolicy.teamID)
      }
      #expect(FileManager.default.fileExists(atPath: backup.path))
    }
  }
}

@Test func updateBackupCleanupFailureDoesNotFailCommittedInstall() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let original = root.appendingPathComponent("Installed/TinyStats.app")
  let staged = root.appendingPathComponent("Staged/TinyStats.app")
  let backup = root.appendingPathComponent("Previous.app")
  for app in [original, staged] {
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  }
  try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
  let files = UpdateFailingMoveFiles(
    staged: staged, original: original, failRestore: false,
    failStagedMove: false, failBackupRemoval: true)
  var reopened = false
  try UpdateInstallRecovery.perform(
    relaunch: true,
    install: {
      try UpdateInstallTransaction.install(
        original: original, staged: staged, backup: backup,
        pid: 42, files: files, waiter: UpdateFakeWaiter(), verify: {})
    }, reopen: { reopened = true }, report: { _ in Issue.record("Committed install must succeed") })
  #expect(reopened && FileManager.default.fileExists(atPath: backup.path))
  #expect(
    try String(contentsOf: original.appendingPathComponent("marker"), encoding: .utf8) == "new")
}

private final class UpdateRunningFixture: UpdateRunningApplicationChecking, @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Bool]
  private(set) var paths: [URL] = []
  init(_ results: [Bool]) { self.results = results }
  func isRunning(from original: URL) throws -> Bool {
    lock.withLock {
      paths.append(original)
      return results.removeFirst()
    }
  }
}

@Test func updateInstallRefusesReopenedOriginalAfterOneRetryAndRecovers() throws {
  for remainsRunning in [false, true] {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Installed/TinyStats.app")
    let staged = root.appendingPathComponent("Staged/TinyStats.app")
    let backup = root.appendingPathComponent("Previous.app")
    for app in [original, staged] {
      try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }
    try Data("old".utf8).write(to: original.appendingPathComponent("marker"))
    try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
    let checker = UpdateRunningFixture([true, remainsRunning])
    var delays = 0
    var reopened = 0
    let install = {
      try UpdateInstallRecovery.perform(
        relaunch: true,
        install: {
          try UpdateInstallTransaction.install(
            original: original, staged: staged, backup: backup,
            pid: 42, files: NativeUpdateFileSystem(), waiter: UpdateFakeWaiter(),
            verify: {
              try UpdateInstallQuiescence.requireIdle(
                original: original, checker: checker,
                retryDelay: { delays += 1 })
            })
        }, reopen: { reopened += 1 }, report: { _ in })
    }
    if remainsRunning { #expect(throws: (any Error).self) { try install() } } else { try install() }
    #expect(delays == 1 && reopened == 1 && checker.paths == [original, original])
    #expect(
      try String(contentsOf: original.appendingPathComponent("marker"), encoding: .utf8)
        == (remainsRunning ? "old" : "new"))
    #expect(!FileManager.default.fileExists(atPath: backup.path))
  }
  let idle = UpdateRunningFixture([false])
  try UpdateInstallQuiescence.requireIdle(
    original: URL(fileURLWithPath: "/fixture/TinyStats.app"),
    checker: idle, retryDelay: { Issue.record("An idle app needs no retry") })
}

@Test func updateStatusAndRateLimitDatesAlwaysUseEnglish() throws {
  let epoch = Date(timeIntervalSince1970: 0)
  #expect(UpdateText.checked(epoch, relativeTo: epoch.addingTimeInterval(7200)) == "2 hours ago")
  let utc = try #require(TimeZone(secondsFromGMT: 0))
  let date = UpdateText.date(epoch, timeZone: utc)
  #expect(date.hasPrefix("Jan 1, 1970") && date.contains("AM"))
  #expect(
    UpdateError.rateLimited(epoch).localizedDescription
      == "GitHub has limited requests. Try again after " + UpdateText.date(epoch) + ".")
}
