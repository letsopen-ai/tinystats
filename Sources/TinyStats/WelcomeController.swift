import AppKit
import TinyStatsCore

/// Separate from the settings payload so merely showing/skipping never writes feature choices.
enum WelcomePresentation {
  static let shownKey = "hasShownWelcome"

  static func shouldShow(in defaults: UserDefaults, arguments: [String], isolated: Bool) -> Bool {
    if arguments.contains("--preview-onboarding") { return isolated }
    guard !isolated, !arguments.contains(where: { $0.hasPrefix("--preview") }) else { return false }
    // Profiles predating the tour have settings but no welcome flag. Migrate silently.
    if defaults.object(forKey: shownKey) == nil, defaults.object(forKey: "settings") != nil {
      recordShown(in: defaults)
      return false
    }
    return !defaults.bool(forKey: shownKey)
  }

  /// Record normal launches before presentation, including a close/crash before Finish.
  /// Isolated previews leave both the flag and saved settings untouched.
  static func prepareLaunch(in defaults: UserDefaults, arguments: [String], isolated: Bool) -> Int?
  {
    guard shouldShow(in: defaults, arguments: arguments, isolated: isolated) else { return nil }
    if arguments.contains("--preview-onboarding") {
      return previewInitialStep(arguments: arguments)
    }
    recordShown(in: defaults)
    return 0
  }

  static func previewInitialStep(arguments: [String]) -> Int {
    guard let index = arguments.firstIndex(of: "--preview-onboarding-step"),
      index + 1 < arguments.count, let number = Int(arguments[index + 1]), (1...6).contains(number)
    else { return 0 }
    return number - 1
  }

  static func recordShown(in defaults: UserDefaults) { defaults.set(true, forKey: shownKey) }
}

@MainActor final class WelcomeController: NSWindowController, NSWindowDelegate {
  var currentSettings: () -> Settings
  var onMenuBarChange: ((Settings) -> Void)?
  var onHistoryPersistence: ((Bool) -> Void)?
  var onWeather: (() -> Void)?
  var onInternet: (() -> Void)?
  var onNotifications: (() -> Void)?
  var onHistory: (() -> Void)?
  var onSettings: (() -> Void)?
  var onOverview: (() -> Void)?
  var onMenuBarSettings: (() -> Void)?
  var onClose: (() -> Void)?
  // Injectable only for owned fixtures; production shares General settings’ ServiceManagement path.
  var loginEnabled: () -> Bool = { LoginItemPreference.enabled }
  var setLoginEnabled: (Bool) -> String = { LoginItemPreference.setEnabled($0) }
  private(set) var step: Int
  private let glassEnvironment: () -> GlassSurface.Environment
  private let heading = NSTextField(labelWithString: "")
  private let progress = NSTextField(labelWithString: "")
  private let body = NSStackView()
  private let back = NSButton(title: "Back", target: nil, action: nil)
  private let next = NSButton(title: "Next", target: nil, action: nil)
  private let skip = NSButton(title: "Skip", target: nil, action: nil)
  private let message = NSTextField(wrappingLabelWithString: "")
  private var readouts: [Module: NSButton] = [:]
  private var styles: [Module: MenuBarStylePicker] = [:]
  private var styleModule: Module = .cpu
  private let styleModuleSelector = NSPopUpButton()
  private var history: NSButton?
  private var login: NSButton?
  private var historyBusy = false
  private static let starterModules: [Module] = [
    .cpu, .memory, .network, .battery, .clock, .weather, .disks,
  ]
  private let presetSelector = MenuBarLayoutIcons.control()
  private var preview: MenuBarPreviewView?
  private var previewScroll: NSScrollView?
  // A fixed, empty fixture: unavailable readings stay unavailable, with no sampler demand.
  private let previewSnapshot = Snapshot()
  private var moreModulesExpanded = false
  private var moreModules: NSView?

  init(
    settings: @escaping () -> Settings, initialStep: Int = 0,
    glassEnvironment: @escaping () -> GlassSurface.Environment = { .current }
  ) {
    self.glassEnvironment = glassEnvironment
    currentSettings = settings
    step = min(5, max(0, initialStep))
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 720, height: 630),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Welcome to TinyStats"
    let glass = glassEnvironment().treatment == .glass
    window.backgroundColor = glass ? .clear : .windowBackgroundColor
    window.isOpaque = !glass
    window.contentView = WelcomeBackgroundView(
      frame: window.contentLayoutRect, environment: glassEnvironment)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    guard let root = window.contentView else { return }
    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.frame = .init(x: 30, y: 550, width: 64, height: 64)
    icon.setAccessibilityLabel("TinyStats")
    root.addSubview(icon)
    heading.font = .systemFont(ofSize: 24, weight: .semibold)
    heading.frame = .init(x: 110, y: 550, width: 580, height: 36)
    root.addSubview(heading)
    progress.font = .systemFont(ofSize: 12, weight: .medium)
    progress.textColor = .secondaryLabelColor
    progress.frame = .init(x: 110, y: 594, width: 580, height: 20)
    root.addSubview(progress)
    body.orientation = .vertical
    body.alignment = .leading
    body.spacing = 14
    body.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(body)
    NSLayoutConstraint.activate([
      body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
      body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
      body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
      body.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -100),
    ])
    for (button, x, action) in [
      (skip, 30, #selector(skipTour)), (back, 500, #selector(previousStep)),
      (next, 592, #selector(nextStep)),
    ] {
      button.bezelStyle = .rounded
      button.frame = .init(x: x, y: 20, width: 90, height: 32)
      button.target = self
      button.action = action
      root.addSubview(button)
    }
    next.keyEquivalent = "\r"
    back.keyEquivalent = "["
    back.keyEquivalentModifierMask = .command
    skip.keyEquivalent = "\u{1b}"
    skip.keyEquivalentModifierMask = []
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    message.frame = .init(x: 30, y: 59, width: 660, height: 32)
    root.addSubview(message)
    render()
    window.center()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func text(_ value: String, secondary: Bool = false) {
    let label = NSTextField(wrappingLabelWithString: value)
    label.font = .systemFont(ofSize: 13)
    if secondary { label.textColor = .secondaryLabelColor }
    body.addArrangedSubview(label)
    label.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
  }

  private func button(
    _ title: String, action: Selector, in container: NSStackView? = nil, symbol: String? = nil
  ) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(title)
    if let symbol {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.imagePosition = .imageLeading
    }
    (container ?? body).addArrangedSubview(button)
    return button
  }

  private func tile(
    _ title: String, _ caption: String, module: Module? = nil,
    symbol: String? = nil, large: Bool = false, compact: Bool = false
  ) -> WelcomeTileView {
    WelcomeTileView(
      title: title, caption: caption, symbol: symbol ?? module?.symbol ?? "square.grid.2x2",
      module: module, large: large, compact: compact, environment: glassEnvironment)
  }

  private func fullWidth(_ view: NSView, in container: NSStackView? = nil) {
    let container = container ?? body
    container.addArrangedSubview(view)
    view.widthAnchor.constraint(
      equalTo: container.widthAnchor,
      constant: -(container.edgeInsets.left + container.edgeInsets.right)
    ).isActive = true
  }

  private func row(_ views: [NSView], in container: NSStackView? = nil) {
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.spacing = 10
    row.distribution = .fillEqually
    row.alignment = .top
    fullWidth(row, in: container)
  }

  private func chips(_ values: [(String, String)]) {
    let views = values.map { title, symbol in
      let group = NSStackView(views: [
        WelcomeGraphic.glyph(symbol, size: 15),
        WelcomeGraphic.label(title, size: 11),
      ])
      group.spacing = 6
      group.setHuggingPriority(.required, for: .horizontal)
      return group
    }
    let strip = NSStackView(views: views)
    strip.spacing = 24
    strip.setHuggingPriority(.required, for: .horizontal)
    body.addArrangedSubview(strip)
  }

  private func render() {
    for view in body.arrangedSubviews {
      body.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    body.detachesHiddenViews = false
    body.spacing = 12
    readouts.removeAll()
    styles.removeAll()
    history = nil
    login = nil
    preview = nil
    previewScroll = nil
    moreModules = nil
    message.stringValue = "Choices take effect when changed. Skip keeps your current choices."
    let settings = currentSettings()
    window?.appearance = settings.theme.nativeAppearance
    progress.stringValue = "Step \(step + 1) of 6"
    back.isEnabled = step > 0
    next.title = step == 5 ? "Finish" : "Next"
    next.setAccessibilityLabel(step == 5 ? "Finish welcome tour" : "Next welcome step")
    back.setAccessibilityLabel("Previous welcome step")
    skip.setAccessibilityLabel("Skip welcome tour and keep current choices")
    switch step {
    case 0:
      heading.stringValue = "Welcome to TinyStats"
      text("Your Mac, at a glance.")
      fullWidth(WelcomeHeroView(environment: glassEnvironment))
      chips([
        ("Local-only by default", "internaldrive"),
        ("No account · No analytics", "person.crop.circle.badge.checkmark"),
        ("Tiny footprint", "leaf"),
      ])
      // Explicit keycaps avoid duplicated Return and ambiguous Space/Escape symbols.
      let keys = NSStackView()
      keys.spacing = 18
      keys.setHuggingPriority(.required, for: .horizontal)
      for (key, action) in [
        ("Tab / ⇧Tab", "Move"), ("Space", "Select"), ("Return", "Next"), ("Esc", "Skip"),
      ] {
        let cap = WelcomeKeycapView(key, environment: glassEnvironment)
        let pair = NSStackView(views: [
          cap, WelcomeGraphic.label(action, size: 11, secondary: true),
        ])
        pair.spacing = 5
        pair.setHuggingPriority(.required, for: .horizontal)
        keys.addArrangedSubview(pair)
      }
      body.addArrangedSubview(keys)
      text("Replay anytime: right-click a readout → Show welcome tour", secondary: true)
    case 1:
      heading.stringValue = "Make the menu bar yours"
      text("Choose your readouts · ⌘-drag menu bar items to reorder.")
      body.spacing = 6
      presetSelector.target = self
      presetSelector.action = #selector(presetChanged)
      presetSelector.setAccessibilityLabel("Menu bar layout")
      let layout = WelcomeSectionView(
        label: "Menu bar preview and layout", environment: glassEnvironment)
      let preview = MenuBarPreviewView(frame: .zero)
      let scroll = NSScrollView()
      scroll.documentView = preview
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      scroll.drawsBackground = false
      scroll.setAccessibilityLabel("Combined menu bar preview; unavailable readings shown as dash")
      let layoutRow = NSStackView(views: [scroll, presetSelector])
      layoutRow.spacing = 12
      layoutRow.alignment = .centerY
      fullWidth(layoutRow, in: layout)
      scroll.heightAnchor.constraint(equalToConstant: 44).isActive = true
      fullWidth(layout)
      self.preview = preview
      previewScroll = scroll
      let readoutSection = WelcomeSectionView(label: "Readouts", environment: glassEnvironment)
      var checks: [NSView] = []
      for module in Self.starterModules {
        let check = WelcomeReadoutButton(
          module: module, target: self, action: #selector(menuChanged),
          environment: glassEnvironment)
        check.state = settings.readouts.contains(module) ? .on : .off
        check.setAccessibilityLabel("Show \(module.title) in menu bar")
        readouts[module] = check
        checks.append(check)
      }
      for start in stride(from: 0, to: checks.count, by: 4) {
        row(Array(checks[start..<min(start + 4, checks.count)]), in: readoutSection)
      }
      readoutSection.addArrangedSubview(
        WelcomeGraphic.label(
          "Showing Weather does not enable forecasts.", size: 11, secondary: true))
      fullWidth(readoutSection)
      styleModuleSelector.removeAllItems()
      styleModuleSelector.addItems(withTitles: Self.starterModules.map(\.title))
      styleModuleSelector.selectItem(withTitle: styleModule.title)
      styleModuleSelector.setAccessibilityLabel("Welcome readout to customize")
      styleModuleSelector.target = self
      styleModuleSelector.action = #selector(styleModuleChanged)
      body.addArrangedSubview(
        SystemSettingsForm.controls([SystemSettingsForm.text("Display style"), styleModuleSelector])
      )
      body.detachesHiddenViews = true
      for module in Self.starterModules {
        let picker = MenuBarStylePicker(module: module, settings: settings)
        picker.target = self
        picker.action = #selector(menuChanged)
        picker.isHidden = module != styleModule
        body.addArrangedSubview(picker)
        let width = picker.widthAnchor.constraint(equalTo: body.widthAnchor)
        width.identifier = "welcome-style-width"
        width.isActive = true
        styles[module] = picker
      }
      updatePreview(settings)
    case 2:
      heading.stringValue = "A home for every reading"
      body.spacing = 8
      row([
        tile("Overview", "Your Mac in one view", symbol: "square.grid.2x2"),
        tile("CPU & GPU", "Activity & top apps", module: .cpu),
      ])
      row([
        tile("Memory", "Pressure & app usage", module: .memory),
        tile("Disks & Network", "Storage & traffic", module: .network),
      ])
      row([
        tile("Power & Time", "Battery, calendar & clocks", module: .battery),
        tile("Weather · Optional", "Forecasts after opt-in", module: .weather),
      ])
      body.detachesHiddenViews = true
      let sensors = tile(
        "Advanced · Sensors", "Read-only · Availability varies by Mac", module: .sensors,
        compact: true)
      sensors.setAccessibilityHelp(
        "Read-only temperatures, fans and electrical readings. Hardware varies; missing readings stay unavailable."
      )
      let disclosure = button("More modules…", action: #selector(toggleMoreModules), in: sensors)
      disclosure.image = NSImage(
        systemSymbolName: moreModulesExpanded ? "chevron.down" : "chevron.right",
        accessibilityDescription: nil)
      disclosure.imagePosition = .imageLeading
      disclosure.state = moreModulesExpanded ? .on : .off
      disclosure.setAccessibilityExpanded(moreModulesExpanded)
      fullWidth(sensors)
      let secondary = NSStackView(views: [
        tile("History", "Charts & CSV", symbol: "clock.arrow.circlepath", compact: true),
        tile("All readings", "Raw SMC keys · Read-only", module: .sensors, compact: true),
      ])
      secondary.distribution = .fillEqually
      secondary.spacing = 10
      secondary.identifier = .init("welcome-more-modules")
      fullWidth(secondary)
      secondary.isHidden = !moreModulesExpanded
      moreModules = secondary
      _ = button("Open Overview…", action: #selector(openOverview), symbol: "square.grid.2x2")
    case 3:
      heading.stringValue = "Online only when you choose"
      chips([("Local first", "internaldrive"), ("Online off by default", "network.slash")])
      let weather = tile(
        "Weather", "MET Norway (api.met.no) · Optional", module: .weather, large: true)
      weather.identifier = .init("welcome-weather")
      for line in [
        "Rounded coordinates + your public IP",
        "Choose a city or allow location in setup",
        "Opening setup enables nothing",
      ] {
        weather.addArrangedSubview(WelcomeGraphic.label(line, size: 11, secondary: true))
      }
      _ = button("Set up…", action: #selector(openWeather), in: weather, symbol: "sun.max")
      weather.arrangedSubviews.last?.setAccessibilityLabel("Set up Weather")
      weather.setAccessibilityHelp(
        "Off until opt-in. Choose a city or allow location in setup. When enabled, MET Norway receives rounded coordinates and your public IP. Opening setup enables nothing. Saved choices stay yours."
      )
      let internet = tile(
        "Advanced · Internet checks", "Apple / your URL · ipify · ping address",
        module: .network, large: true)
      internet.identifier = .init("welcome-internet")
      for line in [
        "Each destination sees your source IP",
        "Review destinations & cadence before opt-in",
        "Opening setup enables nothing",
      ] {
        internet.addArrangedSubview(WelcomeGraphic.label(line, size: 11, secondary: true))
      }
      _ = button("Review…", action: #selector(openInternet), in: internet, symbol: "arrow.up.right")
      internet.arrangedSubviews.last?.setAccessibilityLabel("Internet checks")
      internet.setAccessibilityHelp(
        "Off by default. HTTPS uses Apple’s preset or your URL; public IP uses ipify; ping uses your numeric address. Each destination sees your source IP. Review destinations and cadence before enabling. Existing online choices are preserved."
      )
      row([weather, internet])
      weather.heightAnchor.constraint(equalTo: internet.heightAnchor).isActive = true
    case 4:
      heading.stringValue = "Keep history. Choose your alerts."
      let archive = tile(
        "History", "On by default · Local to this Mac", symbol: "clock.arrow.circlepath",
        large: true)
      archive.identifier = .init("welcome-history")
      archive.addArrangedSubview(WelcomeGraphic.label("28 days · ≤8.2 MiB", size: 13))
      let check = NSButton(
        checkboxWithTitle: "Keep history between launches", target: self,
        action: #selector(historyChanged))
      check.setAccessibilityLabel("Keep history between launches")
      archive.addArrangedSubview(check)
      history = check
      refreshHistoryControl()
      archive.addArrangedSubview(
        WelcomeGraphic.label("Off keeps the file. Clear it in History.", size: 11, secondary: true))
      _ = button(
        "History & storage…", action: #selector(openHistory), in: archive, symbol: "internaldrive")
      let alerts = tile(
        "Notifications", "Off until you enable & allow", symbol: "bell.badge", large: true)
      alerts.identifier = .init("welcome-notifications")
      alerts.addArrangedSubview(WelcomeGraphic.label("Your rules. Your thresholds.", size: 13))
      alerts.addArrangedSubview(
        WelcomeGraphic.label(
          "Editing rules alone does not enable alerts.", size: 11, secondary: true))
      _ = button(
        "Notifications & alert rules…", action: #selector(openNotifications), in: alerts,
        symbol: "bell")
      row([archive, alerts])
    default:
      heading.stringValue = "Ready when you are"
      let ready = tile(
        "Make yourself at home", "Your readings are one click away", symbol: "checkmark.circle")
      let check = NSButton(
        checkboxWithTitle: "Launch at login", target: self, action: #selector(loginChanged))
      check.state = loginEnabled() ? .on : .off
      check.setAccessibilityLabel("Launch at login")
      let loginChoice = NSStackView(views: [
        check,
        WelcomeGraphic.label("Login Items may need macOS approval.", size: 11, secondary: true),
      ])
      loginChoice.orientation = .vertical
      loginChoice.alignment = .leading
      loginChoice.spacing = 5
      ready.addArrangedSubview(loginChoice)
      login = check
      fullWidth(ready)
      row([
        tile("Click a readout", "Open its details", symbol: "cursorarrow.click"),
        tile(
          "Right-click a readout", "Settings · Pause · Replay · Quit",
          symbol: "cursorarrow.and.square.on.square.dashed"),
      ])
      let actions = NSStackView()
      actions.spacing = 12
      _ = button(
        "Open Menu Bar settings…", action: #selector(openMenuBarSettings), in: actions,
        symbol: "menubar.rectangle")
      _ = button(
        "Open Settings…", action: #selector(openSettings), in: actions, symbol: "gearshape")
      body.addArrangedSubview(actions)
      ready.setAccessibilityHelp(
        "Right-click a readout and choose Show welcome tour to replay. General settings: appearance, cadence, history and notifications. Menu Bar: readouts, styles and fonts. Weather and Network: optional online controls."
      )
    }
    (window?.contentView as? WelcomeBackgroundView)?.systemStyleDidChange()
    window?.recalculateKeyViewLoop()
    window?.makeFirstResponder(next)
    NSAccessibility.post(element: heading, notification: .layoutChanged)
  }

  @objc func nextStep() {
    if step == 5 {
      close()
    } else {
      step += 1
      render()
    }
  }
  @objc func previousStep() {
    if step > 0 {
      step -= 1
      render()
    }
  }
  @objc func skipTour() { close() }
  func windowWillClose(_ notification: Notification) { onClose?() }
  func windowDidBecomeKey(_ notification: Notification) {
    refreshHistoryControl()
    let settings = currentSettings()
    for (module, check) in readouts {
      check.state = settings.readouts.contains(module) ? .on : .off
    }
    for popup in styles.values { popup.update(settings: settings) }
    updatePreview(settings)
    login?.state = loginEnabled() ? .on : .off
    window?.appearance = settings.theme.nativeAppearance
  }
  func setHistoryBusy(_ busy: Bool) {
    historyBusy = busy
    refreshHistoryControl()
  }
  private func refreshHistoryControl() {
    history?.state = currentSettings().persistHistory ? .on : .off
    history?.isEnabled = !historyBusy
  }
  @objc private func styleModuleChanged() {
    guard Self.starterModules.indices.contains(styleModuleSelector.indexOfSelectedItem) else {
      return
    }
    styleModule = Self.starterModules[styleModuleSelector.indexOfSelectedItem]
    for (module, picker) in styles { picker.isHidden = module != styleModule }
    if let picker = styles[styleModule],
      !body.constraints.contains(where: {
        $0.identifier == "welcome-style-width" && $0.firstItem as? NSView === picker
      })
    {
      let width = picker.widthAnchor.constraint(equalTo: body.widthAnchor)
      width.identifier = "welcome-style-width"
      width.isActive = true
    }
  }
  @objc private func menuChanged() {
    var settings = currentSettings()
    // Starter controls must not remove advanced readouts saved in Settings.
    let chosen =
      settings.readouts.filter { readouts[$0] == nil }
      + Self.starterModules.filter { readouts[$0]?.state == .on }
    guard !chosen.isEmpty else {
      for module in settings.readouts { readouts[module]?.state = .on }
      message.stringValue = "Keep at least one readout enabled so TinyStats stays accessible."
      return
    }
    settings.readouts =
      settings.readouts.filter { chosen.contains($0) }
      + chosen.filter { !settings.readouts.contains($0) }
    for (module, popup) in styles {
      settings.styles[module.rawValue] =
        MenuBarStyle.available(for: module, sensorKey: settings.sensorKey).first {
          $0.title == popup.titleOfSelectedItem
        } ?? settings.style(for: module)
    }
    settings.validate()
    onMenuBarChange?(settings)
    updatePreview(settings)
    message.stringValue = "Menu bar choices saved."
  }
  @objc private func presetChanged() {
    guard (0...1).contains(presetSelector.selectedSegment) else { return }
    var settings = currentSettings()
    settings.separateItems = presetSelector.selectedSegment == 0
    settings.validate()
    onMenuBarChange?(settings)
    for (module, popup) in styles {
      popup.selectItem(withTitle: settings.style(for: module).title)
    }
    updatePreview(settings)
  }

  private func updatePreview(_ settings: Settings) {
    for picker in styles.values { picker.update(settings: settings) }
    guard let preview, let scroll = previewScroll else { return }
    presetSelector.selectedSegment = settings.separateItems ? 0 : 1
    let groups = settings.readouts.map {
      MenuBarReadout.makeAll(module: $0, snapshot: previewSnapshot, settings: settings, history: [])
    }
    let height = NSStatusBar.system.thickness
    preview.update(
      groups: settings.separateItems ? groups : [groups.flatMap { $0 }], paused: false,
      height: height)
    preview.frame.size = .init(width: max(660, preview.preferredWidth), height: max(36, height))
    scroll.needsDisplay = true
  }

  @objc private func toggleMoreModules(_ sender: NSButton) {
    moreModulesExpanded.toggle()
    moreModules?.isHidden = !moreModulesExpanded
    sender.state = moreModulesExpanded ? .on : .off
    sender.image = NSImage(
      systemSymbolName: moreModulesExpanded ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil)
    sender.setAccessibilityExpanded(moreModulesExpanded)
  }

  @objc private func historyChanged() {
    guard !historyBusy else {
      refreshHistoryControl()
      return
    }
    onHistoryPersistence?(history?.state == .on)
    refreshHistoryControl()
  }
  @objc private func loginChanged() {
    message.stringValue = setLoginEnabled(login?.state == .on)
    login?.state = loginEnabled() ? .on : .off
  }
  @objc private func openWeather() { onWeather?() }
  @objc private func openInternet() { onInternet?() }
  @objc private func openNotifications() { onNotifications?() }
  @objc private func openHistory() { onHistory?() }
  @objc private func openSettings() { onSettings?() }
  @objc private func openOverview() { onOverview?() }
  @objc private func openMenuBarSettings() { onMenuBarSettings?() }
}
