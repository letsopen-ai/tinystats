import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func sampleInformationPreservesPrivacyFrozenCostAndSensorLimit() {
  var settings = Settings()
  var snapshot = Snapshot()
  snapshot.sampleMilliseconds = 1.25
  func value(_ label: String, paused: Bool = false) -> String? {
    DetailReadingsBuilder.sampleRows(snapshot: snapshot, settings: settings, paused: paused)
      .first { $0.label == label }?.value
  }
  #expect(value("Privacy") == "Local only")
  #expect(value("Configured cadence") == "2s")
  #expect(value("Last sample cost") == "1.2 ms")
  #expect(value("Monitoring", paused: true) == "Paused · readings are frozen")
  settings.pingCheck.enabled = true
  #expect(value("Privacy") == "Network checks enabled")
  for source in 0..<3 {
    settings.weather.enabled = source == 0
    settings.publicIPChecks = source == 1
    settings.connectivityChecks = source == 2
    #expect(value("Privacy", paused: true) == "Internet requests enabled")
  }
  for invalid in [Double.nan, .infinity, -1] {
    snapshot.sampleMilliseconds = invalid
    #expect(value("Last sample cost") == "Unavailable")
  }
  snapshot.sampleMilliseconds = 0
  #expect(value("Last sample cost") == "0.0 ms")
  snapshot.sensors = (0..<128).map {
    .init(key: "T\($0)", name: "Temperature", kind: .temperature, value: 40)
  }
  #expect(value("SMC scan limit") == "128 · some sensors may be missing")
}

@Test @MainActor func everyDropdownHasOnlyIconsBelowContentAndReachableSampleHelp() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.view.setFrameSize(SystemStyle.popoverSize)
  controller.showsAllReadings = true
  for module in Module.allCases {
    controller.selected = module
    controller.view.layoutSubtreeIfNeeded()
    let pause = try #require(
      controller.view.subviews.compactMap { $0 as? MenuActionRow }
        .first { $0.title == "Pause" })
    #expect(pause.accessibilityLabel() == "Pause")
    #expect(pause.accessibilityHelp()?.contains("Privacy: Local only") == true)
    #expect(pause.toolTip?.contains("Last sample cost:") == true)
    #expect(
      !controller.view.subviews.contains {
        $0 is NSTextField && !$0.isHidden && $0.frame.minY < 48
      })
    if module != .overview {
      let table = try #require(
        controller.view.subviews.compactMap { $0 as? NSScrollView }
          .compactMap { $0.documentView as? NSTableView }.first)
      let labelColumn = table.tableColumns[0]
      let headings = (0..<table.numberOfRows).compactMap {
        (controller.tableView(table, viewFor: labelColumn, row: $0) as? NSTextField)?.stringValue
      }
      #expect(headings.contains("About this sample"))
      #expect(headings.contains("Privacy") && headings.contains("Last sample cost"))
    }
  }
}

@Test @MainActor func dropdownCardExplanationsMoveToHoverAndAccessibilityWithoutFooterSpace() throws
{
  var snapshot = Snapshot()
  snapshot.cpu = .init(usage: 20, cores: [20], load: [])
  snapshot.processes = [.init(pid: 42, name: "Helper", cpu: 20, memory: 100, read: 20, written: 10)]
  snapshot.memoryApps = [
    .init(name: "App", bundlePath: "/App.app", processCount: 2, cpu: 20, memory: 100)
  ]
  var settings = Settings()
  settings.processGrouping = .bundles
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 324, height: 600))
  view.usesPopoverLayout = true
  for module in [Module.cpu, .memory, .gpu, .disks, .network, .battery] {
    view.update(snapshot, history: [], settings: settings, module: module)
    for card in view.cards where !card.help.isEmpty {
      #expect(card.note.isEmpty || card.note.hasPrefix("Partial · "))
      #expect(card.spoken.contains(card.help))
      #expect(
        view.hoverText(at: .init(x: card.frame.minX + 2, y: card.frame.minY + 2))?
          .contains(card.help) == true)
    }
    if module == .memory {
      let card = try #require(view.cards.first { $0.groupsProcesses })
      #expect(card.help.contains("shared pages may be counted twice"))
    }
  }
}

@Test @MainActor func cachedSensorDeliveryUpdatesSampleCostWithoutLosingSensorSelection() throws {
  let detail = DetailController()
  detail.selected = .sensors
  detail.showsAllReadings = true
  var snapshot = Snapshot()
  snapshot.uptime = 10
  snapshot.sensorsSampledAt = 10
  snapshot.sensors = [.init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 40)]
  snapshot.sampleMilliseconds = 1
  detail.update(snapshot, history: [])
  let table = try #require(
    detail.view.subviews.compactMap { $0 as? NSScrollView }
      .compactMap { $0.documentView as? NSTableView }.first)
  let labelColumn = table.tableColumns[0]
  let index = try #require(
    (0..<table.numberOfRows).first {
      (detail.tableView(table, viewFor: labelColumn, row: $0) as? NSTextField)?.stringValue
        == "Last sample cost"
    })
  let selected = table.selectedRow
  snapshot.sampleMilliseconds = 7
  detail.update(snapshot, history: [])
  let cost = detail.tableView(table, viewFor: table.tableColumns[1], row: index) as? NSTextField
  #expect(cost?.stringValue == "7.0 ms")
  #expect(table.selectedRow == selected)
}

@Test @MainActor func emptyWeatherDropdownKeepsOneCompactStatusAndAccessibleAttribution() {
  let weather = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 324, height: 126))
  weather.update(Snapshot(), settings: Settings(), paused: false, sourceStatus: "Waiting")
  #expect(weather.popoverDocumentHeight == 126)
  let spoken = weather.accessibilityValue() as? String
  #expect(spoken?.contains("Weather is off") == true)
  #expect(spoken?.contains("MET Norway, CC BY 4.0") == true)
}

@Test @MainActor func compactDropdownRowsRetainEveryBoundedAppGroupAndPartialTrafficState() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 324, height: 600))
  view.usesPopoverLayout = true
  var snapshot = Snapshot()
  snapshot.cpuApps = (0..<8).map {
    .init(
      name: "App \($0)", bundlePath: "/App\($0).app", processCount: 1, cpu: Double($0), memory: 100)
  }
  snapshot.memoryApps = snapshot.cpuApps
  snapshot.networkTraffic.grouping = .bundles
  snapshot.networkTraffic.availability = .ready
  snapshot.networkTraffic.bundles = (0..<8).map {
    .init(
      name: "App \($0)", processCount: 1, pid: nil, download: 100, upload: 50,
      bundlePath: "/App\($0).app")
  }
  var settings = Settings()
  settings.processGrouping = .bundles
  for module in [Module.cpu, .memory, .network] {
    view.update(snapshot, history: [], settings: settings, module: module)
    let card = try #require(view.cards.first { $0.groupsProcesses })
    #expect(view.displayedRows(in: card).count == 8)
    #expect(card.contentRect.height >= 8 * 25)
    if module == .network { #expect(card.note == "Partial · TCP/UDP") }
  }
  snapshot.networkTraffic = .init()
  view.update(snapshot, history: [], settings: settings, module: .network)
  let waiting = try #require(view.cards.first { $0.groupsProcesses })
  #expect(waiting.note == "Partial · Collecting process traffic…")
}

@Test @MainActor func physicalSensorRowsAppearOnceAcrossSummarySearchAndAllReadings() {
  var snapshot = Snapshot()
  snapshot.sensors = [
    .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 0),
    .init(key: "PSTR", name: "System total power", kind: .power, value: 6),
    .init(key: "ioreport:gpu", name: "GPU model power", kind: .power, value: 2),
  ]
  for all in [false, true] {
    for query in ["", "fan", "power"] {
      let presentation = SensorBrowserPresentation.build(
        snapshot: snapshot, timeline: SensorTimeline(), settings: Settings(), query: query,
        showsAll: all, selection: .reading("PSTR"))
      for reading in snapshot.sensors {
        let matches = presentation.rows.filter { $0.sensorIdentity == .reading(reading.key) }
        #expect(matches.count <= 1)
        if query.isEmpty { #expect(matches.count == 1) }
      }
      #expect(presentation.selection == .reading("PSTR"))
    }
  }
}
