import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

private func graphicDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Test @MainActor func richClockAtomsRespectZonesRelativeOffsetsAndAccessibilityWithoutFormatters()
  throws
{
  ClockMenuRenderer.invalidate()
  let date = graphicDate("2026-01-01T23:30:30Z")
  let entry = ClockMenuEntry(
    zone: "Asia/Kathmandu", firstLine: "{calendar} {analogSeconds} {localOffset}",
    secondLine: "{fuzzy}")
  let value = ClockMenuRenderer.content(
    entry, at: date, locale: .init(identifier: "en_US_POSIX"),
    calendar: .init(identifier: .gregorian),
    localZone: try #require(TimeZone(identifier: "Asia/Shanghai")))
  let expectedDial = try #require(ClockDialReading(hour: 5, minute: 15, second: 30))
  #expect(value.first.parts == [.calendar(2), .text(" "), .dial(expectedDial), .text(" -02:15")])
  #expect(value.first.text == "Calendar day 2 Analogue 05:15:30 -02:15")
  #expect(value.second?.text == "quarter past five")
  #expect(ClockMenuRenderer.cachedFormatterCount == 0)
  let la = ClockMenuEntry(
    zone: "America/Los_Angeles", firstLine: "{analog} {offset} {localOffset}", secondLine: "")
  let before = ClockMenuRenderer.content(
    la, at: graphicDate("2026-11-01T08:30:00Z"),
    localZone: try #require(TimeZone(identifier: "UTC")))
  let after = ClockMenuRenderer.content(
    la, at: graphicDate("2026-11-01T09:30:00Z"),
    localZone: try #require(TimeZone(identifier: "UTC")))
  #expect(before.first.parts.first == after.first.parts.first)
  #expect(
    before.first.text.hasSuffix("-07:00 -07:00") && after.first.text.hasSuffix("-08:00 -08:00"))
  let invalid = ClockMenuRenderer.content(entry, at: Date(timeIntervalSince1970: .nan))
  #expect(invalid.first.parts == [.text("—")] && invalid.second == nil)
}

@Test @MainActor func clockAtomBoundsPreserveTwoFullLinesAndMergeAdjacentText() {
  let plain = ClockMenuLine([.text("one"), .text(" "), .text("two")])
  #expect(plain.parts == [.text("one two")])
  let long = ClockMenuLine([.text(String(repeating: "a", count: 200))])
  #expect(long.text.count == 128 && long.text.hasSuffix("…"))
  let many = ClockMenuLine(Array(repeating: .calendar(31), count: 200))
  #expect(many.parts.count == 128 && many.parts.last == .text("…"))
  let joined = ClockMenuContent(
    first: .init([.text(String(repeating: "a", count: 128))]),
    second: .init([.text(String(repeating: "b", count: 128))])
  ).joined
  #expect(
    joined.parts == [
      .text(String(repeating: "a", count: 128) + " " + String(repeating: "b", count: 128))
    ])
}

@MainActor private func clockPixels(_ view: NSView) throws -> Data {
  _ = NSApplication.shared
  let rep = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width * 2)),
      pixelsHigh: Int(ceil(view.bounds.height * 2)), bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  rep.size = view.bounds.size
  view.cacheDisplay(in: view.bounds, to: rep)
  return try #require(rep.representation(using: .png, properties: [:]))
}

@Test @MainActor func clockGraphicsRenderAllTextStylesAndChangeWithHandsAndCalendarDay() throws {
  var settings = Settings()
  settings.clockMenu.custom = true
  let first = graphicDate("2026-01-01T00:00:00Z")
  let later = graphicDate("2026-01-02T03:30:30Z")
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for style in [MenuBarStyle.text, .value, .stacked] {
      for height in [22.0, 37] {
        for token in ["{calendar}", "{analog}", "{analogSeconds}"] {
          settings.clockMenu.entries = [.init(zone: "UTC", firstLine: token, secondLine: "fixed")]
          settings.styles["clock"] = style
          settings.appearances["clock"] = .init(
            size: height == 22 ? .compact : .large, color: .blue)
          let view = MenuBarReadoutView()
          view.appearance = NSAppearance(named: appearance)
          view.readouts = ClockMenuRenderer.readouts(settings: settings, at: first)
          view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: height)
          let width = view.preferredWidth
          let before = try clockPixels(view)
          view.readouts = ClockMenuRenderer.readouts(settings: settings, at: later)
          // Stacked clocks retain a 29-point content floor plus two edge points.
          #expect(view.preferredWidth == width && width >= 31 && width < 400)
          let after = try clockPixels(view)
          #expect(before != after)
        }
      }
    }
  }
  if let path = ProcessInfo.processInfo.environment["TINYSTATS_CLOCK_GALLERY"] {
    let gallery = ClockGraphicsGallery(frame: .init(x: 0, y: 0, width: 780, height: 300))
    for (column, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
      let panel = ClockGraphicsGallery(frame: .init(x: column * 390, y: 0, width: 390, height: 300))
      panel.appearance = NSAppearance(named: appearance)
      gallery.addSubview(panel)
      for (index, entry) in [
        ClockMenuEntry(
          name: "Calendar + time", zone: "UTC", firstLine: "{calendar} {hour24}:{minute}",
          secondLine: ""),
        .init(name: "Analogue", zone: "UTC", firstLine: "{analogSeconds}", secondLine: ""),
        .init(
          name: "Mixed two lines", zone: "UTC", firstLine: "{calendar} {weekday}",
          secondLine: "{analog} {hour24}:{minute}"),
        .init(
          name: "Fuzzy + offset", zone: "Asia/Kathmandu", firstLine: "{fuzzy}",
          secondLine: "{localOffset}"),
      ].enumerated() {
        let label = NSTextField(labelWithString: entry.name)
        label.frame = .init(x: 20, y: 260 - index * 70, width: 350, height: 20)
        panel.addSubview(label)
        settings.clockMenu.entries = [entry]
        settings.styles["clock"] = .stacked
        settings.appearances["clock"] = .init()
        let view = MenuBarReadoutView()
        view.readouts = ClockMenuRenderer.readouts(settings: settings, at: later)
        view.frame = .init(
          x: 20, y: CGFloat(230 - index * 70), width: view.preferredWidth, height: 24)
        panel.addSubview(view)
      }
    }
    let pixels = try clockPixels(gallery)
    let bitmap = try #require(NSBitmapImageRep(data: pixels))
    let bytes = try #require(bitmap.bitmapData)
    // Each appearance must retain foreground detail after both sibling panels draw.
    for column in 0..<2 {
      var colors = Set<UInt32>()
      for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 4) {
        for x in stride(from: column * 780 + 20, to: column * 780 + 760, by: 4) {
          let start = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
          colors.insert(
            UInt32(bytes[start]) << 16 | UInt32(bytes[start + 1]) << 8 | UInt32(bytes[start + 2]))
        }
      }
      #expect(colors.count > 8)
    }
    try pixels.write(to: URL(fileURLWithPath: path))
  }
}

@MainActor private final class ClockGraphicsGallery: NSView {
  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      NSBezierPath(rect: bounds).addClip()
      NSColor.windowBackgroundColor.setFill()
      bounds.fill()
    }
  }
}
