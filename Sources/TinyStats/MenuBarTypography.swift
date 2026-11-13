import AppKit
import TinyStatsCore

/// Three bounded caches shared by status buttons and production-renderer previews.
@MainActor struct MenuBarTypography {
  static let cache = Dictionary(uniqueKeysWithValues: MenuBarWeight.allCases.map { ($0, Self($0)) })
  static func forWeight(_ weight: MenuBarWeight) -> Self { cache[weight]! }

  let textWeight: NSFont.Weight
  let verticalLabelFont: NSFont
  let fonts: [MenuBarSize: NSFont]
  let networkFonts: [MenuBarSize: NSFont]
  let networkStackWidths: [MenuBarSize: CGFloat]
  let networkInlineWidths: [MenuBarSize: CGFloat]
  let small: NSFont
  let calendarFont: NSFont
  let smallCalendarFont: NSFont
  let buttonFont: NSFont
  let symbolConfiguration: NSImage.SymbolConfiguration
  let symbols: [String: NSImage]
  let historyStroke, ringStroke, outlineStroke, tickStroke: CGFloat
  let hourStroke, minuteStroke, secondStroke: CGFloat

  private init(_ weight: MenuBarWeight) {
    switch weight {
    case .regular:
      textWeight = .regular
      (historyStroke, ringStroke, outlineStroke, tickStroke) = (1, 3, 1, 0.7)
      (hourStroke, minuteStroke, secondStroke) = (1, 1, 0.7)
    case .medium:
      textWeight = .medium
      (historyStroke, ringStroke, outlineStroke, tickStroke) = (1.25, 3.5, 1.15, 0.85)
      (hourStroke, minuteStroke, secondStroke) = (1.25, 1.15, 0.8)
    case .semibold:
      textWeight = .semibold
      (historyStroke, ringStroke, outlineStroke, tickStroke) = (1.5, 4, 1.25, 1)
      (hourStroke, minuteStroke, secondStroke) = (1.5, 1, 0.7)
    }
    let textWeight = textWeight
    verticalLabelFont = .systemFont(ofSize: 8, weight: textWeight)
    fonts = Dictionary(
      uniqueKeysWithValues: MenuBarSize.allCases.map {
        ($0, NSFont.monospacedDigitSystemFont(ofSize: $0.pointSize, weight: textWeight))
      })
    networkFonts = Dictionary(
      uniqueKeysWithValues: MenuBarSize.allCases.map {
        (
          $0,
          NSFont.monospacedDigitSystemFont(
            ofSize: $0 == .compact ? 10 : $0 == .standard ? 10.5 : 11, weight: textWeight)
        )
      })
    networkStackWidths = networkFonts.mapValues { Self.rateWidth($0) }
    networkInlineWidths = fonts.mapValues { Self.rateWidth($0) }
    small = .systemFont(ofSize: 9, weight: weight == .semibold ? .medium : textWeight)
    calendarFont = .monospacedDigitSystemFont(ofSize: 11, weight: textWeight)
    smallCalendarFont = .monospacedDigitSystemFont(ofSize: 7, weight: textWeight)
    buttonFont = .monospacedDigitSystemFont(ofSize: 11, weight: textWeight)
    // A zero point size preserves native symbol sizing.
    symbolConfiguration = .init(pointSize: 0, weight: textWeight)
    let configuration = symbolConfiguration
    symbols = Dictionary(
      uniqueKeysWithValues: (Module.allCases.map(\.symbol) + [
        "bolt.fill", "powerplug", "cloud", "cloud.bolt.rain", "cloud.sleet", "cloud.snow",
        "cloud.rain", "cloud.fog", "moon.stars", "sun.max", "cloud.moon", "questionmark.circle",
      ]).compactMap { name in
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
          .withSymbolConfiguration(configuration).map { (name, $0) }
      })
  }

  private static func rateWidth(_ font: NSFont) -> CGFloat {
    let candidates =
      ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"].flatMap {
        ["↑ 999 \($0)", "↓ 10.0 \($0)"]
      } + ["↑ >999 EB/s", "↓ >999 EB/s"]
    return ceil(
      candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
  }
}
