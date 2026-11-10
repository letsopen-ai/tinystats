import AppKit
import TinyStatsCore

/// Unprivileged, on-demand reading of macOS's per-source energy settings.
protocol EnergyModeReader: Sendable {
  func read() -> EnergyModeReading
}

/// Outcome of one explicit, user-initiated energy-mode change.
enum EnergyModeApplyResult: Equatable, Sendable {
  case applied, cancelled, failed
}

/// Changes a per-source macOS energy setting. Implementations must only be invoked from an
/// explicit user click; rendering, launch and refresh paths never call this.
@MainActor protocol EnergyModeApplying: AnyObject {
  func apply(
    arguments: [String], completion: @escaping @MainActor (EnergyModeApplyResult) -> Void)
}

/// One bounded child process run: fixed absolute executable, fixed argument vector, no shell.
enum BoundedProcess {
  struct Output: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
  }

  static func run(
    _ executable: String, _ arguments: [String], timeout: Double, maximumBytes: Int = 64 * 1024
  ) -> Output? {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch { return nil }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = done.wait(timeout: .now() + 1)
      return nil
    }
    func text(_ pipe: Pipe) -> String {
      let data = (try? pipe.fileHandleForReading.read(upToCount: maximumBytes + 1)) ?? nil
      guard let data, data.count <= maximumBytes else { return "" }
      return String(decoding: data, as: UTF8.self)
    }
    return .init(status: process.terminationStatus, stdout: text(out), stderr: text(err))
  }
}

/// Reads `pmset -g custom` and `pmset -g cap`. Read-only: `-g` never changes settings.
struct PMSetEnergyModeReader: EnergyModeReader {
  var run: @Sendable (String, [String]) -> BoundedProcess.Output? = {
    BoundedProcess.run($0, $1, timeout: 2)
  }
  func read() -> EnergyModeReading {
    guard let custom = run(EnergyModeCommand.executable, ["-g", "custom"]), custom.status == 0,
      let capabilities = run(EnergyModeCommand.executable, ["-g", "cap"]), capabilities.status == 0
    else { return .unavailable }
    return EnergyModeParser.parse(custom: custom.stdout, capabilities: capabilities.stdout)
  }
}

/// Per-change system administrator prompt for one whitelisted `/usr/bin/pmset` vector.
/// `osascript` runs off the main thread so the menu bar stays responsive during the prompt.
/// The script text is assembled only from `EnergyModeCommand.allowedTokens`.
@MainActor final class AdministratorEnergyModeApplier: EnergyModeApplying {
  private let queue = DispatchQueue(label: "app.tinystats.energy-mode", qos: .userInitiated)
  nonisolated static func script(for arguments: [String]) -> String? {
    guard EnergyModeCommand.isAllowed(arguments) else { return nil }
    let command = ([EnergyModeCommand.executable] + arguments).joined(separator: " ")
    return "do shell script \"\(command)\" with administrator privileges"
  }
  nonisolated static func result(_ output: BoundedProcess.Output?) -> EnergyModeApplyResult {
    guard let output else { return .failed }
    if output.status == 0 { return .applied }
    // AppleScript reports a dismissed authorization dialog as error -128.
    return output.stderr.contains("-128") ? .cancelled : .failed
  }
  func apply(
    arguments: [String], completion: @escaping @MainActor (EnergyModeApplyResult) -> Void
  ) {
    guard let script = Self.script(for: arguments) else {
      completion(.failed)
      return
    }
    queue.async {
      // Generous bound: the person may take a while to read the system prompt.
      let output = BoundedProcess.run("/usr/bin/osascript", ["-e", script], timeout: 300)
      let result = Self.result(output)
      Task { @MainActor in completion(result) }
    }
  }
}

/// Presentation of the dropdown's Energy Mode section. Pure value; no side effects.
struct EnergyModePresentation: Equatable {
  struct Row: Equatable {
    var source: PowerSourceKind
    var modes: [EnergyMode]
    var selected: EnergyMode?
    var isCurrentSource: Bool
  }
  var rows: [Row]
  var busy: Bool
  var message: String?
  var showsFallback: Bool
  static let hidden = EnergyModePresentation(
    rows: [], busy: false, message: nil, showsFallback: false)
  var isVisible: Bool { !rows.isEmpty || showsFallback }
}

/// Owns the on-demand reading and the explicit change flow. Main actor; no timers.
@MainActor final class EnergyModeController {
  static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
  static let messageLifetime: Double = 120
  private let reader: any EnergyModeReader
  private let applier: any EnergyModeApplying
  /// Where the unprivileged read runs; the app points this at the sampler's serial queue.
  var schedule: (@escaping @Sendable () -> Void) -> Void
  private let openURL: (URL) -> Void
  private let uptime: () -> Double
  private(set) var reading: EnergyModeReading?
  /// The requested change: shown while approval is pending and, after success, until the
  /// reconciling read lands.
  private(set) var pending: (source: PowerSourceKind, mode: EnergyMode)?
  private(set) var isAwaitingApproval = false
  /// A change just finished; controls stay busy until a read started after it completes.
  private(set) var isReconciling = false
  private(set) var isReading = false
  /// Bumped whenever earlier reads must not be trusted (a change started or finished).
  private var readGeneration = 0
  private var message: (text: String, fallback: Bool, at: Double)?
  var onChange: (() -> Void)?

  init(
    reader: any EnergyModeReader = PMSetEnergyModeReader(),
    applier: any EnergyModeApplying = AdministratorEnergyModeApplier(),
    schedule: @escaping (@escaping @Sendable () -> Void) -> Void = {
      DispatchQueue.global(qos: .utility).async(execute: $0)
    },
    openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
    uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.reader = reader
    self.applier = applier
    self.schedule = schedule
    self.openURL = openURL
    self.uptime = uptime
  }

  var isBusy: Bool { isAwaitingApproval || isReconciling }

  /// One read per call (dropdown opened on Power). Coalesces overlap; while a change is in
  /// flight the reconciling read after it is the only one that counts.
  func refresh() {
    guard !isReading, !isBusy else { return }
    startRead()
  }

  private func startRead() {
    readGeneration &+= 1
    let generation = readGeneration
    isReading = true
    let reader = reader
    schedule { [weak self] in
      let value = reader.read()
      Task { @MainActor in self?.finishRead(value, generation: generation) }
    }
  }

  private func finishRead(_ value: EnergyModeReading, generation: Int) {
    // A read that started before the latest change began or finished is stale.
    guard generation == readGeneration else { return }
    isReading = false
    isReconciling = false
    pending = nil
    reading = value
    onChange?()
  }

  /// Explicit user action only. Unsupported or unchanged choices do nothing.
  func select(_ mode: EnergyMode, for source: PowerSourceKind) {
    guard !isBusy, case .available(let status) = reading,
      status.sources.contains(source), status.modes[source] != mode,
      let arguments = EnergyModeCommand.arguments(
        mode: mode, source: source, layout: status.layout)
    else {
      onChange?()
      return
    }
    // Invalidate any read already in flight: it may predate the change.
    readGeneration &+= 1
    isReading = false
    pending = (source, mode)
    isAwaitingApproval = true
    message = nil
    onChange?()
    applier.apply(arguments: arguments) { [weak self] result in self?.finishApply(result) }
  }

  private func finishApply(_ result: EnergyModeApplyResult) {
    isAwaitingApproval = false
    switch result {
    case .applied: message = nil
    case .cancelled: message = ("Energy mode unchanged", true, uptime())
    case .failed: message = ("Couldn't change energy mode", true, uptime())
    }
    // Success keeps showing the requested mode until macOS's stored value is read back;
    // cancel/failure shows the last known value right away.
    if result != .applied { pending = nil }
    isReconciling = true
    onChange?()
    // Always a fresh read that starts after the change, superseding any older one.
    startRead()
  }

  func openEnergySettings() { openURL(Self.settingsURL) }

  func presentation(currentSource: PowerSourceKind) -> EnergyModePresentation {
    let now = uptime()
    let note = message.flatMap { now - $0.at <= Self.messageLifetime ? $0 : nil }
    switch reading {
    case nil, .unsupported?: return .hidden
    case .unavailable?:
      return .init(
        rows: [], busy: false, message: "Energy mode unavailable", showsFallback: true)
    case .available(let status)?:
      let rows = status.sources.map { source in
        EnergyModePresentation.Row(
          source: source, modes: status.layout.modes,
          selected: pending?.source == source ? pending?.mode : status.modes[source],
          isCurrentSource: source == currentSource)
      }
      return .init(
        rows: rows, busy: isBusy,
        message: isAwaitingApproval ? "Waiting for approval…" : note?.text,
        showsFallback: note?.fallback == true && !isAwaitingApproval)
    }
  }
}
