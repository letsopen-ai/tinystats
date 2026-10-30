import AppKit
import TinyStatsCore

/// One bounded, native canvas. Forecast updates use the existing sampler; drawing never requests data.
/// Round only displayed solar events; geometry and duration use the original instants.
enum SolarEventPresentation {
  static func minute(_ date: Date, in timeZone: TimeZone) -> Date {
    let offset = Double(timeZone.secondsFromGMT(for: date))
    let localSeconds = date.timeIntervalSince1970 + offset
    return Date(timeIntervalSince1970: floor(localSeconds / 60 + 0.5) * 60 - offset)
  }
}

@MainActor final class WeatherDashboardView: ChartHoverView {
  struct Day: Equatable {
    let date: Date, low: Double?, high: Double?
    let samples: Int
  }
  private(set) var current: WeatherPoint?
  private(set) var upcoming: [WeatherPoint] = []
  private(set) var days: [Day] = []
  private(set) var status = "Weather is off"
  private(set) var solarDay: SolarDay?
  private var solarNow = Date.distantPast
  private let solarCalculator: SolarDayCalculator
  private var fahrenheit = false
  private var hasPresentation = false
  private let dateLabels = WeatherDateLabels()
  private let readLocale: () -> Locale
  private var timeZone = TimeZone.current
  override var isFlipped: Bool { true }
  override convenience init(frame: NSRect) {
    self.init(frame: frame, solarCalculator: SolarDayCalculator())
  }
  init(
    frame: NSRect, solarCalculator: SolarDayCalculator,
    locale: @escaping () -> Locale = { .current }
  ) {
    readLocale = locale
    self.solarCalculator = solarCalculator
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Weather forecast summary")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  /// Locale preferences can change without changing Locale.current.identifier.
  /// The app forwards its existing locale/time notifications; no extra observer or timer.
  func invalidateFormatting() { hasPresentation = false }
  /// Returns whether the presentation changed (independent of AppKit's dirty-region coalescing).
  @discardableResult
  func update(_ snapshot: Snapshot, settings: Settings, paused: Bool, sourceStatus: String) -> Bool
  {
    let now = snapshot.timestamp
    let fahrenheit = settings.fahrenheit
    let timeZone =
      settings.weather.location.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
    let locale = readLocale()
    let weather = snapshot.weather.filtered(settings: settings.weather, suspended: paused)
    let current = weather.current(at: snapshot.uptime, date: snapshot.timestamp)
    let solar = solarCalculator.day(
      on: now,
      location: settings.weather.enabled && !paused ? settings.weather.location : nil)
    let solarNow = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
    var upcoming: [WeatherPoint] = []
    var days: [Day] = []
    var status: String
    if !settings.weather.enabled {
      status = "Weather is off · enable it above"
    } else if paused {
      status = "Monitoring paused · resume to see the forecast"
    } else if settings.weather.source == .currentLocation && settings.weather.location == nil {
      status = sourceStatus
    } else if snapshot.weather.settings != settings.weather {
      status = "Waiting for selected location forecast…"
    } else {
      status =
        weather.forecast != nil && !weather.isFresh(at: snapshot.uptime, date: snapshot.timestamp)
        ? "Forecast is stale · values withheld"
        : weather.checking ? "Updating forecast…" : weather.reason
      if let age = weather.checkedAge(at: snapshot.uptime) { status += " · checked \(age)" }
    }
    if weather.isFresh(at: snapshot.uptime, date: snapshot.timestamp),
      let forecast = weather.forecast
    {
      upcoming = Array(
        forecast.points.filter { $0.date >= now && $0.date <= now.addingTimeInterval(24 * 3600) }
          .prefix(12))
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      let today = calendar.startOfDay(for: now)
      let grouped = Dictionary(grouping: forecast.points.filter { $0.date >= today }) {
        calendar.startOfDay(for: $0.date)
      }
      days = grouped.keys.sorted().prefix(7).map { date in
        let values = (grouped[date] ?? []).compactMap { point in
          point.celsius.flatMap { $0.isFinite ? $0 : nil }
        }
        return Day(date: date, low: values.min(), high: values.max(), samples: values.count)
      }
    }
    // Derive on every shared tick: unchanged forecast bytes can cross freshness,
    // model-time, checked-age or local-day boundaries. Retain only the presentation
    // already used by drawing/inspection, not another forecast or layout cache.
    guard
      !hasPresentation || current != self.current || upcoming != self.upcoming
        || days != self.days || status != self.status || fahrenheit != self.fahrenheit
        || timeZone != self.timeZone || locale != dateLabels.locale
        || solar != solarDay || (solar != nil && solarNow != self.solarNow)
    else { return false }
    self.current = current
    self.upcoming = upcoming
    self.days = days
    self.status = status
    self.fahrenheit = fahrenheit
    self.timeZone = timeZone
    solarDay = solar
    self.solarNow = solarNow
    dateLabels.configure(locale: locale, timeZone: timeZone, force: !hasPresentation)
    hasPresentation = true
    var parts = [
      "Now, model forecast", current?.condition ?? "Conditions unavailable",
      temperature(current?.celsius), status,
    ]
    parts += metrics.map {
      ($0.label == "Pressure" ? "Sea-level pressure" : $0.label) + ": " + $0.value
    }
    parts.append(
      WindDirectionPresentation(current?.windFromDegrees)?.description
        ?? "Wind direction unavailable")
    parts += upcoming.map(pointDescription)
    if !upcoming.isEmpty {
      parts.append(
        "Lighter accent bars show relative temperature. Full accent bars show millimetres of precipitation over each labelled forecast period; periods may overlap and must not be summed. Missing amounts or periods have no bar; zero has no filled bar. Positive bars have a one-pixel minimum."
      )
    }
    parts += days.map { day in
      "\(dateLabel(day.date, style: .day)), sampled low \(temperature(day.low)), high \(temperature(day.high)), \(day.samples) temperature samples; may be partial"
    }
    if solar != nil { parts.append(solarDescription) }
    let spoken =
      (parts + [
        "Times in \(timeZone.identifier). Data from MET Norway, CC BY 4.0. Model samples, not local observations."
      ]).joined(separator: ". ")
    setAccessibilityValue(spoken)
    needsDisplay = true
    refreshHover()
    return true
  }
  struct Metric {
    let label: String, value: String
    let fraction: Double?
    let color: NSColor
  }
  var metrics: [Metric] {
    [
      .init(
        label: "Humidity", value: percent(current?.humidity), fraction: fraction(current?.humidity),
        color: SystemStyle.accent),
      .init(
        label: "Cloud cover", value: percent(current?.cloudCover),
        fraction: fraction(current?.cloudCover), color: .systemGray),
      .init(
        label: "Wind",
        value: current?.windMetersPerSecond.map { String(format: "%.1f m/s", $0) } ?? "—",
        fraction: nil, color: SystemStyle.secondaryAccent),
      .init(
        label: "Pressure",
        value: current?.pressureHPa.map { String(format: "%.0f hPa", $0) } ?? "—", fraction: nil,
        color: SystemStyle.accent),
    ]
  }
  private func fraction(_ value: Double?) -> Double? {
    value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 / 100 : nil }
  }
  private func percent(_ value: Double?) -> String {
    fraction(value).map { String(format: "%.0f%%", $0 * 100) } ?? "—"
  }
  private func temperature(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.0f°%@", fahrenheit ? value * 1.8 + 32 : value, fahrenheit ? "F" : "C")
  }
  private func dateLabel(_ date: Date, style: WeatherDateLabels.Style) -> String {
    dateLabels.string(date, as: style)
  }
  /// Amounts are period accumulations, not probabilities, rates or a sum across columns.
  struct Precipitation {
    let amount: Double?
    let hours: Int?
    init(_ point: WeatherPoint) {
      amount = point.precipitationMM.flatMap {
        $0.isFinite && (0...2000).contains($0) ? $0 : nil
      }
      hours = point.periodHours.flatMap { [1, 6, 12].contains($0) ? $0 : nil }
    }
    var plottedAmount: Double? { hours == nil ? nil : amount }
    var number: String? {
      amount.map { $0 > 0 && $0 < 0.1 ? "<0.1" : String(format: $0 >= 1000 ? "%.0f" : "%.1f", $0) }
    }
    var label: String { number.map { $0 + (hours.map { "/\($0)h" } ?? "/?") } ?? "—" }
    var description: String {
      amount.map { String(format: $0 > 0 && $0 < 0.1 ? "%.3g mm" : "%.1f mm", $0) }
        ?? "Unavailable"
    }
  }
  var precipitationMaximum: Double? {
    upcoming.reduce(nil) { maximum, point in
      guard let value = Precipitation(point).plottedAmount else { return maximum }
      return max(maximum ?? 0, value)
    }
  }
  func precipitationBar(_ index: Int, maximum: Double, scale: CGFloat) -> NSRect? {
    guard upcoming.indices.contains(index), maximum.isFinite, maximum >= 0,
      scale.isFinite, scale > 0, let amount = Precipitation(upcoming[index]).plottedAmount
    else { return nil }
    let height: CGFloat
    if amount == 0 {
      height = 0
    } else if maximum > 0 {
      height = min(22, max(1 / scale, 22 * CGFloat(amount / maximum)))
    } else {
      return nil
    }
    let cell = upcomingCell(index)
    return .init(x: cell.midX + 2, y: cell.minY + 65 - height, width: 7, height: height)
  }
  private func pointDescription(_ point: WeatherPoint) -> String {
    let precipitation = Precipitation(point)
    return
      "\(dateLabel(point.date, style: .forecast)): \(point.condition), \(temperature(point.celsius)); precipitation \(precipitation.description)\(precipitation.hours.map { " over the next \($0)h" } ?? ", interval unavailable")"
  }
  // Fixed reading sizes stay legible; remaining height goes to the range chart.
  var conditionFrame: NSRect {
    .init(x: 0, y: 0, width: bounds.width, height: bounds.width < 400 ? 200 : 120)
  }
  var upcomingFrame: NSRect {
    .init(
      x: 0, y: bounds.width < 400 ? 208 : 128, width: bounds.width,
      height: bounds.width < 400 ? 40 + CGFloat(upcoming.count) * 30 : 146)
  }
  var dailyFrame: NSRect {
    if bounds.width < 400 {
      return .init(
        x: 0, y: upcomingFrame.maxY + 8, width: bounds.width, height: 40 + CGFloat(days.count) * 23)
    }
    let x = showsSolar ? solarFrame.maxX + 8 : 0
    return .init(x: x, y: 282, width: max(0, bounds.width - x), height: max(0, bounds.height - 304))
  }
  var showsSolar: Bool { solarDay != nil && bounds.height >= 364 && bounds.width >= 500 }
  var solarFrame: NSRect {
    .init(x: 0, y: 282, width: min(260, bounds.width * 0.4), height: max(0, bounds.height - 304))
  }
  var solarTrack: NSRect {
    .init(
      x: solarFrame.minX + 12, y: solarFrame.minY + 52,
      width: max(0, solarFrame.width - 24), height: 7)
  }
  private var compactDays: Bool { dailyFrame.height < 100 }
  private var dayHeight: CGFloat { compactDays ? 16 : 23 }
  var visibleDays: Int {
    if bounds.width < 400 { return days.count }
    return min(days.count, max(0, Int((dailyFrame.height - (compactDays ? 38 : 49)) / dayHeight)))
  }
  func upcomingCell(_ index: Int) -> NSRect {
    if bounds.width < 400 {
      return .init(x: 0, y: 242 + CGFloat(index) * 30, width: bounds.width, height: 30)
    }
    let width = (bounds.width - 24) / CGFloat(max(1, upcoming.count))
    return .init(
      x: 12 + CGFloat(index) * width, y: upcomingFrame.minY + 29, width: width, height: 98)
  }
  func upcomingTimeFrame(_ index: Int) -> NSRect {
    let cell = upcomingCell(index)
    return .init(x: cell.minX + 4, y: cell.minY, width: max(0, cell.width - 8), height: 26)
  }
  func upcomingTimeLabel(_ index: Int) -> String { dateLabels.compactTime(upcoming[index].date) }
  func dayRow(_ index: Int) -> NSRect {
    if bounds.width < 400 {
      return .init(
        x: 12, y: dailyFrame.minY + 34 + CGFloat(index) * 23, width: bounds.width - 24, height: 23)
    }
    return .init(
      x: dailyFrame.minX + 12,
      y: dailyFrame.minY + (compactDays ? 24 : 28) + CGFloat(index) * dayHeight,
      width: dailyFrame.width - 24, height: dayHeight)
  }
  override func hoverText(at point: NSPoint) -> String? {
    if bounds.width < 400, solarDay != nil,
      NSRect(x: 0, y: dailyFrame.maxY + 8, width: bounds.width, height: 92).contains(point)
    {
      return solarDescription
    }
    if showsSolar, let day = solarDay, solarFrame.contains(point) {
      if solarTrack.insetBy(dx: 0, dy: -6).contains(point), solarTrack.width > 0 {
        let fraction = min(1, max(0, (point.x - solarTrack.minX) / solarTrack.width))
        let date = day.interval.start.addingTimeInterval(fraction * day.interval.duration)
        return "\(dateLabel(date, style: .forecast)) · "
          + (day.isDaylight(at: date) ? "estimated daylight" : "outside estimated daylight")
          + "\n" + solarDescription
      }
      return solarDescription
    }
    for index in upcoming.indices where upcomingCell(index).contains(point) {
      return pointDescription(upcoming[index])
    }
    for index in 0..<visibleDays where dayRow(index).contains(point) {
      let day = days[index]
      return
        "\(dateLabel(day.date, style: .longDay))\nSampled low \(temperature(day.low)) · high \(temperature(day.high))\n\(day.samples) temperature samples · may be partial"
    }
    if conditionFrame.contains(point), let current {
      return pointDescription(current) + "\n"
        + metrics.map { $0.label + ": " + $0.value }.joined(separator: " · ")
        + "\n"
        + (WindDirectionPresentation(current.windFromDegrees)?.description
          ?? "Wind direction unavailable")
    }
    return nil
  }
  override func draw(_ dirtyRect: NSRect) {
    guard bounds.width >= 300, bounds.height >= 300 else { return }
    if bounds.width < 400 {
      drawPopover()
      return
    }
    if current == nil && upcoming.isEmpty && days.isEmpty && solarDay == nil {
      panel(.init(x: 0, y: 0, width: bounds.width, height: 116))
      symbol("cloud", .init(x: 16, y: 23, width: 46, height: 46), color: .secondaryLabelColor)
      text(
        status, .init(x: 78, y: 26, width: bounds.width - 92, height: 24), size: 14, weight: .medium
      )
      text(
        "Forecast readings appear when a fresh model forecast is available.",
        .init(x: 78, y: 58, width: bounds.width - 92, height: 32), size: 11,
        color: .secondaryLabelColor)
      attribution()
      return
    }
    panel(conditionFrame)
    text(
      "Now · model forecast", .init(x: 12, y: 9, width: bounds.width - 24, height: 16), size: 10,
      color: .secondaryLabelColor)
    symbol(
      current?.systemSymbol ?? "questionmark.circle", .init(x: 13, y: 34, width: 40, height: 40),
      color: SystemStyle.secondaryAccent)
    text(
      temperature(current?.celsius), .init(x: 61, y: 29, width: 150, height: 35), size: 29,
      weight: .medium)
    text(
      current?.condition ?? "Conditions unavailable", .init(x: 14, y: 77, width: 195, height: 20),
      size: 12)
    let metricWidth = (bounds.width - 228) / 4
    for (index, metric) in metrics.enumerated() {
      let x = 218 + CGFloat(index) * metricWidth
      text(
        metric.label, .init(x: x, y: 32, width: metricWidth - 8, height: 14), size: 10,
        color: .secondaryLabelColor)
      text(
        metric.value, .init(x: x, y: 51, width: metricWidth - 8, height: 20),
        size: metricWidth < 90 ? 12 : 15,
        weight: .medium, color: metric.color)
      if index < 2 {
        let track = NSRect(x: x, y: 83, width: metricWidth - 12, height: 5)
        capsule(track, .quaternaryLabelColor)
        if let fraction = metric.fraction {
          capsule(
            .init(
              x: track.minX, y: track.minY, width: track.width * fraction, height: track.height),
            metric.color)
        }
      } else if index == 2 {
        drawWind(at: .init(x: x + 9, y: 90))
        text(
          WindDirectionPresentation(current?.windFromDegrees).map {
            metricWidth < 90 ? $0.cardinal : "From " + $0.value
          } ?? (metricWidth < 90 ? "—" : "Direction —"),
          .init(x: x + 24, y: 83, width: metricWidth - 32, height: 15), size: 9,
          color: .secondaryLabelColor)
      } else {
        text(
          "Sea level", .init(x: x, y: 78, width: metricWidth - 8, height: 15), size: 9,
          color: .secondaryLabelColor)
      }
    }
    text(
      status, .init(x: 12, y: 102, width: bounds.width - 24, height: 14), size: 9,
      color: .secondaryLabelColor)
    panel(upcomingFrame)
    text(
      "Next model times", .init(x: 12, y: 138, width: 160, height: 15), size: 10,
      color: .secondaryLabelColor)
    text(
      timeZone.identifier, .init(x: 177, y: 138, width: bounds.width - 189, height: 15), size: 10,
      color: .secondaryLabelColor, alignment: .right)
    if upcoming.isEmpty {
      text(
        "A fresh forecast will appear here", upcomingFrame.insetBy(dx: 14, dy: 60), size: 12,
        color: .secondaryLabelColor)
    } else {
      let values = upcoming.compactMap(\.celsius).filter(\.isFinite)
      let low = values.min() ?? 0
      let high = values.max() ?? 0
      let rainMaximum = precipitationMaximum ?? 0
      let scale = window?.backingScaleFactor ?? 1
      for index in upcoming.indices {
        let point = upcoming[index]
        let cell = upcomingCell(index)
        text(
          dateLabels.compactTime(point.date),
          upcomingTimeFrame(index), size: 10,
          alignment: .center, wrapping: true)
        symbol(
          point.systemSymbol, .init(x: cell.midX - 7, y: cell.minY + 26, width: 14, height: 14),
          color: SystemStyle.secondaryAccent)
        let height = point.celsius.flatMap {
          $0.isFinite ? 5 + 17 * ($0 - low) / max(1, high - low) : nil
        }
        if let height {
          capsule(
            .init(x: cell.midX - 9, y: cell.minY + 65 - height, width: 7, height: height),
            SystemStyle.secondaryAccent)
        }
        let rain = Precipitation(point)
        if let bar = precipitationBar(index, maximum: rainMaximum, scale: scale), bar.height > 0 {
          capsule(bar, SystemStyle.accent)
        }
        text(
          temperature(point.celsius),
          .init(x: cell.minX, y: cell.minY + 67, width: cell.width, height: 15), size: 11,
          weight: .medium, alignment: .center)
        text(
          rain.label,
          .init(x: cell.minX, y: cell.minY + 84, width: cell.width, height: 13), size: 9,
          color: (rain.plottedAmount ?? 0) > 0 ? SystemStyle.accent : .secondaryLabelColor,
          alignment: .center)
      }
    }
    text(
      "Light: temperature · full: "
        + (precipitationMaximum.map {
          "0–\(String(format: $0 > 0 && $0 < 0.1 ? "%.3g" : "%.1f", $0)) mm / period (may overlap)"
        } ?? "precipitation unavailable"),
      .init(x: 12, y: 256, width: bounds.width - 24, height: 14), size: 9,
      color: .secondaryLabelColor)
    if dailyFrame.height >= 49 {
      panel(dailyFrame)
      text(
        "Daily sampled low / high",
        .init(
          x: dailyFrame.minX + 12, y: dailyFrame.minY + 9, width: dailyFrame.width - 24, height: 15),
        size: 10,
        color: .secondaryLabelColor)
      let all = days.flatMap { [$0.low, $0.high].compactMap { $0 } }
      let low = all.min() ?? 0
      let high = all.max() ?? 0
      for index in 0..<visibleDays {
        let day = days[index]
        let row = dayRow(index)
        text(
          dateLabel(day.date, style: .shortDay),
          .init(x: row.minX, y: row.minY + 2, width: 57, height: 18), size: 11)
        text(
          temperature(day.low), .init(x: row.minX + 57, y: row.minY + 2, width: 45, height: 18),
          size: 11,
          color: SystemStyle.accent, alignment: .right)
        let track = NSRect(
          x: row.minX + 110, y: row.minY + 8, width: max(1, row.width - 163), height: 6)
        capsule(track, .quaternaryLabelColor)
        if let a = day.low, let b = day.high {
          let start = track.minX + track.width * (a - low) / max(1, high - low)
          let end = track.minX + track.width * (b - low) / max(1, high - low)
          capsule(
            .init(x: start, y: track.minY, width: max(3, end - start), height: 6),
            SystemStyle.secondaryAccent)
        }
        text(
          temperature(day.high),
          .init(x: row.maxX - 45, y: row.minY + 2, width: 45, height: 18), size: 11,
          color: SystemStyle.secondaryAccent, alignment: .right)
      }
      text(
        days.isEmpty
          ? "No fresh daily samples"
          : dailyFrame.width < 480
            ? "Sampled ranges · may be partial"
            : "Available model samples · may be partial · all days in All readings",
        .init(
          x: dailyFrame.minX + 12, y: dailyFrame.maxY - (compactDays ? 14 : 18),
          width: dailyFrame.width - 24, height: 14),
        size: 9,
        color: .secondaryLabelColor)
    }
    drawSolarDay()
    attribution()
  }
  var popoverDocumentHeight: CGFloat {
    200 + 8 + 40 + CGFloat(upcoming.count) * 30 + 8 + 40 + CGFloat(days.count) * 23
      + (solarDay == nil ? 0 : 100) + 30
  }
  /// Forecast times remain individual readable rows in a narrow dropdown.
  private func drawPopover() {
    let width = bounds.width
    panel(.init(x: 0, y: 0, width: width, height: 200))
    text(
      "Now · model forecast", .init(x: 12, y: 10, width: width - 24, height: 18), size: 12,
      color: .secondaryLabelColor)
    symbol(
      current?.systemSymbol ?? "cloud", .init(x: width - 54, y: 38, width: 36, height: 36),
      color: SystemStyle.accent)
    text(
      temperature(current?.celsius), .init(x: 12, y: 37, width: width - 80, height: 38), size: 30,
      weight: .semibold)
    text(current?.condition ?? status, .init(x: 12, y: 80, width: width - 24, height: 20), size: 13)
    let cellWidth = (width - 24) / 2
    for (index, metric) in metrics.enumerated() {
      let x = 12 + CGFloat(index % 2) * cellWidth
      let y = 108 + CGFloat(index / 2) * 34
      text(
        metric.label, .init(x: x, y: y, width: cellWidth, height: 13), size: 10,
        color: .secondaryLabelColor)
      text(
        metric.value, .init(x: x, y: y + 14, width: cellWidth, height: 18), size: 14,
        weight: .medium)
    }
    text(
      status, .init(x: 12, y: 180, width: width - 24, height: 14), size: 9,
      color: .secondaryLabelColor)
    if current == nil && upcoming.isEmpty && days.isEmpty && solarDay == nil {
      attribution()
      return
    }
    let forecastY: CGFloat = 208
    let forecastHeight = 40 + CGFloat(upcoming.count) * 30
    panel(.init(x: 0, y: forecastY, width: width, height: forecastHeight))
    text(
      "Next model times", .init(x: 12, y: forecastY + 10, width: width - 24, height: 18), size: 12,
      color: .secondaryLabelColor)
    for (index, point) in upcoming.enumerated() {
      let row = upcomingCell(index)
      text(
        dateLabels.compactTime(point.date), .init(x: 12, y: row.minY + 6, width: 56, height: 18),
        size: 11)
      symbol(
        point.systemSymbol, .init(x: 74, y: row.minY + 6, width: 16, height: 16),
        color: SystemStyle.accent)
      text(
        temperature(point.celsius), .init(x: 100, y: row.minY + 6, width: 66, height: 18), size: 14,
        weight: .medium)
      text(
        Precipitation(point).label + " mm",
        .init(x: 170, y: row.minY + 6, width: width - 182, height: 18), size: 11,
        color: .secondaryLabelColor, alignment: .right)
      NSColor.separatorColor.setFill()
      NSRect(x: 12, y: row.maxY - 0.5, width: width - 24, height: 0.5).fill()
    }
    let dailyY = forecastY + forecastHeight + 8
    let dailyHeight = 40 + CGFloat(days.count) * 23
    panel(.init(x: 0, y: dailyY, width: width, height: dailyHeight))
    text(
      "Sampled low / high · may be partial",
      .init(x: 12, y: dailyY + 10, width: width - 24, height: 18), size: 12,
      color: .secondaryLabelColor)
    for (index, day) in days.enumerated() {
      let y = dailyY + 34 + CGFloat(index) * 23
      text(
        dateLabel(day.date, style: .shortDay), .init(x: 12, y: y, width: 70, height: 20), size: 12)
      text(
        temperature(day.low) + " / " + temperature(day.high),
        .init(x: 90, y: y, width: width - 102, height: 20), size: 13, alignment: .right)
    }
    if let day = solarDay {
      let y = dailyY + dailyHeight + 8
      panel(.init(x: 0, y: y, width: width, height: 92))
      text(
        "Estimated daylight", .init(x: 12, y: y + 10, width: width - 24, height: 18), size: 12,
        color: .secondaryLabelColor)
      text(
        duration(day.daylightDuration), .init(x: 12, y: y + 32, width: width - 24, height: 32),
        size: 26, weight: .semibold)
      text(
        day.events.map {
          $0.kind.rawValue + " "
            + dateLabel(SolarEventPresentation.minute($0.date, in: timeZone), style: .clock)
        }.joined(separator: " · "), .init(x: 12, y: y + 70, width: width - 24, height: 16),
        size: 10, color: .secondaryLabelColor)
    }
    attribution()
  }
  var solarDescription: String {
    guard let day = solarDay else { return "Daylight estimate unavailable" }
    var events = day.events.map {
      "Estimated \($0.kind.rawValue) \(dateLabel(SolarEventPresentation.minute($0.date, in: timeZone), style: .forecast))"
    }
    for kind in [SolarDay.Kind.sunrise, .sunset]
    where !day.events.contains(where: { $0.kind == kind }) {
      events.append("No \(kind.rawValue) within this civil day")
    }
    let state: String
    switch day.state {
    case .crossings: state = events.joined(separator: "; ")
    case .sunUpAllDay: state = "Sun up throughout this civil day"
    case .sunDownAllDay: state = "Sun below the apparent horizon throughout this civil day"
    }
    return "\(state). Daylight \(duration(day.daylightDuration)) in \(timeZone.identifier). "
      + "This civil day is \(duration(day.interval.duration)); the accent fill is estimated daylight, unfilled intervals have the sun below the apparent horizon. "
      + "Times and duration are independently rounded to the nearest minute. Very short intervals have a minimum visible width; use numerical times and duration for precision. "
      + "Now \(dateLabel(solarNow, style: .clockZone)). Local NOAA-based calculation, not a forecast. "
      + "Approximate level, unobstructed horizon; terrain and actual atmospheric refraction can change observed times."
  }
  private func duration(_ seconds: Double) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    return minutes == 0 && seconds > 0 ? "<1 min" : "\(minutes / 60)h \(minutes % 60)m"
  }
  private func drawSolarDay() {
    guard showsSolar, let day = solarDay else { return }
    let rect = solarFrame
    panel(rect)
    text(
      "Est. daylight · \(duration(day.daylightDuration))",
      .init(x: 12, y: rect.minY + 9, width: rect.width - 24, height: 14), size: 10,
      color: .secondaryLabelColor)
    if day.state == .crossings {
      for (index, kind) in [SolarDay.Kind.sunrise, .sunset].enumerated() {
        let x = 12 + CGFloat(index) * (rect.width - 24) / 2
        symbol(
          kind.rawValue, .init(x: x, y: rect.minY + 29, width: 16, height: 16),
          color: SystemStyle.accent
        )
        let times = day.events.filter { $0.kind == kind }.map {
          dateLabel(SolarEventPresentation.minute($0.date, in: timeZone), style: .clock)
        }
        let value = times.first.map { $0 + (times.count > 1 ? " +\(times.count - 1)" : "") } ?? "—"
        text(
          value,
          .init(x: x + 20, y: rect.minY + 29, width: (rect.width - 24) / 2 - 20, height: 16),
          size: 11,
          weight: .medium)
      }
    } else {
      text(
        day.state == .sunUpAllDay ? "Sun up all day" : "Sun down all day",
        .init(x: 12, y: rect.minY + 29, width: rect.width - 24, height: 16), size: 12,
        weight: .medium)
    }
    capsule(solarTrack, .quaternaryLabelColor)
    for interval in day.daylight {
      let left = interval.start.timeIntervalSince(day.interval.start) / day.interval.duration
      let width = interval.duration / day.interval.duration
      capsule(
        .init(
          x: solarTrack.minX + solarTrack.width * left, y: solarTrack.minY,
          width: min(solarTrack.width * (1 - left), max(1, solarTrack.width * width)),
          height: solarTrack.height), SystemStyle.accent)
    }
    let now = solarNow.timeIntervalSince(day.interval.start) / day.interval.duration
    if (0..<1).contains(now) {
      NSColor.labelColor.setFill()
      NSBezierPath(
        ovalIn: .init(
          x: solarTrack.minX + solarTrack.width * now - 2,
          y: solarTrack.midY - 2, width: 4, height: 4)
      ).fill()
    }
    if rect.height >= 100 {
      text(
        "\(dateLabel(solarNow, style: .clock)) now",
        .init(x: 12, y: rect.minY + 66, width: rect.width - 24, height: 16), size: 11,
        color: .secondaryLabelColor)
      text(
        "Local calculation · hover for details",
        .init(x: 12, y: rect.maxY - 20, width: rect.width - 24, height: 15), size: 9,
        color: .secondaryLabelColor)
    }
  }
  private func attribution() {
    text(
      "Data from MET Norway · CC BY 4.0 · api.met.no/doc/License",
      .init(x: 0, y: bounds.height - 16, width: bounds.width, height: 16), size: 10,
      color: .secondaryLabelColor)
  }
  private func drawWind(at center: NSPoint) {
    text(
      "N", .init(x: center.x - 4, y: center.y - 18, width: 8, height: 8), size: 7,
      color: .secondaryLabelColor, alignment: .center)
    NSColor.quaternaryLabelColor.setStroke()
    NSBezierPath(ovalIn: .init(x: center.x - 9, y: center.y - 9, width: 18, height: 18)).stroke()
    guard let direction = current?.windFromDegrees, direction.isFinite,
      (0...360).contains(direction)
    else { return }
    let angle = direction * .pi / 180
    let end = NSPoint(x: center.x + sin(angle) * 8, y: center.y - cos(angle) * 8)
    let path = NSBezierPath()
    path.move(to: center)
    path.line(to: end)
    SystemStyle.accent.setStroke()
    path.lineWidth = 2
    path.stroke()
    SystemStyle.accent.setFill()
    NSBezierPath(ovalIn: .init(x: end.x - 2, y: end.y - 2, width: 4, height: 4)).fill()
  }
  private func panel(_ rect: NSRect) {
    SystemStyle.drawPlatter(rect)
  }
  private func capsule(_ rect: NSRect, _ color: NSColor) {
    guard rect.width > 0 else { return }
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
  }
  private func symbol(_ name: String, _ rect: NSRect, color: NSColor) {
    guard
      let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [color]))
    else { return }
    image.draw(
      in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
  private func text(
    _ string: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor, alignment: NSTextAlignment = .left, wrapping: Bool = false
  ) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
    (string as NSString).draw(
      in: rect,
      withAttributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: style,
      ])
  }
}
