import Foundation
import Testing

@testable import TinyStatsCore

@Test func menuBarLayoutAddsRemovesAndMovesAtOriginalInsertionBoundaries() {
  var settings = Settings()
  func customize(_ module: Module, action: MenuBarLayoutAction) -> Bool {
    settings.customizeReadout(module, action: action)
  }
  #expect(customize(.gpu, action: .add(at: 1)))
  #expect(settings.readouts == [.cpu, .gpu, .memory, .network])
  #expect(customize(.cpu, action: .move(to: 3)))
  #expect(settings.readouts == [.gpu, .memory, .cpu, .network])
  #expect(customize(.network, action: .move(to: 0)))
  #expect(settings.readouts == [.network, .gpu, .memory, .cpu])
  #expect(!customize(.gpu, action: .move(to: 2)))
  #expect(!customize(.overview, action: .add(at: 0)))
  #expect(customize(.memory, action: .remove))
  #expect(settings.readouts == [.network, .gpu, .cpu])
  #expect(customize(.gpu, action: .toggle))
  #expect(customize(.network, action: .remove))
  #expect(settings.readouts == [.cpu])
  #expect(!customize(.cpu, action: .remove))
  #expect(!customize(.cpu, action: .toggle))
  #expect(!customize(.gpu, action: .remove))
  #expect(customize(.weather, action: .add(at: -999)))
  #expect(!settings.weather.enabled)
  #expect(customize(.clock, action: .add(at: 999)))
  #expect(settings.readouts == [.weather, .cpu, .clock])
}

@Test func menuBarLayoutFallbackMovesAndRoundTripsTheExistingSettingsKey() throws {
  let suite = "TinyStats-layout-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  var settings = Settings()
  func customize(_ module: Module, action: MenuBarLayoutAction) -> Bool {
    settings.customizeReadout(module, action: action)
  }
  settings.weather.enabled = false
  settings.persistHistory = false
  settings.styles["cpu"] = .cores
  settings.appearances["memory"] = .init(size: .large)
  let original = settings
  for (action, order) in [
    (MenuBarLayoutAction.left, [Module.cpu, .network, .memory]),
    (.start, [.network, .cpu, .memory]),
    (.right, [.cpu, .network, .memory]),
    (.end, [.cpu, .memory, .network]),
  ] {
    #expect(customize(.network, action: action))
    #expect(settings.readouts == order)
    settings.save(to: defaults)
    #expect(Settings.load(from: defaults) == settings)
  }
  #expect(settings == original)
  #expect(!customize(.network, action: .right))
  #expect(!customize(.gpu, action: .start))
}

@Test func menuBarLayoutMigratesLegacyAndMalformedSelectionsWithoutEnablingExtraReadouts() throws {
  for separate in [true, false] {
    let json = """
      {"separateItems":\(separate),"readouts":["weather","sensors","cpu"],
      "weather":{"enabled":false},"persistHistory":false,"styles":{"cpu":"ring"}}
      """
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.readouts == [.weather, .sensors, .cpu] && settings.separateItems == separate)
    #expect(
      !settings.weather.enabled && !settings.persistHistory && settings.style(for: .cpu) == .ring)
    #expect(
      try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
  }
  for (raw, expected) in [
    (#"["network","future","memory","overview","network"]"#, [Module.network, .memory]),
    (#"["weather",false,"cpu"]"#, [.weather, .cpu]),
    ("false", [.cpu]), ("null", [.cpu]), ("[]", [.cpu]),
  ] {
    let settings = try JSONDecoder().decode(Settings.self, from: Data("{\"readouts\":\(raw)}".utf8))
    #expect(settings.readouts == expected)
    #expect(!settings.weather.enabled)
  }
  #expect(
    try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).readouts == Settings().readouts)
}

@Test func menuBarLayoutAdoptsCompleteLegacyNativeOrderWithoutLosingChoices() throws {
  var settings = try JSONDecoder().decode(
    Settings.self,
    from: Data(
      #"{"readouts":["cpu","weather","network"],"styles":{"cpu":"cores"},"persistHistory":false,"weather":{"enabled":false}}"#
        .utf8))
  let initial = settings
  func adopt(_ order: [Module]) -> Bool { settings.adoptNativeReadoutOrder(order) }
  for partial in [[Module.cpu], [.cpu, .cpu, .network], [.cpu, .memory, .network], []] {
    #expect(!adopt(partial))
    #expect(settings == initial)
  }
  #expect(adopt([.network, .cpu, .weather]))
  #expect(!adopt([.network, .cpu, .weather]))
  var expected = initial
  expected.readouts = [.network, .cpu, .weather]
  #expect(settings == expected)
  #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == expected)
}
