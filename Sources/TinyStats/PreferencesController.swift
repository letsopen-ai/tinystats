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
  private lazy var keepHistory = NSButton(
    checkboxWithTitle: "Keep history between launches", target: nil, action: nil)
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
  private lazy var smart = NSButton(
    checkboxWithTitle: "Poll SMART health (5 min)", target: nil, action: nil)
  private lazy var interval = NSPopUpButton()
  private lazy var network = NSPopUpButton()
  private lazy var units = NSButton(checkboxWithTitle: "Use Fahrenheit", target: nil, action: nil)
  private lazy var alerts = NSButton(
    checkboxWithTitle: "Enable notifications",
    target: nil, action: nil)
  private lazy var login = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
  private lazy var clocks = NSTextField(string: "")
  private lazy var message = NSTextField(wrappingLabelWithString: "")
  private static let menuHelperText =
    "Each readout opens its own page. ⌘-drag menu bar items to reorder. Scroll wide previews horizontally."
  private lazy var menuMessage = NSTextField(wrappingLabelWithString: Self.menuHelperText)
  private var readouts: [Module: NSButton] = [:]
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
  private var styleMenus: [Module: NSPopUpButton] = [:]
  private let presetSelector = NSSegmentedControl(
    labels: MenuBarPreset.allCases.map(\.rawValue), trackingMode: .selectOne,
    target: nil, action: nil)
  private let styleOptions = NSView()
  private lazy var styleDisclosure = NSButton(
    title: "Customize readouts & styles…", target: self, action: #selector(toggleStyleOptions))
  private let onlineTimeOptions = NSView()
  private let historyOptions = NSView()
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

  private func add(_ child: NSView, _ parent: NSView, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
    child.frame = .init(x: x, y: y, width: w, height: h)
    child.autoresizingMask = y <= 32 ? [.maxYMargin] : [.minYMargin]
    if x >= 346 {
      child.autoresizingMask.insert(.minXMargin)
    } else if w >= 300
      || ((parent === menuBarPage || parent === styleOptions) && (x == 136 || x == 140))
    {
      child.autoresizingMask.insert(.width)
    }
    parent.addSubview(child)
  }
  private func label(_ text: String, _ parent: NSView, _ y: Int) {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    add(label, parent, 20, y, 150, 22)
  }
  private func intro(_ title: String, _ text: String, _ parent: NSView) {
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    add(heading, parent, 20, 554, 640, 28)
    let caption = NSTextField(labelWithString: text)
    caption.font = .systemFont(ofSize: 12)
    caption.textColor = .secondaryLabelColor
    add(caption, parent, 20, 526, 640, 22)
  }

  private func buildGeneralPage() {
    let general = generalPage
    intro(
      "General",
      "No account. No analytics. Local only, unless you enable Weather or advanced internet checks.",
      general
    )
    label("Appearance", general, 488)
    appearance.addItems(withTitles: AppTheme.allCases.map(\.title))
    appearance.selectItem(withTitle: settings.theme.title)
    appearance.setAccessibilityLabel("App appearance")
    appearance.target = self
    appearance.action = #selector(changed)
    add(appearance, general, 180, 486, 210, 26)
    label("Units", general, 456)
    units.state = settings.fahrenheit ? .on : .off
    units.target = self
    units.action = #selector(changed)
    add(units, general, 180, 454, 355, 24)
    label("Update interval", general, 424)
    interval.addItems(withTitles: ["1 second", "2 seconds · default", "5 seconds", "10 seconds"])
    interval.selectItem(at: [1.0, 2, 5, 10].firstIndex(of: settings.interval) ?? 1)
    add(interval, general, 180, 422, 355, 26)
    let cadence = NSTextField(
      labelWithString: "Low Power Mode uses at least 5 seconds. Sensors update at ≥5s.")
    cadence.font = .systemFont(ofSize: 10)
    cadence.textColor = .secondaryLabelColor
    add(cadence, general, 180, 400, 470, 18)
    label("Network interface", general, 368)
    network.addItems(withTitles: ["Auto · IPv4 / IPv6 primary route"] + interfaces)
    if settings.networkInterface != "auto", !interfaces.contains(settings.networkInterface) {
      network.addItem(withTitle: settings.networkInterface)
    }
    network.selectItem(
      withTitle: settings.networkInterface == "auto"
        ? "Auto · IPv4 / IPv6 primary route" : settings.networkInterface)
    add(network, general, 180, 366, 300, 26)
    smart.state = settings.monitorStorageHealth ? .on : .off
    label("Disks", general, 336)
    smart.target = self
    smart.action = #selector(changed)
    smart.toolTip =
      "Off: read drive health while disk details are open. On: also check every five minutes in the background."
    add(smart, general, 180, 334, 300, 24)
    login.state = LoginItemPreference.enabled ? .on : .off
    login.target = self
    login.action = #selector(loginChanged)
    label("Startup", general, 304)
    add(login, general, 180, 302, 300, 24)
    alerts.state = settings.alerts ? .on : .off
    alerts.target = self
    alerts.action = #selector(alertsChanged)
    label("Notifications", general, 272)
    add(alerts, general, 180, 270, 300, 24)
    let editRules = NSButton(title: "Edit alert rules…", target: self, action: #selector(showRules))
    editRules.bezelStyle = .rounded
    add(editRules, general, 496, 268, 170, 28)
    label("World clock zones", general, 240)
    clocks.stringValue = settings.worldClockInput
    clocks.placeholderString = "UTC, London office=Europe/London"
    add(clocks, general, 180, 238, 300, 26)
    let saveClocks = NSButton(title: "Save clocks", target: self, action: #selector(saveClocks))
    saveClocks.bezelStyle = .rounded
    add(saveClocks, general, 496, 238, 170, 28)
    let hint = NSTextField(
      labelWithString: "Up to six zones · optional Name=Zone, e.g. Work=Europe/London")
    hint.font = .systemFont(ofSize: 10)
    hint.textColor = .secondaryLabelColor
    add(hint, general, 180, 216, 486, 18)
    label("Time", general, 184)
    let formats = NSButton(
      title: "World clock format…", target: self, action: #selector(showWorldClockFormat))
    formats.bezelStyle = .rounded
    add(formats, general, 180, 182, 300, 28)
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    add(message, general, 20, 20, 646, 18)
    onlineTimeDisclosure.bezelStyle = .rounded
    onlineTimeDisclosure.setAccessibilityLabel("Online & Time advanced")
    onlineTimeDisclosure.setAccessibilityExpanded(false)
    add(onlineTimeDisclosure, general, 20, 150, 330, 28)
    add(onlineTimeOptions, general, 180, 98, 486, 50)
    onlineTimeOptions.isHidden = true
    let internet = NSButton(
      title: "Internet checks…", target: self, action: #selector(showInternetSettings))
    internet.bezelStyle = .rounded
    internet.setAccessibilityLabel("Internet checks")
    add(internet, onlineTimeOptions, 0, 20, 220, 28)
    let calendar = NSButton(
      title: "Calendar…", target: self, action: #selector(showCalendarSettings))
    calendar.bezelStyle = .rounded
    calendar.setAccessibilityLabel("Calendar settings")
    add(calendar, onlineTimeOptions, 240, 20, 246, 28)
    let advancedHint = NSTextField(
      labelWithString: "Optional · off by default · no requests until you enable")
    advancedHint.font = .systemFont(ofSize: 10)
    advancedHint.textColor = .secondaryLabelColor
    add(advancedHint, onlineTimeOptions, 0, 0, 486, 18)
    add(historyOptions, general, 0, 100, 686, 50)
    label("History", historyOptions, 24)
    keepHistory.state = settings.persistHistory ? .on : .off
    keepHistory.isEnabled = !historyStorageBusy
    keepHistory.target = self
    keepHistory.action = #selector(historyChanged)
    keepHistory.toolTip =
      "On by default. Off pauses saving; it does not delete the saved checkpoint. Clear history in History & storage."
    add(keepHistory, historyOptions, 180, 22, 310, 24)
    let storage = NSButton(
      title: "History & storage…", target: self, action: #selector(showHistoryStorage))
    storage.bezelStyle = .rounded
    add(storage, historyOptions, 496, 20, 170, 28)
    let historyScope = NSTextField(
      labelWithString: "Local numeric readings · up to 28 days · checkpoint up to 8.2 MiB")
    historyScope.font = .systemFont(ofSize: 10)
    historyScope.textColor = .secondaryLabelColor
    add(historyScope, historyOptions, 180, 0, 486, 18)

    let footer = NSTextField(
      labelWithString:
        "Most changes apply immediately · Clock zones use Save clocks · ⌘1–9 / ⌘0 switches pages")
    footer.font = .systemFont(ofSize: 10)
    footer.textColor = .secondaryLabelColor
    add(footer, general, 20, 0, 646, 18)
    for popup in [interval, network] {
      popup.target = self
      popup.action = #selector(changed)
    }
    interval.setAccessibilityLabel("Sampling interval")
    network.setAccessibilityLabel("Network interface")
    clocks.setAccessibilityLabel("World clock time zones")
  }

  private func buildMenuBarPage() {
    let menuBar = menuBarPage
    intro(
      "Menu Bar",
      "Changes apply immediately. Adaptive text and graphic colors. CPU cores use E/P colors.",
      menuBar)
    let presetLabel = NSTextField(labelWithString: "Presets")
    presetLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    add(presetLabel, menuBar, 20, 494, 100, 22)
    presetSelector.segmentStyle = .rounded
    presetSelector.target = self
    presetSelector.action = #selector(presetChanged)
    presetSelector.setAccessibilityLabel("Menu bar presets")
    presetSelector.toolTip =
      "Apply styles to enabled readouts. Separate stacks label + value within each separate menu bar item."
    add(presetSelector, menuBar, 136, 492, 440, 26)
    updatePresetSelection()
    let previewLabel = NSTextField(labelWithString: "LIVE MENU BAR PREVIEW")
    previewLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    previewLabel.textColor = .secondaryLabelColor
    add(previewLabel, menuBar, 20, 464, 640, 18)
    previewScroll.hasHorizontalScroller = true
    previewScroll.hasVerticalScroller = false
    previewScroll.scrollerStyle = .overlay
    previewScroll.autohidesScrollers = true
    previewScroll.drawsBackground = true
    previewScroll.backgroundColor = .windowBackgroundColor
    previewScroll.borderType = .bezelBorder
    previewScroll.documentView = preview
    previewScroll.setAccessibilityLabel("Live menu bar preview")
    add(previewScroll, menuBar, 18, 408, 656, 50)
    styleDisclosure.bezelStyle = .rounded
    styleDisclosure.setAccessibilityLabel("Customize menu bar readouts and styles")
    styleDisclosure.setAccessibilityExpanded(false)
    add(styleDisclosure, menuBar, 20, 374, 280, 26)
    add(styleOptions, menuBar, 0, 48, Int(designPageSize.width), 312)
    styleOptions.isHidden = true
    for (title, x, width) in [
      ("Readout", 20, 112), ("Style", 140, 200), ("Font", 350, 90),
    ] {
      let titleLabel = NSTextField(labelWithString: title)
      titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
      titleLabel.textColor = .secondaryLabelColor
      add(titleLabel, styleOptions, x, 288, width, 18)
    }
    for (i, module) in Module.allCases.filter({ $0 != .overview }).enumerated() {
      let y = 256 - i * 28
      let check = NSButton(
        checkboxWithTitle: module.title, target: self, action: #selector(changed))
      check.state = settings.readouts.contains(module) ? .on : .off
      readouts[module] = check
      add(check, styleOptions, 20, y, 112, 25)
      let popup = NSPopUpButton()
      popup.font = .systemFont(ofSize: 12)
      popup.addItems(
        withTitles: MenuBarStyle.available(for: module, sensorKey: settings.sensorKey).map(\.title))
      popup.selectItem(withTitle: settings.style(for: module).title)
      popup.target = self
      popup.action = #selector(changed)
      popup.setAccessibilityLabel("\(module.title) menu bar style")
      styleMenus[module] = popup
      add(popup, styleOptions, 136, y, 202, 25)
      let look = settings.appearance(for: module)
      let size = NSPopUpButton()
      size.font = .systemFont(ofSize: 11)
      size.addItems(withTitles: MenuBarSize.allCases.map(\.title))
      size.selectItem(withTitle: look.size.title)
      size.target = self
      size.action = #selector(changed)
      size.setAccessibilityLabel("\(module.title) menu bar font size")
      sizeMenus[module] = size
      add(size, styleOptions, 346, y, 96, 25)
      if module == .battery {
        let formats = NSButton(title: "…", target: self, action: #selector(showBatteryFormats))
        formats.bezelStyle = .rounded
        formats.setAccessibilityLabel("Battery menu bar formats")
        formats.toolTip = "Choose battery values and per-state styles"
        add(formats, styleOptions, 632, y, 38, 25)
      }
      if module == .clock {
        let formats = NSButton(title: "…", target: self, action: #selector(showClockFormats))
        formats.bezelStyle = .rounded
        formats.setAccessibilityLabel("Clock menu bar formats")
        formats.toolTip = "Edit clock formats and time zones"
        add(formats, styleOptions, 632, y, 38, 25)
      }
    }
    label("Menu bar sensor", styleOptions, 2)
    sensor.target = self
    sensor.action = #selector(sensorChanged)
    sensor.setAccessibilityLabel("Menu bar sensor")
    add(sensor, styleOptions, 180, 0, 470, 26)
    menuMessage.font = .systemFont(ofSize: 10)
    menuMessage.textColor = .secondaryLabelColor
    add(menuMessage, menuBar, 20, 24, 646, 20)

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
    let actualOrder =
      settings.separateItems && individualOrder.count == settings.readouts.count
        && Set(individualOrder) == Set(settings.readouts) ? individualOrder : settings.readouts
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
    styleMenus[.battery]?.isEnabled = !settings.batteryMenu.customizeStates
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
      settings.readouts =
        settings.readouts.filter { chosen.contains($0) }
        + chosen.filter { !settings.readouts.contains($0) }
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
    historyOptions.frame.origin.y += expanded ? -60 : 60
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
