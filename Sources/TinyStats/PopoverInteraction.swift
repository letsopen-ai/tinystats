import AppKit

/// Own visible-only dismissal and route status clicks before native tracking can consume them.
/// Event callbacks run on the main thread; optional click diagnostics use unified logging.
@MainActor final class PopoverInteraction {
  private weak var window: NSWindow?
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var statusEvent: ((NSEvent) -> Bool)?
  private var onStatusClick: ((NSEvent) -> Bool)?
  private var resignDismissal: DispatchWorkItem?
  private var onDismiss: (() -> Void)?
  private var generation: UInt = 0
  private let mouseLocation: () -> NSPoint
  private let scheduleDismissal: (DispatchWorkItem) -> Void
  var onEvent: ((NSEvent, String) -> Void)?

  init(
    mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
    scheduleDismissal: @escaping (DispatchWorkItem) -> Void = {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: $0)
    }
  ) {
    self.mouseLocation = mouseLocation
    self.scheduleDismissal = scheduleDismissal
  }

  var isMonitoring: Bool { localMonitor != nil }

  func start(
    window: NSWindow, statusEvent: @escaping (NSEvent) -> Bool,
    onStatusClick: ((NSEvent) -> Bool)? = nil, onDismiss: @escaping () -> Void
  ) {
    stop()
    self.window = window
    self.statusEvent = statusEvent
    self.onStatusClick = onStatusClick
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
        self.scheduleResignDismissal()
      }
    }
  }

  // AppKit can resign before delivering a status click, and currentEvent need not
  // be that click. Bound the grace period so an unhandled click cannot orphan UI.
  private func scheduleResignDismissal() {
    resignDismissal?.cancel()
    let generation = generation
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == generation else { return }
        self.dismiss()
      }
    }
    resignDismissal = work
    scheduleDismissal(work)
  }

  func stop() {
    generation &+= 1
    resignDismissal?.cancel()
    resignDismissal = nil
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    localMonitor = nil
    globalMonitor = nil
    resignObserver = nil
    statusEvent = nil
    onStatusClick = nil
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
    guard statusEvent?(event) != true else {
      onEvent?(event, "global-status-pass-through")
      return
    }
    onEvent?(event, "global-outside-dismiss")
    dismiss()
  }

  static func isMouse(_ event: NSEvent) -> Bool {
    [
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
      .otherMouseUp,
    ].contains(event.type)
  }

  /// AppKit screen coordinates (including negative origins on other displays), never a
  /// guessed interpretation of a nil/foreign window's locationInWindow. Down/up callbacks
  /// run synchronously on the main thread, before tracking or activation; the current mouse
  /// location is valid for that handling instant. Own-window coordinates are cross-checked;
  /// on disagreement the handling-time cursor wins (never guess proxy-local coordinates).
  static func screenPoint(
    _ event: NSEvent, statusButtons: [NSView], mouseLocation: NSPoint
  ) -> NSPoint? {
    guard isMouse(event) else { return nil }
    let current = mouseLocation.x.isFinite && mouseLocation.y.isFinite ? mouseLocation : nil
    if let converted = statusWindowPoint(event, statusButtons: statusButtons) {
      if converted == current { return converted }
      // A queued/forwarded event can disagree with the live cursor. Keep the source
      // window out of this decision; trace records both points for manual verification.
      return current ?? converted
    }
    return current
  }

  static func statusWindowPoint(_ event: NSEvent, statusButtons: [NSView]) -> NSPoint? {
    guard let window = event.window,
      statusButtons.contains(where: { $0.window === window && screenRect(of: $0) != nil })
    else { return nil }
    let converted = window.convertPoint(toScreen: event.locationInWindow)
    guard converted.x.isFinite, converted.y.isFinite,
      statusButtons.contains(where: { screenRect(of: $0)?.contains(converted) == true })
    else { return nil }
    return converted
  }

  static func screenRect(of view: NSView) -> NSRect? {
    guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
      !view.visibleRect.isEmpty, !view.bounds.isEmpty
    else { return nil }
    let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
    // Overflowed items can retain a window with an off-screen frame. Do not clamp to a
    // primary display or assume a notch position; AppKit owns placement on each display.
    guard NSScreen.screens.contains(where: { $0.frame.contains(rect) }) else { return nil }
    return rect
  }

  static func point(screen: NSPoint, in view: NSView) -> NSPoint? {
    guard let window = view.window else { return nil }
    return view.convert(window.convertPoint(fromScreen: screen), from: nil)
  }

  static func point(
    _ event: NSEvent, in view: NSView, mouseLocation: NSPoint = NSEvent.mouseLocation
  ) -> NSPoint? {
    guard let screen = screenPoint(event, statusButtons: [view], mouseLocation: mouseLocation)
    else { return nil }
    return point(screen: screen, in: view)
  }

  static func hits(
    _ event: NSEvent, view: NSView, mouseLocation: NSPoint = NSEvent.mouseLocation
  ) -> Bool {
    guard let rect = screenRect(of: view),
      let screen = screenPoint(event, statusButtons: [view], mouseLocation: mouseLocation)
    else { return false }
    return rect.contains(screen)
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
    // A dropdown may overlap the menu bar in full screen/auto-hide layouts. Its controls
    // must receive their click even when a status button is behind the same screen point.
    let screen = mouseLocation()
    if window.isVisible && window.frame.contains(screen) {
      onEvent?(event, "dropdown-pass-through")
      return event
    }
    if statusEvent?(event) == true {
      if event.type == .leftMouseDown, let onStatusClick,
        !event.modifierFlags.contains(.command), window.attachedSheet == nil
      {
        // Route before native button tracking/dismissal. Consuming this down event prevents
        // a second button action. Right-click, native Command-drag and sheets retain AppKit input.
        if onStatusClick(event) {
          resignDismissal?.cancel()
          resignDismissal = nil
          return nil
        }
      }
      onEvent?(event, "native-status-pass-through")
      return event
    }
    onEvent?(event, "outside-pass-through")
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
