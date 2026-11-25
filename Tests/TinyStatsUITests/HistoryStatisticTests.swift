import AppKit
import Foundation
import Testing
import TinyStatsTestSupport

@testable import TinyStats
@testable import TinyStatsCore

private func historyActionEvidence(_ message: String) {
  FileHandle.standardError.write(Data("History native action: \(message)\n".utf8))
}

@MainActor private func statisticPickers(in view: NSView) -> [NSPopUpButton] {
  (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { statisticPickers(in: $0) }
}
@Test @MainActor func historyStatisticPickerOffersPeakAverageAndMinimum() throws {
  let controller = HistoryController(module: .cpu, settings: Settings())
  defer { controller.window?.close() }
  let root = try #require(controller.window?.contentView)
  let picker = try #require(
    statisticPickers(in: root).first { $0.itemTitles.contains("Sample average") })
  #expect(picker.itemTitles == ["Peak", "Sample average", "Minimum"])
}

@MainActor private func statisticChart(in view: NSView) -> SummaryDashboardView? {
  if let chart = view as? SummaryDashboardView { return chart }
  return view.subviews.compactMap { statisticChart(in: $0) }.first
}
@Test @MainActor func historyStatisticNativeActionsChangeValuesAndPixelAggregation() throws {
  // Test-host evidence only: locate AppKit termination relative to native window
  // creation and action dispatch on hosted runners.
  let terminationObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification, object: nil, queue: nil
  ) { _ in historyActionEvidence("NSApplication will terminate") }
  defer { NotificationCenter.default.removeObserver(terminationObserver) }
  historyActionEvidence("begin")
  var history = SessionHistory()
  for (seconds, cpu) in [(0.0, 20.0), (1.0, 80.0), (3.0, 10.0)] {
    var p = Snapshot().historyPoint
    p.time = Date(timeIntervalSince1970: 1_699_999_992 + seconds)
    p.sampleInterval = 1
    p.cpu = cpu
    history.append(p, uptime: seconds + 1)
  }
  historyActionEvidence("creating controller")
  let controller = HistoryController(module: .cpu, settings: Settings())
  defer { controller.window?.close() }
  historyActionEvidence("updating controller")
  controller.update(history.projection(.tenMinutes))
  let root = try #require(controller.window?.contentView)
  let picker = try #require(
    statisticPickers(in: root).first { $0.itemTitles.contains("Sample average") })
  let chart = try #require(statisticChart(in: root))
  historyActionEvidence("sending average action; explicit target=\(picker.target != nil)")
  picker.selectItem(at: 1)
  #expect(NSApp.sendAction(try #require(picker.action), to: picker.target, from: picker))
  #expect(
    controller.statistic == .average && chart.cards.first?.title == "RECORDED SAMPLE AVERAGES")
  guard case .plot(let average) = chart.cards.first?.content else {
    Issue.record("Missing average plot")
    return
  }
  #expect(average.first == [50, 10] && average.firstWeights == [2, 1])
  #expect(average.firstValue == "37%" && average.firstCoverage?.label == "3/3 readings")
  #expect(average.firstCoverage?.badge == nil)
  let tiny = HistoryBarLayout(plot: average, graphWidth: 1, scale: 1)
  #expect(tiny.columns.count == 1 && abs((tiny.columns.first?.first ?? 0) - 110.0 / 3) < 0.000001)
  picker.selectItem(at: 2)
  historyActionEvidence("sending minimum action; explicit target=\(picker.target != nil)")
  #expect(NSApp.sendAction(try #require(picker.action), to: picker.target, from: picker))
  guard case .plot(let minimum) = chart.cards.first?.content else {
    Issue.record("Missing minimum plot")
    return
  }
  #expect(minimum.first == [20, 10] && minimum.firstValue == "10%")
  #expect(HistoryBarLayout(plot: minimum, graphWidth: 1, scale: 1).columns.first?.first == 10)
  #expect(
    chart.cards.first?.spoken.contains("recorded minima") == true
      || chart.cards.first?.spoken.contains("RECORDED MINIMA") == true)
  historyActionEvidence("assertions complete")
}

@Test @MainActor func historyStatisticLegacyCoverageIsUnknownAndZeroStaysVisible() throws {
  let now = Date(timeIntervalSince1970: 1_700_000_002)
  var history = try SessionHistory(checkpoint: HistoryFixtures.data("history-v1.bin"), now: now)
  let controller = HistoryController(module: .cpu, settings: Settings())
  defer { controller.window?.close() }
  let root = try #require(controller.window?.contentView)
  let picker = try #require(
    statisticPickers(in: root).first { $0.itemTitles.contains("Sample average") })
  let chart = try #require(statisticChart(in: root))
  // This fixture's two observations share the 12-second hour bucket.
  let range = try #require(statisticPickers(in: root).first { $0.itemTitle(at: 0) == "10 minutes" })
  range.selectItem(at: 1)
  #expect(NSApp.sendAction(try #require(range.action), to: range.target, from: range))
  controller.update(history.projection(.hour))
  picker.selectItem(at: 1)
  #expect(NSApp.sendAction(try #require(picker.action), to: picker.target, from: picker))
  guard case .plot(let old) = chart.cards.first?.content else {
    Issue.record("Missing old plot")
    return
  }
  #expect(old.first.allSatisfy { $0 == nil } && old.firstValue == "—")
  #expect(old.firstCoverage?.label == "0/2 readings" && old.firstCoverage?.badge == "Unavailable")
  var point = Snapshot().historyPoint
  point.time = now
  point.sampleInterval = 1
  point.cpu = 0
  point.upload = 0
  point.download = nil
  history.append(point, uptime: 1)
  controller.update(history.projection(.hour))
  guard case .plot(let partial) = chart.cards.first?.content else {
    Issue.record("Missing partial plot")
    return
  }
  #expect(partial.first == [0] && partial.firstValue == "0%" && partial.partialFirst == [true])
  #expect(
    partial.firstCoverage?.label == "1/3 readings" && partial.firstCoverage?.badge == "Partial")
  #expect(chart.cards.first?.spoken.contains("1 of 3 valid observations") == true)
  controller.select(.network)
  #expect(controller.statistic == .average && picker.indexOfSelectedItem == 1)
  guard case .plot(let network) = chart.cards.first?.content else {
    Issue.record("Missing mixed-coverage network plot")
    return
  }
  // This independent legacy fixture has no upload readings: the new zero is fully known.
  #expect(network.firstValue == "0 B/s" && network.firstCoverage?.badge == nil)
  #expect(network.secondValue == "—" && network.secondCoverage?.badge == "Unavailable")
  #expect(chart.cards.first?.spoken.contains("Unavailable") == true)
  range.selectItem(at: 0)
  #expect(NSApp.sendAction(try #require(range.action), to: range.target, from: range))
  #expect(controller.statistic == .average && controller.range == .tenMinutes)
}

@Test @MainActor func historyStatisticNativeLightDarkFixtures() throws {
  let controller = HistoryController(module: .network, settings: Settings())
  defer { controller.window?.close() }
  let root = try #require(controller.window?.contentView)
  let picker = try #require(
    statisticPickers(in: root).first { $0.itemTitles.contains("Sample average") })
  var history = SessionHistory()
  let start = 1_700_000_000.0
  for index in 0..<580 {
    var point = Snapshot().historyPoint
    point.time = Date(timeIntervalSince1970: start + Double(index))
    point.sampleInterval = 1
    point.cpu = Double(index % 90)
    point.download = index % 31 == 0 ? nil : Double((index * 157) % 600_000)
    point.upload = index % 97 == 0 ? 1_500_000 : Double((index * 53) % 250_000)
    if index % 113 == 0 { point.upload = 0 }
    history.append(point, uptime: Double(index + 1))
  }
  controller.update(history.projection(.tenMinutes))
  let directory = ProcessInfo.processInfo.environment["TINYSTATS_HISTORY_CAPTURE_DIRECTORY"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
  }
  if let directory {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    controller.window?.appearance = NSAppearance(named: appearance)
    for statistic in HistoryStatistic.allCases {
      picker.selectItem(at: statistic.rawValue)
      #expect(NSApp.sendAction(try #require(picker.action), to: picker.target, from: picker))
      root.layoutSubtreeIfNeeded()
      let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
      root.cacheDisplay(in: root.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      #expect(bitmap.pixelsWide >= 560 && bitmap.pixelsHigh >= 490)
      if let directory {
        try data.write(
          to: directory.appendingPathComponent(
            "network-\(statistic.rawValue)-\(appearance.rawValue).png"))
      }
    }
  }
}

@Test @MainActor func historyStatisticMirroredPixelGroupingWeightsEachSeriesAndKeepsMissingZero()
  throws
{
  var history = SessionHistory()
  for (index, upload, download) in [
    (0, 0.0, Optional(100.0)), (1, 40.0, nil), (3, 20.0, Optional(20.0)),
  ] {
    var point = Snapshot().historyPoint
    point.time = Date(timeIntervalSince1970: 1_699_999_992 + Double(index))
    point.sampleInterval = 1
    point.upload = upload
    point.download = download
    history.append(point, uptime: Double(index + 1))
  }
  let chart = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  chart.updateHistory(
    history.projection(.tenMinutes), module: .network, fahrenheit: false, statistic: .average)
  guard case .plot(let plot) = chart.cards.first?.content else {
    Issue.record("Missing mirrored plot")
    return
  }
  #expect(plot.mirrored && plot.firstWeights == [2, 1] && plot.secondWeights == [1, 1])
  let layout = HistoryBarLayout(plot: plot, graphWidth: 1, scale: 1)
  let column = try #require(layout.columns.first)
  #expect(column.first == 20 && column.second == 60 && !column.firstMissing && column.secondMissing)
  #expect(
    plot.firstCoverage?.label == "3/3 readings" && plot.secondCoverage?.label == "2/2 readings")
  // Missing readings are not missing statistics among the valid readings.
  #expect(plot.firstCoverage?.badge == nil && plot.secondCoverage?.badge == nil)
  chart.updateHistory(
    history.projection(.tenMinutes), module: .network, fahrenheit: false, statistic: .minimum)
  guard case .plot(let minimum) = chart.cards.first?.content else {
    Issue.record("Missing mirrored minimum")
    return
  }
  let minima = try #require(HistoryBarLayout(plot: minimum, graphWidth: 1, scale: 1).columns.first)
  #expect(minima.first == 0 && minima.second == 20 && !minima.firstMissing && minima.secondMissing)
}

@Test @MainActor func historyCoverageSeparatesEmptyFromLegacyAndFitsBoundedCounts() throws {
  let chart = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  chart.updateHistory(.init(range: .hour), module: .gpu, fahrenheit: false, statistic: .average)
  guard case .plot(let empty) = chart.cards.first?.content else {
    Issue.record("Missing empty plot")
    return
  }
  #expect(empty.firstValue == "—" && empty.firstCoverage?.badge == "No readings")
  #expect(chart.accessibilityHelp()?.contains("do not claim continuous coverage") == true)
  // A projection holds at most300 buckets with UInt32 counts; keep both series exact.
  let maximum = UInt64(UInt32.max) * 300
  let coverage = SummaryDashboardView.ObservationCoverage(recorded: maximum - 1, valid: maximum)
  #expect(coverage.badge == "Partial")
  let width = (coverage.label as NSString).size(withAttributes: [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
  ]).width
  #expect(width <= (chart.bounds.width - 24) / 2)
  #expect(chart.subviews.isEmpty && chart.layer == nil)
}

@Test @MainActor func historyMixedCoverageSwitchedAndFreshRenderIdentically() throws {
  // Keep optional native QA checkpoints eligible without shifting encoded timestamps.
  let now = Date().addingTimeInterval(-60)
  let legacy = HistoryFixtures.populatedCheckpoint(version: 1, now: now)
  var history = try SessionHistory(
    checkpoint: legacy, now: now)
  for index in 0..<60 {
    var point = Snapshot().historyPoint
    point.time = now.addingTimeInterval(Double(index + 1))
    point.sampleInterval = 1
    point.cpu = index.isMultiple(of: 2) ? 20 : 80
    point.upload = 0
    point.download = nil
    let accepted = history.append(point, uptime: Double(index + 1))
    #expect(accepted)
  }
  let projection = history.projection(.hour)
  #expect(projection.validSamples(.upload, statistic: .average) == 60)
  #expect(projection.validSamples(.download, statistic: .average) == 0)
  #expect(projection.validSamples(.upload, statistic: .peak) > 60)
  #expect(projection.validSamples(.download, statistic: .peak) > 0)
  let directory = ProcessInfo.processInfo.environment["TINYSTATS_HISTORY_CAPTURE_DIRECTORY"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
  }
  if let directory {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let checkpoint = history.checkpoint()
    let restored = try SessionHistory(checkpoint: checkpoint, now: Date())
    #expect(restored.projection(.hour).validSamples(.upload, statistic: .average) == 60)
    try legacy.write(to: directory.appendingPathComponent("mixed-source-v1.bin"))
    try checkpoint.write(to: directory.appendingPathComponent("mixed-source-v2.bin"))
  }
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    let chart = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
    chart.appearance = NSAppearance(named: appearance)
    func image(_ view: SummaryDashboardView) throws -> Data {
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
      view.cacheDisplay(in: view.bounds, to: bitmap)
      return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    for statistic in HistoryStatistic.allCases {
      chart.updateHistory(projection, module: .network, fahrenheit: false, statistic: statistic)
      if statistic != .peak {
        guard case .plot(let plot) = chart.cards.first?.content else {
          Issue.record("Missing mixed coverage plot")
          return
        }
        #expect(plot.firstValue == "0 B/s" && plot.firstCoverage?.badge == "Partial")
        #expect(plot.secondCoverage?.badge == "Unavailable")
      }
      let before = try image(chart)
      chart.updateHistory(projection, module: .cpu, fahrenheit: false, statistic: .minimum)
      _ = try image(chart)
      chart.updateHistory(projection, module: .network, fahrenheit: false, statistic: statistic)
      let switched = try image(chart)
      let fresh = SummaryDashboardView(frame: chart.frame)
      fresh.appearance = chart.appearance
      fresh.updateHistory(projection, module: .network, fahrenheit: false, statistic: statistic)
      let freshImage = try image(fresh)
      #expect(switched == before && switched == freshImage)
      if let directory {
        try switched.write(
          to: directory.appendingPathComponent(
            "mixed-\(statistic.rawValue)-\(appearance.rawValue).png"))
      }
    }
  }
}
