import Foundation

/// One timer can deliver wall-clock boundaries without collecting hardware at those boundaries.
/// Own on the sampler's serial queue; monotonic deadlines drive all collection intervals.
public struct MonitorSchedule: Sendable {
  public struct Decision: Equatable, Sendable {
    public let collect: Bool
    public let clock: Bool
    public let deadline: Double
  }
  private var sampleDeadline: Double?
  private var lastNow: Double?
  private var clockBucket: Double?
  private var previousClockStep: Double?
  public init() {}
  public mutating func reset() {
    sampleDeadline = nil
    lastNow = nil
    clockBucket = nil
    previousClockStep = nil
  }
  public mutating func invalidateClock() { clockBucket = nil }
  public mutating func collectionFinished(at now: Double, interval: Double) {
    guard now.isFinite, now >= 0, let sampleDeadline, now >= sampleDeadline else { return }
    self.sampleDeadline = now + (interval.isFinite ? min(60, max(1, interval)) : 2)
  }
  public func deadline(at now: Double, date: Date, clockStep: Double?) -> Double {
    var deadline = sampleDeadline ?? now + 2
    if let step = clockStep, step == 1 || step == 60, date.timeIntervalSince1970.isFinite {
      let wall = date.timeIntervalSince1970
      deadline = min(deadline, now + max(0.001, step - (wall - floor(wall / step) * step)))
    }
    return max(now + 0.001, deadline)
  }
  public mutating func next(at now: Double, date: Date, interval: Double, clockStep: Double?)
    -> Decision
  {
    let interval = interval.isFinite ? min(60, max(1, interval)) : 2
    guard now.isFinite && now >= 0 else {
      return .init(collect: false, clock: false, deadline: (lastNow ?? 0) + interval)
    }
    if let lastNow, now < lastNow { reset() }
    lastNow = now
    let collect = sampleDeadline.map { now >= $0 } ?? true
    if collect { sampleDeadline = now + interval }
    var deadline = sampleDeadline ?? now + interval
    var clock = false
    if let step = clockStep, step == 1 || step == 60, date.timeIntervalSince1970.isFinite {
      let wall = date.timeIntervalSince1970
      let bucket = floor(wall / step)
      clock = bucket != clockBucket || previousClockStep != step
      clockBucket = bucket
      previousClockStep = step
      let remainder = wall - bucket * step
      deadline = min(deadline, now + max(0.001, step - remainder))
    } else {
      clockBucket = nil
      previousClockStep = nil
    }
    return .init(collect: collect, clock: clock, deadline: max(now + 0.001, deadline))
  }
}
