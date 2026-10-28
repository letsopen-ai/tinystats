import Foundation

/// Shared scaling for detail and menu bar graphs. Automatic domains include zero
/// and preserve signed readings; percentage charts keep their fixed scale.
public struct GraphDomain: Sendable {
  public let lower: Double, upper: Double
  public init(values: [Double?], fixedUpper: Double? = nil, fitToData: Bool = false) {
    if let fixedUpper, fixedUpper.isFinite {
      lower = 0
      upper = max(1, fixedUpper)
    } else {
      let finite = values.compactMap { $0 }.filter(\.isFinite)
      if fitToData, let minimum = finite.min(), let maximum = finite.max() {
        let padding = max(0.01, (maximum - minimum) * 0.1, max(abs(minimum), abs(maximum)) * 0.005)
        let low = minimum - padding
        let high = maximum + padding
        if low.isFinite, high.isFinite, high > low {
          lower = low
          upper = high
        } else {
          lower = 0
          upper = 1
        }
      } else {
        lower = min(0, finite.min() ?? 0)
        let maximum = max(0, finite.max() ?? 0)
        upper = maximum > lower ? maximum : lower + 1
      }
    }
  }
  public func fraction(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return min(1, max(0, (value - lower) / (upper - lower)))
  }
}

/// Retained history supplies units even while the current reading is unavailable.
public struct SensorHistory: Sendable {
  public let values: [Double?], unit: String, upperBound: Double?
  public init(points: [HistoryPoint], key: String, fahrenheit: Bool, current: SensorReading?) {
    let previous = points.last { $0.sensorKey == key && $0.sensorKind != nil }
    let kind = current?.kind ?? previous?.sensorKind
    let temperature = kind == .temperature
    values = points.map { point in
      guard point.sensorKey == key else { return nil }
      return point.sensorValue.map { temperature && fahrenheit ? $0 * 1.8 + 32 : $0 }
    }
    unit = temperature && fahrenheit ? "°F" : kind?.unit ?? ""
    upperBound = temperature ? (fahrenheit ? 250 : 120) : nil
  }
}
