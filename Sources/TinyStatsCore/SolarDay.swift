import Foundation

/// Local, approximate apparent sunrise/sunset at a level, unobstructed horizon.
/// Original implementation of NOAA/Meeus solar-coordinate equations:
/// https://gml.noaa.gov/grad/solcalc/calcdetails.html
/// No atmosphere/terrain observations, transport, timer or persistent state.
public struct SolarDay: Equatable, Sendable {
  static let timestampBounds = -2_208_988_800.0...4_133_980_800.0
  public enum Kind: String, Equatable, Sendable { case sunrise, sunset }
  public struct Event: Equatable, Sendable {
    public let kind: Kind
    public let date: Date
  }
  public enum State: Equatable, Sendable {
    case crossings, sunUpAllDay, sunDownAllDay
  }
  public let interval: DateInterval
  public let timeZone: String
  public let events: [Event]
  /// Intersections with this actual civil day, including daylight across midnight.
  public let daylight: [DateInterval]
  public var daylightDuration: TimeInterval { daylight.reduce(0) { $0 + $1.duration } }
  public var state: State {
    if !events.isEmpty { return .crossings }
    return daylight.isEmpty ? .sunDownAllDay : .sunUpAllDay
  }
  public func isDaylight(at date: Date) -> Bool {
    daylight.contains { date >= $0.start && date < $0.end }
  }
  /// The supported Gregorian date range is deliberately bounded. Time-zone rules,
  /// rather than a fixed UTC offset or 86,400-second assumption, define the day.
  public static func calculate(on date: Date, location: WeatherLocation) -> Self? {
    guard date.timeIntervalSince1970.isFinite, timestampBounds.contains(date.timeIntervalSince1970),
      let location = location.validated,
      let zone = TimeZone(identifier: location.timeZone)
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    guard (1901...2099).contains(calendar.component(.year, from: date)),
      let day = calendar.dateInterval(of: .day, for: date),
      (20 * 3600...28 * 3600).contains(day.duration)
    else { return nil }
    let origin = day.start.timeIntervalSince1970
    // Apparent upper limb: fixed solar-radius/refraction correction, not a
    // weather-dependent prediction. Search sine altitude to avoid acos at poles.
    let horizon = sin(-0.833 * .pi / 180)
    func height(_ offset: Double) -> Double {
      elevationSine(
        unixSeconds: origin + offset, latitude: location.latitude,
        longitude: location.longitude) - horizon
    }
    let count = Int(ceil(day.duration / 600))
    var nodes =
      [-600.0] + (0...count).map { min(day.duration, Double($0) * 600) }
      + [day.duration + 600]
    let heights = nodes.map(height)
    // Refine every bracketed extremum before finding crossings. A short polar
    // daylight/night interval can lie entirely between the coarse samples.
    // Include extrema whose closest coarse node is the civil-day start/end.
    // Crossings outside the actual day are filtered below, not integrated.
    let coarseCount = nodes.count
    for index in 1..<(coarseCount - 1) {
      let a = heights[index - 1]
      let b = heights[index]
      let c = heights[index + 1]
      let maximum = b > a && b >= c
      let minimum = b < a && b <= c
      guard maximum || minimum else { continue }
      var left = nodes[index - 1]
      var right = nodes[index + 1]
      for _ in 0..<48 {
        if right - left < 0.02 { break }
        let p = left + (right - left) / 3
        let q = right - (right - left) / 3
        if (height(p) < height(q)) == maximum { left = p } else { right = q }
      }
      nodes.append((left + right) / 2)
    }
    nodes.sort()
    var events: [Event] = []
    for (a, b) in zip(nodes, nodes.dropFirst()) {
      let ha = height(a)
      let hb = height(b)
      let rises = ha <= 0 && hb > 0
      let sets = ha > 0 && hb <= 0
      guard rises || sets else { continue }
      var left = a
      var right = b
      for _ in 0..<32 {
        if right - left < 0.02 { break }
        let middle = (left + right) / 2
        if (height(middle) > 0) == (ha > 0) { left = middle } else { right = middle }
      }
      let offset = (left + right) / 2
      guard offset >= 0 && offset < day.duration else { continue }
      events.append(
        .init(kind: rises ? .sunrise : .sunset, date: day.start.addingTimeInterval(offset)))
    }
    guard events.count <= 6 else { return nil }
    let boundaries = [day.start] + events.map(\.date) + [day.end]
    var daylight: [DateInterval] = []
    for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
      if height(start.timeIntervalSince(day.start) + end.timeIntervalSince(start) / 2) > 0 {
        daylight.append(.init(start: start, end: end))
      }
    }
    return Self(interval: day, timeZone: zone.identifier, events: events, daylight: daylight)
  }

  /// Geocentric geometric solar-center elevation; fixed apparent-horizon
  /// correction is applied only by the crossing calculation above.
  static func elevationSine(unixSeconds: Double, latitude: Double, longitude: Double) -> Double {
    let t = (unixSeconds / 86400 + 2440587.5 - 2_451_545) / 36525
    let radians = Double.pi / 180
    func normalized(_ degrees: Double) -> Double {
      let value = degrees.truncatingRemainder(dividingBy: 360)
      return value < 0 ? value + 360 : value
    }
    let meanLongitude = normalized(280.46646 + t * (36000.76983 + t * 0.0003032)) * radians
    let anomaly = (357.52911 + t * (35999.05029 - 0.0001537 * t)) * radians
    let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    let center =
      sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
      + sin(2 * anomaly) * (0.019993 - 0.000101 * t) + sin(3 * anomaly) * 0.000289
    let omega = (125.04 - 1934.136 * t) * radians
    let apparentLongitude = meanLongitude + (center - 0.00569 - 0.00478 * sin(omega)) * radians
    let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
    let obliquity = (meanObliquity + 0.00256 * cos(omega)) * radians
    let declination = asin(sin(obliquity) * sin(apparentLongitude))
    let y = pow(tan(obliquity / 2), 2)
    let equation =
      4 / radians
      * (y * sin(2 * meanLongitude) - 2 * eccentricity * sin(anomaly)
        + 4 * eccentricity * y * sin(anomaly) * cos(2 * meanLongitude)
        - 0.5 * y * y * sin(4 * meanLongitude) - 1.25 * eccentricity * eccentricity
        * sin(2 * anomaly))
    let utc = unixSeconds - floor(unixSeconds / 86400) * 86400
    let hourAngle = (utc / 240 + longitude + equation / 4 - 180) * radians
    let lat = latitude * radians
    return sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)
  }
}

/// One-entry cache, confined to its owning queue. Not Sendable. The two Weather
/// presentations share this instance; identical ticks never repeat the solver.
public final class SolarDayCalculator {
  private struct Key: Equatable {
    var day: Date
    var latitude: Double
    var longitude: Double
    var zone: String
  }
  private var key: Key?
  public private(set) var value: SolarDay?
  public init() {}
  public func day(on date: Date, location: WeatherLocation?) -> SolarDay? {
    guard date.timeIntervalSince1970.isFinite,
      SolarDay.timestampBounds.contains(date.timeIntervalSince1970),
      let location = location?.validated,
      let zone = TimeZone(identifier: location.timeZone)
    else {
      key = nil
      value = nil
      return nil
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let next = Key(
      day: calendar.startOfDay(for: date), latitude: location.latitude,
      longitude: location.longitude, zone: zone.identifier)
    if key != next {
      key = next
      value = SolarDay.calculate(on: date, location: location)
    }
    return value
  }
}
