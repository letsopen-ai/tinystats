import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func browser(
  _ readings: [SensorReading], sensorKey: String = "missing", query: String = "",
  all: Bool = false, selection: SensorBrowserIdentity? = nil
) -> SensorBrowserPresentation.Presentation {
  var snapshot = Snapshot()
  snapshot.sensors = readings
  var settings = Settings()
  settings.sensorKey = sensorKey
  return SensorBrowserPresentation.build(
    snapshot: snapshot, timeline: SensorTimeline(), settings: settings, query: query,
    showsAll: all, selection: selection)
}

private let browserCPU = SensorReading(
  key: "Te04", name: "CPU · Te04", kind: .temperature, value: 45)
private let browserHotCPU = SensorReading(
  key: "Te0I", name: "CPU · Te0I", kind: .temperature, value: 65)
private let browserGPU = SensorReading(
  key: "Tg01", name: "GPU · Tg01", kind: .temperature, value: 55)
private let browserFan = SensorReading(key: "F0Ac", name: "Fan 1", kind: .fan, value: 0)

@Test @MainActor func browserFocusHonorsMenuSensorThenCPUThenGPUAndLifetimeSelection() {
  let readings = [browserGPU, browserCPU, browserFan, browserHotCPU]
  #expect(browser(readings, sensorKey: "F0Ac").selection == .reading("F0Ac"))
  #expect(browser(readings, sensorKey: "cpu").selection == .hottest(.cpu))
  let cpu = browser(readings)
  #expect(cpu.selection == .hottest(.cpu) && cpu.value == "65.0°C")
  #expect(
    cpu.subtitle
      == "Hottest CPU sensor")
  #expect(browser([browserFan, browserGPU]).selection == .hottest(.gpu))
  #expect(browser([browserFan]).selection == .reading("F0Ac"))
  let kept = browser(readings, query: "nothing", selection: .reading("gone"))
  #expect(kept.selection == .reading("gone") && kept.value == "Sensor unavailable")
  #expect(kept.subtitle == "gone · currently unavailable")
  #expect(kept.rows.map(\.label) == ["No matching sensors"])
  #expect(browser([], selection: .hottest(.cpu)).subtitle.contains("currently unavailable"))
}

@Test @MainActor func browserFallbackUsesHighlightsThenVisibleDisplayOrderNeverSnapshotOrder() {
  let ambient = SensorReading(key: "TA0P", name: "Ambient", kind: .temperature, value: 20)
  let memory = SensorReading(key: "Tm0P", name: "Memory proximity", kind: .temperature, value: 30)
  let total = SensorReading(key: "PSTR", name: "System total power", kind: .power, value: 0)
  #expect(browser([ambient, memory, total]).selection == .reading("PSTR"))
  #expect(browser([ambient, memory]).selection == .reading("Tm0P"))
  let voltage = SensorReading(key: "ZZZZ", name: "ZZZZ", kind: .voltage, value: 12)
  let current = SensorReading(key: "AAAA", name: "AAAA", kind: .current, value: -1)
  #expect(browser([voltage, current], all: true).selection == .reading("AAAA"))
  #expect(browser([]).selection == nil)
  #expect(browser([]).rows.map(\.label) == ["No readable sensors"])
}

@Test @MainActor func browserSummaryCollapsesUnnamedKeysWhileAllReadingsAndSearchRevealThem() throws
{
  let intel = SensorReading(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 40)
  let readings = [browserGPU, browserHotCPU, intel, browserCPU]
  let summary = browser(readings)
  #expect(summary.title == "SENSORS" && summary.count == "4/4")
  #expect(
    summary.rows.contains { $0.label == "CPU proximity" && $0.sensorIdentity == .reading("TC0P") })
  #expect(!summary.rows.contains { $0.sensorIdentity == .reading("Te04") })
  let collapsed = try #require(
    summary.rows.first { $0.help == "2 more CPU sensors · 45.0–65.0 °C" })
  #expect(collapsed.sensorIdentity == nil && collapsed.value == "All readings")
  #expect(collapsed.accessibilityLabel?.contains("45.0 to 65.0 degrees Celsius") == true)
  let all = browser(readings, all: true)
  #expect(
    all.rows.filter { if case .reading = $0.sensorIdentity { true } else { false } }.count == 4)
  #expect(all.rows.contains { $0.label == "CPU proximity · TC0P" })
  #expect(all.subtitle.contains("· now Te0I"))
  for mode in [false, true] {
    let search = browser(readings, query: "te04", all: mode)
    #expect(search.title == "SENSORS" && search.count == "1/4")
    #expect(search.rows.map(\.label) == ["CPU", "CPU · Te04"])
    #expect(!search.rows.contains { $0.value == "All readings" })
    for query in ["proximity", "CPU", "°C", "temperature"] {
      #expect(
        browser(readings, query: query, all: mode).rows.contains {
          $0.sensorIdentity == .reading("TC0P")
        })
    }
    for query in ["hottest", "max", "cpu temp"] {
      #expect(
        browser(readings, query: query, all: mode).rows.contains {
          $0.sensorIdentity == .hottest(.cpu)
        })
    }
  }
}

@Test @MainActor func browserUnavailableAndValidZeroSignedAndMixedKindSummaries() {
  let unknown = SensorReading(key: "TX00", name: "TX00", kind: .temperature, value: 25)
  let unavailable = browser([unknown])
  #expect(unavailable.value == "Sensor unavailable")
  #expect(
    unavailable.rows.contains {
      $0.value == "Unavailable" && $0.help == "No recognized CPU sensors · see All readings"
        && $0.sensorIdentity == nil
    })
  #expect(!unavailable.rows.contains { $0.sensorIdentity == .hottest(.gpu) })
  #expect(browser([]).rows.count == 1)
  let readings = [
    SensorReading(key: "IX00", name: "IX00", kind: .current, value: -0.5),
    SensorReading(key: "PX00", name: "PX00", kind: .power, value: 0),
  ]
  let summary = browser(readings)
  #expect(summary.rows.contains { $0.help == "2 more readings · power 1 · current 1" })
  let all = browser(readings + [browserFan], all: true)
  #expect(all.rows.contains { $0.value == "-0.50 A" })
  #expect(all.rows.contains { $0.value == "0.00 W" })
  #expect(all.rows.contains { $0.value == "0 rpm" })
}

@Test @MainActor func browserDerivedChartUsesCurrentRecognizedColumnsAndPreservesGaps() {
  var snapshot = Snapshot()
  snapshot.sensors = [browserCPU, browserHotCPU, browserGPU]
  var timeline = SensorTimeline()
  func append(_ time: Double, _ readings: [SensorReading]) {
    snapshot.uptime = time
    snapshot.sensorsSampledAt = time
    snapshot.timestamp = .init(timeIntervalSince1970: 1_700_000_000 + time)
    snapshot.sensors = readings
    timeline.append(snapshot)
  }
  append(5, [browserCPU, browserHotCPU, browserGPU])
  append(10, [])
  append(15, [browserCPU, browserHotCPU, browserGPU])
  let cpu = SensorBrowserPresentation.build(
    snapshot: snapshot, timeline: timeline, settings: Settings(), query: "", showsAll: false,
    selection: .hottest(.cpu))
  #expect(cpu.series.first?.values == [65, nil, 65])
  #expect(cpu.series.first?.name == SensorCatalog.hottestCPULabel)
  #expect(timeline.sensorCount == 3)
  var settings = Settings()
  settings.fahrenheit = true
  let gpu = SensorBrowserPresentation.build(
    snapshot: snapshot, timeline: timeline, settings: settings, query: "", showsAll: false,
    selection: .hottest(.gpu))
  #expect(gpu.series.first?.values == [131, nil, 131])
  snapshot.sensors = [browserCPU]
  let currentOnly = SensorBrowserPresentation.build(
    snapshot: snapshot, timeline: timeline, settings: Settings(), query: "", showsAll: false,
    selection: .hottest(.cpu))
  #expect(currentOnly.series.first?.values == [45, nil, 45])
}
