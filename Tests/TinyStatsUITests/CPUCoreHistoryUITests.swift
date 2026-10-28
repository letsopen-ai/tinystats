import AppKit
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func coreViews<T: NSView>(_ type: T.Type, _ root: NSView) -> [T] {
  (root as? T).map { [$0] } ?? root.subviews.flatMap { coreViews(type, $0) }
}

@Test @MainActor func cpuCoreHistoryScrollsEveryLogicalCounterAndReleasesItsGraph() throws {
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.sampleInterval = 1
  point.cpuCores = CPUCoreHistorySample(
    .init(usage: 50, cores: Array(repeating: 50, count: 256), load: []))
  archive.append(point, uptime: 1)
  weak var graphAfterClose: SummaryDashboardView?
  autoreleasepool {
    let controller = HistoryController(module: .cpu, settings: Settings())
    controller.update(archive.projection(.tenMinutes))
    let root = controller.window!.contentView!
    let graph = coreViews(SummaryDashboardView.self, root)[0]
    let scroll = coreViews(NSScrollView.self, root)[0]
    graphAfterClose = graph
    #expect(controller.window!.styleMask.contains(.resizable))
    #expect(graph.cards.count == 2 && graph.cards[0].frame.height == 190)
    #expect(graph.cards[1].spoken.contains("256 logical cores"))
    #expect(graph.frame.height > scroll.contentSize.height)
    #expect(graph.cards[1].frame.maxY <= graph.frame.height)
    graph.scroll(.init(x: 0, y: graph.frame.maxY - scroll.contentSize.height))
    #expect(graph.visibleRect.maxY >= graph.cards[1].frame.maxY - 1)
    controller.select(.memory)
    #expect(graph.cards.count == 1 && graph.frame.height == scroll.contentSize.height)
    controller.window?.close()
  }
  #expect(graphAfterClose == nil)
}

@Test @MainActor func cpuCoreHistoryKeepsColorsWithoutVisualCoreIDsAndDisclosesChangedLayout() {
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.sampleInterval = 1
  point.time = Date(timeIntervalSince1970: 1_699_999_992)
  point.cpuCores = CPUCoreHistorySample(
    .init(usage: 50, cores: [20, 80], load: [], coreKinds: [.efficiency, .performance]))
  archive.append(point, uptime: 1)
  point.time += 3
  point.cpuCores = CPUCoreHistorySample(
    .init(usage: 50, cores: [80, 20], load: [], coreKinds: [.performance, .efficiency]))
  archive.append(point, uptime: 4)
  let graph = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 445))
  graph.updateHistory(
    archive.projection(.tenMinutes), module: .cpu, fahrenheit: false, statistic: .average)
  #expect(graph.cards.count == 2 && graph.cards[1].note.contains("layout changed"))
  let group = graph.accessibilityChildren()?[1] as? NSAccessibilityElement
  let rows = group?.accessibilityChildren() as? [NSAccessibilityElement]
  #expect(rows?.contains { $0.accessibilityLabel() == "Logical core 1, Performance" } == true)
  #expect(
    rows?.allSatisfy {
      ($0.accessibilityValue() as? String)?.contains("1 of 2 observations; partial coverage")
        == true
    } == true)
  #expect(!graph.cards[1].title.contains("E1") && !graph.cards[1].title.contains("P1"))
}

@Test @MainActor func cpuCoreHistoryAccessibilityDistinguishesZeroMissingAndPartialCoverage() throws
{
  var archive = SessionHistory()
  for offset in 0..<3 {
    var point = Snapshot().historyPoint
    point.time = Date(timeIntervalSince1970: 1_699_999_992 + Double(offset * 3))
    point.sampleInterval = 1
    if offset < 2 {
      point.cpuCores = CPUCoreHistorySample(
        .init(
          usage: nil, cores: [offset == 0 ? 80 : nil, nil, 0], load: [],
          coreKinds: [.performance, .unknown, .efficiency]))
    }
    archive.append(point, uptime: Double(offset * 3 + 1))
  }
  let graph = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 445))
  for statistic in HistoryStatistic.allCases {
    graph.updateHistory(
      archive.projection(.tenMinutes), module: .cpu, fahrenheit: false, statistic: statistic)
    let group = try #require(graph.accessibilityChildren()?[1] as? NSAccessibilityElement)
    let rows = try #require(group.accessibilityChildren() as? [NSAccessibilityElement])
    #expect(
      rows.map { $0.accessibilityLabel() } == [
        "Logical core 3, Efficiency", "Logical core 1, Performance", "Logical core 2, Logical",
      ])
    #expect(
      rows[0].accessibilityValue() as? String
        == "\(statistic.title): 0%, 2 of 3 observations; partial coverage")
    #expect(
      rows[1].accessibilityValue() as? String
        == "\(statistic.title): 80%, 1 of 3 observations; partial coverage")
    #expect(
      rows[2].accessibilityValue() as? String
        == "\(statistic.title): Unavailable, 0 of 3 observations")
    #expect(
      group.accessibilityHelp()?.contains("not continuous time coverage") == true)
    #expect(group.accessibilityHelp()?.contains("Gray means missing, orange outlines") == true)
    #expect(group.accessibilityHelp()?.contains("incompatible layouts") == true)
    #expect(
      group.accessibilityHelp()?.contains("not elapsed time") == (statistic == .average))
    #expect(group.accessibilityValue() == nil)
  }
}

@Test @MainActor func cpuCoreHistoryAccessibilityRowsFollowGeometryReuseAndRelease() throws {
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.sampleInterval = 1
  point.cpuCores = CPUCoreHistorySample(
    .init(usage: 50, cores: Array(repeating: 50, count: 256), load: []))
  archive.append(point, uptime: 1)
  var retainedRow: NSAccessibilityElement?
  weak var releasedGraph: SummaryDashboardView?
  try autoreleasepool {
    let controller = HistoryController(module: .cpu, settings: Settings())
    defer { controller.window?.close() }
    controller.update(archive.projection(.tenMinutes))
    let root = try #require(controller.window?.contentView)
    let graph = try #require(coreViews(SummaryDashboardView.self, root).first)
    releasedGraph = graph
    let group = try #require(graph.accessibilityChildren()?[1] as? NSAccessibilityElement)
    let rows = try #require(group.accessibilityChildren() as? [NSAccessibilityElement])
    let last = try #require(rows.last)
    retainedRow = last
    let before = last.accessibilityFrame()
    controller.window?.setContentSize(.init(width: 900, height: 680))
    controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
    #expect(last.accessibilityFrame().width > before.width)
    let previous = last.accessibilityFrame()
    controller.window?.setFrameOrigin(.init(x: 120, y: 180))
    #expect(last.accessibilityFrame().origin != previous.origin)
    let local = graph.convert(
      controller.window!.convertFromScreen(last.accessibilityFrame()), from: nil)
    let area = graph.cards[1].contentRect
    let heatmap = SummaryDashboardView.coreHistoryGraphRect(
      area: area, count: 256, scale: controller.window!.backingScaleFactor)
    #expect(
      local == SummaryDashboardView.coreHistoryRowRect(area: area, graph: heatmap, position: 255))
    #expect(!graph.visibleRect.intersects(local))
    // Dispatch the actual AX action selectors; static text need not accept AXFocused.
    // The modern NSAccessibility protocol has no scroll-to-visible equivalent.
    let actions =
      last.perform(NSSelectorFromString("accessibilityActionNames"))?
      .takeUnretainedValue() as? [String]
    #expect(actions?.contains("AXScrollToVisible") == true)
    last.perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXScrollToVisible")
    #expect(graph.visibleRect.contains(local))
    let firstLocal = graph.convert(
      controller.window!.convertFromScreen(rows[0].accessibilityFrame()), from: nil)
    rows[0].perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXScrollToVisible")
    #expect(graph.visibleRect.contains(firstLocal))
    controller.update(archive.projection(.tenMinutes))
    let refreshed = try #require((group.accessibilityChildren() as? [NSAccessibilityElement])?.last)
    #expect(last === refreshed)
    // Shrinking a layout detaches externally retained obsolete rows.
    var smaller = SessionHistory()
    point.cpuCores = CPUCoreHistorySample(.init(usage: 0, cores: [0], load: []))
    smaller.append(point, uptime: 1)
    controller.update(smaller.projection(.tenMinutes))
    #expect(last.accessibilityParent() == nil && last.accessibilityFrame() == .zero)
    let visibleAfterShrink = graph.visibleRect
    last.perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXScrollToVisible")
    #expect(graph.visibleRect == visibleAfterShrink)
    #expect(group.accessibilityChildren()?.count == 1)
    let first = try #require(group.accessibilityChildren()?.first as? NSAccessibilityElement)
    controller.select(.memory)
    #expect(group.accessibilityParent() == nil && group.accessibilityChildren() == nil)
    #expect(first.accessibilityParent() == nil)
    controller.select(.cpu)
    controller.update(.init(range: .tenMinutes))
    #expect(graph.accessibilityChildren()?.count == 1)
  }
  #expect(releasedGraph == nil && retainedRow?.accessibilityParent() == nil)
}

/// Traverse the exported AX tree, rather than looking for a substring in Card.spoken.
@Test @MainActor func cpuCoreHistoryAccessibilityReachesEveryCoreAndStatistic() throws {
  for count in [10, 40, CPUCoreHistorySample.maximumCores] {
    var archive = SessionHistory()
    for (offset, value) in [(0.0, 20.0), (1.0, 80.0)] {
      var point = Snapshot().historyPoint
      point.time = Date(timeIntervalSince1970: 1_699_999_992 + offset)
      point.sampleInterval = 1
      point.cpuCores = CPUCoreHistorySample(
        .init(usage: 50, cores: Array(repeating: value, count: count), load: []))
      archive.append(point, uptime: offset + 1)
    }
    let controller = HistoryController(module: .cpu, settings: Settings())
    defer { controller.window?.close() }
    controller.update(archive.projection(.tenMinutes))
    let root = try #require(controller.window?.contentView)
    let graph = try #require(coreViews(SummaryDashboardView.self, root).first)
    let picker = try #require(
      coreViews(NSPopUpButton.self, root).first { $0.itemTitles.contains("Sample average") })
    for (statistic, expected) in [
      (HistoryStatistic.peak, "80%"), (.average, "50%"), (.minimum, "20%"),
    ] {
      picker.selectItem(at: statistic.rawValue)
      #expect(NSApp.sendAction(try #require(picker.action), to: picker.target, from: picker))
      let group = try #require(graph.accessibilityChildren()?[1] as? NSAccessibilityElement)
      #expect(group.accessibilityRole() == .group)
      let rows = try #require(group.accessibilityChildren() as? [NSAccessibilityElement])
      #expect(rows.count == count)
      #expect(group.accessibilityValue() == nil)
      #expect(group.accessibilityHelp()?.contains("\(count) logical cores") == true)
      for index in 0..<count {
        let row = try #require(
          rows.first { $0.accessibilityLabel() == "Logical core \(index + 1), Logical" })
        #expect(row.isAccessibilityElement() && row.accessibilityRole() == .staticText)
        #expect(row.accessibilityParent() as? NSAccessibilityElement === group)
        let value = try #require(row.accessibilityValue() as? String)
        #expect(value.contains(statistic.title) && value.contains(expected))
        #expect(value.contains("2 of 2 observations") && !value.contains("partial"))
        #expect(value.count < 200)
      }
    }
  }
}

@Test @MainActor func cpuCoreHistoryAccessibilityFramesMatchSnappedRows() throws {
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.sampleInterval = 1
  point.cpuCores = CPUCoreHistorySample(.init(usage: 50, cores: [20, 80], load: []))
  archive.append(point, uptime: 1)
  let graph = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520.75, height: 445))
  graph.updateHistory(archive.projection(.tenMinutes), module: .cpu, fahrenheit: false)
  let group = try #require(graph.accessibilityChildren()?[1] as? NSAccessibilityElement)
  let rows = try #require(group.accessibilityChildren() as? [NSAccessibilityElement])
  for width: CGFloat in [520.75, 901.25] {
    graph.setFrameSize(.init(width: width, height: 445))
    let area = graph.cards[1].contentRect
    for scale: CGFloat in [1, 2] {
      let heatmap = SummaryDashboardView.coreHistoryGraphRect(area: area, count: 2, scale: scale)
      #expect(heatmap.maxX * scale == floor(heatmap.maxX * scale))
      for (position, row) in rows.enumerated() {
        let drawn = SummaryDashboardView.coreHistoryRowRect(
          area: area, graph: heatmap, position: position)
        #expect(drawn.minY == heatmap.minY + CGFloat(position) * heatmap.height / 2)
        #expect(drawn.maxX == heatmap.maxX + 50)
        if scale == 1 { #expect(row.accessibilityFrame() == drawn) }
      }
    }
  }
}

@Test @MainActor func cpuCoreHistoryUsesFixedSlotsAndCombinesCollidingStatsMissingAndGaps() throws {
  var history = SessionHistory()
  for (seconds, value) in [(0.0, 10.0), (1, 30), (13, 90), (26, .nan)] {
    var point = Snapshot().historyPoint
    point.sampleInterval = 1
    point.time = Date(timeIntervalSince1970: 1_699_999_992 + seconds)
    point.cpuCores = CPUCoreHistorySample(
      .init(usage: nil, cores: [value], load: [], coreKinds: [.unknown]))
    history.append(point, uptime: seconds + 1)
  }
  let projection = history.projection(.hour)
  let layout = coreHistoryBars(
    CoreHistoryMatrix(projection, kinds: [.unknown], statistic: .peak), core: 0, width: 400,
    scale: 2)
  let positions = layout.timeline.positions.compactMap { $0 }
  #expect(positions.count == 3 && abs(positions[1] - positions[0] - 12.0 / 3600) < 0.000001)
  let peak = coreHistoryBars(
    CoreHistoryMatrix(projection, kinds: [.unknown], statistic: .peak), core: 0, width: 1, scale: 1)
  let minimum = coreHistoryBars(
    CoreHistoryMatrix(projection, kinds: [.unknown], statistic: .minimum), core: 0, width: 1,
    scale: 1)
  let mean = coreHistoryBars(
    CoreHistoryMatrix(projection, kinds: [.unknown], statistic: .average), core: 0, width: 1,
    scale: 1)
  #expect(peak.columns.count == 1 && peak.columns[0].first == 90)
  #expect(minimum.columns[0].first == 10 && peak.columns[0].firstMissing && peak.columns[0].gap)
  #expect(abs(try #require(mean.columns[0].first) - 130.0 / 3) < 0.0001)
  #expect(mean.columns[0].firstWeight == 3)
}

@Test @MainActor func directCoreHistoryInputsMatchPlotColumnsAcrossStatsPixelsAndMissingLayouts() {
  var archive = SessionHistory()
  let start = Date(timeIntervalSince1970: 1_699_999_992)
  for index in 0..<140 {
    var point = Snapshot().historyPoint
    point.time = start + Double(index * 3 + (index > 60 ? 19 : 0))
    point.sampleInterval = 1
    point.cpuCores =
      index % 17 == 0
      ? nil
      : CPUCoreHistorySample(
        .init(
          usage: nil,
          cores: [index % 13 == 0 ? nil : Double(index % 101), Double(100 - index % 101)],
          load: [],
          coreKinds: index > 35 && index < 45
            ? [.performance, .efficiency] : [.efficiency, .performance]))
    archive.append(point, uptime: Double(index * 3 + (index > 60 ? 20 : 1)))
  }
  for range in [HistoryRange.tenMinutes, .hour, .day] {
    let history = archive.projection(range)
    for statistic in [HistoryStatistic.peak, .average, .minimum] {
      let matrix = CoreHistoryMatrix(
        history, kinds: [.efficiency, .performance], statistic: statistic)
      for core in 0..<2 {
        let end = history.buckets.last?.last ?? Date(timeIntervalSince1970: 0)
        // Independent existing Plot representation exercises the same semantic input contract.
        let reference = SummaryDashboardView.Plot(
          first: matrix.cores.map { $0?.value(core, statistic: statistic) }, second: [],
          firstLabel: "Core", secondLabel: "", firstValue: "", secondValue: "", percent: true,
          mirrored: false,
          time: .init(history.bucketCenters, domain: (end - Double(range.rawValue))...end),
          partialFirst: zip(history.buckets, matrix.cores).map { bucket, data in
            (data?.validSamples(core) ?? 0) < bucket.samples || bucket.coreLayoutChanged
          }, gapBuckets: history.buckets.map(\.hasGap), statistic: statistic,
          firstWeights: matrix.cores.map { $0?.validSamples(core) ?? 0 })
        for width: CGFloat in [0, 1, 7.25, 496, 1200] {
          for scale: CGFloat in [1, 2] {
            let expected = HistoryBarLayout(
              plot: reference, graphWidth: width, scale: scale, timeline: matrix.timeline)
            let actual = coreHistoryBars(matrix, core: core, width: width, scale: scale)
            #expect(actual.columns == expected.columns)
            #expect(actual.maximum == expected.maximum && actual.hasData == expected.hasData)
            #expect(
              actual.pixelWidth == expected.pixelWidth && actual.slotCount == expected.slotCount
                && actual.barPixels == expected.barPixels)
            #expect(actual.columns.map(actual.x) == expected.columns.map(expected.x))
          }
        }
      }
    }
  }
}

@Test @MainActor func directCoreHistoryInputsKeepEmptyAndInvalidCoreRequestsUnavailable() {
  let matrix = CoreHistoryMatrix(.init(range: .day), kinds: [.unknown], statistic: .average)
  let empty = coreHistoryBars(matrix, core: 0, width: 496, scale: 2)
  #expect(empty.columns.isEmpty && !empty.hasData && empty.maximum == 100)
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.sampleInterval = 1
  point.cpuCores = CPUCoreHistorySample(.init(usage: nil, cores: [0], load: []))
  archive.append(point, uptime: 1)
  let valid = CoreHistoryMatrix(archive.projection(.hour), kinds: [.unknown], statistic: .minimum)
  let zero = coreHistoryBars(valid, core: 0, width: 400, scale: 1)
  let missing = coreHistoryBars(valid, core: 99, width: 400, scale: 1)
  #expect(zero.columns.first?.first == 0 && zero.hasData)
  #expect(missing.columns.first?.first == nil && !missing.hasData)
  #expect(missing.columns.first?.firstMissing == true && missing.columns.first?.firstWeight == 0)
}
