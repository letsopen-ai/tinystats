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
      #expect(card.note.isEmpty || card.note.hasPrefix("Partial"))
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
    if module == .network { #expect(card.note == "Partial coverage") }
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

@Test @MainActor func sampleCompactValuesAndHelpFollowPausePrivacyAndCadenceChanges() throws {
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.selected = .overview
  var sample = Snapshot()
  for paused in [false, true, false] {
    for privacy in 0..<4 {
      detail.settings.connectivityChecks = privacy == 1
      detail.settings.publicIPChecks = privacy == 2
      detail.settings.weather.enabled = privacy == 3
      detail.settings.pingCheck.enabled = privacy == 0
      detail.settings.interval = 5
      detail.paused = paused
      detail.update(sample, history: [])
      let pause = try #require(
        detail.view.subviews.compactMap { $0 as? MenuActionRow }.first {
          $0.title == (paused ? "Resume" : "Pause")
        })
      let rows = DetailReadingsBuilder.sampleRows(
        snapshot: sample, settings: detail.settings, paused: paused)
      let privacyRow = try #require(rows.first { $0.label == "Privacy" })
      #expect(privacyRow.compactValue == (privacy == 0 ? "Network checks" : "Internet enabled"))
      #expect(rows.first { $0.label == "Monitoring" }?.compactValue == (paused ? "Paused" : nil))
      #expect(rows.first?.sampleSection == true)
      #expect(pause.toolTip?.hasPrefix(pause.title + "\n") == true)
      #expect(pause.accessibilityHelp()?.contains("Privacy: " + privacyRow.value) == true)
      #expect(pause.accessibilityHelp()?.contains("Configured cadence: 5s") == true)
      let information = try #require(
        detail.view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first {
          $0.accessibilityLabel() == "About this sample"
        })
      #expect(
        information.isAccessibilityElement() && information.accessibilityRole() == .staticText)
      #expect(information.accessibilityValue() as? String == pause.accessibilityHelp())
    }
  }
  sample.sampleMilliseconds = .nan
  detail.update(sample, history: [])
  #expect(
    detail.view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.contains {
      ($0.accessibilityValue() as? String)?.contains("Last sample cost: Unavailable") == true
    } == true
  )
}

@Test @MainActor func sensorsScanCapIsVisibleInHighlightsAndExcludesModelChannels() {
  var sample = Snapshot()
  sample.sensors = (0..<127).map {
    .init(key: "T\($0)", name: "CPU", kind: .temperature, value: 40)
  }
  sample.sensors.append(.init(key: "ioreport:gpu", name: "GPU model power", kind: .power, value: 3))
  func browser() -> SensorBrowserPresentation.Presentation {
    SensorBrowserPresentation.build(
      snapshot: sample, timeline: SensorTimeline(), settings: Settings(), query: "",
      showsAll: false, selection: nil)
  }
  #expect(!browser().rows.contains { $0.label == "Sensors may be missing" })
  sample.sensors.append(.init(key: "T127", name: "CPU", kind: .temperature, value: 40))
  let rows = browser().rows
  #expect(rows.filter { $0.label == "Sensors may be missing" }.count == 1)
  #expect(rows.first?.label == "HIGHLIGHTS")
  #expect(rows.first { $0.label == "Sensors may be missing" }?.sensorIdentity == nil)
}

@Test @MainActor func rowCardsFitEmptyMessagesAndDiscloseTruncation() {
  let view = SummaryDashboardView(frame: .zero)
  view.usesPopoverLayout = true
  for count in 0...15 {
    let rows = (0..<count).map { SummaryDashboardView.Reading(label: "Row \($0)", value: "1") }
    var card = SummaryDashboardView.Card(frame: .zero, title: "Rows", content: .rows(rows))
    card.headerHeight = 36
    card.frame.size.height = view.popoverCardHeight(card, canonical: .zero)
    #expect(card.frame.height >= 64)
    let displayed = view.displayedRows(in: card)
    #expect(card.contentRect.height >= max(14, CGFloat(displayed.count) * 25))
    #expect(displayed.count == min(12, count))
    if count > 12 { #expect(displayed.last?.label == "+\(count - 11) more") }
  }
}

@MainActor private final class SampleReloadProbe: NSTableView {
  var fullReloads = 0
  var partialRows = IndexSet()
  override func reloadData() {
    fullReloads += 1
    super.reloadData()
  }
  override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
    partialRows = rowIndexes
    super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
  }
}

@Test @MainActor func cachedSampleSectionReloadsOnlyChangedRowsAndRestoresSelectionWhenItGrows()
  throws
{
  let table = SampleReloadProbe()
  let detail = DetailController(table: table)
  detail.selected = .sensors
  detail.showsAllReadings = true
  var sample = Snapshot()
  sample.uptime = 10
  sample.sensorsSampledAt = 10
  sample.sensors = [.init(key: "PSTR", name: "System total power", kind: .power, value: 0)]
  detail.update(sample, history: [])
  detail.loadViewIfNeeded()
  let full = table.fullReloads
  let selected = table.selectedRow
  sample.sampleMilliseconds = 12
  detail.update(sample, history: [])
  #expect(table.fullReloads == full && table.partialRows.count == 1)
  #expect(table.selectedRow == selected)
  let index = try #require(table.partialRows.first)
  let label = detail.tableView(table, viewFor: table.tableColumns[0], row: index) as? NSTextField
  #expect(label?.stringValue == "Last sample cost")
  // Exercise the structural fallback with cached delivery; it must restore selection too.
  sample.sensors += (0..<127).map {
    .init(key: "T\($0)", name: "CPU", kind: .temperature, value: 40)
  }
  detail.update(sample, history: [])
  #expect(table.fullReloads == full + 1 && table.selectedRow == selected)
}

@Test @MainActor func sensorRangeTooltipUsesWrittenRangeRatherThanVoiceOverPronunciation() throws {
  let detail = DetailController()
  detail.selected = .sensors
  var sample = Snapshot()
  sample.sensors = [
    .init(key: "Te04", name: "CPU · Te04", kind: .temperature, value: 40),
    .init(key: "Te05", name: "CPU · Te05", kind: .temperature, value: 50),
  ]
  detail.update(sample, history: [])
  let table = try #require(
    detail.view.subviews.compactMap { $0 as? NSScrollView }.compactMap {
      $0.documentView as? NSTableView
    }.first)
  let cell = try #require(
    (0..<table.numberOfRows).compactMap {
      detail.tableView(table, viewFor: table.tableColumns[0], row: $0) as? NSTextField
    }.first { $0.stringValue == "2 more sensors" })
  #expect(cell.toolTip?.contains("40.0–50.0") == true)
  #expect(cell.accessibilityLabel()?.contains("40.0 to 50.0") == true)
}

@Test @MainActor func samplePrivacyReflectsEligibleUpdateChecksInRowsAndLiveActionHelp() throws {
  _ = NSApplication.shared
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.showsAllReadings = true
  detail.selected = .cpu
  _ = detail.view
  let pause = try #require(
    detail.view.subviews.compactMap { $0 as? MenuActionRow }
      .first { $0.title == "Pause" })
  var state = UpdatePresentation(eligible: true, canInstall: true)
  for (eligible, checking, expected) in [
    (true, true, "Internet requests enabled"),
    (true, false, "Local only"), (false, true, "Local only"),
    (true, true, "Internet requests enabled"),
  ] {
    state.eligible = eligible
    state.preferences.automaticallyCheck = checking
    detail.updateState = state
    let rows = DetailReadingsBuilder.sampleRows(
      snapshot: Snapshot(), settings: Settings(),
      paused: false, updateChecksOn: state.updateChecksOn)
    #expect(rows.first { $0.label == "Privacy" }?.value == expected)
    #expect(pause.toolTip?.contains("Privacy: " + expected) == true)
    #expect(pause.accessibilityHelp()?.contains("Privacy: " + expected) == true)
    let table = try #require(
      detail.view.subviews.compactMap { $0 as? NSScrollView }
        .compactMap { $0.documentView as? NSTableView }.first)
    let privacyIndex = try #require(
      (0..<table.numberOfRows).first { index in
        (detail.tableView(table, viewFor: table.tableColumns[0], row: index) as? NSTextField)?
          .stringValue == "Privacy"
      })
    let value = try #require(
      detail.tableView(table, viewFor: table.tableColumns[1], row: privacyIndex) as? NSTextField)
    #expect(
      value.stringValue == (expected == "Internet requests enabled" ? "Internet enabled" : expected)
    )
  }
  // An updater remains a disclosed internet capability while monitoring is paused.
  detail.paused = true
  #expect(
    (detail.view as? MainContentView)?.sampleInformation.contains(
      "Privacy: Internet requests enabled") == true)
}
