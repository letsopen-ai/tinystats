import AppKit
import Darwin
import Foundation
import OSLog
import Security
import TinyStatsCore

struct NativeUpdateProcess: UpdateProcessRunner {
  func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    try process.run()
    guard done.wait(timeout: .now() + timeout) == .success else {
      process.terminate()
      // Never leave ditto writing while failure cleanup removes staging.
      if done.wait(timeout: .now() + 2) != .success {
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = done.wait(timeout: .now() + 2)
      }
      throw UpdateError.invalid("The update verification command timed out.")
    }
    guard process.terminationStatus == 0 else {
      throw UpdateError.invalid(
        "The update failed \(URL(fileURLWithPath: executable).lastPathComponent) verification.")
    }
  }
}

struct NativeUpdateVerifier: UpdateCodeVerifier {
  static let requirement =
    "identifier \"com.niechen.tinystats\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"CVQJTDR4LG\""
  let processes: any UpdateProcessRunner
  init(processes: any UpdateProcessRunner = NativeUpdateProcess()) { self.processes = processes }
  static func code(_ app: URL) throws -> SecStaticCode {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
      throw UpdateError.invalid("The update has no valid code signature.")
    }
    return code
  }
  static func check(_ code: SecStaticCode, requirement text: String) throws {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw UpdateError.invalid("Could not create the update signature requirement.") }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    else {
      throw UpdateError.invalid("The update signature or notarization could not be verified.")
    }
  }
  static func team(_ code: SecStaticCode) throws -> String {
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let values = info as? [String: Any],
      let team = values[kSecCodeInfoTeamIdentifier as String] as? String
    else {
      throw UpdateError.invalid("The app has no Developer ID signing team.")
    }
    return team
  }
  func verify(_ app: URL, manifest: UpdateManifest, runningTeam: String) throws {
    try manifest.validate()
    try NativeUpdateFileSystem().validateBundleTree(app)
    let code = try Self.code(app)
    try Self.check(code, requirement: Self.requirement)
    guard try Self.team(code) == runningTeam, runningTeam == UpdatePolicy.teamID else {
      throw UpdateError.invalid("The update signing team does not match TinyStats.")
    }
    try Self.check(code, requirement: "notarized")
    let plistURL = app.appendingPathComponent("Contents/Info.plist")
    let attributes = try FileManager.default.attributesOfItem(atPath: plistURL.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= UpdatePolicy.jsonLimit else {
      throw UpdateError.invalid("The update Info.plist is too large.")
    }
    let data = try Data(contentsOf: plistURL, options: .mappedIfSafe)
    guard data.count <= UpdatePolicy.jsonLimit,
      let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      info["CFBundleIdentifier"] as? String == UpdatePolicy.bundleID,
      info["CFBundleShortVersionString"] as? String == manifest.version,
      info["CFBundleVersion"] as? String == manifest.build
    else {
      throw UpdateError.invalid("The update bundle does not match release.json.")
    }
    try processes.run(
      "/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", app.path], timeout: 45)
  }
  static func eligibility(bundle: Bundle) -> UpdateEligibility {
    let app = bundle.bundleURL
    let code = try? code(app)
    let team = code.flatMap { try? self.team($0) }
    let developerID =
      code.map {
        (try? check($0, requirement: requirement)) != nil
          && (try? check($0, requirement: "notarized")) != nil
      } ?? false
    let readOnly =
      (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true
    return .init(
      bundleID: bundle.bundleIdentifier, teamID: team, developerID: developerID,
      translocated: app.pathComponents.contains("AppTranslocation"), readOnly: readOnly)
  }
}

struct NativeUpdateWaiter: UpdateExitWaiter {
  func waitForExit(pid: Int32, timeout: TimeInterval) throws {
    guard pid > 1, pid != getpid() else {
      throw UpdateError.invalid("Invalid updater process identity.")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while kill(pid, 0) == 0 || errno != ESRCH {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw UpdateError.invalid("TinyStats did not quit before the update deadline.")
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
  }
}

protocol UpdateInstalling: Sendable {
  func launch(_ update: PreparedUpdate, original: URL, pid: Int32, relaunch: Bool) throws
}

struct NativeUpdateInstaller: UpdateInstalling {
  struct Plan: Codable {
    let original: URL
    let directory: URL
    let manifest: UpdateManifest
    let pid: Int32
    let relaunch: Bool
    let originalVersion: String
    let originalBuild: String
    let originalInode: UInt64
    func validate(root: URL, planURL: URL) throws {
      let path = directory.standardizedFileURL
      guard path.deletingLastPathComponent().path == root.standardizedFileURL.path,
        path.path == path.resolvingSymlinksInPath().path,
        planURL.standardizedFileURL.path == path.appendingPathComponent("install.json").path,
        original.standardizedFileURL.path == original.resolvingSymlinksInPath().path,
        original.pathExtension == "app", originalInode != 0, pid > 1,
        try UpdatePolicy.build(manifest.build) > UpdatePolicy.build(originalBuild),
        try UpdateVersion(manifest.version) > UpdateVersion(originalVersion)
      else { throw UpdateError.invalid("Invalid update installation plan.") }
      try manifest.validate()
    }
    func validateInstalled(bundleID: String?, version: String?, build: String?, inode: UInt64?)
      throws
    {
      guard bundleID == UpdatePolicy.bundleID, version == originalVersion,
        build == originalBuild, inode == originalInode
      else {
        throw UpdateError.invalid("The original app changed before installation.")
      }
    }
  }
  static var root: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(UpdatePolicy.bundleID).appendingPathComponent("Updates")
  }
  static func writable(_ original: URL, cacheRoot: URL = root) -> Bool {
    let parent = original.deletingLastPathComponent()
    var cacheParent = cacheRoot
    while !FileManager.default.fileExists(atPath: cacheParent.path), cacheParent.path != "/" {
      cacheParent.deleteLastPathComponent()
    }
    guard original.standardizedFileURL.path == original.resolvingSymlinksInPath().path,
      let owner = try? FileManager.default.attributesOfItem(atPath: original.path)[.ownerAccountID]
        as? NSNumber,
      FileManager.default.isWritableFile(atPath: parent.path),
      let appVolume = try? FileManager.default.attributesOfItem(atPath: parent.path)[.systemNumber]
        as? NSNumber,
      let cacheVolume = try? FileManager.default.attributesOfItem(atPath: cacheParent.path)[
        .systemNumber] as? NSNumber
    else { return false }
    return UpdateInstallAccess.allows(
      bundleWritable: FileManager.default.isWritableFile(atPath: original.path),
      parentWritable: FileManager.default.isWritableFile(atPath: parent.path),
      owner: owner.uint32Value, user: getuid(), sameVolume: appVolume == cacheVolume)
  }
  func launch(_ update: PreparedUpdate, original: URL, pid: Int32, relaunch: Bool) throws {
    guard Self.writable(original), let bundle = Bundle(url: original),
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      let executable = bundle.executableURL
    else { throw UpdateError.invalid("Open the release page to install this update.") }
    let runningTeam = try NativeUpdateVerifier.team(NativeUpdateVerifier.code(original))
    try NativeUpdateVerifier().verify(
      update.app, manifest: update.manifest, runningTeam: runningTeam)
    let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
    let plan = Plan(
      original: original, directory: update.directory, manifest: update.manifest, pid: pid,
      relaunch: relaunch, originalVersion: version, originalBuild: build,
      originalInode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    let planURL = update.directory.appendingPathComponent("install.json")
    let files = NativeUpdateFileSystem()
    try? files.remove(planURL)
    try files.write(JSONEncoder().encode(plan), to: planURL)
    // Use the original signed bundle executable, preserving its bundle identity
    // and quarantine/launch context. The running image survives bundle renames.
    try UpdateHelperLaunch.start(
      executable: executable,
      arguments: ["--install-update", planURL.path, String(pid), relaunch ? "1" : "0"],
      spawner: NativeUpdateHelperSpawner())
  }
  static func runHelper(planURL: URL, parentPID: Int32, relaunch: Bool) throws {
    let files = NativeUpdateFileSystem()
    // Recovery never relies on a decoded (possibly corrupt) plan for its target.
    let original = Bundle.main.bundleURL.standardizedFileURL
    let directory = planURL.deletingLastPathComponent().standardizedFileURL
    let safeDirectory =
      directory.deletingLastPathComponent().path == root.standardizedFileURL.path
      && directory.path == directory.resolvingSymlinksInPath().path
      && planURL.lastPathComponent == "install.json"
    let verifier = NativeUpdateVerifier()
    var succeeded = false
    defer {
      if safeDirectory && !succeeded
        && !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("Previous.app").path)
      {
        try? files.remove(directory)
      }
    }
    let logger = Logger(subsystem: UpdatePolicy.bundleID, category: "UpdateHelper")
    try UpdateHelperLifecycle.perform(
      relaunch: relaunch,
      recoverOnFailure: { kill(parentPID, 0) < 0 && errno == ESRCH },
      load: {
        guard safeDirectory, parentPID > 1, parentPID != getpid(),
          let size = try FileManager.default.attributesOfItem(atPath: planURL.path)[.size]
            as? NSNumber,
          size.intValue <= UpdatePolicy.jsonLimit
        else { throw UpdateError.invalid("Invalid update installation plan location.") }
        return try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
      },
      validate: { plan in
        try plan.validate(root: root, planURL: planURL)
        guard plan.original.standardizedFileURL.path == original.path,
          plan.pid == parentPID, plan.relaunch == relaunch
        else { throw UpdateError.invalid("The update helper identity does not match its plan.") }
      },
      signalReady: { try NativeUpdateHelperSpawner.signalReady() },
      install: { plan in
        let prepared = PreparedUpdate(manifest: plan.manifest, directory: directory)
        try UpdateInstallTransaction.install(
          original: plan.original, staged: prepared.app,
          backup: directory.appendingPathComponent("Previous.app"), pid: plan.pid,
          files: files, waiter: NativeUpdateWaiter(),
          verify: {
            let attributes = try FileManager.default.attributesOfItem(atPath: plan.original.path)
            let installed = Bundle(url: plan.original)
            try plan.validateInstalled(
              bundleID: installed?.bundleIdentifier,
              version: installed?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
              build: installed?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
            guard writable(plan.original) else {
              throw UpdateError.invalid("The app location is not writable.")
            }
            let originalCode = try NativeUpdateVerifier.code(plan.original)
            try NativeUpdateVerifier.check(
              originalCode, requirement: NativeUpdateVerifier.requirement)
            let team = try NativeUpdateVerifier.team(originalCode)
            try verifier.verify(prepared.app, manifest: plan.manifest, runningTeam: team)
          })
      },
      reopen: {
        // Also reopen the restored/untouched app after a failed restart installation.
        // Refuse to open an unrelated or corrupted replacement at that path.
        try NativeUpdateVerifier.check(
          NativeUpdateVerifier.code(original), requirement: NativeUpdateVerifier.requirement)
        try NativeUpdateProcess().run("/usr/bin/open", arguments: [original.path], timeout: 15)
      },
      report: { error in
        logger.updateFailure("Update helper failed", error: error)
      })
    succeeded = true
    try? files.remove(directory)
  }
}

/// A recovery backup is disposable only after authenticating the installed app
/// and comparing trusted versions. Any uncertainty preserves it for inspection.
struct NativeUpdateRecoveryChecker: UpdateRecoveryChecking {
  let original: URL
  func canDiscard(backup: URL) throws -> Bool {
    func identity(_ app: URL) throws -> (String, String) {
      let code = try NativeUpdateVerifier.code(app)
      try NativeUpdateVerifier.check(code, requirement: NativeUpdateVerifier.requirement)
      guard try NativeUpdateVerifier.team(code) == UpdatePolicy.teamID else {
        throw UpdateError.needsAttention
      }
      try NativeUpdateVerifier.check(code, requirement: "notarized")
      guard let bundle = Bundle(url: app), bundle.bundleIdentifier == UpdatePolicy.bundleID,
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      else { throw UpdateError.needsAttention }
      return (version, build)
    }
    let installed = try identity(original)
    let previous = try identity(backup)
    return try UpdateRecoveryVersion.canDiscard(
      installedVersion: installed.0,
      installedBuild: installed.1, backupVersion: previous.0, backupBuild: previous.1,
      installedVerified: true)
  }
}
