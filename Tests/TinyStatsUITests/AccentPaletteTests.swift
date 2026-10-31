import AppKit
import Foundation
import Testing
import TinyStatsCore

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
    ("#873089 / #009393", "#B35DB5 / #00D1D2"),
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

@Test(arguments: Module.allCases.filter { $0 != .overview }) @MainActor
func moduleIdentityPairsResolveAppearancesAndRetainContrast(_ module: Module) throws {
  let palette = try #require(SystemStyle.modulePalettes[module])
  for dark in [false, true] {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    let primary = AccentPalette.RGB(hex: dark ? palette.dark : palette.light)
    let secondary = AccentPalette.RGB(hex: dark ? palette.darkSecondary : palette.lightSecondary)
    appearance.performAsCurrentDrawingAppearance {
      for (color, expected) in [(palette.primary, primary), (palette.secondary, secondary)] {
        let actual = color.usingColorSpace(.sRGB)!
        #expect(abs(actual.redComponent - expected.red) < 0.0001)
        #expect(abs(actual.greenComponent - expected.green) < 0.0001)
        #expect(abs(actual.blueComponent - expected.blue) < 0.0001)
        #expect(actual.alphaComponent == 1)
      }
    }
    // Light inks retain 3:1 on white/#ECECEE and 2.6:1 on conservative #D5D5D5. ΔL 0.13
    // forced amber/indigo companions back to brown/navy. Retain a nonzero lightness
    // cue plus the unchanged full protan/deutan ΔE guard and solid/dashed markers.
    // Dark palettes retain the original ΔL guard. See the dopamine experiment in DESIGN.md.
    #expect(abs(primary.lab.lightness - secondary.lab.lightness) >= (dark ? 0.13 : 0.025))
    appearance.performAsCurrentDrawingAppearance {
      for glass in [false, true] {
        // Overview Memory uses primary palette ink with the secondary (dashed) role.
        for color in [palette.primary, palette.secondary] {
          for role in [ChartSeriesRole.primary, .secondary] {
            let trace = SystemStyle.chartTraceColor(color, role: role, glass: glass)
            #expect(trace.usingColorSpace(.sRGB) == color.usingColorSpace(.sRGB))
          }
        }
      }
    }
    for matrix in [protanopia, deuteranopia] {
      #expect(simulate(primary, matrix).lab.distance(to: simulate(secondary, matrix).lab) >= 0.12)
    }
    for color in [primary, secondary] {
      // Solid fallback/window and conservative neutral bounds; composited glass is measured
      // separately from the owned-window captures, since its colour depends on the backdrop.
      for background: UInt32 in dark ? [0x1F1F21, 0x343436] : [0xFFFFFF, 0xECECEE] {
        #expect(color.contrast(against: .init(hex: background)) >= 3)
      }
      if !dark {
        // Owner-approved candy experiment: labels/glyphs accompany the marks, and
        // #D5D5D5 is a conservative glass floor versus measured compositor backings.
        #expect(color.contrast(against: .init(hex: 0xD5D5D5)) >= 2.6)
      }
    }
  }
}

@Test(arguments: [false, true]) @MainActor
func modulePrimariesRetainDistinctIdentities(_ dark: Bool) {
  let modules = Module.allCases.filter { SystemStyle.modulePalettes[$0] != nil }
  for (index, module) in modules.enumerated() {
    let palette = SystemStyle.modulePalettes[module]!
    let primary = AccentPalette.RGB(hex: dark ? palette.dark : palette.light)
    for other in modules.dropFirst(index + 1) {
      let otherPalette = SystemStyle.modulePalettes[other]!
      let otherPrimary = AccentPalette.RGB(hex: dark ? otherPalette.dark : otherPalette.light)
      // Protect Disk/Sensors, Memory/Time and Network/Weather against hue collisions.
      #expect(primary.lab.distance(to: otherPrimary.lab) >= 0.075)
    }
  }
}

@Test @MainActor func lightCompanionsAvoidReviewedPrimaryCollisions() throws {
  for (module, other) in [(Module.cpu, Module.gpu), (.gpu, .sensors)] {
    let palette = try #require(SystemStyle.modulePalettes[module])
    let otherPalette = try #require(SystemStyle.modulePalettes[other])
    let companion = AccentPalette.RGB(hex: palette.lightSecondary)
    let otherPrimary = AccentPalette.RGB(hex: otherPalette.light)
    #expect(companion.lab.distance(to: otherPrimary.lab) >= 0.075)
  }
}

@Test @MainActor func documentedModulePaletteStaysInSync() throws {
  let document = try String(
    contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/DESIGN.md"), encoding: .utf8)
  let modules: [(Module, String, String)] = [
    (.cpu, "CPU", "#EF2F8E | #FF84CE | #0A88D1 | #85F8E9"),
    (.memory, "Memory", "#A65CF4 | #B8A0FF | #C55F00 | #FFF29A"),
    (.network, "Network", "#00946F | #4CF5B0 | #9B66E8 | #A891FF"),
    (.disks, "Disk", "#B87000 | #FFE93D | #9450DF | #B0A0FF"),
    (.sensors, "Sensors / thermal", "#DD5545 | #FFC266 | #6455F4 | #A58CFF"),
    (.battery, "Battery / Power", "#549200 | #BDFA35 | #A960E4 | #AD99FF"),
    (.gpu, "GPU", "#0079FF | #65CCFF | #BC5700 | #FFF29A"),
    (.clock, "Time", "#CF40DF | #F5A1FF | #C55F00 | #FFF59A"),
    (.weather, "Weather", "#008CBA | #50EFFF | #8340F5 | #A891FF"),
  ]
  let rows = document.split(separator: "\n").filter { line in
    modules.contains { line.hasPrefix("| \($0.1) | #") }
  }
  #expect(rows.count == modules.count)
  #expect(SystemStyle.modulePalettes.count == modules.count)
  for (module, name, expectedHexes) in modules {
    let palette = try #require(SystemStyle.modulePalettes[module])
    let hexes = [palette.light, palette.dark, palette.lightSecondary, palette.darkSecondary]
      .map { AccentPalette.RGB(hex: $0).hex }.joined(separator: " | ")
    #expect(hexes == expectedHexes)
    #expect(document.contains("| \(name) | \(expectedHexes) |"))
  }
}
