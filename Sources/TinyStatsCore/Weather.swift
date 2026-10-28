import Darwin
import Foundation

/// A validated forecast location. No IP-based location inference is used.
public struct WeatherLocation: Codable, Equatable, Sendable {
  public var latitude: Double
  public var longitude: Double
  public var name: String
  public var timeZone: String
  public init(latitude: Double, longitude: Double, name: String, timeZone: String) {
    self.latitude = latitude
    self.longitude = longitude
    self.name = name
    self.timeZone = timeZone
  }
  public var validated: Self? {
    guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
      (-180...180).contains(longitude), TimeZone(identifier: timeZone) != nil,
      name.utf8.count <= 128,
      !name.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
      })
    else { return nil }
    var result = self
    // At most three decimals (~110 m latitude); also improves provider cache reuse.
    result.latitude = (latitude * 1000).rounded(.toNearestOrAwayFromZero) / 1000
    result.longitude = (longitude * 1000).rounded(.toNearestOrAwayFromZero) / 1000
    if result.latitude == 0 { result.latitude = 0 }
    if result.longitude == 0 { result.longitude = 0 }
    result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return result
  }
  var requestKey: String {
    String(format: "%.3f,%.3f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
  }
  public var displayName: String { name.isEmpty ? requestKey : name }
}

public enum WeatherLocationSource: String, Codable, Sendable {
  case manual, currentLocation
}
public struct WeatherSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var location: WeatherLocation?
  public var revision = ""
  public var source: WeatherLocationSource = .manual
  public init() {}
  public mutating func validate() {
    location = location?.validated
    if revision.utf8.count > 64
      || !revision.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      })
    {
      revision = ""
      enabled = false
    }
    if location == nil && source == .manual { enabled = false }
  }
  public static var currentLocationDefault: Self {
    var value = Self()
    value.enabled = true
    value.source = .currentLocation
    return value
  }
  public mutating func prepareForSession() {
    if source == .currentLocation { location = nil }
  }
  /// UI edits cannot reintroduce a stored fix after opt-out or a source change.
  public mutating func prepareForChange(from previous: Self) {
    if source == .currentLocation {
      location =
        enabled && previous.enabled && previous.source == .currentLocation
        ? previous.location : nil
    }
  }
  private enum CodingKeys: String, CodingKey { case enabled, location, revision, source }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? false
    location = try? values.decode(WeatherLocation.self, forKey: .location)
    revision = (try? values.decode(String.self, forKey: .revision)) ?? ""
    if values.contains(.source) {
      if let decoded = try? values.decode(WeatherLocationSource.self, forKey: .source) {
        source = decoded
      } else {
        enabled = false
        location = nil
      }
    }
    validate()
  }
}

public struct WeatherPoint: Sendable, Equatable {
  public var date: Date
  public var celsius: Double?
  public var humidity: Double?
  public var windMetersPerSecond: Double?
  public var pressureHPa: Double?
  public var cloudCover: Double?
  public var windFromDegrees: Double?
  public var symbol: String?
  public var precipitationMM: Double?
  public var periodHours: Int?
  public init(
    date: Date, celsius: Double?, humidity: Double? = nil, windMetersPerSecond: Double? = nil,
    pressureHPa: Double? = nil, symbol: String? = nil, precipitationMM: Double? = nil,
    periodHours: Int? = nil, cloudCover: Double? = nil, windFromDegrees: Double? = nil
  ) {
    self.date = date
    self.celsius = celsius
    self.humidity = humidity
    self.windMetersPerSecond = windMetersPerSecond
    self.pressureHPa = pressureHPa
    self.cloudCover = cloudCover
    self.windFromDegrees = windFromDegrees
    self.symbol = symbol
    self.precipitationMM = precipitationMM
    self.periodHours = periodHours
  }
  public var condition: String {
    guard let symbol else { return "Condition unavailable" }
    let base = symbol.split(separator: "_").first.map(String.init) ?? symbol
    switch base {
    case "clearsky": return "Clear"
    case "fair": return "Mostly clear"
    case "partlycloudy": return "Partly cloudy"
    case "cloudy": return "Cloudy"
    case "fog": return "Fog"
    default:
      if base.contains("thunder") { return "Thunderstorms" }
      if base.contains("sleet") { return "Sleet" }
      if base.contains("snow") { return "Snow" }
      if base.contains("rain") { return "Rain" }
      return "Condition unavailable"
    }
  }
  public var systemSymbol: String {
    guard let symbol else { return "questionmark.circle" }
    let base = symbol.split(separator: "_").first.map(String.init) ?? symbol
    if base.contains("thunder") { return "cloud.bolt.rain" }
    if base.contains("sleet") { return "cloud.sleet" }
    if base.contains("snow") { return "cloud.snow" }
    if base.contains("rain") { return "cloud.rain" }
    if base == "fog" { return "cloud.fog" }
    if base == "clearsky" { return symbol.hasSuffix("_night") ? "moon.stars" : "sun.max" }
    if base == "fair" || base == "partlycloudy" {
      return symbol.hasSuffix("_night") ? "cloud.moon" : "cloud.sun"
    }
    return base == "cloudy" ? "cloud" : "questionmark.circle"
  }
}

public struct WeatherForecast: Sendable, Equatable {
  public var generatedAt: Date
  public var points: [WeatherPoint]
  public init(generatedAt: Date, points: [WeatherPoint]) {
    self.generatedAt = generatedAt
    self.points = Array(points.prefix(256))
  }
  /// "Now" is a model forecast, never presented as a local sensor observation.
  public func current(at date: Date) -> WeatherPoint? {
    points.last { $0.date <= date && date.timeIntervalSince($0.date) <= 3 * 3600 }
  }
}

public struct WeatherSnapshot: Sendable, Equatable {
  public var settings = WeatherSettings()
  public var forecast: WeatherForecast?
  public var receivedAt: Double?
  public var checking = false
  public var reason = "Weather is off"
  public var nextRequestAt: Double?
  public init() {}
  /// Provider-supplied cache/backoff durations need not fit in an Int.
  public func checkedAge(at uptime: Double) -> String? {
    guard let receivedAt, uptime.isFinite else { return nil }
    let elapsed = uptime - receivedAt
    guard elapsed.isFinite, elapsed >= 0 else { return "Unavailable" }
    guard elapsed <= 366 * 24 * 3600 else { return ">1 year ago" }
    return "\(Int(elapsed / 60))m ago"
  }
  public func requestWait(at uptime: Double) -> String? {
    guard let nextRequestAt, uptime.isFinite, nextRequestAt > uptime else { return nil }
    let remaining = nextRequestAt - uptime
    guard remaining.isFinite, remaining <= 366 * 24 * 3600 else { return ">1 year" }
    return "At least \(Int(ceil(remaining / 60)))m"
  }
  public func filtered(settings: WeatherSettings, suspended: Bool = false) -> Self {
    guard !suspended, settings.enabled, self.settings == settings else { return .init() }
    return self
  }
  public func isFresh(at uptime: Double, date: Date) -> Bool {
    guard let forecast, let receivedAt, uptime.isFinite, uptime >= receivedAt,
      uptime - receivedAt <= 3 * 3600,
      date.timeIntervalSince(forecast.generatedAt) >= -300,
      date.timeIntervalSince(forecast.generatedAt) <= 24 * 3600
    else { return false }
    return true
  }
  public func validUntil(at uptime: Double, date: Date) -> Double? {
    guard isFresh(at: uptime, date: date), let forecast, let receivedAt,
      let point = forecast.current(at: date)
    else { return nil }
    return min(
      receivedAt + 3 * 3600, uptime + 24 * 3600 - date.timeIntervalSince(forecast.generatedAt),
      uptime + 3 * 3600 - date.timeIntervalSince(point.date))
  }
  public func current(at uptime: Double, date: Date) -> WeatherPoint? {
    isFresh(at: uptime, date: date) ? forecast?.current(at: date) : nil
  }
}

/// JSON decoding is bounded by the transport's 256 KiB cap and 512 input timestamps.
/// Only 256 relevant points survive decoding. Unknown units never become guessed values.
enum WeatherDecoder {
  static let bodyLimit = 256 * 1024
  private struct Document: Decodable {
    var properties: Properties
  }
  private struct Properties: Decodable {
    var meta: Meta
    var timeseries: [Entry]
    private enum CodingKeys: String, CodingKey { case meta, timeseries }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      meta = try values.decode(Meta.self, forKey: .meta)
      var sequence = try values.nestedUnkeyedContainer(forKey: .timeseries)
      timeseries = []
      while !sequence.isAtEnd {
        guard timeseries.count < 512 else { throw Failure.invalid }
        timeseries.append(try sequence.decode(Entry.self))
      }
    }
  }
  private struct Meta: Decodable {
    var updatedAt: String
    private enum CodingKeys: String, CodingKey {
      case updatedAt = "updated_at"
      case units
    }
    var units: [String: String]
  }
  private struct Entry: Decodable {
    var time: String
    var data: Values
  }
  private struct Values: Decodable {
    var instant: Instant
    var nextOneHours: Period?
    var nextSixHours: Period?
    var nextTwelveHours: Period?
    private enum CodingKeys: String, CodingKey {
      case instant
      case nextOneHours = "next_1_hours"
      case nextSixHours = "next_6_hours"
      case nextTwelveHours = "next_12_hours"
    }
  }
  private struct Instant: Decodable { var details: [String: Double?] }
  private struct Period: Decodable {
    var summary: Summary?
    var details: [String: Double?]?
  }
  private struct Summary: Decodable {
    var symbolCode: String?
    private enum CodingKeys: String, CodingKey { case symbolCode = "symbol_code" }
  }
  enum Failure: Error { case invalid }
  static func decode(_ data: Data, now: Date) throws -> WeatherForecast {
    guard data.count <= bodyLimit else { throw Failure.invalid }
    let document = try JSONDecoder().decode(Document.self, from: data).properties
    let parser = ISO8601DateFormatter()
    guard let generated = parser.date(from: document.meta.updatedAt),
      now.timeIntervalSince(generated) >= -300, now.timeIntervalSince(generated) <= 24 * 3600,
      document.meta.units["air_temperature"] == "celsius"
    else { throw Failure.invalid }
    var points: [WeatherPoint] = []
    var previous: Date?
    for entry in document.timeseries {
      guard let date = parser.date(from: entry.time), previous.map({ date > $0 }) ?? true else {
        throw Failure.invalid
      }
      previous = date
      guard date >= now.addingTimeInterval(-3 * 3600),
        date <= now.addingTimeInterval(10 * 24 * 3600), points.count < 256
      else { continue }
      let details = entry.data.instant.details
      func number(_ key: String, unit: String, range: ClosedRange<Double>) -> Double? {
        guard document.meta.units[key] == unit, let value = details[key] ?? nil,
          value.isFinite, range.contains(value)
        else { return nil }
        return value
      }
      let period: Period?
      let hours: Int?
      if let value = entry.data.nextOneHours {
        period = value
        hours = 1
      } else if let value = entry.data.nextSixHours {
        period = value
        hours = 6
      } else if let value = entry.data.nextTwelveHours {
        period = value
        hours = 12
      } else {
        period = nil
        hours = nil
      }
      let rawSymbol = period?.summary?.symbolCode
      let symbol = rawSymbol.flatMap { value in
        value.utf8.count <= 64
          && value.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) ? value : nil
      }
      let rawPrecipitation = period?.details?["precipitation_amount"] ?? nil
      let precipitation = rawPrecipitation.flatMap { value in
        document.meta.units["precipitation_amount"] == "mm" && value.isFinite
          && (0...2000).contains(value) ? value : nil
      }
      points.append(
        .init(
          date: date, celsius: number("air_temperature", unit: "celsius", range: -150...100),
          humidity: number("relative_humidity", unit: "%", range: 0...100),
          windMetersPerSecond: number("wind_speed", unit: "m/s", range: 0...200),
          pressureHPa: number("air_pressure_at_sea_level", unit: "hPa", range: 500...1200),
          symbol: symbol, precipitationMM: precipitation, periodHours: hours,
          cloudCover: number("cloud_area_fraction", unit: "%", range: 0...100),
          windFromDegrees: number("wind_from_direction", unit: "degrees", range: 0...360)))
    }
    guard !points.isEmpty else { throw Failure.invalid }
    return .init(generatedAt: generated, points: points)
  }
}

struct WeatherReply: Sendable {
  var status: Int?
  var data = Data()
  var expires: Date?
  var lastModified: String?
  var retryAfter: Double?
  var failure: HTTPProbeFailure?
}
protocol WeatherTransport: AnyObject, Sendable {
  func start(
    location: WeatherLocation, lastModified: String?,
    completion: @escaping @Sendable (WeatherReply) -> Void)
  func cancel()
  func shutdown()
}

/// Pure request/cache state. Shared sampler ticks supply all scheduling and timeouts.
struct WeatherLedger {
  private(set) var snapshot = WeatherSnapshot()
  private(set) var generation: UInt64 = 0
  private(set) var active: (token: UInt64, started: Double)?
  private var globalNext = -Double.infinity
  // Never evict an unexpired deadline to issue an early repeat request after location edits.
  private var deadlines: [String: Double] = [:]
  private var lastModified: String?
  private let jitter: Double
  init(jitter: Double = Double.random(in: 0...300)) { self.jitter = max(0, min(jitter, 300)) }
  @discardableResult mutating func configure(_ proposed: WeatherSettings) -> Bool {
    guard proposed != snapshot.settings else { return false }
    var settings = proposed
    settings.validate()
    guard settings != snapshot.settings else { return false }
    let sameCoordinates = settings.location?.requestKey == snapshot.settings.location?.requestKey
    generation &+= 1
    active = nil
    if !settings.enabled || !sameCoordinates {
      snapshot.forecast = nil
      snapshot.receivedAt = nil
      lastModified = nil
    }
    snapshot.settings = settings
    snapshot.checking = false
    snapshot.reason = settings.enabled ? "Waiting for forecast" : "Weather is off"
    return true
  }
  mutating func suspend() {
    generation &+= 1
    active = nil
    snapshot.checking = false
  }
  mutating func next(at time: Double) -> (WeatherLocation, String?)? {
    guard time.isFinite, snapshot.settings.enabled, let location = snapshot.settings.location else {
      return nil
    }
    deadlines = deadlines.filter { $0.value > time }
    let capacityDeadline =
      deadlines.count >= 8 && deadlines[location.requestKey] == nil
      ? deadlines.values.min() ?? time : time
    let due = max(globalNext, deadlines[location.requestKey] ?? time, capacityDeadline)
    snapshot.nextRequestAt = due
    guard active == nil, time >= due else { return nil }
    generation &+= 1
    active = (generation, time)
    globalNext = time + 60
    deadlines[location.requestKey] = time + 1800 + jitter
    snapshot.checking = true
    return (location, snapshot.forecast == nil ? nil : lastModified)
  }
  mutating func finish(_ reply: WeatherReply, token: UInt64, at time: Double, date: Date) {
    guard let active, active.token == token, token == generation,
      time.isFinite, time >= active.started, snapshot.settings.enabled,
      let key = snapshot.settings.location?.requestKey
    else { return }
    self.active = nil
    snapshot.checking = false
    let expiry = reply.expires.map { max(0, $0.timeIntervalSince(date)) } ?? 0
    var delay = max(1800 + jitter, expiry)
    if reply.status == 429 || reply.status == 503 {
      delay = max(delay, 3600, reply.retryAfter ?? 0)
      globalNext = max(globalNext, time + delay)
    }
    deadlines[key] = max(deadlines[key] ?? time, time + delay)
    snapshot.nextRequestAt = deadlines[key]
    guard reply.failure == nil else {
      snapshot.reason = reply.failure!.rawValue
      return
    }
    if reply.status == 304, snapshot.forecast != nil {
      snapshot.receivedAt = time
      snapshot.reason = "Cached forecast confirmed"
    } else if reply.status == 200 || reply.status == 203 {
      guard let forecast = try? WeatherDecoder.decode(reply.data, now: date) else {
        snapshot.reason = "Invalid forecast response"
        return
      }
      snapshot.forecast = forecast
      snapshot.receivedAt = time
      lastModified = reply.lastModified
      snapshot.reason = reply.status == 203 ? "Provider API deprecated" : "MET Norway forecast"
    } else {
      snapshot.reason =
        reply.status.map { "Weather request: HTTP \($0)" } ?? "Weather request failed"
    }
  }
}

final class WeatherReader: @unchecked Sendable {
  private let lock = NSLock()
  private let transport: any WeatherTransport
  private let clock: @Sendable () -> Double
  private let wallClock: @Sendable () -> Date
  private var ledger: WeatherLedger
  init(
    transport: any WeatherTransport = NativeWeatherTransport(),
    clock: @escaping @Sendable () -> Double = {
      Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    },
    wallClock: @escaping @Sendable () -> Date = { Date() },
    jitter: Double = Double.random(in: 0...300)
  ) {
    self.transport = transport
    self.clock = clock
    self.wallClock = wallClock
    ledger = WeatherLedger(jitter: jitter)
  }
  deinit { transport.shutdown() }
  func configure(_ settings: WeatherSettings) {
    lock.lock()
    let changed = ledger.configure(settings)
    lock.unlock()
    if changed {
      transport.cancel()
      if !settings.enabled { transport.shutdown() }
    }
  }
  func suspend() {
    lock.lock()
    ledger.suspend()
    lock.unlock()
    transport.shutdown()
  }
  /// Deadlines/age use a sleep-inclusive clock. Public timestamps use the sampler's
  /// awake-time reference, preserving existing UI and notification comparisons.
  func read(at uptime: Double = ProcessInfo.processInfo.systemUptime) -> WeatherSnapshot {
    let now = clock()
    let date = wallClock()
    lock.lock()
    let timedOut = ledger.active.map { now - $0.started >= 30 } ?? false
    if timedOut, let active = ledger.active {
      ledger.finish(.init(failure: .timeout), token: active.token, at: now, date: date)
    }
    let request = ledger.next(at: now)
    let token = ledger.generation
    var result = ledger.snapshot
    if now.isFinite && uptime.isFinite {
      result.receivedAt = result.receivedAt.map { uptime - (now - $0) }
      result.nextRequestAt = result.nextRequestAt.map { uptime + ($0 - now) }
    } else {
      result.forecast = nil
      result.receivedAt = nil
      result.nextRequestAt = nil
      result.reason = "Clock unavailable"
    }
    lock.unlock()
    if timedOut { transport.cancel() }
    if let (location, modified) = request {
      transport.start(location: location, lastModified: modified) { [weak self] reply in
        guard let self else { return }
        let time = self.clock()
        let date = self.wallClock()
        self.lock.lock()
        self.ledger.finish(reply, token: token, at: time, date: date)
        self.lock.unlock()
      }
    }
    return result
  }
}
