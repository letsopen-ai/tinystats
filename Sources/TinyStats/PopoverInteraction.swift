import AppKit

/// Dismiss only the open popover; never intercept clicks on another TinyStats item.
/// Event callbacks run on the main thread. No event data is stored or collected.
@MainActor final class PopoverInteraction {
  private weak var window: NSWindow?
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var statusEvent: ((NSEvent) -> Bool)?
  private var onDismiss: (() -> Void)?
  private var generation: UInt = 0

  var isMonitoring: Bool { localMonitor != nil }

  func start(
    window: NSWindow, statusEvent: @escaping (NSEvent) -> Bool,
    onDismiss: @escaping () -> Void
  ) {
    stop()
    self.window = window
    self.statusEvent = statusEvent
    self.onDismiss = onDismiss
    let generation = generation
    localMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    ) { [weak self] event in
      let deliver = MainActor.assumeIsolated {
        guard let self, self.generation == generation else { return true }
        return self.handle(event) != nil
      }
      return deliver ? event : nil
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, self.generation == generation else { return }
        self.handleGlobal(event)
      }
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.generation == generation else { return }
        self.dismiss()
      }
    }
  }

  func stop() {
    generation &+= 1
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    localMonitor = nil
    globalMonitor = nil
    resignObserver = nil
    statusEvent = nil
    onDismiss = nil
    window = nil
  }

  private func dismiss() {
    guard isMonitoring else { return }
    let action = onDismiss
    stop()
    action?()
  }

  func handleGlobal(_ event: NSEvent) {
    guard statusEvent?(event) != true else { return }
    dismiss()
  }

  static func hits(_ event: NSEvent, view: NSView) -> Bool {
    guard let window = view.window else { return false }
    let point: NSPoint
    if event.window === window {
      point = event.locationInWindow
    } else if event.window == nil {
      // Windowless global/proxy mouse events use screen coordinates.
      point = window.convertPoint(fromScreen: event.locationInWindow)
    } else {
      return false
    }
    return view.bounds.contains(view.convert(point, from: nil))
  }

  /// Return outside mouse events unchanged so the destination receives the same click.
  func handle(_ event: NSEvent) -> NSEvent? {
    guard isMonitoring, let window else { return event }
    if event.type == .keyDown {
      guard event.window === window, event.keyCode == 53,
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
        !(window.firstResponder is NSText), window.attachedSheet == nil
      else { return event }
      dismiss()
      return nil
    }
    if statusEvent?(event) == true { return event }
    var target = event.window
    while let current = target {
      if current === window { return event }
      target = current.parent
    }
    // Menu tracking and nonactivating panels are allowed, like native transient
    // popovers. External-app clicks are handled by the mouse-only global monitor.
    if event.window?.canBecomeKey == true { dismiss() }
    return event
  }
}
