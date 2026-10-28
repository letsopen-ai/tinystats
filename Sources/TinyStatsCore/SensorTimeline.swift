import Foundation

/// Recent readings for browsing sensors while a detail view is alive. No polling or disk writes.
/// A single time axis and compact columns cap storage at 132 × 120 Float values (~62 KiB value payload).
public struct SensorTimeline: Sendable {
  // 128 SMC readings plus the four IOReport power quantities.
  public static let limit = 132
  public static let capacity = 120
  private var stamps = RingBuffer<Date>(capacity: capacity)
  private var columns: [String: [Float]] = [:]
  private var writeIndex = 0
  private var sampledAt: Double?
  private var lastDate: Date?
  private var kinds: [String: SensorReading.Kind] = [:]
  public init() {}
  public var times: [Date] { stamps.elements }
  public var count: Int { stamps.count }
  public var sensorCount: Int { columns.count }
  public func kind(for key: String) -> SensorReading.Kind? { kinds[key] }

  public mutating func append(_ snapshot: Snapshot) {
    guard let sample = snapshot.sensorsSampledAt, sample.isFinite, sample >= 0,
      snapshot.uptime.isFinite, sample <= snapshot.uptime,
      snapshot.timestamp.timeIntervalSince1970.isFinite, sample != sampledAt
    else { return }
    let date = snapshot.timestamp.addingTimeInterval(sample - snapshot.uptime)
    guard date.timeIntervalSince1970.isFinite else { return }
    if let previous = sampledAt, sample < previous {
      stamps.removeAll()
      writeIndex = 0
      columns.removeAll(keepingCapacity: false)
      kinds.removeAll(keepingCapacity: false)
    } else if let last = lastDate, date <= last {
      stamps.removeAll()
      writeIndex = 0
      columns.removeAll(keepingCapacity: false)
      kinds.removeAll(keepingCapacity: false)
    }
    sampledAt = sample
    lastDate = date
    var readings: [String: SensorReading] = [:]
    for reading in snapshot.sensors.prefix(Self.limit) where readings[reading.key] == nil {
      readings[reading.key] = reading
    }
    for key in readings.keys.sorted() where columns[key] == nil {
      if columns.count == Self.limit,
        let expired = columns.keys.filter({ readings[$0] == nil }).sorted().first
      {
        columns.removeValue(forKey: expired)
        kinds.removeValue(forKey: expired)
      }
      guard columns.count < Self.limit else { continue }
      columns[key] = Array(repeating: .nan, count: Self.capacity)
    }
    for key in columns.keys.sorted() {
      if let reading = readings[key], kinds[key] != reading.kind {
        columns[key] = Array(repeating: .nan, count: Self.capacity)
        kinds[key] = reading.kind
      }
      let compact = readings[key].map { Float($0.value) } ?? .nan
      columns[key]?[writeIndex] = compact.isFinite ? compact : .nan
    }
    stamps.append(date)
    writeIndex = (writeIndex + 1) % Self.capacity
  }

  /// Read-only projection of existing columns. Missing columns/samples remain gaps.
  /// Callers choose the currently readable keys; this adds no retained column or bound.
  public func maximumValues(for keys: [String], fahrenheit: Bool) -> [Double?] {
    var maximum = [Double?](repeating: nil, count: stamps.count)
    for key in Set(keys) where kinds[key] == .temperature {
      let values = values(for: key, fahrenheit: fahrenheit, kind: .temperature)
      for index in values.indices {
        if let value = values[index] {
          maximum[index] = maximum[index].map { max($0, value) } ?? value
        }
      }
    }
    return maximum
  }

  public func values(for key: String, fahrenheit: Bool, kind: SensorReading.Kind?) -> [Double?] {
    guard let column = columns[key] else { return Array(repeating: nil, count: stamps.count) }
    let start = (writeIndex - stamps.count + Self.capacity) % Self.capacity
    return (0..<stamps.count).map { index in
      let value = column[(start + index) % Self.capacity]
      guard value.isFinite else { return nil }
      let number = Double(value)
      return kind == .temperature && fahrenheit ? number * 1.8 + 32 : number
    }
  }
}
