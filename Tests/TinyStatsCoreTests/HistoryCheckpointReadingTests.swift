import Darwin
import Foundation
import Testing
import TinyStatsTestSupport

@testable import TinyStatsCore

private enum CheckpointReadFailure: Error, Equatable { case stopped }

private final class CheckpointSource {
  let data: Data
  var fragment: Int
  var failureAt: Int?
  var offset = 0
  var requests: [Int] = []
  var failed = false
  var callsAfterFailure = 0
  init(_ data: Data, fragment: Int = 65_536) {
    self.data = data
    self.fragment = fragment
  }
  func read(_ buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    requests.append(buffer.count)
    if failed { callsAfterFailure += 1 }
    if let failureAt, offset >= failureAt {
      failed = true
      throw CheckpointReadFailure.stopped
    }
    let count = min(buffer.count, fragment, data.count - offset, (failureAt ?? data.count) - offset)
    if count > 0 { data.copyBytes(to: buffer, from: offset..<(offset + count)) }
    offset += count
    return count
  }
  func restore(now: Date, byteCount: Int? = nil) throws -> SessionHistory {
    try SessionHistory(checkpointByteCount: byteCount ?? data.count, now: now, read: read)
  }
}
private func readingCRC(_ input: Data) -> Data {
  var data = Data(input.dropLast(4))
  var crc: UInt32 = .max
  for byte in data {
    crc ^= UInt32(byte)
    for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
  }
  var value = (crc ^ .max).littleEndian
  withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  return data
}
/// Independent v3 core records appended to independent v2 scalar records, not the app encoder.
private func readingV3(now: Date, cores: Int, maximum: Bool) -> Data {
  let legacy = HistoryFixtures.populatedCheckpoint(version: 2, now: now, maximum: maximum)
  var data = Data(legacy.prefix(24))
  data[8] = 3
  func integer<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
  var offset = 24
  for _ in 0..<6 {
    data.append(legacy[offset..<(offset + 4)])
    integer(UInt16(maximum ? 301 : 2))
    integer(UInt16(0))
    offset += 8
    for index in 0..<(maximum ? 301 : 300) {
      defer { offset += 420 }
      if !maximum && index < 298 { continue }
      data.append(legacy[offset..<(offset + 420)])
      let quarantine = !maximum && index == 299
      integer(quarantine ? UInt16.max : UInt16(cores))
      if quarantine { integer(UInt16(cores)) }
      for core in 0..<cores {
        integer(UInt8(core % 3))
        if quarantine { continue }
        for _ in 0..<3 { integer(Float((index + core) % 101).bitPattern) }
        integer(UInt32(1))
      }
    }
  }
  integer(UInt32(0))
  return readingCRC(data)
}
private let readingNow = Date(timeIntervalSince1970: 1_792_673_280.25)

// Bound large synthetic-fixture demand while other native IPC/deadline tests run.
@Suite(.serialized) struct HistoryCheckpointReadingTests {
  @Test func historyStreamReadingPreservesLegacyScalarMaximumCoresAndRetention() throws {
    let fixtures = [
      SessionHistory().checkpoint(),
      HistoryFixtures.populatedCheckpoint(version: 1, now: readingNow, maximum: true),
      HistoryFixtures.populatedCheckpoint(version: 2, now: readingNow, maximum: true),
      readingV3(now: readingNow, cores: 10, maximum: false),
      readingV3(now: readingNow, cores: 256, maximum: true),
    ]
    #expect(fixtures.last?.count == SessionHistory.maximumCheckpointBytes)
    for data in fixtures {
      let expected = try SessionHistory(checkpoint: data, now: readingNow)
      let source = CheckpointSource(data)
      let restored = try source.restore(now: readingNow)
      #expect(restored.checkpoint() == expected.checkpoint())
      for range in HistoryRange.allCases {
        #expect(restored.projection(range).csv == expected.projection(range).csv)
      }
      #expect(source.offset == data.count && source.requests.last == 1)
      #expect(source.requests.allSatisfy { (1...65_536).contains($0) })
      if data.count > 65_536 { #expect(source.requests.count > 2) }
    }
    let data = fixtures[3]
    for now in [readingNow - 10, readingNow + Double(HistoryRange.fourWeeks.rawValue) + 1] {
      let expected = try SessionHistory(checkpoint: data, now: now)
      let actual = try CheckpointSource(data).restore(now: now)
      #expect(actual.checkpoint() == expected.checkpoint())
    }
  }

  @Test func historyStreamReadingHandlesShortReadsPackedFieldsAndTrailerBoundaries() throws {
    for data in [
      SessionHistory().checkpoint(), readingV3(now: readingNow, cores: 10, maximum: false),
    ] {
      let expected = try SessionHistory(checkpoint: data, now: readingNow).checkpoint()
      for fragment in [1, 2, 3, 7, 17, 4093, 65_536] {
        let source = CheckpointSource(data, fragment: fragment)
        #expect(try source.restore(now: readingNow).checkpoint() == expected)
      }
    }
    // Scalar records are 420 bytes; packed core records are 17 bytes, crossing 64KiB boundaries.
    let large = readingV3(now: readingNow, cores: 10, maximum: true)
    let source = CheckpointSource(large, fragment: 4093)
    #expect(try source.restore(now: readingNow).checkpoint() == large)
  }

  @Test func historyStreamReadingKeepsChecksumPrecedenceAndStructuralValidation() throws {
    let original = readingV3(now: readingNow, cores: 10, maximum: false)
    for (offset, byte) in [
      (0, UInt8(0)), (10, 13), (12, 7), (14, 1), (28, 255), (60, 2), (454, 255),
    ] {
      var invalid = original
      invalid[offset] = byte
      invalid = readingCRC(invalid)
      #expect(throws: HistoryCheckpointError.invalidData) {
        try CheckpointSource(invalid).restore(now: readingNow)
      }
      #expect(throws: HistoryCheckpointError.invalidData) {
        try SessionHistory(checkpoint: invalid, now: readingNow)
      }
    }
    var unsupported = original
    unsupported[8] = 4
    #expect(throws: HistoryCheckpointError.invalidData) {
      try CheckpointSource(unsupported).restore(now: readingNow)
    }
    unsupported = readingCRC(unsupported)
    #expect(throws: HistoryCheckpointError.unsupportedVersion) {
      try CheckpointSource(unsupported).restore(now: readingNow)
    }
    var lateCorrupt = readingV3(now: readingNow, cores: 10, maximum: true)
    lateCorrupt[lateCorrupt.count - 8] ^= 1
    #expect(throws: HistoryCheckpointError.invalidData) {
      try CheckpointSource(lateCorrupt).restore(now: readingNow)
    }
  }

  @Test func historyStreamReadingRejectsTruncationExtraBytesAndStopsAfterSourceFailure() throws {
    let data = readingV3(now: readingNow, cores: 10, maximum: true)
    for end in [0, 10, 65_535, 65_536, data.count - 4, data.count - 1] {
      let source = CheckpointSource(Data(data.prefix(end)))
      #expect(throws: HistoryCheckpointError.invalidData) {
        try source.restore(now: readingNow, byteCount: data.count)
      }
    }
    var extra = data
    extra.append(1)
    #expect(throws: HistoryCheckpointError.invalidData) {
      try CheckpointSource(extra).restore(now: readingNow, byteCount: data.count)
    }
    for failureAt in [0, 10, 65_535, 65_536, data.count - 4, data.count - 1, data.count] {
      let source = CheckpointSource(data)
      source.failureAt = failureAt
      #expect(throws: CheckpointReadFailure.stopped) { try source.restore(now: readingNow) }
      #expect(source.failed && source.callsAfterFailure == 0)
    }
    for result in [-1, 65_537] {
      var calls = 0
      #expect(throws: HistoryCheckpointError.invalidData) {
        try SessionHistory(checkpointByteCount: data.count, now: readingNow) { _ in
          calls += 1
          return result
        }
      }
      #expect(calls == 1)
    }
    for count in [0, 75, SessionHistory.maximumCheckpointBytes + 1] {
      let source = CheckpointSource(data)
      #expect(throws: HistoryCheckpointError.invalidData) {
        try source.restore(now: readingNow, byteCount: count)
      }
      #expect(source.requests.isEmpty)
    }
    let source = CheckpointSource(data)
    #expect(throws: HistoryCheckpointError.invalidData) {
      try source.restore(now: Date(timeIntervalSince1970: .nan))
    }
    #expect(source.requests.isEmpty)
  }

  @Test func historyLocalArchiveReaderUsesSamePinnedFileProtectionsAndPreservesRejectedFiles()
    throws
  {
    let root = try checkpointFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("history")
    let local = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
    let store: any HistoryCheckpointStore = local
    #expect(try store.readHistory(now: readingNow) == nil)
    let data = readingV3(now: readingNow, cores: 10, maximum: false)
    try store.write(data)
    #expect(try store.readHistory(now: readingNow)?.checkpoint() == data)
    let file = directory.appendingPathComponent(LocalHistoryCheckpointStore.fileName)
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    #expect(throws: HistoryFileError.unsafeFile) { try store.readHistory(now: readingNow) }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var corrupt = data
    corrupt[corrupt.count - 1] ^= 1
    try corrupt.write(to: file)
    #expect(throws: HistoryCheckpointError.invalidData) { try store.readHistory(now: readingNow) }
    #expect(try Data(contentsOf: file) == corrupt)
    try fm.removeItem(at: file)
    let target = root.appendingPathComponent("canary")
    try data.write(to: target)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    try fm.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: HistoryFileError.self) { try store.readHistory(now: readingNow) }
    try fm.removeItem(at: file)
    try fm.linkItem(at: target, to: file)
    #expect(throws: HistoryFileError.unsafeFile) { try store.readHistory(now: readingNow) }
    try fm.removeItem(at: file)
    #expect(mkfifo(file.path, 0o600) == 0)
    #expect(throws: HistoryFileError.unsafeFile) { try store.readHistory(now: readingNow) }
    try fm.removeItem(at: file)
    try Data(repeating: 0, count: SessionHistory.maximumCheckpointBytes + 1).write(to: file)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(throws: HistoryFileError.invalidSize) { try store.readHistory(now: readingNow) }
    #expect(try Data(contentsOf: target) == data)
  }

  private final class LegacyReadStore: HistoryCheckpointStore {
    var data: Data?
    var reads = 0
    func read() throws -> Data? {
      reads += 1
      return data
    }
    func write(_ data: Data) throws { self.data = data }
    func remove() throws { data = nil }
  }
  @Test func historyDefaultArchiveReadAdapterPreservesLegacyStoresAndDecodeFailures() throws {
    let concrete = LegacyReadStore()
    let store: any HistoryCheckpointStore = concrete
    #expect(try store.readHistory(now: readingNow) == nil && concrete.reads == 1)
    concrete.data = SessionHistory().checkpoint()
    var padded = Data(repeating: 0, count: 5)
    padded.append(try #require(concrete.data))
    let slice = padded.dropFirst(5)
    #expect(slice.startIndex == 5)
    #expect(try SessionHistory(checkpoint: slice, now: readingNow).checkpoint() == concrete.data)
    #expect(try store.readHistory(now: readingNow)?.retainedBucketCount == 0)
    concrete.data?[0] = 0
    #expect(throws: HistoryCheckpointError.invalidData) { try store.readHistory(now: readingNow) }
    #expect(concrete.reads == 3)
  }

  @Test func historyStreamReadingDrainsLargeEarlyErrorsAndStopsOnRecoverySourceFailure() throws {
    var unsupported = readingV3(now: readingNow, cores: 10, maximum: true)
    unsupported[8] = 4
    unsupported = readingCRC(unsupported)
    let valid = CheckpointSource(unsupported)
    #expect(throws: HistoryCheckpointError.unsupportedVersion) {
      try valid.restore(now: readingNow)
    }
    #expect(valid.offset == unsupported.count && valid.requests.count > 2)
    var corrupt = unsupported
    corrupt[corrupt.count - 8] ^= 1
    let invalid = CheckpointSource(corrupt)
    #expect(throws: HistoryCheckpointError.invalidData) { try invalid.restore(now: readingNow) }
    #expect(invalid.offset == corrupt.count)
    let failed = CheckpointSource(unsupported)
    failed.failureAt = 65_537
    #expect(throws: CheckpointReadFailure.stopped) { try failed.restore(now: readingNow) }
    #expect(failed.failed && failed.offset == 65_537 && failed.callsAfterFailure == 0)
  }

}
