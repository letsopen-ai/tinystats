import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func detailFooterKeepsPauseAndResumeWithoutQuit() throws {
  _ = NSApplication.shared
  let detail = DetailController()
  detail.onPause = { [weak detail] in detail?.paused.toggle() }
  detail.loadViewIfNeeded()
  for size in [NSSize(width: 700, height: 640), NSSize(width: 1200, height: 850)] {
    detail.view.setFrameSize(size)
    for module in [Module.overview, .cpu, .sensors] {
      detail.selected = module
      for allReadings in [false, true] {
        detail.showsAllReadings = allReadings
        detail.update(Snapshot(), history: [])
        detail.view.layoutSubtreeIfNeeded()
        let buttons = detail.view.subviews.compactMap { $0 as? NSButton }
        #expect(!buttons.contains { $0.title.hasPrefix("Quit") })
        let footer = buttons.filter { $0.frame.minY < 50 }
        #expect(footer.map(\.title) == ["Pause"])
        let pause = try #require(footer.first)
        #expect(!pause.isHiddenOrHasHiddenAncestor && pause.isEnabled)
        #expect(detail.view.bounds.contains(pause.frame))
        #expect(detail.view.bounds.maxX - pause.frame.maxX == 28)
        #expect(NSApp.sendAction(try #require(pause.action), to: pause.target, from: pause))
        #expect(detail.paused && pause.title == "Resume")
        detail.update(Snapshot(), history: [])
        #expect(!pause.isHiddenOrHasHiddenAncestor && pause.isEnabled)
        #expect(NSApp.sendAction(try #require(pause.action), to: pause.target, from: pause))
        #expect(!detail.paused && pause.title == "Pause")
      }
    }
  }
}

@Test @MainActor func localDetailReadingsKeepUnavailableHeadlinesAndHistoryGaps() throws {
  var settings = Settings()
  settings.weather.enabled = false
  let snapshot = Snapshot()
  var missing = snapshot.historyPoint
  missing.cpu = nil
  missing.gpu = nil
  missing.memory = nil
  missing.diskRead = nil
  missing.diskWrite = nil
  missing.download = nil
  missing.upload = nil
  missing.battery = nil
  var idle = missing
  idle.cpu = 0
  idle.gpu = 0
  idle.memory = 0
  idle.diskRead = 0
  idle.diskWrite = 0
  idle.download = 0
  idle.upload = 0
  idle.battery = 0
  for (module, headline, upperBound) in [
    (Module.cpu, "—", 100.0 as Double?), (.gpu, "—", 100), (.memory, "—", 100),
    (.disks, "Startup volume unavailable", nil), (.network, "↓ —", nil),
    (.battery, "Plugged in", 100),
  ] {
    let result = try #require(
      DetailReadingsBuilder.build(
        module: module, snapshot: snapshot, history: [missing, idle, missing],
        settings: settings, paused: false))
    #expect(result.value == headline)
    #expect(result.upperBound == upperBound)
    #expect(!result.series.isEmpty)
    for series in result.series { #expect(series.values == [nil, 0, nil]) }
    if module == .network {
      #expect(
        result.rows.contains { $0.label == "IPv4 primary route" && $0.value == "Unavailable" })
      #expect(
        result.rows.contains { $0.label == "Public IP" && $0.value == "Off · enable in Settings" })
      #expect(
        result.rows.contains { $0.label == "ICMP ping" && $0.value == "Off · enable in Settings" })
    }
    if module == .gpu {
      #expect(result.rows.contains { $0.value == "Unavailable" })
    }
  }
}

@Test @MainActor func localDetailReadingsKeepValidIdleMetersAndProcessRowLimit() throws {
  var snapshot = Snapshot()
  snapshot.cpu = .init(usage: 0, cores: [nil, 0], load: [])
  snapshot.processes = (1...20).map {
    .init(pid: Int32($0), name: "Fixture", cpu: Double($0), memory: 0, read: nil, written: nil)
  }
  let result = try #require(
    DetailReadingsBuilder.build(
      module: .cpu, snapshot: snapshot, history: [], settings: Settings(), paused: false))
  #expect(result.value == "0%")
  let missing = try #require(result.rows.first { $0.label == "Logical core 1" })
  let idle = try #require(result.rows.first { $0.label == "Logical core 2" })
  #expect(missing.value == "—" && missing.meter?.value == nil)
  #expect(idle.value == "0%" && idle.meter?.value == 0)
  let processes = result.rows.filter { $0.label.hasPrefix("Fixture · ") }
  #expect(processes.count == 7)
  #expect(processes.first?.label == "Fixture · 20")
  #expect(processes.first?.value == "20% of one core" && processes.first?.meter?.value == 10)
}

@Test @MainActor func sidebarActionsKeepModuleShortcutsAndSettingsDemandStable() throws {
  _ = NSApplication.shared
  let detail = DetailController()
  detail.selected = .network
  #expect(!detail.isViewLoaded)
  detail.loadViewIfNeeded()
  let sidebar = try #require(detail.view.subviews.first as? NSVisualEffectView)
  let buttons = sidebar.subviews.compactMap { $0 as? NSButton }
  var selections: [Module] = []
  var demand: [Module?] = []
  detail.onSelect = { selections.append($0) }
  detail.onMonitoringDemand = { demand.append($0) }
  let prefs = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer {
    detail.onSettingsPage = nil
    prefs.disposeEmbedded()
  }
  let content = try #require(prefs.embeddedView(page: .general))
  var pages: [PreferencesController.Page] = []
  detail.onSettingsPage = { page in
    pages.append(page)
    _ = prefs.embeddedView(page: page)
    detail.showSettingsView(content, page: page)
  }
  for title in ["General", "Menu Bar"] {
    let button = try #require(buttons.first { $0.title == title })
    #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    #expect(detail.showsSettings && button.state == .on && !content.isHidden)
    #expect(buttons.filter { $0.state == .on }.count == 1)
    detail.monitoringVisibilityChanged(true)
    detail.update(Snapshot(), history: [])
    #expect(!content.isHidden)
  }
  #expect(pages == [.general, .menuBar] && demand == [nil, nil, nil, nil])
  for (index, module) in Module.allCases.enumerated() {
    let button = try #require(buttons.first { $0.title == module.title })
    #expect(button.keyEquivalent == (index == 9 ? "0" : "\(index + 1)"))
    #expect(button.keyEquivalentModifierMask == [.command])
    #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    #expect(detail.selected == module && !detail.showsSettings && content.isHidden)
    #expect(button.state == .on && buttons.filter { $0.state == .on }.count == 1)
  }
  #expect(selections == Module.allCases)
  #expect(demand.compactMap { $0 } == Module.allCases)
}

@Test @MainActor func closedDetailReleasesCoordinatorWithNativeSidebarRetained() throws {
  _ = NSApplication.shared
  let window = MainWindow()
  var retainedSidebar: NSView?
  weak var controller: DetailController?
  weak var coordinator: DetailNavigationCoordinator?
  weak var root: NSView?
  try autoreleasepool {
    let detail = DetailController()
    controller = detail
    window.contentViewController = detail
    root = detail.view
    let sidebar = try #require(detail.view.subviews.first as? NSVisualEffectView)
    retainedSidebar = sidebar
    let targets = sidebar.subviews.compactMap {
      ($0 as? NSButton)?.target as? DetailNavigationCoordinator
    }
    #expect(!targets.isEmpty)
    coordinator = targets.first
    window.makeKeyAndOrderFront(nil)
    window.close()
  }
  #expect(retainedSidebar != nil)
  #expect(window.contentViewController == nil)
  #expect(controller == nil && root == nil && coordinator == nil)
}

@Test @MainActor func sidebarVisualSectionsKeepEnumAndShortcutOrderIndependent() throws {
  let navigation = DetailNavigationCoordinator()
  for size in [NSSize(width: 700, height: 640), NSSize(width: 884, height: 660)] {
    navigation.layout(in: .init(origin: .zero, size: size))
    let modules = navigation.sidebar.subviews.compactMap { $0 as? NSButton }
      .filter { !$0.keyEquivalent.isEmpty }.sorted { $0.frame.minY > $1.frame.minY }
    #expect(
      modules.map(\.title) == [
        "Overview", "CPU", "GPU", "Memory", "Disks", "Network", "Power", "Time", "Weather",
        "Sensors",
      ])
    let advanced = try #require(
      navigation.sidebar.subviews.compactMap { $0 as? NSTextField }.first {
        $0.stringValue == "ADVANCED"
      })
    let weather = try #require(modules.first { $0.title == "Weather" })
    let sensors = try #require(modules.first { $0.title == "Sensors" })
    let settings = try #require(
      navigation.sidebar.subviews.compactMap { $0 as? NSTextField }.first {
        $0.stringValue == "SETTINGS"
      })
    #expect(advanced.accessibilityLabel() == "ADVANCED")
    #expect(weather.frame.minY > advanced.frame.maxY)
    #expect(advanced.frame.minY > sensors.frame.maxY)
    #expect(sensors.frame.minY > settings.frame.maxY)
    #expect(sensors.keyEquivalent == "7" && sensors.tag == 6)
  }
  #expect(
    Module.allCases == [
      .overview, .cpu, .gpu, .memory, .disks, .network, .sensors, .battery, .clock, .weather,
    ])
}
