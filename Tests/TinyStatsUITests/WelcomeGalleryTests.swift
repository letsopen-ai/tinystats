import AppKit
import ScreenCaptureKit
import Testing
import TinyStatsCore

@testable import TinyStats

@MainActor private final class WelcomeGalleryBackdrop: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSGradient(colors: [.systemPink, .systemPurple, .systemBlue, .systemTeal, .systemOrange])?
      .draw(in: bounds, angle: 25)
  }
}

/// Captures only our owned synthetic window; never asks for access or touches the real menu bar.
/// Offscreen layout/ink PNGs remain at the root; compositor evidence lives in glass/.
@Test @MainActor func welcomeOwnedGlassGallery() async throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"],
    ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_GLASS_CAPTURE"] == "1"
  else { return }
  let folder = URL(fileURLWithPath: path).appendingPathComponent("glass", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  guard #available(macOS 26, *), CGPreflightScreenCaptureAccess() else {
    try
      "Compositor capture unavailable; no permission requested. Root PNGs prove layout/ink only.\n"
      .write(
        to: folder.appendingPathComponent("welcome-capture.txt"), atomically: true, encoding: .utf8)
    return
  }
  _ = NSApplication.shared
  let previousIcon = NSApp.applicationIconImage
  NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/TinyStats.icns")
  defer { NSApp.applicationIconImage = previousIcon }
  let policy = NSApp.activationPolicy()
  _ = NSApp.setActivationPolicy(.accessory)
  NSApp.finishLaunching()
  NSApp.activate(ignoringOtherApps: true)
  defer { _ = NSApp.setActivationPolicy(policy) }
  let screen = try #require(NSScreen.main)
  let gallery = NSWindow(
    contentRect: .init(
      x: screen.visibleFrame.minX + 30,
      y: screen.visibleFrame.minY + 30, width: 800, height: 710),
    styleMask: [.borderless], backing: .buffered, defer: false)
  gallery.isReleasedWhenClosed = false
  gallery.level = .floating
  gallery.collectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .canJoinAllApplications,
  ]
  let backdrop = WelcomeGalleryBackdrop(frame: .init(x: 0, y: 0, width: 800, height: 710))
  gallery.contentView = backdrop
  defer {
    gallery.orderOut(nil)
    gallery.close()
  }
  let slugs = ["greet", "menubar", "history", "online", "ready"]
  for theme in [AppTheme.light, .dark] {
    for step in 0..<5 {
      var settings = Settings()
      settings.theme = theme
      NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/TinyStats.icns")
      let controller = WelcomeController(settings: { settings }, initialStep: step)
      defer { controller.close() }
      let root = try #require(controller.window?.contentView)
      controller.window?.contentView = nil
      root.frame = .init(x: 40, y: 40, width: 720, height: 630)
      root.appearance = theme.nativeAppearance
      backdrop.addSubview(root)
      defer { root.removeFromSuperview() }
      root.layoutSubtreeIfNeeded()
      if NSApp.activationPolicy() == .prohibited { _ = NSApp.setActivationPolicy(.accessory) }
      gallery.orderFrontRegardless()
      gallery.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: false)
      let owned = try #require(
        content.windows.first { $0.windowID == CGWindowID(gallery.windowNumber) })
      let config = SCStreamConfiguration()
      config.width = Int(gallery.frame.width * gallery.backingScaleFactor)
      config.height = Int(gallery.frame.height * gallery.backingScaleFactor)
      config.scalesToFit = true
      config.showsCursor = false
      config.ignoreShadowsSingleWindow = true
      let captured = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: config)
      let scale = CGFloat(captured.width) / 800
      let cropped = try #require(
        captured.cropping(
          to: .init(
            x: 40 * scale, y: 40 * scale,
            width: 720 * scale, height: 630 * scale)))
      try #require(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
        .write(
          to: folder.appendingPathComponent(
            "welcome-step-\(step + 1)-\(slugs[step])-\(theme.rawValue).png"))
    }
  }
  try
    "Captured five light/dark welcome steps over an owned gradient; all readouts are bounded illustrative examples.\n"
    .write(
      to: folder.appendingPathComponent("welcome-capture.txt"), atomically: true, encoding: .utf8)
}

/// Key-window evidence uses the actual welcome window, never the system menu bar.
@Test @MainActor func welcomeOwnedKeyWindowCapture() async throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"],
    ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_GLASS_CAPTURE"] == "1",
    #available(macOS 26, *), CGPreflightScreenCaptureAccess()
  else { return }
  _ = NSApplication.shared
  let policy = NSApp.activationPolicy()
  let previousIcon = NSApp.applicationIconImage
  _ = NSApp.setActivationPolicy(.accessory)
  NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/TinyStats.icns")
  NSApp.finishLaunching()
  defer {
    NSApp.applicationIconImage = previousIcon
    _ = NSApp.setActivationPolicy(policy)
  }
  var settings = Settings()
  settings.theme = .light
  let controller = WelcomeController(settings: { settings })
  defer { controller.close() }
  NSApp.activate(ignoringOtherApps: true)
  controller.showWindow(nil)
  let window = try #require(controller.window)
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  window.displayIfNeeded()
  try await Task.sleep(for: .milliseconds(200))
  // XCTest can restore the runner's prohibited policy while finishing launch.
  if NSApp.activationPolicy() == .prohibited { _ = NSApp.setActivationPolicy(.accessory) }
  NSApp.activate(ignoringOtherApps: true)
  window.makeKeyAndOrderFront(nil)
  window.makeKey()
  window.displayIfNeeded()
  try await Task.sleep(for: .milliseconds(150))
  #expect(window.defaultButtonCell?.keyEquivalent == "\r")
  let folder = URL(fileURLWithPath: path).appendingPathComponent("glass", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  guard NSApp.isActive else {
    try
      "Live key-window capture unavailable: macOS kept the SwiftPM runner inactive after activation. No accent/key-window claim is made.\n"
      .write(
        to: folder.appendingPathComponent("welcome-key-capture.txt"), atomically: true,
        encoding: .utf8)
    return
  }
  #expect(window.isKeyWindow)
  let content = try await SCShareableContent.excludingDesktopWindows(
    true, onScreenWindowsOnly: false)
  let owned = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
  let config = SCStreamConfiguration()
  config.width = Int(window.frame.width * window.backingScaleFactor)
  config.height = Int(window.frame.height * window.backingScaleFactor)
  config.scalesToFit = true
  config.showsCursor = false
  config.ignoreShadowsSingleWindow = true
  let captured = try await SCScreenshotManager.captureImage(
    contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: config)
  try #require(NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:]))
    .write(to: folder.appendingPathComponent("welcome-key-window-light.png"))
}
