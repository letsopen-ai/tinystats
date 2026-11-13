import AppKit
import TinyStatsCore

/// Owns native readouts and sender identity. Window routing and demand remain with AppDelegate.
@MainActor final class StatusItemController {
  static func buttonFont(_ weight: MenuBarWeight) -> NSFont {
    MenuBarTypography.forWeight(weight).buttonFont
  }

  private var items: [(module: Module, item: NSStatusItem, readout: MenuBarReadoutView)] = []

  private var orderObservation = MenuBarOrderObservation()
  private var rebuilding = false
  private var separateItems = true
  private var weight: MenuBarWeight?
  /// Enabled modules currently hidden by the power-source choice (never "disabled").
  private(set) var hiddenModules: Set<Module> = []
  /// One's drawn modules after power-source hiding (`[.overview]` when none remain); rendering
  /// and keyboard activation both derive from this list.
  private(set) var presentedCombined: [Module] = []
  /// The last source an internal battery reading confirmed this session (nil: never seen).
  private(set) var lastConfirmedSource: PowerSourceKind?
  /// The power source the menu bar is currently presented for.
  private(set) var powerSource: PowerSourceKind = .adapter
  private var itemTarget: AnyObject?
  private var itemAction: Selector?
  private var appearanceChange: (() -> Void)?
  private weak var appearanceObserver: MenuBarReadoutView?
  private var suppliedReadouts: [ObjectIdentifier: [MenuBarReadout]] = [:]

  struct Target {
    var module: Module
    var button: NSView
    var readout: MenuBarReadoutView
  }
  private let suppliedTargets: [Target]?
  let mouseLocation: () -> NSPoint

  /// Owned-view injection exercises the same adapter without creating real status items.
  init(
    targets: [Target]? = nil, combined: Bool = false,
    mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }
  ) {
    suppliedTargets = targets
    separateItems = !combined
    self.mouseLocation = mouseLocation
    for target in targets ?? [] {
      suppliedReadouts[ObjectIdentifier(target.readout)] = target.readout.readouts
    }
  }

  var isCombined: Bool { !separateItems }

  var targets: [Target] {
    let base =
      suppliedTargets
      ?? items.compactMap { entry in
        entry.item.button.map { Target(module: entry.module, button: $0, readout: entry.readout) }
      }
    // One's keyboard/VoiceOver fallback is the first module actually drawn, including the
    // TinyStats overview that replaces an all-hidden list, never a hidden module.
    guard !separateItems, let first = presentedCombined.first else { return base }
    return base.map { target in
      var target = target
      target.module = first
      return target
    }
  }

  /// Shared layout plan, testable without creating real menu bar items.
  static func groups(for settings: Settings) -> [[Module]] {
    let modules = settings.readouts.isEmpty ? [.overview] : settings.readouts
    return settings.separateItems ? modules.map { [$0] } : [modules]
  }

  var firstButton: NSStatusBarButton? { items.first?.item.button }

  func entry(for sender: NSStatusBarButton) -> (module: Module, item: NSStatusItem)? {
    guard let entry = items.first(where: { $0.item.button === sender }) else { return nil }
    return (entry.module, entry.item)
  }

  /// Shared native/proxy input adapter; a keyboard/VoiceOver press uses the first module.
  static func module(
    for event: NSEvent?, button: NSView, readout: MenuBarReadoutView,
    fallback: Module, combined: Bool, mouseLocation: NSPoint = NSEvent.mouseLocation
  ) -> Module {
    guard combined, let event,
      event.type == .leftMouseDown || event.type == .leftMouseUp,
      PopoverInteraction.screenRect(of: button)?.contains(mouseLocation) == true,
      PopoverInteraction.hits(event, view: button, mouseLocation: mouseLocation),
      let point = PopoverInteraction.screenPoint(
        event, statusButtons: [button], mouseLocation: mouseLocation
      )
      .flatMap({ PopoverInteraction.point(screen: $0, in: readout) })
    else { return fallback }
    return readout.module(at: point.x) ?? fallback
  }

  /// Source identity is independent of coordinate recovery: arbitrary app windows must
  /// never have their click swallowed just because their pixels overlap a status button.
  func entry(for event: NSEvent, dropdownWindow: NSWindow? = nil) -> (
    module: Module, button: NSView
  )? {
    let targets = targets
    guard
      event.window == nil || event.window === dropdownWindow
        || targets.contains(where: { $0.button.window === event.window }),
      let screen = PopoverInteraction.screenPoint(
        event, statusButtons: targets.map(\.button), mouseLocation: mouseLocation())
    else { return nil }
    for entry in targets {
      guard let rect = PopoverInteraction.screenRect(of: entry.button), rect.contains(screen),
        let point = PopoverInteraction.point(screen: screen, in: entry.readout)
      else { continue }
      return (
        separateItems ? entry.module : (entry.readout.module(at: point.x) ?? entry.module),
        entry.button
      )
    }
    return nil
  }

  func hits(_ event: NSEvent, dropdownWindow: NSWindow? = nil) -> Bool {
    entry(for: event, dropdownWindow: dropdownWindow) != nil
  }

  /// Complete, distinct native frames only; hidden/overflow/transitional readings cannot erase a layout.
  var observedOrder: [Module]? {
    guard separateItems else { return nil }
    let entries = nativePositions
    guard entries.count == items.count, Set(entries.values).count == items.count else { return nil }
    return entries.sorted { $0.value > $1.value }.map(\.key)
  }

  /// Appearance callbacks during creation and old-but-complete post-rebuild frames are not edits.
  var adoptableOrder: [Module]? {
    guard !rebuilding else { return nil }
    return orderObservation.accept(observedOrder)
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
    rebuilding = true
    defer { rebuilding = false }
    var positions: [Module: Double] = [:]
    // Reuse saved slots exactly. Repeatedly deriving slots from laid-out button centers would
    // accumulate AppKit's placement offsets on every reorder and drift across the menu bar.
    for entry in items where separateItems {
      let key = "NSStatusItem Preferred Position " + autosaveName(for: entry.module)
      if let number = UserDefaults.standard.object(forKey: key) as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
        number.doubleValue >= 0,
        number.doubleValue < (entry.item.button?.window?.screen?.frame.width ?? 10_000)
      {
        positions[entry.module] = number.doubleValue
      }
    }
    if !separateItems && settings.separateItems {
      positions = MenuBarNativeOrder.savedPositions(
        order: settings.readouts, defaults: .standard, autosaveName: autosaveName)
    }
    removeAll()
    separateItems = settings.separateItems
    weight = settings.menuBarWeight
    orderObservation = MenuBarOrderObservation()
    let modules = settings.readouts.isEmpty ? [.overview] : settings.readouts
    if enforceOrder && separateItems {
      orderObservation.enforce(modules)
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
    itemTarget = target
    itemAction = action
    appearanceChange = onAppearanceChange
    appearanceObserver = nil
    // A Power item hidden by the current power source is not created; update() restores it.
    let groups =
      separateItems ? separateModules(settings).map { [$0] } : Self.groups(for: settings)
    for group in groups.reversed() {
      guard let module = group.first else { continue }
      makeItem(module)
    }
  }

  /// Separate items to present. If every enabled module is hidden by the power source, the
  /// TinyStats item keeps the app reachable (the same fallback as an empty readout list).
  private func separateModules(_ settings: Settings) -> [Module] {
    let modules = settings.readouts.filter { !hiddenModules.contains($0) }
    return modules.isEmpty ? [.overview] : modules
  }

  private func makeItem(_ module: Module) {
    guard let target = itemTarget, let action = itemAction else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = autosaveName(for: separateItems ? module : .overview)
    item.button?.target = target
    item.button?.action = action
    item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
    let weight = weight ?? .regular
    item.button?.font = Self.buttonFont(weight)
    item.button?.setAccessibilityIdentifier(
      "\(Bundle.main.bundleIdentifier ?? "tinystats").readout.\(module.rawValue)")
    let readout = MenuBarReadoutView(frame: .zero)
    readout.weight = weight
    if appearanceObserver == nil {
      readout.onAppearanceChange = appearanceChange
      appearanceObserver = readout
    }
    readout.autoresizingMask = [.width, .height]
    item.button?.addSubview(readout)
    items.append((module, item, readout))
  }

  /// Separate: remove/re-create only the affected native item, reusing its autosave slot
  /// (no persisted hidden state). One: the shared item drops the segment in update().
  private func applyPowerSourceVisibility(settings: Settings) {
    if let suppliedTargets {
      for target in suppliedTargets {
        if separateItems {
          target.button.isHidden = hiddenModules.contains(target.module)
        } else if let base = suppliedReadouts[ObjectIdentifier(target.readout)] {
          let shown = base.filter { $0.module.map(hiddenModules.contains) != true }
          if shown.map(\.module) != target.readout.readouts.map(\.module) {
            target.readout.readouts = shown
          }
        }
      }
      return
    }
    guard separateItems else { return }
    let desired = separateModules(settings)
    for entry in items where !desired.contains(entry.module) {
      NSStatusBar.system.removeStatusItem(entry.item)
      if appearanceObserver === entry.readout { appearanceObserver = nil }
    }
    items.removeAll { !desired.contains($0.module) }
    for module in desired where !items.contains(where: { $0.module == module }) {
      makeItem(module)
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
    // An empty battery list is also what a failed read returns: keep the last confirmed source.
    if let confirmed = PowerSourceKind.confirmed(snapshot.batteries) {
      lastConfirmedSource = confirmed
    }
    powerSource = PowerSourceKind.current(snapshot.batteries, lastKnown: lastConfirmedSource)
    let hidden = settings.powerHiddenModules(
      batteries: snapshot.batteries, lastKnown: lastConfirmedSource)
    let presented = settings.presentedReadouts(
      batteries: snapshot.batteries, lastKnown: lastConfirmedSource)
    presentedCombined = presented.isEmpty ? [.overview] : presented
    if hidden != hiddenModules {
      hiddenModules = hidden
      applyPowerSourceVisibility(settings: settings)
    }
    if weight != settings.menuBarWeight {
      let weight = settings.menuBarWeight
      self.weight = weight
      for target in targets {
        target.readout.weight = weight
        (target.button as? NSControl)?.font = Self.buttonFont(weight)
      }
    }
    for (module, item, view) in items {
      // An all-hidden One item keeps the TinyStats item so the app stays reachable.
      let modules = separateItems ? [module] : presentedCombined
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
    let order =
      (orderObservation.pendingEnforcedOrder == nil && !rebuilding ? observedOrder : nil) ?? []
    preferences.updateMenuBarContext(
      appearance: items.first?.readout.effectiveAppearance, order: order,
      height: items.first?.readout.bounds.height ?? NSStatusBar.system.thickness, paused: paused)
  }
}

/// Remap only TinyStats' existing native slots. Distances grow from the right edge of the bar.
enum MenuBarNativeOrder {
  /// Restore module slots when leaving One without creating or inspecting native status items.
  static func savedPositions(
    order: [Module], defaults: UserDefaults, autosaveName: (Module) -> String
  ) -> [Module: Double] {
    var positions: [Module: Double] = [:]
    for module in order {
      let key = "NSStatusItem Preferred Position " + autosaveName(module)
      if let number = defaults.object(forKey: key) as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
        number.doubleValue >= 0, number.doubleValue < 10_000
      {
        positions[module] = number.doubleValue
      }
    }
    return positions
  }

  static func positions(order: [Module], existing: [Module: Double]) -> [Module: Double] {
    // Removed modules must not donate their slots when enabling a different module.
    // All values here are AppKit autosave preferences, never measured button centers.
    let valid = existing.filter {
      order.contains($0.key) && $0.value.isFinite && $0.value >= 0 && $0.value < 10_000_000
    }
    let slots = Array(Set(valid.values)).sorted(by: >)
    let retained = order.filter { valid[$0] != nil }
    var result = Dictionary(uniqueKeysWithValues: zip(retained, slots))
    for (index, module) in order.enumerated() where result[module] == nil {
      let left = order[..<index].last.flatMap { result[$0] }
      let right = order.dropFirst(index + 1).compactMap { result[$0] }.first
      switch (left, right) {
      case (let left?, let right?): result[module] = (left + right) / 2
      case (nil, let right?): result[module] = right + 60
      case (let left?, nil):
        if left > 0 {
          result[module] = left > 60 ? left - 60 : left / 2
        } else {
          // A saved zero has no room to its right. Shift only this app's anchors.
          result = result.mapValues { $0 + 60 }
          result[module] = 0
        }
      case (nil, nil): result[module] = 100 + 60 * Double(order.count - index)
      }
    }
    return result
  }
}

/// Existing refreshes settle enforcement; a failed placement becomes a baseline, not an edit.
struct MenuBarOrderObservation {
  private(set) var pendingEnforcedOrder: [Module]?
  private var previousMismatch: [Module]?
  private var failedPlacement: [Module]?
  mutating func enforce(_ order: [Module]) {
    pendingEnforcedOrder = order
    previousMismatch = nil
    failedPlacement = nil
  }
  mutating func accept(_ observed: [Module]?) -> [Module]? {
    guard let observed, !observed.isEmpty else {
      previousMismatch = nil
      return nil
    }
    if let pendingEnforcedOrder {
      guard Set(observed) == Set(pendingEnforcedOrder), observed.count == pendingEnforcedOrder.count
      else {
        previousMismatch = nil
        return nil
      }
      if observed != pendingEnforcedOrder {
        if previousMismatch == observed {
          self.pendingEnforcedOrder = nil
          failedPlacement = observed
          previousMismatch = nil
        } else {
          previousMismatch = observed
        }
        return nil
      }
      self.pendingEnforcedOrder = nil
      previousMismatch = nil
    }
    guard observed != failedPlacement else { return nil }
    failedPlacement = nil
    return observed
  }
}
