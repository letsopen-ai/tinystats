import Foundation
import TinyStatsCore

/// Retain the newest valid timeline after a clock correction, rather than hiding
/// the entire buffer until the offending timestamp ages out.
struct HistoryTimeline {
  let indices: Range<Int>
  let positions: [Double?]
  let duration: Double
  let reset: Bool
  let gaps: [ClosedRange<Double>]
  let cadence: ClosedRange<Double>?

  init(times: [Date], intervals: [Double?] = [], domain: ClosedRange<Date>? = nil) {
    let initial = max(0, times.count - 300)
    var start = initial
    var previous: Double?
    for index in initial..<times.count {
      let value = times[index].timeIntervalSince1970
      guard value.isFinite else {
        start = index + 1
        previous = nil
        continue
      }
      if let previous,
        value <= previous || !(value - times[start].timeIntervalSince1970).isFinite
      {
        start = index
      }
      previous = value
    }
    indices = start..<times.count
    reset = start > initial
    let observed = indices.count > 1 ? times[times.count - 1].timeIntervalSince(times[start]) : 0
    let domainDuration = domain.map { $0.upperBound.timeIntervalSince($0.lowerBound) }
    let fixedDomain = domainDuration.map { $0.isFinite && $0 > 0 } == true ? domain : nil
    duration = fixedDomain == nil ? observed : domainDuration!
    let origin = fixedDomain?.lowerBound ?? (indices.isEmpty ? Date() : times[start])
    var positions = [Double?](repeating: nil, count: times.count)
    for index in indices {
      positions[index] =
        duration > 0 ? min(1, max(0, times[index].timeIntervalSince(origin) / duration)) : 1
    }
    self.positions = positions
    func expected(_ index: Int) -> Double? {
      guard intervals.indices.contains(index), let value = intervals[index],
        value.isFinite, value > 0
      else { return nil }
      return value
    }
    let observedSteps = indices.dropFirst().map { times[$0].timeIntervalSince(times[$0 - 1]) }
      .sorted()
    let nominal = indices.compactMap(expected)
    let fallback = observedSteps.isEmpty ? nil : observedSteps[observedSteps.count / 2]
    if let minimum = nominal.min(), let maximum = nominal.max() {
      cadence = minimum...maximum
    } else if let fallback {
      cadence = fallback...fallback
    } else {
      cadence = nil
    }
    var gaps: [ClosedRange<Double>] = []
    if duration > 0 {
      for index in indices.dropFirst() {
        let step = max(expected(index) ?? fallback ?? 0, expected(index - 1) ?? fallback ?? 0)
        let elapsed = times[index].timeIntervalSince(times[index - 1])
        if step > 0, elapsed > step * 2.5 {
          let lower = (times[index - 1].timeIntervalSince(origin) + step / 2) / duration
          let upper = (times[index].timeIntervalSince(origin) - step / 2) / duration
          if lower < upper { gaps.append(lower...upper) }
        }
      }
    }
    self.gaps = gaps
  }

  var span: String {
    guard duration < 365 * 86400 else { return ">1y" }
    let seconds = Int(duration.rounded(.down))
    if seconds >= 86400 { return "\(seconds / 86400)d \(seconds % 86400 / 3600)h" }
    if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
    if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds)s"
  }
  var cadenceDescription: String {
    guard let cadence else { return "Cadence unavailable" }
    func text(_ value: Double) -> String {
      value >= 3600 ? "≥1h" : String(format: value < 1 ? "%.1fs" : "%.0fs", value)
    }
    return cadence.lowerBound == cadence.upperBound
      ? "~\(text(cadence.lowerBound)) cadence"
      : "~\(text(cadence.lowerBound))–\(text(cadence.upperBound)) cadence"
  }
}

/// Pixel-sized columns never overlap. Where screen resolution cannot separate
/// every sample, each column explicitly represents peaks of recorded samples.
@MainActor struct HistoryBarLayout {
  struct Column: Equatable {
    let slot: Int
    var first: Double?, second: Double?
    var firstMissing = false, secondMissing = false
    var firstIndex = 0, lastIndex = 0
    var gap = false
    var samples = 0
    var firstWeight: UInt64 = 0, secondWeight: UInt64 = 0
  }
  let timeline: HistoryTimeline
  let columns: [Column]
  let scale: CGFloat
  let pixelWidth: Int, barPixels: Int, slotCount: Int
  let maximum: Double
  let hasData: Bool
  var grouped: Bool { columns.contains { $0.samples > 1 } }
  var barWidth: CGFloat { CGFloat(barPixels) / scale }

  /// Inputs are read once per observation; core rows need no temporary Plot arrays.
  fileprivate struct Observation {
    var first: Double?, second: Double? = nil
    var firstPartial = false, secondPartial = false, gap = false
    var firstWeight: UInt32 = 1, secondWeight: UInt32 = 1
  }

  init(
    plot: SummaryDashboardView.Plot, graphWidth: CGFloat, scale: CGFloat,
    timeline suppliedTimeline: HistoryTimeline? = nil
  ) {
    self.init(
      timeline: suppliedTimeline ?? plot.timeline, graphWidth: graphWidth, scale: scale,
      fixedDomain: plot.domain != nil, paired: !plot.secondLabel.isEmpty,
      percent: plot.percent, mirrored: plot.mirrored, statistic: plot.statistic
    ) { index in
      Observation(
        first: plot.first.indices.contains(index) ? plot.first[index] : nil,
        second: plot.second.indices.contains(index) ? plot.second[index] : nil,
        firstPartial: plot.partialFirst.indices.contains(index) && plot.partialFirst[index],
        secondPartial: plot.partialSecond.indices.contains(index) && plot.partialSecond[index],
        gap: plot.gapBuckets.indices.contains(index) && plot.gapBuckets[index],
        firstWeight: plot.firstWeights.indices.contains(index) ? plot.firstWeights[index] : 1,
        secondWeight: plot.secondWeights.indices.contains(index) ? plot.secondWeights[index] : 1)
    }
  }

  fileprivate init(
    timeline: HistoryTimeline, graphWidth: CGFloat, scale: CGFloat,
    fixedDomain: Bool, paired: Bool, percent: Bool, mirrored: Bool,
    statistic: HistoryStatistic, observation: (Int) -> Observation
  ) {
    self.timeline = timeline
    self.scale = scale.isFinite && scale > 0 ? min(4, scale) : 1
    let pixels = graphWidth.isFinite ? min(16384, max(0, floor(graphWidth * self.scale))) : 0
    pixelWidth = Int(pixels)
    // A fixed domain reserves columns for uncollected time too. Sizing columns
    // by the currently available bucket count would collapse a short session.
    // Two slots per retained bucket also distinguish the newest partial bucket,
    // whose clipped center can be only half a resolution from its predecessor.
    slotCount = min(fixedDomain ? 600 : timeline.indices.count, (pixelWidth + 1) / 2)
    barPixels =
      slotCount > 0
      ? max(1, min(Int(3 * self.scale), pixelWidth / slotCount - 1)) : 0
    func valid(_ value: Double?) -> Double? {
      guard let value, value.isFinite, value >= 0 else { return nil }
      return value
    }
    var bins: [Column] = []
    bins.reserveCapacity(min(slotCount, timeline.indices.count))
    if slotCount > 0 {
      for index in timeline.indices {
        guard let position = timeline.positions[index] else { continue }
        let slot = Int((position * Double(slotCount - 1)).rounded())
        let sample = observation(index)
        let a = valid(sample.first)
        let b = paired ? valid(sample.second) : nil
        // Timeline recovery leaves increasing timestamps. Domain clamping and
        // pixel rounding preserve their order, so only the last bin can merge.
        var column = bins.last?.slot == slot ? bins.removeLast() : Column(slot: slot)
        if paired && !mirrored && statistic == .peak {
          // Keep CPU components from the same observation. Independent maxima
          // could invent a stacked total that never occurred.
          let old = min(100, column.first ?? 0) + min(100, column.second ?? 0)
          let new = min(100, a ?? 0) + min(100, b ?? 0)
          let oldKnown = (column.first == nil ? 0 : 1) + (column.second == nil ? 0 : 1)
          let newKnown = (a == nil ? 0 : 1) + (b == nil ? 0 : 1)
          if column.samples == 0 || new > old || (new == old && newKnown >= oldKnown) {
            column.first = a
            column.second = b
          }
        } else {
          func joined(_ old: Double?, _ value: Double?, _ weight: inout UInt64, count: UInt32)
            -> Double?
          {
            guard let value else { return old }
            let count = UInt64(count)
            guard count > 0 else { return old }
            let result =
              old.flatMap {
                statistic.combined($0, samples: weight, with: value, samples: count)
              } ?? value
            weight += count
            return result
          }
          column.first = joined(column.first, a, &column.firstWeight, count: sample.firstWeight)
          column.second = joined(column.second, b, &column.secondWeight, count: sample.secondWeight)
        }
        column.firstMissing =
          column.firstMissing || a == nil
          || sample.firstPartial
        column.secondMissing =
          column.secondMissing || (paired && b == nil)
          || sample.secondPartial
        if column.samples == 0 { column.firstIndex = index }
        column.lastIndex = index
        column.gap =
          column.gap || sample.gap
        column.samples += 1
        bins.append(column)
      }
    }
    columns = bins
    var found = false
    var largest = 1.0
    for column in bins {
      if let first = column.first {
        found = true
        largest = max(largest, first)
      }
      if let second = column.second {
        found = true
        largest = max(largest, second)
      }
    }
    hasData = found
    maximum = percent ? 100 : largest
  }

  func x(_ column: Column) -> CGFloat {
    guard slotCount > 1 else { return CGFloat(pixelWidth - barPixels) / scale }
    let pixel = (Double(column.slot) * Double(pixelWidth - barPixels) / Double(slotCount - 1))
      .rounded()
    return CGFloat(pixel) / scale
  }
}

/// Compatibility and range totals are computed once per update, not once per core/bucket comparison.
@MainActor struct CoreHistoryMatrix {
  let history: HistoryProjection
  let kinds: [CPUCoreKind]
  let statistic: HistoryStatistic
  let cores: [CPUCoreHistoryBucket?]
  let values: [Double?]
  let counts: [UInt64]
  let timeline: HistoryTimeline
  init(_ history: HistoryProjection, kinds: [CPUCoreKind], statistic: HistoryStatistic) {
    self.history = history
    self.kinds = kinds
    self.statistic = statistic
    cores = history.buckets.map { bucket in bucket.cpuCores.flatMap { $0.kinds == kinds ? $0 : nil }
    }
    var values = [Double?](repeating: nil, count: kinds.count)
    var counts = [UInt64](repeating: 0, count: kinds.count)
    for coreData in cores.compactMap({ $0 }) {
      for index in kinds.indices {
        guard let value = coreData.value(index, statistic: statistic) else { continue }
        let count = UInt64(coreData.validSamples(index))
        values[index] =
          values[index].flatMap {
            statistic.combined($0, samples: counts[index], with: value, samples: count)
          } ?? value
        counts[index] += count
      }
    }
    self.values = values
    self.counts = counts
    let end = history.buckets.last?.last ?? Date(timeIntervalSince1970: 0)
    timeline = HistoryTimeline(
      times: history.bucketCenters, domain: (end - Double(history.range.rawValue))...end)
  }
}

/// Fixed bucket centers plus statistic-aware pixel bins. Active partial buckets are clipped to the domain.
@MainActor func coreHistoryBars(
  _ matrix: CoreHistoryMatrix, core: Int, width: CGFloat, scale: CGFloat
) -> HistoryBarLayout {
  HistoryBarLayout(
    timeline: matrix.timeline, graphWidth: width, scale: scale,
    fixedDomain: true, paired: false, percent: true, mirrored: false,
    statistic: matrix.statistic
  ) { index in
    let bucket = matrix.history.buckets[index]
    let coreData = matrix.cores[index]
    let count = coreData?.validSamples(core) ?? 0
    return .init(
      first: coreData?.value(core, statistic: matrix.statistic),
      firstPartial: count < bucket.samples || bucket.coreLayoutChanged,
      gap: bucket.hasGap, firstWeight: count)
  }
}
