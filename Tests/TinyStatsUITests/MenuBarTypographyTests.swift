import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func menuBarFontsUseRegularWeightAtTheirExistingSizes() {
  #expect(MenuBarReadoutView.verticalLabelFont == .systemFont(ofSize: 8, weight: .regular))
  #expect(MenuBarReadoutView.small == .systemFont(ofSize: 9, weight: .regular))
  #expect(
    MenuBarReadoutView.calendarFont == .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
  #expect(
    MenuBarReadoutView.smallCalendarFont == .monospacedDigitSystemFont(ofSize: 7, weight: .regular))
  #expect(
    StatusItemController.buttonFont == .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
  for size in MenuBarSize.allCases {
    #expect(
      MenuBarReadoutView.fonts[size]
        == .monospacedDigitSystemFont(ofSize: size.pointSize, weight: .regular))
    #expect(
      MenuBarReadoutView.networkFonts[size]
        == .monospacedDigitSystemFont(
          ofSize: size == .compact ? 10 : size == .standard ? 10.5 : 11, weight: .regular))
    // Regular weight retains the tabular digits used by live values and reservations.
    for font in [MenuBarReadoutView.fonts[size]!, MenuBarReadoutView.networkFonts[size]!] {
      let widths = (0...9).map {
        (String($0) as NSString).size(withAttributes: [.font: font]).width
      }
      #expect(Set(widths).count == 1)
    }
  }
}

@Test @MainActor func menuBarCachedSymbolsUseRegularWeightWithoutChangingNativeSize() throws {
  let regular = NSImage.SymbolConfiguration(pointSize: 0, weight: .regular)
  #expect(MenuBarReadoutView.symbolConfiguration.isEqual(regular))
  for name in Set(Module.allCases.map(\.symbol) + ["bolt.fill", "powerplug", "sun.max", "cloud"]) {
    #expect(MenuBarReadoutView.symbols[name] != nil)
  }
  for (name, image) in MenuBarReadoutView.symbols {
    let original = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil))
    #expect(image.symbolConfiguration.isEqual(regular))
    #expect(image.size == original.size)
  }
}

@Test @MainActor func regularNetworkReservationsFitTheWidestFormattedRates() {
  for size in MenuBarSize.allCases {
    for style in [MenuBarStyle.stacked, .historyValue, .text, .value] {
      let font =
        style == .stacked || style == .historyValue
        ? MenuBarReadoutView.networkFonts[size]! : MenuBarReadoutView.fonts[size]!
      let candidates =
        ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"].flatMap {
          ["↑ 999 \($0)", "↓ 10.0 \($0)"]
        } + ["↑ >999 EB/s", "↓ >999 EB/s"]
      let field = candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        .max()!
      var reading = MenuBarReadout(
        label: "NET", value: "↑ >999 EB/s", secondary: "↓ >999 EB/s", style: style)
      reading.isNetwork = true
      reading.appearance.size = size
      let renderer = MenuBarReadoutView()
      renderer.readouts = [reading]
      switch style {
      case .stacked: #expect(renderer.preferredWidth >= ceil(field))
      case .historyValue: #expect(renderer.preferredWidth >= 49 + ceil(field))
      default:
        let prefix =
          style == .text ? ("NET " as NSString).size(withAttributes: [.font: font]).width : 0
        let gap = (" " as NSString).size(withAttributes: [.font: font]).width
        #expect(renderer.preferredWidth >= prefix + 2 * field + gap)
      }
    }
  }
}
