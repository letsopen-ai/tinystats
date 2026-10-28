import Darwin
import Foundation
import TinyStatsTrafficIPC
import TinyStatsTrafficServiceCore

// No installation, registration, elevation or network request is performed by this executable.
let isRoot = geteuid() == 0
let team =
  isRoot
  ? TrafficServiceSigning.currentTeam(identifier: TrafficServiceSigning.serviceIdentifier) : nil
if CommandLine.arguments.contains("--diagnose-policy") {
  print(
    isRoot
      ? (team == nil
        ? "Refused: validated hardened developer signature required."
        : "Eligible for a signed-peer listener; no listener started.")
      : "Refused: root service context required; no listener started.")
  exit(0)
}
guard isRoot, let team,
  let delegate = TrafficServiceListener(team: team, onIdle: { exit(0) })
else {
  FileHandle.standardError.write(
    Data(
      "TinyStats traffic service requires root and a validated hardened developer signature. Nothing started.\n"
        .utf8))
  exit(78)
}
let listener = NSXPCListener(machServiceName: TrafficServiceSigning.serviceIdentifier)
delegate.configure(listener)
listener.resume()
withExtendedLifetime(delegate) { RunLoop.current.run() }
