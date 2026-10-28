import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test func historySavingDefaultsOnAndPreservesExplicitAndMalformedOff() throws {
  #expect(Settings().persistHistory)
  for json in ["{}", "{\"persistHistory\":true}"] {
    #expect(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).persistHistory)
  }
  for json in [
    "{\"persistHistory\":false}", "{\"persistHistory\":\"bad\"}", "{\"persistHistory\":null}",
  ] {
    #expect(try !JSONDecoder().decode(Settings.self, from: Data(json.utf8)).persistHistory)
  }
}

@Test func memoryCompositionCannotOverlapOrOverflow() {
  for total: UInt64 in [0, 1, 100, UInt64.max] {
    for active: UInt64 in [0, 20, UInt64.max] {
      let memory = MemoryReading(
        total: total, active: active, inactive: .max, wired: 30,
        compressed: 40, free: .max, speculative: .max, purgeable: 10, swapUsed: 0, swapTotal: 0,
        pressure: 0)
      let c = memory.composition
      #expect(c.app + c.wired + c.compressed + c.available == total)
      #expect(memory.used == c.app + c.wired + c.compressed)
      #expect(memory.pressureDescription == "Unavailable")
    }
  }
}

@Test @MainActor func mainSettingsPagesShareNavigationAndReleaseHostedContent() throws {
  _ = NSApplication.shared
  let detail = DetailController()
  detail.loadViewIfNeeded()
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  let window = MainWindow()
  window.isReleasedWhenClosed = false
  window.contentViewController = detail
  defer { window.close() }
  var demand: [Module?] = []
  detail.onMonitoringDemand = { demand.append($0) }
  detail.selected = .network
  weak var root: NSView?
  try autoreleasepool {
    let content = try #require(controller.embeddedView(page: .general))
    root = content
    detail.showSettingsView(content, page: .general)
    #expect(window.contentView?.bounds.width == 884)
    #expect(content.window === window)
    #expect(controller.window?.contentView == nil)
    let menuContent = try #require(controller.embeddedView(page: .menuBar))
    #expect(menuContent === content)
    detail.showSettingsView(menuContent, page: .menuBar)
    detail.update(Snapshot(), history: [])
    #expect(!content.isHidden)
    detail.selected = .cpu
    #expect(content.isHidden && window.contentView?.bounds.width == 884)
    #expect(demand == [.network, nil, nil, .cpu])
    controller.disposeEmbedded()
  }
  // Detail must not retain a detached settings subtree.
  #expect(root == nil || (root?.superview == nil && root?.subviews.isEmpty == true))
}

@Test @MainActor func coolingStaysWithItsComponentWithoutGuessingFanNumbers() throws {
  var snapshot = Snapshot()
  snapshot.sensors = [
    .init(key: "F0Ac", name: "CPU Fan", kind: .fan, value: 1200),
    .init(key: "F1Ac", name: "GPU Fan", kind: .fan, value: 1400),
    .init(key: "F2Ac", name: "Fan 3", kind: .fan, value: 1500),
    .init(key: "F3Ac", name: "CPU/GPU shared fan", kind: .fan, value: 1700),
    .init(key: "PCPC", name: "CPU package power", kind: .power, value: 12),
  ]
  #expect(snapshot.sensors[3].fanOwner == nil)
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  for (module, expected, excluded) in [
    (Module.cpu, "CPU Fan", "GPU Fan"), (.gpu, "GPU Fan", "CPU Fan"),
  ] {
    view.update(snapshot, history: [], settings: Settings(), module: module)
    let card = try #require(view.cards.first { $0.title.contains("COOLING") })
    #expect(card.spoken.contains(expected) && card.spoken.contains("Fan 3"))
    #expect(!card.spoken.contains(excluded))
    #expect(card.spoken.contains("Shared / unassigned"))
    if module == .cpu { #expect(!view.cards.contains { $0.title == "GPU" }) }
  }
  view.update(snapshot, history: [], settings: Settings(), module: .battery)
  #expect(Module.battery.title == "Power" && Module.battery.rawValue == "battery")
  #expect(view.cards.contains { $0.spoken.contains("CPU package power") })
}

@Test @MainActor func populatedAccessoryBatteriesHaveRoomToDraw() throws {
  var snapshot = Snapshot()
  snapshot.peripherals = [
    .init(name: "Fixture keyboard", percent: 72), .init(name: "Fixture mouse", percent: 0),
  ]
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(snapshot, history: [], settings: Settings(), module: .battery)
  let card = try #require(view.cards.first { $0.title == "ACCESSORY BATTERIES" })
  #expect(card.frame.height - 37 - 17 - 18 > 12)
  #expect(
    card.spoken.contains("Fixture keyboard: 72%") && card.spoken.contains("Fixture mouse: 0%"))
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    view.appearance = NSAppearance(named: appearance)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide > 0)
  }
}

@Test @MainActor func embeddedSensorPickerTracksDiscoveryAndRefreshesOnReturn() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  let content = try #require(controller.embeddedView(page: .menuBar))
  let host = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 740, height: 660), styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  host.isReleasedWhenClosed = false
  host.contentView = content
  host.makeKeyAndOrderFront(nil)
  defer {
    controller.disposeEmbedded()
    host.close()
  }
  func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
  let picker = try #require(
    descendants(content).compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "Menu bar sensor"
    })
  var snapshot = Snapshot()
  snapshot.sensors = [.init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 50)]
  controller.update(snapshot, history: [])
  #expect(picker.itemTitles.contains { $0.contains("CPU proximity") })
  content.isHidden = true
  snapshot.sensors = [.init(key: "TG0P", name: "GPU fixture", kind: .temperature, value: 60)]
  controller.update(snapshot, history: [])
  content.isHidden = false
  _ = controller.embeddedView(page: .menuBar)
  #expect(picker.itemTitles.contains { $0.contains("GPU fixture") })
  #expect(!picker.itemTitles.contains { $0.contains("CPU proximity") })
}

@Test @MainActor func powerSummaryPrioritizesUsefulReadingsAndDisclosesTruncation() throws {
  var snapshot = Snapshot()
  snapshot.batteries = [
    .init(
      name: "Fixture", percent: 60, charging: false, externalPower: false, minutesRemaining: nil,
      cycles: nil, health: nil, watts: nil)
  ]
  snapshot.peripherals = [.init(name: "Fixture keyboard", percent: 80)]
  snapshot.sensors = (0..<8).map {
    .init(key: "P\($0)XX", name: "P\($0)XX", kind: .power, value: Double($0))
  }
  snapshot.sensors += [
    .init(key: "ioreport:gpu", name: "GPU model power", kind: .power, value: 4),
    .init(key: "ioreport:cpu", name: "CPU model power", kind: .power, value: 6),
    .init(key: "PSTR", name: "System total power", kind: .power, value: 20),
  ]
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(snapshot, history: [], settings: Settings(), module: .battery)
  let power = try #require(view.cards.first { $0.title == "POWER CONSUMPTION" })
  #expect(
    power.spoken.contains("System total power") && power.spoken.contains("CPU model power")
      && power.spoken.contains("GPU model power"))
  #expect(
    power.note.contains("Showing 3 of 11 power sensors") && power.note.contains("All readings"))
  snapshot.batteries = []
  view.update(snapshot, history: [], settings: Settings(), module: .battery)
  #expect(view.cards.first?.frame.height == 54)
}

@Test @MainActor func generalHistoryControlUsesDedicatedActionAndMirrorsBusyState() throws {
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
  let keep = try #require(
    descendants(root).compactMap { $0 as? NSButton }.first {
      $0.title == "Keep history between launches"
    })
  var changes: [Bool] = []
  controller.onHistoryPersistence = { changes.append($0) }
  controller.onChange = { _ in
    Issue.record("History changes must not use generic/stale settings drafts")
  }
  #expect(keep.state == .on && keep.isEnabled)
  keep.performClick(nil)
  #expect(changes == [false])
  controller.updateHistoryPersistence(false)
  controller.setHistoryStorageBusy(true)
  #expect(keep.state == .off && !keep.isEnabled)
  NSApp.sendAction(keep.action!, to: keep.target, from: keep)
  #expect(changes == [false] && keep.state == .off)
  controller.updateHistoryPersistence(true)
  controller.setHistoryStorageBusy(false)
  #expect(keep.state == .on && keep.isEnabled)
}

@Test @MainActor func laptopPowerWithAccessoriesKeepsEveryWattValueDrawable() throws {
  var snapshot = Snapshot()
  snapshot.batteries = [
    .init(
      name: "Fixture", percent: 60, charging: false, externalPower: false, minutesRemaining: 120,
      cycles: 50, health: 97, watts: -12)
  ]
  snapshot.peripherals = [
    .init(name: "Fixture keyboard", percent: 80), .init(name: "Fixture mouse", percent: 30),
  ]
  snapshot.sensors = [
    .init(key: "PSTR", name: "System total power", kind: .power, value: 20),
    .init(key: "ioreport:cpu", name: "CPU model power", kind: .power, value: 6),
    .init(key: "ioreport:gpu", name: "GPU model power", kind: .power, value: 4),
    .init(key: "ioreport:dram", name: "Memory model power", kind: .power, value: 2),
  ]
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(snapshot, history: [], settings: Settings(), module: .battery)
  let power = try #require(view.cards.first { $0.title == "POWER CONSUMPTION" })
  guard case .rows(let rows) = power.content else {
    Issue.record("Compact laptop watt values need full-height rows")
    return
  }
  #expect(rows.count == 4 && (power.frame.height - 54) / CGFloat(rows.count) >= 14)
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    view.appearance = NSAppearance(named: appearance)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    if let folder = ProcessInfo.processInfo.environment["TINYSTATS_POWER_GALLERY"] {
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: folder).appendingPathComponent(
          "laptop-power-\(appearance.rawValue).png"))
    }
  }
}

@Test @MainActor func largeTileValuesAndSubtitlesNeverOverlap() {
  for height: CGFloat in [38, 46, 50, 58, 65, 80, 106, 260] {
    let layout = SummaryDashboardView.TileTextLayout(height: height)
    #expect(layout.valueHeight >= 14)
    if let detailY = layout.detailY {
      #expect(detailY >= layout.valueY + layout.valueHeight + 2)
      #expect(detailY + 12 <= height - 4)
    }
  }
}

@Test @MainActor func initialProcessStatesDoNotContradictTheirCollectionMessage() {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  for module in [Module.cpu, .memory, .network] {
    view.update(Snapshot(), history: [], settings: Settings(), module: module)
    let text = view.cards.map(\.spoken).joined(separator: " ")
    #expect(text.contains("No process readings yet") || text.contains("Collecting"))
    #expect(!text.contains("Open Network details"))
  }
}

@Test @MainActor func newlyOpenedDetailUsesCachedHistoryBeforeNextSample() throws {
  var snapshot = Snapshot()
  snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_004)
  let history = [10.0, 20, 30].enumerated().map { index, value in
    var point = snapshot.historyPoint
    point.time = snapshot.timestamp.addingTimeInterval(Double(index - 2) * 2)
    point.cpu = value
    point.cpuUser = value
    point.cpuSystem = 0
    point.sampleInterval = 2
    return point
  }
  let detail = DetailController(snapshot: snapshot, history: history)
  #expect(!detail.isViewLoaded)
  detail.loadViewIfNeeded()
  let settings = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: snapshot, history: history)
  defer { settings.disposeEmbedded() }
  let settingsView = try #require(settings.embeddedView(page: .general))
  detail.showSettingsView(settingsView, page: .general)
  detail.selected = .cpu
  func summaries(_ view: NSView) -> [SummaryDashboardView] {
    (view as? SummaryDashboardView).map { [$0] } ?? view.subviews.flatMap(summaries)
  }
  let dashboard = try #require(summaries(detail.view).first)
  let plot = try #require(
    dashboard.cards.compactMap { card -> SummaryDashboardView.Plot? in
      if case .plot(let plot) = card.content { return plot }
      return nil
    }.first)
  #expect(plot.times == history.map(\.time) && plot.first == [10, 20, 30])
}

@Test @MainActor func pingOnlyFooterDescribesNetworkChecksWithoutClaimingInternetTraffic() {
  let detail = DetailController(snapshot: Snapshot(), history: [])
  var settings = Settings()
  settings.weather.enabled = false
  settings.pingCheck = .init(enabled: true, destination: "127.0.0.1")
  detail.settings = settings
  detail.loadViewIfNeeded()
  detail.selected = .network
  func strings(_ view: NSView) -> [String] {
    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(strings)
  }
  #expect(strings(detail.view).contains { $0.hasPrefix("Network checks enabled") })
  #expect(!strings(detail.view).contains { $0.hasPrefix("Internet requests enabled") })
  settings.pingCheck.enabled = false
  detail.settings = settings
  detail.update(Snapshot(), history: [])
  #expect(strings(detail.view).contains { $0.hasPrefix("Local only") })
}
