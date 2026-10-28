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

  func rebuild(
    settings: Settings, target: AnyObject, action: Selector,
    onAppearanceChange: @escaping () -> Void
  ) {
    removeAll()
    let modules = settings.readouts.isEmpty ? [.overview] : settings.readouts
    // macOS inserts newly created items to the left; saved native positions still take precedence.
    // One preview refresh per bar appearance flip; every view still redraws itself.
    var previewAppearanceObserverAttached = false
    for module in modules.reversed() {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.autosaveName = "tinystats.\(module.rawValue)"
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

  private func removeAll() {
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
    let order = items.compactMap { entry -> (Module, CGFloat)? in
      guard let button = entry.item.button, let window = button.window
      else { return nil }
      return (entry.module, window.convertToScreen(button.convert(button.bounds, to: nil)).minX)
    }.sorted { $0.1 < $1.1 }.map { $0.0 }
    preferences.updateMenuBarContext(
      appearance: items.first?.readout.effectiveAppearance, order: order,
      height: items.first?.readout.bounds.height ?? NSStatusBar.system.thickness, paused: paused)
  }
}
