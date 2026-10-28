import TinyStatsCore

enum PreferencesApplication {
  static func merging(_ draft: Settings, current: Settings) -> Settings {
    var settings = draft
    // Dedicated history/traffic controls own these fields, even when a draft is stale.
    settings.persistHistory = current.persistHistory
    settings.networkTrafficGrouping = current.networkTrafficGrouping
    settings.networkTrafficRevision = current.networkTrafficRevision
    return settings
  }
}
