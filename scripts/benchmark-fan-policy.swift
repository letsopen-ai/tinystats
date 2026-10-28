// Synthetic policy-only benchmark. No SMC access, service, IPC, network or settings writes.
// Compile with FanControlPolicy.swift, -O; this is not a hardware fan-control test.
import Foundation

@main
private enum FanPolicyBenchmark {
  static func main() throws {
    let curve = FanCurve(points: [
      .init(celsius: 40, fraction: 0), .init(celsius: 70, fraction: 0.5),
      .init(celsius: 95, fraction: 1),
    ])!
    let rules = (0..<8).map { fan in
      FanRule(fanID: fan, mode: .curve(sensorKeys: (0..<8).map { "S\(fan * 8 + $0)" }, curve))
    }
    let readings = (0..<128).map {
      FanTemperature(key: "S\($0)", celsius: Double(55 + $0 % 20), sampledAt: 100)
    }
    let frame = FanControlFrame(
      capability: .raisedMinimumPreservesSystemControl, thermalState: .nominal,
      deviceToken: 1, sampledAt: 100,
      fans: (0..<8).map { FanLimits(id: $0, minimumRPM: 500, maximumRPM: 6000) },
      temperatures: readings)
    let policy = FanControlPolicy()
    precondition(policy.configure(.custom(rules), deviceToken: 1, at: 100))
    let iterations = 50_000
    var checksum = 0
    let started = ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations {
      guard case .raiseMinimum(let output) = policy.evaluate(frame, at: 100) else {
        fatalError("Unexpected fallback")
      }
      checksum &+= output.reduce(0) { $0 + $1.rpm }
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    let result: [String: Any] = [
      "iterations": iterations, "seconds": elapsed,
      "microseconds_per_evaluation": elapsed * 1_000_000 / Double(iterations),
      "fans": 8, "selected_keys": 64, "supplied_readings": 128, "checksum": checksum,
      "scope": "synthetic in-process Release policy only; no native adapter/service/IPC",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
  }
}
