import AppKit
import TinyStatsCore

@MainActor final class WeatherSettingsController: NSWindowController, NSWindowDelegate {
  var onChange: ((WeatherSettings) -> Void)?
  var onClose: (() -> Void)?
  private var settings: WeatherSettings
  private let source = NSPopUpButton()
  private var cities: [WeatherLocation] = []
  private let name = NSTextField(string: "")
  private let latitude = NSTextField(string: "")
  private let longitude = NSTextField(string: "")
  private let zone = NSTextField(string: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let citiesStatus = NSTextField(wrappingLabelWithString: "")
  private var savedDraft: [String] = []
  private var draft: [String] {
    [
      source.titleOfSelectedItem ?? "", name.stringValue,
      latitude.stringValue, longitude.stringValue, zone.stringValue,
    ]
  }
  init(settings: WeatherSettings, cities: [WeatherLocation] = []) {
    self.settings = settings
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "TinyStats Weather Locations"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    window.contentView = SystemSettingsBackgroundView(frame: window.contentView?.bounds ?? .zero)
    guard let content = window.contentView else { return }
    func add(_ view: NSView, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
      view.frame = .init(x: x, y: y, width: width, height: height)
      content.addSubview(view)
    }
    let heading = NSTextField(labelWithString: "Weather locations")
    heading.font = .systemFont(ofSize: 19, weight: .semibold)
    add(heading, 24, 588, 570, 30)
    let intro = NSTextField(
      wrappingLabelWithString:
        "Choose a location or enter custom coordinates. Enable Weather and allow location access on the main Weather tab. Forecast requests send rounded coordinates and your connection's IP address to api.met.no, including with details closed."
    )
    intro.font = .systemFont(ofSize: 12)
    intro.textColor = .secondaryLabelColor
    add(intro, 24, 506, 568, 72)
    add(NSTextField(labelWithString: "Location source"), 24, 473, 170, 22)
    source.target = self
    source.action = #selector(sourceChanged)
    source.setAccessibilityLabel("Weather location source")
    add(source, 202, 470, 390, 26)
    updateCities(cities)
    source.selectItem(at: settings.source == .currentLocation ? 0 : 1)
    name.stringValue = settings.location?.name ?? ""
    latitude.stringValue =
      settings.location.map {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0.latitude)
      } ?? ""
    longitude.stringValue =
      settings.location.map {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0.longitude)
      } ?? ""
    zone.stringValue = settings.location?.timeZone ?? TimeZone.current.identifier
    name.placeholderString = "Optional display name"
    latitude.placeholderString = "Decimal degrees, e.g. 60.100"
    longitude.placeholderString = "Decimal degrees, e.g. 9.580"
    zone.placeholderString = "IANA zone, e.g. Europe/Oslo"
    for (title, field, y) in [
      ("Location name", name, 390), ("Latitude (−90…90)", latitude, 353),
      ("Longitude (−180…180)", longitude, 316), ("Forecast time zone", zone, 279),
    ] {
      add(NSTextField(labelWithString: title), 24, y + 3, 170, 22)
      field.setAccessibilityLabel(title)
      add(field, 202, y, 390, 26)
    }
    let apply = NSButton(title: "Apply location", target: self, action: #selector(apply))
    apply.bezelStyle = .rounded
    apply.keyEquivalent = "\r"
    add(apply, 426, 233, 166, 28)
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    message.stringValue =
      "Apply changes the location only. Weather's enabled state stays unchanged."
    add(message, 24, 157, 568, 36)
    citiesStatus.font = .systemFont(ofSize: 11)
    citiesStatus.textColor = .secondaryLabelColor
    add(citiesStatus, 24, 196, 568, 30)
    let privacy = NSTextField(
      wrappingLabelWithString:
        "Coordinates are rounded to three decimals and saved locally with the display name/time zone. Forecasts stay in memory (up to 256 points). Requests normally wait at least 30 minutes, plus provider cache expiry and a small delay; edits cannot bypass rate limits. Pause/sleep cancel active requests."
    )
    privacy.font = .systemFont(ofSize: 11)
    privacy.textColor = .secondaryLabelColor
    add(privacy, 24, 89, 568, 78)
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.stringValue = settings.enabled ? "Waiting for forecast" : "Weather is off"
    add(status, 24, 55, 568, 30)
    let attribution = NSButton(
      title: "Data from MET Norway · CC BY 4.0", target: self, action: #selector(showLicense))
    attribution.isBordered = false
    attribution.contentTintColor = .linkColor
    add(attribution, 18, 15, 340, 28)
    let terms = NSButton(
      title: "Provider terms & privacy", target: self, action: #selector(showTerms))
    terms.isBordered = false
    terms.contentTintColor = .linkColor
    add(terms, 365, 15, 232, 28)
    let form = SystemSettingsForm.self
    _ = SystemSettingsForm(
      in: content,
      views: [
        intro, form.text("Location", heading: true),
        form.group([
          form.row("Source", source, width: 330),
          form.row("Location name", name, width: 330),
          form.row("Latitude (−90…90)", latitude, width: 330),
          form.row("Longitude (−180…180)", longitude, width: 330),
          form.row("Forecast time zone", zone, width: 330),
          form.row("", apply),
        ]), citiesStatus, message, privacy, status,
        form.group([form.row("", attribution), form.row("", terms)]),
      ])
    updateFieldAvailability()
    savedDraft = draft
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let field = client as? NSTextField,
      [name, latitude, longitude, zone].contains(where: { $0 === field })
    else { return nil }
    return LiteralFieldEditor.prepare(in: sender)
  }
  func windowWillClose(_ notification: Notification) { onClose?() }
  func updateSettings(_ value: WeatherSettings) {
    let edited = draft != savedDraft
    settings = value
    if !edited { showSavedSettings() }
  }
  private func showSavedSettings() {
    source.selectItem(at: settings.source == .currentLocation ? 0 : 1)
    name.stringValue = settings.location?.name ?? ""
    latitude.stringValue = settings.location.map { String($0.latitude) } ?? ""
    longitude.stringValue = settings.location.map { String($0.longitude) } ?? ""
    zone.stringValue = settings.location?.timeZone ?? TimeZone.current.identifier
    updateFieldAvailability()
    savedDraft = draft
  }
  func updateCities(_ cities: [WeatherLocation]) {
    if self.cities == Array(cities.prefix(SystemWeatherCities.cityLimit)), source.numberOfItems > 0
    {
      return
    }
    let selectedIndex = source.indexOfSelectedItem
    let selectedCity =
      self.cities.indices.contains(selectedIndex - 2)
      ? self.cities[selectedIndex - 2] : nil
    self.cities = Array(cities.prefix(SystemWeatherCities.cityLimit))
    source.removeAllItems()
    for title in ["Current location", "Manual coordinates"]
      + WeatherCityMenu.titles(self.cities).map({ "Weather · \($0)" })
    {
      source.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }
    source.selectItem(
      at: selectedCity.flatMap { self.cities.firstIndex(of: $0).map { $0 + 2 } }
        ?? (selectedIndex == 0 ? 0 : 1))
  }
  func updateCitiesStatus(_ text: String) { citiesStatus.stringValue = text }
  func updateCurrentLocation(_ value: WeatherSettings, status: String) {
    updateSettings(value)
    if source.indexOfSelectedItem == 0 { message.stringValue = status }
  }
  private func updateFieldAvailability() {
    for field in [name, latitude, longitude, zone] {
      field.isEnabled = source.indexOfSelectedItem != 0
    }
  }
  @objc private func sourceChanged() {
    let index = source.indexOfSelectedItem - 2
    if cities.indices.contains(index) {
      let city = cities[index]
      name.stringValue = city.name
      latitude.stringValue = String(city.latitude)
      longitude.stringValue = String(city.longitude)
      zone.stringValue = city.timeZone
    }
    updateFieldAvailability()
  }
  func update(_ snapshot: WeatherSnapshot, uptime: Double, suspended: Bool = false) {
    if suspended {
      status.stringValue = "Paused · weather requests stopped"
      return
    }
    guard snapshot.settings == settings, settings.enabled else {
      status.stringValue = settings.enabled ? "Waiting for forecast" : "Weather is off"
      return
    }
    var text = snapshot.checking ? "Checking MET Norway…" : snapshot.reason
    if let age = snapshot.checkedAge(at: uptime) { text += " · checked " + age }
    if let wait = snapshot.requestWait(at: uptime) { text += " · next request " + wait }
    status.stringValue = text
  }
  @objc private func apply() {
    var next = settings
    let latText = latitude.stringValue.trimmingCharacters(in: .whitespaces)
    let lonText = longitude.stringValue.trimmingCharacters(in: .whitespaces)
    if source.indexOfSelectedItem == 0 {
      next.source = .currentLocation
      if settings.source != .currentLocation { next.location = nil }
    } else if let lat = Double(latText), let lon = Double(lonText),
      let chosen = WeatherLocation(
        latitude: lat, longitude: lon, name: name.stringValue,
        timeZone: zone.stringValue.trimmingCharacters(in: .whitespaces)
      ).validated
    {
      next.source = .manual
      next.location = chosen
    } else {
      message.textColor = .systemRed
      message.stringValue =
        "Enter valid decimal coordinates and an IANA time zone. Nothing was applied."
      return
    }
    next.revision = UUID().uuidString
    next.validate()
    settings = next
    if let chosen = next.location {
      latitude.stringValue = String(
        format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), chosen.latitude)
      longitude.stringValue = String(
        format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), chosen.longitude)
      name.stringValue = chosen.name
      zone.stringValue = chosen.timeZone
    }
    onChange?(settings)
    showSavedSettings()
    message.textColor = .secondaryLabelColor
    message.stringValue =
      next.enabled
      ? "Applied. Forecast appears when the provider and rate limits allow."
      : "Saved. Weather requests are off."
  }
  @objc private func showLicense() {
    NSWorkspace.shared.open(URL(string: "https://api.met.no/doc/License")!)
  }
  @objc private func showTerms() {
    NSWorkspace.shared.open(URL(string: "https://api.met.no/doc/TermsOfService")!)
  }
}
