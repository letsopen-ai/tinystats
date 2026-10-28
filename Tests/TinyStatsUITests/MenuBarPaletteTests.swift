import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func luminance(_ color: NSColor) throws -> Double {
  let rgb = try #require(color.usingColorSpace(.sRGB))
  func linear(_ value: CGFloat) -> Double {
    let value = Double(value)
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
    + 0.0722 * linear(rgb.blueComponent)
}

@Test @MainActor func darkMenuBarPalettePreservesExistingColorsAndShadow() throws {
  for name in [
    NSAppearance.Name.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
    .accessibilityHighContrastVibrantDark,
  ] {
    let palette = MenuBarPalette.resolve(try #require(NSAppearance(named: name)))
    #expect(palette.text == .white)
    #expect(palette.gaugeOutline == NSColor.white.withAlphaComponent(0.65))
    let shadow = try #require(palette.textShadow)
    #expect(shadow.shadowColor == NSColor.black.withAlphaComponent(0.65))
    #expect(shadow.shadowBlurRadius == 1)
    #expect(shadow.shadowOffset == NSSize(width: 0, height: -0.5))
    let brightBlue = NSColor(calibratedRed: 0.3, green: 0.78, blue: 1, alpha: 1)
    let expected: [(Module, NSColor)] = [
      (.cpu, brightBlue), (.network, brightBlue), (.gpu, .systemTeal),
      (.memory, .systemPurple), (.disks, .systemOrange), (.sensors, .systemOrange),
      (.weather, .systemOrange), (.battery, .systemGreen), (.clock, .white),
      (.overview, .labelColor),
    ]
    for (module, color) in expected { #expect(palette.graphic(module) == color) }
    #expect(palette.graphic(nil) == .labelColor)
    for kind in [CPUCoreKind.efficiency, .performance, .unknown] {
      #expect(palette.core(kind) == kind.chartColor)
    }
  }
}

@Test @MainActor func lightMenuBarPaletteHasDarkTextAndSaturatedContrastingGraphics() throws {
  let background = try luminance(NSColor(calibratedWhite: 0.94, alpha: 1))
  for name in [
    NSAppearance.Name.aqua, .vibrantLight, .accessibilityHighContrastAqua,
    .accessibilityHighContrastVibrantLight,
  ] {
    let palette = MenuBarPalette.resolve(try #require(NSAppearance(named: name)))
    #expect(palette.text == NSColor(calibratedWhite: 0.1, alpha: 1))
    #expect(palette.textShadow == nil)
    #expect(palette.gaugeOutline == palette.text.withAlphaComponent(0.65))
    #expect((background + 0.05) / (try luminance(palette.text) + 0.05) >= 4.5)
    #expect(palette.graphic(.clock) == palette.text)
    let colors =
      Module.allCases.map { palette.graphic($0) }
      + [CPUCoreKind.efficiency, .performance, .unknown].map { palette.core($0) }
    for color in colors {
      #expect(color.alphaComponent == 1)
      #expect((background + 0.05) / (try luminance(color) + 0.05) >= 3)
    }
    #expect(palette.core(.efficiency) != palette.core(.performance))
    #expect(palette.core(.performance) != palette.core(.unknown))
  }
}

@Test @MainActor func menuBarAppearanceChangesInvalidateDrawingAndNotifyPreview() throws {
  // Host in a window so AppKit keeps needsDisplay; unhosted views may clear it.
  let window = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 120, height: 40),
    styleMask: [.borderless], backing: .buffered, defer: false)
  let view = MenuBarReadoutView(frame: .init(x: 0, y: 0, width: 100, height: 24))
  window.contentView = view
  view.appearance = NSAppearance(named: .darkAqua)
  var notifications = 0
  view.onAppearanceChange = { notifications += 1 }
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    view.appearance = NSAppearance(named: name)
    view.needsDisplay = false
    let before = notifications
    view.viewDidChangeEffectiveAppearance()
    #expect(view.needsDisplay)
    #expect(notifications == before + 1)
    let palette = MenuBarPalette.resolve(view.effectiveAppearance)
    #expect((palette.text == .white) == (name == .darkAqua))
  }
  window.contentView = nil
}

@Test @MainActor func adaptivePalettePreservesWidthsIncludingMultiEntryTime() throws {
  let view = MenuBarReadoutView()
  for size in MenuBarSize.allCases {
    for style in MenuBarStyle.allCases {
      view.readouts = [
        .init(
          label: "CPU", value: "—", secondary: nil, style: style,
          appearance: .init(size: size), cores: [nil, 0, 75])
      ]
      view.appearance = NSAppearance(named: .darkAqua)
      let width = view.preferredWidth
      view.appearance = NSAppearance(named: .aqua)
      #expect(view.preferredWidth == width)
    }
  }
  var settings = Settings()
  settings.clockMenu.custom = true
  settings.clockMenu.entries = [
    .init(name: "UTC", zone: "UTC", firstLine: "{calendar} {hour24}:{minute}"),
    .init(name: "Tokyo", zone: "Asia/Tokyo", firstLine: "{analog} {hour24}:{minute}"),
  ]
  view.readouts = ClockMenuRenderer.readouts(
    settings: settings, at: Date(timeIntervalSince1970: 1_700_000_000))
  #expect(view.readouts.count == 2)
  view.paused = true
  view.appearance = NSAppearance(named: .darkAqua)
  let width = view.preferredWidth
  view.appearance = NSAppearance(named: .aqua)
  #expect(view.preferredWidth == width)
}
