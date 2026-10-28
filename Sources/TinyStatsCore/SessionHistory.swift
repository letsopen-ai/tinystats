import Foundation

/// Bounded numeric retention. A fixed ring per range bounds memory independently of uptime.
public enum HistoryRange: Int, CaseIterable, Sendable {
  case tenMinutes = 600
  case hour = 3600
  case threeHours = 10800
  case sixHours = 21600
  case twelveHours = 43200
  case day = 86400
  case threeDays = 259200
  case week = 604800
  case twoWeeks = 1_209_600
  case fourWeeks = 2_419_200
  public var title: String {
    switch self {
    case .tenMinutes: "10 minutes"
    case .hour: "1 hour"
    case .threeHours: "3 hours"
    case .sixHours: "6 hours"
    case .twelveHours: "12 hours"
    case .day: "1 day"
    case .threeDays: "3 days"
    case .week: "7 days"
    case .twoWeeks: "14 days"
    case .fourWeeks: "28 days"
    }
  }
  fileprivate static let retentionRanges: [HistoryRange] = [
    .tenMinutes, .hour, .sixHours, .day, .week, .fourWeeks,
  ]
  fileprivate var storageRange: HistoryRange {
    switch self {
    case .threeHours: .sixHours
    case .twelveHours: .day
    case .threeDays: .week
    case .twoWeeks: .fourWeeks
    default: self
    }
  }
  public var resolution: Double { Double(storageRange.rawValue) / 300 }
}

/// Numeric system readings only: no processes, addresses, coordinates or account data.
public enum HistoryMetric: Int, CaseIterable, Sendable {
  case cpu, cpuUser, cpuSystem, gpu, memory, download, upload, diskRead, diskWrite, diskUsed
  case temperature, battery
  public var column: String {
    switch self {
    case .cpu: "cpu_percent"
    case .cpuUser: "cpu_user_at_peak_cpu_percent"
    case .cpuSystem: "cpu_system_at_peak_cpu_percent"
    case .gpu: "gpu_percent"
    case .memory: "memory_percent"
    case .download: "download_bytes_per_second"
    case .upload: "upload_bytes_per_second"
    case .diskRead: "disk_read_bytes_per_second"
    case .diskWrite: "disk_write_bytes_per_second"
    case .diskUsed: "startup_volume_used_percent"
    case .temperature: "hottest_recognized_cpu_celsius"
    case .battery: "battery_percent"
    }
  }
  public var aggregateColumn: String {
    switch self {
    case .cpuUser: "cpu_user_percent"
    case .cpuSystem: "cpu_system_percent"
    default: column
    }
  }
  func accepts(_ value: Double) -> Bool {
    guard value.isFinite else { return false }
    if self == .temperature { return true }
    guard value >= 0 else { return false }
    switch self {
    case .cpu, .cpuUser, .cpuSystem, .gpu, .memory, .diskUsed, .battery: return value <= 100
    default: return true
    }
  }
  public func value(in point: HistoryPoint) -> Double? {
    let value: Double?
    switch self {
    case .cpu: value = point.cpu
    case .cpuUser: value = point.cpuUser
    case .cpuSystem: value = point.cpuSystem
    case .gpu: value = point.gpu
    case .memory: value = point.memory
    case .download: value = point.download
    case .upload: value = point.upload
    case .diskRead: value = point.diskRead
    case .diskWrite: value = point.diskWrite
    case .diskUsed: value = point.diskUsed
    case .temperature: value = point.temperature
    case .battery: value = point.battery
    }
    guard let value, accepts(value) else { return nil }
    return value
  }
}

public struct HistoryBucket: Sendable {
  public private(set) var first: Date, last: Date
  public private(set) var samples: UInt32 = 0
  public private(set) var hasGap = false
  public private(set) var maximumSampleInterval: Double = 1
  private var peaks = [Double?](repeating: nil, count: HistoryMetric.allCases.count)
  private var counts = [UInt32](repeating: 0, count: HistoryMetric.allCases.count)
  public subscript(_ metric: HistoryMetric) -> Double? { peaks[metric.rawValue] }
  public private(set) var cpuCores: CPUCoreHistoryBucket?
  public private(set) var coreLayoutChanged = false
  public private(set) var latestCoreKinds: [CPUCoreKind]?
  private var statistics: [HistoryStatistics] = []
  public func value(_ metric: HistoryMetric, statistic: HistoryStatistic) -> Double? {
    if statistic == .peak { return self[metric] }
    guard statistics.indices.contains(metric.rawValue), statistics[metric.rawValue].available else {
      return nil
    }
    return statistic == .minimum
      ? statistics[metric.rawValue].minimum : statistics[metric.rawValue].mean
  }
  public func validSamples(_ metric: HistoryMetric, statistic: HistoryStatistic = .peak) -> UInt32 {
    if statistic == .peak { return counts[metric.rawValue] }
    guard statistics.indices.contains(metric.rawValue), statistics[metric.rawValue].available else {
      return 0
    }
    return statistics[metric.rawValue].count
  }
  fileprivate init(_ point: HistoryPoint, values: [Double?], gap: Bool) {
    first = point.time
    last = point.time
    append(point, values: values, gap: gap)
  }
  fileprivate mutating func append(_ point: HistoryPoint, values: [Double?], gap: Bool) {
    if let cores = point.cpuCores { latestCoreKinds = cores.kinds }
    if !coreLayoutChanged, let cores = point.cpuCores {
      if cpuCores != nil {
        if cpuCores?.kinds == cores.kinds {
          cpuCores?.append(cores)
        } else {
          // A mixed-layout bucket has no defensible per-core identity. Keep scalar history.
          cpuCores = nil
          coreLayoutChanged = true
        }
      } else {
        cpuCores = CPUCoreHistoryBucket(cores)
      }
    }
    last = point.time
    samples = samples == .max ? .max : samples + 1
    hasGap = hasGap || gap
    maximumSampleInterval = max(maximumSampleInterval, point.sampleInterval ?? 1)
    let known = (values[1] == nil ? 0 : 1) + (values[2] == nil ? 0 : 1)
    let oldKnown = (peaks[1] == nil ? 0 : 1) + (peaks[2] == nil ? 0 : 1)
    if statistics.isEmpty && values.contains(where: { $0 != nil }) {
      statistics = Array(repeating: HistoryStatistics(), count: HistoryMetric.allCases.count)
    }
    let replacesCPU =
      values[0].map { $0 > (peaks[0] ?? -1) || ($0 == peaks[0] && known >= oldKnown) } ?? false
    for metric in HistoryMetric.allCases {
      let index = metric.rawValue
      if let value = values[index] {
        counts[index] = counts[index] == .max ? .max : counts[index] + 1
        statistics[index].append(value)
      }
      if metric == .cpuUser || metric == .cpuSystem {
        // Components must come from the same actual peak-total CPU observation.
        if replacesCPU { peaks[index] = values[index] }
      } else if let value = values[index] {
        peaks[index] = max(peaks[index] ?? -.infinity, value)
      }
    }
  }
}

public struct HistoryProjection: Sendable {
  public let range: HistoryRange
  public let buckets: [HistoryBucket]
  public let resets: UInt64
  public var storage = HistoryStorageState()
  public var samples: UInt64 { buckets.reduce(0) { $0 + UInt64($1.samples) } }
  public var gapBuckets: Int { buckets.filter(\.hasGap).count }
  public init(range: HistoryRange, buckets: [HistoryBucket] = [], resets: UInt64 = 0) {
    self.range = range
    self.buckets = Array(buckets.suffix(300))
    self.resets = resets
  }
  public func validSamples(_ metric: HistoryMetric, statistic: HistoryStatistic) -> UInt64 {
    buckets.reduce(0) { $0 + UInt64($1.validSamples(metric, statistic: statistic)) }
  }
  public func value(_ metric: HistoryMetric, statistic: HistoryStatistic) -> Double? {
    var value: Double?
    var samples: UInt64 = 0
    for bucket in buckets {
      guard let next = bucket.value(metric, statistic: statistic) else { continue }
      let count = UInt64(bucket.validSamples(metric, statistic: statistic))
      guard count > 0 else { continue }
      value =
        value.flatMap { statistic.combined($0, samples: samples, with: next, samples: count) }
        ?? next
      samples += count
    }
    return value
  }
  /// Fixed slot centers shared by CPU overview and core graphics; partial last slot is clipped.
  public var bucketCenters: [Date] {
    let end = buckets.last?.last ?? Date(timeIntervalSince1970: 0)
    let start = end - Double(range.rawValue)
    return buckets.map { bucket in
      let seconds =
        floor(bucket.last.timeIntervalSince1970 / range.resolution) * range.resolution + range
        .resolution / 2
      return min(end, max(start, Date(timeIntervalSince1970: seconds)))
    }
  }
  public var latestCPUCoreKinds: [CPUCoreKind]? {
    buckets.reversed().lazy.compactMap(\.latestCoreKinds).first
  }
  public func cpuCoreValidSamples(_ index: Int, kinds: [CPUCoreKind]) -> UInt64 {
    buckets.reduce(0) { total, bucket in
      total
        + UInt64(bucket.cpuCores.flatMap { $0.kinds == kinds ? $0.validSamples(index) : nil } ?? 0)
    }
  }
  public func cpuCoreValue(_ index: Int, kinds: [CPUCoreKind], statistic: HistoryStatistic)
    -> Double?
  {
    var result: Double?
    var count: UInt64 = 0
    for bucket in buckets {
      guard let cores = bucket.cpuCores, cores.kinds == kinds,
        let value = cores.value(index, statistic: statistic)
      else { continue }
      let next = UInt64(cores.validSamples(index))
      result =
        result.flatMap { statistic.combined($0, samples: count, with: value, samples: next) }
        ?? value
      count += next
    }
    return result
  }
  /// A bounded numeric CSV, with explicit units, validity counts and UTC sample bounds.
  /// Empty cells mean unavailable; peaks are not interval means or transfer totals.
  public var csv: String {
    var rows = [
      ["first_sample_utc", "last_sample_utc", "bucket_seconds", "sample_count", "contains_gap"]
        + HistoryMetric.allCases.flatMap { [$0.column, $0.column + "_valid_samples"] }
        + HistoryMetric.allCases.flatMap {
          [
            $0.aggregateColumn + "_minimum", $0.aggregateColumn + "_sample_average",
            $0.aggregateColumn + "_statistic_valid_samples",
          ]
        }
    ]
    let date = ISO8601DateFormatter()
    date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for bucket in buckets {
      var row = [
        date.string(from: bucket.first), date.string(from: bucket.last),
        String(range.resolution), String(bucket.samples), bucket.hasGap ? "true" : "false",
      ]
      for metric in HistoryMetric.allCases {
        row += [bucket[metric].map { String($0) } ?? "", String(bucket.validSamples(metric))]
      }
      for metric in HistoryMetric.allCases {
        row += [
          bucket.value(metric, statistic: .minimum).map { String($0) } ?? "",
          bucket.value(metric, statistic: .average).map { String($0) } ?? "",
          String(bucket.validSamples(metric, statistic: .average)),
        ]
      }
      rows.append(row)
    }
    let coreCount = buckets.compactMap { $0.latestCoreKinds?.count }.max() ?? 0
    if coreCount > 0 || buckets.contains(where: \.coreLayoutChanged) {
      rows[0] +=
        ["cpu_core_layout_changed"]
        + (0..<coreCount).flatMap { index in
          let name = "cpu_logical_core_\(index + 1)"
          return [
            name + "_kind", name + "_peak_percent", name + "_minimum_percent",
            name + "_sample_average_percent", name + "_valid_samples",
          ]
        }
      for (rowIndex, bucket) in buckets.enumerated() {
        rows[rowIndex + 1].append(bucket.coreLayoutChanged ? "true" : "false")
        for index in 0..<coreCount {
          let core = bucket.cpuCores
          let kind = bucket.latestCoreKinds.flatMap {
            $0.indices.contains(index) ? $0[index].rawValue : nil
          }
          rows[rowIndex + 1] +=
            [kind ?? ""]
            + [HistoryStatistic.peak, .minimum, .average].map {
              core?.value(index, statistic: $0).map { String($0) } ?? ""
            } + [String(core?.validSamples(index) ?? 0)]
        }
      }
    }
    return rows.map { $0.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
  }
}

public struct SessionHistory: Sendable {
  private struct Level: Sendable {
    let range: HistoryRange
    var completed = RingBuffer<HistoryBucket>(capacity: 300)
    var active: HistoryBucket?
    var slot: Double?
    mutating func append(_ point: HistoryPoint, values: [Double?], gap: Bool) {
      let cutoff = point.time - Double(range.rawValue)
      completed.removeFirst { $0.last <= cutoff }
      if let active, active.last <= cutoff {
        self.active = nil
        slot = nil
      }
      let next = floor(point.time.timeIntervalSince1970 / range.resolution)
      if slot == next {
        active?.append(point, values: values, gap: gap)
      } else {
        if let active { completed.append(active) }
        active = HistoryBucket(point, values: values, gap: gap)
        slot = next
      }
    }
    var buckets: [HistoryBucket] { completed.elements + (active.map { [$0] } ?? []) }
  }
  private var levels = HistoryRange.retentionRanges.map { Level(range: $0) }
  private var lastDate: Date?, lastUptime: Double?, lastInterval: Double?
  private var pendingGap = false
  public private(set) var resets: UInt64 = 0
  public var retainedBucketCount: Int {
    levels.reduce(0) { $0 + $1.completed.count + ($1.active == nil ? 0 : 1) }
  }
  public static var maximumBuckets: Int { HistoryRange.retentionRanges.count * 301 }
  public init() {}
  @discardableResult public mutating func append(
    _ point: HistoryPoint, uptime: Double, preservingPastOnReset: Bool = false
  ) -> Bool {
    let seconds = point.time.timeIntervalSince1970
    guard seconds.isFinite, (-62_135_596_800...253_402_300_799).contains(seconds),
      uptime.isFinite, uptime >= 0,
      let interval = point.sampleInterval, interval.isFinite, interval >= 1, interval <= 3600
    else {
      pendingGap = true
      return false
    }
    if let lastDate, let lastUptime, uptime > lastUptime, point.time <= lastDate,
      lastDate.timeIntervalSince(point.time) <= 300
    {
      pendingGap = true
      return false
    }
    let restoredClockReset = lastDate.map { lastUptime == nil && point.time <= $0 } ?? false
    let timelineReset: Bool
    if let lastDate, let lastUptime {
      timelineReset = point.time <= lastDate || uptime <= lastUptime
    } else {
      timelineReset = false
    }
    if restoredClockReset || timelineReset {
      if preservingPastOnReset || restoredClockReset {
        for index in levels.indices {
          let range = levels[index].range
          let past = levels[index].buckets.filter {
            $0.last < point.time && $0.last > point.time - Double(range.rawValue)
          }
          levels[index] = Level(range: range)
          for bucket in past.dropLast() { levels[index].completed.append(bucket) }
          if let active = past.last {
            levels[index].active = active
            levels[index].slot = floor(active.last.timeIntervalSince1970 / range.resolution)
          }
        }
        pendingGap = true
      } else {
        levels = HistoryRange.retentionRanges.map { Level(range: $0) }
      }
      resets = resets == .max ? .max : resets + 1
      self.lastDate = nil
      self.lastUptime = nil
    }
    let expected = max(interval, lastInterval ?? interval)
    let gap =
      pendingGap
      // systemUptime excludes sleep; wall time is also required to reveal wake gaps.
      || (lastDate.map { point.time.timeIntervalSince($0) > expected * 2.5 } ?? false)
      || (lastUptime.map { uptime - $0 > expected * 2.5 } ?? false)
    var values = HistoryMetric.allCases.map { $0.value(in: point) }
    if let cpu = values[0], let user = values[1], let system = values[2],
      abs(cpu - user - system) > 0.01
    {
      values[1] = nil
      values[2] = nil
    }
    for index in levels.indices { levels[index].append(point, values: values, gap: gap) }
    pendingGap = false
    lastDate = point.time
    lastUptime = uptime
    lastInterval = interval
    return true
  }
  public func projection(_ range: HistoryRange) -> HistoryProjection {
    guard let level = levels.first(where: { $0.range == range.storageRange }), let lastDate else {
      return HistoryProjection(range: range, resets: resets)
    }
    let cutoff = lastDate.addingTimeInterval(-Double(range.rawValue))
    return HistoryProjection(
      range: range, buckets: level.buckets.filter { $0.last > cutoff }, resets: resets)
  }
}

public enum HistoryCheckpointError: Error, Equatable, Sendable {
  case invalidData, unsupportedVersion
}

extension SessionHistory {
  /// Preserve disjoint older observations when saving is re-enabled. Overlapping observations
  /// remain memory-authoritative; disjoint bounds in the same slot can be aggregated exactly.
  @discardableResult public mutating func mergeOlder(_ saved: SessionHistory, now: Date) -> Bool {
    var imported = false
    var latest: Date?
    var hasMemory = false
    for index in levels.indices {
      let range = levels[index].range
      let cutoff = now - Double(range.rawValue)
      var memory = levels[index].buckets.filter { $0.last <= now && $0.last > cutoff }
      hasMemory = hasMemory || !memory.isEmpty
      var older = saved.levels[index].buckets.filter { bucket in
        bucket.last <= now && bucket.last > cutoff
          && (memory.first.map { bucket.last < $0.first } ?? true)
      }
      if !older.isEmpty {
        imported = true
        if let first = memory.first, let last = older.last,
          floor(first.first.timeIntervalSince1970 / range.resolution)
            == floor(last.first.timeIntervalSince1970 / range.resolution)
        {
          var joined = older.removeLast()
          joined.mergeLater(first)
          memory[0] = joined
        } else if !memory.isEmpty {
          memory[0].markJoinGap()
        }
      }
      let combined = Array((older + memory).suffix(301))
      levels[index] = Level(range: range)
      for bucket in combined.dropLast() { levels[index].completed.append(bucket) }
      if let active = combined.last {
        levels[index].active = active
        levels[index].slot = floor(active.last.timeIntervalSince1970 / range.resolution)
        latest = max(latest ?? active.last, active.last)
      }
    }
    lastDate = latest
    if imported {
      // Cumulative counters may overlap; never double-count their unknown provenance.
      resets = max(resets, saved.resets)
      if !hasMemory { pendingGap = true }
    }
    return imported
  }

  /// v3 adds 17 wire bytes per recorded logical core (kind + packed statistics).
  /// Legacy peak-only/statistic checkpoints stay readable; no layout is invented for them.
  public static var maximumScalarCheckpointBytes: Int { 24 + 6 * 8 + maximumBuckets * 420 + 4 }
  public static var maximumCheckpointBytes: Int {
    maximumScalarCheckpointBytes + maximumBuckets * (2 + CPUCoreHistorySample.maximumCores * 17)
  }
  private var checkpointVersion: UInt16 {
    levels.contains { level in
      level.buckets.contains { $0.cpuCores != nil || $0.coreLayoutChanged }
    } ? 3 : 2
  }
  public func checkpoint() -> Data {
    let version = checkpointVersion
    var result = Data()
    let bytes = levels.reduce(24 + 4) { total, level in
      total + 8 + level.buckets.reduce(0) { $0 + $1.checkpointByteCount(version: version) }
    }
    result.reserveCapacity(bytes)
    serializeCheckpoint(version: version) { result.append(contentsOf: $0) }
    return result
  }

  /// Synchronous borrowed chunks of at most 64 KiB. The sink must consume each chunk before
  /// returning; its bytes are reused. Produces the same v2/v3 bytes as checkpoint(), without
  /// retaining a complete encoded archive. A throwing sink stops serialization immediately.
  public func writeCheckpoint(to sink: (UnsafeRawBufferPointer) throws -> Void) rethrows {
    try serializeCheckpoint(version: checkpointVersion, to: sink)
  }
  private func serializeCheckpoint(
    version: UInt16, to sink: (UnsafeRawBufferPointer) throws -> Void
  ) rethrows {
    var writer = HistoryCheckpointWriter()
    for byte in Array("TNYHIST\0".utf8) { writer.integer(byte) }
    writer.integer(version)
    writer.integer(UInt16(HistoryMetric.allCases.count))
    writer.integer(UInt16(levels.count))
    writer.integer(UInt16(0))
    writer.integer(resets)
    for level in levels {
      let buckets = level.buckets
      try writer.makeRoom(for: 8, to: sink)
      writer.integer(UInt32(level.range.rawValue))
      writer.integer(UInt16(buckets.count))
      writer.integer(UInt16(0))
      for bucket in buckets {
        let count = bucket.checkpointByteCount(version: version)
        try writer.makeRoom(for: count, to: sink)
        let start = writer.data.count
        bucket.checkpoint(to: &writer, version: version)
        assert(
          writer.data.count - start == count
            && writer.data.count <= HistoryCheckpointWriter.chunkBytes)
      }
    }
    try writer.makeRoom(for: 4, to: sink)
    writer.updateChecksum()
    writer.integer(writer.remainder ^ .max)
    try writer.data.withUnsafeBytes(sink)
  }

  public init(checkpoint data: Data, now: Date) throws {
    self.init()
    guard data.count >= 76, data.count <= Self.maximumCheckpointBytes,
      now.timeIntervalSince1970.isFinite
    else { throw HistoryCheckpointError.invalidData }
    var trailer = HistoryCheckpointReader(data: data, offset: data.count - 4, limit: data.count)
    let checksum: UInt32 = try trailer.integer()
    guard historyCheckpointCRC(data, count: data.count - 4) == checksum else {
      throw HistoryCheckpointError.invalidData
    }
    var reader = HistoryCheckpointReader(data: data, limit: data.count - 4)
    try restoreCheckpoint(from: &reader, now: now)
  }

  /// The source is consumed synchronously into one bounded buffer. Never memory-map a mutable
  /// checkpoint: truncation by another process must remain a recoverable read failure.
  init(
    checkpointByteCount: Int, now: Date,
    read: @escaping (UnsafeMutableRawBufferPointer) throws -> Int
  ) throws {
    self.init()
    guard (76...Self.maximumCheckpointBytes).contains(checkpointByteCount),
      now.timeIntervalSince1970.isFinite
    else { throw HistoryCheckpointError.invalidData }
    var reader = HistoryCheckpointReader(byteCount: checkpointByteCount, read: read)
    do {
      try restoreCheckpoint(from: &reader, now: now)
    } catch {
      // Keep the Data decoder's checksum-first error precedence, including unsupported
      // versions. A source failure is terminal; it must not trigger more read attempts.
      try reader.finish()
      throw error
    }
    try reader.finish()
  }
  private mutating func restoreCheckpoint(
    from reader: inout HistoryCheckpointReader, now: Date
  ) throws {
    for byte in Array("TNYHIST\0".utf8) {
      let actual: UInt8 = try reader.integer()
      guard actual == byte else { throw HistoryCheckpointError.invalidData }
    }
    let version: UInt16 = try reader.integer()
    guard (1...3).contains(version) else { throw HistoryCheckpointError.unsupportedVersion }
    let metrics: UInt16 = try reader.integer()
    let count: UInt16 = try reader.integer()
    let reserved: UInt16 = try reader.integer()
    guard metrics == 12, metrics == HistoryMetric.allCases.count, count == levels.count,
      reserved == 0
    else { throw HistoryCheckpointError.invalidData }
    resets = try reader.integer()
    for index in levels.indices {
      let range = levels[index].range
      let seconds: UInt32 = try reader.integer()
      let count: UInt16 = try reader.integer()
      let reserved: UInt16 = try reader.integer()
      guard seconds == range.rawValue, count <= 301, reserved == 0 else {
        throw HistoryCheckpointError.invalidData
      }
      var previousSlot: Double?
      var retained: [HistoryBucket] = []
      for _ in 0..<Int(count) {
        let bucket = try HistoryBucket(checkpoint: &reader, version: version)
        let slot = floor(bucket.first.timeIntervalSince1970 / range.resolution)
        guard slot == floor(bucket.last.timeIntervalSince1970 / range.resolution),
          previousSlot.map({ slot > $0 }) ?? true
        else { throw HistoryCheckpointError.invalidData }
        previousSlot = slot
        // Do not relabel future peaks after a clock correction, or resurrect expired data.
        if bucket.last <= now, bucket.last > now.addingTimeInterval(-Double(range.rawValue)) {
          retained.append(bucket)
        }
      }
      for bucket in retained.dropLast() { levels[index].completed.append(bucket) }
      if let active = retained.last {
        levels[index].active = active
        levels[index].slot = floor(active.last.timeIntervalSince1970 / range.resolution)
        lastDate = max(lastDate ?? active.last, active.last)
      }
    }
    guard reader.offset == reader.limit else { throw HistoryCheckpointError.invalidData }
    // Uptime belongs to this process/boot only. A restart is an explicit discontinuity.
    lastUptime = nil
    lastInterval = nil
    pendingGap = lastDate != nil
  }
}

extension HistoryBucket {
  fileprivate mutating func markJoinGap() { hasGap = true }
  fileprivate mutating func mergeLater(_ later: HistoryBucket) {
    precondition(last < later.first)
    let known = (later.peaks[1] == nil ? 0 : 1) + (later.peaks[2] == nil ? 0 : 1)
    let oldKnown = (peaks[1] == nil ? 0 : 1) + (peaks[2] == nil ? 0 : 1)
    let replaceCPU =
      later.peaks[0].map {
        $0 > (peaks[0] ?? -1) || ($0 == peaks[0] && known >= oldKnown)
      } ?? false
    func sum(_ first: UInt32, _ second: UInt32) -> UInt32 {
      UInt32(min(UInt64(UInt32.max), UInt64(first) + UInt64(second)))
    }
    for metric in HistoryMetric.allCases {
      let index = metric.rawValue
      counts[index] = sum(counts[index], later.counts[index])
      if !later.statistics.isEmpty {
        if statistics.isEmpty {
          statistics = Array(repeating: HistoryStatistics(), count: HistoryMetric.allCases.count)
        }
        statistics[index].merge(later.statistics[index])
      }
      if metric == .cpuUser || metric == .cpuSystem {
        if replaceCPU { peaks[index] = later.peaks[index] }
      } else if let value = later.peaks[index] {
        peaks[index] = max(peaks[index] ?? -.infinity, value)
      }
    }
    latestCoreKinds = later.latestCoreKinds ?? latestCoreKinds
    if coreLayoutChanged || later.coreLayoutChanged {
      cpuCores = nil
      coreLayoutChanged = true
    } else if let next = later.cpuCores {
      if cpuCores != nil {
        if cpuCores?.kinds == next.kinds {
          cpuCores?.merge(next)
        } else {
          cpuCores = nil
          coreLayoutChanged = true
        }
      } else {
        cpuCores = next
      }
    }
    samples = sum(samples, later.samples)
    last = later.last
    maximumSampleInterval = max(maximumSampleInterval, later.maximumSampleInterval)
    hasGap = true
  }

  fileprivate func checkpointByteCount(version: UInt16) -> Int {
    420
      + (version == 3
        ? 2
          + (coreLayoutChanged
            ? 2 + (latestCoreKinds?.count ?? 0) : (cpuCores?.count ?? 0) * 17)
        : 0)
  }

  fileprivate func checkpoint(to writer: inout HistoryCheckpointWriter, version: UInt16) {
    writer.double(first.timeIntervalSinceReferenceDate)
    writer.double(last.timeIntervalSinceReferenceDate)
    writer.double(maximumSampleInterval)
    writer.integer(samples)
    writer.integer(UInt32(hasGap ? 1 : 0))
    let mask = peaks.enumerated().reduce(UInt16(0)) { mask, pair in
      pair.element == nil ? mask : mask | (1 << pair.offset)
    }
    writer.integer(mask)
    writer.integer(UInt16(0))
    for index in peaks.indices {
      writer.double(peaks[index] ?? 0)
      writer.integer(counts[index])
    }
    for index in peaks.indices {
      let aggregate = statistics.indices.contains(index) ? statistics[index] : HistoryStatistics()
      writer.double(aggregate.minimum)
      writer.double(aggregate.mean)
      writer.integer(aggregate.count)
    }
    if version == 3 {
      writer.integer(coreLayoutChanged ? UInt16.max : UInt16(cpuCores?.count ?? 0))
      if coreLayoutChanged {
        let kinds = latestCoreKinds ?? []
        writer.integer(UInt16(kinds.count))
        for kind in kinds {
          writer.integer(UInt8(kind == .efficiency ? 1 : kind == .performance ? 2 : 0))
        }
      } else if let cores = cpuCores {
        for index in cores.kinds.indices {
          writer.integer(
            UInt8(
              cores.kinds[index] == .efficiency ? 1 : cores.kinds[index] == .performance ? 2 : 0))
          let value = cores.statistics[index]
          writer.integer(value.peak.bitPattern)
          writer.integer(value.minimum.bitPattern)
          writer.integer(value.mean.bitPattern)
          writer.integer(value.count)
        }
      }
    }
  }
  fileprivate init(checkpoint reader: inout HistoryCheckpointReader, version: UInt16) throws {
    let first = try reader.double()
    let last = try reader.double()
    let cadence = try reader.double()
    let samples: UInt32 = try reader.integer()
    let flags: UInt32 = try reader.integer()
    let mask: UInt16 = try reader.integer()
    let reserved: UInt16 = try reader.integer()
    guard first.isFinite, last.isFinite,
      (-63_113_904_000...252_423_993_599).contains(first),
      (-63_113_904_000...252_423_993_599).contains(last), first <= last,
      cadence.isFinite, (1...3600).contains(cadence), samples > 0, flags <= 1,
      mask < (1 << HistoryMetric.allCases.count), reserved == 0
    else { throw HistoryCheckpointError.invalidData }
    self.first = Date(timeIntervalSinceReferenceDate: first)
    self.last = Date(timeIntervalSinceReferenceDate: last)
    self.samples = samples
    self.hasGap = flags == 1
    self.maximumSampleInterval = cadence
    for metric in HistoryMetric.allCases {
      let value = try reader.double()
      let count: UInt32 = try reader.integer()
      let present = mask & (1 << metric.rawValue) != 0
      guard value.isFinite, count <= samples else { throw HistoryCheckpointError.invalidData }
      if present {
        guard count > 0 else { throw HistoryCheckpointError.invalidData }
        if metric != .temperature {
          guard value >= 0 else { throw HistoryCheckpointError.invalidData }
          switch metric {
          case .cpu, .cpuUser, .cpuSystem, .gpu, .memory, .diskUsed, .battery:
            guard value <= 100 else { throw HistoryCheckpointError.invalidData }
          default: break
          }
        }
      } else {
        guard value == 0,
          count == 0 || metric == .cpuUser || metric == .cpuSystem
        else { throw HistoryCheckpointError.invalidData }
      }
      peaks[metric.rawValue] = present ? value : nil
      counts[metric.rawValue] = count
    }
    if version >= 2 {
      var decoded: [HistoryStatistics] = []
      decoded.reserveCapacity(HistoryMetric.allCases.count)
      for metric in HistoryMetric.allCases {
        let minimum = try reader.double()
        let mean = try reader.double()
        let count: UInt32 = try reader.integer()
        guard minimum.isFinite, mean.isFinite, count <= counts[metric.rawValue] else {
          throw HistoryCheckpointError.invalidData
        }
        if count == 0 || count == .max {
          guard minimum == 0, mean == 0 else { throw HistoryCheckpointError.invalidData }
        } else {
          guard metric.accepts(minimum), metric.accepts(mean), minimum <= mean,
            count != 1 || minimum == mean
          else { throw HistoryCheckpointError.invalidData }
          if metric != .cpuUser && metric != .cpuSystem {
            guard let peak = self[metric], mean <= peak else {
              throw HistoryCheckpointError.invalidData
            }
            if count == counts[metric.rawValue] {
              if count == 1 {
                guard peak == mean else { throw HistoryCheckpointError.invalidData }
              } else if count == 2,
                let expected = HistoryStatistic.average.combined(
                  minimum, samples: 1, with: peak, samples: 1)
              {
                // Two fully covered observations must be the recorded minimum and peak.
                // Allow the rounding difference from either incremental evaluation order.
                let tolerance = max(abs(expected), abs(mean)).ulp * 16
                guard abs(expected - mean) <= tolerance else {
                  throw HistoryCheckpointError.invalidData
                }
              }
            }
          }
        }
        decoded.append(.init(minimum: minimum, mean: mean, count: count))
      }
      if decoded.contains(where: { $0.count > 0 }) { statistics = decoded }
    }
    if version == 3 {
      let count: UInt16 = try reader.integer()
      if count == .max {
        coreLayoutChanged = true
        let count: UInt16 = try reader.integer()
        guard (1...CPUCoreHistorySample.maximumCores).contains(Int(count)) else {
          throw HistoryCheckpointError.invalidData
        }
        var kinds: [CPUCoreKind] = []
        kinds.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
          let kind: UInt8 = try reader.integer()
          guard kind <= 2 else { throw HistoryCheckpointError.invalidData }
          kinds.append(kind == 1 ? .efficiency : kind == 2 ? .performance : .unknown)
        }
        latestCoreKinds = kinds
      } else {
        guard count <= CPUCoreHistorySample.maximumCores else {
          throw HistoryCheckpointError.invalidData
        }
        var kinds: [CPUCoreKind] = []
        kinds.reserveCapacity(Int(count))
        var values: [CPUCoreStatistics] = []
        values.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
          let kind: UInt8 = try reader.integer()
          let peak = Float(bitPattern: try reader.integer())
          let minimum = Float(bitPattern: try reader.integer())
          let mean = Float(bitPattern: try reader.integer())
          let valid: UInt32 = try reader.integer()
          guard kind <= 2, peak.isFinite, minimum.isFinite, mean.isFinite, valid <= samples else {
            throw HistoryCheckpointError.invalidData
          }
          if valid == 0 || valid == .max {
            guard peak == 0, minimum == 0, mean == 0 else {
              throw HistoryCheckpointError.invalidData
            }
          } else {
            guard minimum >= 0, minimum <= mean, mean <= peak, peak <= 100,
              valid != 1 || minimum == peak
            else { throw HistoryCheckpointError.invalidData }
          }
          if valid == 2 {
            let expected = Float((Double(minimum) + Double(peak)) / 2)
            guard abs(mean - expected) <= max(abs(mean), abs(expected)).ulp * 8 else {
              throw HistoryCheckpointError.invalidData
            }
          }
          kinds.append(kind == 1 ? .efficiency : kind == 2 ? .performance : .unknown)
          values.append(.init(peak: peak, minimum: minimum, mean: mean, count: valid))
        }
        if count > 0 {
          cpuCores = .init(kinds: kinds, statistics: values)
          latestCoreKinds = kinds
        }
      }
    }
    if let user = self[.cpuUser], let system = self[.cpuSystem] {
      guard let cpu = self[.cpu], abs(cpu - user - system) <= 0.01 else {
        throw HistoryCheckpointError.invalidData
      }
    }
    if self[.cpu] == nil, self[.cpuUser] != nil || self[.cpuSystem] != nil {
      throw HistoryCheckpointError.invalidData
    }
  }
}

private struct HistoryCheckpointWriter {
  static let chunkBytes = 64 * 1024
  var data = Data()
  var remainder: UInt32 = .max
  init() { data.reserveCapacity(Self.chunkBytes) }
  mutating func makeRoom(
    for count: Int, to sink: (UnsafeRawBufferPointer) throws -> Void
  ) rethrows {
    precondition(count <= Self.chunkBytes)
    if data.count + count > Self.chunkBytes {
      updateChecksum()
      try data.withUnsafeBytes(sink)
      data.removeAll(keepingCapacity: true)
    }
  }
  mutating func updateChecksum() {
    data.withUnsafeBytes { bytes in
      for byte in bytes {
        remainder =
          (remainder >> 8) ^ historyCheckpointCRCTable[Int((remainder ^ UInt32(byte)) & 255)]
      }
    }
  }
  mutating func integer<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
  mutating func double(_ value: Double) { integer(value.bitPattern) }
}
private struct HistoryCheckpointReader {
  static let chunkBytes = 64 * 1024
  private var data: Data
  var offset: Int
  let limit: Int
  private var cursor: Int
  private var available: Int
  private var fetched = 0
  private var remainder: UInt32 = .max
  private var sourceError: (any Error)?
  private let source: ((UnsafeMutableRawBufferPointer) throws -> Int)?

  init(data: Data, offset: Int = 0, limit: Int) {
    self.data = data
    self.offset = offset
    self.limit = limit
    cursor = offset
    available = data.count
    source = nil
  }
  init(byteCount: Int, read: @escaping (UnsafeMutableRawBufferPointer) throws -> Int) {
    data = Data(count: min(Self.chunkBytes, byteCount))
    offset = 0
    limit = byteCount - 4
    cursor = 0
    available = 0
    source = read
  }
  /// Fill exactly the requested bounded region. Positive short reads are normal.
  private mutating func readExactly(_ count: Int) throws {
    guard let source else { throw HistoryCheckpointError.invalidData }
    do {
      try data.withUnsafeMutableBytes { bytes in
        var used = 0
        while used < count {
          let target = UnsafeMutableRawBufferPointer(rebasing: bytes[used..<count])
          let received = try source(target)
          guard received > 0, received <= target.count else {
            throw HistoryCheckpointError.invalidData
          }
          used += received
        }
      }
    } catch {
      sourceError = error
      throw error
    }
  }
  private mutating func refill() throws {
    let count = min(Self.chunkBytes, limit - fetched)
    guard count > 0 else { throw HistoryCheckpointError.invalidData }
    try readExactly(count)
    var crc = remainder
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      for byte in bytes.prefix(count) {
        crc = (crc >> 8) ^ historyCheckpointCRCTable[Int((crc ^ UInt32(byte)) & 255)]
      }
    }
    remainder = crc
    fetched += count
    cursor = 0
    available = count
  }
  mutating func integer<T: FixedWidthInteger>() throws -> T {
    let size = MemoryLayout<T>.size
    guard offset >= 0, offset <= limit - size else {
      throw HistoryCheckpointError.invalidData
    }
    // Data mode holds the entire byte region, so every valid field takes this raw-buffer
    // path, including Data slices whose collection indices do not start at zero.
    if available - cursor >= size {
      let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
      offset += size
      cursor += size
      return T(littleEndian: value)
    }
    // Fields can straddle any chunk/short-read boundary, including packed 17-byte core records.
    var value: T = 0
    for index in 0..<size {
      if cursor == available { try refill() }
      value |= T(truncatingIfNeeded: data[cursor]) << (index * 8)
      cursor += 1
      offset += 1
    }
    return value
  }
  mutating func double() throws -> Double {
    Double(bitPattern: try integer() as UInt64)
  }
  mutating func finish() throws {
    if let sourceError { throw sourceError }
    guard let source else { throw HistoryCheckpointError.invalidData }
    // A malformed early header still needs CRC validation to preserve error precedence.
    while fetched < limit { try refill() }
    try readExactly(4)
    let expected = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    var extra: UInt8 = 0
    let trailing = try withUnsafeMutableBytes(of: &extra) { try source($0) }
    guard trailing == 0, remainder ^ .max == expected else {
      throw HistoryCheckpointError.invalidData
    }
  }
}
private let historyCheckpointCRCTable: [UInt32] = (0..<256).map { value in
  var remainder = UInt32(value)
  for _ in 0..<8 {
    remainder = (remainder >> 1) ^ (remainder & 1 == 0 ? 0 : 0xEDB8_8320)
  }
  return remainder
}
private func historyCheckpointCRC(_ data: Data, count: Int) -> UInt32 {
  var remainder: UInt32 = .max
  data.withUnsafeBytes { bytes in
    for index in 0..<count {
      remainder =
        (remainder >> 8) ^ historyCheckpointCRCTable[Int((remainder ^ UInt32(bytes[index])) & 255)]
    }
  }
  return remainder ^ .max
}
