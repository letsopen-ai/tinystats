import AppKit
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func emptyChartsUseNeutralCopyWhenHardwareReadingsAreMissing() throws {
  _ = NSApplication.shared
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 302, height: 100))
  #expect(chart.emptyMessage == "No readings yet")
  let detail = DetailController(snapshot: Snapshot(), history: [])
  detail.selected = .gpu
  let rawChart = try #require(detail.view.subviews.compactMap { $0 as? ChartView }.first)
  #expect(rawChart.emptyMessage == "No readings yet")
  #expect(rawChart.series.flatMap(\.values).compactMap { $0 }.isEmpty)
}

@Test @MainActor func chartHoverUsesActualValuesUnitsZeroMissingAndUncollectedTime() throws {
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 302, height: 100))
  chart.times = [epoch, epoch + 2, epoch + 4]
  chart.valueFormat = .rate
  chart.series = [.init(name: "Download", color: .systemBlue, values: [0, nil, 2048])]
  #expect(chart.hoverText(at: .init(x: 1, y: 40))?.contains("Download: 0 B/s") == true)
  #expect(chart.hoverText(at: .init(x: 151, y: 40))?.contains("Unavailable") == true)
  #expect(chart.hoverText(at: .init(x: 300, y: 40))?.contains("2.0 KiB/s") == true)
  #expect(chart.hoverText(at: .init(x: 100, y: 2)) == nil)
  #expect(ChartValueFormat.temperature(fahrenheit: true).string(0) == "32.0°F")
  #expect(ChartValueFormat.percent.string(0) == "0.0%")
  #expect(ChartValueFormat.number.string(.nan) == "Unavailable")
  var archive = SessionHistory()
  var point = Snapshot().historyPoint
  point.time = epoch
  point.sampleInterval = 1
  point.cpu = 0
  archive.append(point, uptime: 1)
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  view.updateHistory(archive.projection(.tenMinutes), module: .cpu, fahrenheit: false)
  #expect(view.hoverText(at: .init(x: 15, y: 130)) == "No recorded observations here")
  #expect(view.hoverText(at: .init(x: 506, y: 130))?.contains("0.0%") == true)
}

@Test @MainActor func chartHoverAndHeatmapShareCPUTimePositionsAndCacheCoreTotals() throws {
  var archive = SessionHistory()
  for (seconds, value) in [(0.0, 10.0), (1, 30), (13, 90)] {
    var point = Snapshot().historyPoint
    point.time = Date(timeIntervalSince1970: 1_699_999_992 + seconds)
    point.sampleInterval = 1
    point.cpu = value
    point.cpuCores = CPUCoreHistorySample(
      .init(usage: value, cores: [value], load: [], coreKinds: [.efficiency]))
    archive.append(point, uptime: seconds + 1)
  }
  let projection = archive.projection(.hour)
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 465))
  view.updateHistory(projection, module: .cpu, fahrenheit: false, statistic: .average)
  guard case .plot(let plot) = view.cards.first?.content,
    case .coreHistory(let matrix) = view.cards.last?.content
  else {
    Issue.record("Missing CPU/core history charts")
    return
  }
  #expect(
    plot.times == projection.bucketCenters && matrix.timeline.positions == plot.timeline.positions)
  let area = NSRect(x: 12, y: 31, width: 496, height: 120)
  let totalRect = SummaryDashboardView.plotGraphRect(plot, area: area)
  let coreRect = SummaryDashboardView.coreHistoryGraphRect(area: area, count: matrix.kinds.count)
  #expect(
    plot.alignsCoreHistory && totalRect.minX == coreRect.minX && totalRect.maxX == coreRect.maxX)
  let average = try #require(matrix.values[0])
  #expect(matrix.counts == [3] && abs(average - 130.0 / 3) < 0.0001)
  #expect(view.hoverText(at: .init(x: 454, y: 232))?.contains("Sample average") == true)
  view.setFrameSize(.init(width: 1200, height: 900))
  view.updateHistory(projection, module: .cpu, fahrenheit: false, statistic: .average)
  #expect(view.contentScale == 1 && view.cards.allSatisfy { $0.frame.width == 1200 })
}

@Test @MainActor func chartHoverUsesTheSelectedLaterAndGroupedObservationBounds() throws {
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  let plot = SummaryDashboardView.Plot(
    first: [10, 90], second: [], firstLabel: "CPU", secondLabel: "", firstValue: "",
    secondValue: "", percent: true, mirrored: false, time: .init([epoch, epoch + 4]))
  let separate = HistoryBarLayout(plot: plot, graphWidth: 200, scale: 1)
  let last = try #require(separate.columns.last)
  #expect(last.first == 90 && last.firstIndex == 1 && last.lastIndex == 1)
  let grouped = HistoryBarLayout(plot: plot, graphWidth: 1, scale: 1)
  #expect(grouped.columns[0].firstIndex == 0 && grouped.columns[0].lastIndex == 1)
  var archive = SessionHistory()
  for seconds in [0.0, 4] {
    var point = Snapshot().historyPoint
    point.time = epoch + seconds
    point.sampleInterval = 1
    point.cpu = seconds == 0 ? 10 : 90
    archive.append(point, uptime: seconds + 1)
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  view.updateHistory(archive.projection(.tenMinutes), module: .cpu, fahrenheit: false)
  let text = try #require(view.hoverText(at: .init(x: 507.5, y: 130)))
  #expect(text.contains(ChartHoverView.hoverDate(epoch + 4)) && text.contains("90.0%"))
}

@MainActor private final class HoverLifecycleFixture: ChartHoverView {
  override func hoverText(at point: NSPoint) -> String? { "Fixture reading: 42.0%" }
}

@Test @MainActor func chartHoverCreatesOneBubbleReplacesTrackingAndReleasesOnDetach() throws {
  weak var releasedBubble: NSView?
  weak var releasedChart: HoverLifecycleFixture?
  try autoreleasepool {
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 300, height: 180), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let chart = HoverLifecycleFixture(frame: .init(x: 0, y: 0, width: 300, height: 180))
    releasedChart = chart
    window.contentView = chart
    window.orderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    #expect(chart.subviews.isEmpty && chart.hoverAccessibilityElement == nil)
    for _ in 0..<5 { chart.updateTrackingAreas() }
    #expect(chart.trackingAreas.count == 1)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: .init(x: 40, y: 70), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
    )
    chart.mouseDown(with: event)
    let bubble = try #require(chart.hoverAccessibilityElement)
    releasedBubble = bubble
    let identity = ObjectIdentifier(bubble)
    chart.mouseDragged(with: event)
    chart.mouseMoved(with: event)
    let secondIdentity = ObjectIdentifier(try #require(chart.hoverAccessibilityElement))
    #expect(chart.subviews.count == 1 && secondIdentity == identity)
    let edgeEvent = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: .init(x: 280, y: 70), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)
    )
    chart.mouseMoved(with: edgeEvent)
    #expect(bubble.frame.maxX <= 268 && chart.subviews.count == 1)
    chart.mouseExited(with: event)
    #expect(chart.hoverAccessibilityElement == nil && chart.subviews.count == 1)
    window.contentView = nil
    #expect(chart.subviews.isEmpty)
  }
  #expect(releasedBubble == nil && releasedChart == nil)
}

@Test @MainActor func coreHistoryAndTotalShareDevicePixelColumnsAtFractionalWidths() {
  var plot = SummaryDashboardView.Plot(
    first: [10, 90], second: [], firstLabel: "CPU", secondLabel: "", firstValue: "",
    secondValue: "", percent: true, mirrored: false,
    time: .init(
      [Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_600)],
      domain: Date(
        timeIntervalSince1970: 1_700_000_000)...Date(timeIntervalSince1970: 1_700_000_600)))
  plot.alignsCoreHistory = true
  for scale: CGFloat in [1, 2] {
    for width: CGFloat in [496, 496.25, 703.75] {
      let area = NSRect(x: 12.25, y: 31, width: width, height: 120)
      let total = SummaryDashboardView.snappedTimeColumn(
        SummaryDashboardView.plotGraphRect(plot, area: area), scale: scale)
      let cores = SummaryDashboardView.coreHistoryGraphRect(area: area, count: 10, scale: scale)
      let totalLayout = HistoryBarLayout(plot: plot, graphWidth: total.width, scale: scale)
      let coreLayout = HistoryBarLayout(plot: plot, graphWidth: cores.width, scale: scale)
      #expect(total.minX == cores.minX && total.maxX == cores.maxX)
      #expect(
        zip(totalLayout.columns, coreLayout.columns).allSatisfy {
          total.minX + totalLayout.x($0) == cores.minX + coreLayout.x($1)
        })
    }
  }
  #expect(CPUCoreKind.efficiency.chartColor == SystemStyle.moduleSecondary(.cpu))
  #expect(CPUCoreKind.performance.chartColor == SystemStyle.moduleAccent(.cpu))
  #expect(
    CPUCoreKind.unknown.chartColor == NSColor.secondaryLabelColor
      && CPUCoreKind.unknown.chartTitle == "Unclassified")
}

@Test @MainActor func rawChartRefreshesVisibleReadingWhenTimesFollowSeries() throws {
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  let window = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 302, height: 100), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 302, height: 100))
  window.contentView = chart
  window.orderFront(nil)
  defer {
    window.contentView = nil
    window.close()
  }
  chart.series = [.init(name: "CPU", color: .systemBlue, values: [10, 90])]
  chart.times = [epoch, epoch + 2]
  let event = try #require(
    NSEvent.mouseEvent(
      with: .mouseMoved, location: .init(x: 300, y: 40), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
  chart.mouseMoved(with: event)
  let first = chart.hoverAccessibilityElement?.accessibilityValue() as? String
  #expect(first?.contains(ChartHoverView.hoverDate(epoch + 2)) == true)
  chart.series = [.init(name: "CPU", color: .systemBlue, values: [20, 80])]
  chart.times = [epoch + 60, epoch + 62]
  let current = chart.hoverAccessibilityElement?.accessibilityValue() as? String
  #expect(
    current?.contains(ChartHoverView.hoverDate(epoch + 62)) == true
      && current?.contains("80.0%") == true)
}

@MainActor private final class ScrollHoverFixture: ChartHoverView {
  var pointerInWindow = NSPoint(x: 40, y: 70)
  var readingCount = 0
  override var isFlipped: Bool { true }
  override func hoverText(at point: NSPoint) -> String? {
    readingCount += 1
    return "Document row \(Int(point.y / 20))"
  }
}

@Test @MainActor func chartHoverRebasesStationaryPointerWhenClipScrolls() throws {
  let window = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 300, height: 180), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 300, height: 180))
  let chart = ScrollHoverFixture(frame: .init(x: 0, y: 0, width: 300, height: 800))
  scroll.documentView = chart
  window.contentView = scroll
  window.orderFront(nil)
  defer {
    window.contentView = nil
    window.close()
  }
  let clip = scroll.contentView
  clip.setBoundsOrigin(.init(x: 0, y: 20))
  #expect(chart.subviews.isEmpty)
  let event = try #require(
    NSEvent.mouseEvent(
      with: .mouseMoved, location: chart.pointerInWindow, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
  chart.mouseMoved(with: event)
  let bubble = try #require(chart.hoverAccessibilityElement)
  let first = bubble.accessibilityValue() as? String
  clip.setBoundsOrigin(.init(x: 0, y: 120))
  let expected = chart.hoverText(at: chart.convert(chart.pointerInWindow, from: nil))
  #expect(expected != first)
  #expect(chart.hoverAccessibilityElement === bubble)
  #expect(bubble.accessibilityValue() as? String == expected)
  chart.mouseExited(with: event)
  clip.setBoundsOrigin(.init(x: 0, y: 180))
  #expect(chart.hoverAccessibilityElement == nil && chart.subviews.count == 1)
}

@Test @MainActor func chartHoverRebindsScrollingAndReleasesDetachedView() throws {
  weak var releasedChart: ScrollHoverFixture?
  try autoreleasepool {
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 300, height: 180), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: .init(x: 0, y: 0, width: 300, height: 180))
    let first = NSScrollView(frame: .init(x: 0, y: 0, width: 140, height: 180))
    let second = NSScrollView(frame: .init(x: 150, y: 0, width: 140, height: 180))
    root.addSubview(first)
    root.addSubview(second)
    let chart = ScrollHoverFixture(frame: .init(x: 0, y: 0, width: 140, height: 800))
    releasedChart = chart
    first.documentView = chart
    window.contentView = root
    window.orderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    first.documentView = nil
    second.documentView = chart
    chart.pointerInWindow = .init(x: 190, y: 70)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: chart.pointerInWindow, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
    )
    chart.mouseMoved(with: event)
    for _ in 0..<5 { chart.viewDidMoveToWindow() }
    let before = chart.readingCount
    first.contentView.setBoundsOrigin(.init(x: 0, y: 40))
    #expect(chart.readingCount == before)
    second.contentView.setBoundsOrigin(.init(x: 0, y: 120))
    #expect(chart.readingCount == before + 1)
    let expected = chart.hoverText(at: chart.convert(chart.pointerInWindow, from: nil))
    #expect(chart.hoverAccessibilityElement?.accessibilityValue() as? String == expected)
    second.documentView = nil
    let detachedReads = chart.readingCount
    second.contentView.setBoundsOrigin(.init(x: 0, y: 180))
    #expect(chart.readingCount == detachedReads && chart.subviews.isEmpty)
  }
  #expect(releasedChart == nil)
}

@Test @MainActor func chartHoverKeepsEventScreenPositionAcrossWindowMovement() throws {
  let window = NSWindow(
    contentRect: .init(x: 100, y: 100, width: 300, height: 180), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let chart = ScrollHoverFixture(frame: .init(x: 0, y: 0, width: 300, height: 180))
  window.contentView = chart
  window.orderFront(nil)
  defer {
    window.contentView = nil
    window.close()
  }
  let screenPoint = window.convertPoint(toScreen: chart.pointerInWindow)
  let event = try #require(
    NSEvent.mouseEvent(
      with: .mouseMoved, location: chart.pointerInWindow, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
  chart.mouseMoved(with: event)
  let first = chart.hoverAccessibilityElement?.accessibilityValue() as? String
  window.setFrameOrigin(.init(x: 100, y: 120))
  chart.updateTrackingAreas()
  let point = chart.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
  let expected = chart.hoverText(at: point)
  #expect(expected != first)
  #expect(chart.hoverAccessibilityElement?.accessibilityValue() as? String == expected)
}
