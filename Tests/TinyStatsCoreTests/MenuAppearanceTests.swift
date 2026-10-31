import Foundation
import Testing

@testable import TinyStatsCore

@Test func appThemeMigratesSafelyAndPersistsIndependentlyOfReadoutColors() throws {
  for json in [#"{}"#, #"{"theme":"future"}"#, #"{"theme":false}"#] {
    #expect(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).theme == .system)
  }
  var settings = Settings()
  settings.theme = .dark
  settings.appearances["cpu"] = .init(color: .green)
  let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  #expect(restored.theme == .dark && restored.appearance(for: .cpu).color == .green)
}
@Test func menuAppearanceMigratesAndIsolatesDamagedPreferences() throws {
  let settings = try JSONDecoder().decode(
    Settings.self,
    from: Data(
      #"{"interval":5,"styles":{"cpu":"ring","network":"pie","memory":"future"},"appearances":{"cpu":{"size":"large","color":"green"},"memory":{"size":"future","color":"orange"},"network":false,"battery":{"size":"compact","color":"future"}}}"#
        .utf8))
  #expect(settings.interval == 5)
  #expect(settings.style(for: .cpu) == .ring)
  #expect(settings.style(for: .network) == .stacked)
  #expect(settings.style(for: .memory) == .stacked)
  #expect(settings.appearance(for: .cpu) == .init(size: .large, color: .green))
  #expect(settings.appearance(for: .memory) == .init(color: .orange))
  #expect(settings.appearance(for: .network) == .init())
  #expect(settings.appearance(for: .battery) == .init(size: .compact))
  let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  #expect(restored == settings)
  let legacy = try JSONDecoder().decode(
    Settings.self, from: Data(#"{"styles":{"cpu":"text","network":"history"}}"#.utf8))
  #expect(legacy.style(for: .cpu) == .text)
  #expect(legacy.style(for: .network) == .history)
  #expect(legacy.appearance(for: .cpu) == .init())
}

@Test func menuGaugesCannotInventPercentagesForRatesOrNonTemperatureSensors() {
  let gauges: Set<MenuBarStyle> = [.bar, .horizontal, .pie, .ring, .cores, .battery]
  for key in ["F0Ac", "PSTR", "VC0C", "IC0C", "ioreport:gpu"] {
    #expect(Set(MenuBarStyle.available(for: .sensors, sensorKey: key)).isDisjoint(with: gauges))
  }
  #expect(Set(MenuBarStyle.available(for: .network)).isDisjoint(with: gauges))
  #expect(Set(MenuBarStyle.available(for: .clock)).isDisjoint(with: gauges))
  #expect(MenuBarStyle.available(for: .sensors, sensorKey: "Tp01").contains(.ring))
  #expect(MenuBarStyle.available(for: .battery).contains(.battery))
  #expect(!MenuBarStyle.available(for: .memory).contains(.battery))
}

@Test func historyDeliveryFollowsVisibleEffectiveStylesWithDetailsClosed() {
  var settings = Settings()
  settings.readouts = [.cpu]
  settings.styles = ["cpu": .historyValue]
  #expect(settings.needsMenuBarHistory)
  settings.styles["cpu"] = .history
  #expect(settings.needsMenuBarHistory)
  settings.styles["cpu"] = .stacked
  settings.styles["memory"] = .historyValue
  #expect(!settings.needsMenuBarHistory)
  settings.readouts = [.clock]
  settings.styles["clock"] = .historyValue
  #expect(!settings.needsMenuBarHistory)
}

@Test func savedCombinedMenuRemainsOne() throws {
  let legacy = try JSONDecoder().decode(
    Settings.self,
    from: Data(#"{"separateItems":false,"readouts":["cpu","memory","network"]}"#.utf8))
  #expect(!legacy.separateItems && Settings().separateItems)
  #expect(legacy.readouts == [.cpu, .memory, .network])
}

@Test func menuBarSpacingAndLayoutDecodeDefaultsAndRejectUnknownValues() throws {
  for json in [
    #"{}"#, #"{"separateItems":"false","menuBarSpacing":false}"#, #"{"menuBarSpacing":"future"}"#,
  ] {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.separateItems && settings.menuBarSpacing == .standard)
  }
  for spacing in MenuBarSpacing.allCases {
    var settings = Settings()
    settings.separateItems = false
    settings.menuBarSpacing = spacing
    #expect(
      try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
  }
}
