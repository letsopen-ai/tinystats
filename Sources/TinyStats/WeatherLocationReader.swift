import CoreLocation
import Foundation
import TinyStatsCore

@MainActor protocol WeatherLocationService: AnyObject {
  var authorization: CLAuthorizationStatus { get }
  var onAuthorization: (() -> Void)? { get set }
  var onFix: ((WeatherLocationFix) -> Void)? { get set }
  var onFailure: (() -> Void)? { get set }
  func requestAuthorization()
  func requestLocation()
  func stop()
}
struct WeatherLocationFix: Sendable {
  var latitude: Double, longitude: Double, accuracy: Double
  var timestamp: Date
}

/// Shared sampler deliveries drive timeouts/retries. There is no timer or continuous tracking.
@MainActor final class WeatherLocationReader {
  var onChange: ((WeatherLocation?, String, Bool) -> Void)?
  private let makeService: () -> any WeatherLocationService
  private let clock: () -> Double
  private let wallClock: () -> Date
  private var service: (any WeatherLocationService)?
  private var generation: UInt64 = 0
  private var enabled = false
  private var requestedAt: Double?
  private var nextRequest = -Double.infinity
  private var lastStatus = ""
  private var lastAuthorization: CLAuthorizationStatus?
  init(
    makeService: @escaping () -> any WeatherLocationService = { NativeWeatherLocationService() },
    clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
    wallClock: @escaping () -> Date = Date.init
  ) {
    self.makeService = makeService
    self.clock = clock
    self.wallClock = wallClock
  }
  func configure(enabled: Bool) {
    self.enabled = enabled
    if !enabled {
      generation &+= 1
      service?.stop()
      service = nil
      requestedAt = nil
      nextRequest = -Double.infinity
      lastAuthorization = nil
    }
  }
  func requestAuthorization() {
    guard enabled else { return }
    prepare().requestAuthorization()
    nextRequest = -Double.infinity
  }
  private func prepare() -> any WeatherLocationService {
    if let service { return service }
    let value = makeService()
    service = value
    generation &+= 1
    let token = generation
    value.onAuthorization = { [weak self] in
      guard let self, self.enabled, self.generation == token else { return }
      guard self.service?.authorization != self.lastAuthorization else { return }
      self.nextRequest = -Double.infinity
      self.tick()
    }
    value.onFix = { [weak self] fix in
      guard let self, self.enabled, self.generation == token, let started = self.requestedAt else {
        return
      }
      let now = self.clock()
      self.requestedAt = nil
      guard now.isFinite, now >= started, now - started < 30 else {
        self.service?.stop()
        self.nextRequest = now.isFinite ? now + 300 : .infinity
        self.status("Location timed out · choose a saved city or retry later")
        return
      }
      guard
        self.service?.authorization == .authorizedAlways
      else {
        self.status(
          "Location unavailable · choose a saved city or allow TinyStats in System Settings")
        return
      }
      guard fix.accuracy.isFinite, fix.accuracy >= 0,
        abs(fix.timestamp.timeIntervalSince(self.wallClock())) <= 300,
        let location = WeatherLocation(
          latitude: fix.latitude, longitude: fix.longitude,
          name: "Current location", timeZone: TimeZone.current.identifier
        ).validated
      else {
        self.nextRequest = self.clock() + 300
        self.status("No recent location fix")
        return
      }
      self.lastStatus = "Current location · time zone follows this Mac"
      self.onChange?(location, self.lastStatus, false)
    }
    value.onFailure = { [weak self] in
      guard let self, self.enabled, self.generation == token, self.requestedAt != nil else {
        return
      }
      self.requestedAt = nil
      self.nextRequest = self.clock() + 300
      self.status("Current location unavailable · choose a saved city or retry later")
    }
    return value
  }
  private func status(_ text: String, clearLocation: Bool = true) {
    guard text != lastStatus else { return }
    lastStatus = text
    onChange?(nil, text, clearLocation)
  }
  func tick() {
    let now = clock()
    guard enabled, now.isFinite else { return }
    let service = prepare()
    lastAuthorization = service.authorization
    switch service.authorization {
    case .notDetermined:
      service.stop()
      requestedAt = nil
      status("Location permission needed · use Allow current location above")
      return
    case .denied, .restricted:
      service.stop()
      requestedAt = nil
      status("Location unavailable · choose a saved city or allow TinyStats in System Settings")
      return
    case .authorizedAlways: break
    @unknown default:
      service.stop()
      requestedAt = nil
      status("Location authorization unavailable")
      return
    }
    if let started = requestedAt {
      guard now < started || now - started >= 30 else { return }
      service.stop()
      requestedAt = nil
      nextRequest = now + 300
      status("Location timed out · choose a saved city or retry later")
      return
    }
    guard now >= nextRequest else { return }
    requestedAt = now
    nextRequest = now + 1800
    status("Finding current location…", clearLocation: false)
    service.requestLocation()
  }
}

/// Core Location callbacks use the main run loop on which this manager is created.
@MainActor
private final class NativeWeatherLocationService: NSObject,
  WeatherLocationService, @preconcurrency CLLocationManagerDelegate
{
  var onAuthorization: (() -> Void)?
  var onFix: ((WeatherLocationFix) -> Void)?
  var onFailure: (() -> Void)?
  private let manager = CLLocationManager()
  var authorization: CLAuthorizationStatus { manager.authorizationStatus }
  override init() {
    super.init()
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    manager.delegate = self
  }
  func requestAuthorization() { manager.requestWhenInUseAuthorization() }
  func requestLocation() { manager.requestLocation() }
  func stop() { manager.stopUpdatingLocation() }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { onAuthorization?() }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let fix = locations.last else {
      onFailure?()
      return
    }
    onFix?(
      .init(
        latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
        accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp))
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { onFailure?() }
}
