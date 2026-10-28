import AppKit
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
  (view as? T).map { [$0] } ?? view.subviews.flatMap { controls(type, in: $0) }
}

@Test @MainActor func sessionHistoryUIChangesRangeWithoutInventingDataAndReleasesOnClose() throws {
  _ = NSApplication.shared
  weak var released: HistoryController?
  weak var releasedGraph: SummaryDashboardView?
  var ranges: [HistoryRange?] = []
  var closed = false
  autoreleasepool {
    var controller: HistoryController? = HistoryController(module: .network, settings: Settings())
    released = controller
    controller?.onRange = { ranges.append($0) }
    controller?.onClose = { closed = true }
    let root = controller!.window!.contentView!
    let pickers = controls(NSPopUpButton.self, in: root)
    let picker = pickers.first { $0.itemTitle(at: 0) == "10 minutes" }!
    picker.selectItem(at: HistoryRange.allCases.firstIndex(of: .fourWeeks)!)
    NSApp.sendAction(picker.action!, to: picker.target, from: picker)
    #expect(controller?.range == .fourWeeks && ranges.count == 1 && ranges[0] == .fourWeeks)
    let export = controls(NSButton.self, in: root).first { $0.title == "Export CSV…" }!
    #expect(!export.isEnabled)
    var archive = SessionHistory()
    var sample = Snapshot().historyPoint
    sample.time = Date(timeIntervalSince1970: 1_700_000_000)
    sample.sampleInterval = 1
    sample.download = 42
    sample.upload = 7
    archive.append(sample, uptime: 1)
    controller?.update(archive.projection(.tenMinutes))
    #expect(!export.isEnabled)
    controller?.update(archive.projection(.fourWeeks))
    #expect(export.isEnabled)
    let chart = controls(SummaryDashboardView.self, in: root).first!
    releasedGraph = chart
    #expect(chart.cards.count == 1 && chart.cards[0].spoken.contains("peak buckets"))
    controller?.window?.close()
    controller = nil
  }
  #expect(
    released == nil && releasedGraph == nil && closed && ranges.count == 2 && ranges[1] == nil)
}

@Test @MainActor func sessionHistoryPartialBucketsKeepVisibleMissingMarkers() throws {
  var archive = SessionHistory()
  var sample = Snapshot().historyPoint
  sample.time = Date(timeIntervalSince1970: 1_700_000_000)
  sample.sampleInterval = 1
  sample.download = 42
  sample.upload = 7
  archive.append(sample, uptime: 1)
  sample.time += 1
  sample.download = nil
  archive.append(sample, uptime: 2)
  let chart = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  chart.updateHistory(archive.projection(.hour), module: .network, fahrenheit: false)
  guard case .plot(let plot) = chart.cards.first?.content else {
    Issue.record("Missing plot")
    return
  }
  let layout = HistoryBarLayout(plot: plot, graphWidth: 490, scale: 2)
  #expect(plot.bucketSeconds == 12 && layout.columns.count == 1)
  #expect(layout.columns[0].first == 7 && layout.columns[0].second == 42)
  #expect(!layout.columns[0].firstMissing && layout.columns[0].secondMissing)
}

@Test @MainActor func slowSessionHistoryDoesNotInventSamplingGaps() throws {
  var archive = SessionHistory()
  for index in 0..<10 {
    var point = Snapshot().historyPoint
    point.time = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 5.4)
    point.sampleInterval = 5
    point.cpu = 50
    archive.append(point, uptime: Double(index) * 5.4 + 1)
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  view.updateHistory(archive.projection(.tenMinutes), module: .cpu, fahrenheit: false)
  guard case .plot(let plot) = view.cards.first?.content else {
    Issue.record("Missing plot")
    return
  }
  #expect(plot.timeline.gaps.isEmpty && plot.first.allSatisfy { $0 == 50 })
  #expect(plot.firstLabel == "CPU peak" && plot.historySpan == "48s")
}

@Test @MainActor func sessionHistoryExportErrorsSurviveNewDeliveriesAndModuleSelection() throws {
  let controller = HistoryController(module: .network, settings: Settings())
  let projection = HistoryProjection(range: .tenMinutes)
  // A directory cannot be atomically replaced with a CSV. No permissions are changed.
  controller.saveExport(projection, to: FileManager.default.temporaryDirectory)
  let message = controller.exportMessage
  #expect(message?.hasPrefix("Could not save CSV:") == true)
  controller.update(projection)
  controller.select(.cpu)
  #expect(controller.module == .cpu && controller.exportMessage == message)
  let labels = controls(NSTextField.self, in: controller.window!.contentView!)
  #expect(labels.contains { label in message.map { label.stringValue.contains($0) } ?? false })
  #expect(
    labels.contains {
      $0.stringValue.contains("Span 0s") && $0.stringValue.contains("0 gap buckets")
    })
  controller.window?.close()
}

@Test @MainActor func sessionHistoryUsesFullRangeWithHonestObservedSpanAndEmptyArea() throws {
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.time = Date(timeIntervalSince1970: 1_700_000_000)
  point.sampleInterval = 1
  point.cpu = 40
  archive.append(point, uptime: 1)
  point.time += 1
  archive.append(point, uptime: 2)
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  view.updateHistory(archive.projection(.tenMinutes), module: .cpu, fahrenheit: false)
  guard case .plot(let plot) = view.cards.first?.content else {
    Issue.record("Missing plot")
    return
  }
  #expect(plot.timeline.duration == 600 && plot.historySpan == "1s")
  #expect((plot.uncollectedFraction ?? 0) > 0.99 && plot.axisLabels != nil)
  #expect(plot.timeline.positions.compactMap { $0 }.allSatisfy { $0 > 0.99 })
  #expect(view.cards.first?.spoken.contains("no recorded data") == true)
}

@Test @MainActor func fixedHistoryDomainKeepsShortSessionBucketsSeparate() throws {
  var archive = SessionHistory()
  for index in 0..<6 {
    var point = Snapshot().historyPoint
    point.time = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 2)
    point.sampleInterval = 2
    point.cpu = Double(index * 10)
    archive.append(point, uptime: Double(index * 2 + 1))
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  view.updateHistory(archive.projection(.tenMinutes), module: .cpu, fahrenheit: false)
  guard case .plot(let plot) = view.cards.first?.content else {
    Issue.record("Missing plot")
    return
  }
  let layout = HistoryBarLayout(plot: plot, graphWidth: 490, scale: 2)
  #expect(layout.columns.count == 6 && !layout.grouped)
  #expect(layout.columns.map(\.first) == [0, 10, 20, 30, 40, 50])
}

@Test func historyPresentationReportsTransitionsWithoutGrowingLongWarmupOutput() {
  var report = PresentationTransitions()
  let first = report.changed(to: "shown")
  #expect(first)
  for _ in 0..<100_000 {
    let changed = report.changed(to: "shown")
    #expect(!changed)
  }
  let closed = report.changed(to: "closed")
  let reopened = report.changed(to: "shown")
  let other = report.changed(to: "other-window")
  let closedAgain = report.changed(to: "closed")
  #expect(closed && reopened && other && closedAgain)
}

@Test @MainActor func closedHistoryReleasesContentEvenWhileNativeWindowIsRetained() throws {
  _ = NSApplication.shared
  var retainedWindow: NSWindow?
  weak var releasedController: HistoryController?
  weak var releasedGraph: SummaryDashboardView?
  autoreleasepool {
    var controller: HistoryController? = HistoryController(module: .network, settings: Settings())
    retainedWindow = controller?.window
    releasedController = controller
    releasedGraph = controls(SummaryDashboardView.self, in: retainedWindow!.contentView!).first
    retainedWindow?.close()
    controller = nil
  }
  #expect(retainedWindow != nil && releasedController == nil)
  #expect(retainedWindow?.contentView == nil && releasedGraph == nil)
  retainedWindow = nil
}
