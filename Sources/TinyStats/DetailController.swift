import AppKit
import TinyStatsCore

@MainActor
final class DetailController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  NSMenuDelegate, NSSearchFieldDelegate
{
  typealias Row = DetailRow
  /// Seed before the first view load, including opening Settings from a closed menu-bar app.
  convenience init(snapshot: Snapshot, history: [HistoryPoint]) {
    self.init(nibName: nil, bundle: nil)
    self.snapshot = snapshot
    self.history = history
    sensorTimeline.append(snapshot)
  }
  /// Inject the native table to verify reload behavior without replacing hardware collection.
  convenience init(table: NSTableView) {
    self.init(nibName: nil, bundle: nil)
    self.table = table
  }
  var isPopoverPresentation = false {
    didSet {
      guard isViewLoaded else { return }
      configurePresentation()
      refresh()
    }
  }
  var onOpenInWindow: (() -> Void)?
  private let headlinePlatter = PlatterView()
  private let readingsPlatter = PlatterView()
  private let tracePlatter = PlatterView()
  var glassEnvironment: () -> GlassSurface.Environment = { .current }
  private lazy var popoverMaterial = GlassSurface(environment: { [weak self] in
    self?.glassEnvironment() ?? .current
  })
  private let summaryScroll = PopoverScrollView()
  private let weatherScroll = PopoverScrollView()
  private let openWindowRow = MenuActionRow()
  private let footerSeparator = NSBox()
  private struct PopoverKeyViewLayout: Equatable {
    let window: ObjectIdentifier
    let module: Module
    let allReadings: Bool
    let paused: Bool
    let weatherEnabled: Bool
    let weatherSource: WeatherLocationSource
    let size: NSSize
  }
  private var popoverKeyViewLayout: PopoverKeyViewLayout?
  var onCalendarDate: ((Date) -> Void)?
  var onCalendarSettings: (() -> Void)?
  var calendarSnapshot = CalendarAgendaSnapshot()
  var selectedCalendarDate: Date { calendar?.selectedDate ?? snapshot.timestamp }
  var onSettingsPage: ((PreferencesController.Page) -> Void)?
  private var navigation: DetailNavigationCoordinator?
  var onMonitoringDemand: ((Module?) -> Void)?
  var showsSettings: Bool { navigation?.showsSettings == true }
  var onSelect: ((Module) -> Void)?
  var selected: Module = .overview {
    didSet {
      navigation?.leaveSettings()
      if isViewLoaded {
        navigation?.layout(in: view.bounds)
        configureTableStyle()
      }
      onMonitoringDemand?(selected)
      onSelect?(selected)
      refresh()
    }
  }
  var settings = Settings()
  var weatherCities: [WeatherLocation] = [] {
    didSet { if isViewLoaded { updateWeatherChoices() } }
  }
  var weatherSourceStatus = "Waiting for current location" {
    didSet { if isViewLoaded && selected == .weather { refresh() } }
  }
  var weatherCitiesStatus = "Saved Weather cities unavailable" {
    didSet { if isViewLoaded && selected == .weather { refresh() } }
  }
  var onProcessGrouping: ((TrafficGrouping) -> Void)?
  private var processGroupingControl: ProcessGroupingControl?
  private let processGroupingHeader = NSView()
  private let sensorCountLabel = NSTextField(labelWithString: "")
  private let appDisplayCache = ProcessAppDisplayCache()
  var onWeatherCity: ((WeatherLocation?) -> Void)?
  var onWeatherEnabled: ((Bool) -> Void)?
  var onWeatherLocationRequest: (() -> Void)?
  var onWeatherLocations: (() -> Void)?
  private var weatherCityPicker: NSPopUpButton?
  private var weatherControls: NSView?
  private var weatherEnable: NSButton?
  private var weatherAllow: NSButton?
  private var weatherChoices: [WeatherLocation?] = []
  private var weatherChoiceConfiguration: WeatherSettings?
  var snapshot = Snapshot(), history: [HistoryPoint] = []
  var onHistory: ((Module) -> Void)?
  var onSettings: (() -> Void)?, onPause: (() -> Void)?
  var paused = false {
    didSet {
      pauseButton.title = paused ? "Resume" : "Pause"
      refresh()
    }
  }
  private var sensorTimeline = SensorTimeline()
  private var selectedSensorIdentity: SensorBrowserIdentity?
  private let sensorSearch = SensorSearchField()
  private var reloadingRows = false
  private var displayedRows: [Row] = []
  private var renderedSensorSample: Double?
  private var renderedSensorFahrenheit = false
  private var rows: [Row] = []
  private let titleLabel = NSTextField(labelWithString: "Overview")
  private let valueLabel = NSTextField(labelWithString: "Starting…")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let chart = ChartView(frame: .zero)
  private var table = NSTableView()
  private var calendar: MonthCalendarView?
  private let pauseButton = MenuActionRow()
  private let clockFormatter = DateFormatter()
  private var weatherDateLabels: WeatherDateLabels?
  private var clockDate: Date?
  var onViewModeChange: (() -> Void)?
  var showsAllReadings = false {
    didSet {
      if oldValue != showsAllReadings { onViewModeChange?() }
      if isViewLoaded { refresh() }
    }
  }
  private var weatherDashboard: WeatherDashboardView?
  private lazy var solarCalculator = SolarDayCalculator()
  private var summary: SummaryDashboardView?
  private var detailScroll: NSScrollView?
  private let historyButton = MenuActionRow()
  private let readingsButton = MenuActionRow()
  override func loadView() {
    view = MainContentView(frame: NSRect(x: 0, y: 0, width: 700, height: 560))
    (view as? MainContentView)?.glassEnvironment = { [weak self] in
      self?.glassEnvironment() ?? .current
    }
    view.clipsToBounds = glassEnvironment().treatment == .glass
    (view as? MainContentView)?.onStyleChange = { [weak self] in self?.refreshAppearanceCells() }
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.group)
    view.addSubview(popoverMaterial)
    for platter in [headlinePlatter, readingsPlatter, tracePlatter] { view.addSubview(platter) }
    summaryScroll.drawsBackground = false
    summaryScroll.hasVerticalScroller = true
    summaryScroll.autohidesScrollers = true
    weatherScroll.drawsBackground = false
    weatherScroll.hasVerticalScroller = true
    weatherScroll.autohidesScrollers = true
    openWindowRow.target = self
    openWindowRow.action = #selector(openInWindow)
    view.addSubview(openWindowRow)
    footerSeparator.boxType = .separator
    view.addSubview(footerSeparator)
    historyButton.title = "History…"
    readingsButton.title = "All readings"
    pauseButton.title = paused ? "Resume" : "Pause"
    let navigation = DetailNavigationCoordinator(environment: glassEnvironment)
    self.navigation = navigation
    (view as? MainContentView)?.sidebarFrame = { [weak navigation] in
      navigation?.sidebar.frame ?? .zero
    }
    view.addSubview(navigation.sidebar, positioned: .below, relativeTo: popoverMaterial)
    navigation.onSelectModule = { [weak self] in self?.selected = $0 }
    navigation.onSettingsPage = { [weak self] in self?.onSettingsPage?($0) }
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .secondaryLabelColor
    valueLabel.font = .monospacedDigitSystemFont(
      ofSize: SystemStyle.TypeSize.value, weight: .semibold)
    subtitleLabel.font = .systemFont(ofSize: 12)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail
    add(titleLabel, x: 154, y: 518, w: 300, h: 20)
    add(valueLabel, x: 154, y: 474, w: 520, h: 39)
    add(subtitleLabel, x: 155, y: 449, w: 520, h: 20)
    add(chart, x: 156, y: 310, w: 520, h: 126)
    let scroll = PopoverScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    add(scroll, x: 150, y: 56, w: 532, h: 244)
    detailScroll = scroll
    view.addSubview(summaryScroll)
    view.addSubview(weatherScroll)
    let labelColumn = NSTableColumn(identifier: .init("label"))
    labelColumn.width = 280
    let valueColumn = NSTableColumn(identifier: .init("value"))
    valueColumn.width = 230
    table.addTableColumn(labelColumn)
    table.addTableColumn(valueColumn)
    table.headerView = nil
    table.backgroundColor = .clear
    table.rowHeight = 25
    table.intercellSpacing = .init(width: 0, height: 1)
    table.delegate = self
    table.dataSource = self
    let copyMenu = NSMenu()
    copyMenu.autoenablesItems = false
    copyMenu.delegate = self
    table.menu = copyMenu
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.setAccessibilityLabel("\(selected.title) details")
    scroll.documentView = table
    readingsButton.target = self
    readingsButton.action = #selector(detailOption)
    readingsButton.bezelStyle = .rounded
    readingsButton.controlSize = .small
    add(readingsButton, x: 568, y: 516, w: 108, h: 26)
    historyButton.target = self
    historyButton.action = #selector(openHistory)
    historyButton.bezelStyle = .rounded
    historyButton.controlSize = .small
    add(historyButton, x: 473, y: 516, w: 90, h: 26)
    pauseButton.target = self
    pauseButton.action = #selector(togglePause)
    pauseButton.bezelStyle = .rounded
    add(pauseButton, x: 600, y: 18, w: 72, h: 28)
    sensorSearch.placeholderString = "Search sensors or SMC keys"
    sensorSearch.setAccessibilityLabel("Search sensors or SMC keys")
    sensorSearch.sendsSearchStringImmediately = true
    sensorSearch.sendsWholeSearchString = false
    sensorSearch.delegate = self
    add(sensorSearch, x: 300, y: 516, w: 376, h: 26)
    sensorSearch.isHidden = true
    sensorCountLabel.font = .systemFont(ofSize: 11)
    sensorCountLabel.textColor = .secondaryLabelColor
    sensorCountLabel.alignment = .right
    view.addSubview(sensorCountLabel)
    sensorCountLabel.isHidden = true
    navigation.layout(in: view.bounds)
    configurePresentation()
    refresh()
  }
  private func configurePresentation() {
    popoverKeyViewLayout = nil
    navigation?.sidebar.isHidden = isPopoverPresentation
    (view as? MainContentView)?.usesPopoverMaterial = isPopoverPresentation
    popoverMaterial.isHidden = !isPopoverPresentation
    for platter in [headlinePlatter, readingsPlatter, tracePlatter] {
      platter.isHidden = !isPopoverPresentation
    }
    summaryScroll.isHidden = !isPopoverPresentation
    footerSeparator.isHidden = !isPopoverPresentation
    configureTableStyle()
    sensorSearch.usesNeutralFill = isPopoverPresentation
    openWindowRow.isHidden = !isPopoverPresentation
    if !isPopoverPresentation { openWindowRow.frame.origin.y = 60 }
    weatherScroll.isHidden = !isPopoverPresentation
    if let weatherDashboard {
      if isPopoverPresentation {
        weatherScroll.documentView = weatherDashboard
      } else {
        weatherScroll.documentView = nil
        view.addSubview(weatherDashboard)
      }
    }
    for scroll in [summaryScroll, weatherScroll, detailScroll].compactMap({
      $0 as? PopoverScrollView
    }) {
      scroll.fadesBottom = isPopoverPresentation
    }
    summary?.usesPopoverLayout = isPopoverPresentation
    if let summary {
      if isPopoverPresentation {
        summaryScroll.documentView = summary
      } else {
        summaryScroll.documentView = nil
        view.addSubview(summary)
      }
    }
    for button in [historyButton, openWindowRow, readingsButton, pauseButton] {
      button.usesIconPresentation = isPopoverPresentation
      button.isBordered = !isPopoverPresentation
      button.bezelStyle = isPopoverPresentation ? .recessed : .rounded
      button.alignment = .center
      button.font = .systemFont(ofSize: 12)
    }
  }
  @objc private func openInWindow() { onOpenInWindow?() }
  private func add(_ child: NSView, x: Int, y: Int, w: Int, h: Int) {
    child.frame = NSRect(x: x, y: y, width: w, height: h)
    view.addSubview(child)
  }
  @objc private func openHistory() { onHistory?(selected) }
  func monitoringVisibilityChanged(_ visible: Bool) {
    onMonitoringDemand?(visible && !showsSettings ? selected : nil)
  }
  private func configureTableStyle() {
    // Sensors own their text padding in both hosts; automatic/fullWidth add native cell gutters.
    table.style = isPopoverPresentation || selected == .sensors ? .plain : .automatic
  }
  func showSettingsView(_ content: NSView, page: PreferencesController.Page) {
    loadViewIfNeeded()
    navigation?.selectSettingsPage(page)
    onMonitoringDemand?(nil)
    navigation?.embedSettings(content, in: view)
    layoutContent()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    layoutContent()
  }
  private func layoutContent() {
    let w = view.bounds.width
    let h = view.bounds.height
    sensorCountLabel.frame = .init(x: 242, y: h - 42, width: 152, height: 20)
    guard w > 0, h > 0 else { return }
    navigation?.layout(in: view.bounds)
    if isPopoverPresentation && !showsSettings {
      layoutPopover()
      return
    }
    if showsSettings {
      navigation?.layoutSettings(in: view.bounds)
      return
    }
    let width = max(0, w - 180)
    titleLabel.frame.origin = .init(x: 154, y: h - 42)
    readingsButton.frame = .init(x: w - 132, y: h - 44, width: 108, height: 26)
    historyButton.frame = .init(
      x: w - (selected == .overview ? 120 : 227), y: h - 44, width: selected == .overview ? 92 : 90,
      height: selected == .overview ? 28 : 26)
    sensorSearch.frame = .init(x: 400, y: h - 44, width: max(0, w - 542), height: 26)
    weatherCityPicker?.frame = .init(x: 250, y: h - 44, width: max(0, w - 395), height: 26)
    weatherDashboard?.frame = .init(x: 154, y: 56, width: width, height: max(0, h - 186))
    weatherControls?.frame = .init(x: 154, y: h - 118, width: width, height: 70)
    let weather = selected == .weather
    valueLabel.frame = .init(x: 154, y: h - (weather ? 160 : 86), width: width, height: 39)
    subtitleLabel.frame = .init(x: 155, y: h - (weather ? 182 : 111), width: width, height: 20)
    let chartHeight = (selected == .sensors ? 156.0 : 126.0) + max(0, h - 560) * 0.3
    chart.frame = .init(
      x: 156, y: h - (weather ? 191 : 124) - chartHeight, width: width, height: chartHeight)
    summary?.frame = .init(
      x: 154, y: selected == .overview ? 40 : 56, width: width,
      height: max(0, h - (selected == .overview ? 96 : 106)))
    calendar?.frame = .init(
      x: 154, y: chart.frame.minY, width: min(600, width * 0.7), height: chartHeight)
    let tableHeight = weather && chart.isHidden ? h - 247 : chart.frame.minY - 66
    detailScroll?.frame = .init(x: 150, y: 56, width: max(0, w - 168), height: max(0, tableHeight))
    let columnsWidth =
      selected == .sensors
      ? max(0, detailScroll?.contentSize.width ?? 0)
      : max(0, min(w - 190, (detailScroll?.contentSize.width ?? 0) - 36))
    let labelWidth: CGFloat = (selected == .network ? 240 : 280) + max(0, w - 700) * 0.55
    sizeColumn(table.tableColumns.first, to: min(columnsWidth, labelWidth))
    sizeColumn(table.tableColumns.last, to: max(0, columnsWidth - labelWidth))
    pauseButton.frame = .init(
      x: w - (selected == .overview ? 216 : 100), y: selected == .overview ? h - 44 : 18,
      width: selected == .overview ? 90 : 72, height: 28)
    titleLabel.textColor = selected == .overview ? .labelColor : .secondaryLabelColor
    if selected == .overview {
      titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
      titleLabel.textColor = .labelColor
      pauseButton.image = NSImage(
        systemSymbolName: paused ? "play" : "pause", accessibilityDescription: nil)
      historyButton.image = NSImage(
        systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
      pauseButton.imagePosition = .imageLeading
      historyButton.imagePosition = .imageLeading
    } else {
      pauseButton.image = nil
      historyButton.image = nil
    }
  }
  /// A narrow material surface; one fixed icon bar gives the remaining height to content.
  private func layoutPopover() {
    let w = view.bounds.width
    let h = view.bounds.height
    let inset = SystemStyle.Space.popoverInset
    let x = inset + SystemStyle.Space.inset
    let width = max(0, w - 2 * inset)
    popoverMaterial.frame = view.bounds
    navigation?.sidebar.isHidden = true
    let actions = [historyButton, openWindowRow, readingsButton].filter {
      !$0.isHidden
    }
    let actionSize = SystemStyle.Space.action
    let barTop = inset + SystemStyle.Space.actionBar
    for (index, action) in actions.enumerated() {
      action.frame = .init(
        x: inset + 4 + CGFloat(index) * (actionSize + SystemStyle.Space.gap), y: inset + 3,
        width: actionSize, height: actionSize)
    }
    pauseButton.frame = .init(
      x: w - inset - 4 - actionSize, y: inset + 3, width: actionSize, height: actionSize)
    let bottom = barTop + 4
    footerSeparator.frame = .init(x: inset + 4, y: barTop, width: width - 8, height: 0.5)
    titleLabel.frame = .init(x: x, y: h - 39, width: width - 24, height: 20)
    valueLabel.frame = .init(x: x, y: h - 80, width: width - 24, height: 38)
    subtitleLabel.frame = .init(x: x, y: h - 101, width: width - 24, height: 18)
    headlinePlatter.frame = .init(x: inset, y: h - 110, width: width, height: 100)
    headlinePlatter.isHidden = selected == .weather && !showsAllReadings
    let compact =
      SummaryDashboardView.supports(selected) && (selected == .overview || !showsAllReadings)
    if compact {
      headlinePlatter.isHidden = true
      titleLabel.isHidden = true
      valueLabel.isHidden = true
      subtitleLabel.isHidden = true
    }
    if selected == .weather && !showsAllReadings { titleLabel.isHidden = true }
    var top = h - (compact ? 10 : 118)
    if selected == .sensors {
      sensorCountLabel.frame = .init(x: w - x - 160, y: h - 39, width: 160, height: 20)
      top -= 32
      sensorSearch.frame = .init(x: inset, y: top + 4, width: width, height: 26)
    }
    if selected == .weather {
      weatherCityPicker?.frame = .init(x: inset, y: h - 40, width: width, height: 26)
      weatherControls?.frame = .init(x: inset, y: h - 166, width: width, height: 120)
      if let controls = weatherControls {
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        for (index, button) in buttons.enumerated() {
          button.frame = .init(x: 0, y: 94 - CGFloat(index) * 26, width: width, height: 26)
        }
        controls.subviews.compactMap { $0 as? NSTextField }.first?.frame = .init(
          x: 0, y: 0, width: width, height: 42)
      }
      top = h - 174
      if showsAllReadings {
        headlinePlatter.isHidden = false
        headlinePlatter.frame.origin.y = top - 100
        titleLabel.frame.origin.y = top - 28
        valueLabel.frame.origin.y = top - 66
        subtitleLabel.frame.origin.y = top - 89
        top -= 108
      }
    }
    summaryScroll.isHidden = summary?.isHidden != false
    summaryScroll.frame = .init(x: inset, y: bottom, width: width, height: max(0, top - bottom))
    if let summary, !summary.isHidden {
      summary.frame.size.width = summaryScroll.contentSize.width
      summary.frame.size.height = summary.popoverDocumentHeight
    }
    weatherScroll.isHidden = weatherDashboard?.isHidden != false
    weatherScroll.frame = .init(x: inset, y: bottom, width: width, height: max(0, top - bottom))
    weatherDashboard?.frame = .init(
      x: 0, y: 0, width: weatherScroll.contentSize.width,
      height: weatherDashboard?.popoverDocumentHeight ?? 760)
    let hasTrace = !chart.isHidden || selected == .clock
    let traceHeight: CGFloat = selected == .sensors ? 156 : selected == .clock ? 148 : 126
    tracePlatter.isHidden = !hasTrace
    tracePlatter.frame = .init(x: inset, y: top - traceHeight, width: width, height: traceHeight)
    chart.frame = tracePlatter.frame.insetBy(dx: 12, dy: 8)
    calendar?.frame = tracePlatter.frame.insetBy(dx: 8, dy: 4)
    let tableTop = hasTrace ? tracePlatter.frame.minY - 8 : top
    readingsPlatter.isHidden = detailScroll?.isHidden != false
    readingsPlatter.frame = .init(
      x: inset, y: bottom, width: width, height: max(0, tableTop - bottom))
    // Sensors draw selection 4pt inside the card; text retains its existing 12pt padding.
    detailScroll?.frame = readingsPlatter.frame.insetBy(dx: selected == .sensors ? 0 : 12, dy: 6)
    let tableWidth = max(0, detailScroll?.contentSize.width ?? width)
    table.frame.size.width = tableWidth
    let columnWidth = max(
      0, tableWidth - table.intercellSpacing.width * CGFloat(table.numberOfColumns))
    sizeColumn(table.tableColumns.first, to: columnWidth * 0.55)
    sizeColumn(table.tableColumns.last, to: columnWidth * 0.45)
    table.tile()
    if let window = view.window {
      let keyLayout = PopoverKeyViewLayout(
        window: ObjectIdentifier(window), module: selected, allReadings: showsAllReadings,
        paused: paused, weatherEnabled: settings.weather.enabled,
        weatherSource: settings.weather.source, size: view.bounds.size)
      if keyLayout != popoverKeyViewLayout {
        // New/hidden module controls need a fresh native loop after their final frames.
        // Keep content controls reachable; unchanged samples do not rebuild traversal.
        popoverKeyViewLayout = keyLayout
        window.recalculateKeyViewLoop()
      }
    }
  }
  private func sizeColumn(_ column: NSTableColumn?, to width: CGFloat) {
    guard let column, column.width != width else { return }
    column.width = width
  }
  @objc private func togglePause() { onPause?() }
  @objc private func detailOption() {
    if selected == .clock { onCalendarSettings?() } else { showsAllReadings.toggle() }
  }
  @objc private func enableWeather(_ sender: NSButton) { onWeatherEnabled?(sender.state == .on) }
  @objc private func requestWeatherLocation() { onWeatherLocationRequest?() }
  @objc private func editWeatherLocations() { onWeatherLocations?() }
  @objc private func selectProcessGrouping(_ sender: NSSegmentedControl) {
    let mode: TrafficGrouping = sender.selectedSegment == 1 ? .bundles : .processes
    settings.processGrouping = mode
    if selected == .network {
      snapshot.networkTraffic = .init()
      snapshot.networkTraffic.grouping = mode
      snapshot.networkTraffic.message = "Collecting a new complete traffic interval."
    }
    onProcessGrouping?(mode)
    refresh()
  }
  private func prepareWeatherControls() {
    guard weatherControls == nil else { return }
    let controls = NSView(frame: .init(x: 154, y: 442, width: 520, height: 70))
    let enable = NSButton(
      checkboxWithTitle: "Enable weather", target: self, action: #selector(enableWeather(_:)))
    enable.frame = .init(x: 0, y: 39, width: 148, height: 26)
    controls.addSubview(enable)
    let allow = NSButton(
      title: "Allow current location…", target: self, action: #selector(requestWeatherLocation))
    allow.bezelStyle = .rounded
    allow.frame = .init(x: 150, y: 39, width: 210, height: 26)
    controls.addSubview(allow)
    let locations = NSButton(
      title: "Locations & privacy…", target: self, action: #selector(editWeatherLocations))
    locations.bezelStyle = .rounded
    locations.frame = .init(x: 365, y: 39, width: 155, height: 26)
    locations.autoresizingMask = [.minXMargin]
    controls.addSubview(locations)
    let privacy = NSTextField(
      wrappingLabelWithString:
        "Forecasts send rounded coordinates and your IP address to api.met.no, including with this tab closed. Location permission is requested only with Allow."
    )
    privacy.font = .systemFont(ofSize: 10)
    privacy.textColor = .secondaryLabelColor
    privacy.autoresizingMask = [.width]
    privacy.frame = .init(x: 0, y: 0, width: 520, height: 34)
    controls.addSubview(privacy)
    view.addSubview(controls)
    weatherControls = controls
    weatherEnable = enable
    weatherAllow = allow
  }
  private func updateWeatherChoices() {
    guard let picker = weatherCityPicker else { return }
    var choices: [WeatherLocation?] = [nil]
    choices.append(
      contentsOf: weatherCities.prefix(SystemWeatherCities.cityLimit).map(Optional.some))
    if settings.weather.source == .manual, let manual = settings.weather.location,
      !weatherCities.contains(manual)
    {
      choices.append(manual)
    }
    picker.toolTip = weatherCitiesStatus
    guard choices != weatherChoices || weatherChoiceConfiguration != settings.weather else {
      return
    }
    if choices != weatherChoices {
      weatherChoices = choices
      picker.removeAllItems()
      for title in ["Current location"] + WeatherCityMenu.titles(choices.compactMap { $0 }) {
        picker.menu?.addItem(
          NSMenuItem(
            title: title,
            action: nil, keyEquivalent: ""))
      }
    }
    weatherChoiceConfiguration = settings.weather
    picker.selectItem(
      at: settings.weather.source == .currentLocation
        ? 0
        : choices.firstIndex(where: { $0 == settings.weather.location }) ?? 0)
  }
  @objc private func selectWeatherCity(_ sender: NSPopUpButton) {
    guard weatherChoices.indices.contains(sender.indexOfSelectedItem) else { return }
    onWeatherCity?(weatherChoices[sender.indexOfSelectedItem])
  }
  func update(_ snapshot: Snapshot, history: [HistoryPoint]) {
    self.snapshot = snapshot
    clockDate = snapshot.timestamp
    self.history = history
    sensorTimeline.append(snapshot)
    if isViewLoaded {
      if selected == .sensors, !showsSettings, let sample = snapshot.sensorsSampledAt,
        sample == renderedSensorSample, renderedSensorFahrenheit == settings.fahrenheit
      {
        updateSampleRows()
        updateSampleHelp()
      } else {
        refresh()
      }
    }
  }
  @discardableResult func updateClock(_ date: Date) -> Bool {
    let step: Double = settings.worldClockIncludesSeconds ? 1 : 60
    let changed =
      clockDate.map {
        floor($0.timeIntervalSince1970 / step) != floor(date.timeIntervalSince1970 / step)
      } ?? true
    clockDate = date
    guard selected == .clock, isViewLoaded, changed else { return false }
    refresh()
    return true
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    guard selected == .sensors else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("sensor-browser-row")
    let view =
      tableView.makeView(withIdentifier: identifier, owner: self) as? SensorBrowserRowView
      ?? SensorBrowserRowView()
    view.identifier = identifier
    return view
  }
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    selected == .sensors && rows.indices.contains(row) && rows[row].sensorIdentity != nil
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !reloadingRows, selected == .sensors, rows.indices.contains(table.selectedRow),
      let key = rows[table.selectedRow].sensorIdentity
    else { return }
    selectedSensorIdentity = key
    refresh()
  }
  func controlTextDidChange(_ notification: Notification) {
    guard notification.object as? NSSearchField === sensorSearch else { return }
    refresh()
  }
  private func refreshAppearanceCells() {
    guard isViewLoaded else { return }
    // Equality only describes sample data. Native icons/semantic colors also depend on
    // appearance; refresh realized body cells while leaving the focused header in place.
    let body = IndexSet(rows.indices.filter { !rows[$0].processGroupingHeader })
    table.reloadData(
      forRowIndexes: body, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
  }
  private func reloadRows() {
    reloadingRows = true
    defer { reloadingRows = false }
    if rows != displayedRows {
      let header = rows.firstIndex(where: \.processGroupingHeader)
      let sameHeader =
        header != nil && header == displayedRows.firstIndex(where: \.processGroupingHeader)
      let focused =
        view.window?.firstResponder === processGroupingControl && processGroupingControl != nil
      if rows.count == displayedRows.count, sameHeader {
        let changed = IndexSet(
          rows.indices.filter { $0 != header && rows[$0] != displayedRows[$0] })
        table.reloadData(
          forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        if let header, rows[header] != displayedRows[header],
          let label = table.view(atColumn: 0, row: header, makeIfNecessary: false) as? NSTextField
        {
          // Even a single-column header reload can resign its sibling's first responder.
          // Unrealized headings read the current row when the table asks for them later.
          label.stringValue = SystemStyle.sectionTitle(rows[header].label)
          label.toolTip = rows[header].help ?? label.stringValue
          label.setAccessibilityLabel(rows[header].accessibilityLabel ?? rows[header].label)
        }
      } else {
        table.reloadData()
        if focused, let header, let control = processGroupingControl {
          _ = table.view(atColumn: 1, row: header, makeIfNecessary: true)
          view.window?.makeFirstResponder(control)
        }
      }
      displayedRows = rows
    }
    if selected == .sensors, let key = selectedSensorIdentity,
      let index = rows.firstIndex(where: { $0.sensorIdentity == key })
    {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int)
    -> NSView?
  {
    let id = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "label")
    let row = rows[index]
    if id.rawValue == "value", row.processGroupingHeader, let control = processGroupingControl {
      let header = processGroupingHeader
      header.frame = .init(x: 0, y: 0, width: tableColumn?.width ?? 135, height: table.rowHeight)
      if control.superview !== header { header.addSubview(control) }
      control.isHidden = false
      control.frame = .init(
        x: max(0, header.bounds.width - ProcessGroupingControl.width), y: 3,
        width: ProcessGroupingControl.width, height: 22)
      control.autoresizingMask = [.minXMargin]
      return header
    }
    if id.rawValue == "label", let fallback = row.appName {
      let cellID = NSUserInterfaceItemIdentifier("process-app-label")
      let cell =
        table.makeView(withIdentifier: cellID, owner: self) as? ProcessAppLabelCell
        ?? ProcessAppLabelCell(frame: .zero)
      cell.identifier = cellID
      let entry =
        row.bundlePath.map { appDisplayCache.entry(path: $0, fallback: fallback) }
        ?? .init(name: fallback, icon: ProcessAppDisplayCache.placeholder)
      cell.update(entry, count: row.processCount, path: row.bundlePath, provenance: row.label)
      if let help = row.help {
        cell.toolTip = (cell.toolTip ?? "") + " · " + help
        cell.setAccessibilityHelp(help)
      } else {
        cell.setAccessibilityHelp(nil)
      }
      return cell
    }
    if id.rawValue == "value", let reading = row.meter {
      let meterID = NSUserInterfaceItemIdentifier("utilization-meter")
      let cell =
        table.makeView(withIdentifier: meterID, owner: self) as? UtilizationMeterCell
        ?? UtilizationMeterCell(frame: .zero)
      cell.identifier = meterID
      cell.update(label: row.label, reading: reading.value, color: reading.color, text: row.value)
      if let help = row.help {
        cell.toolTip = row.value + " · " + help
        cell.setAccessibilityHelp(help)
      } else {
        cell.setAccessibilityHelp(nil)
      }
      return cell
    }
    let textID = selected == .sensors ? NSUserInterfaceItemIdentifier("sensor-" + id.rawValue) : id
    let cell =
      table.makeView(withIdentifier: textID, owner: self) as? NSTextField
      ?? (selected == .sensors
        ? SensorBrowserTextField(labelWithString: "") : NSTextField(labelWithString: ""))
    cell.identifier = textID
    let isValue = id.rawValue == "value"
    cell.stringValue =
      isValue
      ? row.compactValue ?? row.value
      : row.heading ? SystemStyle.sectionTitle(row.label) : row.label
    cell.font =
      isValue
      ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      : .systemFont(ofSize: 12, weight: row.heading ? .semibold : .regular)
    cell.textColor = row.heading ? .secondaryLabelColor : .labelColor
    cell.alignment = isValue ? .right : .left
    cell.lineBreakMode = .byTruncatingTail
    cell.toolTip = row.help ?? (isValue ? row.value : cell.stringValue)
    if !isValue, let spoken = row.accessibilityLabel {
      cell.setAccessibilityLabel(spoken)
      cell.toolTip = row.help ?? cell.stringValue
    } else {
      cell.setAccessibilityLabel(isValue ? row.value : row.label)
    }
    return cell
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let index = table.clickedRow
    let item = NSMenuItem(
      title: "Copy value", action: #selector(copyDetailValue(_:)), keyEquivalent: "")
    if rows.indices.contains(index), !rows[index].value.isEmpty {
      // Capture now: live updates must not change which value a contextual action copies.
      item.representedObject = rows[index].value
      item.target = self
    } else {
      item.isEnabled = false
    }
    menu.addItem(item)
  }
  @objc private func copyDetailValue(_ item: NSMenuItem) {
    guard let value = item.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
  func invalidateWeatherFormatting() {
    weatherDashboard?.invalidateFormatting()
    weatherDateLabels?.invalidate()
  }
  private func refresh() {
    guard isViewLoaded, !showsSettings else { return }
    chart.inspectionDateLabel = nil
    defer { layoutContent() }
    let groupsProcesses = [.cpu, .memory, .network].contains(selected)
    if groupsProcesses {
      if processGroupingControl == nil {
        processGroupingControl = ProcessGroupingControl(
          target: self, action: #selector(selectProcessGrouping(_:)))
      }
      processGroupingControl?.selectedSegment = settings.processGrouping == .bundles ? 1 : 0
    }
    processGroupingControl?.isHidden = !groupsProcesses
    if selected == .network,
      snapshot.networkTraffic.grouping != settings.processGrouping
        || snapshot.networkTraffic.revision != settings.networkTrafficRevision
    {
      snapshot.networkTraffic = .init()
      snapshot.networkTraffic.grouping = settings.processGrouping
      snapshot.networkTraffic.revision = settings.networkTrafficRevision
      snapshot.networkTraffic.message = "Collecting a new complete traffic interval."
    }
    titleLabel.isHidden = false
    pauseButton.isHidden = false
    let s = snapshot
    navigation?.updateSelection(selected)
    titleLabel.stringValue = selected.title + (paused ? " · Paused" : "")
    titleLabel.setAccessibilityLabel(nil)
    titleLabel.font = .systemFont(
      ofSize: selected == .network && paused ? 11 : 13, weight: .semibold)
    if selected == .weather, weatherCityPicker == nil {
      let picker = NSPopUpButton()
      picker.target = self
      picker.action = #selector(selectWeatherCity(_:))
      picker.setAccessibilityLabel("Weather city")
      add(picker, x: 400, y: 516, w: 274, h: 26)
      weatherCityPicker = picker
    }
    weatherCityPicker?.isHidden = selected != .weather
    weatherCityPicker?.isEnabled = settings.weather.enabled
    if selected == .weather {
      prepareWeatherControls()
      weatherEnable?.state = settings.weather.enabled ? .on : .off
      weatherAllow?.isHidden = settings.weather.source != .currentLocation
      weatherAllow?.isEnabled = settings.weather.enabled && !paused
    }
    weatherControls?.isHidden = selected != .weather
    historyButton.isHidden = !HistoryController.modules.contains(selected) && selected != .overview
    sensorSearch.isHidden = selected != .sensors
    sensorCountLabel.isHidden = selected != .sensors
    if selected == .sensors { historyButton.isHidden = true }
    readingsButton.isHidden = selected == .overview
    readingsButton.title =
      selected == .clock ? "Calendar…" : showsAllReadings ? "Summary" : "All readings"
    readingsButton.setAccessibilityLabel(
      selected == .clock
        ? "Calendar settings"
        : selected == .sensors
          ? (showsAllReadings ? "Show summary" : "Show all readings and SMC keys")
          : showsAllReadings ? "Show summary" : "Show all readings")
    updateActionPresentation()
    titleLabel.frame.size.width =
      selected == .overview && !isPopoverPresentation
      ? max(0, view.bounds.width - 390)
      : selected == .network ? 128 : selected == .weather ? 90 : selected == .sensors ? 142 : 300
    if selected == .weather { updateWeatherChoices() }
    chart.isHidden = selected == .clock
    if selected == .clock, calendar == nil {
      let picker = MonthCalendarView(frame: .zero, firstWeekday: settings.calendarFirstWeekday)
      add(picker, x: 153, y: 310, w: 300, h: 130)
      calendar = picker
      picker.onSelect = { [weak self] date in
        self?.onCalendarDate?(date)
        self?.refresh()
      }
    }
    calendar?.isHidden = selected != .clock
    if selected == .clock {
      calendar?.updateToday(
        clockDate ?? snapshot.timestamp, firstWeekday: settings.calendarFirstWeekday)
    }
    let weatherSummary = selected == .weather && !showsAllReadings
    weatherDashboard?.isHidden = !weatherSummary
    let compact =
      SummaryDashboardView.supports(selected) && (selected == .overview || !showsAllReadings)
    valueLabel.isHidden = (compact && !isPopoverPresentation) || weatherSummary
    subtitleLabel.isHidden = (compact && !isPopoverPresentation) || weatherSummary
    chart.isHidden = compact || weatherSummary || selected == .clock
    detailScroll?.isHidden = compact || weatherSummary
    summary?.isHidden = !compact
    if weatherSummary {
      if weatherDashboard == nil {
        let dashboard = WeatherDashboardView(frame: .zero, solarCalculator: solarCalculator)
        view.addSubview(dashboard)
        weatherDashboard = dashboard
        if isPopoverPresentation { weatherScroll.documentView = dashboard }
      }
      weatherDashboard?.update(
        s, settings: settings, paused: paused, sourceStatus: weatherSourceStatus)
      if !rows.isEmpty {
        rows = []
        reloadRows()
      }
      if !chart.series.isEmpty { chart.series = [] }
      if !chart.times.isEmpty { chart.times = [] }
      updateSampleHelp()
      return
    }
    if compact {
      if summary == nil {
        let dashboard = SummaryDashboardView(frame: .zero)
        add(dashboard, x: 154, y: 56, w: 520, h: 454)
        dashboard.appDisplayCache = appDisplayCache
        summary = dashboard
        dashboard.usesPopoverLayout = isPopoverPresentation
        if isPopoverPresentation { summaryScroll.documentView = dashboard }
      }
      if isPopoverPresentation,
        let headline = DetailReadingsBuilder.headline(module: selected, snapshot: s)
      {
        valueLabel.stringValue = headline.value
        subtitleLabel.stringValue = headline.subtitle
        // These pages already show the headline value in their first card's content.
        summary?.popoverHeadline =
          [.gpu, .network, .disks, .battery].contains(selected)
          ? nil
          : (
            titleLabel.stringValue, headline.value,
            selected == .memory
              ? snapshot.memory.map { "of " + Display.bytes($0.total) } ?? headline.subtitle
              : headline.subtitle
          )
      }
      summary?.paused = paused
      summary?.groupingControl = groupsProcesses ? processGroupingControl : nil
      summary?.update(s, history: history, settings: settings, module: selected)
      if !rows.isEmpty {
        rows = []
        reloadRows()
      }
      if !chart.series.isEmpty {
        chart.series = []
        chart.times = []
      }
      updateSampleHelp()
      return
    }
    if groupsProcesses, processGroupingControl?.superview === summary {
      processGroupingControl?.removeFromSuperview()
    }
    chart.fitsDataRange = selected == .sensors
    chart.times = history.map(\.time)
    chart.upperBound = 100
    chart.valueFormat = selected == .network || selected == .disks ? .rate : .percent
    chart.caption = nil
    chart.toolTip = nil
    chart.setAccessibilityHelp(nil)
    chart.newestValueLabel = "Latest"
    chart.emptyMessage = "No readings yet"
    chart.showsSummaryDecorations = selected != .sensors
    chart.setAccessibilityLabel(
      selected == .weather ? "Weather forecast chart" : "Metric history chart")
    var lines: [ChartView.Series] = []
    rows = []
    // Until Sensors/Weather/Clock are extracted, keep these helpers behavior-identical to DetailReadingsBuilder's equivalents.
    func row(_ label: String, _ value: String) { rows.append(.init(label: label, value: value)) }
    func section(_ title: String) { rows.append(.init(label: title, value: "", heading: true)) }
    func utilization(_ label: String, _ reading: Double?, _ color: NSColor, text: String? = nil) {
      let reading = UtilizationMeterCell.normalized(reading)
      rows.append(
        .init(
          label: label, value: reading == nil ? "—" : text ?? Display.percent(reading),
          meter: .init(value: reading, color: color))
      )
    }
    switch selected {
    case .overview, .cpu, .gpu, .memory, .disks, .network, .battery:
      if let presentation = DetailReadingsBuilder.build(
        module: selected, snapshot: s, history: history, settings: settings, paused: paused)
      {
        valueLabel.stringValue = presentation.value
        subtitleLabel.stringValue = presentation.subtitle
        rows = presentation.rows
        lines = presentation.series
        chart.upperBound = presentation.upperBound
      }
      if selected == .overview { valueLabel.font = .systemFont(ofSize: 26, weight: .medium) }
    case .sensors:
      renderedSensorSample = s.sensorsSampledAt
      renderedSensorFahrenheit = settings.fahrenheit
      let presentation = SensorBrowserPresentation.build(
        snapshot: s, timeline: sensorTimeline, settings: settings, query: sensorSearch.stringValue,
        showsAll: showsAllReadings, selection: selectedSensorIdentity, paused: paused)
      selectedSensorIdentity = presentation.selection
      valueLabel.stringValue = presentation.value
      subtitleLabel.stringValue = presentation.subtitle
      chart.times = sensorTimeline.times
      lines = presentation.series
      chart.upperBound = nil
      chart.valueFormat = .unit(presentation.unit)
      chart.emptyMessage =
        presentation.available ? "No readings yet" : "No sensor readings to chart"
      chart.caption = ""
      chart.toolTip = "Read-only · history while this window is open · hover for values"
      chart.setAccessibilityHelp(chart.toolTip)
      titleLabel.stringValue = SystemStyle.sectionTitle(presentation.title)
      titleLabel.setAccessibilityLabel(presentation.title)
      sensorCountLabel.stringValue = presentation.count
      sensorCountLabel.toolTip = presentation.countAccessibilityLabel
      sensorCountLabel.setAccessibilityLabel(presentation.countAccessibilityLabel)
      rows = presentation.rows
    case .weather:
      let weather = s.weather.filtered(settings: settings.weather, suspended: paused)
      let current = weather.current(at: s.uptime, date: s.timestamp)
      let fresh = weather.isFresh(at: s.uptime, date: s.timestamp)
      let awaitingLocation =
        settings.weather.enabled && settings.weather.source == .currentLocation
        && settings.weather.location == nil
      let providerStatus: String
      if !settings.weather.enabled {
        providerStatus = "Weather is off"
      } else if paused {
        providerStatus = "Monitoring paused · resume to see the forecast"
      } else if awaitingLocation {
        providerStatus = weatherSourceStatus
      } else if s.weather.settings != settings.weather {
        providerStatus = "Waiting for selected location forecast…"
      } else if !fresh && weather.forecast != nil {
        providerStatus = "Forecast is stale · values withheld"
      } else {
        providerStatus = weather.checking ? "Checking…" : weather.reason
      }
      valueLabel.stringValue =
        current?.celsius.map { DetailReadingsBuilder.temperature($0, settings: settings) }
        ?? (settings.weather.enabled ? "—" : "Off")
      subtitleLabel.stringValue =
        settings.weather.enabled
        ? "Now (forecast) · \(current?.condition ?? providerStatus)"
        : "Use Enable weather above"
      chart.upperBound = nil
      chart.emptyMessage =
        awaitingLocation
        ? weatherSourceStatus
        : settings.weather.enabled ? "Waiting for a fresh forecast…" : "Weather is off"
      // Pending setup has no forecast plot. Keep the controls and status in one view.
      if !fresh || weather.forecast?.points.isEmpty != false {
        chart.isHidden = true
      }
      let weatherLabels = weatherDateLabels ?? WeatherDateLabels()
      weatherDateLabels = weatherLabels
      let weatherZone =
        settings.weather.location.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
      weatherLabels.configure(locale: .current, timeZone: weatherZone)
      chart.inspectionDateLabel = { weatherLabels.string($0, as: .forecast) }
      if let location = settings.weather.location {
        row("Chosen location", location.displayName)
        row("Forecast time zone", location.timeZone)
      }
      row("Weather app cities", weatherCitiesStatus)
      if settings.weather.enabled {
        row("Provider status", providerStatus)
        if let age = weather.checkedAge(at: s.uptime) { row("Last checked", age) }
        if let wait = weather.requestWait(at: s.uptime) { row("Next request", wait) }
        if !fresh, weather.forecast != nil {
          row("Cached forecast", "Stale · current value withheld")
        }
      }
      if let current {
        utilization("Humidity", current.humidity, SystemStyle.accent)
        utilization("Cloud cover", current.cloudCover, .systemGray)
        row("Wind from", WindDirectionPresentation(current.windFromDegrees)?.value ?? "—")
        row("Wind", current.windMetersPerSecond.map { String(format: "%.1f m/s", $0) } ?? "—")
        row("Sea-level pressure", current.pressureHPa.map { String(format: "%.0f hPa", $0) } ?? "—")
        if let hours = current.periodHours {
          row(
            "Precipitation · next \(hours)h",
            current.precipitationMM.map { String(format: "%.1f mm", $0) } ?? "—")
        }
      }
      if let solar = solarCalculator.day(
        on: s.timestamp,
        location: settings.weather.enabled && !paused ? settings.weather.location : nil)
      {
        section("DAYLIGHT · LOCAL ESTIMATE")
        for event in solar.events {
          row(
            event.kind == .sunrise ? "Estimated sunrise" : "Estimated sunset",
            weatherLabels.string(
              SolarEventPresentation.minute(event.date, in: weatherZone), as: .forecast))
        }
        if solar.events.isEmpty {
          row(
            "Sun", solar.state == .sunUpAllDay ? "Up all civil day" : "Below horizon all civil day")
        }
        let minutes = Int((solar.daylightDuration / 60).rounded())
        row(
          "Daylight duration",
          minutes == 0 && solar.daylightDuration > 0
            ? "<1 min" : "\(minutes / 60)h \(minutes % 60)m")
        row("Estimate", "NOAA-based local calculation · level, unobstructed horizon")
        row("Precision", "Times and duration independently rounded to nearest minute")
      }
      if let forecast = weather.forecast, fresh {
        let upcoming = forecast.points.filter {
          $0.date >= s.timestamp.addingTimeInterval(-3600)
            && $0.date <= s.timestamp.addingTimeInterval(48 * 3600)
        }
        chart.times = upcoming.map(\.date)
        chart.valueFormat = .unit(settings.fahrenheit ? "°F" : "°C")
        chart.newestValueLabel = "Window end"
        chart.caption =
          "Next 48h forecast · \(weatherZone.identifier) · time → · \(settings.fahrenheit ? "°F" : "°C")"
        lines = [
          .init(
            name: "Forecast temperature", color: SystemStyle.accent,
            values: upcoming.map { point in
              point.celsius.map { settings.fahrenheit ? $0 * 1.8 + 32 : $0 }
            })
        ]
        section("DAILY · SAMPLED LOW / HIGH")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone =
          settings.weather.location.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        let today = calendar.startOfDay(for: s.timestamp)
        let days = Dictionary(grouping: forecast.points.filter { $0.date >= today }) {
          calendar.startOfDay(for: $0.date)
        }
        for day in days.keys.sorted().prefix(7) {
          let samples = days[day]?.compactMap(\.celsius) ?? []
          row(
            weatherLabels.string(day, as: .day),
            samples.min().flatMap { low in
              samples.max().map {
                DetailReadingsBuilder.temperature(low, settings: settings) + " / "
                  + DetailReadingsBuilder.temperature($0, settings: settings)
              }
            } ?? "—")
        }
        row("Daily ranges", "Available model samples · may be partial")
        section("UPCOMING MODEL TIMES")
        for point in upcoming.filter({ $0.date >= s.timestamp }).prefix(24) {
          row(
            weatherLabels.string(point.date, as: .modelTime),
            (point.celsius.map { DetailReadingsBuilder.temperature($0, settings: settings) } ?? "—")
              + " · " + point.condition)
        }
        row("Model generated", weatherLabels.string(forecast.generatedAt, as: .forecast))
      }
      section("DATA FROM MET NORWAY · CC BY 4.0")
      row("Forecast data", "api.met.no · model forecast")
      row("Attribution & license", "api.met.no/doc/License")
    case .clock:
      let date = clockDate ?? s.timestamp
      clockFormatter.timeZone = .current
      clockFormatter.dateStyle = .none
      clockFormatter.timeStyle = .none
      clockFormatter.dateFormat = "HH:mm"
      valueLabel.stringValue = clockFormatter.string(from: date)
      clockFormatter.dateFormat = "EEEE, d MMMM yyyy"
      subtitleLabel.stringValue = clockFormatter.string(from: date)
      let agenda = calendarSnapshot
      let day = calendar?.selectedDate ?? date
      section(
        "AGENDA · " + DateFormatter.localizedString(from: day, dateStyle: .medium, timeStyle: .none)
      )
      if !settings.calendarEvents {
        row("Calendar events", "Off · optional · enable in Calendar…")
      } else if agenda.refreshing {
        row("Calendar events", "Loading selected day…")
      } else if agenda.access != .fullAccess {
        let message: String
        switch agenda.access {
        case .denied: message = "Denied · see System Settings"
        case .restricted: message = "Restricted by macOS"
        case .writeOnly: message = "Needs Full Access · Calendar…"
        case .off, .notDetermined: message = "Allow in Calendar…"
        default: message = "Unavailable"
        }
        row("Calendar access", message)
      } else if agenda.selectedCalendarCount == 0 {
        row("Calendar selection", "No accessible calendars selected")
      } else {
        if agenda.events.isEmpty { row("Selected day", "No events") }
        for event in agenda.events {
          if event.allDay {
            row(event.title, "All day · " + event.calendarTitle)
          } else {
            clockFormatter.timeZone = .current
            clockFormatter.dateStyle = .none
            clockFormatter.timeStyle = .short
            if let day = agenda.day {
              row(event.title, event.timeLabel(in: day, formatter: clockFormatter))
            }
            row("  " + event.calendarTitle, "")
          }
        }
        if agenda.eventsTruncated { row("Event limit", "Partial · 128 rows / 2,048 scan cap") }
        if agenda.calendarsTruncated { row("Calendar limit", "Partial · first 64 calendars") }
        if let checked = agenda.checkedAt {
          row("Agenda checked", "\(Int(max(0, date.timeIntervalSince(checked))))s ago")
        }
      }
      section("WORLD CLOCKS")
      for clock in ClockMenuRenderer.worldClockRows(settings: settings, at: date) {
        row(clock.label, clock.value)
      }
    }
    if selected != .overview {
      valueLabel.font = .monospacedDigitSystemFont(
        ofSize: SystemStyle.TypeSize.value, weight: .semibold)
    }
    subtitleLabel.toolTip = subtitleLabel.stringValue
    subtitleLabel.setAccessibilityLabel(subtitleLabel.stringValue)
    if selected != .sensors || showsAllReadings {
      rows += DetailReadingsBuilder.sampleRows(snapshot: s, settings: settings, paused: paused)
    }
    chart.series = lines
    table.setAccessibilityLabel("\(selected.title) details")
    reloadRows()
    updateSampleHelp()
  }
  private func updateActionPresentation() {
    openWindowRow.title = "Open \(selected.title) in TinyStats"
    for button in [historyButton, openWindowRow, pauseButton] {
      button.setAccessibilityLabel(button.title)
      if button !== pauseButton { button.toolTip = button.title }
    }
    readingsButton.toolTip = readingsButton.accessibilityLabel()
    updateSampleHelp()
    guard isPopoverPresentation else { return }
    historyButton.setIcon("clock.arrow.circlepath", fallback: "clock")
    openWindowRow.setIcon("arrow.up.forward.app", fallback: "macwindow")
    if selected == .clock {
      readingsButton.setIcon("calendar", fallback: "clock")
    } else if showsAllReadings {
      readingsButton.setIcon("square.grid.2x2", fallback: "square")
    } else {
      readingsButton.setIcon("list.bullet.rectangle", fallback: "list.bullet")
    }
    pauseButton.showsAccent = paused
    pauseButton.setIcon(paused ? "play.fill" : "pause", fallback: paused ? "play" : "pause")
  }
  private func updateSampleRows() {
    guard let start = rows.firstIndex(where: \.sampleSection) else { return }
    let sample = DetailReadingsBuilder.sampleRows(
      snapshot: snapshot, settings: settings, paused: paused)
    let previous = Array(rows[start...])
    guard previous != sample else { return }
    rows.replaceSubrange(start..., with: sample)
    if previous.count == sample.count {
      let changed = IndexSet(
        sample.indices.filter { sample[$0] != previous[$0] }.map { start + $0 })
      table.reloadData(
        forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
      displayedRows = rows
    } else {
      reloadRows()
    }
  }
  private func updateSampleHelp() {
    let information = DetailReadingsBuilder.sampleRows(
      snapshot: snapshot, settings: settings, paused: paused
    )
    .filter { !$0.heading }.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    // Keep the action's established AX label; supplemental help is reachable on every
    // module, including Overview, which intentionally has no All readings action.
    pauseButton.toolTip = pauseButton.title + "\n" + information
    pauseButton.setAccessibilityHelp(information)
    (view as? MainContentView)?.sampleInformation = information
    view.setAccessibilityLabel("\(selected.title) details")
  }
}

@MainActor final class MainContentView: SystemStyledView {
  var usesPopoverMaterial = false { didSet { needsDisplay = true } }
  var glassEnvironment: () -> GlassSurface.Environment = { .current }
  var sidebarFrame: () -> NSRect = { .zero }
  var onStyleChange: (() -> Void)?
  private lazy var sampleElement: NSAccessibilityElement = {
    let element = NSAccessibilityElement()
    element.setAccessibilityElement(true)
    element.setAccessibilityRole(.staticText)
    element.setAccessibilityLabel("About this sample")
    element.setAccessibilityParent(self)
    return element
  }()
  var sampleInformation = "" {
    didSet {
      sampleElement.setAccessibilityValue(sampleInformation)
    }
  }
  override func accessibilityChildren() -> [Any]? {
    let children = super.accessibilityChildren() ?? []
    guard !sampleInformation.isEmpty else { return children }
    let localFrame = NSRect(x: 0, y: 0, width: bounds.width, height: min(34, bounds.height))
    let windowFrame = convert(localFrame, to: nil)
    sampleElement.setAccessibilityFrame(window?.convertToScreen(windowFrame) ?? windowFrame)
    return children + [sampleElement]
  }
  override func systemStyleDidChange() {
    super.systemStyleDidChange()
    clipsToBounds = glassEnvironment().treatment == .glass
    onStyleChange?()
  }
  override var isOpaque: Bool {
    !usesPopoverMaterial && glassEnvironment().treatment != .glass
  }
  override func draw(_ dirtyRect: NSRect) {
    guard !usesPopoverMaterial else { return }
    NSColor.windowBackgroundColor.setFill()
    let background = NSBezierPath(rect: bounds)
    if glassEnvironment().treatment == .glass {
      // Continue the neutral content around the floating sidebar, leaving only its
      // rounded interior available to the compositor's backdrop sampling.
      background.append(
        NSBezierPath(
          roundedRect: sidebarFrame(),
          xRadius: GlassSurface.sidebarCornerRadius, yRadius: GlassSurface.sidebarCornerRadius))
      background.windingRule = .evenOdd
    }
    background.fill()
  }
}

/// The bottom of a scrolling platter fades into the reserved footer gap. Layer state
/// follows layout/appearance only; no observer, animation, event loop or timer.
@MainActor final class PopoverScrollView: NSScrollView {
  private let fade = CAGradientLayer()
  var fadesBottom = false {
    didSet {
      guard oldValue != fadesBottom else { return }
      automaticallyAdjustsContentInsets = false
      contentInsets = .init(top: 0, left: 0, bottom: fadesBottom ? 22 : 0, right: 0)
      wantsLayer = fadesBottom
      layer?.mask = fadesBottom ? fade : nil
      needsLayout = true
    }
  }
  override func layout() {
    super.layout()
    guard fadesBottom else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.frame = bounds
    // Six clear points hide cut card rims before the sixteen-point ramp.
    fade.colors = [
      NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor,
    ]
    fade.locations = [
      0, NSNumber(value: min(1, 6 / max(1, bounds.height))),
      NSNumber(value: min(1, 22 / max(1, bounds.height))), 1,
    ]
    // NSScrollView has a flipped backing layer: normalized y=1 is the footer edge.
    fade.startPoint = .init(x: 0.5, y: 1)
    fade.endPoint = .init(x: 0.5, y: 0)
    CATransaction.commit()
  }
}
