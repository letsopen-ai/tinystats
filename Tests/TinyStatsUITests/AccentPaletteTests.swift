import Foundation
import Testing

@testable import TinyStats

/// NSColor.controlAccentColor resolved to sRGB in isolated macOS 27.2 processes.
/// AppleAccentColor: blue=4, purple=5, pink=6, red=0, orange=1, yellow=2, green=3;
/// graphite: AppleAccentColor=-1 AND AppleAquaColorVariant=6; default: no override.
/// These are actual control accents, not NSColor.systemBlue/Red/etc. Runtime uses live colors.
struct SystemAccentFixture: Sendable {
  let name: String
  let light: UInt32
  let dark: UInt32
  static let all: [Self] = [
    .init(name: "Blue", light: 0x007AFF, dark: 0x007AFF),
    .init(name: "Purple", light: 0x953D96, dark: 0xA550A7),
    .init(name: "Pink", light: 0xF74F9E, dark: 0xF74F9E),
    .init(name: "Red", light: 0xE0383E, dark: 0xFF5257),
    .init(name: "Orange", light: 0xF7821B, dark: 0xF7821B),
    .init(name: "Yellow", light: 0xFFC726, dark: 0xFFC600),
    .init(name: "Green", light: 0x62BA46, dark: 0x62BA46),
    .init(name: "Graphite", light: 0x989898, dark: 0x8C8C8C),
    .init(name: "Multicolor default", light: 0x007AFF, dark: 0x007AFF),
  ]
}

@Test(arguments: SystemAccentFixture.all)
func derivedAccentPairIsDistinctReadableAndInGamut(_ fixture: SystemAccentFixture) {
  for dark in [false, true] {
    let source = AccentPalette.RGB(hex: dark ? fixture.dark : fixture.light)
    let pair = AccentPalette.derive(from: source, dark: dark)
    #expect(pair.primary.lab.distance(to: pair.secondary.lab) >= 0.12)
    for color in [pair.primary, pair.secondary] {
      #expect(
        [color.red, color.green, color.blue].allSatisfy { $0.isFinite && (0...1).contains($0) })
      for background in dark ? [0x1F1F21, 0x2A2A2D, 0x343436] : [0xFFFFFF, 0xECECEE] {
        #expect(color.contrast(against: .init(hex: UInt32(background))) >= 3)
        // Documented hex rounding must not lose the contrast guarantee.
        let rounded = AccentPalette.RGB(
          (color.red * 255).rounded() / 255, (color.green * 255).rounded() / 255,
          (color.blue * 255).rounded() / 255)
        #expect(rounded.contrast(against: .init(hex: UInt32(background))) >= 3)
      }
    }
    if source.lab.chroma >= 0.025 {
      let separation = abs(
        atan2(
          sin(pair.secondary.lab.hue - source.lab.hue), cos(pair.secondary.lab.hue - source.lab.hue)
        ))
      #expect(abs(separation - .pi / 2) < 0.001)
      #expect(abs(pair.primary.lab.hue - source.lab.hue) < 0.001)
    }
    if source.contrast(against: AccentPalette.background(dark: dark)) >= 3.05 {
      #expect(pair.primary == source)
    }
  }
}

@Test func accentConversionMatchesPublishedReferenceAndRoundTrips() {
  let red = AccentPalette.RGB(1, 0, 0).lab
  #expect(abs(red.lightness - 0.62795536) < 0.000001)
  #expect(abs(red.a - 0.22486306) < 0.000001)
  #expect(abs(red.b - 0.12584630) < 0.000001)
  for hex: UInt32 in [0, 0xFFFFFF, 0x808080, 0x007AFF, 0xF74F9E, 0xFFC726] {
    let rgb = AccentPalette.RGB(hex: hex)
    let roundTrip = rgb.lab.gamutMapped
    #expect(abs(roundTrip.red - rgb.red) < 0.0001)
    #expect(abs(roundTrip.green - rgb.green) < 0.0001)
    #expect(abs(roundTrip.blue - rgb.blue) < 0.0001)
  }
}

@Test func neutralAndUnknownAccentsUseStableChromaticCompanion() {
  for dark in [false, true] {
    let reference = AccentPalette.derive(from: .init(0.5, 0.5, 0.5), dark: dark).secondary
    for gray in [0.0, 0.2, 0.6, 1.0] {
      let secondary = AccentPalette.derive(from: .init(gray, gray, gray), dark: dark).secondary
      #expect(reference.lab.distance(to: secondary.lab) < 0.000001)
      #expect(abs(secondary.lab.hue * 180 / .pi + 110) < 0.001)
    }
  }
}

@Test func documentedAccentHexPairsStayInSync() throws {
  let expected = [
    ("#007AFF / #BD2B87", "#007AFF / #FD79C3"),
    ("#953D96 / #AA5900", "#B35DB5 / #F7903A"),
    ("#EC4495 / #8F6B00", "#F74F9E / #D9A500"),
    ("#E0383E / #717900", "#FF5257 / #AFB800"),
    ("#D26A00 / #0C8A1E", "#F7821B / #5FC961"),
    ("#A98100 / #008570", "#FFC600 / #00CAAD"),
    ("#419920 / #007DA4", "#62BA46 / #00BEF8"),
    ("#878787 / #1F74BF", "#8C8C8C / #67B3FF"),
    ("#007AFF / #BD2B87", "#007AFF / #FD79C3"),
  ]
  let document = try String(
    contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/DESIGN.md"), encoding: .utf8)
  for (fixture, expected) in zip(SystemAccentFixture.all, expected) {
    let light = AccentPalette.derive(from: .init(hex: fixture.light), dark: false)
    let dark = AccentPalette.derive(from: .init(hex: fixture.dark), dark: true)
    #expect(light.primary.hex + " / " + light.secondary.hex == expected.0)
    #expect(dark.primary.hex + " / " + dark.secondary.hex == expected.1)
    let row =
      "| \(fixture.name) | \(AccentPalette.RGB(hex: fixture.light).hex) | \(expected.0) | \(AccentPalette.RGB(hex: fixture.dark).hex) | \(expected.1) |"
    #expect(document.contains(row))
  }
}
