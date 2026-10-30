import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func leftoverViews(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + leftoverViews($0) }
}

@Test @MainActor func partialCPUUsesLowerBoundCueInSummaryAndReadingsOnlyWhenMeasured() throws {
  var snapshot = Snapshot()
  snapshot.cpu = .init(usage: 20, cores: [20, 20], load: [])
  var app = ProcessAppReading(
    name: "Example", bundlePath: "/Example.app", processCount: 3,
    cpu: 80, memory: 100, cpuIncomplete: 1)
  #expect(app.cpuDisplayValue == "≥80%")
  snapshot.cpuApps = [app]
  var settings = Settings()
  settings.processGrouping = .bundles
  let readings = try #require(
    DetailReadingsBuilder.build(
      module: .cpu, snapshot: snapshot,
      history: [], settings: settings, paused: false))
  let row = try #require(readings.rows.first { $0.bundlePath == app.bundlePath })
  #expect(row.value == app.cpuDisplayValue + " of one core")
  #expect(row.help?.contains("1 unmeasured") == true)
  let summary = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 324, height: 600))
  summary.usesPopoverLayout = true
  summary.update(snapshot, history: [], settings: settings, module: .cpu)
  let card = try #require(summary.cards.first { $0.groupsProcesses })
  #expect(summary.displayedRows(in: card).first?.value == app.cpuDisplayValue)
  #expect(card.spoken.contains("unmeasured processes"))
  app.cpu = nil
  #expect(!app.cpuDisplayValue.contains("≥") && app.cpuDisplayValue == "—")
  app.cpu = .nan
  #expect(app.cpuDisplayValue == "—")
  app.cpu = -1
  #expect(app.cpuDisplayValue == "—")
  app.cpu = 0
  #expect(app.cpuDisplayValue.hasPrefix("≥"))
  app.cpuIncomplete = 0
  #expect(!app.cpuDisplayValue.contains("≥"))
}

@Test @MainActor func fourDigitCountsFitAndIconsHaveNoSquareBorderInEitherAppearance() throws {
  let cell = ProcessAppLabelCell(frame: .init(x: 0, y: 0, width: 180, height: 25))
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    cell.appearance = NSAppearance(named: appearance)
    cell.update(
      .init(name: "Example", icon: ProcessAppDisplayCache.placeholder), count: 8192,
      path: nil, provenance: "PID 7")
    cell.layoutSubtreeIfNeeded()
    let count = try #require(
      cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "8192" })
    let textWidth = (count.stringValue as NSString).size(withAttributes: [
      .font: try #require(count.font)
    ]).width
    #expect(count.frame.width >= textWidth + 4)
    #expect(cell.bounds.contains(count.frame))
    let name = try #require(
      cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Example" })
    #expect(name.frame.maxX <= count.frame.minX)
    let icon = try #require(cell.subviews.compactMap { $0 as? NSImageView }.first)
    #expect(icon.layer?.borderWidth ?? 0 == 0)
    #expect(cell.accessibilityLabel()?.contains("8192 processes") == true)
  }
  let image = ProcessAppDisplayCache.placeholder
  #expect(image === ProcessAppDisplayCache.placeholder)
}

@Test @MainActor func compactOverflowOnlyNamesAllReadingsOnModulesWithThatAction() throws {
  let summary = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 324, height: 600))
  summary.usesPopoverLayout = true
  let rows = (0..<15).map { SummaryDashboardView.Reading(label: "Sensor \($0)", value: "1") }
  let card = SummaryDashboardView.Card(
    frame: summary.bounds, title: "Readings", content: .rows(rows))
  for module in [Module.overview, .cpu, .memory, .network, .gpu, .disks, .battery] {
    summary.update(Snapshot(), history: [], settings: Settings(), module: module)
    let overflow = try #require(summary.displayedRows(in: card).last)
    #expect(overflow.label == "+4 more")
    #expect(overflow.value == (module == .overview ? "" : "All readings"))
  }
}

@Test @MainActor func sensorsCountIsReadableAndSelectedHottestValueAppearsOnlyInHeadline() throws {
  var snapshot = Snapshot()
  snapshot.sensors = [
    .init(key: "Tp01", name: "CPU die", kind: .temperature, value: 52),
    .init(key: "F0Ac", name: "Fan", kind: .fan, value: 1000),
  ]
  snapshot.sensorsSampledAt = 10
  let presentation = SensorBrowserPresentation.build(
    snapshot: snapshot, timeline: SensorTimeline(),
    settings: Settings(), query: "", showsAll: false, selection: .hottest(.cpu))
  #expect(presentation.count == "2 sensors")
  #expect(presentation.rows.contains { $0.sensorIdentity == .hottest(.cpu) && $0.value.isEmpty })
  #expect(!presentation.rows.contains { $0.value == presentation.value })
  let detail = DetailController(snapshot: snapshot, history: [])
  detail.isPopoverPresentation = true
  detail.selected = .sensors
  detail.view.setFrameSize(SystemStyle.popoverSize)
  detail.view.layoutSubtreeIfNeeded()
  let count = try #require(
    leftoverViews(detail.view).compactMap { $0 as? NSTextField }.first {
      $0.stringValue == "2 sensors"
    })
  #expect(count.accessibilityLabel() == "2 readable sensors")
  #expect(count.frame.width >= count.intrinsicContentSize.width)
  let chart = try #require(leftoverViews(detail.view).compactMap { $0 as? ChartView }.first)
  #expect(!chart.showsSummaryDecorations && chart.caption == "")
  #expect(chart.accessibilityValue() as? String != nil)
  let search = try #require(leftoverViews(detail.view).compactMap { $0 as? NSSearchField }.first)
  search.stringValue = "fan"
  detail.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: search))
  #expect(count.stringValue == "1 of 2 sensors")
  #expect(count.accessibilityLabel() == "1 of 2 readable sensors match the search")
}

@Test @MainActor func emptyChartsHaveNoGridAndValidZeroStillPlots() {
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 300, height: 150))
  #expect(!chart.hasPlottableData)
  chart.times = [Date()]
  chart.series = [.init(name: "CPU", color: .controlAccentColor, values: [nil])]
  #expect(!chart.hasPlottableData)
  chart.series = [.init(name: "CPU", color: .controlAccentColor, values: [0])]
  #expect(chart.hasPlottableData)
}

@MainActor private final class AppearanceReloadTable: NSTableView {
  var refreshes = 0
  var reloaded = IndexSet()
  override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
    refreshes += 1
    reloaded.formUnion(rowIndexes)
    super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
  }
}

@Test @MainActor func equalReadingsStillRefreshAppearanceDependentCellsWithoutReloadingHeader()
  throws
{
  let table = AppearanceReloadTable()
  let detail = DetailController(table: table)
  detail.selected = .cpu
  detail.showsAllReadings = true
  detail.loadViewIfNeeded()
  table.reloaded = []
  let before = table.refreshes
  NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
  #expect(table.refreshes > before && !table.reloaded.isEmpty)
  for index in table.reloaded {
    let cell = detail.tableView(table, viewFor: table.tableColumns.last, row: index)
    #expect(!(cell?.subviews.contains { $0 is ProcessGroupingControl } ?? false))
  }
}

@Test @MainActor func sampleInformationIsAnUnignoredStaticTextChildWithLiveScreenGeometry() throws {
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.view.setFrameSize(SystemStyle.popoverSize)
  let window = NSWindow(
    contentRect: .init(x: 80, y: 80, width: 344, height: 640),
    styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = detail.view
  defer {
    window.contentView = nil
    window.close()
  }
  let information = try #require(
    detail.view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first {
      $0.accessibilityLabel() == "About this sample"
    })
  #expect(information.isAccessibilityElement() && information.accessibilityRole() == .staticText)
  #expect(information.accessibilityHelp() == nil)
  #expect(detail.view.accessibilityLabel() == "Overview details")
  #expect(
    NSAccessibility.unignoredChildren(from: [information]).contains {
      ($0 as? NSAccessibilityElement) === information
    })
  #expect(
    information.accessibilityFrame().width == 344 && information.accessibilityFrame().height == 34)
  let first = information.accessibilityFrame()
  window.setFrameOrigin(.init(x: 180, y: 180))
  _ = detail.view.accessibilityChildren()
  #expect(information.accessibilityFrame().origin != first.origin)
  detail.settings.interval = 5
  detail.settings.publicIPChecks = true
  detail.paused = true
  #expect((information.accessibilityValue() as? String)?.contains("Configured cadence: 5s") == true)
  #expect((information.accessibilityValue() as? String)?.contains("Monitoring: Paused") == true)
}
