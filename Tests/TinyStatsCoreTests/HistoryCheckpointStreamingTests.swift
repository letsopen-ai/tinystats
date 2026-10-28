import Foundation
import Testing
import TinyStatsTestSupport

@testable import TinyStatsCore

private enum CheckpointSinkFailure: Error, Equatable { case stopped }

@Test func historyCheckpointStreamingPreservesIndependentV2BytesAndStopsOnSinkFailure() throws {
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  for maximum in [false, true] {
    let expected = HistoryFixtures.populatedCheckpoint(version: 2, now: now, maximum: maximum)
    let history = try SessionHistory(checkpoint: expected, now: now)
    var streamed = Data()
    var chunks = 0
    history.writeCheckpoint { bytes in
      #expect(!bytes.isEmpty && bytes.count <= 64 * 1024)
      streamed.append(contentsOf: bytes)
      chunks += 1
    }
    #expect(streamed == expected && history.checkpoint() == expected)
    for failedChunk in Set([1, min(2, chunks), chunks]) {
      var calls = 0
      #expect(throws: CheckpointSinkFailure.stopped) {
        try history.writeCheckpoint { _ in
          calls += 1
          if calls == failedChunk { throw CheckpointSinkFailure.stopped }
        }
      }
      #expect(calls == failedChunk)
    }
  }
  var empty = Data()
  SessionHistory().writeCheckpoint { empty.append(contentsOf: $0) }
  #expect(empty == SessionHistory().checkpoint() && empty.count == 76)
  #expect(try SessionHistory(checkpoint: empty, now: now).retainedBucketCount == 0)
}

@Test func historyStoreStreamFailureAndSizeLimitsPreservePreviousFileAndCleanTemporary() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  let store = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  let previous = SessionHistory().checkpoint()
  try store.write(previous)
  let chunk = Data(repeating: 0, count: 4096)
  func preserved() throws {
    #expect(try store.read() == previous)
    #expect(
      !FileManager.default.fileExists(
        atPath:
          directory.appendingPathComponent(LocalHistoryCheckpointStore.temporaryName).path))
  }
  for writes in [0, 1, 3] {
    #expect(throws: CheckpointSinkFailure.stopped) {
      try store.writeCheckpoint { sink in
        for _ in 0..<writes { try chunk.withUnsafeBytes(sink) }
        throw CheckpointSinkFailure.stopped
      }
    }
    try preserved()
  }
  for count in [0, 1, 75, SessionHistory.maximumCheckpointBytes + 1] {
    #expect(throws: HistoryFileError.invalidSize) {
      try store.writeCheckpoint { sink in
        var remaining = count
        while remaining > 0 {
          let size = min(remaining, chunk.count)
          try chunk.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[..<size])) }
          remaining -= size
        }
      }
    }
    try preserved()
  }
}

@Test func historyStoreArchiveRoundTripKeepsExistingFileProtections() throws {
  let root = try checkpointFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("history")
  let local = try #require(try LocalHistoryCheckpointStore(directory: directory, create: true))
  let store: any HistoryCheckpointStore = local
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  let expected = HistoryFixtures.populatedCheckpoint(version: 2, now: now, maximum: true)
  let history = try SessionHistory(checkpoint: expected, now: now)
  try store.write(history)
  #expect(try store.read() == expected)
  let path = directory.appendingPathComponent(LocalHistoryCheckpointStore.fileName)
  try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
  #expect(throws: HistoryFileError.unsafeFile) { try store.write(SessionHistory()) }
  #expect(try Data(contentsOf: path) == expected)
  #expect(
    !FileManager.default.fileExists(
      atPath:
        directory.appendingPathComponent(LocalHistoryCheckpointStore.temporaryName).path))
}

private final class DataOnlyHistoryStore: HistoryCheckpointStore {
  var data: Data?
  var failure: CheckpointSinkFailure?
  func read() throws -> Data? { data }
  func remove() throws { data = nil }
  func write(_ data: Data) throws {
    if let failure { throw failure }
    self.data = data
  }
}

@Test func historyStoreDefaultArchiveAdapterPreservesBytesAndPropagatesWriteFailure() throws {
  let concrete = DataOnlyHistoryStore()
  let store: any HistoryCheckpointStore = concrete
  let history = SessionHistory()
  try store.write(history)
  #expect(try store.read() == history.checkpoint())
  concrete.failure = .stopped
  #expect(throws: CheckpointSinkFailure.stopped) { try store.write(history) }
  #expect(try store.read() == history.checkpoint())
}

/// Independent mixed-size v3 wire records: zero-core, one core, and quarantined layout.
/// The five empty tiers place the payload end exactly at the requested CRC boundary.
private func checkpointTrailerBoundaryFixture(payloadBytes: Int, now: Date) -> Data {
  let legacy = HistoryFixtures.populatedCheckpoint(version: 2, now: now)
  var data = Data(legacy.prefix(24))
  data[8] = 3
  func integer<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
  let quarantineCores = payloadBytes - (72 + 155 * 422) - 17 - 2
  precondition((1...256).contains(quarantineCores))
  for (tier, span) in [600, 3600, 21600, 86400, 604800, 2_419_200].enumerated() {
    integer(UInt32(span))
    integer(UInt16(tier == 0 ? 155 : 0))
    integer(UInt16(0))
    if tier != 0 { continue }
    for index in 0..<155 {
      let offset = 32 + index * 420
      data.append(legacy[offset..<(offset + 420)])
      if index == 0 {
        integer(UInt16(1))
        integer(UInt8(2))
        for _ in 0..<3 { integer(Float(37.5).bitPattern) }
        integer(UInt32(1))
      } else if index == 154 {
        integer(UInt16.max)
        integer(UInt16(quarantineCores))
        for _ in 0..<quarantineCores { integer(UInt8(1)) }
      } else {
        integer(UInt16(0))
      }
    }
  }
  precondition(data.count == payloadBytes)
  var crc: UInt32 = .max
  for byte in data {
    crc ^= UInt32(byte)
    for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
  }
  integer(crc ^ .max)
  return data
}

@Test func historyCheckpointExactChunkAndTrailerBoundariesKeepCRCAndThrowOnFinalChunk() throws {
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  for payloadBytes in Array(65_532...65_536) + [65_757] {
    let expected = checkpointTrailerBoundaryFixture(payloadBytes: payloadBytes, now: now)
    let history = try SessionHistory(checkpoint: expected, now: now)
    #expect(history.retainedBucketCount == 155)
    var streamed = Data()
    var lengths: [Int] = []
    history.writeCheckpoint { bytes in
      lengths.append(bytes.count)
      streamed.append(contentsOf: bytes)
    }
    #expect(streamed == expected && history.checkpoint() == expected)
    let expectedLengths =
      payloadBytes == 65_757
      ? [65_037, 724] : (payloadBytes == 65_532 ? [65_536] : [payloadBytes, 4])
    #expect(lengths == expectedLengths && lengths.allSatisfy { $0 <= 65_536 })
    if lengths.last == 4 {
      var calls = 0
      #expect(throws: CheckpointSinkFailure.stopped) {
        try history.writeCheckpoint { bytes in
          calls += 1
          if calls == 2 {
            #expect(bytes.count == 4)
            throw CheckpointSinkFailure.stopped
          }
        }
      }
      #expect(calls == 2)
    }
  }
}
