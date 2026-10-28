import XCTest

@testable import TinyStatsCore

final class GraphDomainTests: XCTestCase {
  func testSignedDomainsRetainNegativeValuesAndZero() {
    let mixed = GraphDomain(values: [-2, 0, 2, nil, .nan, .infinity])
    XCTAssertEqual(mixed.lower, -2)
    XCTAssertEqual(mixed.upper, 2)
    XCTAssertEqual(mixed.fraction(-2), 0)
    XCTAssertEqual(mixed.fraction(0), 0.5)
    XCTAssertEqual(mixed.fraction(2), 1)
    XCTAssertNil(mixed.fraction(.nan))
    let negative = GraphDomain(values: [-3, -1])
    XCTAssertEqual(negative.upper, 0)
    XCTAssertNotEqual(negative.fraction(-1), negative.fraction(0))
    let fractional = GraphDomain(values: [0.1, 0.2])
    XCTAssertEqual(fractional.upper, 0.2)
    XCTAssertEqual(fractional.fraction(0.1), 0.5)
  }
  func testFixedPercentageScaleAndEmptyDomains() {
    let fixed = GraphDomain(values: [-2, 200], fixedUpper: 100)
    XCTAssertEqual(fixed.lower, 0)
    XCTAssertEqual(fixed.upper, 100)
    XCTAssertEqual(fixed.fraction(-2), 0)
    XCTAssertEqual(fixed.fraction(200), 1)
    for values: [Double?] in [[], [nil, .nan], [0, 0]] {
      let domain = GraphDomain(values: values)
      XCTAssertEqual(domain.lower, 0)
      XCTAssertEqual(domain.upper, 1)
      XCTAssertEqual(domain.fraction(0), 0)
    }
  }
  func testMissingTemperatureKeepsFahrenheitHistoryAndUnit() {
    var snapshot = Snapshot()
    snapshot.selectedSensor = .init(key: "TC0P", name: "CPU", kind: .temperature, value: 50)
    let original = snapshot.historyPoint
    snapshot.selectedSensor = nil
    let retained = SensorHistory(
      points: [original, snapshot.historyPoint], key: "TC0P", fahrenheit: true, current: nil)
    XCTAssertEqual(retained.values, [122, nil])
    XCTAssertEqual(retained.unit, "°F")
    XCTAssertEqual(retained.upperBound, 250)
    let other = SensorHistory(points: [original], key: "F0Ac", fahrenheit: true, current: nil)
    XCTAssertEqual(other.values, [nil])
  }
  func testSensorDomainsFitActualSignedAndConstantReadingsWithoutChangingPercentageDefaults() {
    let warm = GraphDomain(values: [40, 41, nil, .nan], fitToData: true)
    XCTAssertEqual(warm.lower, 39.795, accuracy: 0.000001)
    XCTAssertEqual(warm.upper, 41.205, accuracy: 0.000001)
    XCTAssertGreaterThan(warm.fraction(41)! - warm.fraction(40)!, 0.7)
    let constant = GraphDomain(values: [2400, 2400], fitToData: true)
    XCTAssertEqual(constant.lower, 2388)
    XCTAssertEqual(constant.upper, 2412)
    XCTAssertEqual(constant.fraction(2400), 0.5)
    let signed = GraphDomain(values: [-0.5, -0.4], fitToData: true)
    XCTAssertLessThan(signed.lower, -0.5)
    XCTAssertLessThan(signed.upper, 0)
    let empty = GraphDomain(values: [nil, .nan, .infinity], fitToData: true)
    XCTAssertEqual(empty.lower, 0)
    XCTAssertEqual(empty.upper, 1)
    let percentage = GraphDomain(values: [40, 41], fixedUpper: 100, fitToData: true)
    XCTAssertEqual(percentage.lower, 0)
    XCTAssertEqual(percentage.upper, 100)
  }

}
