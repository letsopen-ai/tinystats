import Foundation
import Testing

@testable import TinyStatsCore

private let weatherDate = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
private func location(_ latitude: Double = 60.1) -> WeatherLocation {
  .init(latitude: latitude, longitude: 9.58, name: "Fixture", timeZone: "Europe/Oslo")
}
private func weatherSettings(_ latitude: Double = 60.1, revision: String = "fixture")
  -> WeatherSettings
{
  var value = WeatherSettings()
  value.enabled = true
  value.location = location(latitude)
  value.revision = revision
  value.validate()
  return value
}
private func forecastData(
  count: Int = 36, temperatureUnit: String = "celsius", duplicate: Bool = false
) -> Data {
  let formatter = ISO8601DateFormatter()
  let entries: [[String: Any]] = (0..<count).map { index in
    let time = weatherDate.addingTimeInterval(Double(duplicate ? 0 : index) * 3600)
    return [
      "time": formatter.string(from: time),
      "data": [
        "instant": [
          "details": [
            "air_temperature": index == 0 ? -2.0 : Double(index), "relative_humidity": 0.0,
            "wind_speed": 0.0, "air_pressure_at_sea_level": 1012.0,
            "cloud_area_fraction": 25.0, "wind_from_direction": 360.0,
          ]
        ],
        "next_1_hours": [
          "summary": ["symbol_code": "partlycloudy_day"], "details": ["precipitation_amount": 0.0],
        ],
      ],
    ]
  }
  return try! JSONSerialization.data(withJSONObject: [
    "properties": [
      "meta": [
        "updated_at": formatter.string(from: weatherDate),
        "units": [
          "air_temperature": temperatureUnit, "relative_humidity": "%", "wind_speed": "m/s",
          "air_pressure_at_sea_level": "hPa", "precipitation_amount": "mm",
          "cloud_area_fraction": "%", "wind_from_direction": "degrees",
        ],
      ], "timeseries": entries,
    ]
  ])
}

@Test func weatherDefaultsStayOffAndInvalidConfigurationFailsClosedIndependently() throws {
  let defaults = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
  #expect(!defaults.weather.enabled && defaults.weather.location == nil)
  let damaged = try JSONDecoder().decode(
    Settings.self,
    from: Data(
      #"{"theme":"dark","weather":{"enabled":true,"location":{"latitude":91,"longitude":0,"name":"invalid","timeZone":"UTC"}}}"#
        .utf8))
  #expect(damaged.theme == .dark && !damaged.weather.enabled)
  var settings = Settings()
  settings.weather = weatherSettings()
  let copy = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  #expect(copy.weather == settings.weather)
  for coordinate in [Double.nan, .infinity, -91, 91] {
    #expect(location(coordinate).validated == nil)
  }
  var value = location(1.00149)
  let canonical = try #require(value.validated)
  #expect(canonical.latitude == 1.001 && canonical.validated == canonical)
  value.longitude = -0.00001
  #expect(value.validated?.requestKey == "1.001,0.000")
  value.name = "fixture\ncontrol"
  #expect(value.validated == nil)
  value = location()
  value.timeZone = "not-a-zone"
  #expect(value.validated == nil)
  var config = weatherSettings()
  config.revision = "bad\nrevision"
  config.validate()
  #expect(!config.enabled)
}

@Test func weatherDecodingRetainsSignedZeroAndPeriodUnitsWithoutInventingObservations() throws {
  let data = forecastData()
  let forecast = try WeatherDecoder.decode(data, now: weatherDate.addingTimeInterval(600))
  let point = try #require(forecast.current(at: weatherDate.addingTimeInterval(600)))
  #expect(point.celsius == -2 && point.humidity == 0 && point.windMetersPerSecond == 0)
  #expect(point.precipitationMM == 0 && point.periodHours == 1)
  #expect(point.cloudCover == 25 && point.windFromDegrees == 360)
  #expect(point.condition == "Partly cloudy" && point.systemSymbol == "cloud.sun")
  #expect(WeatherPoint(date: weatherDate, celsius: nil).systemSymbol == "questionmark.circle")
  #expect(
    WeatherPoint(date: weatherDate, celsius: nil, symbol: "unknown_day").systemSymbol
      == "questionmark.circle")
  #expect(WeatherPoint(date: weatherDate, celsius: 10, symbol: "cloudy").systemSymbol == "cloud")
  #expect(forecast.current(at: weatherDate.addingTimeInterval(-1)) == nil)
  #expect(forecast.current(at: weatherDate.addingTimeInterval(40 * 3600)) == nil)
  #expect(throws: (any Error).self) {
    try WeatherDecoder.decode(forecastData(temperatureUnit: "fahrenheit"), now: weatherDate)
  }
  #expect(throws: (any Error).self) {
    try WeatherDecoder.decode(forecastData(duplicate: true), now: weatherDate)
  }
  #expect(throws: (any Error).self) {
    try WeatherDecoder.decode(forecastData(count: 513), now: weatherDate)
  }
  #expect(throws: (any Error).self) {
    try WeatherDecoder.decode(
      Data(repeating: 32, count: WeatherDecoder.bodyLimit + 1), now: weatherDate)
  }
  #expect(throws: (any Error).self) {
    try WeatherDecoder.decode(data, now: weatherDate.addingTimeInterval(25 * 3600))
  }
  #expect(throws: (any Error).self) {
    try WeatherDecoder.decode(data, now: weatherDate.addingTimeInterval(-301))
  }
  var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var properties = try #require(json["properties"] as? [String: Any])
  var meta = try #require(properties["meta"] as? [String: Any])
  var units = try #require(meta["units"] as? [String: String])
  units["wind_speed"] = "km/h"
  meta["units"] = units
  properties["meta"] = meta
  json["properties"] = properties
  let changed = try WeatherDecoder.decode(
    JSONSerialization.data(withJSONObject: json), now: weatherDate)
  #expect(changed.current(at: weatherDate)?.windMetersPerSecond == nil)
}

@Test func weatherLedgerHonorsExpiryConditionalCacheRateLimitsAndLateResultRejection() throws {
  var ledger = WeatherLedger(jitter: 0)
  #expect(ledger.next(at: 0) == nil)
  let enabled = ledger.configure(weatherSettings())
  #expect(enabled)
  #expect(ledger.next(at: 0)?.0 == location().validated)
  let first = try #require(ledger.active)
  #expect(ledger.next(at: 1) == nil)
  let modified = "Thu, 22 Oct 2026 12:00:00 GMT"
  ledger.finish(
    .init(
      status: 200, data: forecastData(), expires: weatherDate.addingTimeInterval(7200),
      lastModified: modified), token: first.token, at: 1, date: weatherDate)
  #expect(ledger.snapshot.forecast?.points.count == 36)
  #expect(ledger.next(at: 7200) == nil)
  #expect(ledger.next(at: 7201)?.1 == modified)
  let second = try #require(ledger.active)
  ledger.finish(.init(failure: .connection), token: first.token, at: 7202, date: weatherDate)
  #expect(ledger.active?.token == second.token)
  ledger.finish(.init(status: 304), token: second.token, at: 7202, date: weatherDate)
  #expect(ledger.snapshot.forecast != nil && ledger.snapshot.receivedAt == 7202)
  ledger.suspend()
  #expect(ledger.next(at: 7203) == nil)
  let before = ledger.snapshot.forecast
  let moved = ledger.configure(weatherSettings(61))
  #expect(moved)
  #expect(ledger.snapshot.forecast == nil)
  #expect(ledger.next(at: 7261)?.1 == nil)
  let switched = try #require(ledger.active)
  ledger.configure(.init())
  ledger.finish(
    .init(status: 200, data: forecastData()), token: switched.token, at: 7262, date: weatherDate)
  #expect(ledger.snapshot.forecast == nil && !ledger.snapshot.settings.enabled)
  #expect(before != nil)
  ledger.configure(weatherSettings())
  // Prior coordinate’s unexpired cache deadline survives edits/opt-out.
  #expect(ledger.next(at: 8000) == nil)
}

@Test func weatherCloudAndWindDirectionRequireKnownUnitsAndBoundedValues() throws {
  func point(value: Any?, cloud: Any?, directionUnit: String = "degrees", cloudUnit: String = "%")
    throws -> WeatherPoint
  {
    var json = try #require(
      JSONSerialization.jsonObject(with: forecastData(count: 1)) as? [String: Any])
    var properties = try #require(json["properties"] as? [String: Any])
    var meta = try #require(properties["meta"] as? [String: Any])
    var units = try #require(meta["units"] as? [String: String])
    units["wind_from_direction"] = directionUnit
    units["cloud_area_fraction"] = cloudUnit
    meta["units"] = units
    properties["meta"] = meta
    var series = try #require(properties["timeseries"] as? [[String: Any]])
    var data = try #require(series[0]["data"] as? [String: Any])
    var instant = try #require(data["instant"] as? [String: Any])
    var details = try #require(instant["details"] as? [String: Any])
    details["wind_from_direction"] = value
    details["cloud_area_fraction"] = cloud
    instant["details"] = details
    data["instant"] = instant
    series[0]["data"] = data
    properties["timeseries"] = series
    json["properties"] = properties
    let forecast = try WeatherDecoder.decode(
      JSONSerialization.data(withJSONObject: json), now: weatherDate)
    return try #require(forecast.current(at: weatherDate))
  }
  #expect(try point(value: 0, cloud: 0).windFromDegrees == 0)
  #expect(try point(value: 360, cloud: 100).cloudCover == 100)
  for invalid in [-0.1, 360.1] {
    #expect(try point(value: invalid, cloud: 50).windFromDegrees == nil)
  }
  for invalid in [-0.1, 100.1] { #expect(try point(value: 180, cloud: invalid).cloudCover == nil) }
  let wrongUnits = try point(value: 90, cloud: 0.5, directionUnit: "radians", cloudUnit: "1")
  #expect(wrongUnits.windFromDegrees == nil && wrongUnits.cloudCover == nil)
  let missing = try point(value: nil, cloud: NSNull())
  #expect(missing.windFromDegrees == nil && missing.cloudCover == nil)
}

@Test func weatherLedgerBackoffIsGlobalAndCoordinateEditInventoryIsBounded() throws {
  var ledger = WeatherLedger(jitter: 0)
  ledger.configure(weatherSettings())
  _ = ledger.next(at: 0)
  ledger.finish(
    .init(status: 429, retryAfter: 10_000), token: try #require(ledger.active).token, at: 1,
    date: weatherDate)
  ledger.configure(weatherSettings(62))
  #expect(ledger.next(at: 10_000) == nil)
  #expect(ledger.next(at: 10_001) != nil)
  var edits = WeatherLedger(jitter: 0)
  for index in 0..<8 {
    edits.configure(weatherSettings(Double(index)))
    #expect(edits.next(at: Double(index) * 61) != nil)
    edits.suspend()
  }
  edits.configure(weatherSettings(20))
  #expect(edits.next(at: 8 * 61) == nil)
  #expect(edits.next(at: 1800) != nil)
}

@Test func weatherQueuedSnapshotsRequireCurrentOptInAndFreshness() throws {
  var snapshot = WeatherSnapshot()
  snapshot.settings = weatherSettings()
  snapshot.forecast = try WeatherDecoder.decode(forecastData(), now: weatherDate)
  snapshot.receivedAt = 10
  #expect(snapshot.current(at: 11, date: weatherDate)?.celsius == -2)
  #expect(snapshot.current(at: 10_811, date: weatherDate) == nil)
  #expect(snapshot.current(at: 9, date: weatherDate) == nil)
  #expect(snapshot.current(at: 11, date: weatherDate.addingTimeInterval(25 * 3600)) == nil)
  #expect(snapshot.filtered(settings: .init()).forecast == nil)
  #expect(snapshot.filtered(settings: weatherSettings(revision: "new")).forecast == nil)
  #expect(snapshot.filtered(settings: weatherSettings(), suspended: true).forecast == nil)
}

private final class WeatherClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: Double = 0
  func now() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return time
  }
  func set(_ value: Double) {
    lock.lock()
    time = value
    lock.unlock()
  }
}
private final class WeatherFixture: WeatherTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [@Sendable (WeatherReply) -> Void] = []
  private var cancellations = 0
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return callbacks.count
  }
  func start(
    location: WeatherLocation, lastModified: String?,
    completion: @escaping @Sendable (WeatherReply) -> Void
  ) {
    lock.lock()
    callbacks.append(completion)
    lock.unlock()
  }
  func complete(_ index: Int, _ reply: WeatherReply) {
    lock.lock()
    let callback = callbacks[index]
    lock.unlock()
    callback(reply)
  }
  func cancel() {
    lock.lock()
    cancellations += 1
    lock.unlock()
  }
  func shutdown() { cancel() }
}
@Test func weatherReaderIsLazyTimesOutAndRejectsCompletionAfterSuspendOrDisable() {
  let fixture = WeatherFixture()
  let clock = WeatherClock()
  let reader = WeatherReader(
    transport: fixture, clock: clock.now, wallClock: { weatherDate }, jitter: 0)
  _ = reader.read()
  #expect(fixture.count == 0)
  reader.configure(weatherSettings())
  #expect(reader.read().checking && fixture.count == 1)
  clock.set(31)
  #expect(reader.read().reason == "Timed out")
  fixture.complete(0, .init(status: 200, data: forecastData()))
  #expect(reader.read().forecast == nil)
  clock.set(1900)
  #expect(reader.read().checking && fixture.count == 2)
  reader.suspend()
  fixture.complete(1, .init(status: 200, data: forecastData()))
  #expect(reader.read().forecast == nil)
  clock.set(3800)
  _ = reader.read()
  #expect(fixture.count == 3)
  reader.configure(.init())
  fixture.complete(2, .init(status: 200, data: forecastData()))
  #expect(reader.read().forecast == nil && fixture.count == 3)
}

private final class WeatherURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    let identified =
      request.value(forHTTPHeaderField: "User-Agent")?.contains("https://github.com/niechen")
      == true
    let conditional = request.value(forHTTPHeaderField: "If-Modified-Since") != nil
    let oversized = url.query?.contains("lat=61.000") == true
    let wrongOrigin = url.query?.contains("lat=62.000") == true
    let redirect = url.query?.contains("lat=63.000") == true
    if redirect {
      let target = URLRequest(url: URL(string: "https://other.invalid/")!)
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.url!.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    let response = HTTPURLResponse(
      url: wrongOrigin ? URL(string: "https://other.invalid/")! : url,
      statusCode: identified ? (conditional ? 304 : 200) : 403, httpVersion: "HTTP/1.1",
      headerFields: [
        "Expires": "Thu, 22 Oct 2026 14:00:00 GMT",
        "Last-Modified": "Thu, 22 Oct 2026 12:00:00 GMT", "Retry-After": "7200",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !conditional {
      client?.urlProtocol(
        self,
        didLoad: oversized
          ? Data(repeating: 32, count: WeatherDecoder.bodyLimit + 1) : forecastData())
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
@Test @MainActor func completedWeatherTransportReleasesItsIdleSessionAndDelegate() async throws {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [WeatherURLProtocol.self]
  var owner: NativeWeatherTransport? = NativeWeatherTransport(configuration: config)
  weak var transport: NativeWeatherTransport?
  transport = owner
  defer { transport?.shutdown() }
  let response = await withCheckedContinuation { continuation in
    owner?.start(location: location(), lastModified: nil) { continuation.resume(returning: $0) }
  }
  #expect(response.status == 200 && response.failure == nil)
  owner = nil
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while transport != nil && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(transport == nil)
}

@Test func nativeWeatherTransportUsesBoundedIdentifiedConditionalRequestsWithoutExternalTraffic()
  async
{
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [WeatherURLProtocol.self]
  let transport = NativeWeatherTransport(configuration: config)
  defer { transport.shutdown() }
  let success = await withCheckedContinuation { continuation in
    transport.start(location: location(), lastModified: nil) { continuation.resume(returning: $0) }
  }
  #expect(success.failure == nil && success.status == 200 && success.retryAfter == 7200)
  #expect(success.lastModified == "Thu, 22 Oct 2026 12:00:00 GMT" && success.expires != nil)
  #expect(!success.data.isEmpty)
  let conditional = await withCheckedContinuation { continuation in
    transport.start(location: location(), lastModified: success.lastModified) {
      continuation.resume(returning: $0)
    }
  }
  #expect(conditional.status == 304 && conditional.data.isEmpty && conditional.failure == nil)
  let large = await withCheckedContinuation { continuation in
    transport.start(location: location(61), lastModified: nil) {
      continuation.resume(returning: $0)
    }
  }
  #expect(large.failure == .oversized && large.data.isEmpty)
  let wrong = await withCheckedContinuation { continuation in
    transport.start(location: location(62), lastModified: nil) {
      continuation.resume(returning: $0)
    }
  }
  #expect(wrong.failure == .invalid)
  let redirected = await withCheckedContinuation { continuation in
    transport.start(location: location(63), lastModified: nil) {
      continuation.resume(returning: $0)
    }
  }
  #expect(redirected.failure == .redirect)
  let original = NativeWeatherTransport.url(for: location())
  #expect(
    NativeWeatherTransport.allowsRedirect(
      URL(
        string: "https://api.met.no/weatherapi/locationforecast/2.0/compact/?lat=60.100&lon=9.580"),
      from: original))
  #expect(
    !NativeWeatherTransport.allowsRedirect(
      URL(string: "https://api.met.no/other?lat=60.100&lon=9.580"), from: original))
  #expect(
    !NativeWeatherTransport.allowsRedirect(
      URL(string: "http://api.met.no/weatherapi/locationforecast/2.0/compact?lat=60.100&lon=9.580"),
      from: original))
  #expect(
    !NativeWeatherTransport.allowsRedirect(
      URL(
        string: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=61.000&lon=9.580"),
      from: original))
}

@Test func ownedOptInWeatherEndpointValidation() async throws {
  guard ProcessInfo.processInfo.environment["TINYSTATS_VALIDATE_WEATHER"] == "1" else { return }
  let transport = NativeWeatherTransport()
  defer { transport.shutdown() }
  let response = await withCheckedContinuation { continuation in
    transport.start(location: location(), lastModified: nil) { continuation.resume(returning: $0) }
  }
  #expect(response.status == 200 && response.failure == nil)
  let forecast = try WeatherDecoder.decode(response.data, now: Date())
  #expect(!forecast.points.isEmpty)
  #expect(response.expires != nil && response.lastModified != nil)
}

@Test func forecastRulesUseFreshCanonicalUnitsAndGuardQueuedDeliveryAfterOptOutOrLocationChange()
  throws
{
  var snapshot = Snapshot()
  snapshot.timestamp = weatherDate
  snapshot.uptime = 10
  snapshot.weather.settings = weatherSettings()
  snapshot.weather.receivedAt = 5
  snapshot.weather.forecast = try WeatherDecoder.decode(forecastData(), now: weatherDate)
  for metric in [RuleMetric.weatherTemperature, .weatherWind, .weatherPrecipitation] {
    var rule = AlertRule(metric: metric)
    rule.enabled = true
    rule.hold = 0
    rule.threshold = 0
    rule.comparison = metric == .weatherTemperature ? .atMost : .atLeast
    #expect(rule.validationError == nil)
    var engine = AlertEngine(rules: [rule])
    let event = try #require(engine.evaluate(snapshot, now: 10).first)
    var settings = Settings()
    settings.alerts = true
    settings.rules = [rule]
    settings.weather = snapshot.weather.settings
    #expect(event.canDeliver(with: settings, now: 11))
    #expect(!event.canDeliver(with: settings, suspended: true, now: 11))
    #expect(!event.canDeliver(with: settings, now: 11_000))
    settings.weather.enabled = false
    #expect(!event.canDeliver(with: settings, now: 11))
    settings.weather = weatherSettings(61)
    #expect(!event.canDeliver(with: settings, now: 11))
    settings.weather = weatherSettings(61, revision: "new-location")
    #expect(!event.canDeliver(with: settings, now: 11))
    var stale = snapshot
    stale.uptime = 11_000
    #expect(rule.observation(in: stale) == nil)
  }
  var precipitation = AlertRule(metric: .weatherPrecipitation)
  precipitation.enabled = true
  snapshot.weather.forecast?.points[0].periodHours = 6
  #expect(precipitation.observation(in: snapshot) == nil)
  precipitation.source = "any"
  #expect(precipitation.validationError != nil)
}

@Test func weatherReaderCountsSleepInCacheAgeAndProjectsDeadlinesForAwakeTimeConsumers() throws {
  let fixture = WeatherFixture()
  let continuous = WeatherClock()
  let wallOffset = WeatherClock()
  let awake = 1000.0
  continuous.set(awake)
  let reader = WeatherReader(
    transport: fixture, clock: continuous.now,
    wallClock: { weatherDate.addingTimeInterval(wallOffset.now()) }, jitter: 0)
  reader.configure(weatherSettings())
  _ = reader.read(at: awake)
  continuous.set(awake + 1)
  wallOffset.set(1)
  fixture.complete(0, .init(status: 200, data: forecastData()))
  continuous.set(awake + 2)
  wallOffset.set(2)
  let initial = reader.read(at: awake + 2)
  #expect(initial.current(at: awake + 2, date: weatherDate.addingTimeInterval(2)) != nil)
  reader.suspend()
  // Six hours asleep advance continuous/wall time, while awake uptime barely changes.
  continuous.set(awake + 6 * 3600 + 3)
  wallOffset.set(6 * 3600 + 3)
  let woke = reader.read(at: awake + 3)
  #expect(woke.current(at: awake + 3, date: weatherDate.addingTimeInterval(6 * 3600 + 3)) == nil)
  #expect(woke.checking && fixture.count == 2)
  let next = try #require(reader.read(at: awake + 3).nextRequestAt)
  #expect(next == awake + 3 + 1800)
  fixture.complete(1, .init(status: 304))
  let confirmed = reader.read(at: awake + 3)
  #expect(
    confirmed.current(at: awake + 3, date: weatherDate.addingTimeInterval(6 * 3600 + 3)) != nil)
}

@Test func weatherSleepAwareSchedulingPreservesUnexpiredCacheAndGlobalProviderBackoff() throws {
  let fixture = WeatherFixture()
  let continuous = WeatherClock()
  let wallOffset = WeatherClock()
  let reader = WeatherReader(
    transport: fixture, clock: continuous.now,
    wallClock: { weatherDate.addingTimeInterval(wallOffset.now()) }, jitter: 0)
  reader.configure(weatherSettings())
  _ = reader.read(at: 10)
  continuous.set(1)
  wallOffset.set(1)
  fixture.complete(
    0, .init(status: 200, data: forecastData(), expires: weatherDate.addingTimeInterval(7200)))
  reader.suspend()
  continuous.set(601)
  wallOffset.set(601)
  let shortSleep = reader.read(at: 12)
  #expect(fixture.count == 1 && !shortSleep.checking)
  #expect(shortSleep.current(at: 12, date: weatherDate.addingTimeInterval(601)) != nil)
  #expect(shortSleep.receivedAt == -588)
  #expect(shortSleep.nextRequestAt == 6611)
  #expect(shortSleep.checkedAge(at: 12) == "10m ago")
  continuous.set(7200)
  wallOffset.set(7200)
  _ = reader.read(at: 14)
  #expect(fixture.count == 2)
  fixture.complete(1, .init(status: 429, retryAfter: 10_000))
  reader.configure(weatherSettings(61, revision: "another"))
  reader.suspend()
  continuous.set(17_199)
  wallOffset.set(17_199)
  let waiting = reader.read(at: 15)
  #expect(fixture.count == 2 && waiting.requestWait(at: 15) == "At least 1m")
  continuous.set(17_200)
  wallOffset.set(17_200)
  #expect(reader.read(at: 16).checking && fixture.count == 3)
}

@Test func weatherProjectedTimesHandleInvalidClocksAndUnboundedProviderDurationsSafely() throws {
  let fixture = WeatherFixture()
  let clock = WeatherClock()
  let reader = WeatherReader(
    transport: fixture, clock: clock.now, wallClock: { weatherDate }, jitter: 0)
  reader.configure(weatherSettings())
  _ = reader.read(at: 10)
  fixture.complete(0, .init(status: 429, retryAfter: Double.greatestFiniteMagnitude))
  let held = reader.read(at: 11)
  #expect(held.requestWait(at: 11) == ">1 year")
  #expect(fixture.count == 1)
  let invalid = reader.read(at: .nan)
  #expect(invalid.forecast == nil && invalid.nextRequestAt == nil && invalid.receivedAt == nil)
  #expect(invalid.reason == "Clock unavailable")
  var snapshot = WeatherSnapshot()
  snapshot.receivedAt = -Double.greatestFiniteMagnitude
  #expect(snapshot.checkedAge(at: 0) == ">1 year ago")
  snapshot.receivedAt = .nan
  #expect(snapshot.checkedAge(at: 0) == "Unavailable")
  snapshot.nextRequestAt = .infinity
  #expect(snapshot.requestWait(at: 0) == ">1 year")
  snapshot.nextRequestAt = -1
  #expect(snapshot.requestWait(at: 0) == nil)
}

@Test func nativeWeatherClockPublishesCachedTimesInTheSamplerReferenceWithoutNetwork() throws {
  let fixture = WeatherFixture()
  let reader = WeatherReader(transport: fixture, wallClock: { weatherDate }, jitter: 0)
  reader.configure(weatherSettings())
  _ = reader.read(at: ProcessInfo.processInfo.systemUptime)
  fixture.complete(0, .init(status: 200, data: forecastData()))
  let sampledAt = ProcessInfo.processInfo.systemUptime
  let snapshot = reader.read(at: sampledAt)
  #expect(snapshot.current(at: sampledAt, date: weatherDate)?.celsius == -2)
  let receivedAt = try #require(snapshot.receivedAt)
  #expect((0..<60).contains(sampledAt - receivedAt))
  #expect(snapshot.requestWait(at: sampledAt) == "At least 30m")
  #expect(fixture.count == 1)
}
