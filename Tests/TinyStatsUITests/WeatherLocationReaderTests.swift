import CoreLocation
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private final class LocationServiceFixture: WeatherLocationService {
  var authorization: CLAuthorizationStatus = .notDetermined
  var onAuthorization: (() -> Void)?
  var onFix: ((WeatherLocationFix) -> Void)?
  var onFailure: (() -> Void)?
  var authorizationRequests = 0, locationRequests = 0, stops = 0
  func requestAuthorization() { authorizationRequests += 1 }
  func requestLocation() { locationRequests += 1 }
  func stop() { stops += 1 }
}

@Test @MainActor func currentWeatherLocationRequiresPermissionAndIgnoresRevokedOrLateFixes() {
  let service = LocationServiceFixture()
  var now = 100.0
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let reader = WeatherLocationReader(makeService: { service }, clock: { now }, wallClock: { date })
  var changes: [(WeatherLocation?, Bool)] = []
  reader.onChange = { value, _, clear in changes.append((value, clear)) }
  reader.configure(enabled: true)
  reader.tick()
  #expect(service.authorizationRequests == 0 && service.locationRequests == 0)
  #expect(changes.last?.1 == true)
  reader.requestAuthorization()
  #expect(service.authorizationRequests == 1)
  service.authorization = .authorizedAlways
  service.onAuthorization?()
  #expect(service.locationRequests == 1)
  service.onAuthorization?()
  now = 101
  reader.tick()
  #expect(service.locationRequests == 1)
  service.onFix?(.init(latitude: 59.9139, longitude: 10.7522, accuracy: 100, timestamp: date))
  #expect(changes.last?.0?.latitude == 59.914 && changes.last?.1 == false)
  now = 1899
  reader.tick()
  #expect(service.locationRequests == 1)
  now = 1900
  reader.tick()
  #expect(service.locationRequests == 2)
  service.authorization = .denied
  service.onFix?(.init(latitude: 60, longitude: 10, accuracy: 100, timestamp: date))
  #expect(changes.last?.0 == nil && changes.last?.1 == true)
  service.onAuthorization?()
  #expect(service.locationRequests == 2)
  reader.configure(enabled: false)
  let count = changes.count
  service.onFix?(.init(latitude: 60, longitude: 10, accuracy: 100, timestamp: date))
  service.onFailure?()
  service.onAuthorization?()
  #expect(changes.count == count)
}

@Test @MainActor func currentWeatherLocationRetriesOnlyOnSharedTicksAndRejectsStaleFixes() {
  let service = LocationServiceFixture()
  service.authorization = .authorizedAlways
  var now = 100.0
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let reader = WeatherLocationReader(makeService: { service }, clock: { now }, wallClock: { date })
  var fixes: [WeatherLocation] = []
  reader.onChange = { value, _, _ in if let value { fixes.append(value) } }
  reader.configure(enabled: true)
  reader.tick()
  now = 129
  reader.tick()
  #expect(service.locationRequests == 1)
  now = 130
  reader.tick()
  now = 429
  reader.tick()
  #expect(service.locationRequests == 1)
  now = 430
  reader.tick()
  #expect(service.locationRequests == 2)
  service.onFix?(
    .init(latitude: 60, longitude: 10, accuracy: 10, timestamp: date.addingTimeInterval(-301)))
  #expect(fixes.isEmpty)
  now = 730
  reader.tick()
  service.onFix?(.init(latitude: 60, longitude: 10, accuracy: -1, timestamp: date))
  #expect(fixes.isEmpty)
  reader.configure(enabled: false)
}

@Test @MainActor func currentWeatherFixExpiresBeforeTheNextSharedTick() {
  let service = LocationServiceFixture()
  service.authorization = .authorizedAlways
  var now = 100.0
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let reader = WeatherLocationReader(makeService: { service }, clock: { now }, wallClock: { date })
  var locations: [WeatherLocation] = []
  reader.onChange = { value, _, _ in if let value { locations.append(value) } }
  reader.configure(enabled: true)
  reader.tick()
  now = 131
  service.onFix?(.init(latitude: 60, longitude: 10, accuracy: 100, timestamp: date))
  #expect(locations.isEmpty && service.stops == 1)
  now = 430
  reader.tick()
  #expect(service.locationRequests == 1)
  now = 431
  reader.tick()
  service.onFix?(.init(latitude: 60, longitude: 10, accuracy: 100, timestamp: date))
  #expect(locations.count == 1 && service.locationRequests == 2)
}
