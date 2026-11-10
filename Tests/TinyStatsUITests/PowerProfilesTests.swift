import AppKit
import ScreenCaptureKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

// Every privileged/side-effecting path is a fake here: no pmset write, no authorization
// prompt, no System Settings launch, no real status item or menu-bar click.

final class FakeEnergyReader: EnergyModeReader, @unchecked Sendable {
  private let lock = NSLock()
  private var value: EnergyModeReading
  private var reads = 0
  init(_ value: EnergyModeReading) { self.value = value }
  var count: Int { lock.withLock { reads } }
  func set(_ next: EnergyModeReading) { lock.withLock { value = next } }
  func read() -> EnergyModeReading {
    lock.withLock {
      reads += 1
      return value
    }
  }
}

@MainActor final class FakeEnergyApplier: EnergyModeApplying {
  private(set) var calls: [[String]] = []
  private var completions: [@MainActor (EnergyModeApplyResult) -> Void] = []
  func apply(
    arguments: [String], completion: @escaping @MainActor (EnergyModeApplyResult) -> Void
  ) {
    calls.append(arguments)
    completions.append(completion)
  }
  func finish(_ result: EnergyModeApplyResult) {
    guard !completions.isEmpty else { return }
    completions.removeFirst()(result)
  }
}

let laptopStatus = EnergyModeStatus(
  layout: .unified, sources: [.adapter, .battery], modes: [.adapter: .high, .battery: .low])
let laptopNoHighStatus = EnergyModeStatus(
  layout: .lowPowerOnly, sources: [.adapter, .battery],
  modes: [.adapter: .automatic, .battery: .low])
let desktopStatus = EnergyModeStatus(
  layout: .lowPowerOnly, sources: [.adapter], modes: [.adapter: .automatic])

@MainActor private func settle(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() { await Task.yield() }
}

@MainActor private func makeController(
  _ reading: EnergyModeReading, opened: @escaping (URL) -> Void = { _ in }
) -> (EnergyModeController, FakeEnergyReader, FakeEnergyApplier) {
  let reader = FakeEnergyReader(reading)
  let applier = FakeEnergyApplier()
  let controller = EnergyModeController(
    reader: reader, applier: applier, schedule: { $0() }, openURL: opened, uptime: { 100 })
  return (controller, reader, applier)
}

private func battery(external: Bool, percent: Double = 76) -> BatteryReading {
  .init(
    name: "InternalBattery-0", percent: percent, charging: false, externalPower: external,
    minutesRemaining: external ? nil : 312, cycles: 141, health: 96, watts: external ? 0 : -6.2,
    fullyCharged: false)
}

@MainActor private func descendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + descendants($0) }
}

// MARK: - Applier and reader

@Test func administratorApplierBuildsOnlyWhitelistedFixedScripts() {
  #expect(
    AdministratorEnergyModeApplier.script(for: ["-c", "powermode", "2"])
      == #"do shell script "/usr/bin/pmset -c powermode 2" with administrator privileges"#)
  #expect(
    AdministratorEnergyModeApplier.script(for: ["-b", "lowpowermode", "1"])
      == #"do shell script "/usr/bin/pmset -b lowpowermode 1" with administrator privileges"#)
  #expect(AdministratorEnergyModeApplier.script(for: ["-c", "powermode", "2\" & \"x"]) == nil)
  #expect(AdministratorEnergyModeApplier.script(for: ["-a", "powermode", "2"]) == nil)
  #expect(AdministratorEnergyModeApplier.script(for: ["-c", "displaysleep", "1"]) == nil)
  #expect(AdministratorEnergyModeApplier.result(nil) == .failed)
  #expect(
    AdministratorEnergyModeApplier.result(.init(status: 0, stdout: "", stderr: "")) == .applied)
  #expect(
    AdministratorEnergyModeApplier.result(
      .init(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)")) == .cancelled)
  #expect(
    AdministratorEnergyModeApplier.result(.init(status: 1, stdout: "", stderr: "boom (-60005)"))
      == .failed)
}

@Test func pmsetReaderUsesOnlyReadOnlyQueriesAndFailsToUnavailable() {
  final class Calls: @unchecked Sendable {
    let lock = NSLock()
    var value: [[String]] = []
  }
  let calls = Calls()
  let reader = PMSetEnergyModeReader(run: { executable, arguments in
    calls.lock.withLock { calls.value.append([executable] + arguments) }
    return .init(
      status: 0, stdout: arguments == ["-g", "custom"] ? macMiniFixture : " lowpowermode\n",
      stderr: "")
  })
  #expect(
    reader.read()
      == .available(
        .init(layout: .lowPowerOnly, sources: [.adapter], modes: [.adapter: .automatic])))
  #expect(calls.value == [["/usr/bin/pmset", "-g", "custom"], ["/usr/bin/pmset", "-g", "cap"]])
  #expect(calls.value.allSatisfy { $0[1] == "-g" })
  #expect(PMSetEnergyModeReader(run: { _, _ in nil }).read() == .unavailable)
  #expect(
    PMSetEnergyModeReader(run: { _, _ in .init(status: 1, stdout: "", stderr: "") }).read()
      == .unavailable)
}

private let macMiniFixture = "AC Power:\n lowpowermode         0\n sleep 0\n"

// MARK: - Controller flow

@Test @MainActor func energyControllerNeverReadsOrAppliesUntilAskedAndAppliesExactVectors() async {
  let (controller, reader, applier) = makeController(.available(laptopStatus))
  #expect(reader.count == 0 && applier.calls.isEmpty)
  #expect(controller.presentation(currentSource: .adapter) == .hidden)
  controller.refresh()
  await settle { controller.reading != nil }
  #expect(reader.count == 1)
  let shown = controller.presentation(currentSource: .battery)
  #expect(shown.rows.map(\.source) == [.adapter, .battery])
  #expect(shown.rows.map(\.selected) == [.high, .low])
  #expect(shown.rows.map(\.isCurrentSource) == [false, true])
  #expect(shown.rows.allSatisfy { $0.modes == [.low, .automatic, .high] })
  #expect(applier.calls.isEmpty, "rendering/reading never applies")
  controller.select(.automatic, for: .battery)
  #expect(applier.calls == [["-b", "powermode", "0"]])
  let pending = controller.presentation(currentSource: .battery)
  #expect(pending.busy && pending.rows[1].selected == .automatic)
  // A second click while the prompt is up is ignored.
  controller.select(.high, for: .adapter)
  #expect(applier.calls.count == 1)
  reader.set(
    .available(
      .init(
        layout: .unified, sources: [.adapter, .battery],
        modes: [.adapter: .high, .battery: .automatic])))
  applier.finish(.applied)
  await settle { reader.count == 2 && controller.reading != .available(laptopStatus) }
  let applied = controller.presentation(currentSource: .battery)
  #expect(!applied.busy && applied.rows[1].selected == .automatic && applied.message == nil)
}

@Test @MainActor func energyControllerRevertsAndOffersFallbackOnCancelOrFailure() async {
  var opened: [URL] = []
  let (controller, reader, applier) = makeController(
    .available(laptopNoHighStatus), opened: { opened.append($0) })
  controller.refresh()
  await settle { controller.reading != nil }
  // High is not offered and cannot be requested on Low-Power-only hardware.
  #expect(controller.presentation(currentSource: .adapter).rows[0].modes == [.low, .automatic])
  controller.select(.high, for: .adapter)
  controller.select(.automatic, for: .adapter)  // unchanged: no-op
  #expect(applier.calls.isEmpty)
  for result in [EnergyModeApplyResult.cancelled, .failed] {
    controller.select(.low, for: .adapter)
    #expect(applier.calls.last == ["-c", "lowpowermode", "1"])
    let before = reader.count
    applier.finish(result)
    await settle { reader.count > before && controller.isReading == false }
    let reverted = controller.presentation(currentSource: .adapter)
    #expect(reverted.rows[0].selected == .automatic, "selection reverts to macOS's value")
    #expect(reverted.showsFallback)
    #expect(
      reverted.message
        == (result == .cancelled ? "Energy mode unchanged" : "Couldn't change energy mode"))
  }
  controller.openEnergySettings()
  #expect(opened == [EnergyModeController.settingsURL])
  #expect(
    EnergyModeController.settingsURL.absoluteString
      == "x-apple.systempreferences:com.apple.Battery-Settings.extension")
}

/// Reads run only when the test says so, so ordering races are reproducible.
@MainActor private final class ManualSchedule {
  var jobs: [@Sendable () -> Void] = []
  func run(_ index: Int = 0) { jobs.remove(at: index)() }
}

@Test @MainActor func energyControllerDiscardsReadsThatPredateAChangeAndReconcilesAfterIt() async {
  let reader = FakeEnergyReader(.available(laptopStatus))
  let applier = FakeEnergyApplier()
  let manual = ManualSchedule()
  let controller = EnergyModeController(
    reader: reader, applier: applier, schedule: { manual.jobs.append($0) }, openURL: { _ in },
    uptime: { 100 })
  controller.refresh()
  manual.run()
  await settle { controller.reading != nil }
  // Power reopened: a read is in flight when the person picks a mode.
  controller.refresh()
  #expect(manual.jobs.count == 1)
  controller.select(.automatic, for: .battery)
  #expect(applier.calls == [["-b", "powermode", "0"]])
  // Reopening during the prompt starts no read; the reconcile read after the change counts.
  controller.refresh()
  #expect(manual.jobs.count == 1)
  applier.finish(.applied)
  #expect(manual.jobs.count == 2, "a fresh read always follows a completed change")
  // The pre-change read lands last-but-one with the old value: it must be discarded.
  manual.run(0)
  for _ in 0..<20 { await Task.yield() }
  var shown = controller.presentation(currentSource: .battery)
  #expect(shown.busy, "controls stay busy until the reconciling read lands")
  #expect(shown.rows[1].selected == .automatic)
  #expect(controller.reading == .available(laptopStatus))
  controller.select(.high, for: .battery)
  #expect(applier.calls.count == 1, "no second change while reconciling")
  let changed = EnergyModeStatus(
    layout: .unified, sources: [.adapter, .battery],
    modes: [.adapter: .high, .battery: .automatic])
  reader.set(.available(changed))
  manual.run()
  await settle { controller.reading == .available(changed) }
  shown = controller.presentation(currentSource: .battery)
  #expect(!shown.busy && shown.rows[1].selected == .automatic && shown.message == nil)
  // Choosing Low again is a real change, not swallowed by a stale cache.
  controller.select(.low, for: .battery)
  #expect(applier.calls.last == ["-b", "powermode", "1"])
  // Cancel: the reconcile read is still forced, and the selection reverts meanwhile.
  applier.finish(.cancelled)
  #expect(manual.jobs.count == 1)
  shown = controller.presentation(currentSource: .battery)
  #expect(shown.busy && shown.rows[1].selected == .automatic)
  manual.run()
  await settle { !controller.isBusy }
  #expect(!controller.presentation(currentSource: .battery).busy)
}

@Test @MainActor func energyControllerHidesUnsupportedAndShowsOnlyFallbackWhenUnreadable() async {
  let (unsupported, _, _) = makeController(.unsupported)
  unsupported.refresh()
  await settle { unsupported.reading != nil }
  #expect(!unsupported.presentation(currentSource: .adapter).isVisible)
  let (unreadable, _, _) = makeController(.unavailable)
  unreadable.refresh()
  await settle { unreadable.reading != nil }
  let fallback = unreadable.presentation(currentSource: .adapter)
  #expect(fallback.rows.isEmpty && fallback.showsFallback && fallback.isVisible)
}

// MARK: - Dropdown section

@MainActor private func powerDropdown(
  _ presentation: EnergyModePresentation, batteries: [BatteryReading]
) -> DetailController {
  var snapshot = Snapshot()
  snapshot.batteries = batteries
  snapshot.batteriesSampledAt = snapshot.uptime
  snapshot.sensors = [.init(key: "PSTR", name: "System total power", kind: .power, value: 7.4)]
  let detail = DetailController(snapshot: snapshot, history: [])
  detail.isPopoverPresentation = true
  detail.energyMode = presentation
  detail.selected = .battery
  detail.view.frame = .init(origin: .zero, size: SystemStyle.popoverSize)
  detail.update(snapshot, history: [])
  detail.view.layoutSubtreeIfNeeded()
  return detail
}

@MainActor private func presentation(
  _ status: EnergyModeStatus, current: PowerSourceKind
) async -> EnergyModePresentation {
  let (controller, _, _) = makeController(.available(status))
  controller.refresh()
  await settle { controller.reading != nil }
  return controller.presentation(currentSource: current)
}

@Test @MainActor func dropdownEnergySectionMatchesCapabilitiesAndForwardsOnlyClicks() async throws {
  for (status, batteries, rows, segments) in [
    (laptopStatus, [battery(external: true)], [PowerSourceKind.adapter, .battery], 3),
    (laptopNoHighStatus, [battery(external: false)], [.adapter, .battery], 2),
    (desktopStatus, [], [.adapter], 2),
  ] {
    let value = await presentation(
      status, current: PowerSourceKind.current(batteries))
    let detail = powerDropdown(value, batteries: batteries)
    let control = try #require(detail.energyModeControl)
    #expect(!control.isHidden && control.superview != nil)
    #expect(control.presentation.rows.map(\.source) == rows)
    for source in rows {
      let segmented = try #require(control.segments[source])
      #expect(segmented.segmentCount == segments)
      #expect(segmented.trackingMode == .selectOne)
      for index in 0..<segmented.segmentCount {
        #expect(segmented.toolTip(forSegment: index)?.isEmpty == false)
      }
      #expect(segmented.accessibilityLabel()?.contains("energy mode") == true)
      #expect(segmented.selectedSegmentBezelColor == .controlAccentColor)
    }
    // The only control sits directly under the Battery / Power source header card.
    let titles = try #require(detail.summary).cards.map(\.title)
    #expect(titles.firstIndex(of: SummaryDashboardView.energyModeTitle) == 1)
    let highOffered = control.presentation.rows.allSatisfy { $0.modes.contains(.high) }
    #expect(highOffered == status.supportsHigh)
    #expect(control.presentation.rows.filter(\.isCurrentSource).count == 1)
    var forwarded: [(PowerSourceKind, EnergyMode)] = []
    detail.onEnergyMode = { forwarded.append(($0, $1)) }
    let first = try #require(control.segments[.adapter])
    first.selectedSegment = 0
    _ = first.sendAction(first.action, to: first.target)
    #expect(forwarded.count == 1 && forwarded[0].0 == .adapter && forwarded[0].1 == .low)
  }
  // Other modules and the main window never show it.
  let detail = powerDropdown(await presentation(laptopStatus, current: .adapter), batteries: [])
  detail.selected = .cpu
  detail.update(detail.snapshot, history: [])
  #expect(detail.energyModeControl?.isHidden != false)
}

@Test @MainActor func dropdownFallbackButtonHasTooltipAndOpensSettings() async throws {
  // performClick dispatches through NSApp; without it the click is silently dropped.
  _ = NSApplication.shared
  var opened = 0
  let detail = powerDropdown(
    .init(rows: [], busy: false, message: "Energy mode unavailable", showsFallback: true),
    batteries: [])
  detail.onEnergySettings = { opened += 1 }
  let control = try #require(detail.energyModeControl)
  #expect(control.segments.isEmpty)
  #expect(!control.fallback.isHidden && control.fallback.toolTip?.isEmpty == false)
  control.fallback.performClick(nil)
  #expect(opened == 1)
}

// MARK: - Settings tiles

@Test @MainActor func visibilityTilesExposeLabelsTooltipsAndDesktopState() throws {
  // performClick dispatches through NSApp; without it the click is silently dropped.
  _ = NSApplication.shared
  let picker = PowerVisibilityPicker(visibility: .init(), hasBattery: true)
  picker.frame = .init(x: 0, y: 0, width: 400, height: 80)
  picker.layoutSubtreeIfNeeded()
  for source in PowerSourceKind.allCases {
    let tile = try #require(picker.tile(source))
    #expect(tile.accessibilityLabel() == "Show Power on \(source.title)")
    #expect(tile.toolTip?.isEmpty == false)
    #expect(tile.state == .on && tile.available)
  }
  #expect(picker.caption.isHidden)
  // Its own labelled group; tiles span whole style-grid columns.
  #expect(picker.header.stringValue == "Show in menu bar")
  let tileFrame = try #require(picker.tile(.adapter)).frame
  #expect(tileFrame.minY >= PowerVisibilityPicker.headerHeight)
  let column: CGFloat = (648 - 6 * 8) / 7
  #expect(abs(PowerVisibilityPicker.tileWidth(for: 648) - (column * 2 + 8)) < 0.01)
  var changes = 0
  final class Sink: NSObject {
    var hit: () -> Void = {}
    @objc func changed() { hit() }
  }
  let sink = Sink()
  sink.hit = { changes += 1 }
  picker.target = sink
  picker.action = #selector(Sink.changed)
  try #require(picker.tile(.battery)).performClick(nil)
  #expect(picker.visibility == .init(onAdapter: true, onBattery: false) && changes == 1)
  try #require(picker.tile(.adapter)).performClick(nil)
  #expect(picker.visibility.hidesEverywhere && !picker.caption.isHidden)
  // No battery: the battery tile is dimmed and inert; adapter alone decides "hidden".
  let desktop = PowerVisibilityPicker(visibility: .init(), hasBattery: false)
  let tile = try #require(desktop.tile(.battery))
  #expect(!tile.available && tile.caption == "No Battery")
  #expect(tile.toolTip == "This Mac has no internal battery")
  tile.performClick(nil)
  #expect(desktop.visibility == .init())
  #expect(
    PowerVisibilityPicker.captionText(.init(onAdapter: false, onBattery: true), hasBattery: false)
      != nil)
  #expect(
    PowerVisibilityPicker.captionText(.init(onAdapter: false, onBattery: true), hasBattery: true)
      == nil)
}

@Test @MainActor func settingsPowerEditorSavesVisibilityWithoutDisablingTheModule() throws {
  // performClick dispatches through NSApp; without it the click is silently dropped.
  _ = NSApplication.shared
  var settings = Settings()
  settings.readouts = [.cpu, .battery]
  var snapshot = Snapshot()
  snapshot.batteries = [battery(external: true)]
  let editor = PreferencesController(
    settings: settings, interfaces: [], snapshot: snapshot, history: [], initialPage: .menuBar)
  defer { editor.close() }
  var saved: [Settings] = []
  editor.onChange = { saved.append($0) }
  editor.selectStyleModule(.battery)
  let picker = try #require(editor.powerVisibility)
  #expect(picker.identifier?.rawValue == "menu-bar-battery-visibility")
  #expect(picker.hasBattery)
  try #require(picker.tile(.battery)).performClick(nil)
  let last = try #require(saved.last)
  #expect(last.batteryMenu.visibility == .init(onAdapter: true, onBattery: false))
  #expect(last.readouts == [.cpu, .battery], "hiding by source never disables Power")
}

@Test @MainActor func settingsRetainsBatterySeenAtInitAfterAnEmptyReading() throws {
  var settings = Settings()
  settings.readouts = [.cpu, .battery]
  var snapshot = Snapshot()
  snapshot.batteries = [battery(external: true)]
  let editor = PreferencesController(
    settings: settings, interfaces: [], snapshot: snapshot, history: [], initialPage: .menuBar)
  defer { editor.close() }
  // A failed/empty battery read after init must not flip On Battery to "No Battery".
  editor.update(Snapshot(), history: [])
  editor.selectStyleModule(.battery)
  let picker = try #require(editor.powerVisibility)
  #expect(picker.hasBattery)
  #expect(try #require(picker.tile(.battery)).available)
}

// MARK: - Menu bar visibility, routing and dropdown lifetime

@MainActor private func deliver(_ app: AppDelegate, batteries: [BatteryReading]) {
  var snapshot = Snapshot()
  snapshot.batteries = batteries
  app.receive(snapshot, history: [], alerts: [])
}

@Test(arguments: [false, true])
@MainActor func powerItemHidesOnBatteryRestoresOnAdapterAndClosesItsDropdown(combined: Bool)
  async throws
{
  var settings = Settings()
  settings.readouts = [.cpu, .battery]
  settings.separateItems = !combined
  settings.batteryMenu.visibility = .init(onAdapter: true, onBattery: false)
  let (energy, reader, applier) = makeController(.available(laptopStatus))
  let fixture = try MenuBarRoutingFixture(
    combined: combined, modules: [.cpu, .battery], settings: settings, energyModes: energy)
  defer { fixture.close() }
  let app = try #require(fixture.app)
  deliver(app, batteries: [battery(external: true)])
  #expect(fixture.items.hiddenModules.isEmpty)
  // Open Power: one on-demand unprivileged read, never an apply.
  app.activateStatusButton(
    try fixture.target(.battery).button, event: try fixture.event(.battery, source: 0))
  #expect(app.detail?.selected == .battery && app.popover?.isShown == true)
  app.popover?.animates = false
  await settle { reader.count == 1 && energy.reading != nil }
  #expect(reader.count == 1 && applier.calls.isEmpty)
  #expect(app.detail?.energyMode.rows.first?.isCurrentSource == true)
  // Unplug: the Power item hides and its dropdown closes; the module stays enabled.
  deliver(app, batteries: [battery(external: false)])
  #expect(fixture.items.hiddenModules == [.battery])
  #expect(app.popover?.isShown != true)
  if combined {
    let target = try #require(fixture.items.targets.first)
    #expect(target.readout.segments.compactMap(\.module) == [.cpu])
    #expect(target.module == .cpu)
    // Router: every point in the shared item now selects the remaining module.
    for x in stride(from: 0, through: target.readout.bounds.width, by: 4) {
      #expect(target.readout.module(at: x) != .battery)
    }
  } else {
    #expect(try #require(fixture.statusWindows.last?.contentView?.subviews.first).isHidden)
    #expect(PopoverInteraction.screenRect(of: fixture.items.targets[1].button) == nil)
  }
  // CPU still routes and opens normally while Power is hidden.
  let cpu = try fixture.event(.cpu, source: 1)
  #expect(app.routeStatusEvent(cpu))
  #expect(app.detail?.selected == .cpu && app.popover?.isShown == true)
  app.popover?.animates = false
  app.popover?.close()
  // Plug back in: Power returns without any settings change.
  deliver(app, batteries: [battery(external: true)])
  #expect(fixture.items.hiddenModules.isEmpty)
  if combined {
    #expect(
      try #require(fixture.items.targets.first).readout.segments.compactMap(\.module)
        == [.cpu, .battery])
  } else {
    #expect(try #require(fixture.statusWindows.last?.contentView?.subviews.first).isHidden == false)
  }
  #expect(applier.calls.isEmpty, "no energy-mode change without an explicit click")
}

@Test @MainActor func closingPopoverDiscardsQueuedPowerClickWhenPowerHidesBeforeReplay() throws {
  // Sibling of closingPopoverRetainsClickAndAccountsBeforeReopening: same close-animation
  // queue, but a source change hides Power before didClose. The shared One button stays
  // visible, so only module revalidation can stop the replay.
  var settings = Settings()
  settings.readouts = [.cpu, .battery]
  settings.separateItems = false
  settings.batteryMenu.visibility = .init(onAdapter: true, onBattery: false)
  let (energy, reader, applier) = makeController(.available(laptopStatus))
  let fixture = try MenuBarRoutingFixture(
    combined: true, modules: [.cpu, .battery], settings: settings, energyModes: energy)
  defer { fixture.close() }
  let app = try #require(fixture.app)
  deliver(app, batteries: [battery(external: true)])
  #expect(fixture.items.hiddenModules.isEmpty)
  app.activateStatusButton(try fixture.target(.cpu).button, event: nil)
  let closing = try #require(app.popover)
  closing.animates = false
  #expect(closing.isShown && app.detail?.selected == .cpu)
  app.popoverWillClose(.init(name: NSPopover.willCloseNotification, object: closing))
  let power = try fixture.event(.battery, source: 1)
  #expect(app.popoverInteraction.handle(power) == nil, "queued for didClose")
  #expect(app.detail?.selected == .cpu)
  // Unplug during the close animation: Power hides; the shared button remains on screen.
  deliver(app, batteries: [battery(external: false)])
  #expect(fixture.items.hiddenModules == [.battery])
  let shared = try #require(fixture.items.targets.first)
  #expect(PopoverInteraction.screenRect(of: shared.button) != nil)
  closing.close()
  #expect(app.popover?.isShown != true, "a hidden module's queued click must not reopen")
  #expect(app.detail?.selected != .battery)
  #expect(!app.popoverInteraction.isMonitoring)
  // The visible module still opens normally afterwards.
  app.activateStatusButton(shared.button, event: try fixture.event(.cpu, source: 0))
  #expect(app.popover?.isShown == true && app.detail?.selected == .cpu)
  #expect(reader.count == 0 && applier.calls.isEmpty, "Power never opened, never read/applied")
}

@Test @MainActor func soleHiddenPowerKeyboardActivationOpensOverviewAndStaysOpen() throws {
  var settings = Settings()
  settings.readouts = [.battery]
  settings.separateItems = false
  settings.batteryMenu.visibility = .init(onAdapter: true, onBattery: false)
  let (energy, _, applier) = makeController(.available(laptopStatus))
  let fixture = try MenuBarRoutingFixture(
    combined: true, modules: [.battery], settings: settings, energyModes: energy)
  defer { fixture.close() }
  let app = try #require(fixture.app)
  deliver(app, batteries: [battery(external: false)])
  #expect(fixture.items.hiddenModules == [.battery])
  #expect(fixture.items.presentedCombined == [.overview])
  let target = try #require(fixture.items.targets.first)
  #expect(target.module == .overview, "routing and rendering share one module list")
  // Keyboard/VoiceOver press: no event, production fallback calculation.
  app.activateStatusButton(target.button, event: nil)
  app.popover?.animates = false
  #expect(app.detail?.selected == .overview && app.popover?.isShown == true)
  // The next sample does not close it: Overview is not a hidden module.
  deliver(app, batteries: [battery(external: false)])
  #expect(app.popover?.isShown == true)
  #expect(applier.calls.isEmpty)
}

@Test @MainActor func failedBatteryReadKeepsLastSourceWhileDesktopStaysOnAdapter() throws {
  var settings = Settings()
  settings.readouts = [.cpu, .battery]
  settings.separateItems = false
  settings.batteryMenu.visibility = .init(onAdapter: false, onBattery: true)
  let laptop = try MenuBarRoutingFixture(
    combined: true, modules: [.cpu, .battery], settings: settings)
  defer { laptop.close() }
  deliver(try #require(laptop.app), batteries: [battery(external: false)])
  #expect(laptop.items.hiddenModules.isEmpty && laptop.items.powerSource == .battery)
  // A failed native read also yields an empty list: the laptop stays on battery.
  deliver(try #require(laptop.app), batteries: [])
  #expect(laptop.items.hiddenModules.isEmpty && laptop.items.powerSource == .battery)
  deliver(try #require(laptop.app), batteries: [battery(external: true)])
  #expect(laptop.items.hiddenModules == [.battery])
  // A Mac that never reported a battery is on its adapter.
  let desktop = try MenuBarRoutingFixture(
    combined: true, modules: [.cpu, .battery], settings: settings)
  defer { desktop.close() }
  deliver(try #require(desktop.app), batteries: [])
  #expect(desktop.items.hiddenModules == [.battery] && desktop.items.powerSource == .adapter)
}

@Test @MainActor func launchAndRenderingNeverReadOrApplyEnergyModes() throws {
  let (energy, reader, applier) = makeController(.available(laptopStatus))
  let fixture = try MenuBarRoutingFixture(combined: false, energyModes: energy)
  defer { fixture.close() }
  deliver(try #require(fixture.app), batteries: [battery(external: true)])
  _ = powerDropdown(energy.presentation(currentSource: .adapter), batteries: [])
  #expect(reader.count == 0 && applier.calls.isEmpty)
}

// MARK: - Renders (only with TINYSTATS_SYSTEM_RENDER_PATH; owned views/windows only)

@MainActor private func writePNG(
  _ view: NSView, rect: NSRect? = nil, scale: CGFloat = 2, to url: URL
) throws {
  let area = rect ?? view.bounds
  let output = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(area.width * scale),
      pixelsHigh: Int(area.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  output.size = area.size
  let layer = try #require(view.bitmapImageRepForCachingDisplay(in: area))
  layer.size = area.size
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: area, to: layer)
  }
  let context = try #require(NSGraphicsContext(bitmapImageRep: output))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    NSColor.windowBackgroundColor.setFill()
    NSRect(origin: .zero, size: area.size).fill()
    let image = NSImage(size: area.size)
    image.addRepresentation(layer)
    image.draw(in: NSRect(origin: .zero, size: area.size))
  }
  NSGraphicsContext.restoreGraphicsState()
  try #require(output.representation(using: .png, properties: [:])).write(to: url)
}

private struct EnergyFixture {
  var name: String
  var status: EnergyModeStatus
  var batteries: [BatteryReading]
}

private let energyFixtures = [
  EnergyFixture(name: "laptop", status: laptopStatus, batteries: [battery(external: true)]),
  EnergyFixture(
    name: "laptop-nohigh", status: laptopNoHighStatus,
    batteries: [battery(external: false, percent: 58)]),
  EnergyFixture(name: "desktop", status: desktopStatus, batteries: []),
]

@MainActor private func settingsPowerView(
  theme: AppTheme, solid: Bool, hasBattery: Bool
) throws -> (DetailController, PreferencesController) {
  var settings = Settings()
  settings.theme = theme
  settings.readouts = [.cpu, .memory, .battery]
  settings.batteryMenu.visibility = .init(onAdapter: true, onBattery: !hasBattery)
  var snapshot = Snapshot()
  snapshot.batteries = hasBattery ? [battery(external: true)] : []
  let detail = DetailController(snapshot: snapshot, history: [])
  detail.glassEnvironment = {
    .init(supportsGlass: !solid, reduceTransparency: solid, increaseContrast: false)
  }
  detail.isPopoverPresentation = false
  detail.view.frame = .init(origin: .zero, size: MainWindow.minimumSize)
  let editor = PreferencesController(
    settings: settings, interfaces: [], snapshot: snapshot, history: [], initialPage: .menuBar)
  editor.selectStyleModule(.battery)
  detail.showSettingsView(try #require(editor.embeddedView(page: .menuBar)), page: .menuBar)
  detail.view.appearance = theme.nativeAppearance
  detail.view.layoutSubtreeIfNeeded()
  if let picker = editor.powerVisibility, let section = picker.superview {
    section.scrollToVisible(section.bounds)
  }
  detail.view.layoutSubtreeIfNeeded()
  return (detail, editor)
}

@Test @MainActor func powerProfilesRenderGallery() async throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] else {
    return
  }
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var report: [String] = []
  for theme in [AppTheme.light, .dark] {
    // Settings › Menu Bar › Power: laptop (battery tile off) and desktop (no battery).
    for (variant, hasBattery, solid) in [
      ("", true, false), ("-solid", true, true), ("-desktop", false, false),
    ] {
      let (detail, editor) = try settingsPowerView(
        theme: theme, solid: solid, hasBattery: hasBattery)
      defer {
        editor.disposeEmbedded()
        editor.close()
      }
      let picker = try #require(editor.powerVisibility)
      #expect(picker.visibleRect.height >= picker.bounds.height - 1)
      try writePNG(
        detail.view,
        to: folder.appendingPathComponent(
          "settings-power-visibility\(variant)-\(theme.rawValue).png"))
      if variant.isEmpty || variant == "-desktop" {
        let rect = picker.convert(picker.bounds, to: detail.view).insetBy(dx: -6, dy: -6)
        try writePNG(
          detail.view,
          rect: .init(
            x: rect.minX, y: rect.minY,
            width: 2 * PowerVisibilityPicker.tileWidth(for: picker.bounds.width) + 20,
            height: rect.height),
          scale: 3,
          to: folder.appendingPathComponent(
            "settings-power-visibility\(variant)-tiles-3x-\(theme.rawValue).png"))
      }
      report.append("settings\(variant) \(theme.rawValue): tiles=\(picker.frame.size)")
    }
    // Power dropdown Energy Mode section.
    for fixture in energyFixtures {
      for solid in [false, true] {
        let value = await presentation(
          fixture.status, current: PowerSourceKind.current(fixture.batteries))
        let detail = powerDropdown(value, batteries: fixture.batteries)
        detail.glassEnvironment = {
          .init(supportsGlass: !solid, reduceTransparency: solid, increaseContrast: false)
        }
        detail.view.appearance = theme.nativeAppearance
        detail.update(detail.snapshot, history: [])
        detail.view.layoutSubtreeIfNeeded()
        let stem = "dropdown-energy-mode-\(fixture.name)\(solid ? "-solid" : "")-\(theme.rawValue)"
        try writePNG(detail.view, to: folder.appendingPathComponent(stem + ".png"))
        let control = try #require(detail.energyModeControl)
        if !solid {
          let rows = control.convert(control.bounds, to: detail.view).insetBy(dx: -8, dy: -40)
          try writePNG(
            detail.view, rect: rows.intersection(detail.view.bounds), scale: 3,
            to: folder.appendingPathComponent(
              "dropdown-energy-mode-\(fixture.name)-rows-3x-\(theme.rawValue).png"))
        }
        report.append("\(stem): rows=\(value.rows.count) control=\(control.frame.size)")
      }
    }
    // Cancelled authorization: reverted selection, short message and fallback button.
    let (controller, _, applier) = makeController(.available(laptopStatus))
    controller.refresh()
    await settle { controller.reading != nil }
    controller.select(.automatic, for: .adapter)
    applier.finish(.cancelled)
    await settle { !controller.isReading }
    let detail = powerDropdown(
      controller.presentation(currentSource: .adapter), batteries: [battery(external: true)])
    detail.view.appearance = theme.nativeAppearance
    detail.view.layoutSubtreeIfNeeded()
    try writePNG(
      detail.view,
      to: folder.appendingPathComponent(
        "dropdown-energy-mode-laptop-cancelled-\(theme.rawValue).png"))
  }
  try (report.joined(separator: "\n") + "\n").write(
    to: folder.appendingPathComponent("power-profiles-renders.txt"), atomically: true,
    encoding: .utf8)
  try await powerProfilesGlassCapture(folder: folder)
}

/// Real compositor capture of our own borderless window over a colourful backdrop. Requires
/// existing screen-capture access (preflight only — never requests it) and macOS 26 glass.
@MainActor private func powerProfilesGlassCapture(folder: URL) async throws {
  let note = folder.appendingPathComponent("power-profiles-glass.txt")
  guard ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_GLASS_CAPTURE"] == "1" else {
    return
  }
  guard GlassSurface.Environment.current.supportsGlass, CGPreflightScreenCaptureAccess() else {
    try
      "Glass capture unavailable: macOS 26 glass or existing screen-capture access missing. No permission requested.\n"
      .write(to: note, atomically: true, encoding: .utf8)
    return
  }
  _ = NSApplication.shared
  let size = NSSize(width: 520, height: 720)
  let window = NSWindow(
    contentRect: .init(origin: .init(x: 120, y: 120), size: size), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.level = .floating
  final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
      NSGradient(colors: [.systemPink, .systemOrange, .systemTeal, .systemPurple])?
        .draw(in: bounds, angle: 35)
    }
  }
  let backdrop = Backdrop(frame: .init(origin: .zero, size: size))
  window.contentView = backdrop
  defer {
    for child in backdrop.subviews { child.removeFromSuperview() }
    window.orderOut(nil)
    window.close()
  }
  window.orderFrontRegardless()
  var written: [String] = []
  for theme in [AppTheme.light, .dark] {
    window.appearance = theme.nativeAppearance
    for fixture in energyFixtures where fixture.name == "laptop" {
      let value = await presentation(
        fixture.status, current: PowerSourceKind.current(fixture.batteries))
      let detail = powerDropdown(value, batteries: fixture.batteries)
      detail.glassEnvironment = {
        .init(supportsGlass: true, reduceTransparency: false, increaseContrast: false)
      }
      detail.view.frame.origin = .init(
        x: (size.width - detail.view.frame.width) / 2,
        y: (size.height - detail.view.frame.height) / 2)
      backdrop.addSubview(detail.view)
      detail.update(detail.snapshot, history: [])
      detail.view.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(600))
      let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)
      let owned = try #require(
        content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
      let configuration = SCStreamConfiguration()
      configuration.width = Int(size.width)
      configuration.height = Int(size.height)
      configuration.showsCursor = false
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: owned),
        configuration: configuration)
      let name = "dropdown-energy-mode-\(fixture.name)-glass-\(theme.rawValue).png"
      try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        .write(to: folder.appendingPathComponent(name))
      written.append(name)
      detail.view.removeFromSuperview()
    }
  }
  try
    ("Captured only TinyStats' own synthetic window after CGPreflightScreenCaptureAccess. The test process is not the active app, so native segments may draw inactive gray.\n"
    + written.joined(separator: "\n") + "\n").write(to: note, atomically: true, encoding: .utf8)
}
