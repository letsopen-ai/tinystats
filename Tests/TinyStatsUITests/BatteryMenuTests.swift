import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func batteryViews(_ root: NSView) -> [NSView] {
  var result = root.subviews
  for child in root.subviews { result.append(contentsOf: batteryViews(child)) }
  return result
}
@MainActor private func batteryPopup(_ root: NSView, _ name: String) throws -> NSPopUpButton {
  try #require(
    batteryViews(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == name }
  )
}
@MainActor private func batteryAction(_ control: NSControl) throws {
  let action = try #require(control.action)
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
}
private func menuBattery(external: Bool = false, charging: Bool = false, charged: Bool? = nil)
  -> BatteryReading
{
  .init(
    name: "Fixture", percent: 72, charging: charging, externalPower: external,
    minutesRemaining: 250, cycles: nil, health: nil, watts: -8.4, fullyCharged: charged)
}

@Test @MainActor func batteryRendererUsesCurrentStateTextAndStyleWithoutChangingPercentageHistory()
{
  var settings = Settings()
  settings.batteryMenu.customizeStates = true
  settings.batteryMenu.draining = .init(format: .power, style: .historyValue)
  settings.batteryMenu.charging = .init(format: .time, style: .value)
  var snapshot = Snapshot()
  snapshot.batteries = [menuBattery()]
  var point = snapshot.historyPoint
  point.battery = 65
  let drain = MenuBarReadout.make(
    module: .battery, snapshot: snapshot, settings: settings, history: [point])
  #expect(drain.style == .historyValue && drain.value == "-8.4 W")
  #expect(drain.values == [65] && drain.progress == 72 && !drain.charging)
  snapshot.batteries = [menuBattery(external: true, charging: true)]
  let charge = MenuBarReadout.make(
    module: .battery, snapshot: snapshot, settings: settings, history: [point])
  #expect(charge.style == .value && charge.value == "4:10" && charge.charging)
  settings.batteryMenu.charging = .init(format: .time, style: .horizontal)
  let gauge = MenuBarReadout.make(
    module: .battery, snapshot: snapshot, settings: settings, history: [])
  #expect(gauge.style == .horizontal && gauge.label == "BAT" && gauge.progress == 72)
  snapshot.batteries = []
  settings.styles["battery"] = .ring
  let absent = MenuBarReadout.make(
    module: .battery, snapshot: snapshot, settings: settings, history: [])
  #expect(absent.style == .ring && absent.progress == nil && absent.value == "AC")
}

@Test @MainActor
func batteryFormatEditorPreviewsExamplesWithoutSavingFakeReadingsOrEnablingReadouts() throws {
  var settings = Settings()
  settings.theme = .dark
  var snapshot = Snapshot()
  snapshot.batteries = [menuBattery()]
  let editor = BatteryMenuController(settings: settings, snapshot: snapshot, history: [])
  defer { editor.close() }
  editor.updateMenuBarContext(appearance: NSAppearance(named: .aqua), height: 22, paused: true)
  editor.showWindow(nil)
  let root = try #require(editor.window?.contentView)
  let preview = try #require(batteryViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(editor.window?.appearance?.name == .darkAqua && preview.appearance?.name == .aqua)
  var saved: [BatteryMenuSettings] = []
  editor.onChange = { saved.append($0) }
  let format = try batteryPopup(root, "Default battery menu bar format")
  format.selectItem(withTitle: BatteryMenuFormat.time.title)
  try batteryAction(format)
  #expect(saved.last?.format == .time)
  #expect(preview.renderers.first?.readouts.first?.value == "4:10")
  let source = try batteryPopup(root, "Battery preview source")
  source.selectItem(at: 2)
  try batteryAction(source)
  #expect(saved.count == 1)
  #expect(preview.renderers.first?.readouts.first?.value == "1:05")
  #expect(preview.renderers.first?.paused == false)
  #expect(
    batteryViews(root).compactMap { $0 as? NSTextField }.contains {
      $0.stringValue.contains("Example · Charging") && $0.stringValue.contains("Preview only")
    })
  source.selectItem(at: 0)
  try batteryAction(source)
  #expect(preview.renderers.first?.readouts.first?.value == "4:10")
  #expect(preview.renderers.first?.paused == true)
  #expect(saved.count == 1 && settings.readouts == [.cpu, .memory, .network])
}

@Test @MainActor func batteryEditorStateChangesReachTheParentPreviewAndPreserveUnrelatedSettings()
  throws
{
  var settings = Settings()
  settings.readouts = [.battery]
  settings.worldClockNames = ["UTC": "Build server"]
  var snapshot = Snapshot()
  snapshot.batteries = [menuBattery()]
  let parent = PreferencesController(
    settings: settings, interfaces: [], snapshot: snapshot, history: [], initialPage: .menuBar)
  defer { parent.close() }
  let root = try #require(parent.window?.contentView)
  let button = try #require(
    batteryViews(root).compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel() == "Battery menu bar formats"
    })
  var saved: Settings?
  parent.onChange = { saved = $0 }
  try batteryAction(button)
  let window = try #require(
    NSApp.windows.first { $0.title == "Battery Menu Bar Format" && $0.isVisible })
  let editorRoot = try #require(window.contentView)
  let customize = try #require(
    batteryViews(editorRoot).compactMap { $0 as? SystemSettingSwitch }.first {
      $0.title == "Use different displays for each power state"
    })
  customize.state = .on
  try batteryAction(customize)
  let chargedFormat = try batteryPopup(editorRoot, "Charged battery format")
  #expect(!chargedFormat.isEnabled)
  let chargedStyle = try batteryPopup(editorRoot, "Charged battery style")
  chargedStyle.selectItem(withTitle: MenuBarStyle.value.title)
  try batteryAction(chargedStyle)
  #expect(chargedFormat.isEnabled)
  let format = try batteryPopup(editorRoot, "On battery battery format")
  format.selectItem(withTitle: BatteryMenuFormat.time.title)
  try batteryAction(format)
  let style = try batteryPopup(editorRoot, "On battery battery style")
  style.selectItem(withTitle: MenuBarStyle.value.title)
  try batteryAction(style)
  #expect(saved?.batteryMenu.draining == .init(format: .time, style: .value))
  #expect(saved?.worldClockNames["UTC"] == "Build server" && saved?.readouts == [.battery])
  #expect(!((saved?.alerts) ?? true) && !((saved?.calendarEvents) ?? true))
  let renderer = try #require(
    batteryViews(root).compactMap { $0 as? MenuBarPreviewView }.first?.renderers.first)
  #expect(renderer.readouts.first?.style == .value && renderer.readouts.first?.value == "4:10")
  #expect(try !batteryPopup(root, "Power menu bar style").isEnabled)
  customize.state = .off
  try batteryAction(customize)
  #expect(try batteryPopup(root, "Power menu bar style").isEnabled)
  #expect(renderer.readouts.first?.style == .stacked && renderer.readouts.first?.value == "72%")
  parent.close()
  #expect(!window.isVisible)
}
