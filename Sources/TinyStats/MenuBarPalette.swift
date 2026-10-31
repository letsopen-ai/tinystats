import AppKit
import TinyStatsCore

/// Resolve in the native status item's appearance, independently of the window theme.
/// Status-item graphics stay monochrome for arbitrary wallpaper. Module colour is confined
/// to Settings drag chips, whose semantic backing has known contrast.
@MainActor struct MenuBarPalette {
  let text: NSColor
  let textShadow: NSShadow?
  let gaugeOutline: NSColor
  private let accent: NSColor
  let secondary: NSColor

  static func resolve(_ appearance: NSAppearance) -> Self {
    let dark = SystemStyle.isDark(appearance)
    let text: NSColor = dark ? .white : NSColor(calibratedWhite: 0.1, alpha: 1)
    return Self(
      text: text, textShadow: dark ? darkTextShadow : nil,
      gaugeOutline: text.withAlphaComponent(0.65),
      accent: text, secondary: text)
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
    case .efficiency: text.withAlphaComponent(0.5)
    case .performance: accent
    case .unknown: text.withAlphaComponent(0.65)
    }
  }
}
