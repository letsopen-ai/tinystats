import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

@MainActor private func weatherDescendants(_ view: NSView) -> [NSView] {
  var result = view.subviews
  for child in view.subviews { result.append(contentsOf: weatherDescendants(child)) }
  return result
}
@MainActor private func weatherActivate(_ control: NSControl) throws {
  let action = try #require(control.action)
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
}
@MainActor private func weatherFixture() -> (Settings, Snapshot) {
  var settings = Settings()
  settings.weather.enabled = true
  settings.weather.location = .init(
    latitude: 60, longitude: 10, name: "Example location", timeZone: "Europe/Oslo")
  settings.weather.revision = "fixture"
  var snapshot = Snapshot()
  snapshot.timestamp = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
  snapshot.uptime = 10
  snapshot.weather.settings = settings.weather
  snapshot.weather.receivedAt = 5
  snapshot.weather.reason = "MET Norway forecast"
  snapshot.weather.forecast = .init(
    generatedAt: snapshot.timestamp,
    points: (0..<72).map { index in
      .init(
        date: snapshot.timestamp.addingTimeInterval(Double(index) * 3600),
        celsius: Double(index) - 2, humidity: 0, windMetersPerSecond: 0, symbol: "clearsky_day",
        precipitationMM: 0, periodHours: 1)
    })
  return (settings, snapshot)
}

@Test @MainActor func customWeatherLocationValidatesDraftWithoutEnablingRequests() throws {
  let controller = WeatherSettingsController(settings: .init())
  let root = try #require(controller.window?.contentView)
  let children = weatherDescendants(root)
  let buttons = children.compactMap { $0 as? NSButton }
  #expect(
    !buttons.contains {
      $0.title == "Enable weather requests" || $0.title == "Allow current location…"
    })
  let apply = try #require(buttons.first { $0.title == "Apply location" })
  let fields = children.compactMap { $0 as? NSTextField }.filter(\.isEditable)
  let lat = try #require(fields.first { $0.accessibilityLabel() == "Latitude (−90…90)" })
  let lon = try #require(fields.first { $0.accessibilityLabel() == "Longitude (−180…180)" })
  let zone = try #require(fields.first { $0.accessibilityLabel() == "Forecast time zone" })
  var changes: [WeatherSettings] = []
  controller.onChange = { changes.append($0) }
  lat.stringValue = "91"
  lon.stringValue = "9.58"
  zone.stringValue = "Europe/Oslo"
  try weatherActivate(apply)
  #expect(changes.isEmpty)
  #expect(
    children.compactMap { $0 as? NSTextField }.contains {
      $0.stringValue.contains("Nothing was applied")
    })
  lat.stringValue = "60.123456"
  try weatherActivate(apply)
  let chosen = try #require(changes.last)
  #expect(!chosen.enabled && chosen.location?.latitude == 60.123 && !chosen.revision.isEmpty)
  #expect(
    children.compactMap { $0 as? NSTextField }.contains {
      $0.stringValue.contains("api.met.no") && $0.stringValue.contains("IP address")
    })
}

@Test @MainActor
func weatherChildSettingsSurviveParentEditsAndForecastReadoutsRejectStaleOrWrongLocations() throws {
  _ = NSApplication.shared
  let (settings, snapshot) = weatherFixture()
  let parent = PreferencesController(
    settings: .init(), interfaces: [], snapshot: snapshot, history: [])
  parent.updateWeatherSettings(settings.weather)
  var saved: Settings?
  parent.onChange = { saved = $0 }
  let root = try #require(parent.window?.contentView)
  let fahrenheit = try #require(
    weatherDescendants(root).compactMap { $0 as? NSButton }.first { $0.title == "Use Fahrenheit" })
  fahrenheit.state = .on
  try weatherActivate(fahrenheit)
  #expect(saved?.weather == settings.weather)
  let text = MenuBarReadout.make(
    module: .weather, snapshot: snapshot, settings: settings, history: [])
  #expect(text.value == "-2°C" && text.symbol == "sun.max")
  var imperial = settings
  imperial.fahrenheit = true
  #expect(
    MenuBarReadout.make(module: .weather, snapshot: snapshot, settings: imperial, history: []).value
      == "28°F")
  var stale = snapshot
  stale.uptime = 11_000
  let unavailable = MenuBarReadout.make(
    module: .weather, snapshot: stale, settings: settings, history: [])
  #expect(unavailable.value == "—" && unavailable.symbol == "questionmark.circle")
  var other = settings
  other.weather.revision = "other"
  #expect(
    MenuBarReadout.make(module: .weather, snapshot: snapshot, settings: other, history: []).value
      == "—")
  #expect(!MenuBarStyle.available(for: .weather).contains(.pie))
}

@Test @MainActor func weatherDetailsRenderForecastIntervalsAttributionAndStaleState() throws {
  _ = NSApplication.shared
  let (settings, snapshot) = weatherFixture()
  let controller = DetailController()
  controller.settings = settings
  controller.snapshot = snapshot
  controller.showsAllReadings = true
  controller.selected = .weather
  let table = try #require(
    controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  func rows() -> [(String, String)] {
    (0..<table.numberOfRows).map { row in
      (
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
          ?? "",
        (table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
          ?? ""
      )
    }
  }
  #expect(rows().contains { $0.0 == "DATA FROM MET NORWAY · CC BY 4.0" })
  #expect(rows().contains { $0.0 == "DAILY · SAMPLED LOW / HIGH" })
  #expect(rows().contains { $0.0 == "Precipitation · next 1h" && $0.1 == "0.0 mm" })
  let chart = try #require(controller.view.subviews.compactMap { $0 as? ChartView }.first)
  #expect(chart.caption?.contains("forecast") == true && chart.series.count == 1)
  #expect((chart.accessibilityValue() as? String)?.contains("Window end 46.00 °C") == true)
  #expect((chart.accessibilityValue() as? String)?.contains("window 2d 0h") == true)
  controller.selected = .cpu
  #expect(chart.newestValueLabel == "Latest")
  controller.snapshot.weather.nextRequestAt = .greatestFiniteMagnitude
  controller.selected = .weather
  #expect(rows().contains { $0.0 == "Next request" && $0.1 == ">1 year" })
  controller.snapshot.uptime = 11_000
  controller.selected = .weather
  #expect(rows().contains { $0.0 == "Cached forecast" && $0.1.contains("Stale") })
  #expect(!rows().contains { $0.0 == "UPCOMING MODEL TIMES" })
  #expect(chart.series.isEmpty)
}

@Test @MainActor func weatherLocationApplyReadsTheActiveNativeFieldEditor() throws {
  let controller = WeatherSettingsController(settings: .init())
  defer { controller.close() }
  let window = try #require(controller.window)
  let children = weatherDescendants(try #require(window.contentView))
  let fields = children.compactMap { $0 as? NSTextField }.filter(\.isEditable)
  let lat = try #require(fields.first { $0.accessibilityLabel() == "Latitude (−90…90)" })
  let lon = try #require(fields.first { $0.accessibilityLabel() == "Longitude (−180…180)" })
  let zone = try #require(fields.first { $0.accessibilityLabel() == "Forecast time zone" })
  lat.stringValue = "60.1"
  lon.stringValue = "9.58"
  zone.stringValue = "Invalid/Zone"
  controller.showWindow(nil)
  #expect(window.makeFirstResponder(zone))
  let editor = try #require(zone.currentEditor() as? NSTextView)
  editor.insertText(
    "Europe/Oslo", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
  var saved: WeatherSettings?
  controller.onChange = { saved = $0 }
  let apply = try #require(
    children.compactMap { $0 as? NSButton }.first { $0.title == "Apply location" })
  try weatherActivate(apply)
  #expect(saved?.location?.timeZone == "Europe/Oslo" && saved?.enabled == false)
}

@Test @MainActor func weatherMenuLabelDescribesForecastAndKeepsMissingStatesHonest() throws {
  let (settings, original) = weatherFixture()
  for (symbol, label) in [
    ("clearsky_day", "Sunny"), ("clearsky_night", "Clear"), ("clearsky", "Clear"),
    ("partlycloudy_day", "Partly cloudy"), ("cloudy", "Cloudy"),
    ("heavyrain", "Rainy"), ("snow", "Snowy"), ("fog", "Foggy"),
    ("rainandthunder", "Thunderstorms"), ("future_code", "Unknown"),
  ] {
    var snapshot = original
    snapshot.weather.forecast?.points[0].symbol = symbol
    let reading = MenuBarReadout.make(
      module: .weather, snapshot: snapshot, settings: settings, history: [])
    #expect(reading.label == label && reading.value == "-2°C")
  }
  var snapshot = original
  snapshot.uptime = 11_000
  #expect(
    MenuBarReadout.make(module: .weather, snapshot: snapshot, settings: settings, history: []).label
      == "Unavailable")
  var off = settings
  off.weather.enabled = false
  #expect(
    MenuBarReadout.make(module: .weather, snapshot: original, settings: off, history: []).label
      == "Off")
  var current = settings
  current.weather = .currentLocationDefault
  let pending = MenuBarReadout.make(
    module: .weather, snapshot: original, settings: current, history: [])
  #expect(
    pending.label == "Set location" && pending.value == "—"
      && pending.symbol == "questionmark.circle")
  snapshot = original
  snapshot.weather.forecast = nil
  snapshot.weather.checking = true
  #expect(
    MenuBarReadout.make(module: .weather, snapshot: snapshot, settings: settings, history: []).label
      == "Updating")
}
