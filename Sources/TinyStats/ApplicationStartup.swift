import Foundation
import TinyStatsCore

/// Launch-only configuration. Checkpoint I/O still runs through the worker's factory.
enum ApplicationStartup {
  static func preferenceStore(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> UserDefaults {
    if let suite = environment["TINYSTATS_PREFERENCES_DOMAIN"],
      !suite.isEmpty, let store = UserDefaults(suiteName: suite)
    {
      return store
    }
    return .standard
  }

  static func initialSettings(from store: UserDefaults) -> Settings {
    var value = Settings.load(from: store)
    // A persisted coordinate must not start requests before a fresh authorization/fix check.
    value.weather.prepareForSession()
    return value
  }

  static func historyDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupport: URL? = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first
  ) -> URL? {
    HistoryStoreLocation.directory(environment: environment, applicationSupport: applicationSupport)
  }

  static func historyStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupport: URL? = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first
  ) -> HistoryPersistence.Factory {
    let directory = historyDirectory(
      environment: environment, applicationSupport: applicationSupport)
    let isolated = environment["TINYSTATS_PREFERENCES_DOMAIN"] != nil
    let excluded =
      isolated ? historyDirectory(environment: [:], applicationSupport: applicationSupport) : nil
    return { create in
      guard let directory else { return nil }
      if create && !isolated {
        // The standard support directory may not exist on a fresh account. Opt-in only.
        _ = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
      }
      return try LocalHistoryCheckpointStore(
        directory: directory, create: create, excludingDirectory: excluded)
    }
  }
}
