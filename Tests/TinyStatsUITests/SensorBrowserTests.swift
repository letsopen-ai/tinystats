import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func sensorsOpenDirectlySearchLiveAndSelectTheirOwnHistoricalReading() throws {
  _ = NSApplication.shared
  var snapshot = Snapshot()
  snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
  snapshot.uptime = 10
  snapshot.sensorsSampledAt = 10
  snapshot.sensors = [
    .init(key: "Tg01", name: "GPU", kind: .temperature, value: 60),
    .init(key: "F0Ac", name: "Fan", kind: .fan, value: 0),
    .init(key: "IX", name: "Unknown current", kind: .current, value: -0.5),
  ]
  let detail = DetailController(snapshot: snapshot, history: [])
  detail.selected = .sensors
  let root = detail.view
  root.layoutSubtreeIfNeeded()
  let search = try #require(root.subviews.compactMap { $0 as? NSSearchField }.first)
  let chart = try #require(root.subviews.compactMap { $0 as? ChartView }.first)
  let table = try #require(
    root.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  #expect(!search.isHidden && !chart.isHidden && table.numberOfRows == 9)
  let readingButtons = root.subviews.compactMap { $0 as? NSButton }.filter {
    $0.title == "All readings" || $0.title == "Summary"
  }
  #expect(readingButtons.count == 1 && !readingButtons[0].isHidden)
  #expect(readingButtons[0].accessibilityLabel() == "Show all readings and SMC keys")
  #expect(search.frame.maxX < readingButtons[0].frame.minX)
  let toggle = try #require(readingButtons.first)
  #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
  #expect(detail.showsAllReadings && toggle.title == "Summary")
  #expect(toggle.accessibilityLabel() == "Show summary")
  #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
  #expect(toggle.accessibilityLabel() == "Show all readings and SMC keys")
  #expect(!detail.showsAllReadings && toggle.title == "All readings")
  #expect(chart.series.first?.name == SensorCatalog.hottestGPULabel)
  func filter(_ query: String) {
    search.stringValue = query
    detail.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: search))
  }
  filter("f0ac")
  #expect(table.numberOfRows == 2)
  #expect(
    chart.series.first?.name == SensorCatalog.hottestGPULabel && chart.series.first?.values == [60])
  #expect(detail.tableView(table, shouldSelectRow: 1))
  #expect(!detail.tableView(table, shouldSelectRow: 0))
  table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
  detail.tableViewSelectionDidChange(
    Notification(name: NSTableView.selectionDidChangeNotification, object: table))
  #expect(chart.series.first?.values == [0])
  #expect(detail.settings.sensorKey == "cpu")  // Browsing never changes the menu readout.
  snapshot.timestamp += 6
  snapshot.uptime += 6
  snapshot.sensorsSampledAt = snapshot.uptime
  snapshot.sensors[1].value = 1200
  detail.update(snapshot, history: [])
  #expect(chart.series.first?.values == [0, 1200] && table.selectedRow == 1)
  #expect(
    chart.recordedSummary.contains("Min 0.00 RPM")
      && chart.recordedSummary.contains("Max 1200.00 RPM"))
  #expect(chart.recordedSummary.contains("2 readings"))
  let accessibleChartValue = chart.accessibilityValue() as? String
  #expect(accessibleChartValue?.contains("RPM") == true)
  #expect(
    chart.hoverText(at: .init(x: chart.plotArea.maxX - 1, y: chart.bounds.midY))?.contains("1200")
      == true)
  filter("unclassified")
  #expect(table.numberOfRows == 2)
  filter("not a sensor")
  #expect(table.numberOfRows == 1)
  filter("")
  #expect(table.numberOfRows == 9)
  detail.selected = .cpu
  #expect(search.isHidden)
  detail.selected = .sensors
  #expect(!search.isHidden && table.numberOfRows == 9)
}

@Test @MainActor func sensorDisappearancePreservesHistoricalTemperatureUnitsAndMissingSample()
  throws
{
  _ = NSApplication.shared
  var snapshot = Snapshot()
  snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
  snapshot.uptime = 10
  snapshot.sensorsSampledAt = 10
  snapshot.sensors = [.init(key: "Tg01", name: "GPU", kind: .temperature, value: 60)]
  let detail = DetailController(snapshot: snapshot, history: [])
  detail.settings.fahrenheit = true
  detail.settings.sensorKey = "Tg01"
  detail.selected = .sensors
  let chart = try #require(detail.view.subviews.compactMap { $0 as? ChartView }.first)
  #expect(chart.series.first?.values == [140])
  snapshot.timestamp += 5
  snapshot.uptime += 5
  snapshot.sensorsSampledAt = snapshot.uptime
  snapshot.sensors = []
  detail.update(snapshot, history: [])
  #expect(chart.series.first?.values == [140, nil])
  #expect(chart.valueFormat.string(140) == "140.00 °F")
  #expect(
    detail.view.subviews.compactMap { $0 as? NSTextField }.contains {
      $0.stringValue.contains("currently unavailable")
    })
  snapshot.timestamp += 5
  snapshot.uptime += 5
  snapshot.sensorsSampledAt = snapshot.uptime
  snapshot.sensors = [.init(key: "Tg01", name: "GPU", kind: .temperature, value: 70)]
  detail.update(snapshot, history: [])
  #expect(chart.series.first?.values == [140, nil, 158])
}

@Test @MainActor func populatedSensorBrowserReleasesItsChartAndControllerOnWindowClose() {
  _ = NSApplication.shared
  weak var controller: DetailController?
  weak var chart: ChartView?
  autoreleasepool {
    var snapshot = Snapshot()
    snapshot.uptime = 5
    snapshot.sensorsSampledAt = 5
    snapshot.sensors = (0..<132).map {
      .init(key: "S\($0)", name: "Sensor", kind: .temperature, value: 20)
    }
    let window = MainWindow()
    var detail: DetailController? = DetailController(snapshot: snapshot, history: [])
    window.contentViewController = detail
    detail?.selected = .sensors
    controller = detail
    chart = detail?.view.subviews.compactMap { $0 as? ChartView }.first
    window.close()
    detail = nil
  }
  #expect(controller == nil && chart == nil)
}

@Test @MainActor func sensorValueColumnsKeepAGutterAtEnlargedWindowWidths() throws {
  _ = NSApplication.shared
  let window = MainWindow()
  let detail = DetailController()
  window.contentViewController = detail
  detail.selected = .sensors
  let scroll = try #require(detail.view.subviews.compactMap { $0 as? NSScrollView }.first)
  let table = try #require(scroll.documentView as? NSTableView)
  for size in [NSSize(width: 884, height: 660), NSSize(width: 1920, height: 928)] {
    window.setContentSize(size)
    detail.view.layoutSubtreeIfNeeded()
    #expect(table.tableColumns.reduce(0) { $0 + $1.width } <= scroll.contentSize.width - 30)
  }
  window.close()
}

@MainActor private final class SensorReloadProbe: NSTableView {
  var reloads = 0
  override func reloadData() {
    reloads += 1
    super.reloadData()
  }
}

@Test @MainActor func sensorRowsStayStableForCachedSamplesButRefreshForHardwareSearchAndUnits()
  throws
{
  _ = NSApplication.shared
  let table = SensorReloadProbe()
  let detail = DetailController(table: table)
  var snapshot = Snapshot()
  snapshot.uptime = 10
  snapshot.sensorsSampledAt = 10
  snapshot.sensors = [
    .init(key: "T", name: "CPU", kind: .temperature, value: 60),
    .init(key: "F", name: "Fan", kind: .fan, value: 1200),
  ]
  detail.update(snapshot, history: [])
  detail.selected = .sensors
  let root = detail.view
  let initial = table.reloads
  for _ in 0..<3 {
    snapshot.timestamp += 2
    snapshot.uptime += 2
    detail.update(snapshot, history: [])
  }
  #expect(table.reloads == initial)
  snapshot.sensorsSampledAt = snapshot.uptime
  snapshot.sensors[0].value = 70
  detail.update(snapshot, history: [])
  #expect(table.reloads == initial + 1)
  let search = try #require(root.subviews.compactMap { $0 as? NSSearchField }.first)
  search.stringValue = "CPU"
  detail.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: search))
  #expect(table.reloads == initial + 2 && table.numberOfRows == 4)
  detail.settings.fahrenheit = true
  detail.update(snapshot, history: [])
  #expect(table.reloads == initial + 3)
  let chart = try #require(root.subviews.compactMap { $0 as? ChartView }.first)
  #expect(
    chart.accessibilityValue() as? String
      == SensorCatalog.hottestCPULabel
      + ": Latest 158.00 °F, min 140.00 °F, max 158.00 °F; window 6s")
}

@Test @MainActor func sensorDiscoveryLimitKeepsPauseVisibleAtTheActualBoundary() {
  _ = NSApplication.shared
  var snapshot = Snapshot()
  snapshot.sensorsSampledAt = 1
  snapshot.uptime = 1
  snapshot.sensors = (0..<127).map {
    .init(key: "T\($0)", name: "CPU", kind: .temperature, value: 40)
  }
  let detail = DetailController(snapshot: snapshot, history: [])
  detail.selected = .sensors
  let root = detail.view
  func labels() -> [String] {
    root.subviews.compactMap { ($0 as? MenuActionRow)?.accessibilityHelp() }
  }
  #expect(!labels().contains { $0.contains("SMC scan limit: 128") })
  snapshot.sensors.append(.init(key: "T127", name: "CPU", kind: .temperature, value: 40))
  snapshot.uptime = 6
  snapshot.sensorsSampledAt = 6
  detail.update(snapshot, history: [])
  #expect(labels().contains { $0.contains("SMC scan limit: 128") })
  detail.paused = true
  #expect(
    labels().contains { $0.contains("Paused") && $0.contains("SMC scan limit: 128") })
  detail.paused = false
  #expect(
    labels().contains {
      $0.contains("SMC scan limit: 128") && !$0.contains("Paused")
    })
}
