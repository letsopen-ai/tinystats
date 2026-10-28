import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func historyControls<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
  (root as? T).map { [$0] } ?? root.subviews.flatMap { historyControls(type, in: $0) }
}
private func layoutHistory() -> HistoryProjection {
  var history = SessionHistory()
  for i in 0..<2 {
    var point = Snapshot().historyPoint
    point.time = Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 2))
    point.sampleInterval = 2
    point.cpu = 40
    point.gpu = 40
    point.cpuCores = CPUCoreHistorySample(
      .init(
        usage: 40, cores: Array(repeating: 40, count: 10), load: [],
        coreKinds: Array(repeating: .efficiency, count: 6)
          + Array(repeating: .performance, count: 4)))
    history.append(point, uptime: Double(i * 2 + 1))
  }
  return history.projection(.tenMinutes)
}

@Test @MainActor func historyResizeUsesAddedHeightWithoutRebuildingSamples() throws {
  _ = NSApplication.shared
  let controller = HistoryController(module: .cpu, settings: Settings())
  defer { controller.window?.close() }
  controller.update(layoutHistory())
  let window = try #require(controller.window)
  let root = try #require(window.contentView)
  let graph = try #require(historyControls(SummaryDashboardView.self, in: root).first)
  let scroll = try #require(historyControls(NSScrollView.self, in: root).first)
  guard case .plot(let before) = graph.cards[0].content else {
    Issue.record("Missing CPU history plot")
    return
  }
  let initialHeight = graph.cards[0].frame.height
  let coreHeight = graph.cards[1].frame.height
  window.setContentSize(.init(width: 760, height: 750))
  controller.windowDidResize(.init(name: NSWindow.didResizeNotification, object: window))
  #expect(graph.cards[0].frame.height >= initialHeight + 69)
  #expect(graph.cards[1].frame.height == coreHeight)
  #expect(abs(graph.cards[1].frame.maxY - graph.bounds.maxY) < 0.5)
  #expect(abs(graph.frame.width - scroll.contentSize.width) < 0.5)
  guard case .plot(let after) = graph.cards[0].content else {
    Issue.record("Missing resized plot")
    return
  }
  before.first.withUnsafeBufferPointer { old in
    after.first.withUnsafeBufferPointer { new in
      #expect(old.baseAddress == new.baseAddress)
    }
  }
  window.setContentSize(.init(width: 560, height: 680))
  controller.windowDidResize(.init(name: NSWindow.didResizeNotification, object: window))
  #expect(abs(graph.cards[0].frame.height - initialHeight) < 0.5)
  #expect(abs(graph.cards[1].frame.maxY - graph.bounds.maxY) < 0.5)
}

@Test @MainActor func historyFooterAndLabelsFollowWindowWidth() throws {
  _ = NSApplication.shared
  let controller = HistoryController(module: .cpu, settings: Settings())
  defer { controller.window?.close() }
  let window = try #require(controller.window)
  let root = try #require(window.contentView)
  window.setContentSize(.init(width: 900, height: 750))
  controller.windowDidResize(.init(name: NSWindow.didResizeNotification, object: window))
  let buttons = historyControls(NSButton.self, in: root)
  let export = try #require(buttons.first { $0.title == "Export CSV…" })
  let clear = try #require(buttons.first { $0.title == "Clear history…" })
  #expect(abs(root.bounds.maxX - export.frame.maxX - 20) < 0.5)
  #expect(export.frame.minY == clear.frame.minY && clear.frame.minX == 20)
  let status = try #require(
    historyControls(NSTextField.self, in: root).first {
      $0.stringValue.hasPrefix("Span ")
    })
  #expect(abs(status.frame.width - (root.bounds.width - 48)) < 0.5)
}

@Test @MainActor func historyInspectionPluralizesActualBucketCounts() throws {
  let projection = layoutHistory()
  for (width, expected) in [(520.0, "1 bucket"), (30.0, "2 buckets")] {
    let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: width, height: 300))
    view.updateHistory(projection, module: .gpu, fahrenheit: false)
    let card = try #require(view.cards.first)
    guard case .plot(let plot) = card.content else {
      Issue.record("Missing plot")
      return
    }
    let area = NSRect(x: 12, y: 31, width: card.frame.width - 24, height: card.frame.height - 37)
    let rect = SummaryDashboardView.plotGraphRect(plot, area: area)
    let text = try #require(view.hoverText(at: .init(x: rect.maxX - 0.5, y: rect.midY)))
    #expect(text.contains("Peak · " + expected))
    #expect(!text.contains("bucket(s)"))
  }
}

@Test @MainActor func historyDataRefreshRequestsPaintingWithoutGeometryChanges() throws {
  _ = NSApplication.shared
  let controller = HistoryController(module: .cpu, settings: Settings())
  defer { controller.window?.close() }
  controller.update(layoutHistory())
  let root = try #require(controller.window?.contentView)
  let graph = try #require(historyControls(SummaryDashboardView.self, in: root).first)
  let size = graph.frame.size
  graph.needsDisplay = false
  controller.update(.init(range: .tenMinutes))
  #expect(graph.frame.size == size && graph.needsDisplay)
  guard case .plot(let plot) = graph.cards[0].content else {
    Issue.record("Missing refreshed plot")
    return
  }
  #expect(plot.firstValue == "—" && plot.first.isEmpty)
}
