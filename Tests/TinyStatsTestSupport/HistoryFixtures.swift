import Foundation

public enum HistoryFixtures {
  public static func data(_ name: String) throws -> Data {
    guard
      let file = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: file)
  }
}

extension HistoryFixtures {
  /// Independent synthetic wire fixture, never user data or evidence of an old writer.
  public static func populatedCheckpoint(version: UInt16, now: Date, maximum: Bool = false) -> Data
  {
    precondition(version == 1 || version == 2)
    var data = Data("TNYHIST\0".utf8)
    func integer<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func double(_ value: Double) { integer(value.bitPattern) }
    integer(version)
    integer(UInt16(12))
    integer(UInt16(6))
    integer(UInt16(0))
    integer(UInt64(0))
    let values = [80.0, 60, 20, 0, 45, 100_000, 10_000, 400, 200, 70, -4, 55]
    for span in [600, 3600, 21600, 86400, 604800, 2_419_200] {
      integer(UInt32(span))
      integer(UInt16(maximum ? 301 : 300))
      integer(UInt16(0))
      let width = Double(span) / 300
      let latest = floor(now.timeIntervalSince1970 / width) * width
      for index in 0..<(maximum ? 301 : 300) {
        let seconds =
          maximum
          ? (index == 300
            ? now.timeIntervalSince1970 : latest - Double(300 - index) * width + width - 0.25)
          : latest - Double(299 - index) * width
        let time = Date(timeIntervalSince1970: seconds)
        double(time.timeIntervalSinceReferenceDate)
        double(time.timeIntervalSinceReferenceDate)
        double(2)
        integer(UInt32(1))
        integer(UInt32(0))
        integer(UInt16(4095))
        integer(UInt16(0))
        for value in values {
          double(value)
          integer(UInt32(1))
        }
        if version == 2 {
          for value in values {
            double(value)
            double(value)
            integer(UInt32(1))
          }
        }
      }
    }
    var crc: UInt32 = .max
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
    }
    integer(crc ^ .max)
    return data
  }
}
