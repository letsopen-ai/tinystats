import Foundation

/// Ordered Mach logical counters, with no physical-core identity inferred from position.
/// Float storage is sufficient for percentage charts; nonfinite/out-of-range samples stay missing.
public struct CPUCoreHistorySample: Sendable {
  public static let maximumCores = 256
  public let kinds: [CPUCoreKind]
  private let percentages: [Float]
  public var count: Int { percentages.count }
  public init?(_ cpu: CPUReading) {
    guard (1...Self.maximumCores).contains(cpu.cores.count) else { return nil }
    kinds =
      cpu.coreKinds.count == cpu.cores.count
      ? cpu.coreKinds : Array(repeating: .unknown, count: cpu.cores.count)
    percentages = cpu.cores.map { value in
      guard let value, value.isFinite, (0...100).contains(value) else { return .nan }
      return Float(value)
    }
  }
  public subscript(_ index: Int) -> Double? {
    guard percentages.indices.contains(index), percentages[index].isFinite else { return nil }
    return Double(percentages[index])
  }
}

/// 16 numeric bytes per logical core, allocated only for observed layouts.
/// Counts weight valid observations, never elapsed time. A saturated count withholds all statistics.
struct CPUCoreStatistics: Sendable {
  var peak: Float = 0, minimum: Float = 0, mean: Float = 0
  var count: UInt32 = 0
  var available: Bool { count > 0 && count < .max }
  mutating func append(_ value: Double) {
    guard count < .max else { return }
    guard count < .max - 1 else {
      self = .init(count: .max)
      return
    }
    if count == 0 {
      self = .init(peak: Float(value), minimum: Float(value), mean: Float(value), count: 1)
    } else {
      mean = Float(Double(mean) + (value - Double(mean)) / Double(count + 1))
      peak = max(peak, Float(value))
      minimum = min(minimum, Float(value))
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
    guard available, later.available, total < UInt32.max else {
      self = .init(count: .max)
      return
    }
    mean = Float(
      Double(mean) + (Double(later.mean) - Double(mean)) * Double(later.count) / Double(total))
    peak = max(peak, later.peak)
    minimum = min(minimum, later.minimum)
    count = UInt32(total)
  }
}

public struct CPUCoreHistoryBucket: Sendable {
  public let kinds: [CPUCoreKind]
  var statistics: [CPUCoreStatistics]
  public var count: Int { kinds.count }
  init(_ sample: CPUCoreHistorySample) {
    kinds = sample.kinds
    statistics = Array(repeating: CPUCoreStatistics(), count: sample.count)
    append(sample)
  }
  init(kinds: [CPUCoreKind], statistics: [CPUCoreStatistics]) {
    self.kinds = kinds
    self.statistics = statistics
  }
  mutating func append(_ sample: CPUCoreHistorySample) {
    precondition(sample.kinds == kinds)
    for index in statistics.indices {
      if let value = sample[index] { statistics[index].append(value) }
    }
  }
  mutating func merge(_ later: Self) {
    precondition(later.kinds == kinds)
    for index in statistics.indices { statistics[index].merge(later.statistics[index]) }
  }
  public func validSamples(_ index: Int) -> UInt32 {
    guard statistics.indices.contains(index), statistics[index].available else { return 0 }
    return statistics[index].count
  }
  public func value(_ index: Int, statistic: HistoryStatistic) -> Double? {
    guard statistics.indices.contains(index), statistics[index].available else { return nil }
    let value = statistics[index]
    switch statistic {
    case .peak: return Double(value.peak)
    case .minimum: return Double(value.minimum)
    case .average: return Double(value.mean)
    }
  }
}
