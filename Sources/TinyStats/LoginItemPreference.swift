import ServiceManagement

/// The same ServiceManagement path serves General settings and the welcome tour.
@MainActor enum LoginItemPreference {
  static var enabled: Bool { SMAppService.mainApp.status == .enabled }
  static func setEnabled(_ enabled: Bool) -> String {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      return SMAppService.mainApp.status == .requiresApproval
        ? "Allow TinyStats in System Settings → General → Login Items."
        : "Login preference updated."
    } catch {
      return "Could not update login item: \(error.localizedDescription)"
    }
  }
}
