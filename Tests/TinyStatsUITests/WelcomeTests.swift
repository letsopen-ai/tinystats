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
    "Your Mac, at a glance", "tiny footprint", "No analytics", "Local-only by default",
    "Tab / ⇧Tab", "right-click", "Show welcome tour", "CPU", "Memory", "Network",
  ] {
    #expect(copy.localizedCaseInsensitiveContains(phrase))
  }
}

@Test @MainActor func welcomeSloganHasProminentTypographyAndTightGreetSpacing() throws {
  _ = NSApplication.shared
  for theme in [AppTheme.light, .dark] {
    for treatment in [GlassSurface.Treatment.glass, .solid, .legacy] {
      var settings = Settings()
      settings.theme = theme
      let controller = WelcomeController(
        settings: { settings },
        glassEnvironment: {
          .init(
            supportsGlass: treatment != .legacy, reduceTransparency: treatment == .solid,
            increaseContrast: false)
        })
      defer { controller.close() }
      let root = try #require(controller.window?.contentView)
      // Returning to Greet restores its tighter spacing without changing later pages.
      for step in [0, 1, 0] {
        root.layoutSubtreeIfNeeded()
        let body = try #require(root.subviews.compactMap { $0 as? NSStackView }.first)
        let heading = try #require(
          root.subviews.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 24 })
        let headingFrame = root.convert(heading.bounds, from: heading)
        let bodyFrame = root.convert(body.bounds, from: body)
        #expect(abs(headingFrame.minY - bodyFrame.maxY - (step == 0 ? 8 : 18)) < 1)
        if step == 0 {
          #expect(heading.stringValue == "Welcome to TinyStats")
          let slogan = try #require(
            welcomeViews(body).compactMap { $0 as? NSTextField }.first {
              $0.stringValue == "Your Mac, at a glance."
            })
          let font = try #require(slogan.font)
          #expect(font.pointSize >= 17 && font.pointSize < 24)
          #expect(
            NSFontManager.shared.weight(of: font)
              >= NSFontManager.shared.weight(
                of: .systemFont(ofSize: font.pointSize, weight: .medium)))
          #expect(slogan.textColor == .labelColor)
          #expect(!slogan.isHiddenOrHasHiddenAncestor)
          #expect(slogan.bounds.height >= slogan.intrinsicContentSize.height - 1)
          let hero = try #require(welcomeViews(body).compactMap { $0 as? WelcomeHeroView }.first)
          let sloganFrame = root.convert(slogan.bounds, from: slogan)
          let heroFrame = root.convert(hero.bounds, from: hero)
          #expect(abs(sloganFrame.minY - heroFrame.maxY - 12) < 1)
          #expect(hero.bounds.height >= 240)
          #expect(
            welcomeViews(body).compactMap { $0 as? NSTextField }.filter { $0 !== slogan }
              .allSatisfy { ($0.font?.pointSize ?? 0) <= 13 })
          controller.nextStep()
        } else {
          controller.previousStep()
        }
      }
    }
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
  let cards = welcomeViews(body).compactMap { $0 as? WelcomeTileView }
  #expect(cards.count == 9)
  #expect(cards.allSatisfy { welcomeViews($0).contains { $0 is NSImageView } })
  let labels = welcomeViews(root).compactMap { $0 as? NSTextField }
  #expect(labels.contains { $0.stringValue == "CPU & GPU" })
  #expect(labels.contains { $0.stringValue == "Advanced · Sensors" })
  let more = try #require(
    welcomeViews(root).first {
      $0.identifier?.rawValue == "welcome-more-modules"
    })
  let disclosure = try #require(
    welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == "More modules…" })
  #expect(more.isHidden)
  root.layoutSubtreeIfNeeded()
  let collapsedHeight = body.frame.height
  try welcomeActivate(disclosure)
  root.layoutSubtreeIfNeeded()
  #expect(!more.isHidden && disclosure.state == .on)
  #expect(body.frame.height > collapsedHeight + 50)
  #expect(welcomeViews(more).compactMap { $0 as? WelcomeTileView }.count == 2)
  var opened = 0
  controller.onOverview = { opened += 1 }
  let overview = try #require(
    welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Open Overview…" })
  try welcomeActivate(overview)
  #expect(opened == 1)
  controller.nextStep()
  controller.previousStep()
  #expect(
    welcomeViews(root).first {
      $0.identifier?.rawValue == "welcome-more-modules"
    }?.isHidden == false)
  let reopened = WelcomeController(settings: { settings }, initialStep: 2)
  defer { reopened.close() }
  let reopenedRoot = try #require(reopened.window?.contentView)
  #expect(
    welcomeViews(reopenedRoot).first {
      $0.identifier?.rawValue == "welcome-more-modules"
    }?.isHidden == true)
}

@Test @MainActor func welcomeFinishTeachesClicksAndRoutesMenuBarAndGeneralSettings() throws {
  _ = NSApplication.shared
  let controller = WelcomeController(settings: { Settings() }, initialStep: 5)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let copy = welcomeViews(root).compactMap { ($0 as? NSTextField)?.stringValue }.joined(
    separator: "\n")
  #expect(copy.contains("Click a readout") && copy.contains("Open its details"))
  #expect(
    copy.contains("Right-click a readout") && copy.contains("Settings · Pause · Replay · Quit"))
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
    })
  #expect(labels.contains { $0.stringValue.contains("Rounded coordinates + your public IP") })
  #expect(labels.contains { $0.stringValue.hasPrefix("Opening setup enables nothing") })
  #expect(labels.contains { $0.stringValue == "Online off by default" })
  #expect(
    labels.contains {
      $0.stringValue == "Advanced · Internet checks"
    })
  let setup = welcomeViews(root).compactMap { $0 as? NSButton }.filter {
    $0.title == "Set up…" || $0.title == "Review…"
  }
  #expect(setup.map(\.title) == ["Set up…", "Review…"])
  #expect(
    !welcomeViews(root).compactMap { $0 as? NSButton }.contains {
      $0.title.contains("Calendar")
    })
  for title in ["Set up…", "Review…"] {
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
  let previousIcon = NSApp.applicationIconImage
  NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/TinyStats.icns")
  defer { NSApp.applicationIconImage = previousIcon }
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
      if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
          root.cacheDisplay(in: root.bounds, to: bitmap)
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: directory.appendingPathComponent(
            "welcome-step-\(step + 1)-\(["greet", "menubar", "home", "online", "history", "ready"][step])-\(name).png"
          ))
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
  #expect(body.detachesHiddenViews)  // Home must remove the collapsed secondary row.
  controller.nextStep()
  #expect(!body.detachesHiddenViews)
}

/// Real laid-out content, not copy constants: no teaching label may need a second line.
@Test @MainActor func welcomeGraphicSequenceHasShortCopyAndAccessibleNavigation() throws {
  _ = NSApplication.shared
  for theme in [AppTheme.light, .dark] {
    var settings = Settings()
    settings.theme = theme
    for step in 0..<6 {
      let controller = WelcomeController(settings: { settings }, initialStep: step)
      defer { controller.close() }
      let root = try #require(controller.window?.contentView)
      root.layoutSubtreeIfNeeded()
      let body = try #require(root.subviews.compactMap { $0 as? NSStackView }.first)
      let visible = welcomeViews(body).filter { !$0.isHiddenOrHasHiddenAncestor }
      let copy = visible.compactMap { $0 as? NSTextField }
      #expect(
        copy.allSatisfy {
          $0.bounds.height <= ($0.stringValue == "Your Mac, at a glance." ? 24 : 20)
            && $0.stringValue.count <= 100
        })
      // At most one multi-sentence wrapping caption; formerly up to four long paragraphs.
      #expect(
        copy.filter {
          $0.cell?.wraps == true && $0.stringValue.components(separatedBy: ". ").count > 1
        }.count <= 1)
      let controls = welcomeViews(root).compactMap { $0 as? NSButton }
      for label in [
        "Skip welcome tour and keep current choices", "Previous welcome step",
        step == 5 ? "Finish welcome tour" : "Next welcome step",
      ] {
        #expect(controls.contains { $0.accessibilityLabel() == label })
      }
      #expect(controls.first { $0.title == "Back" }?.isEnabled == (step > 0))
      switch step {
      case 0:
        let hero = try #require(visible.compactMap { $0 as? WelcomeHeroView }.first)
        #expect(hero.bounds.height >= 240)
        #expect(
          hero.preview.renderers.flatMap(\.readouts).compactMap(\.module) == [
            .cpu, .memory, .network,
          ])
        let readings = hero.preview.renderers.flatMap(\.readouts)
        #expect(readings.map(\.value) == ["42%", "68%", "↑ 128 KB/s"])
        #expect(readings[2].secondary == "↓ 2.4 MB/s")
        #expect(copy.contains { $0.stringValue == "Example menu bar · Illustrative readings" })
        for child in welcomeViews(hero).dropFirst() {
          #expect(hero.bounds.contains(hero.convert(child.bounds, from: child)))
        }
        let nodes = try #require(hero.subviews.compactMap { $0 as? NSStackView }.first)
        let centers = nodes.arrangedSubviews.map { hero.convert($0.bounds, from: $0).midX }
        #expect(centers.count == 3)
        #expect(abs(centers[1] - hero.bounds.midX) < 1)
        #expect(abs((centers[1] - centers[0]) - (centers[2] - centers[1])) < 1)
        #expect(
          visible.compactMap { $0 as? NSImageView }.filter {
            $0.contentTintColor != .secondaryLabelColor
          }.count >= 3)
      case 1:
        #expect(visible.compactMap { $0 as? WelcomeReadoutButton }.count == 7)
        #expect(visible.contains { $0 is MenuBarPreviewView })
      case 2:
        #expect(visible.compactMap { $0 as? WelcomeTileView }.count >= 5)
      case 3:
        #expect(visible.contains { $0.identifier?.rawValue == "welcome-weather" })
        #expect(visible.contains { $0.identifier?.rawValue == "welcome-internet" })
      case 4:
        #expect(visible.compactMap { $0 as? WelcomeTileView }.count == 2)
      default:
        #expect(visible.compactMap { $0 as? WelcomeTileView }.count == 3)
      }
    }
  }
}

@Test @MainActor func welcomeLoginUsesSharedPreferencePathWithOwnedFixture() throws {
  _ = NSApplication.shared
  let controller = WelcomeController(settings: { Settings() }, initialStep: 5)
  defer { controller.close() }
  var enabled = false
  var changes: [Bool] = []
  controller.loginEnabled = { enabled }
  controller.setLoginEnabled = {
    enabled = $0
    changes.append($0)
    return "Fixture login preference updated."
  }
  controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  let root = try #require(controller.window?.contentView)
  let login = try #require(
    welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == "Launch at login" })
  #expect(login.state == .off)
  login.state = .on
  try welcomeActivate(login)
  #expect(changes == [true] && login.state == .on)
  enabled = false
  controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  #expect(login.state == .off && changes == [true])
}

@Test @MainActor func welcomeSolidAndLegacyTreatmentsKeepTheGraphicSequence() throws {
  _ = NSApplication.shared
  let previousIcon = NSApp.applicationIconImage
  NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/TinyStats.icns")
  defer { NSApp.applicationIconImage = previousIcon }
  for theme in [AppTheme.light, .dark] {
    for treatment in [GlassSurface.Treatment.solid, .legacy] {
      var settings = Settings()
      settings.theme = theme
      let controller = WelcomeController(
        settings: { settings },
        glassEnvironment: {
          .init(
            supportsGlass: treatment != .legacy, reduceTransparency: treatment == .solid,
            increaseContrast: false)
        })
      defer { controller.close() }
      let root = try #require(controller.window?.contentView)
      root.layoutSubtreeIfNeeded()
      #expect(welcomeViews(root).compactMap { $0 as? GlassSurface }.first?.treatment == treatment)
      #expect(welcomeViews(root).contains { $0 is WelcomeHeroView })
      #expect(controller.window?.isOpaque == true)
      #expect(controller.window?.backgroundColor == .windowBackgroundColor)
      guard treatment == .solid,
        let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"]
      else { continue }
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
      root.effectiveAppearance.performAsCurrentDrawingAppearance {
        root.cacheDisplay(in: root.bounds, to: bitmap)
      }
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: directory.appendingPathComponent("welcome-step-1-greet-solid-\(theme.rawValue).png"))
    }
  }
}

@Test @MainActor func welcomeReadoutToggleExposesCheckboxStateAndDisabledFocus() throws {
  let controller = WelcomeController(settings: { Settings() }, initialStep: 1)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let toggle = try #require(welcomeViews(root).compactMap { $0 as? WelcomeReadoutButton }.first)
  #expect(toggle.accessibilityRole() == .checkBox)
  for state in [NSControl.StateValue.off, .on] {
    toggle.state = state
    #expect((toggle.accessibilityValue() as? Int) == (state == .on ? 1 : 0))
  }
  toggle.isEnabled = false
  #expect(!toggle.acceptsFirstResponder)
  #expect(!toggle.isAccessibilityEnabled())
}

@Test @MainActor func welcomeCardsExposeGuidanceAndOnlineActionsAlign() throws {
  for step in [3, 5] {
    let controller = WelcomeController(settings: { Settings() }, initialStep: step)
    defer { controller.close() }
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    let cards = welcomeViews(root).compactMap { $0 as? WelcomeTileView }
    #expect(cards.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .group })
    #expect(
      cards.allSatisfy {
        $0.accessibilityLabel()?.isEmpty == false && $0.accessibilityHelp()?.isEmpty == false
      })
    if step == 3 {
      let internet = try #require(cards.first { $0.identifier?.rawValue == "welcome-internet" })
      #expect(internet.accessibilityHelp()?.contains("source IP") == true)
      #expect(
        welcomeViews(internet).compactMap { $0 as? NSTextField }.contains {
          $0.stringValue.contains("source IP")
        })
      let buttons = cards.flatMap { welcomeViews($0).compactMap { $0 as? NSButton } }
      #expect(buttons.count == 2)
      let frames = buttons.map { root.convert($0.bounds, from: $0) }
      #expect(abs(frames[0].minY - frames[1].minY) < 1)
      #expect(abs(cards[0].frame.height - cards[1].frame.height) < 1)
    } else {
      #expect(cards.first?.accessibilityHelp()?.contains("Show welcome tour") == true)
      #expect(
        welcomeViews(try #require(cards.first)).compactMap { $0 as? NSButton }.contains {
          $0.title == "Launch at login"
        })
    }
  }
}

@Test @MainActor func welcomeWindowOpacityFollowsTreatmentChanges() throws {
  var environment = GlassSurface.Environment(
    supportsGlass: true, reduceTransparency: false, increaseContrast: false)
  let controller = WelcomeController(settings: { Settings() }, glassEnvironment: { environment })
  defer { controller.close() }
  let root = try #require(controller.window?.contentView as? WelcomeBackgroundView)
  for treatment in [GlassSurface.Treatment.glass, .solid, .legacy, .glass] {
    environment.supportsGlass = treatment != .legacy
    environment.reduceTransparency = treatment == .solid
    root.systemStyleDidChange()
    #expect(controller.window?.isOpaque == (treatment != .glass))
    #expect(
      controller.window?.backgroundColor == (treatment == .glass ? .clear : .windowBackgroundColor))
  }
}
