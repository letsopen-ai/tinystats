import Foundation
import Testing

@testable import TinyStatsCore

private func battery(
  percent: Double = 72, external: Bool = false, charging: Bool = false,
  charged: Bool? = nil, minutes: Int? = 195, watts: Double? = -8.4
) -> BatteryReading {
  .init(
    name: "Fixture", percent: percent, charging: charging, externalPower: external,
    minutesRemaining: minutes, cycles: nil, health: nil, watts: watts, fullyCharged: charged)
}

@Test func batteryStatesUseOSChargeCompletionRatherThanCapacityOrACAlone() {
  #expect(BatteryMenuState.state(for: battery()) == .draining)
  #expect(BatteryMenuState.state(for: battery(external: true, charging: true)) == .charging)
  #expect(
    BatteryMenuState.state(for: battery(percent: 95, external: true, charged: true)) == .charged)
  for charged in [nil, false] as [Bool?] {
    #expect(
      BatteryMenuState.state(for: battery(percent: 100, external: true, charged: charged))
        == .externalPower)
    #expect(
      BatteryMenuState.state(for: battery(percent: 80, external: true, charged: charged))
        == .externalPower)
  }
  #expect(BatteryMenuState.state(for: battery(external: false, charged: true)) == .draining)
  #expect(
    BatteryMenuState.state(for: battery(external: true, charging: true, charged: true)) == .charging
  )
}

@Test func batteryTextKeepsStateTimeAndSignedPowerSemanticsAndRejectsUnknowns() {
  let draining = battery()
  #expect(BatteryMenuText(reading: draining, format: .percent).value == "72%")
  #expect(BatteryMenuText(reading: draining, format: .time).value == "3:15")
  #expect(BatteryMenuText(reading: draining, format: .time).label == "LEFT")
  #expect(BatteryMenuText(reading: draining, format: .percentAndTime).secondary == "↓ 3:15")
  let charging = battery(external: true, charging: true, minutes: 65, watts: 17.2)
  #expect(BatteryMenuText(reading: charging, format: .time).label == "TO FULL")
  #expect(BatteryMenuText(reading: charging, format: .percentAndTime).secondary == "↑ 1:05")
  #expect(BatteryMenuText(reading: charging, format: .power).value == "+17.2 W")
  #expect(BatteryMenuText(reading: draining, format: .power).value == "-8.4 W")
  for minutes in [nil, -1, 0, Int.max, 10_081] as [Int?] {
    let unknown = battery(minutes: minutes)
    #expect(BatteryMenuText(reading: unknown, format: .time).value == "—")
    #expect(BatteryMenuText(reading: unknown, format: .percentAndTime).secondary == "—")
  }
  #expect(BatteryMenuText(reading: battery(minutes: 10_080), format: .time).value == "168:00")
  for invalid in [Double.nan, .infinity, -.infinity, 10_001] {
    #expect(BatteryMenuText(reading: battery(watts: invalid), format: .power).value == "—")
  }
  #expect(BatteryMenuText(reading: battery(percent: .nan), format: .percent).value == "—")
  #expect(
    BatteryMenuText(reading: battery(external: true, charged: true), format: .time).value == "Full")
  #expect(
    BatteryMenuText(reading: battery(external: true, charged: false), format: .time).value == "AC")
  #expect(
    BatteryMenuText(reading: battery(external: true, charged: false), format: .status).value
      == "On AC")
  #expect(BatteryMenuText(reading: nil, format: .time).value == "AC")
}

@Test func batteryMenuMigrationIsPerFieldAndPreservesOtherPreferencesAndDisabledDefaults() throws {
  let legacy = try JSONDecoder().decode(
    Settings.self, from: Data(#"{"styles":{"battery":"ring"}}"#.utf8))
  #expect(!legacy.batteryMenu.customizeStates)
  #expect(
    legacy.batteryMenu.preset(for: battery(), defaultStyle: legacy.style(for: .battery)).style
      == .ring)
  let data = Data(
    #"{"theme":"dark","worldClocks":["UTC"],"worldClockNames":{"UTC":"Build server"},"batteryMenu":{"format":"power","customizeStates":true,"draining":{"format":"time","style":"historyValue"},"charging":{"format":7,"style":"ring"},"charged":false,"externalPower":{"format":"status","style":"cores"}}}"#
      .utf8)
  let saved = try JSONDecoder().decode(Settings.self, from: data)
  #expect(saved.batteryMenu.format == .power && saved.batteryMenu.customizeStates)
  #expect(saved.batteryMenu.draining == .init(format: .time, style: .historyValue))
  #expect(saved.batteryMenu.charging == .init(format: .percent, style: .ring))
  #expect(saved.batteryMenu.charged == BatteryMenuSettings().charged)
  #expect(saved.batteryMenu.externalPower.style == .stacked)
  #expect(saved.theme == .dark && saved.worldClockNames["UTC"] == "Build server")
  #expect(!saved.alerts && !saved.calendarEvents && !saved.weather.enabled && !saved.publicIPChecks)
  #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved)) == saved)
}

@Test func batteryStateHistoriesStayAvailableAcrossTransitionsButNeverRequestHiddenReadouts() {
  var settings = Settings()
  settings.readouts = [.battery]
  settings.batteryMenu.customizeStates = true
  settings.batteryMenu.charging.style = .historyValue
  #expect(settings.needsMenuBarHistory)
  #expect(settings.batteryMenu.preset(for: battery(), defaultStyle: .ring).style == .stacked)
  #expect(
    settings.batteryMenu.preset(for: battery(external: true, charging: true), defaultStyle: .ring)
      .style == .historyValue)
  settings.batteryMenu.customizeStates = false
  #expect(!settings.needsMenuBarHistory)
  settings.styles["battery"] = .history
  #expect(settings.needsMenuBarHistory)
  settings.batteryMenu.customizeStates = true
  settings.batteryMenu.charging.style = .stacked
  #expect(settings.needsMenuBarHistory)  // The no-reading fallback still uses the base style.
  settings.readouts = [.cpu]
  #expect(!settings.needsMenuBarHistory)
  settings.batteryMenu.customizeStates = true
  settings.batteryMenu.draining.style = .cores
  #expect(settings.batteryMenu.preset(for: battery(), defaultStyle: .ring).style == .stacked)
}
