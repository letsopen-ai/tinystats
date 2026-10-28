import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

@MainActor private final class DaylightFixtureBackground: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
  }
}

@Test @MainActor func weatherDaylightRendersOrdinaryPolarMissingAndShortIntervalsWithoutOverlap()
  throws
{
  let cases: [(String, Double?, Double, String, String, NSSize, NSAppearance.Name)] = [
    (
      "ordinary-compact-light", 40.713, -74.006, "America/New_York", "2026-10-25T16:00:00Z",
      .init(width: 520, height: 374), .aqua
    ),
    (
      "ordinary-compact-dark", 40.713, -74.006, "America/New_York", "2026-10-25T16:00:00Z",
      .init(width: 520, height: 374), .darkAqua
    ),
    (
      "ordinary-large-light", -43.95, -176.55, "Pacific/Chatham", "2026-12-21T00:00:00Z",
      .init(width: 1040, height: 714), .aqua
    ),
    (
      "ordinary-large-dark", -43.95, -176.55, "Pacific/Chatham", "2026-12-21T00:00:00Z",
      .init(width: 1040, height: 714), .darkAqua
    ),
    (
      "polar-summer", 69.649, 18.955, "Europe/Oslo", "2026-06-21T12:00:00Z",
      .init(width: 520, height: 374), .darkAqua
    ),
    (
      "polar-winter", 69.649, 18.955, "Europe/Oslo", "2026-12-21T12:00:00Z",
      .init(width: 520, height: 374), .aqua
    ),
    (
      "short-day", 67.398, 179, "UTC", "2026-12-21T12:00:00Z", .init(width: 520, height: 374), .aqua
    ),
    (
      "permission-missing", nil, 0, "UTC", "2026-10-25T12:00:00Z", .init(width: 520, height: 374),
      .darkAqua
    ),
  ]
  for (name, latitude, longitude, zone, date, size, appearance) in cases {
    var (settings, snapshot) = graphicalForecast()
    let now = ISO8601DateFormatter().date(from: date)!
    settings.weather.source = .currentLocation
    settings.weather.location = latitude.map {
      .init(latitude: $0, longitude: longitude, name: "Public synthetic fixture", timeZone: zone)
    }
    let delta = now.timeIntervalSince(snapshot.timestamp)
    if var forecast = snapshot.weather.forecast {
      forecast.generatedAt.addTimeInterval(delta)
      forecast.points = forecast.points.enumerated().map { index, value in
        var point = value
        point.date.addTimeInterval(delta)
        point.celsius = (name == "polar-winter" ? -12 : 12) + 6 * sin(Double(index) / 4)
        return point
      }
      snapshot.weather.forecast = latitude == nil ? nil : forecast
    }
    snapshot.weather.reason = "Forecast ready"
    snapshot.timestamp = now
    snapshot.weather.settings = settings.weather
    let root = DaylightFixtureBackground(frame: .init(origin: .zero, size: size))
    root.appearance = NSAppearance(named: appearance)
    let view = WeatherDashboardView(frame: root.bounds)
    root.addSubview(view)
    view.update(
      snapshot, settings: settings, paused: false, sourceStatus: "Location permission needed")
    if latitude != nil {
      #expect(view.showsSolar && view.solarFrame.maxX < view.dailyFrame.minX)
      #expect(view.solarFrame.contains(view.solarTrack))
      #expect(view.upcoming.count == 12 && view.visibleDays > 0)
    } else {
      #expect(!view.showsSolar && view.solarDay == nil && view.current == nil)
    }
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.effectiveAppearance.performAsCurrentDrawingAppearance {
      root.cacheDisplay(in: root.bounds, to: bitmap)
    }
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    if let path = ProcessInfo.processInfo.environment["TINYSTATS_DAYLIGHT_RENDER_PATH"] {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: directory.appendingPathComponent(name + ".png"))
    }
  }
}

@Test @MainActor func weatherDaylightUpdatesMinuteMarkerWithoutNewForecastBytes() throws {
  var (settings, snapshot) = graphicalForecast()
  settings.weather.location?.timeZone = "UTC"
  snapshot.weather.forecast = nil
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 374))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let first = view.solarDay
  let spoken = view.accessibilityValue() as? String
  snapshot.timestamp.addTimeInterval(60)
  #expect(view.update(snapshot, settings: settings, paused: false, sourceStatus: ""))
  #expect(view.solarDay == first)
  #expect(view.accessibilityValue() as? String != spoken)
  #expect(
    view.solarDescription.contains(
      "Now " + weatherDateOracle(snapshot.timestamp, template: "jmz", zone: "UTC")))
}

@Test @MainActor
func weatherDaylightAllReadingsPreservesFractionalZoneTimesAndRemovesDisabledReadings() throws {
  var (settings, snapshot) = graphicalForecast()
  settings.weather.location = .init(
    latitude: -43.95, longitude: -176.55, name: "Public Chatham fixture",
    timeZone: "Pacific/Chatham")
  snapshot.timestamp = ISO8601DateFormatter().date(from: "2026-12-21T00:00:00Z")!
  snapshot.weather.forecast = nil
  let controller = DetailController(snapshot: snapshot, history: [])
  controller.settings = settings
  controller.selected = .weather
  controller.showsAllReadings = true
  _ = controller.view
  controller.update(snapshot, history: [])
  let table = try #require(
    controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  func values() -> [String] {
    (0..<table.numberOfRows).compactMap {
      (controller.tableView(table, viewFor: table.tableColumns[1], row: $0) as? NSTextField)?
        .stringValue
    }
  }
  let all = values().joined(separator: " · ")
  #expect(all.contains("Waiting for selected location forecast") && !all.contains("Weather is off"))
  // UI parity uses this model's exact events, not another ephemeris's rounded
  // minutes. The separate core reference test keeps the independent90s bound.
  let solar = try #require(
    SolarDay.calculate(on: snapshot.timestamp, location: settings.weather.location!))
  let formatter = DateFormatter()
  formatter.timeZone = TimeZone(identifier: "Pacific/Chatham")
  formatter.locale = .current
  formatter.setLocalizedDateFormatFromTemplate("EEEjmz")
  for event in solar.events {
    #expect(
      all.contains(
        formatter.string(from: SolarEventPresentation.minute(event.date, in: formatter.timeZone))))
  }
  let minutes = Int((solar.daylightDuration / 60).rounded())
  #expect(all.contains("\(minutes / 60)h \(minutes % 60)m"))
  controller.paused = true
  #expect(!values().contains(where: { $0.contains("NOAA-based") }))
  controller.paused = false
  settings.weather.enabled = false
  controller.settings = settings
  controller.update(snapshot, history: [])
  #expect(!values().contains(where: { $0.contains("NOAA-based") }))
  settings.weather.enabled = true
  settings.weather.source = .currentLocation
  settings.weather.location = nil
  controller.settings = settings
  controller.update(snapshot, history: [])
  #expect(!values().contains(where: { $0.contains("NOAA-based") }))
}

@Test @MainActor func weatherDaylightKeepsForecastAndDailyRowsWhileInspectingActualCivilTime()
  throws
{
  let (settings, snapshot) = graphicalForecast()
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 374))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let solar = try #require(view.solarDay)
  #expect(view.showsSolar && view.visibleDays == 2 && view.upcoming.count == 12)
  #expect(view.solarFrame.maxX < view.dailyFrame.minX)
  #expect(view.dayRow(0).minX > view.solarFrame.maxX)
  #expect((view.accessibilityValue() as? String)?.contains("Estimated sunrise") == true)
  #expect(
    (view.accessibilityValue() as? String)?.contains("Local NOAA-based calculation, not a forecast")
      == true)
  let daylight = try #require(solar.daylight.first)
  let middle = daylight.start.addingTimeInterval(daylight.duration / 2)
  func inspect(_ date: Date) -> String? {
    let x =
      view.solarTrack.minX + view.solarTrack.width * date.timeIntervalSince(solar.interval.start)
      / solar.interval.duration
    return view.hoverText(at: .init(x: x, y: view.solarTrack.midY))
  }
  #expect(inspect(middle)?.contains("estimated daylight\n") == true)
  #expect(
    inspect(solar.interval.start.addingTimeInterval(60))?.contains("outside estimated daylight")
      == true)
  #expect(inspect(middle)?.contains("Europe/Oslo") == true)
  view.setFrameSize(.init(width: 1100, height: 750))
  #expect(view.visibleDays == view.days.count && view.showsSolar)
  #expect(inspect(middle)?.contains("estimated daylight\n") == true)
  view.setFrameSize(.init(width: 520, height: 330))
  #expect(!view.showsSolar && view.dailyFrame.minX == 0)
  #expect(view.hoverText(at: .init(x: 20, y: 290))?.contains("Estimated sunrise") != true)
}

@Test @MainActor
func weatherDaylightIsIndependentOfForecastFreshnessButClearsOnOptOutAndPermissionLoss() throws {
  var (settings, snapshot) = graphicalForecast()
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  snapshot.weather.forecast = nil
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "Waiting")
  let first = try #require(view.solarDay)
  #expect(view.current == nil && view.solarDay != nil)
  snapshot.timestamp.addTimeInterval(10)
  #expect(!view.update(snapshot, settings: settings, paused: false, sourceStatus: "Waiting"))
  snapshot.timestamp.addTimeInterval(86400)
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "Waiting")
  #expect(view.solarDay?.interval != first.interval)
  settings.weather.location?.longitude += 10
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.solarDay?.events != first.events)
  view.update(snapshot, settings: settings, paused: true, sourceStatus: "")
  #expect(view.solarDay == nil && !view.showsSolar)
  settings.weather.enabled = false
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.solarDay == nil)
  settings.weather.enabled = true
  settings.weather.source = .currentLocation
  settings.weather.location = nil
  view.update(
    snapshot, settings: settings, paused: false, sourceStatus: "Location permission needed")
  #expect(view.solarDay == nil && view.status.contains("permission needed"))
  #expect(!(view.accessibilityValue() as? String ?? "").contains("Estimated sunrise"))
}

@Test @MainActor func weatherDaylightReportsPolarStatesAndAllReadingsUsesSameNumbers() throws {
  var (settings, snapshot) = graphicalForecast()
  settings.weather.location = .init(
    latitude: 69.649, longitude: 18.955, name: "Public polar fixture", timeZone: "Europe/Oslo")
  snapshot.timestamp = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!
  snapshot.weather.forecast = nil
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.solarDay?.state == .sunUpAllDay)
  #expect(
    view.solarDescription.contains("Sun up throughout") && view.solarDescription.contains("24h 0m"))
  snapshot.timestamp = ISO8601DateFormatter().date(from: "2026-12-21T12:00:00Z")!
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.solarDay?.state == .sunDownAllDay && view.solarDescription.contains("0h 0m"))
  let controller = DetailController(snapshot: snapshot, history: [])
  controller.settings = settings
  controller.selected = .weather
  controller.showsAllReadings = true
  _ = controller.view
  controller.update(snapshot, history: [])
  let table = try #require(
    controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  let values = (0..<table.numberOfRows).compactMap { row in
    (table.delegate?.tableView?(table, viewFor: table.tableColumns[1], row: row) as? NSTextField)?
      .stringValue
  }
  #expect(values.contains("Below horizon all civil day") && values.contains("0h 0m"))
}

@MainActor private func graphicalForecast() -> (Settings, Snapshot) {
  var settings = Settings()
  settings.weather.enabled = true
  settings.weather.location = .init(
    latitude: 60, longitude: 10, name: "Example", timeZone: "Europe/Oslo")
  var snapshot = Snapshot()
  snapshot.timestamp = Date(timeIntervalSince1970: 1_792_670_400)  // 2026-10-22 12:00 UTC
  snapshot.uptime = 100
  snapshot.weather.settings = settings.weather
  snapshot.weather.receivedAt = 99
  var points: [WeatherPoint] = []
  for index in 0..<72 {
    let date = snapshot.timestamp.addingTimeInterval(Double(index) * 3600)
    var point = WeatherPoint(date: date, celsius: Double(index) - 10)
    point.humidity = 0
    point.windMetersPerSecond = 0
    point.pressureHPa = 1012
    point.symbol = "cloudy"
    point.precipitationMM = Double(index % 3)
    point.periodHours = index == 0 ? 6 : 1
    point.cloudCover = 100
    point.windFromDegrees = 0
    points.append(point)
  }
  snapshot.weather.forecast = .init(generatedAt: snapshot.timestamp, points: points)
  return (settings, snapshot)
}

@Test @MainActor func weatherDashboardKeepsIntervalsUnitsMissingValuesAndExactInspection() throws {
  var (settings, snapshot) = graphicalForecast()
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "Pending permission")
  #expect(view.upcoming.count == 12 && view.days.count == 4)
  #expect(view.current?.celsius == -10)
  #expect(view.metrics[0].value == "0%" && view.metrics[0].fraction == 0)
  #expect(view.metrics[1].value == "100%" && view.metrics[1].fraction == 1)
  #expect(view.metrics[2].value == "0.0 m/s")
  #expect(
    (view.accessibilityValue() as? String)?.contains("Wind from 0° clockwise from north") == true)
  let first = view.upcomingCell(0)
  let inspected = try #require(view.hoverText(at: .init(x: first.midX, y: first.midY)))
  #expect(inspected.contains("-10°C") && inspected.contains("0.0 mm over the next 6h"))
  #expect(
    inspected.contains(
      weatherDateOracle(view.upcoming[0].date, template: "EEEjmz", zone: "Europe/Oslo")))
  settings.fahrenheit = true
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.hoverText(at: .init(x: first.midX, y: first.midY))?.contains("14°F") == true)
  snapshot.weather.forecast?.points[0].celsius = nil
  snapshot.weather.forecast?.points[0].cloudCover = nil
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.metrics[1].fraction == nil && view.metrics[1].value == "—")
  #expect(view.hoverText(at: .init(x: first.midX, y: first.midY))?.contains("—") == true)
  let oldWidth = first.width
  view.setFrameSize(.init(width: 1100, height: 750))
  #expect(view.upcomingCell(0).width > oldWidth && view.visibleDays == view.days.count)
  let second = view.upcomingCell(1)
  #expect(view.hoverText(at: .init(x: second.midX, y: second.midY))?.contains("15.8°F") == false)
  #expect(view.hoverText(at: .init(x: second.midX, y: second.midY))?.contains("16°F") == true)
  #expect(view.hoverText(at: .init(x: -1, y: -1)) == nil)
}

@Test @MainActor func weatherDashboardUsesActualModelTimesAcrossDSTAndBoundsDailySamples() throws {
  var (settings, snapshot) = graphicalForecast()
  snapshot.timestamp = ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z")!
  let now = snapshot.timestamp
  var points = [
    WeatherPoint(date: now.addingTimeInterval(-1), celsius: -100),
    WeatherPoint(date: now, celsius: -5),
    WeatherPoint(date: now.addingTimeInterval(3600), celsius: 20),
    WeatherPoint(date: now.addingTimeInterval(24 * 3600), celsius: 10),
    WeatherPoint(date: now.addingTimeInterval(24 * 3600 + 1), celsius: 11),
  ]
  for day in 2...8 {
    points.append(
      .init(
        date: now.addingTimeInterval(Double(day) * 86400), celsius: day == 3 ? nil : Double(day)))
  }
  snapshot.weather.forecast = .init(generatedAt: now, points: points)
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 374))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(
    view.upcoming.map(\.date) == [now, now.addingTimeInterval(3600), now.addingTimeInterval(86400)])
  #expect(view.days.count == 7 && view.days[0].low == -100 && view.days[0].high == 20)
  #expect(view.days[0].samples == 3)
  #expect(view.days[3].low == nil && view.days[3].high == nil && view.days[3].samples == 0)
  let a = view.upcomingCell(0)
  let b = view.upcomingCell(1)
  let first = try #require(view.hoverText(at: .init(x: a.midX, y: a.midY)))
  let second = try #require(view.hoverText(at: .init(x: b.midX, y: b.midY)))
  let repeatedClock = weatherDateOracle(now, template: "jm", zone: "Europe/Oslo")
  #expect(first.contains(repeatedClock) && second.contains(repeatedClock) && first != second)
  #expect(first.contains("interval unavailable"))
  for direction in [0.0, 360.0] {
    snapshot.weather.forecast?.points[1].windFromDegrees = direction
    view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
    #expect(
      (view.accessibilityValue() as? String)?.contains(
        "Wind from \(Int(direction))° clockwise from north") == true)
  }
  snapshot.weather.forecast?.points[1].windFromDegrees = nil
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect((view.accessibilityValue() as? String)?.contains("Wind direction unavailable") == true)
  settings.weather.enabled = false
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.upcoming.isEmpty)
}

@Test @MainActor func weatherDashboardNeverShowsWrongLocationStalePausedOrDisabledForecasts() {
  var (settings, snapshot) = graphicalForecast()
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  func empty() { #expect(view.current == nil && view.upcoming.isEmpty && view.days.isEmpty) }
  snapshot.uptime = 11_000
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  empty()
  #expect(view.status.contains("stale"))
  snapshot.uptime = 100
  settings.weather.revision = "other"
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  empty()
  #expect(view.status == "Waiting for selected location forecast…")
  settings.weather = .currentLocationDefault
  view.update(
    snapshot, settings: settings, paused: false, sourceStatus: "Location permission needed")
  empty()
  #expect(view.status == "Location permission needed")
  view.update(snapshot, settings: settings, paused: true, sourceStatus: "")
  empty()
  #expect(view.status.contains("paused"))
  settings.weather.enabled = false
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  empty()
  #expect(view.status.contains("off"))
}

@Test @MainActor func weatherTabUsesGraphicalSummaryAndPreservesDetailsAndSetupControls() throws {
  let (settings, snapshot) = graphicalForecast()
  let controller = DetailController()
  controller.settings = settings
  controller.snapshot = snapshot
  controller.selected = .weather
  let view = controller.view
  view.setFrameSize(.init(width: 884, height: 660))
  controller.viewDidLayout()
  let dashboard = try #require(view.subviews.compactMap { $0 as? WeatherDashboardView }.first)
  #expect(!dashboard.isHidden && dashboard.current?.symbol == "cloudy")
  let readings = try #require(
    view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "All readings" })
  #expect(!readings.isHidden)
  readings.performClick(nil)
  #expect(controller.showsAllReadings && dashboard.isHidden)
  let table = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
  #expect(!table.isHidden)
  readings.performClick(nil)
  #expect(!dashboard.isHidden && table.isHidden)
  controller.selected = .cpu
  #expect(dashboard.isHidden)
  controller.selected = .weather
  #expect(!dashboard.isHidden)
}

@Test @MainActor func weatherDashboardSkipsIdenticalPresentationButPreservesInspectionAndResize()
  throws
{
  var (settings, snapshot) = graphicalForecast()
  // Between model timestamps: raw snapshot clocks change without changing visible output.
  snapshot.timestamp += 5
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  var changed = false
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let spoken = try #require(view.accessibilityValue() as? String)
  let cell = view.upcomingCell(0)
  let inspected = view.hoverText(at: .init(x: cell.midX, y: cell.midY))
  for _ in 0..<10 {
    snapshot.timestamp += 2
    snapshot.uptime += 2
    changed = view.update(
      snapshot, settings: settings, paused: false, sourceStatus: "Ignored when located")
    #expect(!changed)
    #expect(view.accessibilityValue() as? String == spoken)
    #expect(view.hoverText(at: .init(x: cell.midX, y: cell.midY)) == inspected)
  }
  view.setFrameSize(.init(width: 1100, height: 750))
  let resizedCell = view.upcomingCell(0)
  #expect(resizedCell.width > cell.width)
  #expect(view.hoverText(at: .init(x: resizedCell.midX, y: resizedCell.midY)) == inspected)
  // A formatting notification forces rebuilding even when the locale identifier stays the same.
  view.invalidateFormatting()
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.accessibilityValue() as? String == spoken)
  settings.weather.enabled = false
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  snapshot.uptime += 2
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(!changed && view.current == nil && view.upcoming.isEmpty)
}

@Test @MainActor func weatherDashboardInvalidatesAtClockBoundariesWithoutNewForecastBytes() throws {
  var (settings, snapshot) = graphicalForecast()
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  var changed = false
  let origin = snapshot.timestamp
  snapshot.timestamp += 5
  snapshot.uptime = 158  // 59 seconds since receipt.
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.status.contains("checked 0m"))
  snapshot.uptime += 1
  snapshot.timestamp += 1
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.status.contains("checked 1m"))
  // Keep receipt age constant to isolate model-boundary invalidation from status text.
  snapshot.uptime = 100
  snapshot.weather.receivedAt = 99
  snapshot.timestamp = origin + 3599
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let firstCurrent = view.current
  snapshot.timestamp = origin + 3600
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(
    changed && view.current != firstCurrent && view.current?.date == snapshot.timestamp)
  snapshot.timestamp += 1
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.upcoming.first?.date == origin + 7200)
  // A future-only forecast enters the inclusive 24-hour window; current remains unavailable.
  snapshot.timestamp = origin
  snapshot.weather.forecast = .init(
    generatedAt: origin, points: [.init(date: origin + 86401, celsius: 15)])
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.current == nil && view.upcoming.isEmpty && !view.days.isEmpty)
  snapshot.timestamp += 1
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.upcoming.count == 1 && view.current == nil)
  // Both receipt-age and generated-model age can independently withhold values.
  snapshot.uptime = 10899
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.upcoming.count == 1)
  snapshot.uptime += 0.01
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.upcoming.isEmpty && view.status.contains("stale"))
  snapshot.uptime = 100
  snapshot.timestamp = origin + 86400
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.upcoming.count == 1)
  snapshot.timestamp += 0.01
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.upcoming.isEmpty && view.status.contains("stale"))
  settings.fahrenheit = true
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed)
}

@Test @MainActor func weatherDashboardRecomputesLocalDaysDSTAndLocationAndStateTransitions() throws
{
  var (settings, snapshot) = graphicalForecast()
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  var changed = false
  let iso = ISO8601DateFormatter()
  snapshot.timestamp = try #require(iso.date(from: "2026-10-24T21:59:59Z"))
  let origin = snapshot.timestamp
  snapshot.weather.forecast = .init(
    generatedAt: origin,
    points: [
      .init(date: origin - 3599, celsius: 5),
      .init(date: origin + 7201, celsius: 10),
      .init(date: origin + 10801, celsius: 12),
    ])
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.days.count == 2)
  let oldCurrent = view.current
  snapshot.timestamp += 2
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.days.count == 1 && view.current == oldCurrent)
  // Repeated local model times retain distinct zones across the fall-back transition.
  snapshot.timestamp = origin + 7201
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let before = try #require(view.hoverText(at: .init(x: 10, y: 20)))
  let repeatedClock = weatherDateOracle(
    try #require(view.current).date, template: "jm", zone: "Europe/Oslo")
  snapshot.timestamp = origin + 10801
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let after = try #require(view.hoverText(at: .init(x: 10, y: 20)))
  #expect(
    changed && before.contains(repeatedClock) && after.contains(repeatedClock) && before != after)
  // Same readings, new display zone: labels and inspection must change.
  settings.weather.location?.timeZone = "UTC"
  snapshot.weather.settings = settings.weather
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(
    changed && (view.accessibilityValue() as? String)?.contains("Times in GMT") == true)
  settings.weather.revision = "new-location"
  changed = view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(changed && view.current == nil && view.status.contains("selected location"))
  settings.weather = .currentLocationDefault
  changed = view.update(
    snapshot, settings: settings, paused: false, sourceStatus: "Permission needed")
  changed = view.update(
    snapshot, settings: settings, paused: false, sourceStatus: "Location denied")
  #expect(changed && view.status == "Location denied")
  changed = view.update(snapshot, settings: settings, paused: true, sourceStatus: "Location denied")
  #expect(changed && view.status.contains("paused"))
  changed = view.update(
    snapshot, settings: settings, paused: false, sourceStatus: "Location denied")
  #expect(changed && view.status == "Location denied")
}

@Test @MainActor func weatherCheckingWithoutForecastAndSummaryCleanupRemainCorrect() throws {
  var (settings, snapshot) = graphicalForecast()
  snapshot.weather.forecast = nil
  snapshot.weather.checking = true
  let controller = DetailController()
  controller.settings = settings
  controller.selected = .weather
  controller.update(snapshot, history: [])
  let view = controller.view
  let dashboard = try #require(view.subviews.compactMap { $0 as? WeatherDashboardView }.first)
  let chart = try #require(view.subviews.compactMap { $0 as? ChartView }.first)
  let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
  let table = try #require(scroll.documentView as? NSTableView)
  #expect(dashboard.current == nil && dashboard.status.contains("Updating forecast"))
  for _ in 0..<3 {
    controller.update(snapshot, history: [])
    #expect(chart.series.isEmpty && chart.times.isEmpty && table.numberOfRows == 0)
  }
  controller.showsAllReadings = true
  #expect(dashboard.isHidden && !scroll.isHidden && table.numberOfRows > 0)
  controller.showsAllReadings = false
  #expect(!dashboard.isHidden && scroll.isHidden && table.numberOfRows == 0)
  // Hidden data left by another module must be cleared, including times without series.
  chart.times = [snapshot.timestamp]
  controller.update(snapshot, history: [])
  #expect(chart.times.isEmpty)
  chart.series = [.init(name: "Previous", color: .systemBlue, values: [10])]
  controller.update(snapshot, history: [])
  #expect(chart.series.isEmpty)
  controller.invalidateWeatherFormatting()
  #expect(dashboard.update(snapshot, settings: settings, paused: false, sourceStatus: ""))
  settings.weather.enabled = false
  controller.settings = settings
  controller.update(snapshot, history: [])
  #expect(dashboard.status.contains("off"))
}

@Test @MainActor func weatherDashboardPrecipitationDistinguishesZeroMissingTinyAndUnknownPeriods()
  throws
{
  func rain(_ amount: Double?, _ hours: Int?) -> WeatherDashboardView.Precipitation {
    var point = WeatherPoint(date: .distantPast, celsius: nil)
    point.precipitationMM = amount
    point.periodHours = hours
    return .init(point)
  }
  for hours in [1, 6, 12] {
    let zero = rain(0, hours)
    #expect(zero.plottedAmount == 0 && zero.label == "0.0/\(hours)h")
    #expect(zero.description == "0.0 mm")
    let small = rain(0.001, hours)
    #expect(small.plottedAmount == 0.001 && small.label == "<0.1/\(hours)h")
    #expect(small.description == "0.001 mm")
    #expect(rain(2.5, hours).label == "2.5/\(hours)h")
  }
  for amount in [nil, -1, Double.nan, .infinity, 2000.01] as [Double?] {
    let missing = rain(amount, 1)
    #expect(missing.plottedAmount == nil && missing.label == "—")
    #expect(missing.description == "Unavailable")
  }
  #expect(rain(2000, 12).plottedAmount == 2000 && rain(2000, 12).label == "2000/12h")
  for hours in [nil, 0, 3, -1] as [Int?] {
    let unknown = rain(1.2, hours)
    #expect(unknown.plottedAmount == nil && unknown.label == "1.2/?")
    #expect(unknown.description == "1.2 mm")
  }
}

@Test @MainActor func weatherDashboardRainBarsUsePeriodAmountsAndKeepInspectionThroughResize()
  throws
{
  var (settings, snapshot) = graphicalForecast()
  let amounts: [Double?] = [0, 0.001, 1.2, 2.4, nil, 1500, -1, .nan, .infinity, 2001]
  let periods: [Int?] = [1, 1, 6, 12, 1, nil, 1, 1, 1, 1]
  snapshot.weather.forecast?.points = amounts.indices.map { index in
    var point = WeatherPoint(
      date: snapshot.timestamp + Double(index) * 3600, celsius: Double(index))
    point.precipitationMM = amounts[index]
    point.periodHours = periods[index]
    return point
  }
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 374))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let maximum = try #require(view.precipitationMaximum)
  #expect(maximum == 2.4)  // The 1500 mm reading has no known interval and cannot set the scale.
  for scale in [CGFloat(1), 2] {
    let zero = try #require(view.precipitationBar(0, maximum: maximum, scale: scale))
    let tiny = try #require(view.precipitationBar(1, maximum: maximum, scale: scale))
    let six = try #require(view.precipitationBar(2, maximum: maximum, scale: scale))
    let twelve = try #require(view.precipitationBar(3, maximum: maximum, scale: scale))
    #expect(zero.height == 0 && tiny.height == 1 / scale)
    #expect(six.height == 11 && twelve.height == 22)  // Amounts, never divided into hourly rates.
    for index in amounts.indices {
      let cell = view.upcomingCell(index)
      if let bar = view.precipitationBar(index, maximum: maximum, scale: scale) {
        #expect(cell.contains(bar) && bar.maxY == cell.minY + 65)
      } else {
        #expect(index >= 4)
      }
    }
  }
  for invalid in [Double.nan, .infinity, -1] {
    #expect(view.precipitationBar(0, maximum: invalid, scale: 1) == nil)
  }
  for invalid in [CGFloat.nan, .infinity, 0, -1] {
    #expect(view.precipitationBar(0, maximum: maximum, scale: invalid) == nil)
  }
  #expect(view.precipitationBar(-1, maximum: maximum, scale: 1) == nil)
  #expect(view.precipitationBar(amounts.count, maximum: maximum, scale: 1) == nil)
  #expect(view.precipitationBar(0, maximum: 0, scale: 1)?.height == 0)
  #expect(view.precipitationBar(1, maximum: 0, scale: 1) == nil)
  let cell = view.upcomingCell(2)
  let inspected = try #require(view.hoverText(at: .init(x: cell.midX, y: cell.midY)))
  #expect(inspected.contains("precipitation 1.2 mm over the next 6h"))
  let unknown = view.upcomingCell(5)
  #expect(
    view.hoverText(at: .init(x: unknown.midX, y: unknown.midY))?.contains(
      "1500.0 mm, interval unavailable") == true)
  let spoken = try #require(view.accessibilityValue() as? String)
  #expect(spoken.contains("periods may overlap and must not be summed"))
  #expect(spoken.contains("Missing amounts or periods have no bar; zero has no filled bar"))
  view.setFrameSize(.init(width: 1100, height: 750))
  let resized = view.upcomingCell(2)
  #expect(resized.width > cell.width)
  #expect(view.hoverText(at: .init(x: resized.midX, y: resized.midY)) == inspected)
  #expect(view.precipitationBar(2, maximum: maximum, scale: 2)?.height == 11)
  settings.fahrenheit = true
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.precipitationMaximum == maximum)  // Temperature units never alter precipitation.
  let zeroPoint = try #require(snapshot.weather.forecast?.points.first)
  snapshot.weather.forecast?.points = [zeroPoint]
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.precipitationMaximum == 0)
  #expect(view.precipitationBar(0, maximum: 0, scale: 2)?.height == 0)
  snapshot.weather.forecast?.points[0].periodHours = 3
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.precipitationMaximum == nil)
  let unknownOnly = view.upcomingCell(0)
  #expect(
    view.hoverText(at: .init(x: unknownOnly.midX, y: unknownOnly.midY))?.contains(
      "interval unavailable") == true)
  settings.weather.enabled = false
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(view.precipitationMaximum == nil)
  #expect(view.precipitationBar(0, maximum: maximum, scale: 1) == nil)
}

@Test @MainActor func solarEventMinutesRoundConsistentlyAcrossDatesAndOffsets() throws {
  let utc = try #require(TimeZone(identifier: "UTC"))
  let parse = ISO8601DateFormatter()
  let before = try #require(parse.date(from: "1969-12-31T23:59:29Z"))
  let half = try #require(parse.date(from: "1969-12-31T23:59:30Z"))
  #expect(
    SolarEventPresentation.minute(before, in: utc) == parse.date(from: "1969-12-31T23:59:00Z"))
  #expect(SolarEventPresentation.minute(half, in: utc) == parse.date(from: "1970-01-01T00:00:00Z"))
  let secondsOffset = try #require(TimeZone(secondsFromGMT: 75))
  #expect(
    SolarEventPresentation.minute(Date(timeIntervalSince1970: 14), in: secondsOffset)
      .timeIntervalSince1970 == -15)
  #expect(
    SolarEventPresentation.minute(Date(timeIntervalSince1970: 15), in: secondsOffset)
      .timeIntervalSince1970 == 45)
  var (settings, snapshot) = graphicalForecast()
  settings.weather.location = .init(
    latitude: 59.914, longitude: 10.752, name: "Public Oslo", timeZone: "Europe/Oslo")
  snapshot.timestamp = try #require(parse.date(from: "2026-10-25T12:00:00Z"))
  snapshot.weather.forecast = nil
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 474))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  let label = DateFormatter()
  label.locale = .current
  label.timeZone = TimeZone(identifier: "Europe/Oslo")
  label.setLocalizedDateFormatFromTemplate("EEEjmz")
  let expectedRise = try #require(parse.date(from: "2026-10-25T06:21:00Z"))
  let expectedSet = try #require(parse.date(from: "2026-10-25T15:40:00Z"))
  #expect(view.solarDescription.contains(label.string(from: expectedRise)))
  #expect(view.solarDescription.contains(label.string(from: expectedSet)))
  #expect(view.solarDescription.contains("9h 19m"))
  #expect(view.solarDescription.contains("independently rounded"))
}

@Test @MainActor func weatherWindDirectionIncludesCardinalReference() throws {
  let (settings, initial) = graphicalForecast()
  var snapshot = initial
  snapshot.weather.forecast?.points[0].windFromDegrees = 90
  let view = WeatherDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 374))
  view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
  #expect(
    (view.accessibilityValue() as? String)?.contains("Wind from 90° clockwise from north (E)")
      == true)
}

@MainActor private func weatherDateOracle(
  _ date: Date, template: String, zone: String, locale: Locale = .current
) -> String {
  let formatter = DateFormatter()
  formatter.locale = locale
  formatter.timeZone = TimeZone(identifier: zone)
  formatter.setLocalizedDateFormatFromTemplate(template)
  return formatter.string(from: date)
}

@Test func weatherWindCardinalsRespectNorthWrappingSectorsAndInvalidReadings() {
  let sectors = [
    "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW",
    "NNW",
  ]
  for (index, name) in sectors.enumerated() {
    let degrees = Double(index) * 22.5
    #expect(WindDirectionPresentation(degrees)?.cardinal == name)
    #expect(WindDirectionPresentation(degrees)?.degrees == degrees)
  }
  #expect(WindDirectionPresentation(11.249)?.cardinal == "N")
  #expect(WindDirectionPresentation(11.25)?.cardinal == "NNE")
  #expect(WindDirectionPresentation(348.749)?.cardinal == "NNW")
  #expect(WindDirectionPresentation(348.75)?.cardinal == "N")
  #expect(WindDirectionPresentation(360)?.cardinal == "N")
  #expect(WindDirectionPresentation(360)?.value == "N · 360°")
  for value in [nil, -0.01, 360.01, Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
    #expect(WindDirectionPresentation(value) == nil)
  }
}

@Test @MainActor func weatherDateLabelsHonorHourCyclesZonesAndBoundedPatterns() throws {
  let date = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
  let zone = TimeZone(identifier: "Pacific/Chatham")!
  let labels = WeatherDateLabels(locale: Locale(identifier: "en-US-u-hc-h12"), timeZone: zone)
  #expect(labels.string(date, as: .clock).contains("1:45"))
  #expect(labels.string(date, as: .clock).contains("AM"))
  #expect(!labels.compactTime(date).contains("\u{202F}"))
  #expect(!labels.compactTime(date).contains("\u{00A0}"))
  for id in ["en-US-u-hc-h12", "en-US-u-hc-h23", "en_GB", "zh_CN", "ar_EG"] {
    let locale = Locale(identifier: id)
    labels.configure(locale: locale, timeZone: zone)
    for style in WeatherDateLabels.Style.allCases {
      for hour in 0..<48 {
        let point = date.addingTimeInterval(Double(hour) * 3600)
        #expect(
          labels.string(point, as: style)
            == weatherDateOracle(
              point, template: style.template, zone: zone.identifier, locale: locale))
      }
    }
    #expect(labels.patternCount == WeatherDateLabels.Style.allCases.count)
  }
  labels.configure(locale: Locale(identifier: "en-US-u-hc-h23"), timeZone: zone)
  #expect(labels.string(date, as: .clock) == "01:45")
  labels.configure(
    locale: Locale(identifier: "en-US-u-hc-h23"), timeZone: TimeZone(identifier: "UTC")!)
  #expect(labels.string(date, as: .clock) == "12:00")
  labels.invalidate()
  #expect(labels.patternCount == 0)
  labels.configure(locale: Locale(identifier: "en-US-u-hc-h12"), timeZone: zone)
  #expect(labels.string(date, as: .clock).contains("AM"))
}

@Test @MainActor func weatherLocaleChangesRefreshWithoutNewForecastAndCompactLabelsFit() throws {
  let (settings, snapshot) = graphicalForecast()
  var locale = Locale(identifier: "en-US-u-hc-h12")
  let view = WeatherDashboardView(
    frame: .init(x: 0, y: 0, width: 520, height: 374), solarCalculator: SolarDayCalculator(),
    locale: { locale })
  #expect(view.update(snapshot, settings: settings, paused: false, sourceStatus: ""))
  let first = view.upcomingCell(0)
  let twelve = try #require(view.hoverText(at: .init(x: first.midX, y: first.midY)))
  #expect(twelve.contains("PM"))
  #expect(!view.update(snapshot, settings: settings, paused: false, sourceStatus: ""))
  locale = Locale(identifier: "en-US-u-hc-h23")
  #expect(view.update(snapshot, settings: settings, paused: false, sourceStatus: ""))
  #expect(view.hoverText(at: .init(x: first.midX, y: first.midY))?.contains("14:00") == true)
  view.invalidateFormatting()
  #expect(view.update(snapshot, settings: settings, paused: false, sourceStatus: ""))
  for id in ["en-US-u-hc-h12", "en-US-u-hc-h23", "zh_CN", "zh_TW", "ar_EG", "fr_CA"] {
    locale = Locale(identifier: id)
    view.update(snapshot, settings: settings, paused: false, sourceStatus: "")
    for index in view.upcoming.indices {
      let frame = view.upcomingTimeFrame(index)
      #expect(frame.minX >= view.upcomingCell(index).minX + 4)
      #expect(frame.maxX <= view.upcomingCell(index).maxX - 4)
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      paragraph.lineBreakMode = .byWordWrapping
      let measured = (view.upcomingTimeLabel(index) as NSString).boundingRect(
        with: .init(width: frame.width, height: 200), options: [.usesLineFragmentOrigin],
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
          .paragraphStyle: paragraph,
        ])
      #expect(ceil(measured.height) <= frame.height)
      #expect(frame.maxY <= view.upcomingCell(index).minY + 26)
    }
    #expect(view.visibleDays >= 2)
    #expect(
      view.solarFrame.maxX < view.dailyFrame.minX && view.solarFrame.maxY <= view.bounds.maxY - 16)
  }
}

@Test @MainActor func weatherAllReadingsInspectionUsesForecastZoneAndClearsOnPageChange() throws {
  var (settings, snapshot) = graphicalForecast()
  settings.weather.location?.timeZone = "Pacific/Chatham"
  snapshot.weather.settings = settings.weather
  snapshot.weather.forecast?.points[0].windFromDegrees = 315
  let controller = DetailController(snapshot: snapshot, history: [])
  controller.settings = settings
  controller.selected = .weather
  controller.showsAllReadings = true
  _ = controller.view
  controller.update(snapshot, history: [])
  let chart = try #require(controller.view.subviews.compactMap { $0 as? ChartView }.first)
  let area = chart.plotArea
  let inspected = try #require(chart.hoverText(at: .init(x: area.minX, y: area.midY)))
  #expect(
    inspected.contains(
      weatherDateOracle(snapshot.timestamp, template: "EEEjmz", zone: "Pacific/Chatham")))
  #expect(chart.caption?.contains("Pacific/Chatham") == true)
  let table = try #require(
    controller.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  let values = (0..<table.numberOfRows).compactMap {
    (controller.tableView(table, viewFor: table.tableColumns[1], row: $0) as? NSTextField)?
      .stringValue
  }
  #expect(values.contains("NW · 315°"))
  controller.selected = .cpu
  controller.update(snapshot, history: [])
  #expect(chart.inspectionDateLabel == nil)
}
