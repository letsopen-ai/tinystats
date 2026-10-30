import AppKit
import TinyStatsCore

/// Owns native readouts and sender identity. Window routing and demand remain with AppDelegate.
@MainActor final class StatusItemController {
  private var items: [(module: Module, item: NSStatusItem, readout: MenuBarReadoutView)] = []

  var firstButton: NSStatusBarButton? { items.first?.item.button }

  func entry(for sender: NSStatusBarButton) -> (module: Module, item: NSStatusItem)? {
    guard let entry = items.first(where: { $0.item.button === sender }) else { return nil }
    return (entry.module, entry.item)
  }

  func hits(_ event: NSEvent) -> Bool {
    items.contains { entry in
      guard let button = entry.item.button else { return false }
      return PopoverInteraction.hits(event, view: button)
    }
  }

  /// Complete, distinct native frames only; hidden/overflow/transitional readings cannot erase a layout.
  var observedOrder: [Module]? {
    let entries = nativePositions
    guard entries.count == items.count, Set(entries.values).count == items.count else { return nil }
    return entries.sorted { $0.value > $1.value }.map(\.key)
  }

  private var nativePositions: [Module: Double] {
    var positions: [Module: Double] = [:]
    for entry in items {
      guard let button = entry.item.button, let window = button.window,
        let screen = window.screen, window.isVisible, button.bounds.width > 0
      else { continue }
      let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
      guard rect.minX >= screen.frame.minX, rect.maxX <= screen.frame.maxX else { continue }
      positions[entry.module] = Double(screen.frame.maxX - rect.midX)
    }
    return positions
  }

  private func autosaveName(for module: Module) -> String {
    // Development previews must not rewrite the real app's native placement keys.
    let isolation =
      ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"].map { $0 + "." } ?? ""
    return isolation + "tinystats.\(module.rawValue)"
  }

  func rebuild(
    settings: Settings, target: AnyObject, action: Selector, enforceOrder: Bool = false,
    onAppearanceChange: @escaping () -> Void
  ) {
    var positions = nativePositions
    // Reuse saved slots exactly. Repeatedly deriving slots from laid-out button centers would
    // accumulate AppKit's placement offsets on every reorder and drift across the menu bar.
    for entry in items {
      let key = "NSStatusItem Preferred Position " + autosaveName(for: entry.module)
      if let number = UserDefaults.standard.object(forKey: key) as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
        number.doubleValue >= 0,
        number.doubleValue < (entry.item.button?.window?.screen?.frame.width ?? 10_000)
      {
        positions[entry.module] = number.doubleValue
      }
    }
    removeAll()
    let modules = settings.readouts.isEmpty ? [.overview] : settings.readouts
    if enforceOrder {
      // AppKit has no public move API. Reuse its autosave placement convention rather than
      // private selectors, synthetic mouse events, or replacing the native status buttons.
      // Remove first: AppKit may save the old position while removing an item.
      for (module, position) in MenuBarNativeOrder.positions(order: modules, existing: positions) {
        UserDefaults.standard.set(
          position, forKey: "NSStatusItem Preferred Position " + autosaveName(for: module))
      }
    }
    // macOS inserts newly created items to the left; saved native positions still take precedence.
    // One preview refresh per bar appearance flip; every view still redraws itself.
    var previewAppearanceObserverAttached = false
    for module in modules.reversed() {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.autosaveName = autosaveName(for: module)
      item.button?.target = target
      item.button?.action = action
      item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
      item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
      item.button?.setAccessibilityIdentifier(
        "\(Bundle.main.bundleIdentifier ?? "tinystats").readout.\(module.rawValue)")
      let readout = MenuBarReadoutView(frame: .zero)
      if !previewAppearanceObserverAttached {
        readout.onAppearanceChange = onAppearanceChange
        previewAppearanceObserverAttached = true
      }
      readout.autoresizingMask = [.width, .height]
      item.button?.addSubview(readout)
      items.append((module, item, readout))
    }
  }

  func removeAll() {
    for (_, item, _) in items { NSStatusBar.system.removeStatusItem(item) }
    items = []
  }

  private func readout(
    _ module: Module, snapshot: Snapshot, settings: Settings, clockDate: Date
  ) -> String {
    let s = snapshot
    switch module {
    case .overview: return "TinyStats"
    case .cpu: return "CPU \(Display.percent(s.cpu?.usage))"
    case .gpu: return "GPU \(Display.percent(s.gpus.compactMap(\.usage).max()))"
    case .memory: return "MEM \(Display.percent(s.memory?.percent))"
    case .network: return "↓\(Display.rate(s.download)) ↑\(Display.rate(s.upload))"
    case .disks: return "SSD \(Display.percent(s.startupVolume?.percent))"
    case .sensors:
      return s.sensor(for: settings.sensorKey)?.formatted(fahrenheit: settings.fahrenheit)
        ?? "SENSOR —"
    case .battery:
      let preset = settings.batteryMenu.preset(
        for: s.batteries.first, defaultStyle: settings.style(for: .battery))
      let text = BatteryMenuText(reading: s.batteries.first, format: preset.format)
      let state = s.batteries.first.map { BatteryMenuState.state(for: $0).title } ?? "AC"
      return "Battery · \(state) · \(text.value)\(text.secondary.map { " · \($0)" } ?? "")"
    case .weather:
      let text = MenuBarReadout.make(
        module: .weather, snapshot: s, settings: settings, history: [])
      return "Weather forecast · \(text.label) · \(text.value)"
    case .clock:
      return MenuBarReadout.makeAll(
        module: .clock, snapshot: s, settings: settings, history: [], clockDate: clockDate
      ).map {
        $0.label + " " + $0.value + ($0.secondary.map { " " + $0 } ?? "")
      }.joined(separator: ", ")
    }
  }
  func update(
    snapshot: Snapshot, history: [HistoryPoint], settings: Settings, clockDate: Date,
    paused: Bool, clockOnly: Bool = false
  ) {
    for (module, item, view) in items {
      let modules = [module]
      if clockOnly && !modules.contains(.clock) { continue }
      view.readouts = modules.flatMap {
        MenuBarReadout.makeAll(
          module: $0, snapshot: snapshot, settings: settings, history: history, clockDate: clockDate
        )
      }
      view.paused = paused
      item.length = view.preferredWidth
      if let button = item.button { view.frame = button.bounds }
      view.needsDisplay = true
      let title = modules.map {
        readout($0, snapshot: snapshot, settings: settings, clockDate: clockDate)
      }.joined(separator: ", ")
      item.button?.toolTip =
        "TinyStats\(paused ? " · paused":"") — click for details; right-click for options"
      item.button?.setAccessibilityLabel("TinyStats \(title)")
    }
  }
  func updatePreviewContext(_ preferences: PreferencesController, paused: Bool) {
    let order = observedOrder ?? []
    preferences.updateMenuBarContext(
      appearance: items.first?.readout.effectiveAppearance, order: order,
      height: items.first?.readout.bounds.height ?? NSStatusBar.system.thickness, paused: paused)
  }
}

/// Remap only TinyStats' existing native slots. Distances grow from the right edge of the bar.
enum MenuBarNativeOrder {
  static func positions(order: [Module], existing: [Module: Double]) -> [Module: Double] {
    let valid = existing.filter { $0.value.isFinite && $0.value >= 0 && $0.value < 10_000_000 }
    var slots = Array(Set(valid.values)).sorted(by: >)
    // Removing items retains their peers' slots. Newly enabled items get space at the left.
    if order.count < slots.count {
      let retained = order.compactMap { valid[$0] }
      if retained.count == order.count && Set(retained).count == order.count {
        slots = retained.sorted(by: >)
      } else {
        slots = Array(slots.prefix(order.count))
      }
    }
    while slots.count < order.count { slots.insert((slots.first ?? 100) + 60, at: 0) }
    return Dictionary(uniqueKeysWithValues: zip(order, slots))
  }
}
