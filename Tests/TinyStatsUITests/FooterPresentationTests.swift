import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

/// Rasterize the production footer controls, including AppKit's native symbol cell.
@MainActor private func footerBitmap(_ view: NSView, rect: NSRect? = nil, scale: Int = 2) throws
  -> NSBitmapImageRep
{
  let area = rect ?? view.bounds
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(area.width) * scale,
      pixelsHigh: Int(area.height) * scale,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  bitmap.size = area.size
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: area, to: bitmap)
  }
  // Measure the exact PNG pixels delivered for review, with the same colour conversion
  // as the saved baseline, rather than device-RGB antialias values before serialization.
  let png = try #require(bitmap.representation(using: .png, properties: [:]))
  let rendered = try #require(NSBitmapImageRep(data: png))
  rendered.size = area.size
  return rendered
}

/// Ignore sub-10% antialias fringes; report inclusive pixel extents in points.
@MainActor private func footerInkBounds(
  _ bitmap: NSBitmapImageRep, markInside tile: NSRect? = nil
) throws -> NSRect {
  let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
  var minX = bitmap.pixelsWide
  var minY = bitmap.pixelsHigh
  var maxX = -1
  var maxY = -1
  for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
      let color = try #require(bitmap.colorAt(x: x, y: y))
      let point = NSPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)
      let mark =
        color.usingColorSpace(.sRGB).map {
          max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.5
            || min($0.greenComponent, $0.blueComponent) - $0.redComponent > 0.15
        } ?? false
      // For the mark, exclude the paper rim and count neutral letter ink plus mint.
      let visible =
        tile.map { $0.insetBy(dx: 1, dy: 1).contains(point) && mark && color.alphaComponent > 0.5 }
        ?? (color.alphaComponent >= 0.1)
      if visible {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
  }
  try #require(maxX >= minX && maxY >= minY, "The actual footer must contain visible ink")
  return NSRect(
    x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
    width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
}

@Test @MainActor func footerLogoOpticallyMatchesRenderedSymbols() throws {
  _ = NSApplication.shared
  let savedIcon = NSApp.applicationIconImage
  NSApp.applicationIconImage = NSImage(
    contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/TinyStats.icns"))
  defer { NSApp.applicationIconImage = savedIcon }
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.view.setFrameSize(SystemStyle.popoverSize)
  var measurements: [String] = []
  for theme in [AppTheme.light, .dark] {
    detail.view.appearance = theme.nativeAppearance
    var heights: [CGFloat] = []
    var logoHeight: CGFloat = 0
    var markHeight: CGFloat = 0
    var readingsHeight: CGFloat = 0
    for (module, readings, paused) in [
      (Module.cpu, false, false), (.cpu, true, true), (.clock, false, false),
    ] {
      detail.selected = module
      detail.showsAllReadings = readings
      detail.paused = paused
      detail.view.layoutSubtreeIfNeeded()
      let actions = detail.view.subviews.compactMap { $0 as? MenuActionRow }
        .filter { !$0.isHidden }
      for action in actions {
        let bitmap = try footerBitmap(action)
        let ink = try footerInkBounds(bitmap)
        if action.usesBrandIcon {
          logoHeight = ink.height
          let mark = try footerInkBounds(bitmap, markInside: ink)
          markHeight = mark.height
          measurements.append("\(theme.rawValue) logo mark: \(mark.width) × \(mark.height)pt")
        } else {
          heights.append(ink.height)
          if action.title == "All readings" { readingsHeight = ink.height }
        }
        let label = action.usesBrandIcon ? "logo" : action.title
        measurements.append("\(theme.rawValue) \(label): \(ink.width) × \(ink.height)pt")
        if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
          let folder = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: folder.appendingPathComponent("footer-ink-\(label)-\(theme.rawValue).png"))
        }
      }
    }
    let tallest = try #require(heights.max())
    measurements.append("\(theme.rawValue) logo vs tallest: \(logoHeight) / \(tallest)pt")
    measurements.append(
      "\(theme.rawValue) mark vs All readings: \(markHeight) / \(readingsHeight)pt")
    // Raster extents are host/OS-specific. Leave headroom for AppKit antialias changes;
    // the stable square glyph is the letter's reference, independent of other actions.
    // The old 8 × 7.5pt mark still fails against the 12.5pt square by 5pt on this host.
    #expect(abs(logoHeight - tallest) <= 1.5)
    #expect(abs(markHeight - readingsHeight) <= 1.5, "The letter must also match the square glyph")
  }
  print(measurements.joined(separator: "\n"))
  if let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
    try (measurements.joined(separator: "\n") + "\n").write(
      to: URL(fileURLWithPath: path).appendingPathComponent("footer-ink-measurements.txt"),
      atomically: true, encoding: .utf8)
  }
}

@MainActor private func footerDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + footerDescendants($0) }
}

@Test @MainActor func dropdownActionTooltipsMatchAccessibilityAcrossModulesAndStates() throws {
  _ = NSApplication.shared
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.view.setFrameSize(SystemStyle.popoverSize)
  // Reuse one controller: both directions must replace stale module/state descriptions.
  for module in Module.allCases + Module.allCases.reversed() {
    detail.selected = module
    for allReadings in [false, true] {
      detail.showsAllReadings = allReadings
      for paused in [false, true, false] {
        detail.paused = paused
        detail.update(Snapshot(), history: [])
        detail.view.layoutSubtreeIfNeeded()
        let actions = detail.view.subviews.compactMap { $0 as? MenuActionRow }
          .filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
        let hasHistory = [.overview, .cpu, .gpu, .memory, .disks, .network, .battery].contains(
          module)
        let readingsLabel =
          module == .clock
          ? "Calendar settings"
          : allReadings
            ? "Show summary"
            : module == .sensors ? "Show all readings and SMC keys" : "Show all readings"
        let expected =
          ["Open \(module.title) in TinyStats"] + (hasHistory ? ["History…"] : [])
          + (module == .overview ? [] : [readingsLabel]) + [paused ? "Resume" : "Pause"]
        #expect(actions.map { $0.accessibilityLabel() ?? "" } == expected)
        for button in footerDescendants(detail.view).compactMap({ $0 as? NSButton })
        where !button.isHiddenOrHasHiddenAncestor
          && !(button.superview is MonthCalendarView && Int(button.title) != nil)
        {
          let label = try #require(button.accessibilityLabel())
          let tip = try #require(button.toolTip, "\(module.title): \(button.title) needs a tooltip")
          #expect(!label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          #expect(tip.components(separatedBy: "\n").first == label)
        }
        let pause = try #require(actions.last)
        let help = try #require(pause.accessibilityHelp())
        #expect(!help.isEmpty)
        #expect(pause.toolTip == (paused ? "Resume" : "Pause") + "\n" + help)
      }
    }
  }
  // Day cells retain full-date VoiceOver labels without hover tooltips, including
  // after recycling the grid for another month. Navigation remains covered above.
  detail.selected = .clock
  let calendar = try #require(
    footerDescendants(detail.view).compactMap { $0 as? MonthCalendarView }.first)
  func visibleDays() -> [NSButton] {
    calendar.subviews.compactMap { $0 as? NSButton }.filter {
      !$0.isHidden && Int($0.title) != nil
    }
  }
  let before = visibleDays().map { $0.accessibilityLabel() }
  for monthOffset in [0, 1] {
    calendar.moveMonth(by: monthOffset)
    let days = visibleDays()
    #expect(!days.isEmpty)
    for day in days {
      #expect(day.toolTip == nil)
      #expect((day.accessibilityLabel()?.count ?? 0) > day.title.count)
    }
  }
  #expect(before != visibleDays().map { $0.accessibilityLabel() })

  detail.selected = .weather
  let city = try #require(
    footerDescendants(detail.view).compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "Weather city"
    })
  for status in ["", "Saved Weather cities unavailable", ""] {
    detail.weatherCitiesStatus = status
    #expect(city.toolTip == "Weather city" + (status.isEmpty ? "" : "\n" + status))
  }
}

@Test @MainActor func footerLogoStaysPixelAlignedAtOneAndTwoTimesScale() throws {
  _ = NSApplication.shared
  let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
  let saved = NSApp.applicationIconImage
  defer { NSApp.applicationIconImage = saved }
  // Exercise automatic ICNS selection and the 32px small master explicitly at 1x.
  for source in ["TinyStats.icns", "AppIcon.iconset/icon_16x16@2x.png"] {
    let icon = try #require(NSImage(contentsOf: resources.appendingPathComponent(source)))
    NSApp.applicationIconImage = icon
    let detail = DetailController()
    detail.isPopoverPresentation = true
    detail.view.setFrameSize(SystemStyle.popoverSize)
    let brand = try #require(
      detail.view.subviews.compactMap { $0 as? MenuActionRow }.first { $0.usesBrandIcon })
    if source.hasSuffix(".png") {
      // NSApplication normalizes its icon to the host's backing scale; override the
      // fixture image directly so the 32px representation really reaches draw(_:).
      let small = try #require(icon.copy() as? NSImage)
      small.size = .init(width: 16, height: 16)
      brand.image = small
      #expect(small.representations.map(\.pixelsWide) == [32])
    }
    for theme in [AppTheme.light, .dark] {
      detail.view.appearance = theme.nativeAppearance
      detail.view.layoutSubtreeIfNeeded()
      for scale in source.hasSuffix(".icns") ? [1, 2] : [1] {
        let bitmap = try footerBitmap(brand, scale: scale)
        let ink = try footerInkBounds(bitmap)
        #expect(ink.size == NSSize(width: 15, height: 15))
        #expect(abs(ink.midX - brand.bounds.midX) <= 0.5)
        #expect(abs(ink.midY - brand.bounds.midY) <= 0.5)
        let mark = try footerInkBounds(bitmap, markInside: ink)
        #expect(
          mark.width >= 10 && mark.height >= 10, "The 32px crop must retain the enlarged mark")
        #expect(
          mark.width < ink.width - 2 && mark.height < ink.height - 2,
          "The complete mark must leave paper beyond the rim instead of filling the crop")
        print("FOOTER \(source) \(theme.rawValue) \(scale)x: tile=\(ink), mark=\(mark)")
        if scale == 1,
          let path = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"]
        {
          let folder = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let name = source.hasSuffix(".icns") ? "footer-ink-logo-1x" : "footer-logo-32px-1x"
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: folder.appendingPathComponent("\(name)-\(theme.rawValue).png"))
        }
      }
    }
  }
}
