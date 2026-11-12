import AppKit
import OSLog
import TinyStatsCore

struct UpdatePresentation: Equatable {
  var preferences = UpdatePreferences()
  var version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  var build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
  var eligible = false
  var canInstall = false
  var busy = false
  var readyVersion: String?
  var readyBuild: String?
  var status: String {
    if let readyIdentifier { return "TinyStats \(version) (\(build)) · \(readyIdentifier) ready" }
    if busy { return "Checking for updates…" }
    let checked =
      preferences.lastCheck.map {
        " · Checked \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))"
      } ?? ""
    return "TinyStats \(version) (\(build))\(checked)"
  }
  var readyIdentifier: String? {
    guard let readyVersion, let readyBuild else { return nil }
    return "\(readyVersion) (\(readyBuild))"
  }
  var restartTitle: String { "Restart to Update \(readyIdentifier ?? "")" }
}

@MainActor protocol UpdateUserInterface: AnyObject {
  func alert(title: String, message: String, buttons: [String]) -> Int
  func open(_ url: URL)
}
@MainActor final class NativeUpdateUserInterface: UpdateUserInterface {
  static func makeAlert(title: String, message: String, buttons: [String]) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.icon = NSApp.applicationIconImage
    for title in buttons {
      let button = alert.addButton(withTitle: title)
      if title == "Later" { button.keyEquivalent = "\u{1b}" }
    }
    return alert
  }
  func alert(title: String, message: String, buttons: [String]) -> Int {
    NSApp.activate(ignoringOtherApps: true)
    return Self.makeAlert(title: title, message: message, buttons: buttons).runModal().rawValue
      - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
  }
  func open(_ url: URL) {
    guard url == UpdatePolicy.releasesURL || UpdatePolicy.releasePage(url) else { return }
    NSWorkspace.shared.open(url)
  }
}

private final class UpdateStagingCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  var isCancelled: Bool { lock.withLock { cancelled } }
}

@MainActor final class UpdateController {
  private let defaults: UserDefaults
  private let client: UpdateClient
  private let stager: any UpdatePreparing
  private let installer: any UpdateInstalling
  private let ui: any UpdateUserInterface
  private let original: URL
  private let root: URL
  private let launchDate: Date
  private let launchDelay: TimeInterval
  private let runningTeam: String
  private var manualOperation = false
  private let logger = Logger(subsystem: UpdatePolicy.bundleID, category: "Updates")
  private var task: Task<Void, Never>?
  private(set) var prepared: PreparedUpdate?
  private var quitting = false
  private var helperLaunched = false
  private var installationInFlight = false
  private var installationWaiters: [CheckedContinuation<Void, Never>] = []
  private var pendingQuit: (@MainActor @Sendable () -> Void)?
  private let stagingGroup = DispatchGroup()
  private var stagingCancellation: UpdateStagingCancellation?
  var onChange: ((UpdatePresentation) -> Void)?
  var terminate: () -> Void = { NSApp.terminate(nil) }
  private(set) var presentation: UpdatePresentation
  init(
    defaults: UserDefaults, version: String, build: String, eligibility: UpdateEligibility,
    original: URL, canInstall: Bool, root: URL, client: UpdateClient, stager: any UpdatePreparing,
    installer: any UpdateInstalling, ui: any UpdateUserInterface,
    now: Date = Date(), launchDelay: TimeInterval = Double.random(in: 180...420)
  ) {
    self.defaults = defaults
    self.client = client
    self.stager = stager
    self.installer = installer
    self.ui = ui
    self.original = original
    self.root = root
    launchDate = now
    self.launchDelay = launchDelay
    runningTeam = eligibility.teamID ?? ""
    presentation = .init(
      preferences: .init(defaults: defaults), version: version, build: build,
      eligible: eligibility.eligible, canInstall: canInstall)
  }
  static func live(defaults: UserDefaults, bundle: Bundle = .main) -> UpdateController {
    let version =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    var eligibility = NativeUpdateVerifier.eligibility(bundle: bundle)
    // Diagnostics/previews and isolated preference profiles never authorize network activity.
    if ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"] != nil
      || CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") })
    {
      eligibility.developerID = false
    }
    let files = NativeUpdateFileSystem()
    return .init(
      defaults: defaults, version: version, build: build, eligibility: eligibility,
      original: bundle.bundleURL, canInstall: NativeUpdateInstaller.writable(bundle.bundleURL),
      root: NativeUpdateInstaller.root,
      client: UpdateClient(transport: NativeUpdateTransport(version: version)),
      stager: UpdateStager(
        files: files, processes: NativeUpdateProcess(), verifier: NativeUpdateVerifier()),
      installer: NativeUpdateInstaller(), ui: NativeUpdateUserInterface())
  }
  func setPreferences(check: Bool, download: Bool) {
    presentation.preferences.automaticallyCheck = check
    presentation.preferences.automaticallyDownload = download
    presentation.preferences.save(to: defaults)
    if !check || (!download && !manualOperation) {
      task?.cancel()
      stagingCancellation?.cancel()
    }
    changed()
  }
  func tick(now: Date = Date(), welcomeVisible: Bool) {
    guard !quitting, presentation.eligible, !presentation.busy, prepared == nil,
      presentation.preferences.due(
        now: now, launch: launchDate, delay: launchDelay, welcomeVisible: welcomeVisible)
    else { return }
    check(manual: false, now: now)
  }
  func check(manual: Bool = true, now: Date = Date()) {
    guard !quitting else { return }
    guard presentation.eligible else {
      if manual,
        ui.alert(
          title: "This build doesn’t receive updates",
          message:
            "Development and ad-hoc builds do not check for updates. Install a signed TinyStats release to receive automatic updates.",
          buttons: ["OK", "Open Release Page"]) == 1
      {
        ui.open(UpdatePolicy.releasesURL)
      }
      return
    }
    guard !presentation.busy else { return }
    if let prepared {
      if manual
        && ui.alert(
          title: "TinyStats \(prepared.manifest.version) (\(prepared.manifest.build)) is ready",
          message: "The update is downloaded and verified. Restart to install it.",
          buttons: [presentation.canInstall ? "Restart to Update" : "Open Release Page", "Later"])
          == 0
      {
        restart()
      }
      return
    }
    if let retry = presentation.preferences.retryAfter, now < retry {
      if manual { showError(UpdateError.rateLimited(retry)) }
      return
    }
    manualOperation = manual
    presentation.busy = true
    presentation.preferences.lastCheck = now
    presentation.preferences.save(to: defaults)
    changed()
    task = Task { [weak self] in
      guard let self else { return }
      var requestedRestart = false
      defer {
        self.presentation.busy = false
        self.manualOperation = false
        self.task = nil
        self.changed()
        if requestedRestart && !self.quitting { self.restart() }
      }
      do {
        let candidate = try await client.check(
          version: presentation.version, build: presentation.build)
        try Task.checkCancellation()
        guard let candidate else {
          if manual {
            _ = ui.alert(
              title: "You’re up to date",
              message: "TinyStats \(presentation.version) is the latest version.", buttons: ["OK"])
          }
          return
        }
        var restart = false
        if manual {
          let choice = ui.alert(
            title:
              "TinyStats \(candidate.manifest.version) (\(candidate.manifest.build)) is available",
            message: presentation.canInstall
              ? "Download it now? TinyStats restarts to finish installing."
              : "This location cannot be updated automatically. Open the release page to install this version.",
            buttons: [
              presentation.canInstall ? "Download & Restart" : "Open Release Page", "Later",
              "Release Notes",
            ])
          if choice == 2 {
            ui.open(candidate.releaseURL)
            return
          }
          guard choice == 0 else { return }
          guard presentation.canInstall else {
            ui.open(candidate.releaseURL)
            return
          }
          restart = true
        } else if !presentation.preferences.automaticallyDownload || !presentation.canInstall {
          return
        }
        let archive = try await client.download(candidate)
        try Task.checkCancellation()
        let stager = self.stager
        let root = self.root
        let team = self.runningTeam
        let cancellation = UpdateStagingCancellation()
        stagingCancellation = cancellation
        let group = stagingGroup
        group.enter()
        let update = try await Task.detached(priority: .utility) {
          defer { group.leave() }
          let result = try stager.prepare(
            archive: archive, manifest: candidate.manifest, root: root, team: team)
          if cancellation.isCancelled {
            try? stager.files.remove(result.directory)
            throw CancellationError()
          }
          return result
        }.value
        stagingCancellation = nil
        if Task.isCancelled || quitting {
          try? stager.files.remove(update.directory)
          return
        }
        prepared = update
        presentation.readyVersion = update.manifest.version
        presentation.readyBuild = update.manifest.build
        requestedRestart = restart
      } catch is CancellationError {
        // User disabled checks or the app is quitting.
      } catch let error as URLError where error.code == .cancelled {
        // URLSession cancellation is also a deliberate user action.
      } catch {
        if case UpdateError.rateLimited(let date) = error {
          presentation.preferences.retryAfter = date
          presentation.preferences.save(to: defaults)
        }
        logger.error("Update request failed: \(error.localizedDescription, privacy: .public)")
        if manual && !quitting { showError(error) }
      }
    }
  }
  func restart() {
    guard let prepared, !helperLaunched, !presentation.busy else { return }
    guard presentation.canInstall else {
      ui.open(UpdatePolicy.releasesURL)
      return
    }
    launchInstaller(prepared, relaunch: true)
  }
  private func launchInstaller(_ update: PreparedUpdate, relaunch: Bool) {
    presentation.busy = true
    installationInFlight = true
    changed()
    let installer = self.installer
    let original = self.original
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = Result {
        try installer.launch(
          update, original: original,
          pid: ProcessInfo.processInfo.processIdentifier, relaunch: relaunch)
      }
      HistoryQuitCoordinator.deliver { [weak self] in
        guard let self else { return }
        self.installationInFlight = false
        self.presentation.busy = false
        switch result {
        case .success: self.helperLaunched = true
        case .failure(let error):
          self.discardPrepared()
          self.logger.error(
            "Update installation preparation failed: \(error.localizedDescription, privacy: .public)"
          )
          if !self.quitting { self.showError(error) }
        }
        self.changed()
        let waiters = self.installationWaiters
        self.installationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let completion = self.pendingQuit
        self.pendingQuit = nil
        completion?()
        if case .success = result, relaunch, !self.quitting { self.terminate() }
      }
    }
  }
  /// AppKit's termination loop may suspend the main dispatch queue. Wait only on
  /// worker-owned staging, and deliver through the common/modal main run loop.
  func prepareToQuit(completion: @escaping @MainActor @Sendable () -> Void) {
    quitting = true
    task?.cancel()
    stagingCancellation?.cancel()
    if installationInFlight {
      pendingQuit = completion
      return
    }
    let group = stagingGroup
    DispatchQueue.global(qos: .utility).async { [weak self] in
      group.wait()
      HistoryQuitCoordinator.deliver { [weak self] in
        guard let self else {
          completion()
          return
        }
        guard let prepared = self.prepared, !self.helperLaunched,
          self.presentation.preferences.automaticallyCheck,
          self.presentation.preferences.automaticallyDownload, self.presentation.canInstall
        else {
          completion()
          return
        }
        self.pendingQuit = completion
        self.launchInstaller(prepared, relaunch: false)
      }
    }
  }
  func waitForIdle() async {
    while let active = task { await active.value }
    if installationInFlight {
      await withCheckedContinuation { installationWaiters.append($0) }
    }
  }
  private func discardPrepared() {
    if let prepared { try? stager.files.remove(prepared.directory) }
    prepared = nil
    presentation.readyVersion = nil
    presentation.readyBuild = nil
  }
  private func changed() { onChange?(presentation) }
  private func showError(_ error: any Error) {
    _ = ui.alert(
      title: "Couldn’t check for updates", message: error.localizedDescription, buttons: ["OK"])
  }
}
