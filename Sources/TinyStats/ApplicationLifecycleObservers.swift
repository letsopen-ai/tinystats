import AppKit

/// Owns notification registrations only; AppDelegate orders UI invalidation and worker commands.
@MainActor final class ApplicationLifecycleObservers {
  enum Event: Sendable { case sleep, wake, power, clock }

  private var registrations: [(NotificationCenter, NSObjectProtocol)] = []

  func start(
    workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
    application: NotificationCenter = .default,
    receive: @escaping @MainActor @Sendable (Event) -> Void
  ) {
    guard registrations.isEmpty else { return }
    observe(NSWorkspace.willSleepNotification, on: workspace, event: .sleep, receive: receive)
    observe(NSWorkspace.didWakeNotification, on: workspace, event: .wake, receive: receive)
    observe(.NSProcessInfoPowerStateDidChange, on: application, event: .power, receive: receive)
    for name in [
      Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification,
      Notification.Name.NSSystemClockDidChange,
    ] {
      observe(name, on: application, event: .clock, receive: receive)
    }
  }

  func stop() {
    for (center, token) in registrations { center.removeObserver(token) }
    registrations.removeAll()
  }

  private func observe(
    _ name: Notification.Name, on center: NotificationCenter, event: Event,
    receive: @escaping @MainActor @Sendable (Event) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
      // The observer queue already guarantees main-actor delivery; do not defer lifecycle work.
      MainActor.assumeIsolated { receive(event) }
    }
    registrations.append((center, token))
  }
}
