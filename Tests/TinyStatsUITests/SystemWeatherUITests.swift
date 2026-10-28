import AppKit
import Foundation
import Testing
import TinyStatsCore

@testable import TinyStats

@MainActor private func weatherSourceViews(_ view: NSView) -> [NSView] {
  var result = view.subviews
  for child in view.subviews { result.append(contentsOf: weatherSourceViews(child)) }
  return result
}
@MainActor private func weatherSourceAction(_ control: NSControl) throws {
  let action = try #require(control.action)
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
}
private let importedWeatherCity = WeatherLocation(
  latitude: 59.914, longitude: 10.752, name: "Oslo example", timeZone: "Europe/Oslo")

@Test @MainActor func weatherLocationEditorChoosesCitiesWithoutChangingEnablement()
  throws
{
  let controller = WeatherSettingsController(
    settings: .currentLocationDefault, cities: [importedWeatherCity])
  defer { controller.close() }
  let window = try #require(controller.window)
  let root = try #require(window.contentView)
  let views = weatherSourceViews(root)
  let source = try #require(
    views.compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "Weather location source"
    })
  let latitude = try #require(
    views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Latitude (−90…90)" }
  )
  let apply = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Apply location" })
  var saved: WeatherSettings?
  controller.onChange = { saved = $0 }
  #expect(source.indexOfSelectedItem == 0 && !latitude.isEnabled)
  source.selectItem(at: 2)
  try weatherSourceAction(source)
  #expect(latitude.isEnabled && latitude.stringValue == "59.914")
  let editor = try #require(window.fieldEditor(true, for: latitude) as? NSTextView)
  #expect(
    !editor.isAutomaticDashSubstitutionEnabled && !editor.isAutomaticSpellingCorrectionEnabled)
  #expect(editor.enabledTextCheckingTypes == 0 && editor.allowsUndo)
  controller.updateCities([importedWeatherCity])
  #expect(source.indexOfSelectedItem == 2)
  try weatherSourceAction(apply)
  #expect(
    saved?.location == importedWeatherCity && saved?.source == .manual && saved?.enabled == true)
  source.selectItem(at: 0)
  try weatherSourceAction(source)
  try weatherSourceAction(apply)
  #expect(saved?.source == .currentLocation && saved?.location == nil && saved?.enabled == true)
}

@Test @MainActor func weatherCityPickerKeepsPendingSelectionDuringUnchangedSamplerUpdates() throws {
  let detail = DetailController()
  detail.settings.weather = .currentLocationDefault
  detail.weatherCities = [importedWeatherCity]
  detail.selected = .weather
  let root = detail.view
  let picker = try #require(
    weatherSourceViews(root).compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "Weather city"
    })
  #expect(picker.numberOfItems == 2 && picker.indexOfSelectedItem == 0)
  picker.selectItem(at: 1)
  detail.update(Snapshot(), history: [])
  #expect(picker.indexOfSelectedItem == 1)
  var choice: WeatherLocation?
  detail.onWeatherCity = { choice = $0 }
  try weatherSourceAction(picker)
  #expect(choice == importedWeatherCity)
  detail.selected = .cpu
  #expect(picker.isHidden)
}

@Test @MainActor func weatherSettingsFollowCanonicalCityWithoutClobberingAnEditedDraft() throws {
  let controller = WeatherSettingsController(settings: .currentLocationDefault)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let views = weatherSourceViews(root)
  let source = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
  let name = try #require(
    views.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "Location name"
    })
  let apply = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Apply location" })
  var canonical = WeatherSettings()
  canonical.enabled = true
  canonical.location = importedWeatherCity
  controller.updateSettings(canonical)
  #expect(source.indexOfSelectedItem == 1 && name.stringValue == importedWeatherCity.name)
  var saved: WeatherSettings?
  controller.onChange = { saved = $0 }
  try weatherSourceAction(apply)
  #expect(saved?.source == .manual && saved?.location == importedWeatherCity)
  name.stringValue = "Unsaved name"
  controller.updateSettings(.currentLocationDefault)
  #expect(name.stringValue == "Unsaved name" && source.indexOfSelectedItem == 1)
  var disabled = WeatherSettings.currentLocationDefault
  disabled.enabled = false
  controller.updateSettings(disabled)
  try weatherSourceAction(apply)
  #expect(
    saved?.source == .manual && saved?.location?.name == "Unsaved name" && saved?.enabled == false)
}

@Test @MainActor func sameNamedWeatherCitiesRetainTheirCoordinatesAndFollowingIndices() throws {
  let cities = [
    WeatherLocation(
      latitude: 45.515, longitude: -122.679, name: "Portland", timeZone: "America/Los_Angeles"),
    WeatherLocation(
      latitude: 43.659, longitude: -70.257, name: "Portland", timeZone: "America/New_York"),
    importedWeatherCity,
  ]
  let controller = WeatherSettingsController(settings: .currentLocationDefault, cities: cities)
  defer { controller.close() }
  let views = weatherSourceViews(try #require(controller.window?.contentView))
  let source = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
  let apply = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Apply location" })
  var saved: WeatherSettings?
  controller.onChange = { saved = $0 }
  #expect(source.numberOfItems == 5)
  #expect(Set(source.itemTitles).count == 5)
  for index in cities.indices {
    source.selectItem(at: index + 2)
    try weatherSourceAction(source)
    try weatherSourceAction(apply)
    #expect(saved?.location == cities[index])
  }
  source.selectItem(at: 3)
  try weatherSourceAction(source)
  controller.updateCities([cities[1], cities[2], cities[0]])
  #expect(source.indexOfSelectedItem == 2)
  try weatherSourceAction(apply)
  #expect(saved?.location == cities[1])
  let detail = DetailController()
  detail.settings.weather = .currentLocationDefault
  detail.weatherCities = cities
  detail.selected = .weather
  let picker = try #require(
    weatherSourceViews(detail.view).compactMap { $0 as? NSPopUpButton }.first)
  #expect(picker.numberOfItems == 4)
  #expect(Set(picker.itemTitles).count == 4)
  var chosen: WeatherLocation?
  detail.onWeatherCity = { chosen = $0 }
  for index in cities.indices {
    picker.selectItem(at: index + 1)
    try weatherSourceAction(picker)
    #expect(chosen == cities[index])
  }
}

@Test @MainActor func weatherMainTabOwnsEnablementAndExplicitLocationRequest() throws {
  let detail = DetailController()
  detail.settings.weather = .currentLocationDefault
  detail.selected = .weather
  let root = detail.view
  let views = weatherSourceViews(root)
  let enable = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Enable weather" })
  let allow = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Allow current location…" })
  let locations = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Locations & privacy…" })
  var requested = 0
  var edited = 0
  var changes: [Bool] = []
  detail.onWeatherEnabled = { changes.append($0) }
  detail.onWeatherLocationRequest = { requested += 1 }
  detail.onWeatherLocations = { edited += 1 }
  detail.update(Snapshot(), history: [])
  #expect(requested == 0 && changes.isEmpty && enable.state == .on)
  #expect(allow.isEnabled && !allow.isHidden)
  allow.performClick(nil)
  #expect(requested == 1)
  enable.state = .off
  try weatherSourceAction(enable)
  #expect(changes == [false])
  detail.settings.weather.enabled = false
  detail.update(Snapshot(), history: [])
  #expect(!allow.isEnabled)
  allow.performClick(nil)
  #expect(requested == 1)
  detail.settings.weather.enabled = true
  detail.settings.weather.source = .manual
  detail.settings.weather.location = importedWeatherCity
  detail.update(Snapshot(), history: [])
  #expect(allow.isHidden && requested == 1)
  locations.performClick(nil)
  #expect(edited == 1)
  let chart = try #require(root.subviews.compactMap { $0 as? ChartView }.first)
  #expect(chart.isHidden)
  let preferences = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  let settingsRoot = try #require(preferences.window?.contentView)
  #expect(
    !weatherSourceViews(settingsRoot).compactMap { $0 as? NSButton }.contains {
      $0.title == "Weather…"
    })
}
