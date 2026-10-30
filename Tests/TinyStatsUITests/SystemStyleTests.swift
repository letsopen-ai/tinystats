import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func systemDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + systemDescendants($0) }
}

@Test @MainActor func systemAccentPairResolvesInBothAppearancesAndKeepsCoreClassification() throws {
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    let appearance = try #require(NSAppearance(named: name))
    appearance.performAsCurrentDrawingAppearance {
      let accent = SystemStyle.accent.usingColorSpace(.sRGB)
      let tint = SystemStyle.secondaryAccent.usingColorSpace(.sRGB)
      let expected = SystemStyle.resolvedPalette(in: appearance)
      #expect(accent == expected.primary.usingColorSpace(.sRGB))
      #expect(tint == expected.secondary.usingColorSpace(.sRGB))
      #expect(accent != tint)
      #expect(tint?.alphaComponent == 1)
      #expect(CPUCoreKind.efficiency.chartColor == SystemStyle.secondaryAccent)
      #expect(CPUCoreKind.performance.chartColor == SystemStyle.accent)
      #expect(CPUCoreKind.unknown.chartColor == .secondaryLabelColor)
    }
  }
  #expect(
    SystemStyle.sectionTitle("TOP CPU · BARS = MAC CAPACITY") == "Top CPU · bars = mac capacity")
  #expect(SystemStyle.sectionTitle("METAL GPU TIME") == "Metal GPU time")
}

@Test @MainActor func systemColorNotificationInvalidatesMenuAndChartsWithoutRetainingViews() throws
{
  let window = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 344, height: 640), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  weak var released: MenuBarReadoutView?
  do {
    let menu = MenuBarReadoutView(frame: .init(x: 0, y: 0, width: 100, height: 24))
    window.contentView = menu
    var changes = 0
    menu.onAppearanceChange = { changes += 1 }
    menu.needsDisplay = false
    NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
    #expect(menu.needsDisplay && changes == 1)
    window.contentView = nil
  }
  autoreleasepool {
    let detached = MenuBarReadoutView()
    released = detached
    NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
  }
  #expect(released == nil)
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 300, height: 150))
  window.contentView = chart
  chart.needsDisplay = false
  NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
  #expect(chart.needsDisplay)
  window.contentView = nil
  window.close()
}

@Test @MainActor func systemDropdownsKeepActionsTablesAndScrollablePlattersForEveryModule() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.loadViewIfNeeded()
  controller.view.setFrameSize(SystemStyle.popoverSize)
  var opened = 0
  var histories: [Module] = []
  var calendarSettings = 0
  controller.onOpenInWindow = { opened += 1 }
  controller.onHistory = { histories.append($0) }
  controller.onCalendarSettings = { calendarSettings += 1 }
  controller.onPause = { [weak controller] in controller?.paused.toggle() }
  for module in Module.allCases {
    for allReadings in [false, true] {
      controller.selected = module
      controller.showsAllReadings = allReadings
      controller.update(Snapshot(), history: [])
      controller.view.layoutSubtreeIfNeeded()
      let buttons = controller.view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
      let open = try #require(buttons.first { $0.title == "Open \(module.title) in TinyStats" })
      #expect(controller.view.bounds.contains(open.frame))
      #expect(open.frame.width == 28)
      #expect(NSApp.sendAction(try #require(open.action), to: open.target, from: open))
      let actions = buttons.compactMap { $0 as? MenuActionRow }.sorted {
        $0.frame.minX < $1.frame.minX
      }
      let hasHistory = [.overview, .cpu, .gpu, .memory, .disks, .network, .battery].contains(module)
      let optionTitle = module == .clock ? "Calendar…" : allReadings ? "Summary" : "All readings"
      let expected =
        (hasHistory ? ["History…"] : []) + [open.title]
        + (module == .overview ? [] : [optionTitle]) + ["Pause"]
      #expect(actions.map(\.title) == expected)
      for action in actions {
        #expect(controller.view.bounds.contains(action.frame))
        #expect(action.frame.size == NSSize(width: 28, height: 28))
        #expect(action.frame.minY == 13)
        #expect(action.image != nil && action.imagePosition == .imageOnly)
        #expect(!action.isBordered && action.usesIconPresentation)
        #expect(action.toolTip == action.accessibilityLabel())
        #expect(action.accessibilityLabel()?.isEmpty == false)
        #expect(action.acceptsFirstResponder && action.focusRingType == .exterior)
        #expect(action.keyEquivalent.isEmpty)
        for other in buttons where action !== other {
          #expect(!action.frame.intersects(other.frame))
        }
      }
      if module != .overview {
        let option = try #require(actions.first { $0.title == optionTitle })
        let expectedLabel =
          module == .clock
          ? "Calendar settings"
          : allReadings
            ? "Show summary"
            : module == .sensors ? "Show all readings and SMC keys" : "Show all readings"
        #expect(option.accessibilityLabel() == expectedLabel)
        let iconBefore = option.image
        #expect(NSApp.sendAction(try #require(option.action), to: option.target, from: option))
        if module == .clock {
          #expect(calendarSettings == (allReadings ? 2 : 1))
          #expect(controller.showsAllReadings == allReadings)
          #expect(option.image === iconBefore)
        } else {
          #expect(controller.showsAllReadings != allReadings)
          #expect(option.title == (allReadings ? "All readings" : "Summary"))
          #expect(option.image !== iconBefore)
          #expect(option.toolTip == option.accessibilityLabel())
          controller.showsAllReadings = allReadings
        }
      }
      let pause = try #require(actions.last)
      let pauseIcon = pause.image
      #expect(pause.frame.maxX == 330)
      #expect(pause.accessibilityLabel() == "Pause")
      pause.performClick(nil)
      #expect(controller.paused && pause.title == "Resume")
      #expect(pause.accessibilityLabel() == "Resume" && pause.toolTip == "Resume")
      #expect(pause.image !== pauseIcon)
      pause.performClick(nil)
      #expect(!controller.paused && pause.accessibilityLabel() == "Pause")
      if let history = buttons.first(where: { $0.title == "History…" }) {
        #expect(NSApp.sendAction(try #require(history.action), to: history.target, from: history))
        #expect(histories.last == module)
      }
      let views = systemDescendants(controller.view)
      #expect(views.compactMap { $0 as? NSTableView }.count == 1)
      if let summary = views.compactMap({ $0 as? SummaryDashboardView }).first, !summary.isHidden {
        #expect(summary.usesPopoverLayout)
        #expect(summary.enclosingScrollView != nil)
        #expect(summary.enclosingScrollView?.frame.minY == 68)
        for card in summary.cards {
          #expect(card.frame.width == summary.bounds.width)
          #expect(summary.bounds.contains(card.frame))
        }
      }
    }
  }
  #expect(opened == Module.allCases.count * 2)
  controller.isPopoverPresentation = false
  controller.selected = .cpu
  controller.showsAllReadings = false
  controller.view.setFrameSize(MainWindow.minimumSize)
  controller.view.layoutSubtreeIfNeeded()
  let summary = try #require(
    controller.view.subviews.compactMap { $0 as? SummaryDashboardView }.first)
  #expect(!summary.usesPopoverLayout && summary.enclosingScrollView == nil)
  let windowButtons = controller.view.subviews.compactMap { $0 as? MenuActionRow }
    .filter { !$0.isHidden }
  #expect(windowButtons.allSatisfy { !$0.usesIconPresentation && $0.isBordered })
  #expect(windowButtons.first { $0.title == "All readings" }?.frame.width == 108)
  #expect(windowButtons.allSatisfy { $0.image == nil })
  #expect(controller.view.subviews.first?.isHidden == false)
  controller.selected = .overview
  controller.view.layoutSubtreeIfNeeded()
  let title = try #require(
    controller.view.subviews.compactMap { $0 as? NSTextField }.first {
      $0.stringValue == "Overview"
    })
  #expect(title.frame.minX == 154)
}

@Test @MainActor func systemDropdownIconActionsParticipateInNativeKeyLoopAndActivate() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.isPopoverPresentation = true
  let window = NSWindow(
    contentRect: .init(origin: .zero, size: SystemStyle.popoverSize), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = controller
  window.setContentSize(SystemStyle.popoverSize)
  defer {
    window.contentViewController = nil
    window.close()
  }
  var opened = 0
  var histories: [Module] = []
  var calendars = 0
  controller.onOpenInWindow = { opened += 1 }
  controller.onHistory = { histories.append($0) }
  controller.onCalendarSettings = { calendars += 1 }
  controller.onPause = { [weak controller] in controller?.paused.toggle() }
  for module in Module.allCases {
    for allReadings in [false, true] {
      controller.selected = module
      controller.showsAllReadings = allReadings
      controller.view.layoutSubtreeIfNeeded()
      let actions = controller.view.subviews.compactMap { $0 as? MenuActionRow }
        .filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
      for (index, button) in actions.enumerated() {
        #expect(window.makeFirstResponder(button))
        #expect(window.firstResponder === button)
        #expect(button.focusRingMaskBounds == button.bounds)
        if index + 1 < actions.count {
          window.selectNextKeyView(button)
          #expect(window.firstResponder === actions[index + 1])
          window.selectPreviousKeyView(actions[index + 1])
          #expect(window.firstResponder === button)
        }
        for (characters, code) in [(" ", UInt16(49)), ("\r", UInt16(36))] {
          let priorOpened = opened
          let priorHistories = histories.count
          let priorCalendars = calendars
          let priorPaused = controller.paused
          let priorReadings = controller.showsAllReadings
          let title = button.title
          let event = try #require(
            NSEvent.keyEvent(
              with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
              windowNumber: window.windowNumber, context: nil, characters: characters,
              charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
          window.sendEvent(event)
          if title.hasPrefix("Open ") {
            #expect(opened == priorOpened + 1)
          } else if title == "History…" {
            #expect(histories.count == priorHistories + 1 && histories.last == module)
          } else if title == "Calendar…" {
            #expect(calendars == priorCalendars + 1)
          } else if title == "Pause" || title == "Resume" {
            #expect(controller.paused != priorPaused)
          } else {
            #expect(controller.showsAllReadings != priorReadings)
          }
        }
      }
      // The native loop must also wrap and skip hidden module actions.
      let first = try #require(actions.first)
      var visited: [NSView] = []
      var candidate: NSView? = first
      while let current = candidate, !visited.contains(where: { $0 === current }),
        visited.count < 40
      {
        visited.append(current)
        candidate = current.nextValidKeyView
      }
      #expect(actions.allSatisfy { action in visited.contains { $0 === action } })
      #expect(!visited.contains { $0.isHiddenOrHasHiddenAncestor })
      if module == .sensors {
        #expect(visited.contains { $0 is NSSearchField })
      }
      if module == .weather {
        // The city picker is disabled while Weather is off; its opt-in action stays available.
        #expect(!visited.contains { ($0 as? NSPopUpButton)?.isEnabled == false })
      }
    }
  }
}

@Test @MainActor func systemDropdownIconsFallbackToAvailableSymbols() throws {
  let fallback = try #require(MenuActionRow.symbolImage("clock", fallback: "clock"))
  let unavailable = try #require(
    MenuActionRow.symbolImage("tinystats.unavailable.symbol", fallback: "clock"))
  #expect(unavailable.tiffRepresentation == fallback.tiffRepresentation)
}

@Test @MainActor func systemDropdownIconHoverAndPressRenderInBothAppearances() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.loadViewIfNeeded()
  controller.view.setFrameSize(SystemStyle.popoverSize)
  controller.selected = .cpu
  controller.view.layoutSubtreeIfNeeded()
  let button = try #require(
    controller.view.subviews.compactMap { $0 as? MenuActionRow }.first { $0.title == "History…" })
  let event = try #require(
    NSEvent.enterExitEvent(
      with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    controller.view.appearance = NSAppearance(named: name)
    func render(_ state: String) throws -> Data {
      let rect = NSRect(x: 0, y: 0, width: 344, height: 54)
      let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: rect))
      controller.view.cacheDisplay(in: rect, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try png.write(to: url.appendingPathComponent("footer-\(state)-\(name.rawValue).png"))
      }
      return png
    }
    let normal = try render("normal")
    button.mouseEntered(with: event)
    let hover = try render("hover")
    button.highlight(true)
    let pressed = try render("pressed")
    #expect(normal != hover && hover != pressed)
    button.highlight(false)
    button.mouseExited(with: event)
    #expect(try render("normal") == normal)
    #expect(button.accessibilityLabel() == "History…")
    button.isEnabled = false
    button.mouseEntered(with: event)
    #expect(!button.acceptsFirstResponder && !button.canBecomeKeyView)
    button.mouseExited(with: event)
    button.isEnabled = true
  }
}

@Test @MainActor func systemPopoverRenderingGalleryPreservesMissingAndZeroReadings() throws {
  _ = NSApplication.shared
  let savedIcon = NSApp.applicationIconImage
  let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Resources/TinyStats.icns")
  NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
  defer { NSApp.applicationIconImage = savedIcon }
  let controller = DetailController()
  controller.isPopoverPresentation = true
  var snapshot = Snapshot()
  snapshot.cpu = .init(
    usage: 23, cores: [31, 28, 22, nil, 0, 12, 52, 39, 9, 4, 18, 27, 36, 45, 54, 63],
    load: [1.84, 2.1, 2.31],
    coreKinds: [
      .efficiency, .efficiency, .efficiency, .efficiency, .efficiency, .efficiency, .performance,
      .performance, .performance, .performance, .performance, .performance, .performance,
      .performance, .performance, .performance,
    ], user: 15, system: 8)
  snapshot.memory = .init(
    total: 24_000_000_000, active: 9_000_000_000, inactive: 2_000_000_000, wired: 2_600_000_000,
    compressed: 2_700_000_000, free: 7_700_000_000, speculative: 0, purgeable: 100_000_000,
    swapUsed: 400_000_000, swapTotal: 1_000_000_000, pressure: 1)
  snapshot.device = .init(model: "Mac mini", chip: "Apple M4", operatingSystem: "macOS 15.0")
  snapshot.uptime = 11 * 86_400 + 5 * 3600
  snapshot.gpus = [
    .init(name: "Apple M4", usage: 8, memory: nil, coreCount: 10, rendererUsage: 6, tilerUsage: 3)
  ]
  snapshot.volumes = [
    .init(name: "Macintosh HD", path: "/", total: 494_000_000_000, available: 193_000_000_000)
  ]
  snapshot.sensors = [
    .init(key: "Tp01", name: "CPU die", kind: .temperature, value: 52),
    .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1034),
    .init(key: "PSTR", name: "System total power", kind: .power, value: 6.8),
  ]
  snapshot.disks = [.init(id: 1, name: "disk0", read: 2_100_000, written: 640_000)]
  snapshot.selectedInterface = "en0"
  snapshot.download = 1_200_000
  snapshot.upload = 48_000
  snapshot.sampleMilliseconds = 3
  snapshot.processes = [
    .init(pid: 42, name: "Xcode", cpu: 38.2, memory: 0, read: nil, written: nil)
  ]
  let history = (0..<150).map { index in
    var point = snapshot.historyPoint
    point.time = Date(timeIntervalSince1970: Double(index * 2))
    point.cpu = index == 75 ? nil : Double(10 + index % 53)
    point.gpu = index == 75 ? nil : Double(index % 19)
    point.download = index == 75 ? nil : Double(500_000 + (index * 127_333) % 4_000_000)
    point.upload = index == 75 ? nil : Double(10_000 + (index * 18_777) % 400_000)
    return point
  }
  controller.loadViewIfNeeded()
  controller.view.setFrameSize(SystemStyle.popoverSize)
  for module in Module.allCases {
    controller.selected = module
    var sample = snapshot
    if module == .battery {
      sample.batteries = [
        .init(
          name: "Internal battery", percent: 63, charging: false, externalPower: false,
          minutesRemaining: 754, cycles: 1234, health: 87, watts: -123.4)
      ]
      sample.sensors.append(.init(key: "TB0T", name: "Battery", kind: .temperature, value: 31))
    }
    controller.update(sample, history: history)
    // Existing filenames keep the summary/running fixture; add the alternate icons per module.
    for alternate in [false, true] {
      controller.showsAllReadings = alternate
      controller.paused = alternate
      for name in [NSAppearance.Name.aqua, .darkAqua] {
        controller.view.appearance = NSAppearance(named: name)
        controller.view.layoutSubtreeIfNeeded()
        let actions = controller.view.subviews.compactMap { $0 as? MenuActionRow }
          .filter { !$0.isHidden }
        #expect(actions.allSatisfy { $0.image != nil && $0.imagePosition == .imageOnly })
        let bitmap = try #require(
          controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
          let url = URL(fileURLWithPath: directory, isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          let state = alternate ? "-readings-paused" : ""
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: url.appendingPathComponent("\(module.rawValue)\(state)-\(name.rawValue).png"))
        }
      }
    }
    controller.showsAllReadings = false
    controller.paused = false
  }
  controller.isPopoverPresentation = false
  controller.selected = .overview
  for size in [MainWindow.minimumSize, NSSize(width: 1000, height: 700)] {
    controller.view.setFrameSize(size)
    controller.update(snapshot, history: history)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      controller.view.appearance = NSAppearance(named: name)
      controller.view.layoutSubtreeIfNeeded()
      let bitmap = try #require(
        controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
      if let directory = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let width = size.width == 1000 ? "" : "-\(Int(size.width))"
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: url.appendingPathComponent("overview-window\(width)-\(name.rawValue).png"))
      }
    }
  }
}

@Test @MainActor func systemSettingsFormsRenderInLightAndDarkWithoutEnablingFeatures() throws {
  _ = NSApplication.shared
  for theme in [AppTheme.light, .dark] {
    var settings = Settings()
    settings.theme = theme
    settings.persistHistory = false
    settings.sensorKey = "missing-sensor"
    settings.readouts = [.cpu, .memory, .network, .disks, .sensors, .weather]
    settings.styles = ["cpu": .ring, "memory": .horizontal, "weather": .icon]
    var snapshot = Snapshot()
    snapshot.cpu = .init(usage: 23, cores: [23], load: [])
    snapshot.memory = .init(
      total: 100, active: 59, inactive: 0, wired: 0, compressed: 0,
      free: 41, speculative: 0, purgeable: 0, swapUsed: 0, swapTotal: 0, pressure: 1)
    snapshot.download = 1_200_000
    snapshot.upload = 48_000
    let controller = PreferencesController(
      settings: settings, interfaces: [], snapshot: snapshot, history: [])
    defer { controller.close() }
    var changes = 0
    controller.onChange = { _ in changes += 1 }
    let root = try #require(controller.window?.contentView)
    for page in [PreferencesController.Page.general, .menuBar] {
      controller.selectPage(page)
      root.layoutSubtreeIfNeeded()
      let views = systemDescendants(root)
      #expect(views.contains { $0 is SystemFormSection })
      #expect(views.contains { $0 is NSSwitch })
      if page == .menuBar {
        let customization = try #require(views.compactMap { $0 as? MenuBarCustomization }.first)
        #expect(customization.strip.chips.map(\.module) == settings.readouts)
        #expect(customization.palette.chips.map(\.module) == [.gpu, .battery, .clock])
        #expect(customization.strip.visibleRect.height >= 50)
        #expect(customization.palette.visibleRect.height >= 80)
        if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
          let url = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          let image = try #require(
            customization.bitmapImageRepForCachingDisplay(in: customization.bounds))
          customization.cacheDisplay(in: customization.bounds, to: image)
          try #require(image.representation(using: .png, properties: [:])).write(
            to: url.appendingPathComponent("settings-menubar-customization-\(theme.rawValue).png"))
        }
      }
      let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
      root.cacheDisplay(in: root.bounds, to: bitmap)
      #expect(bitmap.pixelsWide >= 740 && bitmap.pixelsHigh >= 660)
      if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: url.appendingPathComponent("settings-\(page.identifier)-\(theme.rawValue).png"))
      }
    }
    #expect(changes == 0)
    controller.selectPage(.general)
    let switches = systemDescendants(root).compactMap { $0 as? SystemSettingSwitch }
    #expect(switches.first { $0.title == "Keep history between launches" }?.state == .off)
    controller.selectPage(.menuBar)
    let sensor = systemDescendants(root).compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "Menu bar sensor"
    }
    #expect(sensor?.titleOfSelectedItem == "missing-sensor · unavailable")
  }
}

@Test @MainActor func systemFeatureEditorsUseGroupedFormsAndKeepDraftsLocal() throws {
  _ = NSApplication.shared
  for theme in [AppTheme.light, .dark] {
    var settings = Settings()
    settings.theme = theme
    let rules = RulesController(rules: [.init()], snapshot: Snapshot())
    let internet = InternetSettingsController(connectivity: false, publicIP: false)
    let weather = WeatherSettingsController(settings: settings.weather)
    let calendar = CalendarSettingsController(enabled: false, selectedIDs: [])
    let controllers: [(String, NSWindowController)] = [
      ("rules", rules), ("internet", internet), ("weather", weather), ("calendar", calendar),
      ("battery", BatteryMenuController(settings: settings, snapshot: Snapshot(), history: [])),
      ("clock", ClockMenuController(settings: settings, date: .distantPast)),
      ("world-clock", WorldClockController(settings: settings, date: .distantPast)),
    ]
    var writes = 0
    rules.onSave = { _ in writes += 1 }
    internet.onChange = { _, _, _, _ in writes += 1 }
    weather.onChange = { _ in writes += 1 }
    calendar.onChange = { _, _ in writes += 1 }
    calendar.onPermission = { writes += 1 }
    for (name, controller) in controllers {
      defer { controller.close() }
      controller.window?.appearance = theme.nativeAppearance
      let root = try #require(controller.window?.contentView)
      root.layoutSubtreeIfNeeded()
      let views = systemDescendants(root)
      #expect(views.contains { $0 is SystemFormSection })
      #expect(views.contains { $0 is SystemSettingsForm })
      for group in views.compactMap({ $0 as? SystemFormSection }) {
        #expect(!group.hasAmbiguousLayout)
      }
      if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: url.appendingPathComponent("settings-\(name)-\(theme.rawValue).png"))
      }
    }
    #expect(writes == 0)
  }
}

@MainActor private final class AccentPairGallerySurface: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let rgb = AccentPalette.background(dark: SystemStyle.isDark(effectiveAppearance))
    NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
    bounds.fill()
  }
}

/// A deterministic fixture sheet uses the production ChartView with actual native accent inputs.
/// It supplements live-accent dropdown/Overview renders without changing system preferences.
@Test @MainActor func systemAccentPairGalleryRendersLightAndDarkChartsAndMenuGraphs() throws {
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    let appearance = try #require(NSAppearance(named: name))
    let dark = SystemStyle.isDark(appearance)
    let root = AccentPairGallerySurface(frame: .init(x: 0, y: 0, width: 640, height: 1000))
    root.appearance = appearance
    for (index, fixture) in SystemAccentFixture.all.enumerated() {
      let pair = AccentPalette.derive(
        from: .init(hex: dark ? fixture.dark : fixture.light), dark: dark)
      func color(_ c: AccentPalette.RGB) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
      }
      let y = CGFloat(900 - index * 100)
      let label = NSTextField(
        labelWithString: fixture.name + " · " + pair.primary.hex + " / " + pair.secondary.hex)
      label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      label.frame = .init(x: 12, y: y + 78, width: 610, height: 18)
      root.addSubview(label)
      let chart = ChartView(frame: .init(x: 12, y: y, width: 610, height: 74))
      chart.times = (0..<5).map { Date(timeIntervalSince1970: Double($0 * 2)) }
      chart.series = [
        .init(
          name: "User / Download / Read / P", color: color(pair.primary),
          values: [20, 40, nil, 60, 40]),
        .init(
          name: "System / Upload / Write / E", color: color(pair.secondary),
          values: [10, 20, nil, 30, 20]),
      ]
      #expect(
        (chart.accessibilityValue() as? String)?.contains("System / Upload / Write / E") == true)
      root.addSubview(chart)
    }
    let menu = MenuBarReadoutView(frame: .init(x: 12, y: 8, width: 240, height: 24))
    var network = MenuBarReadout(
      label: "NET", value: "↓ 1 MB/s", secondary: "↑ 48 KB/s", style: .historyValue)
    network.module = .network
    network.isNetwork = true
    network.values = [10, 40, nil, 70, 50]
    network.secondValues = [5, 10, nil, 25, 15]
    var cpu = MenuBarReadout(label: "CPU", value: "23%", secondary: nil, style: .cores)
    cpu.module = .cpu
    cpu.cores = [0, nil, 30, 70]
    cpu.coreKinds = [.efficiency, .efficiency, .performance, .performance]
    menu.readouts = [network, cpu]
    root.addSubview(menu)
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= 640 && bitmap.pixelsHigh >= 1000)
    if let directory = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: url.appendingPathComponent("accent-pairs-\(name.rawValue).png"))
    }
  }
}

@Test @MainActor func pairedSeriesKeepNamedColorsAcrossLiveRecordedAndSingleSeriesCharts() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  let snapshot = Snapshot()
  var point = snapshot.historyPoint
  point.cpuUser = 20
  point.cpuSystem = 10
  point.gpu = 15
  point.upload = 5
  point.download = 25
  point.diskRead = 10
  point.diskWrite = 5
  let overview = try #require(
    DetailReadingsBuilder.build(
      module: .overview, snapshot: snapshot, history: [point], settings: Settings(), paused: false))
  #expect(overview.series.map(\.name) == ["CPU", "Memory"])
  #expect(overview.series.map(\.color) == [SystemStyle.accent, SystemStyle.secondaryAccent])
  var archive = SessionHistory()
  archive.append(point, uptime: 1)
  for module in [Module.cpu, .network, .disks, .gpu] {
    let details = try #require(
      DetailReadingsBuilder.build(
        module: module, snapshot: snapshot, history: [point], settings: Settings(), paused: false))
    #expect(details.series.first?.color == SystemStyle.accent)
    if module == .network || module == .disks {
      #expect(details.series.last?.color == SystemStyle.secondaryAccent)
    } else {
      #expect(details.series.count == 1)
    }
    view.update(snapshot, history: [point], settings: Settings(), module: module)
    let plot = try #require(
      view.cards.compactMap { card -> SummaryDashboardView.Plot? in
        if case .plot(let plot) = card.content { return plot }
        return nil
      }.first)
    #expect(
      plot.firstColor == (module == .network ? SystemStyle.secondaryAccent : SystemStyle.accent))
    if module == .gpu {
      #expect(plot.second.isEmpty && plot.secondLabel.isEmpty)
    } else {
      #expect(
        plot.secondColor == (module == .network ? SystemStyle.accent : SystemStyle.secondaryAccent))
      #expect(!plot.firstLabel.isEmpty && !plot.secondLabel.isEmpty)
    }
    view.updateHistory(archive.projection(.tenMinutes), module: module, fahrenheit: false)
    let recorded = try #require(
      view.cards.compactMap { card -> SummaryDashboardView.Plot? in
        if case .plot(let plot) = card.content { return plot }
        return nil
      }.first)
    #expect(
      recorded.firstColor == (module == .network ? SystemStyle.secondaryAccent : SystemStyle.accent)
    )
    if module == .network || module == .disks {
      #expect(
        recorded.secondColor
          == (module == .network ? SystemStyle.accent : SystemStyle.secondaryAccent))
      #expect(!recorded.secondLabel.isEmpty)
    } else {
      #expect(recorded.second.isEmpty && recorded.secondLabel.isEmpty)
    }
  }
}
