import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func mainWindowResizesWithoutTabSizeResets() throws {
  _ = NSApplication.shared
  let window = MainWindow()
  let detail = DetailController()
  window.contentViewController = detail
  defer { window.close() }
  #expect(window.styleMask.contains(.resizable) && window.styleMask.contains(.miniaturizable))
  #expect(window.contentMinSize == MainWindow.minimumSize)
  window.setContentSize(.init(width: 1200, height: 850))
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { controller.disposeEmbedded() }
  let root = try #require(controller.embeddedView(page: .general))
  detail.showSettingsView(root, page: .general)
  detail.view.layoutSubtreeIfNeeded()
  #expect(detail.view.bounds.size == NSSize(width: 1200, height: 850))
  #expect(root.frame.width == 740 && root.frame.height == 850)
  for module in Module.allCases {
    detail.selected = module
    detail.view.layoutSubtreeIfNeeded()
    #expect(detail.view.bounds.size == NSSize(width: 1200, height: 850))
  }
}

@Test @MainActor func summaryCardsGrowAndStayWithinResizedContent() {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  for module in Module.allCases where SummaryDashboardView.supports(module) {
    view.frame.size = .init(width: 520, height: 454)
    view.update(Snapshot(), history: [], settings: Settings(), module: module)
    let original = view.cards.map(\.frame)
    view.frame.size = .init(width: 1020, height: 744)
    for (index, card) in view.cards.enumerated() {
      #expect(card.frame.maxX <= 1020.01 && card.frame.maxY <= 744.01)
      #expect(card.frame.width > original[index].width)
      if module == .overview {
        if index == 0 {
          #expect(card.frame.height == 74 && original[index].height == 86)
        } else {
          #expect(card.frame.height >= original[index].height)
        }
      } else {
        #expect(card.frame.height > original[index].height)
      }
    }
    let resized = view.cards.map(\.frame)
    view.update(Snapshot(), history: [], settings: Settings(), module: module)
    #expect(view.cards.map(\.frame) == resized)
  }
}

@Test @MainActor func retainedClosedMainWindowDropsItsControllerAndContent() {
  _ = NSApplication.shared
  let window = MainWindow()
  weak var controller: DetailController?
  weak var root: NSView?
  autoreleasepool {
    let detail = DetailController()
    controller = detail
    window.contentViewController = detail
    root = detail.view
    window.makeKeyAndOrderFront(nil)
    window.close()
  }
  #expect(window.contentViewController == nil)
  #expect(root == nil && controller == nil)
}

@Test @MainActor func hiddenEmbeddedMenuBarPreviewDoesNotRebuildForClockOrContext() throws {
  _ = NSApplication.shared
  let prefs = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  let host = MainWindow()
  let root = try #require(prefs.embeddedView(page: .menuBar))
  host.contentView = root
  host.makeKeyAndOrderFront(nil)
  defer {
    prefs.disposeEmbedded()
    host.close()
  }
  prefs.refreshVisibleContent()
  func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
  let preview = try #require(descendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
  let before = preview.renderers.map { $0.readouts.map(\.appearance) }
  root.isHidden = true
  // An appearance-context update would mutate all renderer widths/readings without the visibility guard.
  prefs.updateMenuBarContext(
    appearance: NSAppearance(named: .darkAqua), order: [], height: 42, paused: true)
  prefs.updateClock(Date(timeIntervalSince1970: 1000))
  #expect(preview.renderers.allSatisfy { !$0.paused })
  #expect(preview.renderers.map { $0.readouts.map(\.appearance) } == before)
  root.isHidden = false
  prefs.refreshVisibleContent()
  #expect(preview.renderers.allSatisfy { $0.paused })
}

@Test @MainActor func mainWindowVisibilityPausesAndRestoresSelectedDemandWithoutLeavingSettings()
  throws
{
  let detail = DetailController()
  detail.loadViewIfNeeded()
  var calls: [Module?] = []
  detail.onMonitoringDemand = { calls.append($0) }
  detail.selected = .cpu
  detail.monitoringVisibilityChanged(false)
  detail.monitoringVisibilityChanged(true)
  let prefs = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { prefs.disposeEmbedded() }
  detail.showSettingsView(try #require(prefs.embeddedView(page: .general)), page: .general)
  detail.monitoringVisibilityChanged(false)
  detail.monitoringVisibilityChanged(true)
  #expect(calls == [.cpu, nil, .cpu, nil, nil, nil])
  #expect(detail.showsSettings)
}

@Test @MainActor func lazySettingsPagesKeepTheirButtonGapsAtEveryHostSize() throws {
  _ = NSApplication.shared
  let prefs = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  let host = MainWindow()
  let root = try #require(prefs.embeddedView(page: .menuBar))
  host.contentView = root
  defer {
    prefs.disposeEmbedded()
    host.close()
  }
  host.setContentSize(.init(width: 1150, height: 820))
  _ = prefs.embeddedView(page: .general)
  func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
  let buttons = descendants(root).compactMap { $0 as? NSButton }
  let calendar = try #require(buttons.first { $0.accessibilityLabel() == "Calendar settings" })
  let internet = try #require(buttons.first { $0.accessibilityLabel() == "Internet checks" })
  let disclosure = try #require(
    buttons.first { $0.accessibilityLabel() == "Online & Time advanced" })
  let storage = try #require(buttons.first { $0.title == "History & storage…" })
  for size in [NSSize(width: 884, height: 660), NSSize(width: 1200, height: 850)] {
    host.setContentSize(size)
    for page in [PreferencesController.Page.general, .menuBar] {
      prefs.selectPage(page)
      root.layoutSubtreeIfNeeded()
      let form = try #require(descendants(root).compactMap { $0 as? SystemSettingsForm }.first)
      let document = try #require(form.documentView)
      #expect(form.bounds.width > 0 && document.bounds.width == form.contentSize.width)
      for row in descendants(document).compactMap({ $0 as? SystemFormRow }) {
        #expect(!row.hasAmbiguousLayout)
        for control in row.subviews {
          #expect(row.bounds.contains(control.frame))
        }
      }
    }
    prefs.selectPage(.general)
    for _ in 0..<2 {
      disclosure.performClick(nil)
      root.layoutSubtreeIfNeeded()
      if disclosure.isAccessibilityExpanded() {
        let form = try #require(internet.enclosingScrollView)
        let document = try #require(form.documentView)
        let internetFrame = internet.convert(internet.bounds, to: document)
        let calendarFrame = calendar.convert(calendar.bounds, to: document)
        #expect(!internetFrame.intersects(calendarFrame))
        #expect(document.bounds.contains(internetFrame) && document.bounds.contains(calendarFrame))
      }
      _ = storage.scrollToVisible(storage.bounds)
      let form = try #require(storage.enclosingScrollView)
      let document = try #require(form.documentView)
      #expect(form.documentVisibleRect.intersects(storage.convert(storage.bounds, to: document)))
    }
  }

}

@Test @MainActor func expandedSummaryScalesTypeAndShowsMoreAlreadyCollectedProcesses() throws {
  var snapshot = Snapshot()
  snapshot.processes = (0..<20).map {
    .init(
      pid: Int32($0 + 100), name: "Fixture \($0)", cpu: Double($0), memory: UInt64($0 + 1), read: 0,
      written: 0)
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(snapshot, history: [], settings: Settings(), module: .cpu)
  #expect(view.contentScale == 1)
  view.frame.size = .init(width: 1740, height: 894)
  view.update(snapshot, history: [], settings: Settings(), module: .cpu)
  #expect(view.contentScale > 1 && view.contentScale <= 1.5)
  let card = try #require(view.cards.first { $0.title == "TOP PROCESSES" })
  guard case .rows(let rows) = card.content else {
    Issue.record("Missing process rows")
    return
  }
  #expect(rows.count <= 12)
  #expect(view.displayedRows(in: card).count > 5 && view.displayedRows(in: card).count <= 12)
}

@Test @MainActor func gpuTimeRowsReturnAfterResizeWithoutAnotherSample() throws {
  var snapshot = Snapshot()
  snapshot.gpuTime.status = .ready
  snapshot.gpuTime.rows = (0..<12).map {
    .init(pid: Int32($0 + 1), name: "Fixture \($0)", millisecondsPerSecond: Double(12 - $0))
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(snapshot, history: [], settings: Settings(), module: .gpu)
  let compact = try #require(view.cards.first { $0.title == "METAL GPU TIME" })
  #expect(view.displayedRows(in: compact).count == 6)
  func checkVisibleHover(_ card: SummaryDashboardView.Card) {
    let rows = view.displayedRows(in: card)
    let zoom = view.contentScale
    let height = min(25, (card.frame.height / zoom - 37 - 17) / CGFloat(rows.count))
    for (index, row) in rows.enumerated() {
      let point = NSPoint(
        x: card.frame.minX + 20 * zoom,
        y: card.frame.minY + (31 + (CGFloat(index) + 0.5) * height) * zoom)
      #expect(view.hoverText(at: point) == row.label + ": " + row.value)
    }
  }
  checkVisibleHover(compact)
  view.setFrameSize(.init(width: 1040, height: 900))
  let expanded = try #require(view.cards.first { $0.title == "METAL GPU TIME" })
  #expect(view.displayedRows(in: expanded).count == 12)
  checkVisibleHover(expanded)
  view.setFrameSize(.init(width: 520, height: 454))
  let restored = try #require(view.cards.first { $0.title == "METAL GPU TIME" })
  #expect(view.displayedRows(in: restored).count == 6)
  checkVisibleHover(restored)
}

@Test @MainActor func missingProcessRatesStayOutOfListsAndGPUCaveatSurvivesSmallTiles() throws {
  var snapshot = Snapshot()
  snapshot.processes = [
    .init(pid: 1, name: "Repeated", cpu: nil, memory: 1, read: nil, written: nil),
    .init(pid: 2, name: "Repeated", cpu: 2, memory: 2, read: nil, written: nil),
  ]
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 554))
  view.update(snapshot, history: [], settings: Settings(), module: .cpu)
  let cpu = try #require(view.cards.first { $0.title == "TOP PROCESSES" })
  guard case .rows(let rows) = cpu.content else {
    Issue.record("Missing CPU rows")
    return
  }
  #expect(rows.count == 1 && rows[0].label == "Repeated (2)")
  view.update(snapshot, history: [], settings: Settings(), module: .disks)
  let disk = try #require(view.cards.first { $0.title == "TOP PROCESSES" })
  guard case .none = disk.content else {
    Issue.record("Empty disk rows should have one status")
    return
  }
  view.update(snapshot, history: [], settings: Settings(), module: .gpu)
  #expect(
    view.cards.first { $0.title == "DRIVER ENGINES" }?.note.contains(
      "Usage per GPU core is not available") == true)
}

@Test @MainActor func calendarGridGrowsWithItsAvailableSpace() throws {
  let calendar = MonthCalendarView(frame: .init(x: 0, y: 0, width: 300, height: 130))
  let labels = calendar.subviews.compactMap { $0 as? NSTextField }
  let before = try #require(labels.first?.font?.pointSize)
  calendar.setFrameSize(.init(width: 600, height: 260))
  #expect(labels.first?.font?.pointSize == before * 2)
  #expect(calendar.subviews.allSatisfy { calendar.bounds.contains($0.frame) })
}

@Test @MainActor func pairedProcessRowsReserveSpaceBetweenNumbersAndMeters() throws {
  for height: CGFloat in [14, 18, 20, 25] {
    let layout = SummaryDashboardView.PairedRowLayout(height: height)
    #expect(layout.meterY >= layout.textHeight + 3)
    #expect(layout.meterY + 2 <= height)
  }
  var snapshot = Snapshot()
  snapshot.processes = (0..<20).map {
    .init(
      pid: Int32($0), name: "Process \($0)", cpu: 0, memory: 1,
      read: Double($0), written: Double($0))
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 1740, height: 894))
  view.update(snapshot, history: [], settings: Settings(), module: .disks)
  let card = try #require(view.cards.first { $0.title == "TOP PROCESSES" })
  guard case .rows(let rows) = card.content else {
    Issue.record("Missing paired rates")
    return
  }
  #expect(!rows.isEmpty)
  #expect(
    (card.frame.height / view.contentScale - 54) / CGFloat(view.displayedRows(in: card).count) >= 20
  )
}
