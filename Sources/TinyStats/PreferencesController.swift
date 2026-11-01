import AppKit
import TinyStatsCore

@MainActor
final class PreferencesController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
  enum Page: Int {
    case general, menuBar
    var identifier: String { self == .general ? "general" : "menubar" }
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
  private lazy var customization: MenuBarCustomization = {
    let view = MenuBarCustomization(frame: .zero)
    view.onSelection = { [weak self] module in self?.selectStyleModule(module) }
    view.onActivation = { [weak self] in
      guard let self, self.styleOptions.isHidden else { return }
      self.toggleStyleOptions()
    }
    view.onAction = { [weak self] module, action in
      guard let self else { return false }
      // The displayed native order is the starting point, including pre-existing ⌘-drag positions.
      var updated = self.settings
      updated.readouts = self.displayedOrder
      guard updated.customizeReadout(module, action: action) else { return false }
      updated.validate()
      self.settings = updated
      self.individualOrder = self.settings.readouts
      self.updateLayoutSelection()
      self.customization.update(order: self.settings.readouts, animated: true)
      self.updatePreview()
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
  private var styleMenus: [Module: MenuBarStylePicker] = [:]
  private var moduleEditors: [Module: NSView] = [:]
  private(set) var selectedStyleModule: Module = .cpu
  static let menuBarToolsHeightBudget: CGFloat = 28
  static let menuBarHeaderHeightBudget: CGFloat = 74
  static let menuBarCPUBottomChromeBudget: CGFloat = 20
  static let menuBarCPUOptionsHeightBudget: CGFloat = 230
  /// Includes the preview, title, help and segmented control in one row.
  static let menuBarLayoutSectionHeightBudget: CGFloat = 74
  private let layoutSelector = MenuBarLayoutIcons.control()
  private let styleOptions = NSStackView()
  private lazy var styleDisclosure = NSButton(
    title: "Customize styles…", target: self, action: #selector(toggleStyleOptions))
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
    selectedStyleModule = settings.readouts.first ?? .cpu
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
    layoutSelector.target = self
    layoutSelector.action = #selector(layoutChanged)
    layoutSelector.setAccessibilityLabel("Menu bar layout")
    for (index, title) in ["Separate", "One"].enumerated() {
      layoutSelector.setToolTip(title, forSegment: index)
    }
    layoutSelector.heightAnchor.constraint(lessThanOrEqualToConstant: Self.menuBarToolsHeightBudget)
      .isActive = true
    previewScroll.hasHorizontalScroller = true
    previewScroll.hasVerticalScroller = false
    previewScroll.scrollerStyle = .overlay
    previewScroll.autohidesScrollers = true
    previewScroll.drawsBackground = false
    previewScroll.borderType = .noBorder
    previewScroll.documentView = preview
    previewScroll.setAccessibilityLabel("Live menu bar preview")
    let wallpaper = SystemWallpaperStrip()
    wallpaper.heightAnchor.constraint(equalToConstant: 50).isActive = true
    previewScroll.translatesAutoresizingMaskIntoConstraints = false
    wallpaper.addSubview(previewScroll)
    NSLayoutConstraint.activate([
      previewScroll.leadingAnchor.constraint(equalTo: wallpaper.leadingAnchor, constant: 8),
      previewScroll.trailingAnchor.constraint(equalTo: wallpaper.trailingAnchor, constant: -8),
      previewScroll.topAnchor.constraint(equalTo: wallpaper.topAnchor, constant: 6),
      previewScroll.heightAnchor.constraint(equalToConstant: 42),
    ])
    styleDisclosure.isBordered = false
    styleDisclosure.alignment = .left
    styleDisclosure.imagePosition = .imageLeading
    styleDisclosure.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
    styleDisclosure.title = "Hide styles"
    styleDisclosure.setAccessibilityLabel("Customize menu bar styles")
    styleDisclosure.setAccessibilityExpanded(true)
    styleOptions.orientation = .vertical
    styleOptions.alignment = .leading
    styleOptions.spacing = 10
    sensor.target = self
    sensor.action = #selector(sensorChanged)
    sensor.setAccessibilityLabel("Menu bar sensor")
    for module in Module.allCases where module != .overview {
      let popup = MenuBarStylePicker(module: module, settings: settings)
      popup.target = self
      popup.action = #selector(changed)
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
      icon.contentTintColor = SystemStyle.moduleAccent(module)
      icon.identifier = NSUserInterfaceItemIdentifier("readout-icon-\(module.rawValue)")
      icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
      let name = NSTextField(labelWithString: module.title)
      name.font = .systemFont(ofSize: 13)
      let identity = form.controls([icon, name])
      identity.setContentCompressionResistancePriority(.required, for: .horizontal)
      var tool: NSView?
      if module == .sensors {
        sensor.font = .systemFont(ofSize: 11)
        tool = sensor
      } else if module == .battery || module == .clock {
        let button = NSButton(
          title: module == .battery ? "Battery formats…" : "Clock formats…",
          target: self,
          action: module == .battery ? #selector(showBatteryFormats) : #selector(showClockFormats))
        button.font = .systemFont(ofSize: 11)
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(
          module == .battery ? "Battery menu bar formats" : "Clock menu bar formats")
        tool = button
      }
      tool?.identifier = NSUserInterfaceItemIdentifier("menu-bar-\(module.rawValue)-tools")
      let header = MenuBarStyleHeader(identity: identity, size: size, tool: tool)
      let contents: [NSView] = [header, popup]
      let editor = NSStackView(views: contents)
      editor.orientation = .vertical
      editor.alignment = .leading
      editor.spacing = 8
      for child in editor.arrangedSubviews {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
      }
      editor.isHidden = module != selectedStyleModule
      moduleEditors[module] = editor
      styleOptions.addArrangedSubview(editor)
    }
    styleOptions.detachesHiddenViews = true
    for child in styleOptions.arrangedSubviews {
      child.translatesAutoresizingMaskIntoConstraints = false
      let width = child.widthAnchor.constraint(equalTo: styleOptions.widthAnchor)
      width.identifier = "style-editor-width"
      width.isActive = true
    }
    let layoutTitle = NSTextField(labelWithString: "Layout")
    layoutTitle.font = .systemFont(ofSize: 13, weight: .medium)
    layoutTitle.textColor = .secondaryLabelColor
    layoutSelector.setAccessibilityTitleUIElement(layoutTitle)
    let layoutHelp = form.text("Separate items or one shared item.")
    let layoutChoice = NSStackView(views: [
      form.controls([layoutTitle, layoutSelector]), layoutHelp,
    ])
    layoutChoice.orientation = .vertical
    layoutChoice.alignment = .leading
    layoutChoice.spacing = 2
    layoutChoice.widthAnchor.constraint(equalToConstant: 190).isActive = true
    layoutHelp.widthAnchor.constraint(equalTo: layoutChoice.widthAnchor).isActive = true
    let layoutRow = form.controls([wallpaper, layoutChoice])
    wallpaper.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    let layoutSection = form.group([
      form.row("", layoutRow, height: Self.menuBarLayoutSectionHeightBudget)
    ])
    layoutSection.identifier = NSUserInterfaceItemIdentifier("menu-bar-layout-section")
    _ = SystemSettingsForm(
      in: menuBarPage,
      views: [layoutSection, customization, styleDisclosure, styleOptions])
    selectStyleModule(selectedStyleModule)
    updateLayoutSelection()
  }

  func selectStyleModule(_ module: Module) {
    guard module != .overview else { return }
    selectedStyleModule = module
    customization.select(module)
    for (candidate, editor) in moduleEditors { editor.isHidden = candidate != module }
    // NSStackView may discard cross-view constraints when detaching a hidden editor.
    if let editor = moduleEditors[module] {
      if !styleOptions.constraints.contains(where: {
        $0.identifier == "style-editor-width" && $0.firstItem as? NSView === editor
      }) {
        let width = editor.widthAnchor.constraint(equalTo: styleOptions.widthAnchor)
        width.identifier = "style-editor-width"
        width.isActive = true
      }
    }
    styleOptions.needsLayout = true
  }
  @objc private func toggleStyleOptions() {
    styleOptions.isHidden.toggle()
    styleDisclosure.title =
      styleOptions.isHidden ? "Customize styles…" : "Hide styles"
    styleDisclosure.image = NSImage(
      systemSymbolName: styleOptions.isHidden ? "chevron.right" : "chevron.down",
      accessibilityDescription: nil)
    styleDisclosure.setAccessibilityExpanded(!styleOptions.isHidden)
  }

  @objc private func layoutChanged() {
    guard (0...1).contains(layoutSelector.selectedSegment) else { return }
    settings.separateItems = layoutSelector.selectedSegment == 0
    individualOrder = settings.readouts
    updateLayoutSelection()
    updatePreview()
    onChange?(settings)
  }

  private func updateLayoutSelection() {
    layoutSelector.selectedSegment = settings.separateItems ? 0 : 1
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
  func updateProcessGrouping(_ value: TrafficGrouping, revision: String) {
    settings.processGrouping = value
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
    settings.separateItems = value.separateItems
    settings.readouts = value.readouts
    individualOrder = value.readouts
    settings.styles = value.styles
    settings.appearances = value.appearances
    for (module, popup) in styleMenus {
      popup.selectItem(withTitle: settings.style(for: module).title)
    }
    for (module, popup) in sizeMenus {
      popup.selectItem(withTitle: settings.appearance(for: module).size.title)
    }
    applyAppearance()
    updateLayoutSelection()
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
      // The embedded host has no tab selector. Remove its standalone top reserve
      // before autoresizing so the form stays inside the shared page inset.
      tabs.tabViewType = .noTabsNoBorder
      if let hostedRoot { tabs.frame = hostedRoot.bounds.insetBy(dx: 22, dy: 0) }
    }
    for page in [generalPage, menuBarPage] {
      for form in page.subviews.compactMap({ $0 as? SystemSettingsForm }) {
        // The main window already owns titlebar clearance. AppKit's automatic
        // scroll inset would reserve the overlapping native toolbar band again.
        form.automaticallyAdjustsContentInsets = false
        form.contentInsets = .init()
      }
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
    for picker in styleMenus.values { picker.update(settings: settings) }
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
      popup.isEnabled = style.usesFont
    }
    styleMenus[.battery]?.isEnabled =
      !settings.batteryMenu.customizeStates
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
    sensor.superview?.needsLayout = true
  }
  @objc private func sensorChanged() {
    guard sensorKeys.indices.contains(sensor.indexOfSelectedItem) else { return }
    settings.sensorKey = sensorKeys[sensor.indexOfSelectedItem]
    let effective = settings.style(for: .sensors)
    settings.styles[Module.sensors.rawValue] = effective
    styleMenus[.sensors]?.update(settings: settings)
    settings.validate()
    updateLayoutSelection()
    updatePreview()
    onChange?(settings)
  }
  @objc private func changed() {
    if builtPages.contains(.menuBar) {
      for (module, popup) in styleMenus {
        settings.styles[module.rawValue] =
          popup.selectedStyle ?? settings.style(for: module)
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
    updateLayoutSelection()
    updatePreview()
    if builtPages.contains(.general) { message.stringValue = "" }
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
