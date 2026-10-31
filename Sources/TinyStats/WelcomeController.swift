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

@MainActor private final class WelcomeBackgroundView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

@MainActor private final class WelcomeCardView: NSStackView {
  override func draw(_ dirtyRect: NSRect) {
    SystemStyle.drawPlatter(bounds)
  }
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
  private(set) var step: Int
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
  private var moreModules: NSTextField?

  init(settings: @escaping () -> Settings, initialStep: Int = 0) {
    currentSettings = settings
    step = min(5, max(0, initialStep))
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 720, height: 630),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Welcome to TinyStats"
    window.contentView = WelcomeBackgroundView(frame: window.contentLayoutRect)
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

  private func button(_ title: String, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(title)
    body.addArrangedSubview(button)
    return button
  }

  private func card(_ title: String, _ summary: String) {
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    let label = NSTextField(wrappingLabelWithString: summary)
    label.font = .systemFont(ofSize: 12)
    let card = WelcomeCardView(views: [heading, label])
    card.orientation = .vertical
    card.alignment = .leading
    card.spacing = 2
    card.edgeInsets = .init(top: 4, left: 10, bottom: 4, right: 10)
    body.addArrangedSubview(card)
    card.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    label.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -20).isActive = true
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
      heading.stringValue = "Your Mac, at a glance"
      text(
        "Start with CPU, Memory and Network in your menu bar. Click a readout for a native window with the details."
      )
      text(
        "Designed for a tiny footprint: one shared sampler, bounded local history and no extra polling for this tour. Resource costs vary by Mac and enabled features."
      )
      text(
        "No account. No analytics. Local-only by default. Weather and internet checks stay off until you opt in; existing saved choices are preserved."
      )
      text(
        "Use Tab / Shift-Tab to move, Space to select, Return for Next and Escape to Skip. Right-click a readout and choose Show welcome tour to replay it.",
        secondary: true)
    case 1:
      heading.stringValue = "Make the menu bar yours"
      text(
        "Choose readouts and picture styles. Keep at least one enabled; ⌘-drag menu bar items to reorder."
      )
      body.spacing = 6
      presetSelector.target = self
      presetSelector.action = #selector(presetChanged)
      presetSelector.setAccessibilityLabel("Menu bar layout")
      body.addArrangedSubview(presetSelector)
      var checks: [NSView] = []
      for module in Self.starterModules {
        let check = NSButton(
          checkboxWithTitle: module.title, target: self, action: #selector(menuChanged))
        check.state = settings.readouts.contains(module) ? .on : .off
        check.setAccessibilityLabel("Show \(module.title) in menu bar")
        check.widthAnchor.constraint(equalToConstant: 150).isActive = true
        readouts[module] = check
        checks.append(check)
      }
      for start in stride(from: 0, to: checks.count, by: 4) {
        body.addArrangedSubview(
          SystemSettingsForm.controls(Array(checks[start..<min(start + 4, checks.count)])))
      }
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
      text("Combined preview · Placeholder readings; scroll horizontally", secondary: true)
      let preview = MenuBarPreviewView(frame: .zero)
      let scroll = NSScrollView()
      scroll.documentView = preview
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      scroll.drawsBackground = false
      scroll.setAccessibilityLabel("Combined menu bar preview")
      body.addArrangedSubview(scroll)
      scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
      scroll.heightAnchor.constraint(equalToConstant: 52).isActive = true
      self.preview = preview
      previewScroll = scroll
      updatePreview(settings)
      text(
        "Weather requires separate opt-in. All readouts and fonts: Settings → Menu Bar.",
        secondary: true)
    case 2:
      heading.stringValue = "A home for every reading"
      body.spacing = 6
      card("Overview", "Your Mac’s key readings together in one compact summary.")
      card("CPU & GPU", "Processor use, top apps and supported graphics activity.")
      card("Memory / Disks / Network", "Memory pressure, storage space and traffic at a glance.")
      card("Power & Time", "Battery, accessories, energy mode, local calendar and world clocks.")
      card("Weather · Optional", "Forecasts and daylight after you choose to set up Weather.")
      text(
        "Advanced · Sensors: read-only temperatures, fan speeds and electrical readings.",
        secondary: true)
      let disclosure = button("More modules…", action: #selector(toggleMoreModules))
      disclosure.image = NSImage(
        systemSymbolName: moreModulesExpanded ? "chevron.down" : "chevron.right",
        accessibilityDescription: nil)
      disclosure.imagePosition = .imageLeading
      disclosure.state = moreModulesExpanded ? .on : .off
      disclosure.setAccessibilityExpanded(moreModulesExpanded)
      text(
        "History · Numeric charts and CSV export. Sensors’ All readings reveals raw SMC keys.",
        secondary: true)
      moreModules = body.arrangedSubviews.last as? NSTextField
      moreModules?.isHidden = !moreModulesExpanded
      text(
        "Hardware support varies. Missing readings remain unavailable, never a fabricated zero.",
        secondary: true)
      _ = button("Open Overview…", action: #selector(openOverview))
    case 3:
      heading.stringValue = "Online only when you choose"
      text(
        "Weather forecasts come from MET Norway (api.met.no). When enabled, it receives rounded coordinates and your public IP. Weather stays off until you opt in through Set up Weather."
      )
      text(
        "Remains off if you skip. Opening setup changes nothing: choose whether to enable in the existing controls. Use a manual/saved city, or explicitly allow TinyStats’ macOS location permission."
      )
      _ = button("Set up Weather…", action: #selector(openWeather))
      text(
        "Optional advanced · Internet checks are off by default. HTTPS → Apple’s preset or your URL; public IP → ipify; ping → your numeric address. Each destination sees your source IP. Review destinations and cadence before enabling.",
        secondary: true)
      let internet = button("Advanced · Internet checks…", action: #selector(openInternet))
      internet.setAccessibilityLabel("Internet checks")
      text(
        "Existing explicit online choices are preserved. You can turn each feature off in its own page at any time.",
        secondary: true)
    case 4:
      heading.stringValue = "Keep history. Choose your alerts."
      text(
        "History saving starts on: keep up to 28 days of numeric readings on this Mac, using at most 8.2 MiB of disk space (about 9 MB). Turn saving Off to keep the file without updating it, or Clear it in History & storage."
      )
      let check = NSButton(
        checkboxWithTitle: "Keep history between launches", target: self,
        action: #selector(historyChanged))
      body.addArrangedSubview(check)
      history = check
      refreshHistoryControl()
      _ = button("History & storage…", action: #selector(openHistory))
      text(
        "Notifications default off. Enable them explicitly in General settings, allow macOS permission, then choose alert rules and thresholds. Editing rules alone does not enable notifications."
      )
      _ = button("Notifications & alert rules…", action: #selector(openNotifications))
    default:
      heading.stringValue = "Ready when you are"
      text(
        "Click any TinyStats menu bar readout for details. Right-click a readout for Settings, pause, Show welcome tour or Quit. Choose Show welcome tour to replay this guide later."
      )
      text(
        "General settings has appearance, cadence, history and notifications. Menu Bar settings has readouts, styles and fonts. Weather and Network own their optional online controls."
      )
      let check = NSButton(
        checkboxWithTitle: "Launch at login", target: self, action: #selector(loginChanged))
      check.state = LoginItemPreference.enabled ? .on : .off
      body.addArrangedSubview(check)
      login = check
      text(
        "Uses macOS Login Items. Enabling may require approval in System Settings → General → Login Items.",
        secondary: true)
      _ = button("Open Menu Bar settings…", action: #selector(openMenuBarSettings))
      _ = button("Open Settings…", action: #selector(openSettings))
    }
    if step != 1 && step != 2 { body.spacing = 14 }
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
    login?.state = LoginItemPreference.enabled ? .on : .off
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
    message.stringValue = "Menu bar choices saved. Showing Weather does not enable forecasts."
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
      height: height, spacing: settings.menuBarSpacing)
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
    message.stringValue = LoginItemPreference.setEnabled(login?.state == .on)
    login?.state = LoginItemPreference.enabled ? .on : .off
  }
  @objc private func openWeather() { onWeather?() }
  @objc private func openInternet() { onInternet?() }
  @objc private func openNotifications() { onNotifications?() }
  @objc private func openHistory() { onHistory?() }
  @objc private func openSettings() { onSettings?() }
  @objc private func openOverview() { onOverview?() }
  @objc private func openMenuBarSettings() { onMenuBarSettings?() }
}
