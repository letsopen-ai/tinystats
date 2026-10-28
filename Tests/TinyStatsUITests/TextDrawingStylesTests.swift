import AppKit
import CryptoKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func drawingStylesPreserveFontColorAlignmentAndImmutableParagraphs() throws {
  let styles = TextDrawingStyles()
  for alignment in [NSTextAlignment.left, .center, .right] {
    let color = NSColor.systemPink
    var first = styles.attributes(color: color, size: 17, weight: .semibold, alignment: alignment)
    let font = try #require(first[.font] as? NSFont)
    let paragraph = try #require(first[.paragraphStyle] as? NSParagraphStyle)
    #expect(font == NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold))
    #expect(first[.foregroundColor] as? NSColor == color)
    #expect(paragraph.alignment == alignment && paragraph.lineBreakMode == .byTruncatingTail)
    #expect(!(paragraph is NSMutableParagraphStyle))
    first[.foregroundColor] = NSColor.systemGreen
    let again = styles.attributes(color: color, size: 17, weight: .semibold, alignment: alignment)
    #expect(again[.foregroundColor] as? NSColor == color)
    #expect(again[.paragraphStyle] as? NSParagraphStyle === paragraph)
  }
  #expect(styles.count == 3)
}

@Test @MainActor func drawingStylesRemainBoundedAndOverflowStillUsesRequestedStyle() throws {
  let styles = TextDrawingStyles()
  for index in 0..<TextDrawingStyles.capacity + 10 {
    let size = CGFloat(9 + index)
    let attributes = styles.attributes(
      color: .labelColor, size: size, weight: .bold, alignment: .right)
    #expect((attributes[.font] as? NSFont)?.pointSize == size)
    #expect((attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment == .right)
    #expect(styles.count <= TextDrawingStyles.capacity)
  }
  #expect(styles.count == TextDrawingStyles.capacity)
  styles.reset()
  #expect(styles.count == 0)
  let next = styles.attributes(color: .systemBlue, size: 11, weight: .regular, alignment: .left)
  #expect(next[.foregroundColor] as? NSColor == .systemBlue)
  #expect(styles.count == 1)
}

@Test @MainActor func drawingStyleStorageReleasesWhenItsOwnerDropsIt() {
  weak var released: TextDrawingStyles?
  autoreleasepool {
    let styles = TextDrawingStyles()
    released = styles
    _ = styles.attributes(color: .labelColor, size: 12, weight: .regular, alignment: .left)
    #expect(released != nil)
  }
  #expect(released == nil)
}

@MainActor private func styledSummaryPixels(_ view: SummaryDashboardView, scale: Int) throws -> Data
{
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
      pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  let bytes = try #require(bitmap.bitmapData)
  let length = bitmap.bytesPerRow * bitmap.pixelsHigh
  bytes.initialize(repeating: 0, count: length)
  let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    view.displayIgnoringOpacity(view.bounds, in: context)
    NSGraphicsContext.restoreGraphicsState()
  }
  return Data(bytes: bytes, count: length)
}

@Test @MainActor func reusedDrawingStylesMatchFreshViewsAcrossContentAppearanceAndSizeChanges()
  throws
{
  _ = NSApplication.shared
  var populated = Snapshot()
  populated.timestamp = Date(timeIntervalSince1970: 1_792_670_400)
  populated.cpu = .init(
    usage: 51, cores: [75, nil, 28], load: [1.2, 2.3, 3.4],
    coreKinds: [.efficiency, .efficiency, .performance], user: 35, system: 16)
  populated.gpus = [
    .init(
      name: "Synthetic graphics with a long label", usage: 44, memory: 1234, coreCount: 10,
      rendererUsage: 32, tilerUsage: 21)
  ]
  populated.memory = .init(
    total: 1000, active: 400, inactive: 300, wired: 200, compressed: 100,
    free: 100, speculative: 0, purgeable: 50, swapUsed: 50, swapTotal: 200, pressure: 2)
  populated.volumes = [
    .init(name: "Synthetic startup volume", path: "/", total: 1000, available: 200)
  ]
  populated.processes = [
    .init(
      pid: 1, name: "Synthetic long process label 示例", cpu: 33, memory: 500, read: 700, written: 300
    )
  ]
  populated.sensors = [
    .init(key: "TP0P", name: "CPU test", kind: .temperature, value: 63),
    .init(key: "TCGC", name: "GPU temperature", kind: .temperature, value: 45),
    .init(key: "PSTR", name: "System total power", kind: .power, value: 8.5),
    .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1000),
  ]
  populated.batteries = [
    .init(
      name: "Synthetic battery", percent: 22, charging: false, externalPower: false,
      minutesRemaining: 61, cycles: 120, health: 94, watts: -4.5)
  ]
  populated.upload = 1000
  populated.download = 2000
  let history = (0..<12).map { index in
    var sample = populated
    sample.timestamp += Double(index * 2)
    sample.upload = index == 3 ? nil : Double(index * 100)
    sample.download = Double(index * 200)
    return sample.historyPoint
  }
  let reused = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  let themes: [NSAppearance.Name] = [
    .darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
    .accessibilityHighContrastAqua,
  ]
  for theme in themes {
    for size in [NSSize(width: 520, height: 454), NSSize(width: 704, height: 600)] {
      for module in Module.allCases where SummaryDashboardView.supports(module) {
        for missing in [false, true] {
          try autoreleasepool {
            let sample = missing ? Snapshot() : populated
            let fresh = SummaryDashboardView(frame: .init(origin: .zero, size: size))
            fresh.appearance = NSAppearance(named: theme)
            reused.appearance = NSAppearance(named: theme)
            reused.setFrameSize(size)
            fresh.update(sample, history: history, settings: Settings(), module: module)
            reused.update(sample, history: history, settings: Settings(), module: module)
            for scale in [1, 2] {
              let expected = SHA256.hash(data: try styledSummaryPixels(fresh, scale: scale))
              let actual = SHA256.hash(data: try styledSummaryPixels(reused, scale: scale))
              #expect(
                actual == expected,
                "\(module) / \(theme) / \(size) / missing:\(missing) / \(scale)x")
            }
          }
        }
      }
    }
  }
}
