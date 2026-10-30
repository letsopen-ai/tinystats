import AppKit
import TinyStatsCore

/// Resolve in the native status item's appearance, independently of the window theme.
/// No wallpaper sampling or layout-dependent colour work.
@MainActor struct MenuBarPalette {
  let text: NSColor
  let textShadow: NSShadow?
  let gaugeOutline: NSColor
  private let accent: NSColor
  private let isDark: Bool

  static func resolve(_ appearance: NSAppearance) -> Self {
    let dark = SystemStyle.isDark(appearance)
    let text: NSColor = dark ? .white : NSColor(calibratedWhite: 0.1, alpha: 1)
    return Self(
      text: text, textShadow: dark ? darkTextShadow : nil,
      gaugeOutline: text.withAlphaComponent(0.65),
      accent: SystemStyle.menuBarAccent(SystemStyle.resolvedAccent(in: appearance), dark: dark),
      isDark: dark)
  }
  private static let darkTextShadow: NSShadow = {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
    shadow.shadowBlurRadius = 1
    shadow.shadowOffset = .init(width: 0, height: -0.5)
    return shadow
  }()

  func graphic(_ module: Module?) -> NSColor { accent }

  func core(_ kind: CPUCoreKind) -> NSColor {
    switch kind {
    case .efficiency: accent.withAlphaComponent(isDark ? 0.5 : 0.45)
    case .performance: accent
    case .unknown: text.withAlphaComponent(0.65)
    }
  }
}
