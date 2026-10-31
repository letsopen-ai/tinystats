import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func brandBitmap(_ view: NSView, rect: NSRect? = nil) throws -> NSBitmapImageRep
{
  let area = rect ?? view.bounds
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(area.width * 2), pixelsHigh: Int(area.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  bitmap.size = area.size
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: area, to: bitmap)
  }
  return bitmap
}

/// Bitmap rows run top to bottom. The real master's asymmetric mint full stop is below centre.
@MainActor private func mintY(_ bitmap: NSBitmapImageRep) throws -> Double {
  var weight = 0.0
  var moment = 0.0
  for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
      let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      let mint =
        max(0, Double(min(color.greenComponent, color.blueComponent) - color.redComponent) - 0.08)
        * Double(color.alphaComponent)
      weight += mint
      moment += mint * (Double(y) + 0.5) / Double(bitmap.pixelsHigh)
    }
  }
  #expect(weight > 0.5, "The source and rendered logo must retain the mint full stop")
  return moment / max(weight, 0.001)
}

@MainActor private func brandDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + brandDescendants($0) }
}

/// Compare asymmetric chip symbols with AppKit's upright native image view.
@Test @MainActor func menuBarChipSymbolsMatchNativeUprightOrientation() throws {
  _ = NSApplication.shared
  for theme in [AppTheme.light, .dark] {
    for name in ["thermometer.medium", "bolt.fill", "clock"] {
      let chip = MenuBarChip(module: .sensors)
      chip.frame = .init(x: 0, y: 0, width: 90, height: 28)
      chip.appearance = theme.nativeAppearance
      #expect(chip.isFlipped)
      chip.image = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil))
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
      let native = NSImageView(frame: .init(x: 0, y: 0, width: 13, height: 13))
      native.appearance = theme.nativeAppearance
      native.image = chip.image
      native.imageScaling = .scaleAxesIndependently
      native.contentTintColor = SystemStyle.moduleAccent(.sensors)
      let actual = try brandBitmap(
        chip, rect: .init(x: 10, y: chip.bounds.midY - 6.5, width: 13, height: 13))
      let reference = try brandBitmap(native)
      func centroid(_ bitmap: NSBitmapImageRep) throws -> Double {
        var weight = 0.0
        var moment = 0.0
        for y in 0..<bitmap.pixelsHigh {
          for x in 0..<bitmap.pixelsWide {
            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            // Neutral button backing contributes no chroma; alpha excludes transparent pixels.
            let chroma =
              Double(max(0, color.redComponent - color.blueComponent))
              * Double(color.alphaComponent)
            weight += chroma
            moment += chroma * (Double(y) + 0.5) / Double(bitmap.pixelsHigh)
          }
        }
        #expect(weight > 0.5)
        return moment / max(weight, 0.001)
      }
      let uprightY = try centroid(reference)
      let actualY = try centroid(actual)
      #expect(abs(uprightY - 0.5) > 0.005, "The reference must distinguish vertical orientation")
      print("CHIP \(name) \(theme.rawValue): actual=\(actualY), native upright=\(uprightY)")
      #expect(abs(actualY - uprightY) < 0.04)
      #expect(abs(actualY - uprightY) < abs(actualY - (1 - uprightY)))
      if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (label, bitmap) in [("actual", actual), ("native-upright", reference)] {
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: folder.appendingPathComponent(
              "chip-\(name)-\(label)-\(theme.rawValue).png"))
        }
      }
    }
  }
}

@Test @MainActor func brandViewsMatchUprightSourceOrientation() throws {
  _ = NSApplication.shared
  let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
  let sourceData = try Data(
    contentsOf: resources.appendingPathComponent("AppIcon.iconset/icon_16x16@2x.png"))
  let source = try #require(NSBitmapImageRep(data: sourceData))
  let reference = try mintY(source)
  #expect(reference > 0.6)
  let saved = NSApp.applicationIconImage
  let appIcon = NSImage(contentsOf: resources.appendingPathComponent("TinyStats.icns"))
  NSApp.applicationIconImage = appIcon
  defer { NSApp.applicationIconImage = saved }
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.loadViewIfNeeded()
  detail.view.setFrameSize(SystemStyle.popoverSize)
  detail.view.layoutSubtreeIfNeeded()
  let footer = try #require(
    brandDescendants(detail.view).compactMap { $0 as? MenuActionRow }.first { $0.usesBrandIcon })
  #expect(footer.isFlipped)
  let welcome = WelcomeController(settings: { Settings() })
  defer { welcome.close() }
  let welcomeRoot = try #require(welcome.window?.contentView)
  let icon = try #require(
    brandDescendants(welcomeRoot).compactMap { $0 as? NSImageView }.first {
      $0.accessibilityLabel() == "TinyStats"
    })
  // Render the production Overview dashboard, including its custom icon draw.
  let overview = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 554))
  overview.update(Snapshot(), history: [], settings: Settings(), module: .overview)
  for theme in [AppTheme.light, .dark] {
    for (name, view, area) in [
      (
        "footer", footer as NSView,
        NSRect(x: footer.bounds.midX - 8, y: footer.bounds.midY - 8, width: 16, height: 16)
      ),
      ("welcome", icon as NSView, icon.bounds),
      ("overview", overview as NSView, NSRect(x: 14, y: 12, width: 40, height: 40)),
    ] {
      view.appearance = theme.nativeAppearance
      view.layoutSubtreeIfNeeded()
      let bitmap = try brandBitmap(view, rect: area)
      let actual = try mintY(bitmap)
      #expect(
        abs(actual - reference) < 0.14,
        "\(name) \(theme.rawValue): mint y=\(actual), upright source y=\(reference)")
      if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent("brand-\(name)-\(theme.rawValue).png"))
        if name == "footer" {
          // Four times the captured pixels; nearest-neighbour keeps the real rendered edges visible.
          let zoom = try #require(
            NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide * 4,
              pixelsHigh: bitmap.pixelsHigh * 4, bitsPerSample: 8, samplesPerPixel: 4,
              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
              bitsPerPixel: 0))
          for y in 0..<zoom.pixelsHigh {
            for x in 0..<zoom.pixelsWide {
              zoom.setColor(try #require(bitmap.colorAt(x: x / 4, y: y / 4)), atX: x, y: y)
            }
          }
          try #require(zoom.representation(using: .png, properties: [:])).write(
            to: folder.appendingPathComponent("footer-logo-zoom-\(theme.rawValue).png"))
        }
      }
    }
  }
}

/// At the standard window size the entire CPU form must fit without scrolling.
/// 74pt includes preview, title, help, control and row insets (Round B used 150pt).
@Test @MainActor func menuBarLayoutSectionAndWholeCPUPageFitHeightBudget() throws {
  _ = NSApplication.shared
  for embedded in [true, false] {
    for separate in [true, false] {
      for theme in [AppTheme.light, .dark] {
        var settings = Settings()
        settings.separateItems = separate
        settings.theme = theme
        let editor = PreferencesController(
          settings: settings, interfaces: [], snapshot: Snapshot(), history: [],
          initialPage: .menuBar)
        defer {
          editor.disposeEmbedded()
          editor.close()
        }
        let detail = DetailController()
        detail.isPopoverPresentation = false
        detail.view.setFrameSize(MainWindow.minimumSize)
        let root: NSView
        if embedded {
          detail.showSettingsView(try #require(editor.embeddedView(page: .menuBar)), page: .menuBar)
          root = detail.view
        } else {
          root = try #require(editor.window?.contentView)
        }
        root.appearance = theme.nativeAppearance
        root.layoutSubtreeIfNeeded()
        let views = brandDescendants(root)
        let control = try #require(
          views.compactMap { $0 as? NSSegmentedControl }.first {
            $0.accessibilityLabel() == "Menu bar layout"
          })
        let section = try #require(
          views.first { $0.identifier?.rawValue == "menu-bar-layout-section" })
        let title = try #require(control.accessibilityTitleUIElement() as? NSTextField)
        #expect(title.stringValue == "Layout")
        let peer = try #require(
          views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "In menu bar" })
        #expect(title.font == peer.font && title.textColor == peer.textColor)
        let preview = try #require(views.compactMap { $0 as? MenuBarPreviewView }.first)
        #expect(preview.renderers.allSatisfy { !$0.isFlipped })
        let form = try #require(section.enclosingScrollView)
        let document = try #require(form.documentView)
        #expect(section.frame.height <= PreferencesController.menuBarLayoutSectionHeightBudget)
        #expect(control.frame.height <= PreferencesController.menuBarToolsHeightBudget)
        #expect(control.acceptsFirstResponder)
        let host = NSWindow(
          contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        if embedded { host.contentView = root }
        defer {
          host.contentView = nil
          host.close()
        }
        let window = try #require(control.window)
        #expect(window.makeFirstResponder(control))
        #expect(window.firstResponder === control)
        let scroll = try #require(preview.enclosingScrollView)
        let wallpaper = try #require(scroll.superview)
        let previewRect = wallpaper.convert(wallpaper.bounds, to: section)
        let controlRect = control.convert(control.bounds, to: section)
        #expect(previewRect.maxX < controlRect.minX)
        #expect(controlRect.midY >= previewRect.minY && controlRect.midY <= previewRect.maxY)
        #expect(document.bounds.height <= form.contentView.bounds.height)
        #expect(form.contentView.bounds.minY == 0)
        for view in views
        where !view.isHiddenOrHasHiddenAncestor
          && (view is MenuBarStylePicker || view is MenuBarCustomization || view === section)
        {
          #expect(view.visibleRect.height >= view.bounds.height - 0.5)
        }
        let metrics =
          "ROUND-C \(embedded ? "embedded" : "standalone") \(separate ? "separate" : "one") \(theme.rawValue): layout section=\(section.frame.height)pt document=\(document.bounds.height)pt viewport=\(form.contentView.bounds.height)pt\n"
        print(metrics)
        if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
          try metrics.write(
            to: URL(fileURLWithPath: path).appendingPathComponent(
              "layout-height-\(embedded ? "embedded" : "standalone")-\(separate ? "separate" : "one")-\(theme.rawValue).txt"
            ), atomically: true, encoding: .utf8)
        }
      }
    }
  }
}
