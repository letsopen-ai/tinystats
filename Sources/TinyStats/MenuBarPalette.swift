import AppKit
import TinyStatsCore

/// The host status item's appearance, independent of TinyStats' window theme.
/// Two shared palettes keep appearance work bounded; no wallpaper or screen sampling.
@MainActor struct MenuBarPalette {
  let text: NSColor
  let textShadow: NSShadow?
  let gaugeOutline: NSColor
  private let isDark: Bool

  static func resolve(_ appearance: NSAppearance) -> Self {
    let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
    return match == .darkAqua || match == .vibrantDark ? dark : light
  }

  private static let dark = Self(
    text: .white,
    textShadow: {
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
      shadow.shadowBlurRadius = 1
      shadow.shadowOffset = .init(width: 0, height: -0.5)
      return shadow
    }(),
    gaugeOutline: NSColor.white.withAlphaComponent(0.65), isDark: true)
  private static let lightText = NSColor(calibratedWhite: 0.1, alpha: 1)
  private static let light = Self(
    text: lightText, textShadow: nil,
    gaugeOutline: lightText.withAlphaComponent(0.65), isDark: false)
  private static let brightBlue = NSColor(calibratedRed: 0.3, green: 0.78, blue: 1, alpha: 1)
  private static let lightBlue = NSColor(calibratedRed: 0, green: 0.40, blue: 0.85, alpha: 1)
  private static let lightTeal = NSColor(calibratedRed: 0, green: 0.50, blue: 0.55, alpha: 1)
  private static let lightPurple = NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.80, alpha: 1)
  private static let lightOrange = NSColor(calibratedRed: 0.75, green: 0.35, blue: 0, alpha: 1)
  private static let lightGreen = NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.20, alpha: 1)
  private static let lightPink = NSColor(calibratedRed: 0.75, green: 0.15, blue: 0.40, alpha: 1)

  func graphic(_ module: Module?) -> NSColor {
    switch module {
    case .cpu, .network: isDark ? Self.brightBlue : Self.lightBlue
    case .gpu: isDark ? .systemTeal : Self.lightTeal
    case .memory: isDark ? .systemPurple : Self.lightPurple
    case .disks, .sensors, .weather: isDark ? .systemOrange : Self.lightOrange
    case .battery: isDark ? .systemGreen : Self.lightGreen
    case .clock: text
    default: isDark ? .labelColor : text
    }
  }

  func core(_ kind: CPUCoreKind) -> NSColor {
    // Detail charts keep their existing chartColor in both appearances.
    if isDark { return kind.chartColor }
    switch kind {
    case .efficiency: return Self.lightPink
    case .performance: return Self.lightBlue
    case .unknown: return Self.lightTeal
    }
  }
}
