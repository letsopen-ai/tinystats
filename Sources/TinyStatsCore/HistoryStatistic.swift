import Foundation

public enum HistoryStatistic: Int, CaseIterable, Sendable {
  case peak, average, minimum
  public var title: String {
    switch self {
    case .peak: "Peak"
    case .average: "Sample average"
    case .minimum: "Minimum"
    }
  }
  public var singular: String {
    switch self {
    case .peak: "peak"
    case .average: "sample average"
    case .minimum: "minimum"
    }
  }
  public var plural: String {
    switch self {
    case .peak: "peaks"
    case .average: "sample averages"
    case .minimum: "minima"
    }
  }

  /// Sample weights are counts, never elapsed time or transfer totals.
  public func combined(
    _ first: Double, samples firstSamples: UInt64,
    with second: Double, samples secondSamples: UInt64
  ) -> Double? {
    guard first.isFinite, second.isFinite, firstSamples > 0, secondSamples > 0 else { return nil }
    switch self {
    case .peak: return max(first, second)
    case .minimum: return min(first, second)
    case .average:
      let weight = Double(secondSamples) / (Double(firstSamples) + Double(secondSamples))
      // Same-sign subtraction is bounded. Opposite-sign products avoid an
      // overflowing subtraction, including finite negative temperatures.
      let mean =
        first.sign == second.sign
        ? first + (second - first) * weight
        : first * (1 - weight) + second * weight
      return min(max(first, second), max(min(first, second), mean))
    }
  }
}

/// One packed aggregate per metric. Zero count is unknown (including v1 data).
/// The max-count sentinel withholds aggregates after a conservative overflow.
struct HistoryStatistics: Sendable {
  var minimum: Double = 0
  var mean: Double = 0
  var count: UInt32 = 0
  var available: Bool { count > 0 && count < .max }
  mutating func append(_ value: Double) {
    guard value.isFinite, count < .max else { return }
    guard count < .max - 1 else {
      self = .init(count: .max)
      return
    }
    if count == 0 {
      self = .init(minimum: value, mean: value, count: 1)
    } else if let joined = HistoryStatistic.average.combined(
      mean, samples: UInt64(count), with: value, samples: 1)
    {
      mean = joined
      minimum = min(minimum, value)
      count += 1
    }
  }
  mutating func merge(_ later: Self) {
    guard later.count > 0 else { return }
    guard count > 0 else {
      self = later
      return
    }
    let total = UInt64(count) + UInt64(later.count)
    guard count < .max, later.count < .max, total < UInt32.max else {
      self = .init(count: .max)
      return
    }
    if let joined = HistoryStatistic.average.combined(
      mean, samples: UInt64(count), with: later.mean, samples: UInt64(later.count))
    {
      mean = joined
      minimum = min(minimum, later.minimum)
      count = UInt32(total)
    }
  }
}
