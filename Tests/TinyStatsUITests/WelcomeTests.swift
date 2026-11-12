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
  for step in 1...5 {
    #expect(
      WelcomePresentation.previewInitialStep(
        arguments: ["TinyStats", "--preview-onboarding-step", String(step)]) == step - 1)
  }
  for suffix in [
    [], ["0"], ["6"], ["7"], ["-1"], ["bad"], ["1.5"], [String(repeating: "9", count: 100)],
  ] {
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
    for _ in 0..<4 { controller.nextStep() }
    #expect(controller.step == 4)
    controller.previousStep()
    #expect(controller.step == 3)
    controller.skipTour()
    #expect(settings == original && changes == 0)
  }
}

@Test @MainActor func welcomeNamesDefaultReadoutsAndPrivacyChoices() throws {
  let controller = WelcomeController(settings: { Settings() })
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let copy = welcomeViews(root).compactMap { ($0 as? NSTextField)?.stringValue }.joined(
    separator: "\n")
  for phrase in [
    "Your Mac, at a glance.", "Tiny footprint", "No analytics", "Local-only by default", "CPU",
    "Memory", "Network",
  ] {
    #expect(copy.contains(phrase))
  }
  #expect(!copy.contains("Tab / ⇧Tab") && !copy.contains("Replay anytime"))
}

/// Difference the actual 2× strip with/without its preview, then find each visible cell's
/// horizontal extent. No renderer-to-stage coordinate conversion participates in this oracle.
@MainActor private func welcomeDrawnReadoutCenters(_ hero: WelcomeHeroView) throws -> [CGFloat] {
  func raster() throws -> NSBitmapImageRep {
    let bitmap = try #require(hero.bitmapImageRepForCachingDisplay(in: hero.bounds))
    hero.effectiveAppearance.performAsCurrentDrawingAppearance {
      hero.cacheDisplay(in: hero.bounds, to: bitmap)
    }
    return bitmap
  }
  let visible = try raster()
  hero.magnifiedPreview.isHidden = true
  defer { hero.magnifiedPreview.isHidden = false }
  let hidden = try raster()
  let scale = CGFloat(visible.pixelsWide) / hero.bounds.width
  let top = Int((hero.bounds.height - hero.strip.maxY) * scale)
  let bottom = Int((hero.bounds.height - hero.strip.minY) * scale)
  var runs: [ClosedRange<Int>] = []
  for x in 0..<visible.pixelsWide {
    let changed = (top..<bottom).contains { y in
      guard let a = visible.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
        let b = hidden.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
      else { return false }
      return max(
        abs(a.alphaComponent - b.alphaComponent),
        abs(a.redComponent * a.alphaComponent - b.redComponent * b.alphaComponent),
        abs(a.greenComponent * a.alphaComponent - b.greenComponent * b.alphaComponent),
        abs(a.blueComponent * a.alphaComponent - b.blueComponent * b.alphaComponent)) > 0.01
    }
    if changed {
      if let last = runs.last, last.upperBound == x - 1 {
        runs[runs.count - 1] = last.lowerBound...x
      } else {
        runs.append(x...x)
      }
    }
  }
  return runs.map { CGFloat($0.lowerBound + $0.upperBound + 1) / (2 * scale) }
}

@Test @MainActor func welcomeSloganIsTheCentredHeadlineAboveMagnifiedMenuBar() throws {
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
      for step in [0, 1, 0] {
        root.layoutSubtreeIfNeeded()
        let labels = root.subviews.compactMap { $0 as? NSTextField }
        let heading = try #require(labels.first { $0.font?.pointSize == (step == 0 ? 34 : 24) })
        let greeting = try #require(labels.first { $0.stringValue == "Welcome to TinyStats" })
        #expect(greeting.isHidden == (step != 0))
        if step == 0 {
          #expect(heading.stringValue == "Your Mac, at a glance.")
          #expect(heading.alignment == .center && heading.textColor == .labelColor)
          #expect(heading.font == .systemFont(ofSize: 34, weight: .bold))
          #expect(greeting.font == .systemFont(ofSize: 15, weight: .medium))
          #expect(
            greeting.textColor
              == (treatment == .glass ? SystemStyle.glassSecondaryLabel : .secondaryLabelColor))
          #expect(34.0 / 15.0 > 2.2)
          #expect(heading.frame == NSRect(x: 30, y: 401, width: 660, height: 41))
          #expect(greeting.frame.minY > heading.frame.maxY)
          let hero = try #require(welcomeViews(root).compactMap { $0 as? WelcomeHeroView }.first)
          #expect(hero.bounds.height == 196)
          #expect(root.convert(hero.bounds, from: hero).maxY == 381)
          // Measure the drawn cell outlines, independently of the scroll/bounds conversion.
          let centers = try welcomeDrawnReadoutCenters(hero)
          let glyphs = hero.subviews.filter { $0.identifier != nil }.flatMap {
            $0.subviews.compactMap { $0 as? NSImageView }
          }
          #expect(centers.count == 3 && glyphs.count == 3)
          for (glyph, center) in zip(glyphs, centers) {
            #expect(abs(hero.convert(glyph.bounds, from: glyph).midX - center) <= 1)
          }
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
    #expect(
      readings.map(\.value)
        == settings.readouts.map {
          MenuBarStyleExample.readout(
            module: $0, style: settings.style(for: $0), settings: settings
          ).value
        })
    #expect(readings.allSatisfy { $0.value != "—" })
    #expect(readings.first { $0.module == .cpu }?.progress == 42)
    #expect(readings.map(\.style) == settings.readouts.map { settings.style(for: $0) })
    #expect(!settings.weather.enabled && !settings.connectivityChecks && !settings.publicIPChecks)
  }
  // Returning from Settings refreshes the fixture and preset selection without emitting edits.
  settings.styles[Module.cpu.rawValue] = .ring
  controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  #expect(presets.selectedSegment == 1)
  #expect(preview.renderers.first?.readouts.first { $0.module == .cpu }?.style == .ring)
}

@Test @MainActor func welcomeReadyRoutesOverviewAndSettingsAndSharesRealStatusMenuTitles() throws {
  let controller = WelcomeController(settings: { Settings() }, initialStep: 4)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let stage = try #require(welcomeViews(root).compactMap { $0 as? WelcomeReadyStageView }.first)
  #expect(stage.accessibilityLabel()?.contains("sidebar for every module") == true)
  #expect(WelcomeReadyStageView.menuTitles == StatusMenuTitles.tour)
  root.layoutSubtreeIfNeeded()
  #expect(abs(stage.bounds.maxX - stage.preview.frame.maxX - 44) <= 1)
  let native = MenuBarPreviewView()
  native.update(
    groups: WelcomeGraphic.examples(WelcomeGraphic.starterSettings), paused: false,
    height: NSStatusBar.system.thickness)
  #expect(stage.preview.renderers.map(\.frame) == native.renderers.map(\.frame))
  #expect(stage.preview.frame.width == native.preferredWidth)
  let menu = AppDelegate.makeStatusMenu(paused: false, target: nil)
  #expect(
    menu.items.filter { !$0.isSeparatorItem }.map(\.title) == WelcomeReadyStageView.menuTitles)
  #expect(
    AppDelegate.makeStatusMenu(paused: true, target: nil).items.first?.title
      == StatusMenuTitles.resume)
  var actions: [String] = []
  controller.onOverview = { actions.append("overview") }
  controller.onSettings = { actions.append("settings") }
  for title in ["Open Overview…", "Settings…"] {
    try welcomeActivate(
      try #require(welcomeViews(root).compactMap { $0 as? NSButton }.first { $0.title == title }))
  }
  #expect(actions == ["overview", "settings"])
}

@Test @MainActor func welcomeMoreReadoutsRoutesMenuBarSettingsWithoutChangingChoices() throws {
  var settings = Settings()
  settings.readouts.append(.gpu)
  let original = settings
  let controller = WelcomeController(settings: { settings }, initialStep: 1)
  defer { controller.close() }
  var opened = 0
  var changes = 0
  controller.onMenuBarSettings = { opened += 1 }
  controller.onMenuBarChange = { _ in changes += 1 }
  let root = try #require(controller.window?.contentView)
  let more = try #require(welcomeViews(root).compactMap { $0 as? WelcomeMoreReadoutsButton }.first)
  #expect(more.accessibilityLabel() == "More readouts in Menu Bar settings")
  try welcomeActivate(more)
  #expect(opened == 1 && changes == 0 && settings == original)
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
  let controller = WelcomeController(settings: { settings }, initialStep: 2)
  defer { controller.close() }
  var changes = 0
  controller.onHistoryPersistence = { enabled in
    changes += 1
    settings.persistHistory = enabled
    settings.save(to: store)
  }
  let root = try #require(controller.window?.contentView)
  let history = try #require(
    welcomeViews(root).compactMap { $0 as? SystemSettingSwitch }.first {
      $0.accessibilityLabel() == "Keep history between launches"
    })
  #expect(history.state == .on)
  history.state = .off
  try welcomeActivate(history)
  #expect(!Settings.load(from: store).persistHistory)
  #expect(history.accessibilityHelp()?.contains("Turning off keeps saved data") == true)
  #expect(
    welcomeViews(root).compactMap { $0 as? NSTextField }.contains {
      $0.stringValue == "History paused. Saved data stays until you clear it in History & Storage."
    })
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
  #expect(labels.contains { $0.stringValue == "Know what goes online" })
  #expect(
    labels.contains {
      $0.stringValue.contains("MET Norway · api.met.no")
    })
  #expect(
    welcomeViews(root).compactMap { $0 as? WelcomeTileView }.contains {
      $0.lines.contains("Sends rounded location and your IP")
    })
  let stage = try #require(welcomeViews(root).compactMap { $0 as? WelcomeOnlineStageView }.first)
  #expect(stage.weatherPill.text == "Off" && stage.internetPill.text == "Off")
  #expect(stage.accessibilityLabel()?.contains("Opening setup changes nothing") == true)
  #expect(
    labels.contains {
      $0.stringValue == "Internet checks"
    })
  let setup = welcomeViews(root).compactMap { $0 as? NSButton }.filter {
    $0.title == "Set Up Weather…" || $0.title == "Review Checks…"
  }
  #expect(setup.map(\.title) == ["Set Up Weather…", "Review Checks…"])
  #expect(
    !welcomeViews(root).compactMap { $0 as? NSButton }.contains {
      $0.title.contains("Calendar")
    })
  for title in ["Set Up Weather…", "Review Checks…"] {
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
    for step in 0..<5 {
      let controller = WelcomeController(settings: { settings }, initialStep: step)
      let root = try #require(controller.window?.contentView)
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
            "welcome-step-\(step + 1)-\(["greet", "menubar", "history", "online", "ready"][step])-\(name).png"
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
  #expect(!body.detachesHiddenViews)
  controller.nextStep()
  #expect(!body.detachesHiddenViews)
}

/// Real laid-out content, not copy constants: no teaching label may need a second line.
@Test @MainActor func welcomeGraphicSequenceHasShortCopyAndAccessibleNavigation() throws {
  for theme in [AppTheme.light, .dark] {
    var settings = Settings()
    settings.theme = theme
    for step in 0..<5 {
      let controller = WelcomeController(settings: { settings }, initialStep: step)
      defer { controller.close() }
      let root = try #require(controller.window?.contentView)
      root.layoutSubtreeIfNeeded()
      let body = try #require(root.subviews.compactMap { $0 as? NSStackView }.first)
      let visible = welcomeViews(root).filter { !$0.isHiddenOrHasHiddenAncestor }
      for label in visible.compactMap({ $0 as? NSTextField }) {
        #expect(
          label.bounds.height
            <= (label.stringValue == "Your Mac, at a glance."
              ? 44 : label.font?.pointSize == 24 ? 30 : 20))
        #expect(label.stringValue.count <= 100)
        #expect(
          label.bounds.width >= label.intrinsicContentSize.width - 1,
          "Clipped: \(label.stringValue)")
      }
      let controls = welcomeViews(root).compactMap { $0 as? NSButton }
      #expect(
        controls.contains {
          $0.accessibilityLabel() == (step == 4 ? "Finish welcome tour" : "Next welcome step")
            && $0.keyEquivalent == "\r"
        })
      #expect(controls.first { $0.title == "Back" }?.isHidden == (step == 0))
      #expect(controls.first { $0.title == "Skip" }?.isHidden == (step == 4))
      let progress = try #require(visible.compactMap { $0 as? WelcomeProgressDots }.first)
      #expect(progress.accessibilityLabel() == "Step \(step + 1) of 5")
      #expect(controller.stepAnnouncement.hasPrefix("Step \(step + 1) of 5, "))
      #expect(!body.detachesHiddenViews)
      let stage = try #require(body.arrangedSubviews.first as? WelcomeStageView)
      // §5.2 explicitly budgets ~164pt for Menu Bar to retain the full 52pt style grid.
      // This specific geometry takes precedence over §12's generic 45% stage-area target.
      if step != 1 { #expect(stage.bounds.height >= body.bounds.height * 0.45) }
      switch step {
      case 0:
        let hero = try #require(stage as? WelcomeHeroView)
        #expect(hero.bounds.height >= 196)
        let readings = hero.preview.renderers.flatMap(\.readouts)
        #expect(readings.compactMap(\.module) == [.cpu, .memory, .network])
        #expect(readings.map(\.value) == ["42%", "68%", "↑ 128 KB/s"])
        #expect(readings[2].secondary == "↓ 2.4 MB/s")
        #expect(stage.accessibilityLabel()?.contains("Example readings") == true)
        for child in welcomeViews(hero).dropFirst() {
          #expect(hero.bounds.contains(hero.convert(child.bounds, from: child)))
          #expect(!child.isAccessibilityElement())
        }
      case 1:
        let chips = visible.compactMap { $0 as? WelcomeReadoutButton }
        #expect(chips.count == 7)
        #expect(visible.compactMap { $0 as? WelcomeMoreReadoutsButton }.count == 1)
        #expect(chips.allSatisfy { abs($0.bounds.width - 159) < 1 && $0.bounds.height == 38 })
        #expect(visible.contains { $0 is MenuBarPreviewView })
      case 2:
        #expect(visible.compactMap { $0 as? WelcomeTileView }.count == 2)
        #expect(visible.contains { $0.identifier?.rawValue == "welcome-history" })
        #expect(visible.contains { $0.identifier?.rawValue == "welcome-notifications" })
      case 3:
        #expect(visible.contains { $0.identifier?.rawValue == "welcome-weather" })
        #expect(visible.contains { $0.identifier?.rawValue == "welcome-internet" })
      default:
        #expect(stage is WelcomeReadyStageView)
        #expect(visible.compactMap { $0 as? WelcomeTileView }.count == 1)
      }
    }
  }
}

@Test @MainActor func welcomeLoginUsesSharedPreferencePathWithOwnedFixture() throws {
  _ = NSApplication.shared
  let controller = WelcomeController(settings: { Settings() }, initialStep: 4)
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
    welcomeViews(root).compactMap { $0 as? SystemSettingSwitch }.first {
      $0.accessibilityLabel() == "Launch at login"
    })
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

@Test @MainActor func welcomeCardsExposeGuidanceAndActionsTrailTheirCards() throws {
  for step in [2, 3, 4] {
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
    for card in cards {
      if let button = card.actionButton {
        #expect(abs(button.frame.maxX - (card.bounds.width - 16)) < 1)
        #expect(abs(button.frame.minY - 14) < 1)
      }
    }
    if step == 3 {
      let internet = try #require(cards.first { $0.identifier?.rawValue == "welcome-internet" })
      #expect(internet.accessibilityHelp()?.contains("source IP") == true)
      #expect(internet.lines.contains("Each destination sees your IP"))
      #expect(cards[0].frame.height == cards[1].frame.height)
      #expect(cards[0].actionButton?.frame.minY == cards[1].actionButton?.frame.minY)
    } else if step == 4 {
      #expect(
        welcomeViews(root).contains {
          ($0 as? SystemSettingSwitch)?.accessibilityLabel() == "Launch at login"
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

@Test @MainActor func welcomeEnablingAChipRetargetsStyleWithoutChangingOnlineState() throws {
  var settings = Settings()
  let controller = WelcomeController(settings: { settings }, initialStep: 1)
  defer { controller.close() }
  controller.onMenuBarChange = { settings = $0 }
  let root = try #require(controller.window?.contentView)
  let chip = try #require(
    welcomeViews(root).compactMap { $0 as? WelcomeReadoutButton }.first { $0.module == .weather })
  let popup = try #require(welcomeViews(root).compactMap { $0 as? NSPopUpButton }.first)
  chip.state = .on
  try welcomeActivate(chip)
  #expect(popup.titleOfSelectedItem == Module.weather.title)
  chip.state = .off
  try welcomeActivate(chip)
  #expect(popup.titleOfSelectedItem == Module.weather.title)
  #expect(!settings.weather.enabled)
}

@Test @MainActor func welcomeOnlineReplayReflectsSavedStateWithoutWritingIt() throws {
  for online in [false, true] {
    var settings = Settings()
    if online {
      settings.weather = .currentLocationDefault
      settings.publicIPChecks = true
    }
    let original = settings
    let controller = WelcomeController(settings: { settings }, initialStep: 3)
    defer { controller.close() }
    let root = try #require(controller.window?.contentView)
    let stage = try #require(welcomeViews(root).compactMap { $0 as? WelcomeOnlineStageView }.first)
    #expect(stage.weatherPill.text == (online ? "On" : "Off"))
    #expect(stage.internetPill.text == (online ? "On" : "Off"))
    #expect(stage.weatherOn == online && stage.internetOn == online)
    var changes = 0
    controller.onMenuBarChange = { _ in changes += 1 }
    controller.onHistoryPersistence = { _ in changes += 1 }
    controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    #expect(settings == original && changes == 0)
    settings.weather.enabled.toggle()
    settings.publicIPChecks.toggle()
    controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    #expect(stage.weatherOn != online && stage.internetOn != online)
  }
}

@Test @MainActor func welcomeEscapeOnReadyClosesAndKeepsChoices() throws {
  let settings = Settings()
  let controller = WelcomeController(settings: { settings }, initialStep: 4)
  var changes = 0
  controller.onMenuBarChange = { _ in changes += 1 }
  controller.onHistoryPersistence = { _ in changes += 1 }
  controller.setLoginEnabled = { _ in
    changes += 1
    return "Unexpected"
  }
  var closed = false
  controller.onClose = { closed = true }
  controller.window?.cancelOperation(nil)
  #expect(closed && changes == 0)
}

@Test func welcomeHistoryFixturesAreBoundedAndDerivedFromStorageConstants() {
  #expect(WelcomeFixture.historyCPU.count == 56 && WelcomeFixture.historyMemory.count == 56)
  #expect(
    (WelcomeFixture.historyCPU + WelcomeFixture.historyMemory).allSatisfy { (0...100).contains($0) }
  )
  #expect(
    WelcomeFixture.historySize
      == String(format: "%.1f MiB", Double(SessionHistory.maximumCheckpointBytes) / 1_048_576))
}

@Test @MainActor func welcomeHistoryCardsRefreshSavedAlertsAndExposeTheExampleRule() throws {
  var settings = Settings()
  let controller = WelcomeController(settings: { settings }, initialStep: 2)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let card = try #require(
    welcomeViews(root).compactMap { $0 as? WelcomeTileView }.first { $0.rule })
  let badge = try #require(card.accessory as? WelcomeBadge)
  #expect(badge.text == "Off")
  #expect(card.captionLabel.stringValue == "Off until you turn them on and allow them")
  root.layoutSubtreeIfNeeded()
  let archive = try #require(
    welcomeViews(root).compactMap { $0 as? WelcomeTileView }.first {
      $0.identifier?.rawValue == "welcome-history"
    })
  let action = try #require(archive.actionButton)
  #expect(archive.bounds.height == 112)
  #expect(archive.captionLabel.frame.minY - action.frame.maxY <= 24)
  settings.alerts = true
  controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  #expect(badge.text == "On")
  #expect(card.captionLabel.stringValue == "On · Review rules and notification access")
  #expect(card.accessibilityHelp() == card.captionLabel.stringValue)
  settings.alerts = false
  controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
  #expect(badge.text == "Off")
  #expect(card.captionLabel.stringValue == "Off until you turn them on and allow them")
  #expect(
    card.accessibilityChildren()?.compactMap {
      ($0 as? NSAccessibilityElement)?.accessibilityLabel()
    }.contains("Example rule: CPU above 90% for 5 minutes") == true)
}

@Test @MainActor func welcomeEachInternetOptInIndependentlyLightsTheSavedStatePill() throws {
  for kind in 0..<3 {
    var settings = Settings()
    switch kind {
    case 0: settings.connectivityChecks = true
    case 1: settings.publicIPChecks = true
    default: settings.pingCheck.enabled = true
    }
    let original = settings
    let controller = WelcomeController(settings: { settings }, initialStep: 3)
    defer { controller.close() }
    let root = try #require(controller.window?.contentView)
    let stage = try #require(welcomeViews(root).compactMap { $0 as? WelcomeOnlineStageView }.first)
    #expect(stage.internetOn && stage.internetPill.text == "On")
    #expect(!stage.weatherOn && stage.weatherPill.text == "Off")
    #expect(settings == original)
  }
}

@Test @MainActor func welcomeOnlineShowsDistinctUpdateDefaultAndNoOverlappingCaption() throws {
  _ = NSApplication.shared
  for enabled in [true, false] {
    var updates = UpdatePresentation(eligible: true, canInstall: true)
    updates.preferences.automaticallyCheck = enabled
    let controller = WelcomeController(
      settings: { Settings() }, initialStep: 3, updates: { updates })
    defer { controller.close() }
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    let stage = try #require(welcomeViews(root).compactMap { $0 as? WelcomeOnlineStageView }.first)
    stage.layoutSubtreeIfNeeded()
    #expect(stage.updatesPill.text == (enabled ? "On" : "Off"))
    #expect(stage.updatesOn == enabled && !stage.weatherOn && !stage.internetOn)
    #expect(stage.updates.identifier?.rawValue == "welcome-updates")
    #expect(stage.promiseLabel.stringValue.count <= 100 && stage.promiseLabel.bounds.height <= 20)
    for tile in [stage.weather, stage.internet, stage.updates] {
      #expect(!tile.frame.intersects(stage.promiseLabel.frame))
      #expect(stage.bounds.contains(tile.frame))
    }
    #expect(!stage.weather.frame.intersects(stage.internet.frame))
    #expect(!stage.internet.frame.intersects(stage.updates.frame))
    #expect(stage.updates.accessibilityHelp()?.contains("Development builds never check") == true)
  }
}
