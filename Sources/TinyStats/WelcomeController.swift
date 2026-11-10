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
      index + 1 < arguments.count, let number = Int(arguments[index + 1]), (1...5).contains(number)
    else { return 0 }
    return number - 1
  }

  static func recordShown(in defaults: UserDefaults) { defaults.set(true, forKey: shownKey) }
}

/// Escape remains available when the last step hides Skip.
@MainActor final class WelcomeWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) { close() }
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
  var loginEnabled: () -> Bool = { LoginItemPreference.enabled }
  var setLoginEnabled: (Bool) -> String = { LoginItemPreference.setEnabled($0) }
  private(set) var step: Int
  private(set) var stepAnnouncement = ""
  private let glassEnvironment: () -> GlassSurface.Environment
  private let heading = NSTextField(labelWithString: "")
  private let greeting = WelcomeGraphic.label("Welcome to TinyStats", size: 15, secondary: true)
  private let icon = NSImageView()
  private let progress = WelcomeProgressDots()
  private let body = NSStackView()
  private var bodyTop: NSLayoutConstraint!
  private var bodyBottom: NSLayoutConstraint!
  private let back = NSButton(title: "Back", target: nil, action: nil)
  private let next = NSButton(title: "Next", target: nil, action: nil)
  private let skip = NSButton(title: "Skip", target: nil, action: nil)
  private let message = WelcomeGraphic.label("", size: 11, secondary: true)
  private var readouts: [Module: NSButton] = [:]
  private var styles: [Module: MenuBarStylePicker] = [:]
  private var styleModule: Module = .cpu
  private let styleModuleSelector = NSPopUpButton()
  private var history: SystemSettingSwitch?
  private var login: SystemSettingSwitch?
  private var historyBusy = false
  private var menuStage: WelcomeMenuBarStageView?
  private var onlineStage: WelcomeOnlineStageView?
  private var alertsCard: WelcomeTileView?
  private static let starterModules: [Module] = [
    .cpu, .memory, .network, .battery, .clock, .weather, .disks,
  ]
  private let presetSelector = MenuBarLayoutIcons.control()

  init(
    settings: @escaping () -> Settings, initialStep: Int = 0,
    glassEnvironment: @escaping () -> GlassSurface.Environment = { .current }
  ) {
    self.glassEnvironment = glassEnvironment
    currentSettings = settings
    step = min(4, max(0, initialStep))
    let window = WelcomeWindow(
      contentRect: .init(x: 0, y: 0, width: 720, height: 630),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Welcome to TinyStats"
    window.contentView = WelcomeBackgroundView(
      frame: window.contentLayoutRect, environment: glassEnvironment)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    guard let root = window.contentView else { return }
    icon.image = NSApp.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.frame = .init(x: 320, y: 476, width: 80, height: 80)
    icon.setAccessibilityLabel("TinyStats")
    icon.setAccessibilityElement(false)
    root.addSubview(icon)
    root.addSubview(heading)
    greeting.font = .systemFont(ofSize: 15, weight: .medium)
    greeting.alignment = .center
    greeting.frame = .init(x: 30, y: 445, width: 660, height: 19)
    root.addSubview(greeting)
    body.orientation = .vertical
    body.alignment = .leading
    body.spacing = 16
    body.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(body)
    bodyTop = body.topAnchor.constraint(equalTo: root.topAnchor, constant: 80)
    bodyBottom = body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -104)
    NSLayoutConstraint.activate([
      body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
      body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30), bodyTop,
      bodyBottom,
    ])
    for (button, action, shortcut) in [
      (skip, #selector(skipTour), "Esc"), (back, #selector(previousStep), "⌘["),
      (next, #selector(nextStep), "Return"),
    ] {
      button.bezelStyle = .rounded
      button.target = self
      button.action = action
      button.toolTip = shortcut
      button.setAccessibilityHelp(shortcut)
      root.addSubview(button)
    }
    next.keyEquivalent = "\r"
    next.keyEquivalentModifierMask = []
    window.defaultButtonCell = next.cell as? NSButtonCell
    back.keyEquivalent = "["
    back.keyEquivalentModifierMask = .command
    skip.keyEquivalent = "\u{1b}"
    skip.keyEquivalentModifierMask = []
    skip.frame = .init(x: 30, y: 20, width: 96, height: 32)
    progress.frame = .init(x: 315, y: 20, width: 90, height: 32)
    root.addSubview(progress)
    message.frame = .init(x: 30, y: 65, width: 420, height: 14)
    root.addSubview(message)
    render()
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func button(_ title: String, action: Selector, symbol: String) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.setAccessibilityLabel(title)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    return button
  }
  private func fullWidth(_ view: NSView, in container: NSStackView? = nil) {
    let container = container ?? body
    container.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
  }
  private func render() {
    for view in body.arrangedSubviews {
      body.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    body.detachesHiddenViews = false
    readouts.removeAll()
    styles.removeAll()
    history = nil
    login = nil
    menuStage = nil
    onlineStage = nil
    alertsCard = nil
    bodyTop.constant = step == 0 ? 249 : 80
    bodyBottom.constant = step == 0 ? -145 : -104
    icon.isHidden = step != 0
    greeting.isHidden = step != 0
    heading.font = .systemFont(ofSize: step == 0 ? 34 : 24, weight: step == 0 ? .bold : .semibold)
    heading.textColor = .labelColor
    heading.alignment = step == 0 ? .center : .left
    heading.frame =
      step == 0
      ? .init(x: 30, y: 401, width: 660, height: 41)
      : .init(x: 30, y: 572, width: 560, height: 30)
    let titles = [
      "Your Mac, at a glance.", "Make the menu bar yours", "History stays on this Mac",
      "Online only when you choose", "Ready when you are",
    ]
    heading.stringValue = titles[step]
    message.stringValue =
      step == 0 || step == 3
      ? ""
      : step == 4
        ? "Changes apply right away." : "Changes apply right away. Skip keeps them."
    progress.step = step
    back.isHidden = step == 0
    back.isEnabled = step > 0
    skip.isHidden = step == 4
    next.title = step == 0 ? "Get Started" : step == 4 ? "Finish" : "Next"
    let width: CGFloat = step == 0 ? 112 : 96
    next.frame = .init(x: 690 - width, y: 20, width: width, height: 32)
    back.frame = .init(x: next.frame.minX - 106, y: 20, width: 96, height: 32)
    next.setAccessibilityLabel(step == 4 ? "Finish welcome tour" : "Next welcome step")
    back.setAccessibilityLabel("Previous welcome step")
    skip.setAccessibilityLabel("Skip welcome tour and keep current choices")
    let settings = currentSettings()
    window?.appearance = settings.theme.nativeAppearance
    switch step {
    case 0:
      fullWidth(WelcomeHeroView(environment: glassEnvironment))
      let chips = NSStackView(views: [
        trustChip("Local-only by default", "internaldrive"),
        trustChip("No account · No analytics", "person.crop.circle.badge.checkmark"),
        trustChip("Tiny footprint", "leaf"),
      ])
      chips.spacing = 28
      let holder = NSView()
      chips.translatesAutoresizingMaskIntoConstraints = false
      holder.addSubview(chips)
      NSLayoutConstraint.activate([
        holder.heightAnchor.constraint(equalToConstant: 20),
        chips.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
        chips.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
      ])
      fullWidth(holder)
      body.setCustomSpacing(20, after: body.arrangedSubviews[0])
    case 1: renderMenuBar(settings)
    case 2: renderHistory(settings)
    case 3:
      let stage = WelcomeOnlineStageView(settings: settings, environment: glassEnvironment)
      stage.weather.actionButton = button(
        "Set Up Weather…", action: #selector(openWeather), symbol: "slider.horizontal.3")
      stage.weather.actionButton?.setAccessibilityLabel("Set up Weather")
      stage.internet.actionButton = button(
        "Review Checks…", action: #selector(openInternet), symbol: "slider.horizontal.3")
      stage.internet.actionButton?.setAccessibilityLabel("Review Internet checks")
      fullWidth(stage)
      onlineStage = stage
    default:
      let stage = WelcomeReadyStageView(environment: glassEnvironment)
      stage.overviewButton = button(
        "Open Overview…", action: #selector(openOverview), symbol: "square.grid.2x2")
      stage.settingsButton = button(
        "Settings…", action: #selector(openSettings), symbol: "gearshape")
      fullWidth(stage)
      let check = SystemSettingSwitch(
        title: "Launch at login", target: self, action: #selector(loginChanged))
      check.state = loginEnabled() ? .on : .off
      login = check
      let card = WelcomeTileView(
        title: "Launch at login", caption: "Login Items may need macOS approval", symbol: "power",
        height: 60, environment: glassEnvironment)
      card.accessory = check
      fullWidth(card)
    }
    (window?.contentView as? WelcomeBackgroundView)?.systemStyleDidChange()
    window?.recalculateKeyViewLoop()
    window?.makeFirstResponder(next)
    NSAccessibility.post(element: heading, notification: .layoutChanged)
    stepAnnouncement = "Step \(step + 1) of 5, \(heading.stringValue)"
    if let window {
      NSAccessibility.post(
        element: window, notification: .announcementRequested,
        userInfo: [
          .announcement: stepAnnouncement, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
  }
  private func trustChip(_ title: String, _ symbol: String) -> NSView {
    let row = NSStackView(views: [
      WelcomeGraphic.glyph(symbol, size: 15),
      WelcomeGraphic.label(title, size: 12, secondary: true),
    ])
    row.spacing = 6
    return row
  }
  private func renderMenuBar(_ settings: Settings) {
    presetSelector.target = self
    presetSelector.action = #selector(presetChanged)
    presetSelector.setAccessibilityLabel("Menu bar layout")
    let stage = WelcomeMenuBarStageView(environment: glassEnvironment)
    stage.layoutControl = presetSelector
    fullWidth(stage)
    menuStage = stage
    let controls = NSStackView()
    controls.orientation = .vertical
    controls.alignment = .leading
    controls.spacing = 8
    controls.detachesHiddenViews = true
    var chips: [NSView] = []
    for module in Self.starterModules {
      let chip = WelcomeReadoutButton(
        module: module, target: self, action: #selector(menuChanged), environment: glassEnvironment)
      chip.state = settings.readouts.contains(module) ? .on : .off
      readouts[module] = chip
      chips.append(chip)
    }
    let more = WelcomeMoreReadoutsButton(
      title: "More readouts…", target: self, action: #selector(openMenuBarSettings))
    chips.append(more)
    for start in [0, 4] {
      let row = NSStackView(views: Array(chips[start..<start + 4]))
      row.spacing = 8
      for chip in row.arrangedSubviews {
        chip.widthAnchor.constraint(equalToConstant: 159).isActive = true
      }
      fullWidth(row, in: controls)
    }
    let note = NSStackView(views: [
      WelcomeGraphic.glyph("lock", size: 12),
      WelcomeGraphic.label(
        "Showing Weather does not turn on forecasts.", size: 11, secondary: true),
    ])
    note.spacing = 6
    controls.addArrangedSubview(note)
    styleModuleSelector.removeAllItems()
    styleModuleSelector.addItems(withTitles: Self.starterModules.map(\.title))
    for (item, module) in zip(styleModuleSelector.itemArray, Self.starterModules) {
      item.image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(
          .init(pointSize: 14, weight: .regular).applying(
            .init(paletteColors: [SystemStyle.moduleAccent(module)])))
    }
    styleModuleSelector.selectItem(withTitle: styleModule.title)
    styleModuleSelector.setAccessibilityLabel("Welcome readout to customize")
    styleModuleSelector.target = self
    styleModuleSelector.action = #selector(styleModuleChanged)
    controls.addArrangedSubview(
      NSStackView(views: [WelcomeGraphic.label("Style for", size: 13), styleModuleSelector]))
    for module in Self.starterModules {
      let picker = MenuBarStylePicker(
        module: module, settings: settings, tileHeight: 52, welcomeEnvironment: glassEnvironment)
      picker.target = self
      picker.action = #selector(menuChanged)
      fullWidth(picker, in: controls)
      picker.isHidden = module != styleModule
      styles[module] = picker
    }
    fullWidth(controls)
    updatePreview(settings)
  }
  private func renderHistory(_ settings: Settings) {
    fullWidth(WelcomeHistoryStageView(environment: glassEnvironment))
    let archive = WelcomeTileView(
      title: "Keep history",
      caption: "On by default · \(HistoryRange.fourWeeks.title), only on this Mac",
      symbol: "clock.arrow.circlepath", height: 112, environment: glassEnvironment)
    archive.identifier = .init("welcome-history")
    let check = SystemSettingSwitch(
      title: "Keep history between launches", target: self, action: #selector(historyChanged))
    check.setAccessibilityHelp("Turning off keeps saved data. Clear it in History & Storage.")
    history = check
    refreshHistoryControl()
    archive.accessory = check
    archive.actionButton = button(
      "History & Storage…", action: #selector(openHistory), symbol: "internaldrive")
    let alerts = WelcomeTileView(
      title: "Alerts", caption: Self.alertsCaption(settings), symbol: "bell.badge",
      height: 168, environment: glassEnvironment)
    alerts.identifier = .init("welcome-notifications")
    let badge = WelcomeBadge(settings.alerts ? "On" : "Off")
    alerts.accessory = badge
    alertsCard = alerts
    alerts.rule = true
    alerts.actionButton = button(
      "Alert Rules…", action: #selector(openNotifications), symbol: "bell")
    alerts.actionButton?.setAccessibilityHelp("Editing rules alone does not turn on alerts.")
    let row = NSStackView(views: [archive, alerts])
    row.spacing = 10
    row.alignment = .top
    row.distribution = .fillEqually
    fullWidth(row)
  }
  private static func alertsCaption(_ settings: Settings) -> String {
    settings.alerts
      ? "On · Review rules and notification access"
      : "Off until you turn them on and allow them"
  }
  @objc func nextStep() {
    if step == 4 {
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
    updatePreview(settings)
    onlineStage?.update(settings)
    (alertsCard?.accessory as? WelcomeBadge)?.text = settings.alerts ? "On" : "Off"
    alertsCard?.captionLabel.stringValue = Self.alertsCaption(settings)
    alertsCard?.setAccessibilityHelp(Self.alertsCaption(settings))
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
  }
  @objc private func menuChanged(_ sender: NSControl) {
    var settings = currentSettings()
    let chosen =
      settings.readouts.filter { readouts[$0] == nil }
      + Self.starterModules.filter { readouts[$0]?.state == .on }
    guard !chosen.isEmpty else {
      for module in settings.readouts { readouts[module]?.state = .on }
      message.stringValue = "Keep at least one readout enabled so TinyStats stays accessible."
      return
    }
    if let chip = sender as? WelcomeReadoutButton, chip.state == .on {
      styleModuleSelector.selectItem(withTitle: chip.module.title)
      styleModuleChanged()
    }
    settings.readouts =
      settings.readouts.filter { chosen.contains($0) }
      + chosen.filter { !settings.readouts.contains($0) }
    for (module, picker) in styles {
      settings.styles[module.rawValue] = picker.selectedStyle ?? settings.style(for: module)
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
    updatePreview(settings)
  }
  private func updatePreview(_ settings: Settings) {
    for picker in styles.values { picker.update(settings: settings) }
    presetSelector.selectedSegment = settings.separateItems ? 0 : 1
    menuStage?.update(settings)
  }
  @objc private func historyChanged() {
    guard !historyBusy else {
      refreshHistoryControl()
      return
    }
    let enabled = history?.state == .on
    onHistoryPersistence?(enabled)
    message.stringValue =
      enabled
      ? "History will be kept between launches."
      : "History paused. Saved data stays until you clear it in History & Storage."
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
