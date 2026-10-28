import Foundation
import Testing

@testable import TinyStatsCore

@Test func frequencyTablesValidateUnitsAndShape() {
  func table(_ words: [UInt32]) -> Data {
    Data(
      words.flatMap { word in
        (0..<8).map { $0 < 4 ? UInt8(truncatingIfNeeded: word >> (8 * $0)) : 0 }
      })
  }
  #expect(SiliconDecoder.frequencies(table([600_000_000, 3_200_000_000])) == [600, 3200])
  #expect(SiliconDecoder.frequencies(table([900_000, 4_464_000])) == [900, 4464])
  #expect(
    SiliconDecoder.frequencies(table([0, 338_000_000, 618_000_000]), gpu: true) == [0, 338, 618])
  #expect(SiliconDecoder.frequencies(Data([1])) == nil)
  #expect(SiliconDecoder.frequencies(table([0, 900_000])) == nil)
  #expect(SiliconDecoder.frequencies(table([900_000, 3_200_000_000])) == nil)
  #expect(SiliconDecoder.frequencies(table([338_000_000, 0]), gpu: true) == nil)
  #expect(SiliconDecoder.frequencies(table(Array(repeating: 900_000, count: 65))) == nil)
}

@Test func activeFrequencyExcludesIdleAndUsesStateIdentifiers() {
  let before = [
    ResidencyState(name: "IDLE", ticks: 100), .init(name: "V0P1", ticks: 20),
    .init(name: "V1P0", ticks: 30),
  ]
  let after = [
    ResidencyState(name: "V1P0", ticks: 60), .init(name: "IDLE", ticks: 10_000),
    .init(name: "V0P1", ticks: 30),
  ]
  #expect(
    SiliconDecoder.frequency(current: after, previous: before, table: [1000, 3000], gpu: false)
      == 2500)
  #expect(
    SiliconDecoder.frequency(current: before, previous: before, table: [1000, 3000], gpu: false)
      == nil)
  #expect(
    SiliconDecoder.frequency(current: before, previous: after, table: [1000, 3000], gpu: false)
      == nil)
  #expect(
    SiliconDecoder.frequency(current: after, previous: before, table: [1000], gpu: false) == nil)
  var renamed = after
  renamed[0].name = "V1P2"
  #expect(
    SiliconDecoder.frequency(current: renamed, previous: before, table: [1000, 3000], gpu: false)
      == nil)
  var duplicate = after
  duplicate[0].name = "V0P1"
  #expect(
    SiliconDecoder.frequency(current: duplicate, previous: before, table: [1000, 3000], gpu: false)
      == nil)
}

@Test func gpuFrequencyHandlesOffEntryAndNonmonotonicTables() {
  let before = [
    ResidencyState(name: "OFF", ticks: 5), .init(name: "P1", ticks: 0), .init(name: "P2", ticks: 0),
  ]
  let after = [
    ResidencyState(name: "OFF", ticks: 500), .init(name: "P1", ticks: 1),
    .init(name: "P2", ticks: 3),
  ]
  #expect(
    SiliconDecoder.frequency(current: after, previous: before, table: [0, 600, 500], gpu: true)
      == 525)
  #expect(
    SiliconDecoder.frequency(current: after, previous: before, table: [600, 500], gpu: true) == 525)
}

@Test func energyUnitsAreExplicit() {
  #expect(SiliconDecoder.joulesPerUnit("mJ") == 1e-3)
  #expect(SiliconDecoder.joulesPerUnit("uJ") == 1e-6)
  #expect(SiliconDecoder.joulesPerUnit("nJ") == 1e-9)
  #expect(SiliconDecoder.joulesPerUnit("J") == 1)
  #expect(SiliconDecoder.joulesPerUnit("ticks") == nil)
}

@Test func energyModelCounterHandlesDormantChannelsAndResets() {
  var dormant = EnergyModelCounter()
  #expect(dormant.sample(500, unit: "mJ", at: 0) == nil)
  #expect(dormant.sample(500, unit: "mJ", at: 5) == nil)
  #expect(dormant.sample(5500, unit: "mJ", at: 10) == 1)
  #expect(dormant.sample(5500, unit: "mJ", at: 15) == 0)
  var counter = EnergyModelCounter()
  #expect(counter.sample(0, unit: "nJ", at: 0) == nil)
  #expect(counter.sample(0, unit: "nJ", at: 5) == nil)
  #expect(counter.sample(10_000_000_000, unit: "nJ", at: 10) == 2)
  #expect(counter.sample(10_000_000_000, unit: "nJ", at: 15) == 0)
  #expect(counter.sample(1, unit: "nJ", at: 20) == nil)
  #expect(counter.sample(10, unit: "mJ", at: 25) == nil)
  #expect(counter.sample(5010, unit: "mJ", at: 30) == 1)
  #expect(counter.sample(-1, unit: "mJ", at: 35) == nil)
  #expect(counter.sample(5010, unit: "mJ", at: 40) == nil)
  #expect(counter.sample(6000, unit: "unknown", at: 45) == nil)
  #expect(counter.sample(6000, unit: "mJ", at: 50) == nil)
  #expect(counter.sample(60_000_000, unit: "mJ", at: 55) == nil)
  #expect(counter.sample(60_005_000, unit: "mJ", at: 60) == 1)
}

@Test func modelPowerSensorsPersistAndValidateTypedRules() throws {
  var settings = Settings()
  for key in ["ioreport:cpu", "ioreport:gpu", "ioreport:ane", "ioreport:dram"] {
    settings.sensorKey = key
    settings.validate()
    #expect(settings.sensorKey == key)
    let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.sensorKey == key)
    var rule = AlertRule(metric: .sensor)
    rule.source = key
    rule.sensorKind = .power
    rule.threshold = 20
    #expect(rule.validationError == nil)
    rule.sensorKind = .temperature
    #expect(rule.validationError != nil)
  }
  #expect(!SensorReading.validKey("ioreport:unknown"))
  #expect(!SensorReading.validKey("ioreport:gpu\n"))
  #expect(SensorReading.validKey("TC0P", kind: .temperature))
  #expect(!SensorReading.validKey("cpu", kind: .power))
}
