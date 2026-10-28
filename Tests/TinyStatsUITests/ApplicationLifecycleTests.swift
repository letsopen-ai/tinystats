import AppKit
import Darwin
import Testing
import os

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func applicationLifecycleObserversRouteOnceAndStopOnTheirOwnCenters() {
  let workspace = NotificationCenter()
  let application = NotificationCenter()
  let received = OSAllocatedUnfairLock(initialState: [ApplicationLifecycleObservers.Event]())
  let observers = ApplicationLifecycleObservers()
  defer { observers.stop() }
  observers.start(workspace: workspace, application: application) { event in
    received.withLock { $0.append(event) }
  }
  observers.start(workspace: workspace, application: application) { _ in
    Issue.record("A second start must not register duplicate lifecycle handlers")
  }
  let notifications:
    [(NotificationCenter, Notification.Name, ApplicationLifecycleObservers.Event)] = [
      (workspace, NSWorkspace.willSleepNotification, .sleep),
      (workspace, NSWorkspace.didWakeNotification, .wake),
      (application, .NSProcessInfoPowerStateDidChange, .power),
      (application, .NSSystemTimeZoneDidChange, .clock),
      (application, NSLocale.currentLocaleDidChangeNotification, .clock),
      (application, .NSSystemClockDidChange, .clock),
    ]
  for (index, notification) in notifications.enumerated() {
    let (center, name, event) = notification
    center.post(name: name, object: nil)
    #expect(received.withLock { $0.count == index + 1 && $0.last == event })
  }
  observers.stop()
  for (center, name, _) in notifications {
    center.post(name: name, object: nil)
    #expect(received.withLock { $0.count == notifications.count })
  }
}

@Test func applicationStartupPreservesWeatherChoicesAndClearsSessionCoordinates() throws {
  let name = "TinyStatsIssue13-\(UUID().uuidString)"
  let store = try #require(UserDefaults(suiteName: name))
  defer { store.removePersistentDomain(forName: name) }
  let initial = ApplicationStartup.initialSettings(from: store)
  #expect(!initial.weather.enabled)
  #expect(!initial.readouts.contains(.weather) && initial.persistHistory)
  var settings = Settings()
  settings.persistHistory = false
  settings.weather = .currentLocationDefault
  settings.weather.location = .init(latitude: 59, longitude: 10, name: "Fixture", timeZone: "UTC")
  for enabled in [false, true] {
    settings.weather.enabled = enabled
    settings.save(to: store)
    let loaded = ApplicationStartup.initialSettings(from: store)
    #expect(loaded.weather.enabled == enabled && loaded.weather.location == nil)
    #expect(!loaded.persistHistory)
  }
}

@Test func applicationStartupHistoryFactoryIsLazyAndIsolated() throws {
  let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
  defer { free(pointer) }
  // Match the secure store's no-symlink contract, including /private/var rather than /var.
  let root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let support = root.appendingPathComponent("support")
  let directory = root.appendingPathComponent("isolated-history")
  let environment = [
    "TINYSTATS_PREFERENCES_DOMAIN": "fixture", "TINYSTATS_HISTORY_DIRECTORY": directory.path,
  ]
  let factory = ApplicationStartup.historyStore(
    environment: environment, applicationSupport: support)
  #expect(!FileManager.default.fileExists(atPath: directory.path))
  #expect(try factory(false) == nil)
  #expect(try factory(true) != nil)
  #expect(FileManager.default.fileExists(atPath: directory.path))
  #expect(!FileManager.default.fileExists(atPath: support.path))
  let noDirectory = ApplicationStartup.historyStore(
    environment: ["TINYSTATS_PREFERENCES_DOMAIN": "fixture"], applicationSupport: support)
  #expect(try noDirectory(true) == nil)
  let ownerDirectory = ApplicationStartup.historyDirectory(
    environment: [:], applicationSupport: support)
  #expect(ownerDirectory?.lastPathComponent == "TinyStatsHistory")
  #expect(
    ApplicationStartup.historyDirectory(
      environment: [
        "TINYSTATS_PREFERENCES_DOMAIN": "fixture",
        "TINYSTATS_HISTORY_DIRECTORY": try #require(ownerDirectory).path,
      ],
      applicationSupport: support) == nil)
}
