import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func descendants(_ root: NSView) -> [NSView] {
  var result = root.subviews
  for child in root.subviews { result.append(contentsOf: descendants(child)) }
  return result
}
@MainActor private func activate(_ control: NSControl) throws {
  let action = try #require(control.action)
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
}
@MainActor private func popup(_ root: NSView, _ name: String) throws -> NSPopUpButton {
  try #require(
    descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == name })
}

@Test @MainActor func generalPrivacyLineDisclosesOptionalInternetRequests() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let tabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
  #expect(tabs.selectedTabViewItem?.identifier as? String == "general")
  let general = try #require(tabs.selectedTabViewItem?.view)
  #expect(
    descendants(general).compactMap { $0 as? NSTextField }.contains {
      $0.stringValue
        == "No account. No analytics. Local only, unless you enable Weather or advanced internet checks."
    })
}

@Test(arguments: [AppTheme.light, .dark]) @MainActor
func generalAdvancedOptionsStartCollapsedAndOnlyRouteExplicitClicks(theme: AppTheme) throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.theme = theme
  #expect(!settings.connectivityChecks && !settings.publicIPChecks && !settings.calendarEvents)
  #expect(!settings.pingCheck.enabled && !settings.weather.enabled)
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [])
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let buttons = descendants(root).compactMap { $0 as? NSButton }
  let disclosure = try #require(
    buttons.first { $0.accessibilityLabel() == "Online & Time advanced" })
  let internet = try #require(buttons.first { $0.accessibilityLabel() == "Internet checks" })
  let calendar = try #require(buttons.first { $0.accessibilityLabel() == "Calendar settings" })
  let formats = try #require(buttons.first { $0.title == "World clock format…" })
  var changes = 0
  var routes: [String] = []
  controller.onChange = { _ in changes += 1 }
  controller.onInternetSettings = { routes.append("internet") }
  controller.onCalendarSettings = { routes.append("calendar") }
  #expect(!disclosure.isAccessibilityExpanded())
  #expect(internet.isHiddenOrHasHiddenAncestor && calendar.isHiddenOrHasHiddenAncestor)
  #expect(!formats.isHiddenOrHasHiddenAncestor)
  disclosure.performClick(nil)
  #expect(disclosure.isAccessibilityExpanded())
  #expect(!internet.isHiddenOrHasHiddenAncestor && !calendar.isHiddenOrHasHiddenAncestor)
  #expect(changes == 0 && routes.isEmpty)
  #expect(
    descendants(root).compactMap { $0 as? NSTextField }.contains {
      $0.stringValue == "Optional · off by default · no requests until you enable"
        && !$0.isHiddenOrHasHiddenAncestor
    })
  internet.performClick(nil)
  calendar.performClick(nil)
  #expect(routes == ["internet", "calendar"] && changes == 0)
  controller.selectPage(.menuBar)
  controller.selectPage(.general)
  #expect(disclosure.isAccessibilityExpanded())
  disclosure.performClick(nil)
  #expect(!disclosure.isAccessibilityExpanded())
  #expect(internet.isHiddenOrHasHiddenAncestor && calendar.isHiddenOrHasHiddenAncestor)
  // A primary local edit still carries the original disabled opt-ins after setup routing.
  var saved: Settings?
  controller.onChange = { saved = $0 }
  let units = try #require(
    descendants(root).compactMap { $0 as? SystemSettingSwitch }.first {
      $0.title == "Use Fahrenheit"
    })
  units.performClick(nil)
  let updated = try #require(saved)
  #expect(!updated.connectivityChecks && !updated.publicIPChecks && !updated.calendarEvents)
  #expect(!updated.pingCheck.enabled && !updated.weather.enabled)
  // Disclosure state belongs to this controller session only.
  disclosure.performClick(nil)
  let reopened = PreferencesController(
    settings: updated, interfaces: [], snapshot: Snapshot(), history: [])
  defer { reopened.close() }
  let nextRoot = try #require(reopened.window?.contentView)
  let nextDisclosure = try #require(
    descendants(nextRoot).compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel() == "Online & Time advanced"
    })
  #expect(!nextDisclosure.isAccessibilityExpanded())
}

@Test @MainActor func settingsTabsApplyStylesImmediatelyWithTheProductionRenderer() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.readouts = [.cpu, .memory]
  var snapshot = Snapshot()
  snapshot.cpu = .init(usage: 18, cores: [18], load: [])
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: snapshot, history: [])
  let root = try #require(controller.window?.contentView)
  let tabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
  #expect(tabs.tabViewItems.map(\.label) == ["General", "Menu Bar"])
  var saved: Settings?
  controller.onChange = { saved = $0 }
  let selector = try #require(root.subviews.compactMap { $0 as? NSSegmentedControl }.first)
  selector.selectedSegment = 1
  try activate(selector)
  #expect(tabs.selectedTabViewItem?.identifier as? String == "menubar")
  let style = try #require(
    descendants(root).compactMap { $0 as? MenuBarStylePicker }.first { $0.module == .cpu })
  style.selectItem(withTitle: MenuBarStyle.historyValue.title)
  try activate(style)
  let size = try popup(root, "CPU menu bar font size")
  size.selectItem(withTitle: MenuBarSize.large.title)
  try activate(size)
  let preview = try #require(descendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
  let renderer = try #require(preview.renderers.first)
  #expect(renderer.readouts.first?.style == .historyValue)
  #expect(renderer.readouts.first?.appearance == .init(size: .large, color: .automatic))
  #expect(saved?.style(for: .cpu) == .historyValue)
  let expected = MenuBarReadoutView()
  let actualSettings = try #require(saved)
  expected.readouts = actualSettings.readouts.prefix(1).map {
    MenuBarReadout.make(module: $0, snapshot: snapshot, settings: actualSettings, history: [])
  }
  #expect(renderer.preferredWidth == expected.preferredWidth)
  #expect(renderer.readouts.first?.value == "18%")
  snapshot.cpu?.usage = 63
  controller.window?.orderFront(nil)
  controller.update(snapshot, history: [])
  #expect(renderer.readouts.first?.value == "63%")
  controller.close()
}

@Test @MainActor func appThemeChangesDoNotOverrideTheActualMenuBarAppearance() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  let root = try #require(controller.window?.contentView)
  let choice = try popup(root, "App appearance")
  choice.selectItem(withTitle: "Dark")
  try activate(choice)
  #expect(controller.window?.appearance?.name == .darkAqua)
  controller.updateMenuBarContext(
    appearance: NSAppearance(named: .aqua), order: [], height: 22, paused: false)
  controller.selectMenuBarTab()
  let preview = try #require(descendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(preview.appearance?.name == .aqua)
  #expect(preview.renderers.first?.bounds.height == 22)
  let selector = try #require(root.subviews.compactMap { $0 as? NSSegmentedControl }.first)
  selector.selectedSegment = 0
  try activate(selector)
  choice.selectItem(withTitle: "Light")
  try activate(choice)
  #expect(controller.window?.appearance?.name == .aqua)
  choice.selectItem(withTitle: "System")
  try activate(choice)
  #expect(controller.window?.appearance == nil)
}

@Test @MainActor func individualPreviewMatchesLiveOrderPaddingAndPausedItems() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.separateItems = true
  settings.readouts = [.cpu, .network]
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [])
  controller.selectMenuBarTab()
  controller.updateMenuBarContext(
    appearance: nil, order: [.network, .cpu], height: 24, paused: true)
  let root = try #require(controller.window?.contentView)
  let preview = try #require(descendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(preview.renderers.count == 2)
  #expect(preview.renderers[0].readouts.first?.label == "NET")
  #expect(
    preview.renderers.allSatisfy { $0.paused && $0.readouts.count == 1 && $0.bounds.height == 24 })
  #expect(preview.preferredWidth == preview.renderers.reduce(0) { $0 + $1.preferredWidth })
  #expect(preview.renderers[1].frame.minX == preview.renderers[0].frame.maxX)
  controller.updateMenuBarContext(appearance: nil, order: [.cpu, .cpu], height: 24, paused: false)
  #expect(preview.renderers[0].readouts.first?.label == "CPU")
  #expect(preview.renderers.allSatisfy { !$0.paused })
}

@Test @MainActor func settingsGalleryUsesNativeDarkControlsAndLiveRendererFixtures() throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SETTINGS_GALLERY"] else { return }
  _ = NSApplication.shared
  var settings = Settings()
  settings.theme = .dark
  settings.readouts = [.sensors, .network, .disks, .cpu, .memory]
  var snapshot = Snapshot()
  snapshot.cpu = .init(usage: 18, cores: [18], load: [])
  snapshot.sensors = [.init(key: "Tp01", name: "CPU · Tp01", kind: .temperature, value: 52)]
  snapshot.selectedInterface = "en0"
  snapshot.download = 93000
  snapshot.upload = 3_100_000
  snapshot.interfaces = [
    .init(
      name: "en0", address: "", up: true, received: 0, sent: 0, download: 93000, upload: 3_100_000)
  ]
  snapshot.volumes = [.init(name: "Example SSD", path: "/", total: 100, available: 27)]
  snapshot.memory = .init(
    total: 100, active: 47, inactive: 0, wired: 0, compressed: 0, free: 53, speculative: 0,
    purgeable: 0, swapUsed: 0, swapTotal: 0, pressure: 1)
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: snapshot, history: [])
  controller.selectMenuBarTab()
  controller.updateMenuBarContext(
    appearance: NSAppearance(named: .darkAqua), order: [], height: 24, paused: false)
  let root = try #require(controller.window?.contentView)
  let tabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
  let content = try #require(tabs.selectedTabViewItem?.view)
  let canvas = SettingsGalleryBackground(frame: content.bounds)
  canvas.appearance = NSAppearance(named: .darkAqua)
  controller.window?.contentView = canvas
  content.frame.origin = .zero
  canvas.addSubview(content)
  controller.window?.displayIfNeeded()
  let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
  canvas.cacheDisplay(in: canvas.bounds, to: rep)
  try #require(rep.representation(using: .png, properties: [:])).write(
    to: URL(fileURLWithPath: path))
}

@MainActor private final class SettingsGalleryBackground: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

@Test @MainActor func generalEditsPreserveUnbuiltMenuBarChoicesAndUseLatestValuesOnFirstVisit()
  throws
{
  _ = NSApplication.shared
  var settings = Settings()
  settings.readouts = [.network, .sensors, .clock]
  settings.separateItems = true
  settings.styles = ["network": .historyValue, "sensors": .history]
  settings.appearances = ["clock": .init(size: .large, color: .purple)]
  settings.sensorKey = "PSTR"
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [])
  let root = try #require(controller.window?.contentView)
  let ownedTabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
  #expect(ownedTabs.tabViewItem(at: 1).view?.subviews.isEmpty == true)
  #expect(!descendants(root).contains { $0 is MenuBarPreviewView })
  #expect(
    !descendants(root).compactMap { $0 as? MenuBarStylePicker }.contains {
      $0.accessibilityLabel() == "CPU menu bar style"
    })
  var saved: Settings?
  controller.onChange = { saved = $0 }
  let fahrenheit = try #require(
    descendants(root).compactMap { $0 as? SystemSettingSwitch }.first {
      $0.title == "Use Fahrenheit"
    })
  fahrenheit.state = .on
  try activate(fahrenheit)
  let result = try #require(saved)
  #expect(result.fahrenheit && result.readouts == settings.readouts && result.separateItems)
  #expect(
    result.styles == settings.styles && result.appearances == settings.appearances
      && result.sensorKey == "PSTR")
  var latest = Snapshot()
  latest.upload = 3_100_000
  latest.download = 93_000
  controller.update(latest, history: [])
  controller.updateMenuBarContext(
    appearance: NSAppearance(named: .aqua), order: [.clock, .sensors, .network], height: 24,
    paused: true)
  controller.selectMenuBarTab()
  let preview = try #require(descendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(
    preview.renderers.count == 3
      && preview.renderers.allSatisfy { $0.paused && $0.bounds.height == 24 })
  #expect(preview.renderers.last?.readouts.first?.value == "↑ 3.1 MB/s")
  #expect(try popup(root, "Time menu bar font size").titleOfSelectedItem == "Large")
  #expect(
    !descendants(root).compactMap { $0 as? NSPopUpButton }.contains {
      $0.accessibilityLabel()?.contains("menu bar color") == true
    })
}

@Test @MainActor func menuBarFirstEditsKeepGeneralValuesUntilGeneralIsConstructed() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.interval = 10
  settings.fahrenheit = true
  settings.networkInterface = "en9"
  settings.theme = .dark
  settings.monitorStorageHealth = true
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  let root = try #require(controller.window?.contentView)
  let ownedTabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
  #expect(ownedTabs.tabViewItem(at: 0).view?.subviews.isEmpty == true)
  #expect(
    !descendants(root).compactMap { $0 as? NSPopUpButton }.contains {
      $0.accessibilityLabel() == "App appearance"
    })
  var saved: Settings?
  controller.onChange = { saved = $0 }
  let style = try #require(
    descendants(root).compactMap { $0 as? MenuBarStylePicker }.first { $0.module == .cpu })
  style.selectItem(withTitle: MenuBarStyle.historyValue.title)
  try activate(style)
  #expect(saved?.interval == 10 && saved?.fahrenheit == true && saved?.networkInterface == "en9")
  #expect(saved?.theme == .dark && saved?.monitorStorageHealth == true)
  let tabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
  tabs.selectTabViewItem(withIdentifier: "general")
  #expect(try popup(root, "App appearance").titleOfSelectedItem == "Dark")
  #expect(try popup(root, "Sampling interval").titleOfSelectedItem == "10 seconds")
  #expect(try popup(root, "Network interface").titleOfSelectedItem == "en9")
}

@Test @MainActor
func revisitingSettingsTabsPreservesDraftsAndRefreshesTheHiddenPreviewOnlyOnReturn() throws {
  _ = NSApplication.shared
  var snapshot = Snapshot()
  snapshot.cpu = .init(usage: 18, cores: [18], load: [])
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: snapshot, history: [], initialPage: .menuBar)
  let root = try #require(controller.window?.contentView)
  let tabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
  let preview = try #require(descendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
  let renderer = try #require(preview.renderers.first)
  tabs.selectTabViewItem(withIdentifier: "general")
  let clocks = try #require(
    descendants(root).compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "World clock time zones"
    })
  clocks.stringValue = "UTC, Europe/Paris"
  var saves = 0
  controller.onChange = { _ in saves += 1 }
  snapshot.cpu?.usage = 63
  controller.update(snapshot, history: [])
  controller.updateMenuBarContext(appearance: nil, order: [], height: 22, paused: true)
  #expect(renderer.readouts.first?.value == "18%" && !renderer.paused)
  controller.selectMenuBarTab()
  #expect(
    renderer.readouts.first?.value == "63%" && renderer.paused && renderer.bounds.height == 22)
  tabs.selectTabViewItem(withIdentifier: "general")
  #expect(clocks.stringValue == "UTC, Europe/Paris" && saves == 0)
  let menuPage = try #require(tabs.tabViewItem(at: 1).view)
  #expect(
    descendants(menuPage).compactMap { $0 as? MenuBarStylePicker }.filter {
      $0.accessibilityLabel() == "CPU menu bar style"
    }.count == 1)
  controller.tabView(tabs, willSelect: nil)
}
