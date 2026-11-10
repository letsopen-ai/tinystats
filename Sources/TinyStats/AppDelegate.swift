import AppKit
import TinyStatsCore
import UserNotifications

struct PresentationTransitions {
  private var last: String?
  mutating func changed(to value: String) -> Bool {
    guard last != value else { return false }
    last = value
    return true
  }
}

/// Shared by the real status menu and the welcome illustration to prevent copy drift.
enum StatusMenuTitles {
  static let pause = "Pause monitoring"
  static let resume = "Resume monitoring"
  static let settings = "Settings…"
  static let welcome = "Show welcome tour"
  static let activity = "Open Activity Monitor"
  static let quit = "Quit TinyStats"
  static let tour = [pause, settings, welcome, activity, quit]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
  private static let preferenceStore = ApplicationStartup.preferenceStore()
  private var settings = ApplicationStartup.initialSettings(from: preferenceStore)
  private var weatherLocationReader: WeatherLocationReader?
  private var weatherCities: [WeatherLocation] = []
  private var weatherCitiesLoading = false
  private var weatherCitiesStatus = "Open Weather to load saved cities"
  private var weatherSourceStatus = "Waiting for location"
  private var worker: MonitorWorker?
  private let statusItems: StatusItemController
  private(set) var popover: NSPopover?
  let popoverInteraction: PopoverInteraction
  private(set) var detail: DetailController?
  private var welcome: WelcomeController?
  private var preferences: PreferencesController?
  private var weatherPreferences: WeatherSettingsController?
  private var internetPreferences: InternetSettingsController?
  private var historyController: HistoryController?
  private var historyStorageActionPending = false
  private var historyQuit: HistoryQuitCoordinator?
  private var calendarPreferences: CalendarSettingsController?
  private var calendarReader: CalendarAgendaReader?
  private var sleeping = false
  private var snapshot = Snapshot()
  private var history: [HistoryPoint] = []
  private var paused = false
  private let lifecycleObservers = ApplicationLifecycleObservers()
  private var clockDate = Date()
  private var previewWindow: NSWindow?
  private let reportsMainPresentation =
    CommandLine.arguments.contains("--preview-main-report")
    && ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"] != nil
  private var mainPresentationTransitions = PresentationTransitions()
  private var previewMainCloseDeadline: TimeInterval?
  private var mainPresentationStarted = false
  private var mainWindowVisible: Bool {
    previewWindow?.isVisible == true && previewWindow?.isMiniaturized != true
  }
  private let reportsHistoryPresentation = CommandLine.arguments.contains("--preview-history")
  private let reportsPopoverPresentation = CommandLine.arguments.contains("--preview-popover")
  private var pendingPopoverModule: Module?
  var previewCycleProbe: PopoverCycleProbe?
  private var previewCycleModule: Module = .network
  private var previewPopoverCloseDelay: TimeInterval?
  private var previewPopoverCloseDeadline: TimeInterval?
  private var previewHistoryCloseDeadline: TimeInterval?
  private var previewQuitDeadline: TimeInterval?
  private var historyPresentationTransitions = PresentationTransitions()
  private var closingPopover: NSPopover?
  private var pendingStatusOpen: (module: Module, button: NSView)?
  private let clickTrace: MenuBarClickTrace
  private let presentationReporter: ((Bool) -> Void)?
  private let cycleReporter: ((PopoverCycleProbe.Event) -> Void)?
  /// Reads only when the Power dropdown is shown; changes only on an explicit click.
  let energyModes: EnergyModeController

  init(
    statusItems: StatusItemController = StatusItemController(),
    popoverInteraction: PopoverInteraction = PopoverInteraction(),
    settings: Settings? = nil,
    snapshot: Snapshot = Snapshot(), history: [HistoryPoint] = [],
    clickTrace: MenuBarClickTrace = MenuBarClickTrace(),
    presentationReporter: ((Bool) -> Void)? = nil,
    cycleReporter: ((PopoverCycleProbe.Event) -> Void)? = nil,
    energyModes: EnergyModeController? = nil
  ) {
    self.statusItems = statusItems
    self.energyModes = energyModes ?? EnergyModeController()
    self.snapshot = snapshot
    self.history = history
    self.popoverInteraction = popoverInteraction
    self.clickTrace = clickTrace
    self.presentationReporter = presentationReporter
    self.cycleReporter = cycleReporter
    super.init()
    if let settings { self.settings = settings }
    popoverInteraction.onEvent = { [weak self] event, result in
      self?.traceClick(event, result: result)
    }
    self.energyModes.onChange = { [weak self] in self?.updateEnergyModePresentation() }
  }

  private func updateEnergyModePresentation() {
    detail?.energyMode = energyModes.presentation(
      currentSource: PowerSourceKind.current(
        snapshot.batteries, lastKnown: statusItems.lastConfirmedSource))
  }

  /// One unprivileged read each time the Power page is presented in the dropdown.
  private func refreshEnergyModesIfShowing(_ module: Module) {
    guard module == .battery else { return }
    updateEnergyModePresentation()
    energyModes.refresh()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A second launch activates the existing instance rather than leaving duplicate samplers.
    if let identifier = Bundle.main.bundleIdentifier,
      NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
      })
    {
      NSApp.terminate(nil)
      return
    }
    if CommandLine.arguments.contains("--preview-popover-cycles") {
      guard
        let configuration = PopoverCycleProbe.Configuration.parse(
          arguments: CommandLine.arguments,
          preferencesDomain: ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"]),
        configuration.permits(settings)
      else {
        FileHandle.standardError.write(
          Data("TinyStats: invalid isolated cycle probe configuration\n".utf8))
        NSApp.terminate(nil)
        return
      }
      previewCycleProbe = .init(configuration: configuration)
    }
    rebuildItems()
    setupMenu()
    let worker = MonitorWorker(
      historyStore: ApplicationStartup.historyStore(),
      clock: { [weak self] date in self?.receiveClock(date) },
      history: { [weak self] projection in self?.historyController?.update(projection) },
      receive: { [weak self] snapshot, history, alerts in
        self?.receive(snapshot, history: history, alerts: alerts)
      })
    self.worker = worker
    energyModes.schedule = { [weak worker] work in worker?.perform(work) }
    worker.start(settings)
    refreshWeatherSource()
    refreshWeatherCities()
    lifecycleObservers.start { [weak self] event in
      guard let self else { return }
      switch event {
      case .sleep:
        self.interruptCycleProbe()
        self.sleeping = true
        self.invalidateRemoteSnapshots()
        self.worker?.setSleeping(true, settings: self.settings)
        self.refreshCalendarDemand()
      case .wake:
        self.sleeping = false
        self.invalidateRemoteSnapshots()
        self.worker?.setSleeping(false, settings: self.settings)
        self.refreshCalendarDemand()
      case .power:
        self.worker?.powerChanged()
      case .clock:
        ClockMenuRenderer.invalidate()
        self.detail?.invalidateWeatherFormatting()
        self.worker?.invalidateClock()
        self.receiveClock(Date())
      }
    }
    let arguments = CommandLine.arguments
    let requestedModule: Module = {
      guard let index = arguments.firstIndex(of: "--preview-module"), index + 1 < arguments.count,
        let module = Module(rawValue: arguments[index + 1])
      else { return .overview }
      return module
    }()
    if arguments.contains("--preview") {
      prepareDetails()
      detail?.selected = requestedModule
      detail?.isPopoverPresentation = false
      let window = MainWindow()
      window.title = "TinyStats Preview"
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentViewController = detail
      detail?.view.frame.size = window.contentView?.bounds.size ?? window.contentLayoutRect.size
      window.appearance = settings.theme.nativeAppearance
      window.center()
      window.makeKeyAndOrderFront(nil)
      previewWindow = window
      worker.setDetails(true, module: detail?.selected ?? .overview)
      refreshCalendarDemand()
      NSApp.activate(ignoringOtherApps: true)
    } else if arguments.contains("--preview-popover") {
      if let index = arguments.firstIndex(of: "--preview-popover-close-after"),
        index + 1 < arguments.count, let delay = Double(arguments[index + 1]),
        delay.isFinite, delay > 0, delay <= 3600
      {
        previewPopoverCloseDelay = delay
      }
      previewCycleModule = requestedModule
      if previewCycleProbe == nil { pendingPopoverModule = requestedModule }
      NSApp.activate(ignoringOtherApps: true)
    }
    if arguments.contains("--preview-history") {
      showHistory(requestedModule)
      if let index = arguments.firstIndex(of: "--preview-history-close-after"),
        index + 1 < arguments.count, let delay = Double(arguments[index + 1]),
        delay.isFinite, delay > 0, delay <= 3600
      {
        previewHistoryCloseDeadline = ProcessInfo.processInfo.systemUptime + delay
      }
    }
    if reportsHistoryPresentation,
      ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"] != nil,
      let index = arguments.firstIndex(of: "--preview-quit-after"), index + 1 < arguments.count,
      let delay = Double(arguments[index + 1]), delay.isFinite, delay > 0, delay <= 3600
    {
      previewQuitDeadline = ProcessInfo.processInfo.systemUptime + delay
    }
    if arguments.contains("--preview-settings") || arguments.contains("--preview-settings-general")
    {
      presentSettings(
        initialPage: arguments.contains("--preview-settings-general") ? .general : .menuBar)
    }
    if reportsMainPresentation {
      reportMainPresentation()
      if let index = arguments.firstIndex(of: "--preview-main-close-after"),
        index + 1 < arguments.count,
        let delay = Double(arguments[index + 1]), delay.isFinite, delay > 0, delay <= 3600
      {
        previewMainCloseDeadline = ProcessInfo.processInfo.systemUptime + delay
      }
    }
    if let initialStep = WelcomePresentation.prepareLaunch(
      in: Self.preferenceStore, arguments: arguments,
      isolated: ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"] != nil)
    {
      presentWelcome(initialStep: initialStep)
    }
  }

  private func openPendingPopover() {
    guard let module = pendingPopoverModule, let button = statusItems.firstButton,
      let window = button.window, window.isVisible, window.frame.height > 0,
      !button.visibleRect.isEmpty
    else { return }
    // Status items can initially have a zero-height proxy window. Wait on the
    // existing shared sample deliveries; never fabricate an anchor or add a timer.
    showDetails(relativeTo: button, module: module)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag && popover?.isShown != true { showSettings() }
    return false
  }
  private func prepareDetails() {
    guard detail == nil else { return }
    let detail = DetailController(snapshot: snapshot, history: history)
    detail.settings = settings
    detail.isPopoverPresentation = true
    detail.onOpenInWindow = { [weak self] in self?.openDetailsInWindow() }
    detail.view.appearance = settings.theme.nativeAppearance
    let popover = NSPopover()
    self.detail = detail
    self.popover = popover
    // Native transient dismissal can consume the click on another status item
    // before its action can switch pages. Own dismissal while this popover is open.
    popover.behavior = .applicationDefined
    popover.contentSize = SystemStyle.popoverSize
    popover.contentViewController = detail
    popover.delegate = self
    popover.appearance = settings.theme.nativeAppearance
    detail.onMonitoringDemand = { [weak self] module in
      guard let self else { return }
      let visible = self.mainWindowVisible || self.popover?.isShown == true
      self.worker?.setDetails(visible && module != nil, module: module ?? .overview)
      self.refreshCalendarDemand()
    }
    detail.onSelect = { [weak self] module in
      if let self, self.previewCycleProbe != nil, module != self.previewCycleModule {
        self.interruptCycleProbe()
      }
      self?.worker?.setDetailModule(module)
      self?.refreshCalendarDemand()
      if module == .weather { self?.refreshWeatherCities(force: true) }
    }
    detail.weatherCities = weatherCities
    detail.weatherSourceStatus = weatherSourceStatus
    detail.weatherCitiesStatus = weatherCitiesStatus
    detail.onWeatherCity = { [weak self] city in
      guard let self else { return }
      var value = city == nil ? WeatherSettings.currentLocationDefault : WeatherSettings()
      value.enabled = self.settings.weather.enabled
      value.location =
        city
        ?? (self.settings.weather.source == .currentLocation ? self.settings.weather.location : nil)
      value.revision = UUID().uuidString
      self.publishWeatherSettings(value)
      self.refreshWeatherSource()
    }
    detail.onWeatherEnabled = { [weak self] enabled in
      guard let self else { return }
      var value = self.settings.weather
      if enabled && value.source == .manual && value.location == nil {
        value.source = .currentLocation
      }
      value.enabled = enabled
      value.revision = UUID().uuidString
      self.publishWeatherSettings(value)
      self.refreshWeatherSource()
      if enabled { self.refreshWeatherCities(force: true) }
    }
    detail.onWeatherLocationRequest = { [weak self] in
      guard let self, self.settings.weather.enabled,
        self.settings.weather.source == .currentLocation, !self.paused, !self.sleeping
      else { return }
      self.refreshWeatherSource()
      self.weatherLocationReader?.requestAuthorization()
    }
    detail.onEnergyMode = { [weak self] source, mode in
      self?.energyModes.select(mode, for: source)
    }
    detail.onEnergySettings = { [weak self] in self?.energyModes.openEnergySettings() }
    detail.onProcessGrouping = { [weak self] mode in
      guard let self, self.settings.processGrouping != mode else { return }
      self.interruptCycleProbe()
      self.settings.processGrouping = mode
      if self.detail?.selected == .network {
        self.settings.networkTrafficRevision = UUID().uuidString
      }
      self.detail?.settings = self.settings
      self.settings.save(to: Self.preferenceStore)
      self.preferences?.updateProcessGrouping(mode, revision: self.settings.networkTrafficRevision)
      self.worker?.update(self.settings)
    }
    detail.onWeatherLocations = { [weak self] in self?.showWeatherSettings() }
    detail.onCalendarDate = { [weak self] _ in self?.refreshCalendarDemand() }
    detail.onCalendarSettings = { [weak self] in self?.showCalendarSettings() }
    if previewCycleProbe != nil {
      detail.onViewModeChange = { [weak self] in self?.interruptCycleProbe() }
    }
    detail.onHistory = { [weak self] module in self?.showHistory(module) }
    detail.onSettings = { [weak self] in self?.showSettings() }
    detail.onSettingsPage = { [weak self] page in self?.presentSettings(initialPage: page) }
    detail.onPause = { [weak self] in self?.togglePause() }
  }
  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    preferences?.windowWillReturnFieldEditor(sender, to: client)
  }
  func windowDidMiniaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === previewWindow else { return }
    detail?.monitoringVisibilityChanged(false)
    refreshCalendarDemand()
  }
  func windowDidDeminiaturize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === previewWindow else { return }
    detail?.update(snapshot, history: history)
    detail?.monitoringVisibilityChanged(true)
    preferences?.refreshVisibleContent()
    refreshCalendarDemand()
  }
  func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === previewWindow else { return }
    preferences?.refreshVisibleContent()
  }
  func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === previewWindow {
      worker?.setDetails(popover?.isShown == true)
      reportMainPresentation(closed: true)
      Task { @MainActor [weak self] in
        self?.previewWindow = nil
        self?.discardClosedDetails()
      }
    }
  }
  private func discardClosedDetails() {
    guard previewWindow?.isVisible != true, popover?.isShown != true else { return }
    popoverInteraction.stop()
    preferences?.disposeEmbedded()
    preferences = nil
    popover?.contentViewController = nil
    detail = nil
    popover = nil
    refreshCalendarDemand()
  }
  private func setupMenu() {
    let main = NSMenu()
    let appMenu = NSMenu()
    let root = NSMenuItem()
    root.submenu = appMenu
    main.addItem(root)
    let settings = NSMenuItem(
      title: StatusMenuTitles.settings, action: #selector(showSettings), keyEquivalent: ",")
    settings.target = self
    appMenu.addItem(settings)
    let welcome = NSMenuItem(
      title: StatusMenuTitles.welcome, action: #selector(showWelcome), keyEquivalent: "")
    welcome.target = self
    appMenu.addItem(welcome)
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: StatusMenuTitles.quit, action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let editRoot = NSMenuItem()
    editRoot.title = "Edit"
    editRoot.submenu = Self.makeEditMenu()
    main.addItem(editRoot)
    let fileRoot = NSMenuItem()
    fileRoot.title = "File"
    let file = NSMenu(title: "File")
    file.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileRoot.submenu = file
    main.insertItem(fileRoot, at: 1)
    let windowsRoot = NSMenuItem()
    windowsRoot.title = "Window"
    let windows = NSMenu(title: "Window")
    windows.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windows.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowsRoot.submenu = windows
    main.addItem(windowsRoot)
    NSApp.windowsMenu = windows
    NSApp.mainMenu = main
  }
  static func makeEditMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    return edit
  }
  /// The worker's main-actor delivery. Internal so owned-window regressions can drive the
  /// same power-source transition path without starting a collector.
  func receive(_ snapshot: Snapshot, history: [HistoryPoint], alerts: [AlertEvent]) {
    var snapshot = snapshot
    snapshot.internetChecks = snapshot.internetChecks.filtered(
      connectivity: settings.connectivityChecks, publicIP: settings.publicIPChecks,
      revision: settings.internetRevision, suspended: paused || sleeping,
      httpsCheck: settings.httpsCheck, pingCheck: settings.pingCheck)
    snapshot.weather = snapshot.weather.filtered(
      settings: settings.weather, suspended: paused || sleeping)
    self.snapshot = snapshot
    if let deadline = previewQuitDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
      previewQuitDeadline = nil
      NSApp.terminate(nil)
      return
    }
    if reportsMainPresentation { reportMainPresentation() }
    if let deadline = previewMainCloseDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
      previewMainCloseDeadline = nil
      previewWindow?.performClose(nil)
    }
    if reportsHistoryPresentation { reportHistoryPresentation() }
    if let deadline = previewHistoryCloseDeadline, ProcessInfo.processInfo.systemUptime >= deadline
    {
      previewHistoryCloseDeadline = nil
      historyController?.window?.close()
    }
    clockDate = snapshot.timestamp
    if !history.isEmpty { self.history = history }
    updateTitles()
    if let step = previewCycleProbe?.tick(
      at: ProcessInfo.processInfo.systemUptime, shown: popover?.isShown == true)
    {
      reportCycleEvent(step.event)
      switch step.command {
      case .show: pendingPopoverModule = previewCycleModule
      case .close: popover?.performClose(nil)
      case nil: break
      }
    }
    openPendingPopover()
    if let deadline = previewPopoverCloseDeadline, ProcessInfo.processInfo.systemUptime >= deadline
    {
      previewPopoverCloseDeadline = nil
      popover?.performClose(nil)
    }
    refreshCalendarDemand()
    calendarReader?.tick(at: snapshot.uptime, date: snapshot.timestamp)
    calendarPreferences?.updateClock(snapshot.timestamp)
    refreshWeatherSource()
    preferences?.update(snapshot, history: self.history)
    weatherPreferences?.update(
      snapshot.weather, uptime: snapshot.uptime, suspended: paused || sleeping)
    updateMenuBarPreviewContext()
    if let detail, popover?.isShown == true || mainWindowVisible {
      detail.settings = settings
      if detail.selected == .battery { updateEnergyModePresentation() }
      detail.update(snapshot, history: self.history)
    }
    for event in alerts where event.canDeliver(with: settings, suspended: paused || sleeping) {
      let content = UNMutableNotificationContent()
      content.title = event.title
      content.body = event.message
      content.sound = event.sound ? .default : nil
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: "tinystats.\(event.id)", content: content, trigger: nil))
    }
  }
  private func receiveClock(_ date: Date) {
    guard !paused && !sleeping else { return }
    clockDate = date
    updateTitles(clockOnly: true)
    preferences?.updateClock(date)
    if let detail, detail.selected == .clock,
      popover?.isShown == true || mainWindowVisible,
      detail.updateClock(date)
    {
      refreshCalendarDemand()
    }
  }
  private func rebuildItems(enforceOrder: Bool = false) {
    popover?.performClose(nil)
    statusItems.rebuild(
      settings: settings, target: self, action: #selector(statusClicked(_:)),
      enforceOrder: enforceOrder
    ) {
      [weak self] in self?.updateMenuBarPreviewContext()
    }
    updateTitles()
  }
  private func updateTitles(clockOnly: Bool = false) {
    statusItems.update(
      snapshot: snapshot, history: history, settings: settings, clockDate: clockDate,
      paused: paused, clockOnly: clockOnly)
    // A power-source change can hide the Power item; its dropdown must not outlive it,
    // and a click queued during a close animation must not reopen it later.
    if let pending = pendingStatusOpen, statusItems.hiddenModules.contains(pending.module) {
      pendingStatusOpen = nil
    }
    if popover?.isShown == true, closingPopover == nil, let selected = detail?.selected,
      statusItems.hiddenModules.contains(selected)
    {
      popover?.performClose(nil)
    }
  }
  private func updateMenuBarPreviewContext() {
    // Adopt legacy/native ⌘-drag order on the existing shared refresh, without a new observer/timer.
    // This is also the migration: retain the complete enabled set and the actual native order.
    if let order = statusItems.adoptableOrder, settings.adoptNativeReadoutOrder(order) {
      settings.save(to: Self.preferenceStore)
      preferences?.updateMenuBarSettings(settings)
    }
    guard let preferences else { return }
    statusItems.updatePreviewContext(preferences, paused: paused)
  }
  private func applyAppearance() {
    welcome?.window?.appearance = settings.theme.nativeAppearance
    preferences?.applyAppearance()
    weatherPreferences?.window?.appearance = settings.theme.nativeAppearance
    internetPreferences?.window?.appearance = settings.theme.nativeAppearance
    historyController?.window?.appearance = settings.theme.nativeAppearance
    calendarPreferences?.window?.appearance = settings.theme.nativeAppearance
    previewWindow?.appearance = settings.theme.nativeAppearance
    detail?.view.appearance = settings.theme.nativeAppearance
    popover?.appearance = settings.theme.nativeAppearance
  }
  @objc private func statusClicked(_ sender: NSStatusBarButton) {
    guard let entry = statusItems.entry(for: sender) else { return }
    if NSApp.currentEvent?.type == .rightMouseUp {
      if let event = NSApp.currentEvent { traceClick(event, result: "native-options-menu") }
      popover?.performClose(nil)
      let menu = Self.makeStatusMenu(paused: paused, target: self)
      entry.item.menu = menu
      sender.performClick(nil)
      entry.item.menu = nil
      return
    }
    // Command-drag belongs to native status-item placement, including during a popover.
    activateStatusButton(sender, event: NSApp.currentEvent)
  }

  /// Native action entry shared with keyboard/VoiceOver and owned-window regressions.
  func activateStatusButton(_ sender: NSView, event: NSEvent?) {
    guard let target = statusItems.targets.first(where: { $0.button === sender }) else { return }
    if let event, event.modifierFlags.contains(.command) {
      traceClick(event, result: "native-command-pass-through")
      return
    }
    let module = StatusItemController.module(
      for: event, button: sender, readout: target.readout, fallback: target.module,
      combined: statusItems.isCombined, mouseLocation: statusItems.mouseLocation())
    let transition = routeStatusClick(module: module, sender: sender)
    if let event { traceClick(event, result: "native \(transition)") }
  }

  /// The local monitor and tests enter here; there is no duplicate test-side transition logic.
  @discardableResult func routeStatusEvent(_ event: NSEvent) -> Bool {
    let dropdown = detail?.view.window
    guard event.type == .leftMouseDown, !event.modifierFlags.contains(.command),
      dropdown?.attachedSheet == nil,
      !(dropdown?.isVisible == true
        && dropdown?.frame.contains(statusItems.mouseLocation()) == true),
      let entry = statusItems.entry(for: event, dropdownWindow: dropdown)
    else { return false }
    let transition = routeStatusClick(module: entry.module, sender: entry.button)
    traceClick(event, result: "routed \(transition)")
    return true
  }

  private func traceClick(_ event: NSEvent, result: String) {
    guard clickTrace.isEnabled else { return }
    clickTrace.record(event, buttons: statusItems.targets, result: result)
  }

  @discardableResult private func routeStatusClick(
    module: Module, sender: NSView
  ) -> MenuBarClickRouter.Transition {
    let transition = MenuBarClickRouter.transition(
      open: popover?.isShown == true && closingPopover == nil ? detail?.selected : nil,
      clicked: module)
    switch transition {
    case .close:
      popover?.performClose(nil)
    case .switchModule(_, let module):
      // Replace the page without closing the presentation: no didClose can release the new page.
      if let detail {
        refreshEnergyModesIfShowing(module)
        detail.selected = module
        detail.update(snapshot, history: history)
        worker?.setDetails(true, module: module)
        refreshCalendarDemand()
      }
    case .open(let module):
      if closingPopover != nil {
        // Last click wins during native close animation. didClose opens it immediately;
        // no timer and no page switch into a presentation that is already disappearing.
        pendingStatusOpen = (module, sender)
      } else {
        showDetails(relativeTo: sender, module: module)
      }
    case .none: break
    }
    return transition
  }
  static func makeStatusMenu(paused: Bool, target: AppDelegate?) -> NSMenu {
    let menu = NSMenu()
    let pause = NSMenuItem(
      title: paused ? StatusMenuTitles.resume : StatusMenuTitles.pause,
      action: #selector(togglePause),
      keyEquivalent: "")
    pause.target = target
    menu.addItem(pause)
    let preferences = NSMenuItem(
      title: StatusMenuTitles.settings, action: #selector(showSettings), keyEquivalent: ",")
    preferences.target = target
    menu.addItem(preferences)
    let welcome = NSMenuItem(
      title: StatusMenuTitles.welcome, action: #selector(showWelcome), keyEquivalent: "")
    welcome.target = target
    menu.addItem(welcome)
    let activity = NSMenuItem(
      title: StatusMenuTitles.activity, action: #selector(openActivityMonitor), keyEquivalent: "")
    activity.target = target
    menu.addItem(activity)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: StatusMenuTitles.quit, action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    return menu
  }
  private func showDetails(relativeTo sender: NSView, module: Module) {
    prepareDetails()
    guard let detail, let popover else { return }
    detail.settings = settings
    detail.paused = paused
    if previewWindow == nil { refreshEnergyModesIfShowing(module) }
    detail.selected = module
    detail.update(snapshot, history: history)
    if let window = previewWindow {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      worker?.setDetails(true, module: module)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    popover.contentViewController = detail
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    let shown = popover.isShown
    worker?.setDetails(shown, module: detail.selected)
    reportPopoverPresentation(shown)
    reportCycleEvent(previewCycleProbe?.didShow(shown, at: ProcessInfo.processInfo.systemUptime))
    guard shown else {
      if previewCycleProbe != nil {
        pendingPopoverModule = nil
        discardClosedDetails()
      }
      return
    }
    pendingPopoverModule = nil
    if let delay = previewPopoverCloseDelay {
      previewPopoverCloseDeadline = ProcessInfo.processInfo.systemUptime + delay
      previewPopoverCloseDelay = nil
    }
    refreshCalendarDemand()
    popover.contentViewController?.view.window?.makeKey()
    NSApp.activate(ignoringOtherApps: true)
    if let window = detail.view.window {
      popoverInteraction.start(
        window: window,
        statusEvent: { [weak self] event in
          self?.statusItems.hits(event, dropdownWindow: self?.detail?.view.window) ?? false
        },
        onStatusClick: { [weak self] event in
          self?.routeStatusEvent(event)
        },
        onDismiss: { [weak self] in self?.popover?.performClose(nil) })
    } else {
      popover.performClose(nil)
    }
  }
  func popoverWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSPopover, closing === popover else { return }
    closingPopover = closing
  }

  func popoverDidClose(_ notification: Notification) {
    guard let closed = notification.object as? NSPopover, closed === popover else { return }
    // Account for the completed close even if AppKit has already re-shown this instance.
    // Only teardown is conditional on isShown; diagnostic accounting must not be skipped.
    reportPopoverPresentation(false)
    reportCycleEvent(previewCycleProbe?.didClose(at: ProcessInfo.processInfo.systemUptime))
    closingPopover = nil
    guard !closed.isShown else { return }
    popoverInteraction.stop()
    previewPopoverCloseDeadline = nil
    if let pending = pendingStatusOpen {
      pendingStatusOpen = nil
      // Revalidate at replay: the module may have hidden while the close animated.
      if !statusItems.hiddenModules.contains(pending.module),
        PopoverInteraction.screenRect(of: pending.button) != nil
      {
        showDetails(relativeTo: pending.button, module: pending.module)
        return
      }
    }
    if previewWindow?.isVisible != true {
      worker?.setDetails(false)
      Task { @MainActor [weak self] in self?.discardClosedDetails() }
    }
  }
  private func interruptCycleProbe() {
    reportCycleEvent(previewCycleProbe?.interrupt(at: ProcessInfo.processInfo.systemUptime))
  }
  private func reportCycleEvent(_ event: PopoverCycleProbe.Event?) {
    guard let event else { return }
    cycleReporter?(event)
    FileHandle.standardOutput.write(Data(event.line.utf8))
    if event.kind == .failed { pendingPopoverModule = nil }
  }
  private func reportPopoverPresentation(_ shown: Bool) {
    presentationReporter?(shown)
    guard reportsPopoverPresentation else { return }
    // Diagnostic launch only: the harness must reject a closed popover being
    // mislabeled as an open-window measurement. No user data or file writes.
    FileHandle.standardOutput.write(
      Data("TinyStats:popover=\(shown ? "shown" : "closed")\n".utf8))
  }
  private func reportMainPresentation(closed: Bool = false) {
    guard reportsMainPresentation else { return }
    let window = previewWindow
    let other =
      NSApp.windows.contains {
        $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
      } || window?.attachedSheet != nil || popover?.isShown == true
    let state: String
    if other {
      state = "other-window"
    } else if closed || window == nil {
      state = "closed"
    } else if mainWindowVisible {
      state = "shown"
    } else {
      state = "other-window"
    }  // Minimized/ordered-out is not a verified normal close.
    if state == "shown" { mainPresentationStarted = true }
    emitMainPresentation(state)
  }
  private func emitMainPresentation(_ state: String) {
    guard reportsMainPresentation, mainPresentationTransitions.changed(to: state) else { return }
    FileHandle.standardOutput.write(Data("TinyStats:main=\(state)\n".utf8))
  }
  private func reportHistoryPresentation(closed: Bool = false) {
    guard reportsHistoryPresentation else { return }
    let window = historyController?.window
    let other =
      NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== window }
      || window?.attachedSheet != nil || popover?.isShown == true
    let state =
      other
      ? "other-window"
      : !closed && window?.isVisible == true && window?.isMiniaturized != true ? "shown" : "closed"
    emitHistoryPresentation(state)
  }
  private func emitHistoryPresentation(_ state: String) {
    guard reportsHistoryPresentation, historyPresentationTransitions.changed(to: state) else {
      return
    }
    FileHandle.standardOutput.write(Data("TinyStats:history=\(state)\n".utf8))
  }
  private func reportOtherBenchmarkWindow() {
    if mainPresentationStarted { emitMainPresentation("other-window") }
    if reportsHistoryPresentation && historyController != nil {
      emitHistoryPresentation("other-window")
    }
    guard reportsPopoverPresentation else { return }
    FileHandle.standardOutput.write(Data("TinyStats:popover=other-window\n".utf8))
  }
  @objc private func togglePause() {
    interruptCycleProbe()
    paused.toggle()
    invalidateRemoteSnapshots()
    worker?.setPaused(paused, settings: settings)
    refreshCalendarDemand()
    detail?.paused = paused
    updateTitles()
    updateMenuBarPreviewContext()
  }
  @objc private func openActivityMonitor() {
    NSWorkspace.shared.open(
      URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
  }
  private func showHistory(_ module: Module) {
    reportOtherBenchmarkWindow()
    popover?.performClose(nil)
    if let historyController {
      historyController.select(module)
      historyController.showWindow(nil)
      historyController.window?.makeKeyAndOrderFront(nil)
    } else {
      let controller = HistoryController(
        module: module, settings: settings,
        persistenceAvailable: ApplicationStartup.historyDirectory() != nil)
      controller.setStorageBusy(historyStorageActionPending)
      controller.onPersistence = { [weak self] enabled in self?.changeHistoryPersistence(enabled) }
      controller.onClear = { [weak self] in self?.clearRecordedHistory() }
      controller.onRange = { [weak self] range in
        self?.worker?.setHistoryRange(range)
        self?.reportHistoryPresentation()
      }
      controller.onClose = { [weak self] in
        self?.reportHistoryPresentation(closed: true)
        self?.historyController = nil
      }
      historyController = controller
      controller.showWindow(nil)
      worker?.setHistoryRange(controller.range)
      reportHistoryPresentation()
    }
    NSApp.activate(ignoringOtherApps: true)
  }
  private func changeHistoryPersistence(_ enabled: Bool) {
    guard !historyStorageActionPending, let worker else { return }
    historyStorageActionPending = true
    historyController?.setStorageBusy(true)
    preferences?.setHistoryStorageBusy(true)
    welcome?.setHistoryBusy(true)
    settings.persistHistory = enabled
    settings.save(to: Self.preferenceStore)
    preferences?.updateHistoryPersistence(enabled)
    detail?.settings = settings
    worker.setHistoryPersistence(enabled) { [weak self] in self?.historyStorageActionFinished() }
  }
  private func clearRecordedHistory() {
    guard !historyStorageActionPending, let worker else { return }
    historyStorageActionPending = true
    historyController?.setStorageBusy(true)
    preferences?.setHistoryStorageBusy(true)
    welcome?.setHistoryBusy(true)
    worker.clearHistory { [weak self] in self?.historyStorageActionFinished() }
  }
  private func historyStorageActionFinished() {
    historyStorageActionPending = false
    historyController?.setStorageBusy(false)
    preferences?.setHistoryStorageBusy(false)
    welcome?.setHistoryBusy(false)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if historyQuit?.replied == true { return .terminateNow }
    if historyQuit?.waiting == true { return .terminateLater }
    guard let worker, settings.persistHistory || historyStorageActionPending else {
      return .terminateNow
    }
    let quit = HistoryQuitCoordinator { NSApp.reply(toApplicationShouldTerminate: true) }
    historyQuit = quit
    quit.begin { completion in worker.finishHistory(completion: completion) }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) {
    popoverInteraction.stop()
    lifecycleObservers.stop()
  }
  @objc private func showWelcome() {
    WelcomePresentation.recordShown(in: Self.preferenceStore)
    presentWelcome()
  }
  private func presentWelcome(initialStep: Int = 0) {
    reportOtherBenchmarkWindow()
    popover?.performClose(nil)
    if let welcome,
      welcome.window?.isVisible == true || welcome.window?.isMiniaturized == true
    {
      NSApp.activate(ignoringOtherApps: true)
      welcome.window?.deminiaturize(nil)
      welcome.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = WelcomeController(
      settings: { [weak self] in self?.settings ?? Settings() }, initialStep: initialStep)
    controller.onMenuBarChange = { [weak self] value in
      guard let self else { return }
      self.applyPreferences(value)
      self.preferences?.updateMenuBarSettings(self.settings)
    }
    controller.onHistoryPersistence = { [weak self] in self?.changeHistoryPersistence($0) }
    controller.onWeather = { [weak self] in
      self?.presentSettings(initialPage: .general)
      self?.detail?.selected = .weather
    }
    controller.onInternet = { [weak self] in self?.showInternetSettings() }
    controller.onNotifications = { [weak self] in self?.showSettings() }
    controller.onHistory = { [weak self] in self?.showHistory(.cpu) }
    controller.onSettings = { [weak self] in self?.showSettings() }
    controller.onOverview = { [weak self] in
      self?.presentSettings(initialPage: .general)
      self?.detail?.selected = .overview
    }
    controller.onMenuBarSettings = { [weak self] in self?.presentSettings(initialPage: .menuBar) }
    controller.onClose = { [weak self, weak controller] in
      Task { @MainActor [weak self, weak controller] in
        if self?.welcome === controller { self?.welcome = nil }
      }
    }
    controller.setHistoryBusy(historyStorageActionPending)
    welcome = controller
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
  private func applyPreferences(_ value: Settings) {
    let settings = PreferencesApplication.merging(value, current: self.settings)
    let rebuild =
      self.settings.separateItems != settings.separateItems
      || self.settings.readouts != settings.readouts
    self.settings = settings
    settings.save(to: Self.preferenceStore)
    self.worker?.update(settings)
    self.detail?.settings = settings
    self.refreshCalendarDemand()
    if rebuild { self.rebuildItems(enforceOrder: true) } else { self.updateTitles() }
    self.applyAppearance()
    if !rebuild { self.updateMenuBarPreviewContext() }
  }
  private func openDetailsInWindow() {
    guard let detail else { return }
    promoteDetailsToWindow(detail)
    previewWindow?.deminiaturize(nil)
    previewWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  private func promoteDetailsToWindow(_ detail: DetailController) {
    detail.isPopoverPresentation = false
    // Stop transient-only event handling before promoting the same controller.
    popoverInteraction.stop()
    // Move the same controller out of the popover before closing it.
    if previewWindow == nil {
      let origin = detail.view.window?.frame.origin
      let window = MainWindow()
      window.title = "TinyStats"
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.appearance = settings.theme.nativeAppearance
      previewWindow = window
      popover?.contentViewController = nil
      window.contentViewController = detail
      detail.view.frame.size = window.contentView?.bounds.size ?? window.contentLayoutRect.size
      if let origin { window.setFrameOrigin(origin) } else { window.center() }
      window.makeKeyAndOrderFront(nil)
      popover?.performClose(nil)
    }
  }
  @objc private func showSettings() { presentSettings(initialPage: .general) }
  private func presentSettings(initialPage: PreferencesController.Page) {
    reportOtherBenchmarkWindow()
    prepareDetails()
    guard let detail else { return }
    promoteDetailsToWindow(detail)
    previewWindow?.title = "TinyStats"
    if let preferences, let content = preferences.embeddedView(page: initialPage) {
      detail.showSettingsView(content, page: initialPage)
      previewWindow?.deminiaturize(nil)
      previewWindow?.makeKeyAndOrderFront(nil)
      preferences.refreshVisibleContent()
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let controller = PreferencesController(
      settings: settings, interfaces: snapshot.interfaces.map(\.name).sorted(), snapshot: snapshot,
      history: history, initialPage: initialPage)
    controller.onChange = { [weak self] value in self?.applyPreferences(value) }
    controller.setHistoryStorageBusy(historyStorageActionPending)
    controller.onHistoryPersistence = { [weak self] enabled in
      self?.changeHistoryPersistence(enabled)
    }
    controller.onHistory = { [weak self] in self?.showHistory(self?.detail?.selected ?? .cpu) }
    controller.onInternetSettings = { [weak self] in self?.showInternetSettings() }
    controller.onCalendarSettings = { [weak self] in self?.showCalendarSettings() }
    controller.onClockPreview = { [weak self] seconds in
      self?.worker?.setClockPreview(seconds: seconds)
    }
    controller.onAlertPermission = { callback in
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
        allowed, _ in Task { @MainActor in callback(allowed) }
      }
    }
    controller.onClose = { [weak self, weak controller] in
      self?.internetPreferences?.close()
      self?.calendarPreferences?.close()
      Task { @MainActor [weak self, weak controller] in
        if self?.preferences === controller { self?.preferences = nil }
      }
    }
    preferences = controller
    updateMenuBarPreviewContext()
    if let content = controller.embeddedView(page: initialPage) {
      detail.showSettingsView(content, page: initialPage)
    }
    worker?.setDetails(false)
    previewWindow?.deminiaturize(nil)
    previewWindow?.makeKeyAndOrderFront(nil)
    controller.refreshVisibleContent()
    refreshCalendarDemand()
    NSApp.activate(ignoringOtherApps: true)
  }

  private func prepareCalendarReader() -> CalendarAgendaReader {
    if let calendarReader { return calendarReader }
    let reader = CalendarAgendaReader()
    calendarReader = reader
    reader.onChange = { [weak self, weak reader] in
      guard let self, let reader else { return }
      self.detail?.calendarSnapshot = reader.snapshot
      if self.detail?.selected == .clock {
        self.detail?.update(self.snapshot, history: self.history)
      }
      self.calendarPreferences?.update(reader.snapshot, requesting: reader.requestingAccess)
    }
    return reader
  }
  private func refreshCalendarDemand() {
    let visible = popover?.isShown == true || mainWindowVisible
    let day =
      visible && detail?.showsSettings != true && detail?.selected == .clock
      ? detail?.selectedCalendarDate : nil
    let configurationVisible = calendarPreferences?.window?.isVisible == true
    if calendarReader == nil && (configurationVisible || (day != nil && settings.calendarEvents)) {
      _ = prepareCalendarReader()
    }
    calendarReader?.configure(
      enabled: settings.calendarEvents, selectedIDs: settings.calendarIDs, day: day,
      configurationVisible: configurationVisible, suspended: paused || sleeping)
  }
  private func showCalendarSettings() {
    reportOtherBenchmarkWindow()
    let previewDate = detail?.selected == .clock ? detail?.selectedCalendarDate : nil
    popover?.performClose(nil)
    if let calendarPreferences, calendarPreferences.window?.isVisible == true {
      calendarPreferences.window?.makeKeyAndOrderFront(nil)
      return
    }
    let reader = prepareCalendarReader()
    let controller = CalendarSettingsController(
      enabled: settings.calendarEvents, selectedIDs: settings.calendarIDs,
      firstWeekday: settings.calendarFirstWeekday)
    if let previewDate { controller.selectPreviewDate(previewDate) }
    calendarPreferences = controller
    controller.window?.appearance = settings.theme.nativeAppearance
    controller.onChange = { [weak self] enabled, ids in
      guard let self else { return }
      self.settings.calendarEvents = enabled
      self.settings.calendarIDs = ids
      self.settings.validate()
      self.preferences?.updateCalendarSettings(
        enabled: self.settings.calendarEvents, selectedIDs: self.settings.calendarIDs)
      self.settings.save(to: Self.preferenceStore)
      self.detail?.settings = self.settings
      self.refreshCalendarDemand()
    }
    controller.onPermission = { [weak reader] in reader?.requestAccess() }
    controller.onFirstWeekday = { [weak self] day in
      guard let self else { return }
      self.settings.calendarFirstWeekday = day
      self.settings.validate()
      self.preferences?.updateCalendarFirstWeekday(self.settings.calendarFirstWeekday)
      self.settings.save(to: Self.preferenceStore)
      self.detail?.settings = self.settings
      self.detail?.update(self.snapshot, history: self.history)
    }
    controller.onClose = { [weak self] in
      Task { @MainActor [weak self] in
        self?.calendarPreferences = nil
        self?.refreshCalendarDemand()
      }
    }
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    refreshCalendarDemand()
    controller.update(reader.snapshot, requesting: reader.requestingAccess)
    reader.tick(at: ProcessInfo.processInfo.systemUptime)
  }

  private func invalidateRemoteSnapshots() {
    if paused || sleeping { settings.weather.prepareForSession() }
    refreshWeatherSource()
    if settings.weather.enabled {
      settings.weather.revision = UUID().uuidString
      preferences?.updateWeatherSettings(settings.weather)
      weatherPreferences?.updateSettings(settings.weather)
    }
    snapshot.weather = .init()
    preferences?.update(snapshot, history: history)
    weatherPreferences?.update(
      snapshot.weather, uptime: snapshot.uptime, suspended: paused || sleeping)
    settings.internetRevision = UUID().uuidString
    snapshot.internetChecks = .init()
    preferences?.updateInternetSettings(
      connectivity: settings.connectivityChecks, publicIP: settings.publicIPChecks,
      revision: settings.internetRevision, httpsCheck: settings.httpsCheck,
      pingCheck: settings.pingCheck)
    detail?.update(snapshot, history: history)
  }
  private func showWeatherSettings() {
    reportOtherBenchmarkWindow()
    if let weatherPreferences, weatherPreferences.window?.isVisible == true {
      weatherPreferences.window?.makeKeyAndOrderFront(nil)
      return
    }
    refreshWeatherCities(force: true)
    let controller = WeatherSettingsController(settings: settings.weather, cities: weatherCities)
    controller.onChange = { [weak self] value in
      guard let self else { return }
      self.publishWeatherSettings(value)
      self.refreshWeatherSource()
    }
    controller.onClose = { [weak self] in
      Task { @MainActor [weak self] in self?.weatherPreferences = nil }
    }
    weatherPreferences = controller
    controller.updateCitiesStatus(weatherCitiesStatus)
    controller.window?.appearance = settings.theme.nativeAppearance
    controller.update(snapshot.weather, uptime: snapshot.uptime)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
  private func publishWeatherSettings(_ value: WeatherSettings) {
    var value = value
    value.prepareForChange(from: settings.weather)
    if paused || sleeping { value.prepareForSession() }
    settings.weather = value
    snapshot.weather = .init()
    settings.save(to: Self.preferenceStore)
    preferences?.updateWeatherSettings(value)
    weatherPreferences?.updateSettings(value)
    worker?.update(settings)
    detail?.settings = settings
    detail?.update(snapshot, history: history)
    updateTitles()
    preferences?.update(snapshot, history: history)
  }
  private func refreshWeatherSource() {
    // Hermetic QA/benchmark suites never read personal Weather cities or request location.
    guard ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"] == nil else { return }
    let wanted =
      settings.weather.enabled && settings.weather.source == .currentLocation
      && !paused && !sleeping
    if wanted, weatherLocationReader == nil {
      let reader = WeatherLocationReader()
      reader.onChange = { [weak self] location, status, clear in
        guard let self else { return }
        self.weatherSourceStatus = status
        self.detail?.weatherSourceStatus = status
        if self.settings.weather.source == .currentLocation,
          location != nil || clear, self.settings.weather.location != location
        {
          var value = self.settings.weather
          value.location = location
          value.revision = UUID().uuidString
          // Only this authorized, fresh Core Location callback may replace a current fix.
          self.settings.weather.location = location
          self.publishWeatherSettings(value)
        }
        self.weatherPreferences?.updateCurrentLocation(self.settings.weather, status: status)
      }
      weatherLocationReader = reader
    }
    weatherLocationReader?.configure(enabled: wanted)
    if wanted { weatherLocationReader?.tick() }
  }
  private func refreshWeatherCities(force: Bool = false) {
    guard !weatherCitiesLoading,
      settings.weather.enabled || force,
      ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"] == nil
    else { return }
    weatherCitiesLoading = true
    Task { [weak self] in
      let catalog = await Task.detached(priority: .utility) {
        try? SystemWeatherCities.read()
      }.value
      guard let self else { return }
      self.weatherCitiesLoading = false
      if let catalog {
        self.weatherCities = catalog.locations
        self.weatherCitiesStatus =
          catalog.truncated
          ? "Saved city limit · first \(SystemWeatherCities.cityLimit) cache entries"
          : catalog.locations.isEmpty
            ? "No cached saved cities · open Weather once, then reopen this page"
            : "\(catalog.locations.count) saved Weather cities · cached locally"
        self.detail?.weatherCities = catalog.locations
        self.weatherPreferences?.updateCities(catalog.locations)
      } else {
        self.weatherCitiesStatus =
          self.weatherCities.isEmpty
          ? "Saved cities unavailable · open Weather once, then reopen this page"
          : "Saved city cache unavailable · showing last successful read"
      }
      self.detail?.weatherCitiesStatus = self.weatherCitiesStatus
      self.weatherPreferences?.updateCitiesStatus(self.weatherCitiesStatus)
    }
  }
  private func showInternetSettings() {
    reportOtherBenchmarkWindow()
    if let internetPreferences, internetPreferences.window?.isVisible == true {
      internetPreferences.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = InternetSettingsController(
      connectivity: settings.connectivityChecks, publicIP: settings.publicIPChecks,
      httpsCheck: settings.httpsCheck, pingCheck: settings.pingCheck)
    controller.onChange = { [weak self] connectivity, publicIP, httpsCheck, pingCheck in
      guard let self,
        self.settings.connectivityChecks != connectivity
          || self.settings.publicIPChecks != publicIP || self.settings.httpsCheck != httpsCheck
          || self.settings.pingCheck != pingCheck
      else { return }
      self.settings.connectivityChecks = connectivity
      self.settings.publicIPChecks = publicIP
      self.settings.httpsCheck = httpsCheck
      self.settings.pingCheck = pingCheck
      self.settings.internetRevision = UUID().uuidString
      self.snapshot.internetChecks = .init()
      self.settings.save(to: Self.preferenceStore)
      self.preferences?.updateInternetSettings(
        connectivity: connectivity, publicIP: publicIP, revision: self.settings.internetRevision,
        httpsCheck: httpsCheck, pingCheck: pingCheck)
      self.worker?.update(self.settings)
      // Hide opt-out values immediately, before the next worker delivery.
      self.detail?.settings = self.settings
      self.detail?.update(self.snapshot, history: self.history)
    }
    controller.onClose = { [weak self] in
      Task { @MainActor [weak self] in self?.internetPreferences = nil }
    }
    internetPreferences = controller
    controller.window?.appearance = settings.theme.nativeAppearance
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
