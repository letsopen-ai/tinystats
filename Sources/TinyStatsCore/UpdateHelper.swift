import Foundation

public protocol UpdateHelperChild: Sendable {
  func waitUntilReady(timeout: TimeInterval) throws -> Bool
  func stop()
}

public protocol UpdateHelperSpawning: Sendable {
  func spawn(executable: URL, arguments: [String]) throws -> any UpdateHelperChild
}

public enum UpdateHelperLaunch {
  /// Called on the install worker, never on the main actor. Returning means the
  /// actual helper decoded and validated the plan, not merely that spawn succeeded.
  public static func start(
    executable: URL, arguments: [String],
    spawner: any UpdateHelperSpawning, timeout: TimeInterval = 10
  ) throws {
    let child = try spawner.spawn(executable: executable, arguments: arguments)
    do {
      guard try child.waitUntilReady(timeout: timeout) else {
        throw UpdateError.invalid(
          "The update installer did not become ready. TinyStats is still running. Try checking again."
        )
      }
    } catch {
      child.stop()
      throw error
    }
  }
}

public enum UpdateHelperLifecycle {
  /// Decoding and validation belong inside recovery as well as installation.
  public static func perform<Plan>(
    relaunch: Bool, recoverOnFailure: @escaping () -> Bool,
    load: () throws -> Plan, validate: (Plan) throws -> Void,
    signalReady: () throws -> Void, install: (Plan) throws -> Void,
    reopen: () throws -> Void, report: (any Error) -> Void
  ) throws {
    try UpdateInstallRecovery.perform(
      relaunch: relaunch, recoverOnFailure: recoverOnFailure,
      install: {
        let plan = try load()
        try validate(plan)
        try signalReady()
        try install(plan)
      }, reopen: reopen, report: report)
  }
}
