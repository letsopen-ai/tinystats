import Foundation
import XCTest

@testable import TinyStatsCore

final class SensorSelectionTests: XCTestCase {
  func testSettingsMigrationAndInvalidKeys() throws {
    let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"interval":5}"#.utf8))
    XCTAssertEqual(legacy.sensorKey, "cpu")
    XCTAssertFalse(legacy.monitorStorageHealth)
    var settings = Settings()
    settings.sensorKey = "invalid-key"
    settings.validate()
    XCTAssertEqual(settings.sensorKey, "cpu")
    settings.sensorKey = "F0Ac"
    settings.monitorStorageHealth = true
    let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored, settings)
  }
  func testNonPercentSensorStylesCannotInventAPercentage() {
    var settings = Settings()
    settings.styles["sensors"] = .pie
    settings.sensorKey = "F0Ac"
    XCTAssertEqual(settings.style(for: .sensors), .stacked)
    XCTAssertEqual(
      MenuBarStyle.available(for: .sensors, sensorKey: "PSTR"),
      [.text, .stacked, .value, .label, .icon, .history, .historyValue])
    settings.sensorKey = "TC0P"
    XCTAssertEqual(settings.style(for: .sensors), .pie)
  }
  func testSelectedSourceIsExplicitAndHistoryRecordsItsKey() {
    var snapshot = Snapshot()
    let fan = SensorReading(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1000)
    snapshot.sensors = [fan, .init(key: "Tp01", name: "CPU · Tp01", kind: .temperature, value: 52)]
    XCTAssertEqual(snapshot.sensor(for: "cpu")?.value, 52)
    XCTAssertEqual(snapshot.sensor(for: "F0Ac")?.value, 1000)
    XCTAssertNil(snapshot.sensor(for: "XXXX"))
    snapshot.selectedSensor = fan
    XCTAssertEqual(snapshot.historyPoint.sensorKey, "F0Ac")
    XCTAssertEqual(snapshot.historyPoint.sensorValue, 1000)
    XCTAssertEqual(fan.menuLabel, "FAN")
    XCTAssertEqual(fan.formatted(fahrenheit: false), "1000 rpm")
    XCTAssertEqual(snapshot.sensor(for: "cpu")?.formatted(fahrenheit: true, compact: true), "126°")
  }
}

extension SensorSelectionTests {
  func testBoundedDiscoveryKeepsEveryQuantityAndKnownSystemPower() {
    var candidates = (0..<250).map { index in
      SensorReading(
        key: String(format: "T%03d", index), name: "Temperature", kind: .temperature, value: 40)
    }
    candidates += [
      .init(key: "Tp01", name: "CPU · Tp01", kind: .temperature, value: 52),
      .init(key: "Tg0G", name: "GPU · Tg0G", kind: .temperature, value: 45),
      .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1000),
      .init(key: "PSTR", name: "System total power", kind: .power, value: 20),
      .init(key: "VC0C", name: "Voltage", kind: .voltage, value: 1),
      .init(key: "IC0C", name: "Current", kind: .current, value: 1),
    ]
    let selected = SensorCatalog.selectForMonitoring(candidates)
    XCTAssertEqual(selected.count, 128)
    XCTAssertTrue(selected.contains { $0.key == "PSTR" })
    XCTAssertTrue(selected.contains { $0.kind == .fan })
    XCTAssertTrue(selected.contains { $0.kind == .voltage })
    XCTAssertTrue(selected.contains { $0.kind == .current })
    XCTAssertEqual(
      selected.map(\.key), SensorCatalog.selectForMonitoring(candidates.reversed()).map(\.key))
  }
}
