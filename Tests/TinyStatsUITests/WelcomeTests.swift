import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

private func welcomeStore() throws -> (String, UserDefaults) {
  let name = "TinyStats.WelcomeTests.\(UUID().uuidString)"
  return (name, try #require(UserDefaults(suiteName: name)))
}

@Test func welcomeUpgradeSilentlyRecordsFlagWithoutChangingSavedChoices() throws {
  let (name, store) = try welcomeStore()
  defer { store.removePersistentDomain(forName: name) }
  var saved = Settings()
  saved.weather = .currentLocationDefault
  saved.persistHistory = false
  saved.save(to: store)
  let payload = store.data(forKey: "settings")
  #expect(!WelcomePresentation.shouldShow(in: store, arguments: ["TinyStats"], isolated: false))
  #expect(store.bool(forKey: WelcomePresentation.shownKey))
  #expect(store.data(forKey: "settings") == payload)
  #expect(Settings.load(from: store) == saved)
}

@Test func welcomeFirstLaunchIsRecordedIndependentlyOfFeatureChoices() throws {
  let (name, store) = try welcomeStore()
  defer { store.removePersistentDomain(forName: name) }
  let args = ["TinyStats"]
  #expect(WelcomePresentation.shouldShow(in: store, arguments: args, isolated: false))
  WelcomePresentation.recordShown(in: store)
  #expect(!WelcomePresentation.shouldShow(in: store, arguments: args, isolated: false))
  #expect(store.object(forKey: "settings") == nil)
  // A fresh store instance sees the same one-time flag, including after Skip/close.
  let reopened = try #require(UserDefaults(suiteName: name))
  #expect(!WelcomePresentation.shouldShow(in: reopened, arguments: args, isolated: false))
  #expect(!Settings.load(from: reopened).weather.enabled)
}

@Test func welcomePreviewIsExplicitAndIsolatedWithoutChangingTheFlag() throws {
  let (name, store) = try welcomeStore()
  defer { store.removePersistentDomain(forName: name) }
  for arguments in [
    ["TinyStats"], ["TinyStats", "--preview"], ["TinyStats", "--preview-settings"],
  ] {
    #expect(!WelcomePresentation.shouldShow(in: store, arguments: arguments, isolated: true))
  }
  #expect(
    !WelcomePresentation.shouldShow(
      in: store, arguments: ["TinyStats", "--preview"], isolated: false))
  WelcomePresentation.recordShown(in: store)
  #expect(
    WelcomePresentation.shouldShow(
      in: store, arguments: ["TinyStats", "--preview-onboarding"], isolated: true))
  #expect(
    !WelcomePresentation.shouldShow(
      in: store, arguments: ["TinyStats", "--preview-onboarding"], isolated: false))
}

@Test func welcomeLaunchWiringRecordsOnlyOrdinaryPresentationAndSilentUpgrades() throws {
  let (name, store) = try welcomeStore()
  defer { store.removePersistentDomain(forName: name) }
  let normal = ["TinyStats"]
  let preview = ["TinyStats", "--preview-onboarding", "--preview-onboarding-step", "4"]
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: preview, isolated: true) == 3)
  #expect(store.object(forKey: WelcomePresentation.shownKey) == nil)
  #expect(store.object(forKey: "settings") == nil)
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: preview, isolated: false) == nil)
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: normal, isolated: true) == nil)
  #expect(
    WelcomePresentation.prepareLaunch(
      in: store, arguments: ["TinyStats", "--preview-settings"], isolated: false) == nil)
  #expect(store.object(forKey: WelcomePresentation.shownKey) == nil)
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: normal, isolated: false) == 0)
  #expect(store.bool(forKey: WelcomePresentation.shownKey))
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: normal, isolated: false) == nil)
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: preview, isolated: true) == 3)
  #expect(store.bool(forKey: WelcomePresentation.shownKey))

  // Any existing settings object identifies an upgrade, even if decoding fails.
  store.removeObject(forKey: WelcomePresentation.shownKey)
  store.set("damaged", forKey: "settings")
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: preview, isolated: true) == 3)
  #expect(store.object(forKey: WelcomePresentation.shownKey) == nil)
  #expect(WelcomePresentation.prepareLaunch(in: store, arguments: normal, isolated: false) == nil)
  #expect(store.bool(forKey: WelcomePresentation.shownKey))
  #expect(store.string(forKey: "settings") == "damaged")
}

@Test func welcomePreviewStepParsingIsBoundedAndOnlyAffectsPreviews() throws {
  for step in 1...6 {
    #expect(
      WelcomePresentation.previewInitialStep(
        arguments: ["TinyStats", "--preview-onboarding-step", String(step)]) == step - 1)
  }
  for suffix in [[], ["0"], ["7"], ["-1"], ["bad"], ["1.5"], [String(repeating: "9", count: 100)]] {
    #expect(
      WelcomePresentation.previewInitialStep(
        arguments: ["TinyStats", "--preview-onboarding-step"] + suffix) == 0)
  }
  let (name, store) = try welcomeStore()
  defer { store.removePersistentDomain(forName: name) }
  #expect(
    WelcomePresentation.prepareLaunch(
      in: store, arguments: ["TinyStats", "--preview-onboarding-step", "6"], isolated: false) == nil
  )
  #expect(store.object(forKey: WelcomePresentation.shownKey) == nil)
}

@Test func welcomePreferencesApplicationPreservesIndependentChangesFromStaleDrafts() {
  for history in [true, false] {
    var draft = Settings()
    draft.persistHistory = !history
    draft.fahrenheit = true
    draft.readouts = [.cpu, .weather]
    draft.styles[Module.cpu.rawValue] = .ring
    var current = Settings()
    current.persistHistory = history
    current.networkTrafficGrouping = .bundles
    current.networkTrafficRevision = "new-revision"
    let merged = PreferencesApplication.merging(draft, current: current)
    var expected = draft
    expected.persistHistory = history
    expected.networkTrafficGrouping = current.networkTrafficGrouping
    expected.networkTrafficRevision = current.networkTrafficRevision
    #expect(merged == expected)
  }
}

@Test @MainActor func welcomeChangesSyncOpenSettingsAndSurviveLaterEdits() throws {
  _ = NSApplication.shared
  for initialPage in [PreferencesController.Page.general, .menuBar] {
    var original = Settings()
    original.persistHistory = false
    original.fahrenheit = true
    let prefs = PreferencesController(
      settings: original, interfaces: [], snapshot: Snapshot(), history: [],
      initialPage: initialPage)
    defer { prefs.close() }
    var changed = original
    changed.readouts = [.cpu, .weather]
    changed.styles[Module.cpu.rawValue] = .ring
    var emitted: Settings?
    prefs.onChange = { emitted = $0 }
    prefs.updateMenuBarSettings(changed)
    #expect(emitted == nil)
    prefs.selectMenuBarTab()
    let root = try #require(prefs.window?.contentView)
    let controls = welcomeViews(root)
    let tray = try #require(controls.compactMap { $0 as? MenuBarCustomization }.first)
    #expect(tray.order == changed.readouts)
    let style = try #require(
      controls.compactMap { $0 as? MenuBarStylePicker }.first {
        $0.accessibilityLabel() == "CPU menu bar style"
      })
    #expect(style.titleOfSelectedItem == MenuBarStyle.ring.title)
    // A later Settings edit must keep the tour's readouts/styles and other saved choices.
    try welcomeActivate(style)
    let saved = try #require(emitted)
    #expect(saved.readouts == changed.readouts && saved.style(for: .cpu) == .ring)
    #expect(!saved.persistHistory && saved.fahrenheit && !saved.weather.enabled)
    prefs.selectPage(.general)
    let login = try #require(
      welcomeViews(root).compactMap { $0 as? SystemSettingSwitch }.first {
        $0.title == "Launch at login"
      })
    login.state = LoginItemPreference.enabled ? .off : .on
    prefs.refreshVisibleContent()
    #expect(login.state == (LoginItemPreference.enabled ? .on : .off))
  }
}

@MainActor private func welcomeViews(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(welcomeViews)
}
@MainActor private func welcomeActivate(_ control: NSControl) throws {
  let action = try #require(control.action)
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
}

@Test @MainActor func welcomeSkipAndNavigationLeaveNewAndExistingChoicesUntouched() throws {
  _ = NSApplication.shared
  for existing in [false, true] {
    var settings = Settings()
    if existing {
      settings.weather = .currentLocationDefault
      settings.persistHistory = false
      settings.alerts = true
    }
    let original = settings
    let controller = WelcomeController(settings: { settings })
    var changes = 0
    controller.onMenuBarChange = { _ in changes += 1 }
    controller.onHistoryPersistence = { _ in changes += 1 }
    controller.onWeather = { changes += 1 }
    controller.onInternet = { changes += 1 }
    controller.onNotifications = { changes += 1 }
    controller.onOverview = { changes += 1 }
    controller.onMenuBarSettings = { changes += 1 }
    #expect(controller.step == 0)
    controller.previousStep()
    #expect(controller.step == 0)
    for _ in 0..<5 { controller.nextStep() }
    #expect(controller.step == 5)
    controller.previousStep()
    #expect(controller.step == 4)
    controller.skipTour()
    #expect(settings == original && changes == 0)
  }
}

@Test @MainActor func welcomeNamesDefaultReadoutsAndPrivacyChoices() throws {
  _ = NSApplication.shared
  let controller = WelcomeController(settings: { Settings() })
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let copy = welcomeViews(root).compactMap { ($0 as? NSTextField)?.stringValue }.joined(
    separator: "\n")
  for phrase in [
    "CPU, Memory and Network", "tiny footprint", "No analytics",
    "Weather and internet checks stay off until you opt in", "existing saved choices are preserved",
    "Tab / Shift-Tab", "right-click", "Show welcome tour",
  ] {
    #expect(copy.localizedCaseInsensitiveContains(phrase))
  }
}

@Test @MainActor func welcomeStarterListPresetsAndPreviewPreserveAdvancedChoices() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.readouts = [
    .cpu, .memory, .network, .battery, .clock, .weather, .disks, .sensors, .gpu,
  ]
  settings.sensorKey = "F0Ac"
  settings.styles[Module.disks.rawValue] = .ring
  var disabledLook = settings.appearance(for: .disks)
  disabledLook.size = .large
  settings.appearances[Module.disks.rawValue] = disabledLook
  let controller = WelcomeController(settings: { settings }, initialStep: 1)
  defer { controller.close() }
  controller.onMenuBarChange = { settings = $0 }
  let root = try #require(controller.window?.contentView)
  let buttons = welcomeViews(root).compactMap { $0 as? NSButton }
  let starters: [Module] = [.cpu, .memory, .network, .battery, .clock, .weather, .disks]
  #expect(
    buttons.filter { $0.accessibilityLabel()?.hasPrefix("Show ") == true }.map(\.title)
      == starters.map(\.title))
  for module in [Module.overview, .sensors, .gpu] {
    #expect(!buttons.contains { $0.title == module.title })
  }
  #expect(!buttons.contains { $0.title == "History" })
  let disks = try #require(buttons.first { $0.title == Module.disks.title })
  disks.state = .off
  try welcomeActivate(disks)
  #expect(
    settings.readouts == [
      .cpu, .memory, .network, .battery, .clock, .weather, .sensors, .gpu,
    ])
  let presets = try #require(welcomeViews(root).compactMap { $0 as? NSSegmentedControl }.first)
  #expect(
    (0..<presets.segmentCount).compactMap {
      presets.image(forSegment: $0)?.accessibilityDescription
    } == [
      "Separate", "One",
    ])
  let preview = try #require(welcomeViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
  for segment in [0, 1] {
    presets.selectedSegment = segment
    try welcomeActivate(presets)
    #expect(settings.separateItems == (segment == 0))
    #expect(settings.style(for: .disks) == .ring)
    #expect(settings.appearance(for: .disks).size == .large)
    #expect(preview.renderers.count == (segment == 0 ? settings.readouts.count : 1))
    let readings = preview.renderers.flatMap(\.readouts)
    #expect(readings.compactMap(\.module) == settings.readouts)
    #expect(readings.first { $0.module == .cpu }?.value == "—")
    #expect(readings.first { $0.module == .cpu }?.progress == nil)
    #expect(readings.map(\.style) == settings.readouts.map { settings.style(for: $0) })
    #expect(!settings.weather.enabled && !settings.connectivityChecks && !settings.publicIPChecks)
  }
  // Returning from Settings refreshes the fixture and preset selection without emitting edits.
  settings.styles[Module.cpu.rawValue] = .ring
  controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  #expect(presets.selectedSegment == 1)
  #expect(preview.renderers.first?.readouts.first { $0.module == .cpu }?.style == .ring)
}

@Test @MainActor func welcomeModuleCardsDiscloseSecondaryContentAndRouteOverview() throws {
  _ = NSApplication.shared
  let settings = Settings()
  let controller = WelcomeController(settings: { settings }, initialStep: 2)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let body = try #require(root.subviews.compactMap { $0 as? NSStackView }.first)
  let cards = body.arrangedSubviews.compactMap { $0 as? NSStackView }
  #expect(cards.count == 5)
  #expect(cards.allSatisfy { $0.arrangedSubviews.compactMap { $0 as? NSTextField }.count == 2 })
  let labels = welcomeViews(root).compactMap { $0 as? NSTextField }
  #expect(labels.contains { $0.stringValue == "CPU & GPU" })
  #expect(!labels.contains { $0.stringValue.hasPrefix("CPU · Total and per-core") })
  #expect(
    labels.contains {
      $0.stringValue.hasPrefix("Advanced · Sensors") && $0.textColor == .secondaryLabelColor
    })
  let more = try #require(labels.first { $0.stringValue.hasPrefix("History ·") })
  let disclosure = try #require(
    welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == "More modules…" })
  #expect(more.isHidden)
  try welcomeActivate(disclosure)
  #expect(!more.isHidden && disclosure.state == .on)
  var opened = 0
  controller.onOverview = { opened += 1 }
  let overview = try #require(
    welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Open Overview…" })
  try welcomeActivate(overview)
  #expect(opened == 1)
  controller.nextStep()
  controller.previousStep()
  #expect(
    welcomeViews(root).compactMap { $0 as? NSTextField }.first {
      $0.stringValue.hasPrefix("History ·")
    }?.isHidden == false)
  let reopened = WelcomeController(settings: { settings }, initialStep: 2)
  defer { reopened.close() }
  let reopenedRoot = try #require(reopened.window?.contentView)
  #expect(
    welcomeViews(reopenedRoot).compactMap { $0 as? NSTextField }.first {
      $0.stringValue.hasPrefix("History ·")
    }?.isHidden == true)
}

@Test @MainActor func welcomeFinishTeachesClicksAndRoutesMenuBarAndGeneralSettings() throws {
  _ = NSApplication.shared
  let controller = WelcomeController(settings: { Settings() }, initialStep: 5)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let copy = welcomeViews(root).compactMap { ($0 as? NSTextField)?.stringValue }.joined(
    separator: "\n")
  #expect(copy.contains("Click any TinyStats menu bar readout for details."))
  #expect(copy.contains("Right-click a readout for Settings, pause, Show welcome tour or Quit."))
  var actions: [String] = []
  controller.onMenuBarSettings = { actions.append("menuBar") }
  controller.onSettings = { actions.append("general") }
  for title in ["Open Menu Bar settings…", "Open Settings…"] {
    let button = try #require(
      welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == title })
    try welcomeActivate(button)
  }
  #expect(actions == ["menuBar", "general"])
  #expect(
    welcomeViews(root).compactMap { $0 as? NSButton }.contains { $0.title == "Launch at login" })
}

@Test @MainActor func welcomeMenuChoicesPersistAndWeatherReadoutDoesNotEnableWeather() throws {
  _ = NSApplication.shared
  let (name, store) = try welcomeStore()
  defer { store.removePersistentDomain(forName: name) }
  var settings = Settings()
  let controller = WelcomeController(settings: { settings }, initialStep: 1)
  defer { controller.close() }
  controller.onMenuBarChange = { value in
    settings = value
    value.save(to: store)
  }
  let root = try #require(controller.window?.contentView)
  let weather = try #require(
    welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Weather" })
  weather.state = .on
  try welcomeActivate(weather)
  let cpuStyle = try #require(
    welcomeViews(root).compactMap { $0 as? MenuBarStylePicker }.first {
      $0.accessibilityLabel() == "CPU menu bar style"
    })
  cpuStyle.selectItem(withTitle: MenuBarStyle.ring.title)
  try welcomeActivate(cpuStyle)
  let preview = try #require(welcomeViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(
    preview.renderers.flatMap(\.readouts).compactMap(\.module) == [
      .cpu, .memory, .network, .weather,
    ])
  #expect(preview.renderers.first?.readouts.first { $0.module == .cpu }?.style == .ring)
  let saved = Settings.load(from: store)
  #expect(saved.readouts == [.cpu, .memory, .network, .weather])
  #expect(saved.style(for: .cpu) == .ring)
  #expect(!saved.weather.enabled && saved.weather.location == nil)
  #expect(
    !saved.connectivityChecks && !saved.publicIPChecks && !saved.pingCheck.enabled && !saved.alerts)
  // A later external setting change survives the next tour choice.
  settings.fahrenheit = true
  try welcomeActivate(cpuStyle)
  #expect(Settings.load(from: store).fahrenheit)
  settings.weather = .currentLocationDefault
  settings.sensorKey = "F0Ac"
  controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  try welcomeActivate(cpuStyle)
  #expect(Settings.load(from: store).weather.enabled)
  #expect(Settings.load(from: store).sensorKey == "F0Ac")
  for check in welcomeViews(root).compactMap({ $0 as? NSButton })
  where Module.allCases.contains(where: { $0.title == check.title }) {
    check.state = .off
  }
  try welcomeActivate(weather)
  #expect(Settings.load(from: store).readouts == saved.readouts)
}

@Test @MainActor func welcomeHistoryUsesExistingCallbackAndRespectsBusyState() throws {
  _ = NSApplication.shared
  let (name, store) = try welcomeStore()
  defer { store.removePersistentDomain(forName: name) }
  var settings = Settings()
  let controller = WelcomeController(settings: { settings }, initialStep: 4)
  defer { controller.close() }
  var changes = 0
  controller.onHistoryPersistence = { enabled in
    changes += 1
    settings.persistHistory = enabled
    settings.save(to: store)
  }
  let root = try #require(controller.window?.contentView)
  let history = try #require(
    welcomeViews(root).compactMap { $0 as? NSButton }.first {
      $0.title == "Keep history between launches"
    })
  #expect(history.state == .on)
  history.state = .off
  try welcomeActivate(history)
  #expect(!Settings.load(from: store).persistHistory)
  #expect(!Settings.load(from: store).weather.enabled)
  controller.setHistoryBusy(true)
  #expect(!history.isEnabled)
  history.state = .on
  try welcomeActivate(history)
  #expect(changes == 1 && history.state == .off)
  controller.setHistoryBusy(false)
  #expect(history.isEnabled)
}

@Test @MainActor func welcomeOnlineSetupOnlyRoutesExplicitActions() throws {
  _ = NSApplication.shared
  let settings = Settings()
  let controller = WelcomeController(settings: { settings }, initialStep: 3)
  defer { controller.close() }
  var actions: [String] = []
  controller.onWeather = { actions.append("weather") }
  controller.onInternet = { actions.append("internet") }
  #expect(actions.isEmpty)
  let root = try #require(controller.window?.contentView)
  let labels = welcomeViews(root).compactMap { $0 as? NSTextField }
  #expect(labels.contains { $0.stringValue == "Online only when you choose" })
  #expect(
    labels.contains {
      $0.stringValue.contains("MET Norway (api.met.no)")
        && $0.stringValue.contains("rounded coordinates and your public IP")
    })
  #expect(labels.contains { $0.stringValue.hasPrefix("Remains off if you skip.") })
  #expect(
    labels.contains {
      $0.stringValue.hasPrefix("Optional advanced · Internet checks are off by default.")
        && $0.textColor == .secondaryLabelColor
    })
  let setup = welcomeViews(root).compactMap { $0 as? NSButton }.filter {
    $0.title == "Set up Weather…" || $0.title == "Advanced · Internet checks…"
  }
  #expect(setup.map(\.title) == ["Set up Weather…", "Advanced · Internet checks…"])
  #expect(
    !welcomeViews(root).compactMap { $0 as? NSButton }.contains {
      $0.title.contains("Calendar")
    })
  for title in ["Set up Weather…", "Advanced · Internet checks…"] {
    let button = try #require(
      welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == title })
    try welcomeActivate(button)
  }
  #expect(actions == ["weather", "internet"])
  #expect(!settings.weather.enabled && !settings.connectivityChecks)
  #expect(!settings.publicIPChecks && !settings.pingCheck.enabled && !settings.calendarEvents)
}

@Test @MainActor func welcomeStepsFitNativeWindowInLightAndDark() throws {
  _ = NSApplication.shared
  for (theme, name) in [(AppTheme.light, "light"), (.dark, "dark")] {
    var settings = Settings()
    settings.theme = theme
    for step in 0..<6 {
      let controller = WelcomeController(settings: { settings }, initialStep: step)
      let root = try #require(controller.window?.contentView)
      if step == 2 {
        let disclosure = try #require(
          welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == "More modules…" })
        try welcomeActivate(disclosure)
      }
      root.layoutSubtreeIfNeeded()
      let controls = welcomeViews(root).compactMap { $0 as? NSControl }.filter {
        !$0.isHiddenOrHasHiddenAncestor
      }
      for control in controls {
        let frame = root.convert(control.bounds, from: control)
        #expect(
          root.bounds.contains(frame), "Step \(step + 1): \(control) exceeds window: \(frame)")
      }
      let body = try #require(root.subviews.first { $0 is NSStackView })
      let bodyFrame = body.frame
      #expect(bodyFrame.minY >= 100 && bodyFrame.maxY <= 550)
      let labels = welcomeViews(body).compactMap { $0 as? NSTextField }.filter {
        !$0.isHiddenOrHasHiddenAncestor
      }
      for label in labels {
        #expect(label.bounds.height >= label.intrinsicContentSize.height - 1)
      }
      if let path = ProcessInfo.processInfo.environment["TINYSTATS_WELCOME_RENDER_PATH"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
          root.cacheDisplay(in: root.bounds, to: bitmap)
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: directory.appendingPathComponent("welcome-\(step + 1)-\(name).png"))
      }
      controller.close()
    }
  }
}

@Test @MainActor func welcomeStyleWidthsSurviveSwitchingAndHiddenLayoutResetsForLaterSteps() throws
{
  let controller = WelcomeController(settings: { Settings() }, initialStep: 1)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let selector = try #require(
    welcomeViews(root).compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "Welcome readout to customize"
    })
  for module in [Module.memory, .battery, .cpu, .memory] {
    selector.selectItem(withTitle: module.title)
    try welcomeActivate(selector)
    root.layoutSubtreeIfNeeded()
    let picker = try #require(
      welcomeViews(root).compactMap { $0 as? MenuBarStylePicker }.first {
        $0.module == module
      })
    #expect(!picker.isHiddenOrHasHiddenAncestor)
    #expect(abs(picker.bounds.width - (picker.superview?.bounds.width ?? 0)) < 1)
  }
  controller.nextStep()
  let body = try #require(root.subviews.compactMap { $0 as? NSStackView }.first)
  #expect(!body.detachesHiddenViews)
}
