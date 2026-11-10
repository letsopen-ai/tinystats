import AppKit
import ScreenCaptureKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private final class MenuBarClickEvidenceView: NSView {
  var clickX: CGFloat = 0
  override func draw(_ dirtyRect: NSRect) {
    NSGradient(colors: [.systemPink, .systemPurple, .systemBlue, .systemTeal])?
      .draw(in: bounds, angle: 25)
    NSColor.windowBackgroundColor.setFill()
    NSRect(x: 0, y: 678, width: bounds.width, height: 82).fill()
    NSColor.controlBackgroundColor.setFill()
    NSBezierPath(
      roundedRect: .init(x: 20, y: 698, width: 480, height: 28),
      xRadius: 6, yRadius: 6
    ).fill()
    NSColor.labelColor.setFill()
    let marker = NSBezierPath()
    marker.move(to: .init(x: clickX, y: 700))
    marker.line(to: .init(x: clickX - 5, y: 688))
    marker.line(to: .init(x: clickX + 5, y: 688))
    marker.close()
    marker.fill()
  }
}

@MainActor private func menuBarClickBitmap(_ view: NSView, to url: URL) throws {
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: view.bounds, to: bitmap)
  }
  try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
}

/// No status items or collectors are created. Every event targets an owned view/window.
/// Bitmap evidence is always generated; optional compositor captures preflight existing access.
@Test @MainActor func menuBarClickRoutingEvidence() async throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] else {
    return
  }
  _ = NSApplication.shared
  let previousIcon = NSApp.applicationIconImage
  NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/TinyStats.icns")
  defer { NSApp.applicationIconImage = previousIcon }
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let window = NSWindow(
    contentRect: .init(x: 150, y: 100, width: 520, height: 760),
    styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let root = MenuBarClickEvidenceView(frame: .init(x: 0, y: 0, width: 520, height: 760))
  window.contentView = root
  defer {
    window.orderOut(nil)
    window.close()
  }
  let caption = NSTextField(labelWithString: "")
  caption.frame = .init(x: 20, y: 734, width: 480, height: 20)
  caption.font = .systemFont(ofSize: 13, weight: .medium)
  root.addSubview(caption)
  let button = NSButton(frame: .init(x: 30, y: 700, width: 460, height: 24))
  button.isBordered = false
  button.title = ""
  root.addSubview(button)
  let renderer = MenuBarReadoutView(frame: button.bounds)
  button.addSubview(renderer)
  let modules: [Module] = [.cpu, .memory, .network, .battery]
  var snapshot = Snapshot()
  snapshot.cpu = .init(
    usage: 23, cores: [31, 18, 24, 19, 32, 14, 27, 19], load: [1.2, 1.4, 1.6],
    coreKinds: [
      .efficiency, .efficiency, .efficiency, .efficiency, .performance, .performance,
      .performance, .performance,
    ], user: 15, system: 8)
  snapshot.memory = .init(
    total: 24_000_000_000, active: 9_000_000_000,
    inactive: 2_000_000_000, wired: 2_600_000_000, compressed: 2_700_000_000,
    free: 7_700_000_000, speculative: 0, purgeable: 100_000_000,
    swapUsed: 400_000_000, swapTotal: 1_000_000_000, pressure: 1)
  snapshot.download = 1_200_000
  snapshot.upload = 48_000
  snapshot.selectedInterface = "en0"
  snapshot.batteries = [
    .init(
      name: "Internal battery", percent: 63, charging: false,
      externalPower: false, minutesRemaining: 240, cycles: 123, health: 94, watts: -8.2)
  ]
  let history = (0..<80).map { index in
    var point = snapshot.historyPoint
    point.time = Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 2))
    point.cpu = Double(15 + index % 23)
    point.download = Double(500_000 + index % 17 * 90_000)
    point.upload = Double(10_000 + index % 11 * 4_000)
    return point
  }
  var settings = Settings()
  settings.separateItems = false
  settings.readouts = modules
  renderer.readouts = modules.flatMap {
    MenuBarReadout.makeAll(module: $0, snapshot: snapshot, settings: settings, history: history)
  }
  button.frame.size.width = renderer.preferredWidth
  renderer.frame = button.bounds
  // Keep the native popover on a separate owned anchor. ScreenCaptureKit includes a
  // window's child popovers in desktop-independent captures; anchoring to the gallery
  // would put the native page over its mirrored compositor surface a second time.
  let screen = try #require(NSScreen.main).frame
  let routingWindow = NSWindow(
    contentRect: .init(x: screen.maxX - 500, y: screen.maxY - 120, width: 480, height: 50),
    styleMask: [.borderless], backing: .buffered, defer: false)
  routingWindow.isReleasedWhenClosed = false
  let routingButton = NSButton(
    frame: .init(x: 10, y: 12, width: renderer.preferredWidth, height: 24))
  let routingReadout = MenuBarReadoutView(frame: routingButton.bounds)
  routingReadout.readouts = renderer.readouts
  routingButton.addSubview(routingReadout)
  routingWindow.contentView?.addSubview(routingButton)
  routingWindow.orderFrontRegardless()
  defer { routingWindow.close() }
  var cursor = NSPoint.zero
  let items = StatusItemController(
    targets: [.init(module: modules[0], button: routingButton, readout: routingReadout)],
    combined: true,
    mouseLocation: { cursor })
  let app = AppDelegate(
    statusItems: items, popoverInteraction: PopoverInteraction(mouseLocation: { cursor }),
    settings: settings, snapshot: snapshot, history: history,
    clickTrace: MenuBarClickTrace(environment: [:]))
  defer {
    app.popoverInteraction.stop()
    app.popover?.animates = false
    app.popover?.close()
  }
  // The gallery's compositor surface mirrors the page selected by the real delegate.
  let controller = DetailController(snapshot: snapshot, history: history)
  controller.isPopoverPresentation = true
  controller.settings = settings
  controller.view.frame = .init(x: 88, y: 28, width: 344, height: 640)
  root.addSubview(controller.view)
  defer { controller.view.removeFromSuperview() }
  var sequence = [
    "Owned-window simulation through AppDelegate/PopoverInteraction; no physical menu-bar clicks. The gallery mirrors the production-selected page."
  ]
  let interaction = app.popoverInteraction
  func record(_ label: String) {
    sequence.append(
      "\(label) selected=\(app.detail?.selected.rawValue ?? "unavailable") shown=\(app.popover?.isShown == true)"
    )
  }
  window.orderFrontRegardless()
  let glassRequested = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_GLASS_CAPTURE"] == "1"
  var capturedGlass = false
  for theme in [AppTheme.light, .dark] {
    root.appearance = theme.nativeAppearance
    window.appearance = theme.nativeAppearance
    controller.settings.theme = theme
    app.popover?.close()
    for module in modules {
      let segment = try #require(renderer.segments.first { $0.module == module })
      let point = routingReadout.convert(.init(x: segment.frame.midX, y: 12), to: nil)
      cursor = routingWindow.convertPoint(toScreen: point)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: point,
          modifierFlags: [], timestamp: 1, windowNumber: routingWindow.windowNumber, context: nil,
          eventNumber: 1, clickCount: 1, pressure: 1))
      if app.popover?.isShown != true {
        app.activateStatusButton(routingButton, event: event)
        app.popover?.animates = false
      } else {
        let presented = app.popover
        #expect(interaction.handle(event) == nil)
        #expect(app.popover === presented)
      }
      #expect(app.popover?.isShown == true && app.detail?.selected == module)
      record("click=\(module.rawValue)")
      controller.selected = try #require(app.detail).selected
      controller.update(snapshot, history: history)
      root.clickX = renderer.convert(.init(x: segment.frame.midX, y: 12), to: root).x
      caption.stringValue = "One layout · simulated click: \(module.title)"
      root.needsDisplay = true
      root.layoutSubtreeIfNeeded()
      let filename = "combined-item-\(module.rawValue)-\(theme.rawValue).png"
      try menuBarClickBitmap(root, to: folder.appendingPathComponent(filename))
      if glassRequested, #available(macOS 26, *), CGPreflightScreenCaptureAccess() {
        let glass = folder.appendingPathComponent("glass", isDirectory: true)
        try FileManager.default.createDirectory(at: glass, withIntermediateDirectories: true)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let content = try await SCShareableContent.excludingDesktopWindows(
          true, onScreenWindowsOnly: false)
        let owned = try #require(
          content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let captured = try await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: config)
        try #require(
          NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:])
        )
        .write(to: glass.appendingPathComponent(filename))
        capturedGlass = true
      }
    }
    let batterySegment = try #require(renderer.segments.last)
    let toggle = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: routingReadout.convert(.init(x: batterySegment.frame.midX, y: 12), to: nil),
        modifierFlags: [], timestamp: 2, windowNumber: routingWindow.windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 1))
    cursor = routingWindow.convertPoint(
      toScreen: routingReadout.convert(.init(x: batterySegment.frame.midX, y: 12), to: nil))
    #expect(interaction.handle(toggle) == nil)
    #expect(app.popover?.isShown == false && !interaction.isMonitoring)
    record("battery-toggle")
    app.activateStatusButton(routingButton, event: nil)
    app.popover?.animates = false
    record("reopen-default")
    let outside = NSWindow(
      contentRect: .init(x: 900, y: 100, width: 100, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    outside.isReleasedWhenClosed = false
    defer { outside.close() }
    let outsideClick = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .init(x: 10, y: 10), modifierFlags: [], timestamp: 3,
        windowNumber: outside.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1
      ))
    cursor = outside.convertPoint(toScreen: .init(x: 10, y: 10))
    #expect(interaction.handle(outsideClick) === outsideClick)
    #expect(app.popover?.isShown == false && !interaction.isMonitoring)
    record("outside-dismiss")
  }
  sequence.append(
    capturedGlass
      ? "Captured owned-window glass with existing authorization."
      : "Bitmap layout/ink evidence only; compositor capture unavailable or disabled. No permission requested."
  )
  try (sequence.joined(separator: "\n") + "\n").write(
    to: folder.appendingPathComponent("switch-sequence.txt"), atomically: true, encoding: .utf8)
}
