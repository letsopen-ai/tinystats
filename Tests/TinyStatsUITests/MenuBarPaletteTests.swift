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

@Test @MainActor func menuBarPaletteUsesMonochromeGraphicsAndPreservesLabelContrast() throws {
  for name in [
    NSAppearance.Name.aqua, .darkAqua, .vibrantLight, .vibrantDark,
    .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
  ] {
    let appearance = try #require(NSAppearance(named: name))
    let palette = MenuBarPalette.resolve(appearance)
    let dark = SystemStyle.isDark(appearance)
    let expectedText: NSColor = dark ? .white : NSColor(calibratedWhite: 0.1, alpha: 1)
    #expect(palette.text == expectedText)
    #expect(palette.gaugeOutline == expectedText.withAlphaComponent(0.65))
    #expect((palette.textShadow != nil) == dark)
    if let shadow = palette.textShadow {
      #expect(shadow.shadowColor == NSColor.black.withAlphaComponent(0.65))
      #expect(shadow.shadowBlurRadius == 1)
      #expect(shadow.shadowOffset == NSSize(width: 0, height: -0.5))
    }
    // Wallpaper-independent status items use native monochrome ink for every module.
    for module in Module.allCases { #expect(palette.graphic(module) == expectedText) }
    #expect(palette.graphic(nil) == expectedText)
    #expect(palette.core(.performance) == expectedText)
    #expect(palette.core(.efficiency) == expectedText)
    #expect(palette.secondary == expectedText)
    #expect(palette.core(.unknown) == expectedText.withAlphaComponent(0.65))
    let background = try luminance(dark ? .black : .white)
    let foreground = try luminance(palette.text)
    #expect((max(background, foreground) + 0.05) / (min(background, foreground) + 0.05) >= 4.5)
  }
}

@Test @MainActor func menuBarAccentAdjustmentPreservesUserHueIncludingGraphite() throws {
  for accent in [NSColor.systemPurple, .systemGreen, .systemGray] {
    #expect(SystemStyle.menuBarAccent(accent, dark: false) == accent)
    let adjusted = try #require(
      SystemStyle.menuBarAccent(accent, dark: true).usingColorSpace(.sRGB))
    let original = try #require(accent.usingColorSpace(.sRGB))
    #expect(adjusted.redComponent >= original.redComponent)
    #expect(adjusted.greenComponent >= original.greenComponent)
    #expect(adjusted.blueComponent >= original.blueComponent)
    #expect(adjusted.alphaComponent == 1)
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
