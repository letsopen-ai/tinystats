import AppKit
import ScreenCaptureKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func systemDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + systemDescendants($0) }
}

/// Composite material/document gaps on the native background for standalone PNG review.
@MainActor private func systemGalleryImage(_ view: NSView, to url: URL) throws {
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: view.bounds, to: bitmap)
  }
  let output = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  let context = try #require(NSGraphicsContext(bitmapImageRep: output))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    NSColor.windowBackgroundColor.setFill()
    let rect = NSRect(x: 0, y: 0, width: output.pixelsWide, height: output.pixelsHigh)
    rect.fill()
    let image = NSImage(size: rect.size)
    image.addRepresentation(bitmap)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
  }
  NSGraphicsContext.restoreGraphicsState()
  try #require(output.representation(using: .png, properties: [:])).write(to: url)
}

/// Review the solid accessibility fallback and unchanged legacy material alongside native glass.
@Test @MainActor func systemGlassFallbackGallery() throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] else {
    return
  }
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  for theme in [AppTheme.light, .dark] {
    for treatment in [GlassSurface.Treatment.legacy, .solid] {
      let surface = GlassSurface(environment: {
        .init(
          supportsGlass: treatment != .legacy, reduceTransparency: treatment == .solid,
          increaseContrast: false)
      })
      surface.frame = .init(origin: .zero, size: SystemStyle.popoverSize)
      surface.appearance = theme.nativeAppearance
      let title = NSTextField(labelWithString: "CPU · Paused")
      title.font = .systemFont(ofSize: 13, weight: .semibold)
      title.frame = .init(x: 22, y: 600, width: 280, height: 20)
      surface.addSubview(title)
      let caption = NSTextField(labelWithString: "No reading available")
      caption.textColor = .secondaryLabelColor
      caption.frame = .init(x: 22, y: 570, width: 280, height: 20)
      surface.addSubview(caption)
      try systemGalleryImage(
        surface, to: folder.appendingPathComponent("glass-\(treatment)-\(theme.rawValue).png"))
    }
  }
}

/// Explicit gallery-only capture of our synthetic window. Never request screen-recording access,
/// capture another app, or enable live collection. Bitmap caching alone cannot prove glass blur.
@Test @MainActor func systemGlassOnscreenGallery() async throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"],
    ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_GLASS_CAPTURE"] == "1"
  else { return }
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let report = folder.appendingPathComponent("glass-capture.txt")
  guard GlassSurface.Environment.current.supportsGlass, CGPreflightScreenCaptureAccess() else {
    try
      "On-screen glass capture unavailable: macOS 26 or existing screen-capture permission missing. No permission requested.\n"
      .write(to: report, atomically: true, encoding: .utf8)
    return
  }
  _ = NSApplication.shared
  let savedPolicy = NSApp.activationPolicy()
  _ = NSApp.setActivationPolicy(.accessory)
  NSApp.finishLaunching()
  NSApp.activate()
  defer { _ = NSApp.setActivationPolicy(savedPolicy) }
  let window = GlassGalleryWindow(
    contentRect: .init(x: 80, y: 80, width: 1080, height: 780), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let backdrop = GlassGalleryBackdrop(frame: .init(x: 0, y: 0, width: 1080, height: 780))
  window.contentView = backdrop
  defer {
    for child in backdrop.subviews { child.removeFromSuperview() }
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }
  var snapshot = Snapshot()
  snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
  snapshot.uptime = 968400
  snapshot.device = .init(model: "Mac mini", chip: "Apple M4", operatingSystem: "macOS")
  snapshot.cpu = .init(
    usage: 23, cores: [30, 16], load: [1.2, 1.1, 1], coreKinds: [.efficiency, .performance],
    user: 15, system: 8)
  snapshot.cpuApps = [
    .init(
      name: "TextEdit", bundlePath: "/System/Applications/TextEdit.app", processCount: 1234,
      cpu: 12, memory: 220_000_000, cpuIncomplete: 1),
    .init(
      name: "Terminal", bundlePath: "/System/Applications/Utilities/Terminal.app", processCount: 2,
      cpu: 4, memory: 120_000_000),
  ]
  snapshot.memoryApps = snapshot.cpuApps
  snapshot.memory = .init(
    total: 24_000_000_000, active: 9_000_000_000, inactive: 2_000_000_000, wired: 2_600_000_000,
    compressed: 2_700_000_000, free: 7_700_000_000, speculative: 0, purgeable: 100_000_000,
    swapUsed: 400_000_000, swapTotal: 1_000_000_000, pressure: 1)
  snapshot.networkTraffic.grouping = .bundles
  snapshot.networkTraffic.availability = .ready
  snapshot.networkTraffic.bundles = [
    .init(
      name: "TextEdit", processCount: 1234, pid: nil, download: 2048, upload: 512,
      bundlePath: "/System/Applications/TextEdit.app")
  ]
  snapshot.download = 2048
  snapshot.upload = 512
  snapshot.sensors = [
    .init(key: "Tp01", name: "CPU die", kind: .temperature, value: 52),
    .init(key: "F0Ac", name: "Fan", kind: .fan, value: 1200),
    .init(key: "PSTR", name: "System total power", kind: .power, value: 6.8),
  ]
  snapshot.sensorsSampledAt = snapshot.uptime
  let history = (0..<30).map { index in
    var point = snapshot.historyPoint
    point.time = snapshot.timestamp.addingTimeInterval(Double(index - 29) * 2)
    point.sampleInterval = 2
    point.cpuUser = Double(12 + index % 17)
    point.cpuSystem = Double(5 + index % 9)
    point.cpu = (point.cpuUser ?? 0) + (point.cpuSystem ?? 0)
    point.download = Double(1000 + (index * 173) % 2000)
    point.upload = Double(200 + (index * 107) % 800)
    return point
  }
  window.makeKeyAndOrderFront(nil)
  window.orderFrontRegardless()
  window.displayIfNeeded()
  try await Task.sleep(for: .milliseconds(250))
  let content = try await SCShareableContent.excludingDesktopWindows(
    true, onScreenWindowsOnly: true)
  let ownedWindow = try #require(
    content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
  let filter = SCContentFilter(desktopIndependentWindow: ownedWindow)
  let config = SCStreamConfiguration()
  config.width = 1080
  config.height = 780
  config.showsCursor = false
  config.ignoreShadowsSingleWindow = true
  let surfaces: [(String, Module, Bool, Bool, Int)] = [
    ("cpu", .cpu, true, false, 0), ("memory", .memory, true, false, 0),
    ("network", .network, true, false, 0), ("overview", .overview, true, false, 0),
    ("sensors", .sensors, true, false, 0),
    ("sensors-readings", .sensors, true, false, 0),
    ("main-window", .overview, false, false, 0),
    ("main-sensors", .sensors, false, false, 0),
    ("main-sensors-readings", .sensors, false, false, 0),
    ("settings-menu-bar-cpu", .cpu, false, true, 0),
    ("settings-menu-bar-memory", .memory, false, true, 0),
    ("settings-menu-bar-power", .battery, false, true, 0),
  ]
  let cases =
    surfaces
    + [1, 2].flatMap { fallback in
      surfaces.map { surface, module, dropdown, settings, _ in
        ("\(fallback == 1 ? "solid" : "contrast")-\(surface)", module, dropdown, settings, fallback)
      }
    }
  var activationStates: [String] = []
  for gradient in [false, true] {
    backdrop.gradient = gradient
    backdrop.needsDisplay = true
    for theme in [AppTheme.light, .dark] {
      window.appearance = theme.nativeAppearance
      window.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(750))
      for (surface, module, dropdown, settingsPage, fallback) in cases {
        let controller = DetailController(snapshot: snapshot, history: history)
        controller.glassEnvironment = {
          .init(
            supportsGlass: GlassSurface.Environment.current.supportsGlass,
            reduceTransparency: fallback == 1, increaseContrast: fallback == 2)
        }
        // Seed only synthetic existing observations before loading the view: no collector,
        // permission, timer or live hardware access. This makes the sensor accent inspectable.
        for index in 0..<30 {
          var sample = snapshot
          let offset = Double(index - 29) * 5
          sample.timestamp = snapshot.timestamp.addingTimeInterval(offset)
          sample.uptime = snapshot.uptime + offset
          sample.sensorsSampledAt = sample.uptime
          sample.sensors[0].value = index == 29 ? 52 : Double(48 + index % 5)
          controller.update(sample, history: history)
        }
        controller.settings.processGrouping = .bundles
        controller.isPopoverPresentation = dropdown
        controller.selected = module
        controller.showsAllReadings = surface.hasSuffix("sensors-readings")
        let size = dropdown ? SystemStyle.popoverSize : MainWindow.minimumSize
        controller.view.frame = .init(
          x: (1080 - size.width) / 2, y: (780 - size.height) / 2,
          width: size.width, height: size.height)
        backdrop.addSubview(controller.view)
        var preferences: PreferencesController?
        if settingsPage {
          let editor = PreferencesController(
            settings: controller.settings, interfaces: [],
            snapshot: snapshot, history: [], initialPage: .menuBar)
          preferences = editor
          editor.selectStyleModule(module)
          controller.showSettingsView(
            try #require(editor.embeddedView(page: .menuBar)), page: .menuBar)
        }
        controller.view.layoutSubtreeIfNeeded()
        for tile in systemDescendants(controller.view).compactMap({ $0 as? MenuBarStyleTile }) {
          tile.increaseContrast = { fallback == 2 }
        }
        if let preferences { systemRevealStyleEditor(preferences, in: controller.view) }
        controller.view.layoutSubtreeIfNeeded()
        // Exercise the existing insertion marker above real compositor glass, using
        // only a private synthetic drag payload in our own fixture window.
        var insertionDrag: ReadoutDrag?
        if settingsPage {
          let editor = try #require(
            systemDescendants(controller.view).compactMap { $0 as? MenuBarCustomization }.first)
          let cpu = try #require(editor.chips[.cpu])
          let memory = try #require(editor.chips[.memory])
          let drag = ReadoutDrag()
          drag.draggingSource = cpu
          #expect(drag.draggingPasteboard.writeObjects([editor.pasteboardItem(for: .cpu)]))
          drag.draggingLocation = editor.strip.convert(
            .init(x: memory.frame.minX, y: memory.frame.midY), to: nil)
          #expect(editor.strip.draggingEntered(drag) == .move)
          insertionDrag = drag
        }
        window.makeKey()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        activationStates.append(
          "\(surface)-\(theme.rawValue): active=\(NSApp.isActive), key=\(window.isKeyWindow)")
        let stem = "glass-onscreen-\(surface)\(gradient ? "-gradient" : "")-\(theme.rawValue)"
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: config)
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
          .write(to: folder.appendingPathComponent(stem + ".png"))
        try systemGalleryImage(backdrop, to: folder.appendingPathComponent(stem + "-bitmap.png"))
        if settingsPage && !gradient && NSApp.isActive && window.isKeyWindow {
          try #require(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
          )
          .write(
            to: folder.appendingPathComponent(
              "glass-onscreen-settings-menu-bar-active-\(theme.rawValue).png"))
        }
        insertionDrag?.draggingPasteboard.releaseGlobally()
        controller.view.removeFromSuperview()
        preferences?.disposeEmbedded()
        preferences?.close()
      }
    }
  }
  try
    ("Captured only the owned synthetic window using ScreenCaptureKit after CGPreflightScreenCaptureAccess succeeded. No permission request, real menu bar, live sampling or other application's content. Saturated stripes and a smooth multi-hue gradient exercise glass. Full-content solid/contrast cases inject the same policy inputs as accessibility notifications; system preferences were not changed. Paired bitmap PNGs establish layout only. Activation is reported honestly; inactive native segments may be gray.\n"
    + activationStates.joined(separator: "\n") + "\n")
    .write(to: report, atomically: true, encoding: .utf8)
}

@MainActor private final class GlassGalleryWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor private final class GlassGalleryBackdrop: NSView {
  var gradient = false
  override func draw(_ dirtyRect: NSRect) {
    let colors: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemGreen]
    if gradient {
      NSGradient(colors: colors)?.draw(in: bounds, angle: 24)
      NSGradient(starting: NSColor.systemPink.withAlphaComponent(0.8), ending: .clear)?
        .draw(
          fromCenter: .init(x: bounds.width * 0.65, y: bounds.height * 0.7), radius: 0,
          toCenter: .init(x: bounds.width * 0.65, y: bounds.height * 0.7),
          radius: bounds.width * 0.7,
          options: [.drawsAfterEndingLocation])
      return
    }
    for (index, color) in colors.enumerated() {
      color.setFill()
      NSRect(
        x: CGFloat(index) * bounds.width / 4, y: 0, width: bounds.width / 4, height: bounds.height
      ).fill()
    }
  }
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
      #expect(CPUCoreKind.efficiency.chartColor == SystemStyle.moduleSecondary(.cpu))
      #expect(CPUCoreKind.performance.chartColor == SystemStyle.moduleAccent(.cpu))
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
        #expect(action.toolTip?.hasPrefix(action.accessibilityLabel() ?? "") == true)
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
      #expect(
        pause.accessibilityLabel() == "Resume" && pause.toolTip?.hasPrefix("Resume\n") == true)
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
        #expect(summary.enclosingScrollView?.frame.minY == 48)
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
      if [.cpu, .memory, .network].contains(module) && !allReadings {
        #expect(visited.contains { $0 is ProcessGroupingControl })
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
  snapshot.gpuTime.status = .ready
  snapshot.gpuTime.rows = [
    .init(pid: 42, name: "Xcode", millisecondsPerSecond: 125),
    .init(pid: 43, name: "WindowServer", millisecondsPerSecond: 4.5),
  ]
  snapshot.peripherals = [.init(name: "Keyboard", percent: 75)]
  snapshot.processes = [
    .init(pid: 42, name: "Xcode", cpu: 38.2, memory: 0, read: 22_000, written: 12_000)
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
          let views = systemDescendants(controller.view)
          if alternate, module != .overview,
            let table = views.compactMap({ $0 as? NSTableView }).first
          {
            table.scrollRowToVisible(table.numberOfRows - 1)
            controller.view.layoutSubtreeIfNeeded()
            try systemGalleryImage(
              controller.view,
              to: url.appendingPathComponent(
                "\(module.rawValue)-sample-\(name.rawValue).png"))
            table.scrollRowToVisible(0)
          } else if !alternate {
            for document in views.filter({
              ($0 is SummaryDashboardView || $0 is WeatherDashboardView)
                && !$0.isHiddenOrHasHiddenAncestor
            }) {
              try systemGalleryImage(
                document,
                to: url.appendingPathComponent(
                  "\(module.rawValue)-document-\(name.rawValue).png"))
            }
          }
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
    // Request a key fixture window; the test runner may still receive inactive native ink.
    // AppKit can constrain windows to the current test display's available screen height.
    #expect(root.bounds.width == 740 && root.bounds.height == 660)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    for page in [PreferencesController.Page.general, .menuBar] {
      controller.selectPage(page)
      root.layoutSubtreeIfNeeded()
      let views = systemDescendants(root)
      #expect(views.contains { $0 is SystemFormSection })
      #expect(views.contains { page == .general ? $0 is NSSwitch : $0 is MenuBarChip })
      if page == .menuBar {
        let customization = try #require(views.compactMap { $0 as? MenuBarCustomization }.first)
        #expect(customization.strip.chips.map(\.module) == settings.readouts)
        for toggle in views.compactMap({ $0 as? SystemSettingSwitch }) {
          if let module = Module.allCases.first(where: { $0.title == toggle.title }) {
            #expect((toggle.state == .on) == settings.readouts.contains(module))
          }
        }
        for module in Module.allCases where module != .overview {
          let icon = try #require(
            views.compactMap { $0 as? NSImageView }.first {
              $0.identifier?.rawValue == "readout-icon-\(module.rawValue)"
            })
          #expect(icon.contentTintColor == SystemStyle.moduleAccent(module))
        }
        #expect(customization.palette.chips.map(\.module) == [.gpu, .battery, .clock])
        #expect(customization.strip.visibleRect.height >= 50)
        #expect(customization.palette.visibleRect.height >= 50)
        if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
          let url = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          #expect(SystemStyle.isDark(customization.effectiveAppearance) == (theme == .dark))
          let crop = customization.convert(customization.bounds, to: root)
          let image = try #require(root.bitmapImageRepForCachingDisplay(in: crop))
          root.cacheDisplay(in: crop, to: image)
          let backing = try #require(
            image.colorAt(x: image.pixelsWide - 8, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
          #expect((backing.brightnessComponent < 0.5) == (theme == .dark))
          try #require(image.representation(using: .png, properties: [:])).write(
            to: url.appendingPathComponent("settings-menubar-customization-\(theme.rawValue).png"))
          func captureState(_ state: String) throws {
            root.layoutSubtreeIfNeeded()
            let currentCrop = customization.convert(customization.bounds, to: root)
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: currentCrop))
            root.cacheDisplay(in: currentCrop, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
              to: url.appendingPathComponent(
                "settings-menubar-customization-\(state)-\(theme.rawValue).png"))
          }
          let drag = ReadoutDrag()
          defer { drag.draggingPasteboard.releaseGlobally() }
          let sourceChip = try #require(customization.chips[.gpu])
          drag.draggingSource = sourceChip
          #expect(drag.draggingPasteboard.writeObjects([customization.pasteboardItem(for: .gpu)]))
          let chip = try #require(customization.strip.chips.first)
          drag.draggingLocation = customization.strip.convert(
            .init(x: chip.frame.maxX + 2, y: 26), to: nil)
          #expect(customization.strip.draggingEntered(drag) == .move)
          #expect(customization.strip.insertion == 1)
          try captureState("drag")
          customization.strip.draggingExited(drag)
          var allEnabled = settings
          allEnabled.readouts = Module.allCases.filter { $0 != .overview }
          controller.updateMenuBarSettings(allEnabled)
          root.layoutSubtreeIfNeeded()
          #expect(customization.palette.chips.isEmpty)
          #expect(
            customization.strip.chips.allSatisfy { customization.strip.bounds.contains($0.frame) })
          try captureState("empty-available")
          let full = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
          root.cacheDisplay(in: root.bounds, to: full)
          try #require(full.representation(using: .png, properties: [:])).write(
            to: url.appendingPathComponent(
              "settings-menubar-all-modules-enabled-\(theme.rawValue).png"))
          let secondRow = try #require(customization.strip.chips.first { $0.frame.minY > 12 })
          drag.draggingLocation = customization.strip.convert(
            .init(x: secondRow.frame.minX, y: secondRow.frame.midY), to: nil)
          #expect(customization.strip.draggingEntered(drag) == .move)
          try captureState("wrapped-drag")
          customization.strip.draggingExited(drag)
          controller.updateMenuBarSettings(settings)
        }
      }
      let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
      root.cacheDisplay(in: root.bounds, to: bitmap)
      #expect(
        bitmap.pixelsWide >= Int(root.bounds.width) && bitmap.pixelsHigh >= Int(root.bounds.height))
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
          values: [10, 20, nil, 30, 20], role: .secondary),
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
  #expect(
    overview.series.map(\.color) == [
      SystemStyle.moduleAccent(.cpu), SystemStyle.moduleAccent(.memory),
    ])
  var archive = SessionHistory()
  archive.append(point, uptime: 1)
  for module in [Module.cpu, .network, .disks, .gpu] {
    let details = try #require(
      DetailReadingsBuilder.build(
        module: module, snapshot: snapshot, history: [point], settings: Settings(), paused: false))
    #expect(details.series.first?.color == SystemStyle.moduleAccent(module))
    #expect(details.series.first?.role == .primary)
    if module == .network || module == .disks {
      #expect(details.series.last?.color == SystemStyle.moduleSecondary(module))
      #expect(details.series.last?.role == .secondary)
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
      plot.firstColor
        == (module == .network
          ? SystemStyle.moduleSecondary(module) : SystemStyle.moduleAccent(module)))
    #expect(plot.firstRole == (module == .network ? .secondary : .primary))
    #expect(plot.secondRole == (module == .network ? .primary : .secondary))
    if module == .gpu {
      #expect(plot.second.isEmpty && plot.secondLabel.isEmpty)
    } else {
      #expect(
        plot.secondColor
          == (module == .network
            ? SystemStyle.moduleAccent(module) : SystemStyle.moduleSecondary(module)))
      #expect(!plot.firstLabel.isEmpty && !plot.secondLabel.isEmpty)
    }
    view.updateHistory(archive.projection(.tenMinutes), module: module, fahrenheit: false)
    let recorded = try #require(
      view.cards.compactMap { card -> SummaryDashboardView.Plot? in
        if case .plot(let plot) = card.content { return plot }
        return nil
      }.first)
    #expect(
      recorded.firstColor
        == (module == .network
          ? SystemStyle.moduleSecondary(module) : SystemStyle.moduleAccent(module))
    )
    #expect(recorded.firstRole == plot.firstRole && recorded.secondRole == plot.secondRole)
    if module == .network || module == .disks {
      #expect(
        recorded.secondColor
          == (module == .network
            ? SystemStyle.moduleAccent(module) : SystemStyle.moduleSecondary(module)))
      #expect(!recorded.secondLabel.isEmpty)
    } else {
      #expect(recorded.second.isEmpty && recorded.secondLabel.isEmpty)
    }
  }
}

@Test @MainActor func dropdownReadingsKeepTheirTrailingValuesInsideThePlatter() throws {
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.showsAllReadings = true
  controller.loadViewIfNeeded()
  controller.view.setFrameSize(SystemStyle.popoverSize)
  var snapshot = Snapshot()
  snapshot.cpu = .init(usage: 23, cores: [31, 28], load: [1.84, 2.10, 2.31])
  snapshot.uptime = 968400
  controller.selected = .cpu
  controller.update(snapshot, history: [])
  controller.view.layoutSubtreeIfNeeded()
  let table = try #require(
    systemDescendants(controller.view).compactMap { $0 as? NSTableView }.first)
  let scroll = try #require(table.enclosingScrollView)
  #expect(table.rect(ofColumn: 1).maxX <= scroll.documentVisibleRect.maxX)
  let trailing = table.convert(.init(x: table.rect(ofColumn: 1).maxX, y: 0), to: controller.view)
  #expect(abs(trailing.x - (controller.view.bounds.maxX - 22)) < 1)
  let value = try #require(
    controller.tableView(table, viewFor: table.tableColumns[1], row: 0) as? NSTextField)
  #expect(value.lineBreakMode == .byTruncatingTail)
  #expect(value.stringValue == "1.84 / 2.10 / 2.31")
  #expect(value.toolTip == value.stringValue && value.accessibilityLabel() == value.stringValue)
  #expect(scroll.frame.maxX <= controller.view.bounds.maxX - 22)
  let mask = try #require(scroll.layer?.mask as? CAGradientLayer)
  #expect(scroll.layer?.isGeometryFlipped == true)
  #expect(mask.startPoint.y == 1 && mask.endPoint.y == 0)
  #expect(scroll.contentInsets.bottom == 22)
  // Reserve nonzero cell spacing too, without changing proportions or horizontal extent.
  table.intercellSpacing.width = 3
  controller.view.needsLayout = true
  controller.view.layoutSubtreeIfNeeded()
  #expect(table.columnAutoresizingStyle == .noColumnAutoresizing)
  #expect(table.frame.width <= scroll.contentSize.width + 0.01)
  #expect(abs(table.tableColumns[0].width / table.tableColumns[1].width - 0.55 / 0.45) < 0.001)
  #expect(table.rect(ofColumn: 1).maxX <= scroll.documentVisibleRect.maxX + 0.01)
  let spacedTrailing = table.convert(
    .init(x: table.rect(ofColumn: 1).maxX, y: 0), to: controller.view)
  #expect(abs(spacedTrailing.x - (controller.view.bounds.maxX - 22)) < 1)
}

@Test @MainActor func memoryNeutralSeriesResolveToDistinctInkInBothAppearances() throws {
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    let appearance = try #require(NSAppearance(named: name))
    appearance.performAsCurrentDrawingAppearance {
      let compressed = SystemStyle.neutralSeries.usingColorSpace(.sRGB)
      let available = SystemStyle.availableSeries.usingColorSpace(.sRGB)
      #expect(compressed?.redComponent == (name == .darkAqua ? 1 : 0))
      #expect(available?.redComponent == compressed?.redComponent)
      #expect(compressed?.alphaComponent == 0.55 && available?.alphaComponent == 0.12)
    }
  }
}

@Test @MainActor func bottomScrollFadeKeepsTopOpaqueAndFadesOnlyFooterEdge() throws {
  _ = NSApplication.shared
  let root = NSView(frame: .init(x: 0, y: 0, width: 100, height: 100))
  root.wantsLayer = true
  root.layer?.backgroundColor = NSColor.black.cgColor
  let scroll = PopoverScrollView(frame: root.bounds)
  scroll.drawsBackground = true
  scroll.backgroundColor = .white
  let document = NSView(frame: .init(x: 0, y: 0, width: 100, height: 200))
  document.wantsLayer = true
  document.layer?.backgroundColor = NSColor.white.cgColor
  scroll.documentView = document
  root.addSubview(scroll)
  scroll.fadesBottom = true
  root.layoutSubtreeIfNeeded()
  let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
  root.cacheDisplay(in: root.bounds, to: bitmap)
  let top = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 3)?.usingColorSpace(.sRGB))
  let bottom = try #require(
    bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 3)?.usingColorSpace(.sRGB))
  let transition = try #require(
    bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(Double(bitmap.pixelsHigh) * 0.86))?
      .usingColorSpace(.sRGB))
  #expect(transition.redComponent > 0.20 && transition.redComponent < 0.80)
  #expect(top.redComponent > 0.95)
  #expect(bottom.redComponent < 0.20)
  // Prove this measures the mask, rather than empty document inset or clipping.
  scroll.layer?.mask = nil
  let unmasked = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
  root.cacheDisplay(in: root.bounds, to: unmasked)
  let reference = try #require(
    unmasked.colorAt(x: unmasked.pixelsWide / 2, y: unmasked.pixelsHigh - 3)?.usingColorSpace(.sRGB)
  )
  #expect(reference.redComponent > 0.95)
}

@Test @MainActor func chartRoleSurvivesEmptyAndReorderedSeries() throws {
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 280, height: 120))
  chart.times = (0..<5).map { Date(timeIntervalSince1970: Double($0)) }
  let primary = ChartView.Series(
    name: "Download", color: .systemBlue, values: [20, 40, nil, 60, 40], role: .primary)
  let secondary = ChartView.Series(
    name: "Upload", color: .systemOrange, values: [10, 20, nil, 30, 20], role: .secondary)
  func plotImage(_ series: [ChartView.Series]) throws -> Data {
    chart.series = series
    let bitmap = try #require(chart.bitmapImageRepForCachingDisplay(in: chart.plotArea))
    chart.cacheDisplay(in: chart.plotArea, to: bitmap)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
  var missing = secondary
  missing.values = [nil, nil, nil, nil, nil]
  #expect(try plotImage([primary]) == plotImage([missing, primary]))
  #expect(!primary.role.dashed && primary.role.legendMarker == .first)
  #expect(secondary.role.dashed && secondary.role.legendMarker == .second)
  missing = primary
  missing.values = []
  #expect(try plotImage([secondary]) == plotImage([missing, secondary]))
}

@Test @MainActor func pausedMemoryProcessRowsUseTheSharedTableStyleAndShortHeader() throws {
  _ = NSApplication.shared
  var snapshot = Snapshot()
  snapshot.memory = .init(
    total: 100, active: 59, inactive: 0, wired: 0, compressed: 0,
    free: 41, speculative: 0, purgeable: 0, swapUsed: 0, swapTotal: 0, pressure: 1)
  snapshot.processes = [.init(pid: 42, name: "Xcode", cpu: nil, memory: 0, read: nil, written: nil)]
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.showsAllReadings = true
  controller.paused = true
  controller.selected = .memory
  controller.view.setFrameSize(SystemStyle.popoverSize)
  controller.update(snapshot, history: [])
  controller.view.layoutSubtreeIfNeeded()
  let table = try #require(
    systemDescendants(controller.view).compactMap { $0 as? NSTableView }.first)
  func label(_ row: Int) throws -> NSTextField {
    try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField)
  }
  let labels = try (0..<table.numberOfRows).map { try label($0) }
  let header = try #require(labels.first { $0.stringValue == "Top memory" })
  #expect(header.accessibilityLabel() == "Top memory · physical footprint")
  let process = try #require(labels.first { $0.stringValue == "Xcode · 42" })
  let active = try #require(labels.first { $0.stringValue == "Active" })
  #expect(process.font == active.font && process.textColor == active.textColor)
  #expect(
    process.convert(process.bounds, to: controller.view).minX
      == active.convert(active.bounds, to: controller.view).minX)
  #expect(abs(process.convert(process.bounds, to: controller.view).minX - 22) < 1)
}

@Test @MainActor func emptyProcessCardsStayCompactInThePopover() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 324, height: 600))
  view.usesPopoverLayout = true
  for module in [Module.cpu, .disks, .network] {
    view.update(Snapshot(), history: [], settings: Settings(), module: module)
    let card = try #require(
      view.cards.first {
        $0.title == "TOP PROCESSES" || $0.title == "PROCESS TRAFFIC · PARTIAL"
      })
    #expect(card.frame.height == 56)
    #expect(!card.note.isEmpty)
  }
}

/// Exercise the production header, icon cells and worker projections with local-only fixtures.
@Test @MainActor func systemProcessGroupingGalleryAndHeadersCoverAllThreeModules() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.view.setFrameSize(SystemStyle.popoverSize)
  let terminal = "/System/Applications/Utilities/Terminal.app"
  let editor = "/System/Applications/TextEdit.app"
  var sample = Snapshot()
  sample.cpu = .init(usage: 23, cores: [30, 16], load: [1.2, 1.1, 1.0], user: 15, system: 8)
  sample.memory = .init(
    total: 24_000_000_000, active: 9_000_000_000, inactive: 2_000_000_000, wired: 2_600_000_000,
    compressed: 2_700_000_000, free: 7_700_000_000, speculative: 0, purgeable: 100_000_000,
    swapUsed: 400_000_000, swapTotal: 1_000_000_000, pressure: 1)
  sample.processes = [
    .init(pid: 42, name: "Terminal helper", cpu: 18, memory: 220_000_000, read: nil, written: nil),
    .init(pid: 43, name: "TextEdit", cpu: 4, memory: 120_000_000, read: nil, written: nil),
    .init(pid: 99, name: "Shared broker", cpu: 1, memory: 40_000_000, read: nil, written: nil),
  ]
  sample.cpuApps = [
    .init(name: "Terminal", bundlePath: terminal, processCount: 12, cpu: 38, memory: 420_000_000),
    .init(name: "TextEdit", bundlePath: editor, processCount: 1, cpu: 4, memory: 120_000_000),
    .init(name: "Shared broker", pid: 99, processCount: 1, cpu: 1, memory: 40_000_000),
  ]
  sample.memoryApps = sample.cpuApps
  sample.selectedInterface = "en0"
  sample.download = 2048
  sample.upload = 1024
  sample.networkTraffic.availability = .ready
  sample.networkTraffic.message = "Ready · socket byte counters"
  sample.networkTraffic.processes = [
    .init(pid: 42, uniqueID: 1, name: "Terminal helper", download: 2048, upload: 1024)
  ]
  sample.networkTraffic.bundles = [
    .init(
      name: "Terminal", processCount: 12, pid: nil, download: 4096, upload: 1024,
      bundlePath: terminal),
    .init(
      name: "TextEdit", processCount: 1, pid: nil, download: 1024, upload: 2048, bundlePath: editor),
    .init(name: "Shared broker", processCount: 1, pid: 99, download: 512, upload: 256),
  ]
  let history = (0..<20).map { index in
    var point = sample.historyPoint
    point.time = Date(timeIntervalSince1970: Double(index * 2))
    return point
  }
  func capture(_ view: NSView, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] else {
      return
    }
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    // A document-only crop has transparent platter gaps/material. Composite it on the
    // native background so dark ink/fills remain reviewable in ordinary PNG viewers.
    let output = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: output))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      let rect = NSRect(x: 0, y: 0, width: output.pixelsWide, height: output.pixelsHigh)
      rect.fill()
      let image = NSImage(size: rect.size)
      image.addRepresentation(bitmap)
      image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    try #require(output.representation(using: .png, properties: [:])).write(
      to: folder.appendingPathComponent(name + ".png"))
  }
  for theme in [AppTheme.light, .dark] {
    controller.view.appearance = theme.nativeAppearance
    for module in [Module.cpu, .memory, .network] {
      controller.selected = module
      for mode in [TrafficGrouping.processes, .bundles] {
        controller.showsAllReadings = false
        controller.paused = false
        controller.settings.processGrouping = mode
        var snapshot = sample
        snapshot.networkTraffic.grouping = mode
        controller.update(snapshot, history: history)
        controller.view.layoutSubtreeIfNeeded()
        let summary = try #require(
          systemDescendants(controller.view).compactMap { $0 as? SummaryDashboardView }.first)
        let control = try #require(
          systemDescendants(controller.view).compactMap { $0 as? ProcessGroupingControl }.first)
        let card = try #require(summary.cards.first { $0.groupsProcesses })
        #expect(control.superview === summary && card.frame.contains(control.frame))
        #expect(control.frame.minY == card.frame.minY + 9)
        #expect(
          control.label(forSegment: 0) == "Processes" && control.label(forSegment: 1) == "Apps")
        #expect(
          control.accessibilityLabel() == "Process list grouping" && control.controlSize == .small)
        #expect(control.selectedSegment == (mode == .bundles ? 1 : 0))
        if mode == .bundles {
          #expect(card.spoken.contains("Terminal · 12 processes") && card.spoken.contains(terminal))
          let entry = summary.appDisplayCache.entry(path: terminal, fallback: "Terminal")
          #expect(entry.icon.size.width > 0 && !entry.name.isEmpty)
        } else {
          #expect(card.spoken.contains("Terminal helper") && !card.spoken.contains("12 processes"))
        }
        let stem = "\(module.rawValue)-\(mode == .bundles ? "apps" : "processes")-\(theme.rawValue)"
        // The whole document includes below-fold process cards; root also checks actual viewport chrome.
        try capture(summary, name: stem + "-details")
        try capture(controller.view, name: stem + "-dropdown")
        let windowController = DetailController()
        windowController.settings = controller.settings
        windowController.selected = module
        windowController.view.appearance = theme.nativeAppearance
        windowController.view.setFrameSize(MainWindow.minimumSize)
        windowController.update(snapshot, history: history)
        windowController.view.layoutSubtreeIfNeeded()
        let windowSummary = try #require(
          systemDescendants(windowController.view).compactMap { $0 as? SummaryDashboardView }.first)
        let windowCard = try #require(windowSummary.cards.first { $0.groupsProcesses })
        let windowControl = try #require(windowSummary.groupingControl)
        #expect(windowCard.frame.contains(windowControl.frame))
        try capture(windowController.view, name: stem + "-window")
        controller.paused = true
        controller.view.layoutSubtreeIfNeeded()
        try capture(controller.view, name: stem + "-summary-paused")
        if mode == .bundles {
          controller.showsAllReadings = true
          controller.paused = true
          controller.update(snapshot, history: history)
          controller.view.layoutSubtreeIfNeeded()
          let table = try #require(
            systemDescendants(controller.view).compactMap { $0 as? NSTableView }.first)
          let presentation = try #require(
            DetailReadingsBuilder.build(
              module: module, snapshot: snapshot, history: history, settings: controller.settings,
              paused: true))
          let header = try #require(presentation.rows.firstIndex { $0.processGroupingHeader })
          table.scrollRowToVisible(min(table.numberOfRows - 1, header + 5))
          table.scrollRowToVisible(header)
          controller.view.layoutSubtreeIfNeeded()
          let headerCell = try #require(table.view(atColumn: 1, row: header, makeIfNecessary: true))
          #expect(control.superview === headerCell)
          #expect(headerCell.bounds.contains(control.frame))
          #expect(presentation.rows.contains { $0.bundlePath == terminal && $0.processCount == 12 })
          try capture(controller.view, name: stem + "-readings-paused")
        }
      }
    }
  }
}

@Test @MainActor func sharedHeaderControlSwitchesCPUAndMemoryRowsAndSurvivesNavigation() throws {
  let controller = DetailController()
  var sample = Snapshot()
  sample.processes = [.init(pid: 42, name: "Helper", cpu: 2, memory: 100, read: nil, written: nil)]
  sample.cpuApps = [
    .init(name: "Outer", bundlePath: "/Outer.app", processCount: 2, cpu: 4, memory: 200)
  ]
  sample.memoryApps = sample.cpuApps
  sample.networkTraffic.availability = .ready
  sample.networkTraffic.processes = [
    .init(pid: 42, uniqueID: 1, name: "Helper", download: 1, upload: 1)
  ]
  sample.networkTraffic.bundles = [
    .init(
      name: "Outer", processCount: 2, pid: nil, download: 2, upload: 2, bundlePath: "/Outer.app")
  ]
  controller.selected = .cpu
  controller.update(sample, history: [])
  let control = try #require(
    systemDescendants(controller.view).compactMap { $0 as? ProcessGroupingControl }.first)
  var chosen: [TrafficGrouping] = []
  controller.onProcessGrouping = { chosen.append($0) }
  for module in [Module.cpu, .memory, .network] {
    controller.selected = module
    control.selectedSegment = 1
    #expect(NSApp.sendAction(try #require(control.action), to: control.target, from: control))
    #expect(controller.settings.processGrouping == .bundles)
    sample.networkTraffic.grouping = .bundles
    controller.update(sample, history: [])
    let summary = try #require(control.superview as? SummaryDashboardView)
    #expect(
      summary.cards.contains {
        $0.groupsProcesses && $0.title.hasPrefix(module == .network ? "APP TRAFFIC" : "TOP APPS")
      })
    #expect(
      summary.cards.filter { $0.groupsProcesses }.map(\.spoken).joined().contains(
        "Outer · 2 processes"))
    #expect(!summary.cards.filter { $0.groupsProcesses }.map(\.spoken).joined().contains("Helper"))
    control.selectedSegment = 0
    #expect(NSApp.sendAction(try #require(control.action), to: control.target, from: control))
    #expect(controller.settings.processGrouping == .processes)
    sample.networkTraffic.grouping = .processes
    controller.update(sample, history: [])
    #expect(summary.cards.filter { $0.groupsProcesses }.map(\.spoken).joined().contains("Helper"))
    #expect(!summary.cards.filter { $0.groupsProcesses }.map(\.spoken).joined().contains("Outer"))
  }
  #expect(chosen == [.bundles, .processes, .bundles, .processes, .bundles, .processes])
}

@Test @MainActor func systemSensorStatesGalleryAndScrolledFade() throws {
  guard let directory = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] else {
    return
  }
  let folder = URL(fileURLWithPath: directory, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.selected = .sensors
  detail.view.setFrameSize(SystemStyle.popoverSize)
  for all in [false, true] {
    detail.isPopoverPresentation = false
    detail.view.setFrameSize(MainWindow.minimumSize)
    detail.showsAllReadings = all
    var sample = Snapshot()
    sample.sensors = [
      .init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 45),
      .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1200),
    ]
    detail.update(sample, history: [])
    for theme in [AppTheme.light, .dark] {
      detail.view.appearance = theme.nativeAppearance
      detail.view.layoutSubtreeIfNeeded()
      try systemGalleryImage(
        detail.view,
        to: folder.appendingPathComponent(
          "sensors-window-\(all ? "readings" : "summary")-\(theme.rawValue).png"))
    }
  }
  detail.isPopoverPresentation = true
  detail.view.setFrameSize(SystemStyle.popoverSize)
  for state in ["empty", "populated", "scan-limit"] {
    var sample = Snapshot()
    sample.sensors =
      state == "empty"
      ? []
      : [
        .init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 45),
        .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1200),
      ]
    if state == "scan-limit" {
      sample.sensors += (0..<126).map {
        .init(key: "Te\($0)", name: "CPU", kind: .temperature, value: 50)
      }
    }
    for index in 0..<3 {
      sample.uptime = Double(100 + index * 6)
      sample.timestamp = Date(timeIntervalSince1970: 1_700_000_000 + sample.uptime)
      sample.sensorsSampledAt = sample.uptime
      detail.update(sample, history: [])
    }
    for all in [false, true] {
      detail.showsAllReadings = all
      for paused in [false, true] {
        detail.paused = paused
        for theme in [AppTheme.light, .dark] {
          detail.view.appearance = theme.nativeAppearance
          detail.view.layoutSubtreeIfNeeded()
          let stem =
            "sensors-\(state)-\(all ? "readings" : "summary")-\(paused ? "paused" : "running")-\(theme.rawValue)"
          try systemGalleryImage(detail.view, to: folder.appendingPathComponent(stem + ".png"))
          if state == "scan-limit", all {
            let table = try #require(
              systemDescendants(detail.view).compactMap { $0 as? NSTableView }.first)
            table.scrollRowToVisible(min(20, table.numberOfRows - 1))
            detail.view.layoutSubtreeIfNeeded()
            try systemGalleryImage(
              detail.view, to: folder.appendingPathComponent(stem + "-scrolled.png"))
            table.scrollRowToVisible(0)
          }
        }
      }
    }
  }
}

/// Detached native controls use AppKit's active drawing appearance without foreground input.
@Test @MainActor func menuBarSwitchActiveAppearanceHasDistinctNativeOnInk() throws {
  _ = NSApplication.shared
  for theme in [AppTheme.light, .dark] {
    let root = NSView(frame: .init(x: 0, y: 0, width: 240, height: 80))
    root.appearance = theme.nativeAppearance
    let controls = [SystemSettingSwitch(title: "CPU"), SystemSettingSwitch(title: "GPU")]
    for (index, control) in controls.enumerated() {
      control.controlSize = .small
      control.state = index == 0 ? .on : .off
      control.frame = .init(x: 32 + index * 120, y: 26, width: 42, height: 24)
      root.addSubview(control)
    }
    root.layoutSubtreeIfNeeded()
    var samples: [[(luminance: CGFloat, alpha: CGFloat)]] = []
    for control in controls {
      let bitmap = try #require(control.bitmapImageRepForCachingDisplay(in: control.bounds))
      control.effectiveAppearance.performAsCurrentDrawingAppearance {
        control.cacheDisplay(in: control.bounds, to: bitmap)
      }
      var pixels: [(luminance: CGFloat, alpha: CGFloat)] = []
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
          let channels = [color.redComponent, color.greenComponent, color.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
          }
          pixels.append(
            (
              channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722,
              color.alphaComponent
            ))
        }
      }
      samples.append(pixels)
    }
    #expect(samples[0].count == samples[1].count)
    // Native ON must differ even with a neutral Graphite accent: compare coverage
    // and premultiplied luminance rather than requiring chromatic track pixels.
    var distinctPixels = 0
    for (on, off) in zip(samples[0], samples[1]) {
      let alphaDifference = abs(on.alpha - off.alpha)
      let luminanceDifference = abs(on.luminance * on.alpha - off.luminance * off.alpha)
      if alphaDifference > 0.1 || luminanceDifference > 0.1 { distinctPixels += 1 }
    }
    #expect(distinctPixels > 20)
    if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
      let folder = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try systemGalleryImage(
        root,
        to: folder.appendingPathComponent(
          "glass-offscreen-settings-menu-bar-active-\(theme.rawValue).png"))
      try
        "Detached native switch active drawing appearance. Native ON/OFF distinct luminance/alpha pixels: \(distinctPixels). No claim of foreground activation.\n"
        .write(
          to: folder.appendingPathComponent("switch-active-\(theme.rawValue).txt"),
          atomically: true, encoding: .utf8)
    }
  }
}

/// The editor is scrolled inside our fixture so pictures and the compact bottom row share a frame.
@Test @MainActor func systemMenuBarPictureEditorGallery() throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] else {
    return
  }
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  for theme in [AppTheme.light, .dark] {
    for policy in ["glass", "legacy", "solid", "contrast"] {
      for module in [Module.cpu, .memory, .battery, .clock, .sensors] {
        var settings = Settings()
        settings.theme = theme
        let detail = DetailController(snapshot: Snapshot(), history: [])
        detail.glassEnvironment = {
          .init(
            supportsGlass: policy != "legacy", reduceTransparency: policy == "solid",
            increaseContrast: policy == "contrast")
        }
        detail.isPopoverPresentation = false
        detail.view.frame = .init(origin: .zero, size: MainWindow.minimumSize)
        let editor = PreferencesController(
          settings: settings, interfaces: [], snapshot: Snapshot(), history: [],
          initialPage: .menuBar)
        defer {
          editor.disposeEmbedded()
          editor.close()
        }
        editor.selectStyleModule(module)
        detail.showSettingsView(try #require(editor.embeddedView(page: .menuBar)), page: .menuBar)
        detail.view.appearance = theme.nativeAppearance
        detail.view.layoutSubtreeIfNeeded()
        systemRevealStyleEditor(editor, in: detail.view)
        detail.view.layoutSubtreeIfNeeded()
        let picker = try #require(
          systemDescendants(detail.view).compactMap { $0 as? MenuBarStylePicker }.first {
            $0.module == module
          })
        for tile in picker.tiles { tile.increaseContrast = { policy == "contrast" } }
        let options = try #require(picker.superview?.superview)
        let document = try #require(options.enclosingScrollView?.documentView)
        let bottomChrome =
          document.bounds.height - picker.convert(picker.bounds, to: document).maxY
        #expect(bottomChrome <= PreferencesController.menuBarCPUBottomChromeBudget + 0.5)
        if module == .cpu {
          #expect(options.bounds.height <= PreferencesController.menuBarCPUOptionsHeightBudget)
        }
        let metrics =
          "\(module.title) \(policy) \(theme.rawValue): pane=\(picker.bounds.width)pt, options=\(options.bounds.height)pt, grid=\(picker.bounds.height)pt, tiles-to-document-end=\(bottomChrome)pt\n"
        let file = folder.appendingPathComponent(
          "menu-bar-layout-\(module.rawValue)-\(policy)-\(theme.rawValue).txt")
        try metrics.write(to: file, atomically: true, encoding: .utf8)
        #expect(picker.visibleRect.height >= picker.bounds.height - 1)
        let header = try #require((picker.superview as? NSStackView)?.arrangedSubviews.first)
        #expect(header.visibleRect.height >= header.bounds.height - 1)
        if module == .battery {
          let tools = try #require(
            systemDescendants(detail.view).first {
              $0.identifier?.rawValue == "menu-bar-battery-tools"
            })
          #expect(tools.visibleRect.height >= tools.bounds.height - 1)
          #expect(tools.bounds.height <= PreferencesController.menuBarToolsHeightBudget)
        }
        try systemGalleryImage(
          detail.view,
          to: folder.appendingPathComponent(
            "settings-menu-bar-\(module.rawValue)-\(policy)-\(theme.rawValue).png"))
      }
    }
  }
}

@MainActor private func systemRevealStyleEditor(_ editor: PreferencesController, in root: NSView) {
  root.layoutSubtreeIfNeeded()
  if let picker = systemDescendants(root).compactMap({ $0 as? MenuBarStylePicker }).first(where: {
    $0.module == editor.selectedStyleModule
  }), let section = picker.superview {
    section.scrollToVisible(section.bounds)
  }
}
