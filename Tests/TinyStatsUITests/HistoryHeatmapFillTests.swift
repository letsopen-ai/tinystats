import AppKit
import Testing

@testable import TinyStats

@MainActor private func heatmapPixels(
  _ color: NSColor, optimized: Bool, appearance: NSAppearance.Name, scale: Int,
  inheritedOpacity: CGFloat
) throws -> Data {
  let image = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 320 * scale, pixelsHigh: 48 * scale,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  let bytes = try #require(image.bitmapData)
  bytes.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
  let context = try #require(NSGraphicsContext(bitmapImageRep: image))
  try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    NSColor.windowBackgroundColor.setFill()
    NSRect(x: 0, y: 0, width: 320, height: 48).fill()
    context.cgContext.setAlpha(inheritedOpacity)
    var fill = HistoryHeatmapFill(color)
    for index in 0..<101 {
      let rect = NSRect(x: index * 3, y: 12, width: 2, height: 14)
      // Independent legacy AppKit primitive is the pixel oracle, including intrinsic-alpha override.
      let opacity = 0.12 + 0.88 * Double(index) / 100
      if optimized {
        fill.fill(rect, opacity: opacity)
      } else {
        color.withAlphaComponent(opacity).setFill()
        rect.fill()
      }
      if index % 7 == 0 {
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: rect.minX, y: 12, width: 2, height: 2).fill()
      }
      if index % 11 == 0 {
        NSColor.systemOrange.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.5))
        path.lineWidth = 0.5
        path.stroke()
      }
      if index % 13 == 0 {
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: rect.maxX, y: 12, width: 1, height: 14).fill()
      }
    }
    // Following opaque content must retain the caller's inherited opacity and blend behavior.
    NSColor.systemGreen.setFill()
    NSRect(x: 308, y: 0, width: 12, height: 48).fill()
  }
  return Data(bytes: bytes, count: image.bytesPerRow * image.pixelsHigh)
}

@Test @MainActor func heatmapFillPreservesLegacyPixelsAppearanceSpacesAndInheritedOpacity() throws {
  _ = NSApplication.shared
  let colors: [NSColor] = [
    .systemPink, .systemBlue, .systemTeal, .clear,
    NSColor(deviceWhite: 0.42, alpha: 0.7),
    NSColor(displayP3Red: 0.3, green: 0.6, blue: 0.8, alpha: 0.45),
  ]
  for appearance: NSAppearance.Name in [
    .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
  ] {
    for color in colors {
      for scale in [1, 2] {
        for inheritedOpacity: CGFloat in [0.35, 1] {
          let baseline = try heatmapPixels(
            color, optimized: false, appearance: appearance, scale: scale,
            inheritedOpacity: inheritedOpacity)
          let candidate = try heatmapPixels(
            color, optimized: true, appearance: appearance, scale: scale,
            inheritedOpacity: inheritedOpacity)
          #expect(candidate == baseline)
        }
      }
    }
  }
}

@Test @MainActor func heatmapFillRetainsLegacyPatternFallback() throws {
  _ = NSApplication.shared
  let pattern = NSImage(size: .init(width: 4, height: 4))
  pattern.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 4, height: 4).fill()
  NSColor.black.setFill()
  NSRect(x: 0, y: 0, width: 2, height: 2).fill()
  pattern.unlockFocus()
  let color = NSColor(patternImage: pattern)
  for scale in [1, 2] {
    let baseline = try heatmapPixels(
      color, optimized: false, appearance: .darkAqua, scale: scale, inheritedOpacity: 0.4)
    let candidate = try heatmapPixels(
      color, optimized: true, appearance: .darkAqua, scale: scale, inheritedOpacity: 0.4)
    #expect(candidate == baseline)
  }
}
