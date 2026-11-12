import AppKit
import ScreenCaptureKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func updatePNG(_ view: NSView, to url: URL) async throws -> String {
  var host: NSWindow?
  if view.window == nil {
    let window = NSWindow(
      contentRect: .init(origin: .zero, size: view.bounds.size),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    host = window
  }
  defer {
    host?.contentView = nil
    host?.close()
  }
  let window = view.window
  let hasDisplay = !NSScreen.screens.isEmpty
  if hasDisplay, let window {
    if NSApp.activationPolicy() == .prohibited { _ = NSApp.setActivationPolicy(.accessory) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeMain()
    try await Task.sleep(for: .milliseconds(200))
    window.displayIfNeeded()
  }
  view.layoutSubtreeIfNeeded()
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: view.bounds, to: bitmap)
  }
  try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
  return hasDisplay
    ? "key=\(window?.isKeyWindow == true), main=\(window?.isMainWindow == true), active=\(NSApp.isActive)"
    : "No display available: NSScreen.screens is empty; native key/active capture unavailable."
}

/// An owned AppKit menu illustration driven by the actual production NSMenu. Native
/// tracking would capture a separate menu window; this keeps evidence off the status bar.
@MainActor private func updateMenuMirror(_ menu: NSMenu) -> NSView {
  let root = NSVisualEffectView(frame: .init(x: 0, y: 0, width: 330, height: 210))
  root.material = .menu
  root.state = .active
  root.wantsLayer = true
  root.layer?.cornerRadius = 8
  var y: CGFloat = 186
  for item in menu.items where !item.isHidden {
    if item.isSeparatorItem {
      let line = NSBox(frame: .init(x: 10, y: y + 9, width: 310, height: 1))
      line.boxType = .separator
      root.addSubview(line)
      y -= 12
    } else {
      let label = NSTextField(labelWithString: item.title)
      label.font = .menuFont(ofSize: 14)
      label.frame = .init(x: 18, y: y, width: 290, height: 21)
      root.addSubview(label)
      y -= 30
    }
  }
  return root
}

/// Offscreen NSAlert windows render empty in this restricted host. Mirror its actual
/// strings, icon and button labels using ordinary native AppKit views instead.
@MainActor private func updateAlertMirror(_ alert: NSAlert) -> NSView {
  let root = SystemSettingsBackgroundView(frame: .init(x: 0, y: 0, width: 360, height: 344))
  let icon = NSImageView(frame: .init(x: 148, y: 256, width: 64, height: 64))
  icon.image = alert.icon
  root.addSubview(icon)
  let title = NSTextField(wrappingLabelWithString: alert.messageText)
  title.font = .systemFont(ofSize: 15, weight: .bold)
  title.alignment = .center
  title.frame = .init(x: 24, y: 215, width: 312, height: 35)
  root.addSubview(title)
  let message = NSTextField(wrappingLabelWithString: alert.informativeText)
  message.font = .systemFont(ofSize: 13)
  message.alignment = .center
  message.frame = .init(x: 24, y: 174, width: 312, height: 34)
  root.addSubview(message)
  for (index, original) in alert.buttons.enumerated() {
    let button = NSButton(title: original.title, target: nil, action: nil)
    button.bezelStyle = .rounded
    button.frame = .init(x: 24, y: 122 - CGFloat(index) * 40, width: 312, height: 32)
    button.keyEquivalent = original.keyEquivalent
    if index == 0 { button.keyEquivalent = "\r" }
    root.addSubview(button)
  }
  return root
}

@Test @MainActor func updateOwnedWindowGallery() async throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_UPDATE_RENDER_PATH"] else {
    return
  }
  _ = NSApplication.shared
  let savedPolicy = NSApp.activationPolicy()
  if !NSScreen.screens.isEmpty {
    _ = NSApp.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
  }
  defer { if !NSScreen.screens.isEmpty { _ = NSApp.setActivationPolicy(savedPolicy) } }
  let folder = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let savedIcon = NSApp.applicationIconImage
  NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/TinyStats.icns")
  defer { NSApp.applicationIconImage = savedIcon }
  var descriptions: [String] = []
  for theme in [AppTheme.light, .dark] {
    var settings = Settings()
    settings.theme = theme
    let detail = DetailController()
    detail.settings = settings
    let window = MainWindow()
    window.isReleasedWhenClosed = false
    window.appearance = theme.nativeAppearance
    window.contentViewController = detail
    let preferences = PreferencesController(
      settings: settings, interfaces: [], snapshot: Snapshot(), history: [])
    defer {
      preferences.disposeEmbedded()
      preferences.close()
      window.close()
    }
    let page = try #require(preferences.embeddedView(page: .general))
    detail.showSettingsView(page, page: .general)
    // Explicit no-op callbacks: there is no controller, transport or installer here.
    preferences.updatesView.onCheck = {}
    preferences.updatesView.onRestart = {}
    var state = UpdatePresentation(version: "0.37.5", build: "77", eligible: true, canInstall: true)
    state.preferences.lastCheck = Date().addingTimeInterval(-7200)
    for ready in [false, true] {
      state.readyVersion = ready ? "0.37.6" : nil
      state.readyBuild = ready ? "78" : nil
      preferences.updatesView.update(state)
      window.contentView?.layoutSubtreeIfNeeded()
      let stem = "updates-general-\(ready ? "ready" : "idle")-\(theme.rawValue)"
      #expect(preferences.updatesView.check.isEnabled && preferences.updatesView.check.state == .on)
      let activity = try await updatePNG(
        try #require(window.contentView), to: folder.appendingPathComponent(stem + ".png"))
      descriptions.append("\(stem): \(activity); update switches enabled.")
      descriptions.append(
        "\(stem).png — Native General settings with \(ready ? "0.37.6 (78) prepared" : "daily checks enabled and last-check status")."
      )
    }
    let alert = NativeUpdateUserInterface.makeAlert(
      title: "TinyStats 0.37.6 (78) is available",
      message: "Download it now? TinyStats restarts to finish installing.",
      buttons: ["Download & Restart", "Later", "Release Notes"])
    let alertWindow = alert.window
    alertWindow.appearance = theme.nativeAppearance
    alert.layout()
    let alertStem = "updates-available-alert-\(theme.rawValue)"
    let alertMirror = updateAlertMirror(alert)
    alertMirror.appearance = theme.nativeAppearance
    let alertActivity = try await updatePNG(
      alertMirror, to: folder.appendingPathComponent(alertStem + ".png"))
    descriptions.append("\(alertStem): \(alertActivity)")
    descriptions.append(
      "\(alertStem).png — Owned alert-content mirror from the production NSAlert, never submitted; native window presentation is unavailable in this sandbox."
    )
    let app = AppDelegate()
    let mirror = updateMenuMirror(app.makeApplicationMenu())
    mirror.appearance = theme.nativeAppearance
    let menuStem = "updates-app-menu-\(theme.rawValue)"
    let menuActivity = try await updatePNG(
      mirror, to: folder.appendingPathComponent(menuStem + ".png"))
    descriptions.append("\(menuStem): \(menuActivity)")
    descriptions.append(
      "\(menuStem).png — Owned menu mirror sourced from the production application menu, including Check for Updates… after About."
    )
    let dropdown = DetailController()
    dropdown.settings = settings
    dropdown.isPopoverPresentation = true
    dropdown.selected = .cpu
    dropdown.onRestartUpdate = {}
    dropdown.updateReady = "0.37.6 (78)"
    dropdown.view.appearance = theme.nativeAppearance
    dropdown.view.setFrameSize(SystemStyle.popoverSize)
    let footerStem = "updates-dropdown-ready-\(theme.rawValue)"
    let footerActivity = try await updatePNG(
      dropdown.view, to: folder.appendingPathComponent(footerStem + ".png"))
    descriptions.append("\(footerStem): \(footerActivity)")
    descriptions.append(
      "\(footerStem).png — Owned CPU dropdown with the temporary prepared-update footer icon and no-op action."
    )
    alertWindow.close()
    let welcome = WelcomeController(settings: { settings }, initialStep: 3, updates: { state })
    defer { welcome.close() }
    welcome.window?.appearance = theme.nativeAppearance
    let welcomeStem = "welcome-online-\(theme.rawValue)"
    let welcomeActivity = try await updatePNG(
      try #require(welcome.window?.contentView),
      to: folder.appendingPathComponent(welcomeStem + ".png"))
    descriptions.append(
      "\(welcomeStem).png — Production Welcome Online step with default-on Updates/GitHub and opt-in Weather/Internet. \(welcomeActivity)"
    )
  }
  try
    (descriptions.joined(separator: "\n")
    + "\nBitmap layout/ink evidence. No live data, network, installation, permission requests or real menu-bar interaction.\n")
    .write(
      to: folder.appendingPathComponent("updates-capture.txt"), atomically: true, encoding: .utf8)
}
