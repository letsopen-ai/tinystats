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
    #expect(pair.primary.lab.distance(to: pair.secondary.lab) >= 0.18)
    #expect(abs(pair.primary.lab.lightness - pair.secondary.lab.lightness) >= 0.1299)
    #expect(pair.secondary.lab.chroma >= 0.09)
    for matrix in [protanopia, deuteranopia] {
      #expect(
        simulate(pair.primary, matrix).lab.distance(to: simulate(pair.secondary, matrix).lab)
          >= 0.12)
    }
    for color in [pair.primary, pair.secondary] {
      let hue = (color.lab.hue * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
      #expect(color.lab.chroma < 0.025 || color.lab.lightness >= 0.7 || !(85...125).contains(hue))
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
      let hue = (source.lab.hue * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
      if !(85...125).contains(hue) {
        #expect(abs(pair.primary.lab.hue - source.lab.hue) < 0.001)
      }
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
      #expect(abs(reference.lab.hue - secondary.lab.hue) < 0.000001)
      #expect(abs(secondary.lab.hue * 180 / .pi + 110) < 0.001)
    }
  }
}

@Test func documentedAccentHexPairsStayInSync() throws {
  let expected = [
    ("#005FCA / #D16C00", "#007AFF / #FFA566"),
    ("#873089 / #009393", "#B35DB5 / #00D8D9"),
    ("#EC4495 / #004981", "#F74F9E / #90C6FF"),
    ("#E0383E / #005DA1", "#FF5257 / #8FC6FF"),
    ("#D26A00 / #0067B3", "#F7821B / #0081DE"),
    ("#B57A00 / #0064AD", "#FFC600 / #54ABFF"),
    ("#419920 / #872D9A", "#62BA46 / #F0AEFF"),
    ("#878787 / #0063AC", "#8C8C8C / #89C3FF"),
    ("#005FCA / #D16C00", "#007AFF / #FFA566"),

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

// Machado, Oliveira & Fernandes (2009), severity 1.0, published linear-sRGB matrices.
// https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/CVD_Simulation.html
// Original test implementation of the mathematical transforms; no external code/library.
private let protanopia = [
  [0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216],
  [-0.003882, -0.048116, 1.051998],
]
private let deuteranopia = [
  [0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413],
  [-0.011820, 0.042940, 0.968881],
]
private func simulate(_ rgb: AccentPalette.RGB, _ matrix: [[Double]]) -> AccentPalette.RGB {
  let linear = [rgb.red, rgb.green, rgb.blue].map {
    $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
  }
  let mapped = matrix.map { row in
    let c = min(1, max(0, zip(row, linear).reduce(0) { $0 + $1.0 * $1.1 }))
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
  }
  return .init(mapped[0], mapped[1], mapped[2])
}
