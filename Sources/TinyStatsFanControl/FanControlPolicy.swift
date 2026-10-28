import Foundation

/// Experimental policy only: no SMC access, timer, IPC, persistence or actuator. Not linked
/// into the preview. A future adapter must prove that a raised minimum leaves the system
/// free to demand higher speeds; a forced target or a readable key is not that proof.
public struct FanCurve: Equatable, Sendable {
  public struct Point: Equatable, Sendable {
    public let celsius: Double, fraction: Double
    public init(celsius: Double, fraction: Double) {
      self.celsius = celsius
      self.fraction = fraction
    }
  }
  public let points: [Point]
  public init?(points: [Point]) {
    guard (2...8).contains(points.count),
      points.allSatisfy({
        $0.celsius.isFinite && (-20...125).contains($0.celsius)
          && $0.fraction.isFinite && (0...1).contains($0.fraction)
      })
    else { return nil }
    for index in 1..<points.count {
      guard points[index].celsius > points[index - 1].celsius,
        points[index].fraction >= points[index - 1].fraction
      else { return nil }
    }
    self.points = points
  }
  public func minimumRPM(celsius: Double, limits: FanLimits) -> Int? {
    guard celsius.isFinite, (-20...125).contains(celsius), limits.valid else { return nil }
    var fraction = points[0].fraction
    for index in 1..<points.count {
      let lower = points[index - 1]
      let upper = points[index]
      if celsius <= lower.celsius { break }
      if celsius >= upper.celsius {
        fraction = upper.fraction
        continue
      }
      let progress = (celsius - lower.celsius) / (upper.celsius - lower.celsius)
      fraction = lower.fraction + (upper.fraction - lower.fraction) * progress
      break
    }
    let span = Double(limits.maximumRPM - limits.minimumRPM)
    return min(
      limits.maximumRPM,
      max(
        limits.minimumRPM,
        Int((Double(limits.minimumRPM) + span * fraction).rounded(.up))))
  }
}

public struct FanLimits: Equatable, Sendable {
  public let id: Int, minimumRPM: Int, maximumRPM: Int
  public init(id: Int, minimumRPM: Int, maximumRPM: Int) {
    self.id = id
    self.minimumRPM = minimumRPM
    self.maximumRPM = maximumRPM
  }
  var valid: Bool {
    (0..<8).contains(id) && minimumRPM >= 0 && maximumRPM <= 20_000
      && maximumRPM > minimumRPM
  }
}
public struct FanRule: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case manual(minimumRPM: Int)
    case curve(sensorKeys: [String], FanCurve)
  }
  public let fanID: Int, mode: Mode
  public init(fanID: Int, mode: Mode) {
    self.fanID = fanID
    self.mode = mode
  }
  var valid: Bool {
    guard (0..<8).contains(fanID) else { return false }
    switch mode {
    case .manual(let rpm): return (0...20_000).contains(rpm)
    case .curve(let keys, _):
      return (1...8).contains(keys.count) && Set(keys).count == keys.count
        && keys.allSatisfy {
          !$0.isEmpty && $0.utf8.count <= 64
            && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }
  }
}
public enum FanConfiguration: Equatable, Sendable {
  case automatic
  case custom([FanRule])
  var valid: Bool {
    switch self {
    case .automatic: return true
    case .custom(let rules):
      return (1...8).contains(rules.count) && rules.allSatisfy(\.valid)
        && Set(rules.map(\.fanID)).count == rules.count
    }
  }
}
public struct FanTemperature: Sendable {
  public let key: String, celsius: Double, sampledAt: Double
  public init(key: String, celsius: Double, sampledAt: Double) {
    self.key = key
    self.celsius = celsius
    self.sampledAt = sampledAt
  }
}
public struct FanControlFrame: Sendable {
  public enum Capability: Sendable {
    case unverified, raisedMinimumPreservesSystemControl
  }
  public enum ThermalState: Sendable { case unknown, nominal, fair, serious, critical }
  /// Set only by a verified, queue-confined native adapter, never by an XPC caller.
  public let capability: Capability, thermalState: ThermalState
  public let deviceToken: UInt64, sampledAt: Double
  public let fans: [FanLimits], temperatures: [FanTemperature]
  public init(
    capability: Capability, thermalState: ThermalState, deviceToken: UInt64,
    sampledAt: Double, fans: [FanLimits], temperatures: [FanTemperature]
  ) {
    self.capability = capability
    self.thermalState = thermalState
    self.deviceToken = deviceToken
    self.sampledAt = sampledAt
    self.fans = fans
    self.temperatures = temperatures
  }
}
public struct FanMinimum: Equatable, Sendable {
  public let fanID: Int, rpm: Int
  public init(fanID: Int, rpm: Int) {
    self.fanID = fanID
    self.rpm = rpm
  }
}
public enum FanDecision: Equatable, Sendable {
  public enum Reason: Equatable, Sendable {
    case automatic, invalidConfiguration, leaseExpired, clockReset, deviceChanged
    case unverifiedBackend, invalidInventory, boundsChanged, staleInventory, missingSensor,
      staleSensor
    case invalidSensor, thermalPressure
  }
  /// A future actuator restores only minima it owns, not arbitrary fan modes/other apps.
  case restoreSystem(Reason)
  case raiseMinimum([FanMinimum])
}

/// Own on one serial queue. All times must share a monotonic, sleep-inclusive clock.
/// Evaluating never renews the 10-second client lease. A future native service also needs
/// an independent one-shot expiry watchdog: no tick after a crash means no policy call.
public final class FanControlPolicy {
  public static let leaseSeconds = 10.0, freshnessSeconds = 5.0, coolingDelaySeconds = 5.0
  private var configuration: FanConfiguration = .automatic
  private var deviceToken: UInt64 = 0
  private var lastTime = -Double.infinity, heartbeatTime = -Double.infinity
  private var stopReason: FanDecision.Reason = .automatic
  private var previous: [Int: Int] = [:], coolingSince: [Int: Double] = [:]
  public init() {}
  @discardableResult public func configure(
    _ configuration: FanConfiguration, deviceToken: UInt64, at time: Double
  ) -> Bool {
    stop(.automatic)
    guard time.isFinite, time >= 0, deviceToken > 0, configuration.valid else {
      stop(.invalidConfiguration)
      return false
    }
    self.configuration = configuration
    self.deviceToken = deviceToken
    lastTime = time
    heartbeatTime = time
    return true
  }
  public func stop() { stop(.automatic) }
  private func stop(_ reason: FanDecision.Reason) {
    configuration = .automatic
    deviceToken = 0
    stopReason = reason
    previous.removeAll(keepingCapacity: true)
    coolingSince.removeAll(keepingCapacity: true)
  }
  @discardableResult public func keepAlive(at time: Double) -> Bool {
    guard case .custom = configuration else { return false }
    guard time.isFinite, time >= lastTime, time >= heartbeatTime else {
      stop(.clockReset)
      return false
    }
    guard time - heartbeatTime < Self.leaseSeconds else {
      stop(.leaseExpired)
      return false
    }
    heartbeatTime = time
    return true
  }
  public func evaluate(_ frame: FanControlFrame, at time: Double) -> FanDecision {
    guard case .custom(let rules) = configuration else { return .restoreSystem(stopReason) }
    guard time.isFinite, time >= lastTime, time >= heartbeatTime else {
      stop(.clockReset)
      return .restoreSystem(.clockReset)
    }
    lastTime = time
    guard time - heartbeatTime < Self.leaseSeconds else {
      stop(.leaseExpired)
      return .restoreSystem(.leaseExpired)
    }
    guard frame.deviceToken == deviceToken else {
      stop(.deviceChanged)
      return .restoreSystem(.deviceChanged)
    }
    func restore(_ reason: FanDecision.Reason) -> FanDecision {
      previous.removeAll(keepingCapacity: true)
      coolingSince.removeAll(keepingCapacity: true)
      return .restoreSystem(reason)
    }
    guard frame.capability == .raisedMinimumPreservesSystemControl else {
      return restore(.unverifiedBackend)
    }
    guard frame.thermalState == .nominal || frame.thermalState == .fair else {
      return restore(.thermalPressure)
    }
    guard frame.sampledAt.isFinite, frame.sampledAt >= 0, frame.sampledAt <= time,
      time - frame.sampledAt <= Self.freshnessSeconds
    else { return restore(.staleInventory) }
    guard (1...8).contains(frame.fans.count), frame.fans.allSatisfy(\.valid),
      Set(frame.fans.map(\.id)).count == frame.fans.count, frame.temperatures.count <= 128
    else { return restore(.invalidInventory) }
    for limits in frame.fans {
      if let old = previous[limits.id], !(limits.minimumRPM...limits.maximumRPM).contains(old) {
        return restore(.boundsChanged)
      }
    }
    var requiredKeys = Set<String>()
    for rule in rules {
      if case .curve(let keys, _) = rule.mode { requiredKeys.formUnion(keys) }
    }
    var temperatures: [String: FanTemperature] = [:]
    for reading in frame.temperatures where requiredKeys.contains(reading.key) {
      guard temperatures.updateValue(reading, forKey: reading.key) == nil else {
        return restore(.missingSensor)
      }
    }
    var wanted: [FanMinimum] = []
    for rule in rules {
      guard let limits = frame.fans.first(where: { $0.id == rule.fanID }) else {
        return restore(.invalidInventory)
      }
      let rpm: Int
      switch rule.mode {
      case .manual(let value):
        guard (limits.minimumRPM...limits.maximumRPM).contains(value) else {
          return restore(.invalidConfiguration)
        }
        rpm = value
      case .curve(let keys, let curve):
        var hottest = -Double.infinity
        for key in keys {
          guard let reading = temperatures[key] else {
            return restore(.missingSensor)
          }
          guard reading.sampledAt.isFinite, reading.sampledAt >= 0, reading.sampledAt <= time,
            time - reading.sampledAt <= Self.freshnessSeconds
          else { return restore(.staleSensor) }
          guard reading.celsius.isFinite, (-20...125).contains(reading.celsius) else {
            return restore(.invalidSensor)
          }
          hottest = max(hottest, reading.celsius)
        }
        guard let value = curve.minimumRPM(celsius: hottest, limits: limits) else {
          return restore(.invalidSensor)
        }
        rpm = value
      }
      wanted.append(.init(fanID: rule.fanID, rpm: rpm))
    }
    // Validate the whole batch before updating state. Rises are immediate; a lower demand
    // must persist for five seconds. A safety fallback clears this history before recovery.
    var output: [FanMinimum] = []
    for value in wanted {
      var rpm = value.rpm
      if let old = previous[value.fanID], rpm < old {
        let since = coolingSince[value.fanID] ?? time
        coolingSince[value.fanID] = since
        if time - since < Self.coolingDelaySeconds {
          rpm = old
        } else {
          coolingSince[value.fanID] = nil
        }
      } else {
        coolingSince[value.fanID] = nil
      }
      previous[value.fanID] = rpm
      output.append(.init(fanID: value.fanID, rpm: rpm))
    }
    return .raiseMinimum(output.sorted { $0.fanID < $1.fanID })
  }
}
