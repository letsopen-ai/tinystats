import AppKit
import CoreFoundation
import Security
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func updateDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + updateDescendants($0) }
}

@Test @MainActor func updateSettingsAndMenuReflectEligibilityPreferencesAndPreparedState() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { controller.close() }
  let view = controller.updatesView
  var state = UpdatePresentation(version: "0.37.5", build: "77", eligible: true, canInstall: true)
  view.update(state)
  #expect(view.check.state == .on && view.download.state == .on)
  #expect(view.download.isEnabled && view.restart.isHidden)
  state.preferences.automaticallyCheck = false
  view.update(state)
  #expect(!view.download.isEnabled && view.checkNow.isEnabled)
  state.readyVersion = "0.37.6"
  state.readyBuild = "78"
  view.update(state)
  #expect(view.status.stringValue == "TinyStats 0.37.5 (77) · 0.37.6 (78) ready")
  #expect(!view.restart.isHidden && view.restart.title == "Restart to Update")
  state.eligible = false
  state.canInstall = false
  view.update(state)
  #expect(!view.check.isEnabled && !view.download.isEnabled && view.checkNow.isEnabled)
  #expect(view.note.stringValue.contains("doesn’t receive updates"))
  #expect(view.restart.title == "Open Release Page")
  let app = AppDelegate()
  let menu = app.makeApplicationMenu()
  #expect(menu.items[0].title == "About TinyStats")
  #expect(menu.items[1].title == "Check for Updates…")
  #expect(menu.items[1].action != nil && menu.items[1].target === app)
  #expect(menu.items[2].isHidden)
}

@Test @MainActor func updateFooterExistsOnlyWhenPreparedAndHasHelpAndNoOpAction() throws {
  _ = NSApplication.shared
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.view.setFrameSize(SystemStyle.popoverSize)
  let button = try #require(
    updateDescendants(detail.view).compactMap { $0 as? MenuActionRow }.first {
      $0.title == "Restart to Update"
    })
  #expect(button.isHidden)
  var invoked = false
  detail.onRestartUpdate = { invoked = true }
  detail.updateReady = "0.37.6 (78)"
  detail.view.layoutSubtreeIfNeeded()
  #expect(!button.isHidden && button.toolTip == "Update 0.37.6 (78) ready — restart to install")
  #expect(button.accessibilityLabel() == "Restart to install TinyStats 0.37.6 (78)")
  #expect(button.usesIconPresentation && detail.view.bounds.contains(button.frame))
  for other in detail.view.subviews
  where other !== button && other is MenuActionRow && !other.isHidden {
    #expect(!other.frame.intersects(button.frame))
  }
  button.performClick(nil)
  #expect(invoked)
  detail.isPopoverPresentation = false
  #expect(button.isHidden)
}

private actor OfflineUpdateTransport: UpdateTransport {
  var calls = 0
  let available: Bool
  let rateLimit: Bool
  init(available: Bool = false, rateLimit: Bool = false) {
    self.available = available
    self.rateLimit = rateLimit
  }
  func get(_ url: URL, limit: Int) async throws -> Data {
    calls += 1
    if rateLimit { throw UpdateError.rateLimited(Date().addingTimeInterval(7200)) }
    if url == UpdatePolicy.latestURL {
      let names = ["release.json", "TinyStats-0.37.6-macOS-universal.zip"]
      return try JSONSerialization.data(withJSONObject: [
        "tag_name": "v0.37.6", "draft": false, "prerelease": false,
        "html_url": "https://github.com/letsopen-ai/tinystats/releases/tag/v0.37.6",
        "assets": names.map {
          [
            "name": $0, "size": 1000,
            "browser_download_url":
              "https://github.com/letsopen-ai/tinystats/releases/download/v0.37.6/\($0)",
          ]
        },
      ])
    }
    if url.lastPathComponent == "release.json" {
      return try JSONEncoder().encode(
        UpdateManifest(
          version: "0.37.6", build: available ? "78" : "76",
          sha256: String(repeating: "a", count: 64), file: "TinyStats-0.37.6-macOS-universal.zip"))
    }
    throw UpdateError.invalid("Offline fixture refuses downloads.")
  }
}
private struct UnusedUpdateProcess: UpdateProcessRunner {
  func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws {
    throw UpdateError.invalid("Unexpected process in offline UI test.")
  }
}
private struct UnusedUpdateVerifier: UpdateCodeVerifier {
  func verify(_ app: URL, manifest: UpdateManifest, runningTeam: String) throws {
    throw UpdateError.invalid("Unexpected signature check in offline UI test.")
  }
}
private struct NoOpUpdateInstaller: UpdateInstalling {
  func launch(_ update: PreparedUpdate, original: URL, pid: Int32, relaunch: Bool) throws {}
}
@MainActor private final class OfflineUpdateUI: UpdateUserInterface {
  var alerts: [String] = []
  var opened: [URL] = []
  var choice = 0
  func alert(title: String, message: String, buttons: [String]) -> Int {
    alerts.append(title)
    return choice
  }
  func open(_ url: URL) { opened.append(url) }
}
@MainActor private func offlineController(
  transport: any UpdateTransport, ui: OfflineUpdateUI, defaults: UserDefaults,
  eligible: Bool = true, canInstall: Bool = true
) -> UpdateController {
  .init(
    defaults: defaults, version: "0.37.5", build: "77",
    eligibility: .init(
      bundleID: UpdatePolicy.bundleID, teamID: UpdatePolicy.teamID, developerID: eligible,
      translocated: false, readOnly: false),
    original: URL(fileURLWithPath: "/tmp/UnusedTinyStats.app"), canInstall: canInstall,
    root: FileManager.default.temporaryDirectory.appendingPathComponent(
      "unused-update-test-\(UUID())"),
    client: UpdateClient(transport: transport),
    stager: UpdateStager(
      files: NativeUpdateFileSystem(), processes: UnusedUpdateProcess(),
      verifier: UnusedUpdateVerifier()),
    installer: NoOpUpdateInstaller(), ui: ui, now: Date(timeIntervalSince1970: 1000),
    launchDelay: 180)
}
@Test @MainActor func updateDevelopmentBuildNeverUsesTransportAndExplainsManualCheck() async throws
{
  let name = "TinyStats.UpdateUI.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let transport = OfflineUpdateTransport()
  let ui = OfflineUpdateUI()
  let updater = offlineController(transport: transport, ui: ui, defaults: defaults, eligible: false)
  updater.tick(now: Date(timeIntervalSince1970: 999_999), welcomeVisible: false)
  updater.check()
  await updater.waitForIdle()
  #expect(await transport.calls == 0)
  #expect(ui.alerts == ["This build doesn’t receive updates"])
  ui.choice = 1
  updater.check()
  #expect(ui.opened == [UpdatePolicy.releasesURL])
}
@Test @MainActor func updateManualAlertsAndRateLimitBackoffAreOffline() async throws {
  let name = "TinyStats.UpdateUI.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let ui = OfflineUpdateUI()
  let transport = OfflineUpdateTransport()
  let updater = offlineController(transport: transport, ui: ui, defaults: defaults)
  updater.setPreferences(check: false, download: false)
  updater.check()
  await updater.waitForIdle()
  #expect(ui.alerts == ["You’re up to date"])
  #expect(await transport.calls == 2)
  let limited = OfflineUpdateTransport(rateLimit: true)
  let controller = offlineController(transport: limited, ui: ui, defaults: defaults)
  controller.check()
  await controller.waitForIdle()
  controller.check()
  await controller.waitForIdle()
  #expect(await limited.calls == 1)
  #expect(ui.alerts.last == "Couldn’t check for updates")
  #expect(UpdatePreferences(defaults: defaults).retryAfter != nil)
}
@Test @MainActor func updateManualOfferRoutesLaterNotesAndUnwritableInstallsSafely() async throws {
  let name = "TinyStats.UpdateUI.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let ui = OfflineUpdateUI()
  let transport = OfflineUpdateTransport(available: true)
  let updater = offlineController(
    transport: transport, ui: ui, defaults: defaults, canInstall: false)
  for choice in [1, 2, 0] {
    ui.choice = choice
    updater.check()
    await updater.waitForIdle()
  }
  #expect(await transport.calls == 6)  // metadata only, never downloads or installs
  #expect(ui.alerts.allSatisfy { $0 == "TinyStats 0.37.6 (78) is available" })
  #expect(ui.opened.count == 2 && ui.opened.allSatisfy(UpdatePolicy.releasePage))
}

private actor PreparingUpdateTransport: UpdateTransport {
  var calls = 0
  func get(_ url: URL, limit: Int) async throws -> Data {
    calls += 1
    let name = "TinyStats-0.37.6-macOS-universal.zip"
    let archive = Data("offline archive; extraction injected".utf8)
    if url == UpdatePolicy.latestURL {
      return try JSONSerialization.data(withJSONObject: [
        "tag_name": "v0.37.6", "draft": false, "prerelease": false,
        "html_url": "https://github.com/letsopen-ai/tinystats/releases/tag/v0.37.6",
        "assets": ["release.json", name].map {
          [
            "name": $0, "size": 100,
            "browser_download_url":
              "https://github.com/letsopen-ai/tinystats/releases/download/v0.37.6/\($0)",
          ]
        },
      ])
    }
    if url.lastPathComponent == "release.json" {
      return try JSONEncoder().encode(
        UpdateManifest(
          version: "0.37.6", build: "78", sha256: UpdatePolicy.digest(archive), file: name))
    }
    if url.lastPathComponent == name { return archive }
    throw UpdateError.invalid("Unexpected offline request")
  }
}
private struct PreparingUpdateStager: UpdatePreparing {
  let files: any UpdateFileSystem = NativeUpdateFileSystem()
  func prepare(archive: Data, manifest: UpdateManifest, root: URL, team: String) throws
    -> PreparedUpdate
  {
    try files.createPrivateDirectory(root)
    return PreparedUpdate(manifest: manifest, directory: root)
  }
}
private final class RecordingUpdateInstaller: UpdateInstalling, @unchecked Sendable {
  private let lock = NSLock()
  private var launches: [Bool] = []
  var relaunches: [Bool] { lock.withLock { launches } }
  func launch(_ update: PreparedUpdate, original: URL, pid: Int32, relaunch: Bool) throws {
    lock.withLock { launches.append(relaunch) }
  }
}
@Test @MainActor func updatePreparedRestartAndNormalQuitUseOnlyInjectedInstaller() async throws {
  for mode in ["restart", "quit", "downloadOff", "checkOff"] {
    let name = "TinyStats.UpdateUI.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = RecordingUpdateInstaller()
    let ui = OfflineUpdateUI()
    let transport = PreparingUpdateTransport()
    let controller = UpdateController(
      defaults: defaults, version: "0.37.5", build: "77",
      eligibility: .init(
        bundleID: UpdatePolicy.bundleID, teamID: UpdatePolicy.teamID, developerID: true,
        translocated: false, readOnly: false),
      original: root.appendingPathComponent("Original.app"), canInstall: true, root: root,
      client: UpdateClient(transport: transport), stager: PreparingUpdateStager(),
      installer: installer, ui: ui,
      now: Date(timeIntervalSince1970: 1000), launchDelay: 180)
    controller.tick(now: Date(timeIntervalSince1970: 2000), welcomeVisible: true)
    #expect(await transport.calls == 0)
    controller.tick(now: Date(timeIntervalSince1970: 2000), welcomeVisible: false)
    await controller.waitForIdle()
    #expect(controller.presentation.readyVersion == "0.37.6" && controller.prepared != nil)
    #expect(ui.alerts.isEmpty && installer.relaunches.isEmpty)
    var terminated = false
    controller.terminate = { terminated = true }
    if mode == "restart" {
      controller.restart()
      await controller.waitForIdle()
      #expect(terminated && installer.relaunches == [true])
    } else {
      if mode == "downloadOff" { controller.setPreferences(check: true, download: false) }
      if mode == "checkOff" { controller.setPreferences(check: false, download: true) }
      await withCheckedContinuation { continuation in
        controller.prepareToQuit { continuation.resume() }
      }
      #expect(!terminated)
      #expect(installer.relaunches == (mode == "quit" ? [false] : []))
    }
  }
}

@Test func updateArchiveAcceptsExistingDittoReleaseFormatWithoutNetwork() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let app = root.appendingPathComponent("TinyStats.app")
  let contents = app.appendingPathComponent("Contents")
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  try Data("fixture".utf8).write(to: contents.appendingPathComponent("Info.plist"))
  let archive = root.appendingPathComponent("fixture.zip")
  try NativeUpdateProcess().run(
    "/usr/bin/ditto",
    arguments: ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", app.path, archive.path],
    timeout: 10)
  try UpdateArchiveLayout.validate(Data(contentsOf: archive))
}

@Test @MainActor func updateAutomaticFailuresStaySilentAndDisabledDownloadsNeverFetchArchives()
  async throws
{
  for rateLimited in [false, true] {
    let name = "TinyStats.UpdateUI.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = OfflineUpdateTransport(available: true, rateLimit: rateLimited)
    let ui = OfflineUpdateUI()
    let controller = offlineController(transport: transport, ui: ui, defaults: defaults)
    controller.setPreferences(check: true, download: false)
    controller.tick(now: Date(timeIntervalSince1970: 2000), welcomeVisible: false)
    await controller.waitForIdle()
    controller.tick(now: Date(timeIntervalSince1970: 3000), welcomeVisible: false)
    await controller.waitForIdle()
    #expect(ui.alerts.isEmpty && controller.prepared == nil)
    #expect(await transport.calls == (rateLimited ? 1 : 2))
    #expect(UpdatePreferences(defaults: defaults).lastCheck == Date(timeIntervalSince1970: 2000))
  }
}

@MainActor private final class UpdateModalQuitState {
  var replies = 0
}
@Test @MainActor func updateQuitInstallerCompletesInsideAppKitModalLoop() async throws {
  let name = "TinyStats.UpdateUI.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let installer = RecordingUpdateInstaller()
  let controller = UpdateController(
    defaults: defaults, version: "0.37.5", build: "77",
    eligibility: .init(
      bundleID: UpdatePolicy.bundleID, teamID: UpdatePolicy.teamID, developerID: true,
      translocated: false, readOnly: false),
    original: root.appendingPathComponent("Original.app"), canInstall: true, root: root,
    client: UpdateClient(transport: PreparingUpdateTransport()), stager: PreparingUpdateStager(),
    installer: installer, ui: OfflineUpdateUI(), now: Date(timeIntervalSince1970: 1000),
    launchDelay: 180)
  controller.tick(now: Date(timeIntervalSince1970: 2000), welcomeVisible: false)
  await controller.waitForIdle()
  #expect(controller.prepared != nil)
  let state = UpdateModalQuitState()
  controller.prepareToQuit {
    state.replies += 1
    CFRunLoopStop(CFRunLoopGetMain())
  }
  runHistoryTerminationMode { state.replies > 0 }
  #expect(state.replies == 1 && installer.relaunches == [false])
}

@Test func updateHelperPlanValidationRejectsWrongDirectoryDowngradeAndChangedInstalledIdentity()
  throws
{
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  let directory = root.appendingPathComponent("78", isDirectory: true)
  let manifest = UpdateManifest(
    version: "0.37.6", build: "78", sha256: String(repeating: "a", count: 64),
    file: "TinyStats-0.37.6-macOS-universal.zip")
  func plan(build: String = "77", version: String = "0.37.5") -> NativeUpdateInstaller.Plan {
    .init(
      original: root.appendingPathComponent("TinyStats.app"), directory: directory,
      manifest: manifest, pid: 42,
      relaunch: true, originalVersion: version, originalBuild: build, originalInode: 123)
  }
  let file = directory.appendingPathComponent("install.json")
  try plan().validate(root: root, planURL: file)
  try plan().validate(root: URL(fileURLWithPath: root.path + "/"), planURL: file)
  #expect(throws: (any Error).self) {
    try plan().validate(root: root.appendingPathComponent("wrong"), planURL: file)
  }
  #expect(throws: (any Error).self) { try plan(build: "79").validate(root: root, planURL: file) }
  #expect(throws: (any Error).self) {
    try plan(version: "0.38.0").validate(root: root, planURL: file)
  }
  try plan().validateInstalled(
    bundleID: UpdatePolicy.bundleID, version: "0.37.5", build: "77", inode: 123)
  #expect(throws: (any Error).self) {
    try plan().validateInstalled(
      bundleID: UpdatePolicy.bundleID, version: "0.37.5", build: "77", inode: 456)
  }
  #expect(throws: (any Error).self) {
    try plan().validateInstalled(
      bundleID: UpdatePolicy.bundleID, version: "0.37.5", build: "79", inode: 123)
  }
}

@Test func updateNativeWritabilityRejectsReadOnlyFixtureBundleAndRequirementsParseOffline() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  let app = root.appendingPathComponent("TinyStats.app")
  try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path)
    try? FileManager.default.removeItem(at: root)
  }
  #expect(NativeUpdateInstaller.writable(app))
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: app.path)
  #expect(!NativeUpdateInstaller.writable(app))
  for text in [NativeUpdateVerifier.requirement, "notarized"] {
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
    #expect(requirement != nil)
  }
}

@Test @MainActor func updateAlertEscapeCopyAndVersionPresentationAreConsistent() throws {
  _ = NSApplication.shared
  let alert = NativeUpdateUserInterface.makeAlert(
    title: "TinyStats 0.37.6 (78) is available",
    message: "Download it now? TinyStats restarts to finish installing.",
    buttons: ["Download & Restart", "Later", "Release Notes"])
  #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
  let state = UpdatePresentation(
    version: "0.37.5", build: "77", eligible: true, canInstall: true, readyVersion: "0.37.6",
    readyBuild: "78")
  #expect(
    state.status == "TinyStats 0.37.5 (77) · 0.37.6 (78) ready"
      && state.restartTitle == "Restart to Update 0.37.6 (78)")
  let view = UpdateSettingsView(frame: .zero)
  view.update(state)
  #expect(view.checkNow.isHidden && !view.restart.isHidden)
  #expect(!view.note.stringValue.contains("quit"))
}

private struct UpdateCancelledTransport: UpdateTransport {
  func get(_ url: URL, limit: Int) async throws -> Data { throw URLError(.cancelled) }
}
@Test @MainActor func updateURLSessionCancellationDoesNotShowAnErrorAlert() async throws {
  let name = "TinyStats.UpdateUI.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let ui = OfflineUpdateUI()
  let controller = offlineController(
    transport: UpdateCancelledTransport(), ui: ui, defaults: defaults)
  controller.check()
  await controller.waitForIdle()
  #expect(ui.alerts.isEmpty && !controller.presentation.busy)
}

@Test @MainActor func updateDisablingAutomaticDownloadsPreservesExplicitDownloadAndRestart()
  async throws
{
  let name = "TinyStats.UpdateUI.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let installer = RecordingUpdateInstaller()
  let controller = UpdateController(
    defaults: defaults, version: "0.37.5", build: "77",
    eligibility: .init(
      bundleID: UpdatePolicy.bundleID, teamID: UpdatePolicy.teamID, developerID: true,
      translocated: false, readOnly: false),
    original: root.appendingPathComponent("Original.app"), canInstall: true, root: root,
    client: UpdateClient(transport: PreparingUpdateTransport()), stager: PreparingUpdateStager(),
    installer: installer, ui: OfflineUpdateUI())
  var terminated = false
  controller.terminate = { terminated = true }
  controller.check()
  controller.setPreferences(check: true, download: false)
  await controller.waitForIdle()
  #expect(terminated && installer.relaunches == [true])
}
