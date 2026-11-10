import Foundation
import Testing

@testable import TinyStatsCore

// MARK: - Fixtures: verbatim/representative `pmset -g custom` and `pmset -g cap` text.

/// Captured read-only on the development Mac mini M4 (Mac16,10), macOS 27.2.
let macMiniM4Custom = """
  AC Power:
   Sleep On Power Button 1
   autorestartatconnect 0
   lowpowermode         0
   standby              0
   ttyskeepawake        1
   powernap             1
   displaysleep         10
   womp                 1
   networkoversleep     0
   sleep                0
   tcpkeepalive         1
   autorestart          1
   disksleep            10
  """
let macMiniM4Cap = """
  Capabilities for AC Power:
   displaysleep
   disksleep
   sleep
   womp
   autorestart
   autorestartatconnect
   standby
   powernap
   ttyskeepawake
   tcpkeepalive
   lowpowermode
  """
/// Representative MacBook Air layout (Low Power Mode per source, no High Power).
let macBookAirCustom = """
  Battery Power:
   lidwake              1
   lowpowermode         1
   standbydelaylow      10800
   displaysleep         2
   sleep                1
  AC Power:
   lidwake              1
   lowpowermode         0
   displaysleep         10
   sleep                1
  """
let macBookAirCap = """
  Capabilities for Battery Power:
   displaysleep
   lidwake
   lowpowermode
  """
/// Representative MacBook Pro M4 Max layout with the unified `powermode` key.
let macBookProMaxCustom = """
  Battery Power:
   lowpowermode         1
   powermode            1
   displaysleep         2
  AC Power:
   lowpowermode         0
   powermode            2
   displaysleep         10
  UPS Power:
   powermode            0
  """
let macBookProMaxCap = """
  Capabilities for AC Power:
   displaysleep
   lowpowermode
   powermode
  """
/// Representative older (macOS 14-era) layout with separate `highpowermode`.
let legacyHighPowerCustom = """
  Battery Power:
   lowpowermode         0
   highpowermode        0
  AC Power:
   lowpowermode         0
   highpowermode        1
  """
let legacyHighPowerCap = """
  Capabilities for AC Power:
   lowpowermode
   highpowermode
  """

@Test func energyModeParsesMacMiniAsLowPowerOnlyOnAdapter() {
  let reading = EnergyModeParser.parse(custom: macMiniM4Custom, capabilities: macMiniM4Cap)
  #expect(
    reading
      == .available(
        .init(layout: .lowPowerOnly, sources: [.adapter], modes: [.adapter: .automatic]))
  )
  if case .available(let status) = reading {
    #expect(!status.supportsHigh)
    #expect(status.layout.modes == [.low, .automatic])
  }
}

@Test func energyModeParsesMacBookAirPerSourceLowPower() {
  let reading = EnergyModeParser.parse(custom: macBookAirCustom, capabilities: macBookAirCap)
  #expect(
    reading
      == .available(
        .init(
          layout: .lowPowerOnly, sources: [.adapter, .battery],
          modes: [.adapter: .automatic, .battery: .low])))
}

@Test func energyModeParsesUnifiedPowerModeWithHighAndIgnoresUPS() {
  let reading = EnergyModeParser.parse(custom: macBookProMaxCustom, capabilities: macBookProMaxCap)
  #expect(
    reading
      == .available(
        .init(
          layout: .unified, sources: [.adapter, .battery],
          modes: [.adapter: .high, .battery: .low])))
  if case .available(let status) = reading {
    #expect(status.layout.modes == [.low, .automatic, .high])
  }
}

@Test func energyModeParsesLegacyHighPowerKeys() {
  let reading = EnergyModeParser.parse(
    custom: legacyHighPowerCustom, capabilities: legacyHighPowerCap)
  #expect(
    reading
      == .available(
        .init(
          layout: .legacyHighPower, sources: [.adapter, .battery],
          modes: [.adapter: .high, .battery: .automatic])))
}

@Test func energyModeGarbageEmptyAndOversizedOutputFailClosed() {
  #expect(EnergyModeParser.parse(custom: "", capabilities: "") == .unsupported)
  #expect(
    EnergyModeParser.parse(custom: "garbage\n\u{0}::\n", capabilities: "%%%") == .unsupported)
  // A capability without any per-source profile is not offered.
  #expect(EnergyModeParser.parse(custom: "", capabilities: macBookProMaxCap) == .unsupported)
  let huge = String(repeating: "x", count: EnergyModeParser.maximumBytes + 1)
  #expect(EnergyModeParser.parse(custom: huge, capabilities: "") == .unavailable)
}

@Test func energyModeUnknownOrConflictingValuesStayUnavailableNotAutomatic() {
  let unknown = EnergyModeParser.parse(
    custom: "AC Power:\n powermode 7\n", capabilities: "Capabilities for AC Power:\n powermode\n")
  #expect(unknown == .available(.init(layout: .unified, sources: [.adapter], modes: [:])))
  let conflicting = EnergyModeParser.parse(
    custom: "AC Power:\n lowpowermode 1\n highpowermode 1\n", capabilities: "")
  #expect(
    conflicting == .available(.init(layout: .legacyHighPower, sources: [.adapter], modes: [:])))
  let missingValue = EnergyModeParser.parse(
    custom: "AC Power:\n lowpowermode\n", capabilities: " lowpowermode\n")
  #expect(missingValue == .available(.init(layout: .lowPowerOnly, sources: [.adapter], modes: [:])))
}

@Test func energyModePartialLegacyReadingsNeverBecomeAutomatic() {
  typealias P = EnergyModeParser
  // Legacy pair: a missing counterpart could still mean Low or High Power.
  #expect(P.mode(["highpowermode": 0], layout: .legacyHighPower) == nil)
  #expect(P.mode(["lowpowermode": 0], layout: .legacyHighPower) == nil)
  #expect(P.mode(["lowpowermode": 0, "highpowermode": 0], layout: .legacyHighPower) == .automatic)
  // A set flag is decisive even when its counterpart is missing.
  #expect(P.mode(["highpowermode": 1], layout: .legacyHighPower) == .high)
  #expect(P.mode(["lowpowermode": 1], layout: .legacyHighPower) == .low)
  // Unified capability without `powermode` in the section falls back to the same rule.
  #expect(P.mode(["lowpowermode": 0], layout: .unified) == nil)
  // Low-Power-only Macs have no counterpart, so `lowpowermode 0` is Automatic.
  #expect(P.mode(["lowpowermode": 0], layout: .lowPowerOnly) == .automatic)
  let partial = P.parse(
    custom: "AC Power:\n highpowermode 0\nBattery Power:\n lowpowermode 0\n", capabilities: "")
  #expect(
    partial
      == .available(.init(layout: .legacyHighPower, sources: [.adapter, .battery], modes: [:])))
}

@Test func energyModeCommandVectorsAreExactPerSourceModeAndLayout() {
  typealias C = EnergyModeCommand
  #expect(C.arguments(mode: .high, source: .adapter, layout: .unified) == ["-c", "powermode", "2"])
  #expect(C.arguments(mode: .low, source: .battery, layout: .unified) == ["-b", "powermode", "1"])
  #expect(
    C.arguments(mode: .automatic, source: .battery, layout: .unified) == ["-b", "powermode", "0"])
  #expect(
    C.arguments(mode: .high, source: .adapter, layout: .legacyHighPower)
      == ["-c", "lowpowermode", "0", "highpowermode", "1"])
  #expect(
    C.arguments(mode: .low, source: .battery, layout: .legacyHighPower)
      == ["-b", "lowpowermode", "1", "highpowermode", "0"])
  #expect(
    C.arguments(mode: .automatic, source: .adapter, layout: .legacyHighPower)
      == ["-c", "lowpowermode", "0", "highpowermode", "0"])
  #expect(
    C.arguments(mode: .low, source: .adapter, layout: .lowPowerOnly)
      == ["-c", "lowpowermode", "1"])
  #expect(
    C.arguments(mode: .automatic, source: .battery, layout: .lowPowerOnly)
      == ["-b", "lowpowermode", "0"])
  #expect(C.arguments(mode: .high, source: .adapter, layout: .lowPowerOnly) == nil)
  for layout in [EnergyModeKeyLayout.unified, .legacyHighPower, .lowPowerOnly] {
    for source in PowerSourceKind.allCases {
      for mode in EnergyMode.allCases {
        if let vector = C.arguments(mode: mode, source: source, layout: layout) {
          #expect(C.isAllowed(vector))
        }
      }
    }
  }
  #expect(!C.isAllowed(["-a", "powermode", "2"]))
  #expect(!C.isAllowed(["-c", "powermode", "2; rm -rf /"]))
  #expect(!C.isAllowed(["-c", "sleep", "0"]))
  #expect(!C.isAllowed(["-c"]))
  // Malformed vectors built only from allowed tokens are still rejected.
  for malformed in [
    ["-c", "powermode", "2", "-b", "0"],
    ["-c", "powermode", "powermode"],
    ["-b", "lowpowermode", "2"],
    ["-c", "highpowermode", "1"],
    ["-c", "highpowermode", "0", "lowpowermode", "1"],
    ["-b", "lowpowermode", "1", "highpowermode", "1"],
    ["-c", "lowpowermode", "0", "highpowermode"],
    ["-c", "-b", "powermode"],
    ["powermode", "-c", "1"],
    ["-c", "powermode", "3"],
  ] {
    #expect(!C.isAllowed(malformed), "\(malformed)")
  }
  #expect(C.generatedVectors.count == 16)
}

// MARK: - Power item visibility preferences and state machine

@Test func powerVisibilityDefaultsPreserveTodayAndMigrateOldProfiles() throws {
  #expect(Settings().batteryMenu.visibility == .init(onAdapter: true, onBattery: true))
  // A 0.37.2 profile: Power customised, no visibility key.
  let old = #"""
    {"readouts":["cpu","battery"],"batteryMenu":{"format":"time","customizeStates":true,
    "draining":{"format":"percent","style":"ring"}},"styles":{"battery":"pie"}}
    """#
  let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
  #expect(settings.batteryMenu.visibility == .init())
  #expect(settings.batteryMenu.format == .time)
  #expect(settings.batteryMenu.customizeStates)
  #expect(settings.batteryMenu.draining == .init(format: .percent, style: .ring))
  #expect(settings.readouts == [.cpu, .battery])
  #expect(settings.style(for: .battery) == .pie)
}

@Test func powerVisibilityRoundTripsAndMalformedFieldsRecoverIndependently() throws {
  var settings = Settings()
  settings.batteryMenu.visibility = .init(onAdapter: false, onBattery: true)
  let data = try JSONEncoder().encode(settings)
  #expect(
    try JSONDecoder().decode(Settings.self, from: data).batteryMenu.visibility
      == .init(
        onAdapter: false, onBattery: true))
  func decode(_ json: String) throws -> PowerItemVisibility {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).batteryMenu.visibility
  }
  #expect(
    try decode(#"{"batteryMenu":{"visibility":{"onAdapter":"no","onBattery":false}}}"#)
      == .init(onAdapter: true, onBattery: false))
  #expect(
    try decode(#"{"batteryMenu":{"visibility":{"onAdapter":false,"onBattery":3}}}"#)
      == .init(onAdapter: false, onBattery: true))
  #expect(try decode(#"{"batteryMenu":{"visibility":"hidden"}}"#) == .init())
  // A damaged visibility value must not reset other Power choices.
  let mixed = try JSONDecoder().decode(
    Settings.self,
    from: Data(#"{"batteryMenu":{"format":"power","visibility":[1]}}"#.utf8))
  #expect(mixed.batteryMenu.format == .power)
}

private func reading(external: Bool) -> BatteryReading {
  .init(
    name: "Internal", percent: 70, charging: false, externalPower: external, minutesRemaining: nil,
    cycles: nil, health: nil, watts: nil)
}

@Test func powerVisibilityStateMachineCoversEverySourceAndChoice() {
  let sources: [(String, [BatteryReading], PowerSourceKind)] = [
    ("adapter", [reading(external: true)], .adapter),
    ("battery", [reading(external: false)], .battery),
    ("no battery", [], .adapter),
  ]
  for (name, batteries, source) in sources {
    #expect(PowerSourceKind.current(batteries) == source, "\(name)")
    for onAdapter in [true, false] {
      for onBattery in [true, false] {
        var settings = Settings()
        settings.readouts = [.cpu, .battery, .memory]
        settings.batteryMenu.visibility = .init(onAdapter: onAdapter, onBattery: onBattery)
        let visible = source == .adapter ? onAdapter : onBattery
        #expect(
          settings.powerHiddenModules(batteries: batteries) == (visible ? [] : [.battery]),
          "\(name) adapter=\(onAdapter) battery=\(onBattery)")
        #expect(
          settings.presentedReadouts(batteries: batteries)
            == (visible ? [.cpu, .battery, .memory] : [.cpu, .memory]))
        // Hidden by source is not disabled: the enabled list is untouched.
        #expect(settings.readouts == [.cpu, .battery, .memory])
      }
    }
  }
  // An empty list is either a desktop (never confirmed a battery) or a failed read on a
  // laptop: only the latter keeps the last confirmed source.
  #expect(PowerSourceKind.confirmed([]) == nil)
  #expect(PowerSourceKind.current([], lastKnown: nil) == .adapter, "desktop")
  #expect(PowerSourceKind.current([], lastKnown: .battery) == .battery, "failed read on battery")
  #expect(PowerSourceKind.current([], lastKnown: .adapter) == .adapter, "failed read on adapter")
  #expect(PowerSourceKind.current([reading(external: true)], lastKnown: .battery) == .adapter)
  var laptop = Settings()
  laptop.readouts = [.cpu, .battery]
  laptop.batteryMenu.visibility = .init(onAdapter: false, onBattery: true)
  #expect(laptop.powerHiddenModules(batteries: [], lastKnown: .battery).isEmpty)
  #expect(laptop.presentedReadouts(batteries: [], lastKnown: .battery) == [.cpu, .battery])
  #expect(laptop.powerHiddenModules(batteries: [], lastKnown: nil) == [.battery])
  var disabled = Settings()
  disabled.readouts = [.cpu]
  disabled.batteryMenu.visibility = .init(onAdapter: false, onBattery: false)
  #expect(disabled.powerHiddenModules(batteries: []).isEmpty)
}
