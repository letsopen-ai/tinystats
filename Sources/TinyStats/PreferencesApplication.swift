import TinyStatsCore

enum PreferencesApplication {
  static func merging(_ draft: Settings, current: Settings) -> Settings {
    var settings = draft
    // Dedicated history/grouping controls own these fields, even when a draft is stale.
    settings.persistHistory = current.persistHistory
    settings.processGrouping = current.processGrouping
    settings.networkTrafficRevision = current.networkTrafficRevision
    return settings
  }
}
