import AppKit
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test func trafficGroupingMigratesAndRoundTripsWithoutChangingExistingChoices() throws {
  let legacy = try JSONDecoder().decode(
    Settings.self, from: Data("{\"theme\":\"dark\",\"networkInterface\":\"en0\"}".utf8))
  #expect(legacy.networkTrafficGrouping == .processes && legacy.networkTrafficRevision == "")
  #expect(legacy.theme == .dark && legacy.networkInterface == "en0")
  var current = legacy
  current.networkTrafficGrouping = .bundles
  current.networkTrafficRevision = "new"
  #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(current)) == current)
  let malformed = try JSONDecoder().decode(
    Settings.self, from: Data("{\"networkTrafficGrouping\":\"unknown\"}".utf8))
  #expect(malformed.networkTrafficGrouping == .processes)
}
@Test @MainActor func nativeNetworkGroupingResetsDisplayAndRejectsOldModeAndRevision() throws {
  let controller = DetailController()
  controller.selected = .network
  let control = try #require(
    controller.view.subviews.compactMap { $0 as? NSSegmentedControl }.first)
  #expect(!control.isHidden && control.selectedSegment == 0)
  var chosen: TrafficGrouping?
  controller.onNetworkGrouping = { [weak controller] mode in
    chosen = mode
    controller?.settings.networkTrafficRevision = "new"
  }
  var snapshot = Snapshot()
  snapshot.networkTraffic.availability = .ready
  snapshot.networkTraffic.processes = [
    .init(pid: 1, uniqueID: 1, name: "Old process", download: 100, upload: 200)
  ]
  controller.update(snapshot, history: [])
  control.selectedSegment = 1
  #expect(
    NSApplication.shared.sendAction(try #require(control.action), to: control.target, from: control)
  )
  #expect(chosen == .bundles && controller.snapshot.networkTraffic.processes.isEmpty)
  #expect(controller.snapshot.networkTraffic.message.contains("Collecting"))
  snapshot.networkTraffic.grouping = .bundles
  snapshot.networkTraffic.bundles = [
    .init(name: "Stale bundle", processCount: 2, pid: nil, download: 100, upload: 200)
  ]
  controller.update(snapshot, history: [])
  #expect(controller.snapshot.networkTraffic.bundles.isEmpty)
  snapshot.networkTraffic.revision = "new"
  controller.update(snapshot, history: [])
  let summary = try #require(
    controller.view.subviews.compactMap { $0 as? SummaryDashboardView }.first)
  #expect(summary.cards.map(\.spoken).joined().contains("Stale bundle · 2 active"))
  controller.selected = .cpu
  #expect(control.isHidden)
  controller.selected = .network
  #expect(!control.isHidden && control.selectedSegment == 1)
  let history = try #require(
    controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "History…" })
  #expect(control.frame.maxX <= history.frame.minX)
}
@Test @MainActor func bundleDashboardKeepsGraphicalRatesAndMakesScopeSpoken() throws {
  var snapshot = Snapshot()
  var settings = Settings()
  settings.networkTrafficGrouping = .bundles
  snapshot.networkTraffic.grouping = .bundles
  snapshot.networkTraffic.availability = .ready
  snapshot.networkTraffic.bundles = [
    .init(name: "Browser", processCount: 3, pid: nil, download: 200, upload: 100)
  ]
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(snapshot, history: [], settings: settings, module: .network)
  let card = try #require(view.cards.last)
  #expect(card.title.contains("APP BUNDLES") && card.title.contains("PARTIAL"))
  #expect(
    card.spoken.contains("Browser · 3 active")
      && card.spoken.contains("shared / unresolved separate"))
  guard case .rows(let rows) = card.content else {
    Issue.record("Missing paired graphical rows")
    return
  }
  #expect(rows.count == 1 && rows[0].fraction == 0.5 && rows[0].secondFraction == 1)
  #expect(view.subviews.isEmpty)
}
@Test @MainActor func unrelatedSettingsChangePreservesNetworkGroupingAndRevision() throws {
  let preferences = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { preferences.close() }
  preferences.updateNetworkGrouping(.bundles, revision: "live")
  var saved: Settings?
  preferences.onChange = { saved = $0 }
  func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
  let root = try #require(preferences.window?.contentView)
  let control = try #require(
    descendants(root).compactMap { $0 as? SystemSettingSwitch }.first {
      $0.title == "Use Fahrenheit"
    })
  control.state = .on
  #expect(
    NSApplication.shared.sendAction(try #require(control.action), to: control.target, from: control)
  )
  #expect(saved?.networkTrafficGrouping == .bundles && saved?.networkTrafficRevision == "live")
}

@Test @MainActor func bundleAllReadingsShowsGroupsFallbackRatesAndEmptyTrafficWithoutDuplicates()
  throws
{
  let controller = DetailController()
  controller.settings.networkTrafficGrouping = .bundles
  controller.selected = .network
  controller.showsAllReadings = true
  var s = Snapshot()
  s.networkTraffic.grouping = .bundles
  s.networkTraffic.availability = .ready
  s.networkTraffic.processes = [
    .init(pid: 1, uniqueID: 1, name: "Duplicate sentinel", download: 1, upload: 1)
  ]
  s.networkTraffic.bundles = [
    .init(name: "Browser", processCount: 3, pid: nil, download: 2048, upload: 1024),
    .init(name: "Broker", processCount: 1, pid: 99, download: 512, upload: 256),
  ]
  controller.update(s, history: [])
  let table = try #require(
    controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  func rowStrings() -> [(String, String)] {
    (0..<table.numberOfRows).map { row in
      (
        (controller.tableView(table, viewFor: table.tableColumns[0], row: row) as? NSTextField)?
          .stringValue ?? "",
        (controller.tableView(table, viewFor: table.tableColumns[1], row: row) as? NSTextField)?
          .stringValue ?? ""
      )
    }
  }
  let rows = rowStrings()
  #expect(
    rows.contains {
      $0.0 == "Browser · 3 active" && $0.1 == "↓ \(Display.rate(2048))  ↑ \(Display.rate(1024))"
    })
  #expect(rows.contains { $0.0 == "Broker · 99" && $0.1 == "↓ 512 B/s  ↑ 256 B/s" })
  #expect(!rows.contains { $0.0.contains("Duplicate sentinel") })
  #expect(rows.contains { $0.0 == "Scope" && $0.1 == "All interfaces + loopback" })
  #expect(rows.contains { $0.0 == "Shared services / WebKit" && $0.1.contains("not attributed") })
  s.networkTraffic.bundles = []
  controller.update(s, history: [])
  #expect(rowStrings().contains { $0.0 == "Active kernel TCP/UDP traffic" && $0.1 == "None" })
}

@Test @MainActor func networkPausedHeaderFitsBesideGroupingAndCanRenderSafeFixtures() throws {
  let controller = DetailController()
  controller.settings.networkTrafficGrouping = .bundles
  controller.selected = .network
  controller.paused = true
  let root = controller.view
  let title = try #require(
    root.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Network · Paused" })
  let width = (title.stringValue as NSString).size(withAttributes: [.font: try #require(title.font)]
  ).width
  #expect(width <= title.frame.width)
  guard let directory = ProcessInfo.processInfo.environment["TINYSTATS_BUNDLE_FIXTURE_CAPTURES"]
  else { return }
  let folder = URL(fileURLWithPath: directory, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let window = NSWindow(
    contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = controller
  defer {
    window.contentViewController = nil
    window.close()
  }
  var s = Snapshot()
  s.selectedInterface = "en-fixture"
  s.download = 2048
  s.upload = 1024
  s.networkTraffic.grouping = .bundles
  s.networkTraffic.availability = .ready
  s.networkTraffic.bundles = [
    .init(name: "Example Browser", processCount: 7, pid: nil, download: 4096, upload: 1024),
    .init(name: "Example Editor", processCount: 3, pid: nil, download: 1024, upload: 2048),
    .init(name: "Shared broker", processCount: 1, pid: 99, download: 512, upload: 256),
  ]
  let history = (0..<300).map { i -> HistoryPoint in
    var value = s
    value.timestamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 2))
    value.download = Double(100 + i % 30 * 100)
    value.upload = Double(200 + i % 11 * 80)
    return value.historyPoint
  }
  for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    window.appearance = NSAppearance(named: appearance)
    for state in ["ready", "paused", "collecting", "empty", "unavailable"] {
      var fixture = s
      controller.paused = state == "paused"
      if state != "ready" && state != "paused" { fixture.networkTraffic.bundles = [] }
      if state == "collecting" {
        fixture.networkTraffic.availability = .warming
        fixture.networkTraffic.message = "Collecting a second complete query for rates."
      } else if state == "unavailable" {
        fixture.networkTraffic.availability = .unavailable
        fixture.networkTraffic.message = "Native traffic unavailable. Retrying in one minute."
      }
      controller.update(fixture, history: history)
      root.layoutSubtreeIfNeeded()
      let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
      window.appearance?.performAsCurrentDrawingAppearance {
        root.cacheDisplay(in: root.bounds, to: bitmap)
      }
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: folder.appendingPathComponent("synthetic-\(state)-\(theme).png"))
    }
  }
}
