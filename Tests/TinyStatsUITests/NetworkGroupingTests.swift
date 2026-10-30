import AppKit
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func groupingDescendants(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + groupingDescendants($0) }
}

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
    groupingDescendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first)
  #expect(!control.isHidden && control.selectedSegment == 0)
  var chosen: TrafficGrouping?
  controller.onProcessGrouping = { [weak controller] mode in
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
  #expect(summary.cards.map(\.spoken).joined().contains("Stale bundle · 2 processes"))
  controller.selected = .cpu
  #expect(!control.isHidden)
  controller.selected = .network
  #expect(!control.isHidden && control.selectedSegment == 1)
  #expect(control.superview === summary)
  let card = try #require(summary.cards.first { $0.groupsProcesses })
  #expect(card.frame.contains(control.frame))
  #expect(control.frame.minY == card.frame.minY + 9)
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
  #expect(card.title.contains("APP TRAFFIC") && card.title.contains("PARTIAL"))
  #expect(
    card.spoken.contains("Browser · 3 processes")
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
  preferences.updateProcessGrouping(.bundles, revision: "live")
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
      let labelView = controller.tableView(table, viewFor: table.tableColumns[0], row: row)
      let label =
        (labelView as? NSTextField)?.stringValue
        ?? (labelView as? ProcessAppLabelCell)?.accessibilityLabel()?.components(
          separatedBy: " · "
        ).prefix(2).joined(separator: " · ") ?? ""
      return (
        label,
        (controller.tableView(table, viewFor: table.tableColumns[1], row: row) as? NSTextField)?
          .stringValue ?? ""
      )
    }
  }
  let rows = rowStrings()
  #expect(
    rows.contains {
      $0.0 == "Browser · 3 processes" && $0.1 == "↓ \(Display.rate(2048))  ↑ \(Display.rate(1024))"
    })
  #expect(rows.contains { $0.0 == "Broker · 1 process" && $0.1 == "↓ 512 B/s  ↑ 256 B/s" })
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

@Test func oneSharedGroupingPreferenceKeepsTheOriginalPersistedValueAndDefaults() throws {
  let saved = try JSONDecoder().decode(
    Settings.self,
    from: Data(#"{"networkTrafficGrouping":"bundles","networkTrafficRevision":"saved"}"#.utf8))
  #expect(saved.processGrouping == .bundles)
  var updated = saved
  updated.processGrouping = .processes
  #expect(updated.networkTrafficGrouping == .processes && updated.networkTrafficRevision == "saved")
  #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(updated)) == updated)
  let suite = "TinyStatsGroupingTests-" + UUID().uuidString
  let store = try #require(UserDefaults(suiteName: suite))
  defer { store.removePersistentDomain(forName: suite) }
  saved.save(to: store)
  #expect(Settings.load(from: store).processGrouping == .bundles)
}

@Test @MainActor func appReadingsKeepKnownCPUWithoutCoreInventoryAndUnavailableMemory() throws {
  var settings = Settings()
  settings.processGrouping = .bundles
  var sample = Snapshot()
  sample.cpuApps = [.init(name: "App", processCount: 2, cpu: 4, memory: nil)]
  sample.memoryApps = sample.cpuApps
  let cpu = try #require(
    DetailReadingsBuilder.build(
      module: .cpu, snapshot: sample, history: [], settings: settings, paused: true))
  let row = try #require(cpu.rows.first { $0.label == "App · 2 processes" })
  #expect(row.value == "4.0% of one core" && row.meter == nil)
  let memory = try #require(
    DetailReadingsBuilder.build(
      module: .memory, snapshot: sample, history: [], settings: settings, paused: true))
  #expect(memory.rows.first { $0.label == "App · 2 processes" }?.value == "—")
  #expect(memory.rows.contains { $0.label == "Shared pages" && $0.value == "May be counted twice" })
}

@Test @MainActor func cpuAndMemoryGroupingPreservesTrafficSnapshotAndRevision() throws {
  for module in [Module.cpu, .memory] {
    let detail = DetailController()
    detail.selected = module
    var sample = Snapshot()
    sample.networkTraffic.availability = .ready
    sample.networkTraffic.revision = "retained"
    sample.networkTraffic.processes = [
      .init(pid: 5, uniqueID: 6, name: "Broker", download: 10, upload: 20)
    ]
    detail.settings.networkTrafficRevision = "retained"
    detail.update(sample, history: [])
    let control = try #require(
      groupingDescendants(detail.view).compactMap { $0 as? ProcessGroupingControl }.first)
    control.selectedSegment = 1
    #expect(NSApp.sendAction(try #require(control.action), to: control.target, from: control))
    #expect(detail.snapshot.networkTraffic.availability == .ready)
    #expect(detail.snapshot.networkTraffic.revision == "retained")
    #expect(detail.snapshot.networkTraffic.processes.first?.pid == 5)
    #expect(detail.snapshot.networkTraffic.processes.first?.download == 10)
    #expect(detail.settings.networkTrafficRevision == "retained")
  }
}

@Test @MainActor func readingsGroupingHeaderRetainsParentAndKeyboardFocusAcrossSamples() throws {
  let detail = DetailController()
  detail.selected = .cpu
  detail.showsAllReadings = true
  var sample = Snapshot()
  sample.cpu = .init(usage: 10, cores: [10], load: [])
  sample.processes = [.init(pid: 1, name: "Helper", cpu: 10, memory: 1, read: nil, written: nil)]
  detail.update(sample, history: [])
  let window = NSWindow(
    contentRect: detail.view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = detail
  defer {
    window.contentViewController = nil
    window.close()
  }
  let table = try #require(groupingDescendants(detail.view).compactMap { $0 as? NSTableView }.first)
  let rows = try #require(
    DetailReadingsBuilder.build(
      module: .cpu, snapshot: sample, history: [], settings: detail.settings, paused: false)
  ).rows
  let header = try #require(rows.firstIndex(where: { $0.processGroupingHeader }))
  table.scrollRowToVisible(header)
  let cell = try #require(table.view(atColumn: 1, row: header, makeIfNecessary: true))
  let control = try #require(cell.subviews.compactMap { $0 as? ProcessGroupingControl }.first)
  #expect(window.makeFirstResponder(control))
  sample.processes[0].cpu = 20
  detail.update(sample, history: [])
  #expect(control.superview === cell && window.firstResponder === control)
  sample.processes.append(.init(pid: 2, name: "Second", cpu: 1, memory: 1, read: nil, written: nil))
  detail.update(sample, history: [])
  #expect(window.firstResponder === control)
  sample.cpuApps = [
    .init(name: "App", processCount: 1, cpu: 20, memory: 1),
    .init(name: "Second", processCount: 1, cpu: 1, memory: 1),
  ]
  detail.update(sample, history: [])
  control.selectedSegment = 1
  #expect(NSApp.sendAction(try #require(control.action), to: control.target, from: control))
  let heading = table.view(atColumn: 0, row: header, makeIfNecessary: true) as? NSTextField
  #expect(heading?.stringValue == "Top apps")
  #expect(control.superview === cell && window.firstResponder === control)
}

@Test @MainActor func brokerTableCellReservesTheCountAndKeepsPIDProvenance() throws {
  let cell = ProcessAppLabelCell(frame: .init(x: 0, y: 0, width: 165, height: 25))
  cell.update(
    .init(name: "Shared broker", icon: ProcessAppDisplayCache.placeholder), count: 1, path: nil,
    provenance: "Shared broker · 99")
  cell.needsLayout = true
  cell.layoutSubtreeIfNeeded()
  let fields = cell.subviews.compactMap { $0 as? NSTextField }
  let name = try #require(fields.first { $0.stringValue == "Shared broker" })
  let count = try #require(fields.first { $0.stringValue == "1" })
  #expect(!name.frame.intersects(count.frame))
  #expect(name.intrinsicContentSize.width <= name.frame.width)
  #expect(count.toolTip == "1 process")
  #expect(cell.accessibilityLabel()?.contains("Shared broker · 99") == true)
  #expect(cell.accessibilityLabel()?.contains("1 process") == true)
}
