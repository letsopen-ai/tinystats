import AppKit
import TinyStatsCore

@MainActor
final class PreferencesController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
  enum Page: Int {
    case general, menuBar
    var identifier: String { self == .general ? "general" : "menubar" }
  }
  private enum MenuBarPreset: String, CaseIterable {
    case simpleText = "Simple text"
    case compactBars = "Compact bars"
    case separate = "Separate"

    var size: MenuBarSize { self == .compactBars ? .compact : .standard }
    func style(for module: Module, sensorKey: String) -> MenuBarStyle {
      switch self {
      case .simpleText: return .text
      case .separate: return .stacked
      case .compactBars:
        let available = MenuBarStyle.available(for: module, sensorKey: sensorKey)
        // Rates, non-temperature sensors, Time and Weather have no percentage gauge.
        return [.horizontal, .bar, .labeledBar].first { available.contains($0) } ?? .text
      }
    }
    func matches(_ settings: Settings) -> Bool {
      settings.separateItems
        && settings.readouts.allSatisfy {
          settings.style(for: $0) == style(for: $0, sensorKey: settings.sensorKey)
            && settings.appearance(for: $0).size == size
        }
    }
  }
  var onHistoryPersistence: ((Bool) -> Void)?
  var onHistory: (() -> Void)?
  private var historyStorageBusy = false
  private lazy var keepHistory = SystemSettingSwitch(
    title: "Keep history between launches", target: nil, action: nil)
  var onClose: (() -> Void)?
  var onChange: ((Settings) -> Void)?
  var onInternetSettings: (() -> Void)?
  var onCalendarSettings: (() -> Void)?
  var onClockPreview: ((Bool?) -> Void)?
  var onAlertPermission: ((@escaping @MainActor @Sendable (Bool) -> Void) -> Void)?
  private var notificationRequest: UUID?
  private var ruleEditor: RulesController?
  private var batteryMenuController: BatteryMenuController?
  private var clockMenuController: ClockMenuController?
  private var worldClockController: WorldClockController?
  private var menuClockDemand: Bool?, worldClockDemand: Bool?
  private var clockDate: Date?
  private var settings: Settings
  private lazy var sensor = NSPopUpButton()
  private var sensorKeys: [String] = []
  private lazy var smart = SystemSettingSwitch(
    title: "Poll SMART health (5 min)", target: nil, action: nil)
  private lazy var interval = NSPopUpButton()
  private lazy var network = NSPopUpButton()
  private lazy var units = SystemSettingSwitch(title: "Use Fahrenheit", target: nil, action: nil)
  private lazy var alerts = SystemSettingSwitch(
    title: "Enable notifications",
    target: nil, action: nil)
  private lazy var login = SystemSettingSwitch(title: "Launch at login", target: nil, action: nil)
  private lazy var clocks = NSTextField(string: "")
  private lazy var message = NSTextField(wrappingLabelWithString: "")
  private static let menuHelperText =
    "Each readout opens its own page. Drag chips to customize, or use their context menus and keyboard actions. Scroll wide strips horizontally."
  private lazy var menuMessage = NSTextField(wrappingLabelWithString: Self.menuHelperText)
  private var readouts: [Module: SystemSettingSwitch] = [:]
  private lazy var customization: MenuBarCustomization = {
    let view = MenuBarCustomization(frame: .zero)
    view.onAction = { [weak self] module, action in
      guard let self else { return false }
      // The displayed native order is the starting point, including pre-existing ⌘-drag positions.
      self.settings.readouts = self.displayedOrder
      guard self.settings.customizeReadout(module, action: action) else { return false }
      self.individualOrder = self.settings.readouts
      for (module, toggle) in self.readouts {
        toggle.state = self.settings.readouts.contains(module) ? .on : .off
      }
      self.updatePresetSelection()
      self.customization.update(order: self.settings.readouts, animated: true)
      self.updatePreview()
      self.menuMessage.stringValue = Self.menuHelperText
      self.onChange?(self.settings)
      return true
    }
    return view
  }()
  private var displayedOrder: [Module] {
    individualOrder.count == settings.readouts.count
      && Set(individualOrder) == Set(settings.readouts)
      ? individualOrder : settings.readouts
  }
  private lazy var preview = MenuBarPreviewView(frame: .zero)
  private lazy var appearance = NSPopUpButton()
  private let presetStatus = SystemSettingsForm.text("")
  private let tabs = NSTabView()
  private let tabSelector = NSSegmentedControl(
    labels: ["General", "Menu Bar"], trackingMode: .selectOne, target: nil, action: nil)
  private let generalPage = NSView(), menuBarPage = NSView()
  private let interfaces: [String]
  private var builtPages = Set<Page>()
  private var designPageSize = NSSize.zero
  private var hostedRoot: NSView?
  private var menuBarAppearance: NSAppearance?
  private var individualOrder: [Module] = []
  private var previewPaused = false
  private var menuBarHeight = NSStatusBar.system.thickness
  private var latest = Snapshot()
  private var history: [HistoryPoint] = []
  private var sizeMenus: [Module: NSPopUpButton] = [:]
  private lazy var previewScroll = NSScrollView()
  private var styleMenus: [Module: NSPopUpButton] = [:]
  private lazy var presetSelector: SystemPresetChoices = {
    let examples = MenuBarPreset.allCases.map { preset in
      var example = settings
      for module in [Module.cpu, .memory] {
        example.styles[module.rawValue] = preset.style(for: module, sensorKey: settings.sensorKey)
        example.appearances[module.rawValue] = .init(size: preset.size, color: .automatic)
      }
      return example
    }
    return SystemPresetChoices(
      titles: MenuBarPreset.allCases.map(\.rawValue), settings: examples, snapshot: latest)
  }()
  private let styleOptions = NSStackView()
  private lazy var styleDisclosure = NSButton(
    title: "Customize readouts & styles…", target: self, action: #selector(toggleStyleOptions))
  private let onlineTimeOptions = NSStackView()
  private lazy var onlineTimeDisclosure = NSButton(
    title: "Online & Time advanced", target: self, action: #selector(toggleOnlineTimeOptions))
  init(
    settings: Settings, interfaces: [String], snapshot: Snapshot, history: [HistoryPoint],
    initialPage: Page = .general
  ) {
    self.interfaces = interfaces
    self.latest = snapshot
    self.history = history
    self.settings = settings
    self.settings.separateItems = true
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 740, height: 660), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "TinyStats Settings"
    window.center()
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.appearance = settings.theme.nativeAppearance
    window.contentView = SystemSettingsBackgroundView(
      frame: .init(x: 0, y: 0, width: 740, height: 660))
    guard let outer = window.contentView else { return }
    tabs.frame = .init(x: 12, y: 12, width: 716, height: 606)
    tabs.tabViewType = .noTabsBezelBorder
    tabs.autoresizingMask = [.width, .height]
    tabs.setAccessibilityLabel("Settings tabs")
    outer.addSubview(tabs)
    tabSelector.frame = .init(x: 270, y: 622, width: 200, height: 26)
    tabSelector.segmentStyle = .rounded
    tabSelector.selectedSegment = 0
    tabSelector.target = self
    tabSelector.action = #selector(tabChanged)
    tabSelector.setAccessibilityLabel("Settings sections")
    outer.addSubview(tabSelector)
    let general = generalPage
    let menuBar = menuBarPage
    for (id, title, page) in [("general", "General", general), ("menubar", "Menu Bar", menuBar)] {
      let item = NSTabViewItem(identifier: id)
      item.label = title
      item.view = page
      tabs.addTabViewItem(item)
    }
    designPageSize = tabs.contentRect.size
    tabs.delegate = self
    selectPage(initialPage)
  }

  private func buildGeneralPage() {
    let general = generalPage
    appearance.addItems(withTitles: AppTheme.allCases.map(\.title))
    appearance.selectItem(withTitle: settings.theme.title)
    appearance.setAccessibilityLabel("App appearance")
    appearance.target = self
    appearance.action = #selector(changed)
    units.state = settings.fahrenheit ? .on : .off
    units.target = self
    units.action = #selector(changed)
    interval.addItems(withTitles: ["1 second", "2 seconds · default", "5 seconds", "10 seconds"])
    interval.selectItem(at: [1.0, 2, 5, 10].firstIndex(of: settings.interval) ?? 1)
    let cadence = NSTextField(
      labelWithString: "Low Power Mode uses at least 5 seconds. Sensors update at ≥5s.")
    cadence.font = .systemFont(ofSize: 10)
    cadence.textColor = .secondaryLabelColor
    network.addItems(withTitles: ["Auto · IPv4 / IPv6 primary route"] + interfaces)
    if settings.networkInterface != "auto", !interfaces.contains(settings.networkInterface) {
      network.addItem(withTitle: settings.networkInterface)
    }
    network.selectItem(
      withTitle: settings.networkInterface == "auto"
        ? "Auto · IPv4 / IPv6 primary route" : settings.networkInterface)
    smart.state = settings.monitorStorageHealth ? .on : .off
    smart.target = self
    smart.action = #selector(changed)
    smart.toolTip =
      "Off: read drive health while disk details are open. On: also check every five minutes in the background."
    login.state = LoginItemPreference.enabled ? .on : .off
    login.target = self
    login.action = #selector(loginChanged)
    alerts.state = settings.alerts ? .on : .off
    alerts.target = self
    alerts.action = #selector(alertsChanged)
    let editRules = NSButton(title: "Edit alert rules…", target: self, action: #selector(showRules))
    editRules.bezelStyle = .rounded
    clocks.stringValue = settings.worldClockInput
    clocks.placeholderString = "UTC, London office=Europe/London"
    let saveClocks = NSButton(title: "Save clocks", target: self, action: #selector(saveClocks))
    saveClocks.bezelStyle = .rounded
    let hint = NSTextField(
      labelWithString: "Up to six zones · optional Name=Zone, e.g. Work=Europe/London")
    hint.font = .systemFont(ofSize: 10)
    hint.textColor = .secondaryLabelColor
    let formats = NSButton(
      title: "World clock format…", target: self, action: #selector(showWorldClockFormat))
    formats.bezelStyle = .rounded
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    onlineTimeDisclosure.bezelStyle = .rounded
    onlineTimeDisclosure.setAccessibilityLabel("Online & Time advanced")
    onlineTimeDisclosure.setAccessibilityExpanded(false)
    onlineTimeOptions.isHidden = true
    let internet = NSButton(
      title: "Internet checks…", target: self, action: #selector(showInternetSettings))
    internet.bezelStyle = .rounded
    internet.setAccessibilityLabel("Internet checks")
    let calendar = NSButton(
      title: "Calendar…", target: self, action: #selector(showCalendarSettings))
    calendar.bezelStyle = .rounded
    calendar.setAccessibilityLabel("Calendar settings")
    let advancedHint = NSTextField(
      labelWithString: "Optional · off by default · no requests until you enable")
    advancedHint.font = .systemFont(ofSize: 10)
    advancedHint.textColor = .secondaryLabelColor
    keepHistory.state = settings.persistHistory ? .on : .off
    keepHistory.isEnabled = !historyStorageBusy
    keepHistory.target = self
    keepHistory.action = #selector(historyChanged)
    keepHistory.toolTip =
      "On by default. Off pauses saving; it does not delete the saved checkpoint. Clear history in History & storage."
    let storage = NSButton(
      title: "History & storage…", target: self, action: #selector(showHistoryStorage))
    storage.bezelStyle = .rounded
    let historyScope = NSTextField(
      labelWithString: "Local numeric readings · up to 28 days · checkpoint up to 8.2 MiB")
    historyScope.font = .systemFont(ofSize: 10)
    historyScope.textColor = .secondaryLabelColor

    let footer = NSTextField(
      labelWithString:
        "Most changes apply immediately · Clock zones use Save clocks · ⌘1–9 / ⌘0 switches pages")
    footer.font = .systemFont(ofSize: 10)
    footer.textColor = .secondaryLabelColor
    for popup in [interval, network] {
      popup.target = self
      popup.action = #selector(changed)
    }
    interval.setAccessibilityLabel("Sampling interval")
    network.setAccessibilityLabel("Network interface")
    clocks.setAccessibilityLabel("World clock time zones")
    let form = SystemSettingsForm.self
    onlineTimeOptions.orientation = .vertical
    onlineTimeOptions.alignment = .leading
    onlineTimeOptions.spacing = 8
    onlineTimeOptions.addArrangedSubview(
      form.group([
        form.row("Internet checks", internet), form.row("Calendar", calendar),
      ]))
    onlineTimeOptions.addArrangedSubview(advancedHint)
    for child in onlineTimeOptions.arrangedSubviews {
      child.translatesAutoresizingMaskIntoConstraints = false
      child.widthAnchor.constraint(equalTo: onlineTimeOptions.widthAnchor).isActive = true
    }
    _ = SystemSettingsForm(
      in: general,
      views: [
        form.text(
          "No account. No analytics. Local only, unless you enable Weather or advanced internet checks."
        ),
        form.text("Appearance and updates", heading: true),
        form.group([
          form.row("Appearance", appearance, width: 210),
          form.row(units.title, units),
          form.row("Update interval", interval, width: 240),
        ]), cadence,
        form.text("Local monitoring", heading: true),
        form.group([
          form.row("Network interface", network, width: 300),
          form.row(smart.title, smart), form.row(login.title, login),
        ]),
        form.text("Notifications", heading: true),
        form.group([form.row(alerts.title, alerts), form.row("Alert rules", editRules)]),
        form.text("World clocks", heading: true),
        form.group([
          form.row("Time zones", form.controls([clocks, saveClocks], widths: [260, 120])),
          form.row("Display", formats),
        ]), hint,
        onlineTimeDisclosure, onlineTimeOptions,
        form.text("History", heading: true),
        form.group([form.row(keepHistory.title, keepHistory), form.row("Storage", storage)]),
        historyScope,
        message, footer,
      ])
  }

  private func buildMenuBarPage() {
    let form = SystemSettingsForm.self
    presetSelector.target = self
    presetSelector.action = #selector(presetChanged)
    presetSelector.toolTip =
      "Apply styles to enabled readouts. Separate stacks label + value within each separate menu bar item."
    previewScroll.hasHorizontalScroller = true
    previewScroll.hasVerticalScroller = false
    previewScroll.scrollerStyle = .overlay
    previewScroll.autohidesScrollers = true
    previewScroll.drawsBackground = false
    previewScroll.borderType = .noBorder
    previewScroll.documentView = preview
    previewScroll.setAccessibilityLabel("Live menu bar preview")
    let wallpaper = SystemWallpaperStrip()
    wallpaper.heightAnchor.constraint(equalToConstant: 62).isActive = true
    previewScroll.translatesAutoresizingMaskIntoConstraints = false
    wallpaper.addSubview(previewScroll)
    NSLayoutConstraint.activate([
      previewScroll.leadingAnchor.constraint(equalTo: wallpaper.leadingAnchor, constant: 8),
      previewScroll.trailingAnchor.constraint(equalTo: wallpaper.trailingAnchor, constant: -8),
      previewScroll.topAnchor.constraint(equalTo: wallpaper.topAnchor, constant: 6),
      previewScroll.heightAnchor.constraint(equalToConstant: 42),
    ])
    styleDisclosure.bezelStyle = .rounded
    styleDisclosure.title = "Hide readout & style options"
    styleDisclosure.setAccessibilityLabel("Customize menu bar readouts and styles")
    styleDisclosure.setAccessibilityExpanded(true)
    styleOptions.orientation = .vertical
    styleOptions.alignment = .leading
    styleOptions.spacing = 10
    var rows: [SystemFormRow] = []
    for module in Module.allCases where module != .overview {
      let toggle = SystemSettingSwitch(
        title: module.title, target: self, action: #selector(changed))
      toggle.state = settings.readouts.contains(module) ? .on : .off
      readouts[module] = toggle
      let popup = NSPopUpButton()
      popup.font = .systemFont(ofSize: 12)
      popup.addItems(
        withTitles: MenuBarStyle.available(for: module, sensorKey: settings.sensorKey).map(\.title))
      popup.selectItem(withTitle: settings.style(for: module).title)
      popup.target = self
      popup.action = #selector(changed)
      popup.setAccessibilityLabel("\(module.title) menu bar style")
      styleMenus[module] = popup
      let size = NSPopUpButton()
      size.font = .systemFont(ofSize: 11)
      size.addItems(withTitles: MenuBarSize.allCases.map(\.title))
      size.selectItem(withTitle: settings.appearance(for: module).size.title)
      size.target = self
      size.action = #selector(changed)
      size.setAccessibilityLabel("\(module.title) menu bar font size")
      sizeMenus[module] = size
      let icon = NSImageView(
        image: NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) ?? NSImage())
      icon.contentTintColor = .secondaryLabelColor
      icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
      let name = NSTextField(labelWithString: module.title)
      name.font = .systemFont(ofSize: 13)
      let identity = form.controls([icon, name])
      let controls = form.controls([popup, size, toggle], widths: [200, 96, 38])
      let row = form.controls([identity, controls])
      identity.setContentHuggingPriority(.defaultLow, for: .horizontal)
      rows.append(form.row("", row, height: 38))
    }
    let headings = form.controls([
      form.text("Readouts", heading: true), form.text("Style"), form.text("Font"),
      form.text("Show"),
    ])
    // Match the trailing control columns while the leading identity column absorbs resizing.
    headings.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: 200).isActive = true
    headings.arrangedSubviews[2].widthAnchor.constraint(equalToConstant: 96).isActive = true
    headings.arrangedSubviews[3].widthAnchor.constraint(equalToConstant: 38).isActive = true
    styleOptions.addArrangedSubview(headings)
    styleOptions.addArrangedSubview(form.group(rows))
    sensor.target = self
    sensor.action = #selector(sensorChanged)
    sensor.setAccessibilityLabel("Menu bar sensor")
    styleOptions.addArrangedSubview(form.group([form.row("Menu bar sensor", sensor, width: 390)]))
    let battery = NSButton(
      title: "Battery formats…", target: self, action: #selector(showBatteryFormats))
    battery.setAccessibilityLabel("Battery menu bar formats")
    let clock = NSButton(title: "Clock formats…", target: self, action: #selector(showClockFormats))
    clock.setAccessibilityLabel("Clock menu bar formats")
    styleOptions.addArrangedSubview(
      form.group([
        form.row("Battery", battery), form.row("Time", clock),
      ]))
    for child in styleOptions.arrangedSubviews {
      child.translatesAutoresizingMaskIntoConstraints = false
      child.widthAnchor.constraint(equalTo: styleOptions.widthAnchor).isActive = true
    }
    menuMessage.font = .systemFont(ofSize: 11)
    menuMessage.textColor = .secondaryLabelColor
    _ = SystemSettingsForm(
      in: menuBarPage,
      views: [
        form.group([form.row("", wallpaper, height: 78), form.row("", presetSelector, height: 86)]),
        presetStatus, customization, styleDisclosure, styleOptions, menuMessage,
      ])
    updatePresetSelection()
  }

  @objc private func toggleStyleOptions() {
    styleOptions.isHidden.toggle()
    styleDisclosure.title =
      styleOptions.isHidden ? "Customize readouts & styles…" : "Hide readout & style options"
    styleDisclosure.setAccessibilityExpanded(!styleOptions.isHidden)
  }

  @objc private func presetChanged() {
    guard MenuBarPreset.allCases.indices.contains(presetSelector.selectedSegment) else { return }
    let preset = MenuBarPreset.allCases[presetSelector.selectedSegment]
    settings.separateItems = true
    for module in settings.readouts {
      settings.styles[module.rawValue] = preset.style(for: module, sensorKey: settings.sensorKey)
      var look = settings.appearance(for: module)
      look.size = preset.size
      settings.appearances[module.rawValue] = look
    }
    for (module, check) in readouts {
      check.state = settings.readouts.contains(module) ? .on : .off
    }
    for (module, popup) in styleMenus {
      popup.selectItem(withTitle: settings.style(for: module).title)
    }
    for (module, popup) in sizeMenus {
      popup.selectItem(withTitle: settings.appearance(for: module).size.title)
    }
    settings.validate()
    applyAppearance()
    updatePresetSelection()
    updatePreview()
    if builtPages.contains(.general) { message.stringValue = "" }
    menuMessage.stringValue = Self.menuHelperText
    onChange?(settings)
  }

  private func updatePresetSelection() {
    presetSelector.selectedSegment =
      MenuBarPreset.allCases.firstIndex { $0.matches(settings) } ?? -1
    presetStatus.stringValue =
      presetSelector.selectedSegment < 0
      ? "No preset selected: your readouts use individual styles"
      : presetSelector.label(forSegment: presetSelector.selectedSegment) + " preset"
  }

  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let field = client as? NSTextField, field === clocks else { return nil }
    return LiteralFieldEditor.prepare(in: sender)
  }
  func windowWillClose(_ notification: Notification) {
    batteryMenuController?.close()
    batteryMenuController = nil
    clockMenuController?.close()
    clockMenuController = nil
    worldClockController?.close()
    worldClockController = nil
    ruleEditor?.close()
    ruleEditor = nil
    // AppKit can retain the most recently displayed tab view after its window closes.
    // This controller is replaced on reopening; discard its pages with the window.
    tabs.delegate = nil
    for item in tabs.tabViewItems {
      tabs.removeTabViewItem(item)
      item.view = nil
    }
    onClose?()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func updateInternetSettings(
    connectivity: Bool, publicIP: Bool, revision: String,
    httpsCheck: HTTPSCheckConfiguration, pingCheck: ICMPCheckConfiguration
  ) {
    settings.connectivityChecks = connectivity
    settings.publicIPChecks = publicIP
    settings.httpsCheck = httpsCheck
    settings.pingCheck = pingCheck
    settings.internetRevision = revision
  }
  func updateNetworkGrouping(_ value: TrafficGrouping, revision: String) {
    settings.networkTrafficGrouping = value
    settings.networkTrafficRevision = revision
  }
  func updateHistoryPersistence(_ enabled: Bool) {
    settings.persistHistory = enabled
    if builtPages.contains(.general) { keepHistory.state = enabled ? .on : .off }
  }
  func setHistoryStorageBusy(_ busy: Bool) {
    historyStorageBusy = busy
    if builtPages.contains(.general) { keepHistory.isEnabled = !busy }
  }
  @objc private func historyChanged() {
    guard !historyStorageBusy else {
      keepHistory.state = settings.persistHistory ? .on : .off
      return
    }
    onHistoryPersistence?(keepHistory.state == .on)
  }
  @objc private func showHistoryStorage() { onHistory?() }
  func updateMenuBarSettings(_ value: Settings) {
    settings.readouts = value.readouts
    individualOrder = value.readouts
    settings.styles = value.styles
    settings.appearances = value.appearances
    for (module, check) in readouts {
      check.state = settings.readouts.contains(module) ? .on : .off
    }
    for (module, popup) in styleMenus {
      popup.selectItem(withTitle: settings.style(for: module).title)
    }
    for (module, popup) in sizeMenus {
      popup.selectItem(withTitle: settings.appearance(for: module).size.title)
    }
    applyAppearance()
    updatePresetSelection()
    updatePreview()
  }
  func updateWeatherSettings(_ value: WeatherSettings) { settings.weather = value }
  func updateCalendarSettings(enabled: Bool, selectedIDs: [String]?) {
    settings.calendarEvents = enabled
    settings.calendarIDs = selectedIDs
  }
  func updateCalendarFirstWeekday(_ day: Int?) { settings.calendarFirstWeekday = day }
  func update(_ snapshot: Snapshot, history: [HistoryPoint]) {
    self.history = history
    latest = snapshot
    clockDate = snapshot.timestamp
    batteryMenuController?.update(snapshot, history: history)
    clockMenuController?.updateClock(snapshot.timestamp)
    worldClockController?.updateClock(snapshot.timestamp)
    ruleEditor?.update(snapshot)
    if hostedRoot.map({ $0.window?.isVisible == true && !$0.isHidden })
      ?? (window?.isVisible == true),
      tabs.selectedTabViewItem?.identifier as? String == Page.menuBar.identifier
    {
      refreshSensorChoices()
      updatePreview()
    }
  }
  func updateClock(_ date: Date) {
    clockDate = date
    clockMenuController?.updateClock(date)
    worldClockController?.updateClock(date)
    updatePreview()
  }
  func updateMenuBarContext(
    appearance: NSAppearance?, order: [Module], height: CGFloat, paused: Bool
  ) {
    menuBarAppearance = appearance
    individualOrder = order
    if height > 0 && height <= 100 { menuBarHeight = height }
    previewPaused = paused
    batteryMenuController?.updateMenuBarContext(
      appearance: appearance, height: menuBarHeight, paused: paused)
    clockMenuController?.updateMenuBarContext(
      appearance: appearance, height: menuBarHeight, paused: paused)
    updatePreview()
  }
  func applyAppearance() {
    window?.appearance = settings.theme.nativeAppearance
    ruleEditor?.window?.appearance = settings.theme.nativeAppearance
    batteryMenuController?.updateSettings(settings)
    clockMenuController?.updateSettings(settings)
    worldClockController?.updateSettings(settings)
  }
  func selectMenuBarTab() { selectPage(.menuBar) }
  private func ensurePage(_ page: Page) {
    guard !builtPages.contains(page) else { return }
    let content = page == .general ? generalPage : menuBarPage
    let actualSize = content.frame.size
    content.setFrameSize(designPageSize)
    defer { if actualSize.width > 0 && actualSize.height > 0 { content.setFrameSize(actualSize) } }
    switch page {
    case .general: buildGeneralPage()
    case .menuBar: buildMenuBarPage()
    }
    builtPages.insert(page)
    if page == .menuBar { refreshSensorChoices() }
  }
  func embeddedView(page: Page) -> NSView? {
    selectPage(page)
    tabSelector.isHidden = true
    if hostedRoot == nil {
      hostedRoot = window?.contentView
      window?.contentView = nil
    }
    return hostedRoot
  }
  func disposeEmbedded() {
    for child in hostedRoot?.subviews ?? [] { child.removeFromSuperview() }
    hostedRoot?.removeFromSuperview()
    hostedRoot = nil
    windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
  }
  func selectPage(_ page: Page) {
    ensurePage(page)
    if page == .menuBar { refreshSensorChoices() }
    tabSelector.selectedSegment = page.rawValue
    tabs.selectTabViewItem(withIdentifier: page.identifier)
    updatePreview()
  }
  func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
    guard let tabViewItem, let page = Page(rawValue: tabView.indexOfTabViewItem(tabViewItem)) else {
      return
    }
    ensurePage(page)
  }
  func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    guard let tabViewItem, let page = Page(rawValue: tabView.indexOfTabViewItem(tabViewItem)) else {
      return
    }
    tabSelector.selectedSegment = page.rawValue
    updatePreview()
  }
  @objc private func tabChanged() {
    guard let page = Page(rawValue: tabSelector.selectedSegment) else { return }
    selectPage(page)
  }
  func refreshVisibleContent() {
    if builtPages.contains(.general) { login.state = LoginItemPreference.enabled ? .on : .off }
    if builtPages.contains(.menuBar) { refreshSensorChoices() }
    updatePreview()
  }
  private func updatePreview() {
    // Selected NSTabView item remains Menu Bar when the entire embedded host is hidden.
    // Clock/context updates must not rebuild an invisible preview after returning to monitoring.
    if let host = hostedRoot,
      host.isHidden || host.window?.isVisible != true || host.window?.isMiniaturized == true
    {
      return
    }
    guard builtPages.contains(.menuBar),
      tabs.selectedTabViewItem?.identifier as? String == Page.menuBar.identifier
    else { return }
    preview.appearance = menuBarAppearance
    previewScroll.appearance = menuBarAppearance
    previewScroll.superview?.appearance = menuBarAppearance
    let actualOrder = displayedOrder
    customization.update(order: actualOrder)
    let groups = actualOrder.map {
      MenuBarReadout.makeAll(
        module: $0, snapshot: latest, settings: settings, history: history, clockDate: clockDate)
    }
    preview.update(
      groups: settings.separateItems ? groups : [groups.flatMap { $0 }],
      paused: previewPaused, height: menuBarHeight)
    preview.frame.size = .init(
      width: max(654, preview.preferredWidth), height: max(36, menuBarHeight))
    preview.needsDisplay = true
    for (module, popup) in sizeMenus {
      let style =
        module == .battery
        ? settings.batteryMenu.preset(
          for: latest.batteries.first, defaultStyle: settings.style(for: module)
        ).style
        : settings.style(for: module)
      popup.isEnabled = style.usesFont && settings.readouts.contains(module)
    }
    for (module, popup) in styleMenus {
      popup.isEnabled = settings.readouts.contains(module)
    }
    styleMenus[.battery]?.isEnabled =
      settings.readouts.contains(.battery) && !settings.batteryMenu.customizeStates
    styleMenus[.battery]?.toolTip =
      settings.batteryMenu.customizeStates
      ? "Per-state styles are configured in Battery formats (…)" : nil
  }

  private func refreshSensorChoices() {
    guard builtPages.contains(.menuBar) else { return }
    let grouped = SensorComponent.allCases.flatMap { component in
      latest.sensors.filter { $0.component == component }.sorted { $0.key < $1.key }
    }
    var keys = ["cpu"] + grouped.map(\.key)
    if !keys.contains(settings.sensorKey) { keys.append(settings.sensorKey) }
    guard keys != sensorKeys else { return }
    sensorKeys = keys
    sensor.removeAllItems()
    for key in keys {
      let reading = latest.sensor(for: key)
      let name =
        key == "cpu"
        ? SensorCatalog.hottestCPULabel
        : (reading.map { "\($0.component.title) · \($0.name) (\($0.unit))" }
          ?? "\(key) · unavailable")
      sensor.addItem(withTitle: name)
    }
    sensor.selectItem(at: keys.firstIndex(of: settings.sensorKey) ?? 0)
  }
  @objc private func sensorChanged() {
    guard sensorKeys.indices.contains(sensor.indexOfSelectedItem) else { return }
    settings.sensorKey = sensorKeys[sensor.indexOfSelectedItem]
    let effective = settings.style(for: .sensors)
    settings.styles[Module.sensors.rawValue] = effective
    if let popup = styleMenus[.sensors] {
      popup.removeAllItems()
      popup.addItems(
        withTitles: MenuBarStyle.available(for: .sensors, sensorKey: settings.sensorKey).map(
          \.title))
      popup.selectItem(withTitle: effective.title)
    }
    settings.validate()
    updatePresetSelection()
    updatePreview()
    onChange?(settings)
  }
  @objc private func changed() {
    if builtPages.contains(.menuBar) {
      let chosen = Module.allCases.filter { readouts[$0]?.state == .on }
      guard !chosen.isEmpty else {
        for module in settings.readouts { readouts[module]?.state = .on }
        let error = "Keep at least one readout enabled so TinyStats remains accessible."
        if builtPages.contains(.general) { message.stringValue = error }
        menuMessage.stringValue = error
        return
      }
      // Preserve existing order; append newly enabled readouts in module order.
      let previousOrder = displayedOrder
      settings.readouts =
        previousOrder.filter { chosen.contains($0) }
        + chosen.filter { !previousOrder.contains($0) }
      individualOrder = settings.readouts
      settings.separateItems = true
      for (module, popup) in styleMenus {
        settings.styles[module.rawValue] =
          MenuBarStyle.available(for: module, sensorKey: settings.sensorKey)[
            max(0, popup.indexOfSelectedItem)]
      }
      for module in Module.allCases where module != .overview {
        if let size = sizeMenus[module] {
          settings.appearances[module.rawValue] = .init(
            size: MenuBarSize.allCases[max(0, size.indexOfSelectedItem)],
            color: .automatic)
        }
      }
    }
    if builtPages.contains(.general) {
      settings.interval = [1.0, 2, 5, 10][max(0, interval.indexOfSelectedItem)]
      settings.networkInterface =
        network.indexOfSelectedItem == 0 ? "auto" : network.titleOfSelectedItem ?? "auto"
      settings.fahrenheit = units.state == .on
      settings.theme = AppTheme.allCases[max(0, appearance.indexOfSelectedItem)]
      settings.monitorStorageHealth = smart.state == .on
    }
    settings.validate()
    applyAppearance()
    updatePresetSelection()
    updatePreview()
    if builtPages.contains(.general) { message.stringValue = "" }
    if builtPages.contains(.menuBar) {
      menuMessage.stringValue = Self.menuHelperText
    }
    onChange?(settings)
  }
  @objc private func showBatteryFormats() {
    if batteryMenuController == nil {
      let controller = BatteryMenuController(settings: settings, snapshot: latest, history: history)
      controller.onChange = { [weak self] value in
        guard let self else { return }
        self.settings.batteryMenu = value
        self.settings.validate()
        self.updatePreview()
        self.onChange?(self.settings)
      }
      batteryMenuController = controller
    }
    batteryMenuController?.updateSettings(settings)
    batteryMenuController?.update(latest, history: history)
    batteryMenuController?.updateMenuBarContext(
      appearance: menuBarAppearance, height: menuBarHeight, paused: previewPaused)
    batteryMenuController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func showClockFormats() {
    if clockMenuController == nil {
      let controller = ClockMenuController(settings: settings, date: clockDate ?? latest.timestamp)
      controller.onChange = { [weak self] value in
        guard let self else { return }
        self.settings.clockMenu = value
        self.onChange?(self.settings)
        self.updatePreview()
      }
      controller.onPreviewDemand = { [weak self] seconds in
        self?.menuClockDemand = seconds
        self?.updateClockDemand()
      }
      clockMenuController = controller
    }
    clockMenuController?.updateSettings(settings)
    clockMenuController?.updateClock(clockDate ?? latest.timestamp)
    clockMenuController?.updateMenuBarContext(
      appearance: menuBarAppearance, height: menuBarHeight, paused: previewPaused)
    clockMenuController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  private func updateClockDemand() {
    onClockPreview?(Self.combinedClockDemand(menuClockDemand, worldClockDemand))
  }
  static func combinedClockDemand(_ menu: Bool?, _ world: Bool?) -> Bool? {
    if menu == true || world == true { return true }
    return menu != nil || world != nil ? false : nil
  }
  @objc private func showWorldClockFormat() {
    if worldClockController == nil {
      let controller = WorldClockController(settings: settings, date: clockDate ?? latest.timestamp)
      controller.onChange = { [weak self] value in
        guard let self else { return }
        self.settings.worldClockFormat = value
        self.onChange?(self.settings)
      }
      controller.onPreviewDemand = { [weak self] seconds in
        self?.worldClockDemand = seconds
        self?.updateClockDemand()
      }
      worldClockController = controller
    }
    worldClockController?.updateSettings(settings)
    worldClockController?.updateClock(clockDate ?? latest.timestamp)
    worldClockController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func toggleOnlineTimeOptions() {
    onlineTimeOptions.isHidden.toggle()
    let expanded = !onlineTimeOptions.isHidden
    onlineTimeDisclosure.title = expanded ? "Hide Online & Time advanced" : "Online & Time advanced"
    onlineTimeDisclosure.setAccessibilityExpanded(expanded)
    // Session-only disclosure: leave feature settings and authorization untouched.
  }
  @objc private func showInternetSettings() { onInternetSettings?() }
  @objc private func showCalendarSettings() { onCalendarSettings?() }
  @objc private func saveClocks() {
    guard let entries = WorldClockEntry.parse(clocks.stringValue) else {
      message.stringValue =
        "Enter up to six unique zones, optionally Name=Zone (for example Work=Europe/London). Labels use at most 40 characters; nothing was saved."
      return
    }
    settings.worldClocks = entries.map(\.zone)
    settings.worldClockNames = Dictionary(
      uniqueKeysWithValues: entries.compactMap { entry in
        entry.name.map { (entry.zone, $0) }
      })
    settings.validate()
    message.stringValue = "World clocks saved."
    worldClockController?.updateSettings(settings)
    onChange?(settings)
  }
  @objc private func loginChanged() {
    message.stringValue = LoginItemPreference.setEnabled(login.state == .on)
    login.state = LoginItemPreference.enabled ? .on : .off
  }

  @objc private func showRules() {
    if let ruleEditor, ruleEditor.window?.isVisible == true {
      ruleEditor.window?.makeKeyAndOrderFront(nil)
      return
    }
    message.stringValue = ""
    let editor = RulesController(rules: settings.rules, snapshot: latest)
    editor.window?.appearance = settings.theme.nativeAppearance
    editor.onSave = { [weak self] rules in
      guard let self else { return }
      self.settings.rules = rules
      self.settings.validate()
      self.onChange?(self.settings)
      self.message.stringValue =
        "Alert rules saved. Notifications require the Enable notifications switch."
    }
    editor.onClose = { [weak self, weak editor] in
      Task { @MainActor [weak self, weak editor] in
        guard self?.ruleEditor === editor else { return }
        self?.ruleEditor = nil
      }
    }
    ruleEditor = editor
    editor.showWindow(nil)
    editor.window?.makeKeyAndOrderFront(nil)
  }
  @objc private func alertsChanged() {
    if alerts.state == .off {
      notificationRequest = nil
      settings.alerts = false
      onChange?(settings)
      return
    }
    let request = UUID()
    notificationRequest = request
    onAlertPermission? { [weak self] allowed in
      guard let self, self.notificationRequest == request, self.alerts.state == .on else { return }
      self.notificationRequest = nil
      self.settings.alerts = allowed
      self.alerts.state = allowed ? .on : .off
      self.message.stringValue =
        allowed
        ? "Alerts enabled. Configure thresholds and cooldowns in Edit alert rules."
        : "Enable notifications for TinyStats in System Settings to use alerts."
      self.onChange?(self.settings)
    }
  }
}
