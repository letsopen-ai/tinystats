import Foundation
import Testing

@testable import TinyStatsCore

private func sensorSample(_ time: Double, _ readings: [SensorReading]) -> Snapshot {
  var snapshot = Snapshot()
  snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_000 + time)
  snapshot.uptime = time
  snapshot.sensorsSampledAt = time
  snapshot.sensors = readings
  return snapshot
}

@Test func recentSensorHistoryUsesActualCollectionTimesAndKeepsMissingDistinctFromZero() {
  var timeline = SensorTimeline()
  let temperature = SensorReading(key: "T", name: "Temperature", kind: .temperature, value: 0)
  var first = sensorSample(5, [temperature])
  timeline.append(first)
  first.timestamp += 2
  first.uptime += 2
  timeline.append(first)  // Cached hardware observation, not a new reading.
  #expect(timeline.count == 1)
  timeline.append(sensorSample(10, []))
  var last = sensorSample(15, [temperature])
  last.sensors[0].value = -10
  timeline.append(last)
  #expect(
    timeline.times.map(\.timeIntervalSince1970) == [1_700_000_005, 1_700_000_010, 1_700_000_015])
  #expect(timeline.values(for: "T", fahrenheit: false, kind: .temperature) == [0, nil, -10])
  #expect(timeline.values(for: "T", fahrenheit: true, kind: .temperature) == [32, nil, 14])
  #expect(timeline.values(for: "missing", fahrenheit: false, kind: nil) == [nil, nil, nil])
}

@Test func sensorTimelineCapsColumnsAndSamplesAndRestartsOnIncompatibleIdentityOrTime() {
  var timeline = SensorTimeline()
  let sensors = (0..<200).map {
    SensorReading(key: "S\($0)", name: "S\($0)", kind: .fan, value: Double($0))
  }
  for time in 1...200 { timeline.append(sensorSample(Double(time), sensors)) }
  #expect(timeline.count == 120 && timeline.sensorCount == 132)
  #expect(timeline.values(for: "S0", fahrenheit: false, kind: .fan).count == 120)
  timeline.append(sensorSample(201, [.init(key: "new", name: "New", kind: .current, value: -0.5)]))
  #expect(timeline.sensorCount == 132)
  #expect(
    timeline.values(for: "new", fahrenheit: false, kind: .current).dropLast().allSatisfy {
      $0 == nil
    })
  #expect(timeline.values(for: "new", fahrenheit: false, kind: .current).last! == -0.5)
  timeline.append(sensorSample(202, [.init(key: "new", name: "New", kind: .power, value: 0)]))
  #expect(
    timeline.values(for: "new", fahrenheit: false, kind: .power).dropLast().allSatisfy { $0 == nil }
  )
  #expect(timeline.values(for: "new", fahrenheit: false, kind: .power).last! == 0)
  timeline.append(sensorSample(1, sensors))
  #expect(timeline.count == 1)
  var backwards = sensorSample(2, sensors)
  backwards.timestamp -= 10
  timeline.append(backwards)
  #expect(timeline.count == 1)
}

@Test func sensorTimelineRejectsInvalidTimingAndNonfiniteReadings() {
  var timeline = SensorTimeline()
  let bad = SensorReading(key: "T", name: "T", kind: .temperature, value: .infinity)
  var snapshot = sensorSample(5, [bad])
  snapshot.sensorsSampledAt = nil
  timeline.append(snapshot)
  snapshot.sensorsSampledAt = 6
  timeline.append(snapshot)
  #expect(timeline.count == 0)
  snapshot.sensorsSampledAt = 5
  timeline.append(snapshot)
  #expect(timeline.values(for: "T", fahrenheit: false, kind: .temperature) == [nil])
}

@Test func sensorTimelineWrapKeepsChangingValuesChronologicalAndIncludesModelPowerTail() {
  var timeline = SensorTimeline()
  var readings = (0..<128).map { SensorReading(key: "SMC\($0)", name: "SMC", kind: .fan, value: 0) }
  readings += (0..<4).map {
    SensorReading(key: "model\($0)", name: "Model power", kind: .power, value: 0)
  }
  for time in 1...243 {
    readings[131].value = Double(time)
    timeline.append(sensorSample(Double(time), readings))
  }
  #expect(
    timeline.values(for: "model3", fahrenheit: false, kind: .power)
      == (124...243).map { Double($0) })
  #expect(timeline.kind(for: "model3") == .power)
  timeline.append(sensorSample(244, []))
  #expect(timeline.kind(for: "model3") == .power)
  #expect(timeline.values(for: "model3", fahrenheit: false, kind: .power).last! == nil)
}

@Test func sensorMaximumProjectionPreservesGapsZeroAndRingOrderWithoutNewColumns() {
  var timeline = SensorTimeline()
  for time in 1...125 {
    let readings: [SensorReading] =
      time % 3 == 0
      ? []
      : [
        .init(key: "cpu1", name: "CPU", kind: .temperature, value: Double(-time)),
        .init(key: "cpu2", name: "CPU", kind: .temperature, value: 0),
        .init(key: "fan1", name: "Fan", kind: .fan, value: 5000),
      ]
    timeline.append(sensorSample(Double(time), readings))
  }
  let keys = ["cpu1", "cpu2", "fan1", "missing", "cpu1"]
  #expect(
    timeline.maximumValues(for: keys, fahrenheit: false) == (6...125).map { $0 % 3 == 0 ? nil : 0 })
  #expect(
    timeline.maximumValues(for: keys, fahrenheit: true) == (6...125).map { $0 % 3 == 0 ? nil : 32 })
  #expect(timeline.maximumValues(for: [], fahrenheit: false).allSatisfy { $0 == nil })
  #expect(timeline.sensorCount == 3 && timeline.count == 120)
}

@Test func friendlySensorNamesRequireEvidenceAndHottestLabelIsShared() {
  for key in ["Te04", "Tp01", "Tf04", "Tf14", "Tg01", "TCMz"] {
    #expect(SensorCatalog.friendlyName(for: key, appleSilicon: true) == nil)
  }
  #expect(SensorCatalog.friendlyName(for: "TC0P", appleSilicon: false) == "CPU proximity")
  #expect(SensorCatalog.friendlyName(for: "ioreport:gpu", appleSilicon: true) == "GPU model power")
  var snapshot = Snapshot()
  snapshot.sensors = [.init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 60)]
  #expect(SensorCatalog.hottestCPULabel == "CPU · hottest recognized sensor")
  #expect(snapshot.sensor(for: "cpu")?.name == SensorCatalog.hottestCPULabel)
  #expect(!SensorReading.validKey("gpu"))
}
