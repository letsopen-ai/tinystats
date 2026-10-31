import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func layoutDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + layoutDescendants($0) }
}

@Test @MainActor func menuBarCustomizationFallbacksUpdateExistingControlsAndPreviewImmediately()
  throws
{
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  root.layoutSubtreeIfNeeded()
  let views = layoutDescendants(root)
  let editor = try #require(views.compactMap { $0 as? MenuBarCustomization }.first)
  let preview = try #require(views.compactMap { $0 as? MenuBarPreviewView }.first)
  let cpu = try #require(editor.chips[.cpu])
  let gpu = try #require(editor.chips[.gpu])
  var changes: [Settings] = []
  controller.onChange = { changes.append($0) }
  #expect(editor.order == [.cpu, .memory, .network])
  #expect(editor.strip.chips.map(\.module) == editor.order)
  #expect(editor.palette.chips.count == 6)
  #expect(gpu.accessibilityCustomActions()?.map(\.name) == ["Add to menu bar"])
  #expect(gpu.accessibilityCustomActions()?.first?.handler?() == true)
  #expect(editor.order == [.cpu, .memory, .network, .gpu])
  #expect(changes.last?.readouts == editor.order)
  let gpuStyle = try #require(
    views.compactMap { $0 as? MenuBarStylePicker }.first {
      $0.accessibilityLabel() == "GPU menu bar style"
    })
  #expect(editor.order.contains(.gpu) && gpuStyle.isEnabled)
  #expect(preview.renderers.count == 4)
  let menu = try #require(cpu.menu(for: NSEvent()))
  #expect(
    menu.items.map(\.title) == [
      "Remove from menu bar", "Move left", "Move right", "Move to start", "Move to end",
    ])
  #expect(!menu.items[1].isEnabled && menu.items[2].isEnabled)
  let toEnd = menu.items[4]
  #expect(NSApp.sendAction(try #require(toEnd.action), to: toEnd.target, from: toEnd))
  #expect(editor.order == [.memory, .network, .gpu, .cpu])
  #expect(editor.lastAnnouncement.contains("position 4 of 4"))
  let moveLeft = try #require(cpu.accessibilityCustomActions()?.first { $0.name == "Move left" })
  #expect(moveLeft.handler?() == true)
  #expect(editor.order == [.memory, .network, .cpu, .gpu])
  #expect(cpu.accessibilityPerformPress())
  #expect(controller.selectedStyleModule == .cpu)
  #expect(editor.order == [.memory, .network, .cpu, .gpu])
  #expect(
    cpu.accessibilityCustomActions()?.first { $0.name == "Remove from menu bar" }?.handler?()
      == true)
  #expect(editor.order == [.memory, .network, .gpu])
  #expect(editor.lastAnnouncement == "CPU removed from menu bar.")
  #expect(cpu.accessibilityValue() as? String == "Available")
  // A native/menu refresh while the context menu is open must not turn Remove into Add.
  let staleRemove = menu.items[0]
  let previousWrites = changes.count
  #expect(
    NSApp.sendAction(try #require(staleRemove.action), to: staleRemove.target, from: staleRemove))
  #expect(editor.order == [.memory, .network, .gpu] && changes.count == previousWrites)
  #expect(editor.perform(.remove, for: .memory))
  #expect(editor.perform(.remove, for: .network))
  #expect(!editor.perform(.remove, for: .gpu))
  #expect(editor.order == [.gpu] && editor.lastAnnouncement.hasPrefix("Keep at least one"))
  #expect(gpu.accessibilityCustomActions()?.isEmpty == true)
  #expect(gpu.menu(for: NSEvent())?.items.allSatisfy { !$0.isEnabled } == true)
  #expect(changes.last?.readouts == [.gpu])
  #expect(changes.allSatisfy { !$0.weather.enabled })
}

@Test @MainActor func menuBarCustomizationKeyboardRetainsFocusAndUsesObservedNativeOrder() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let window = try #require(controller.window)
  window.makeKeyAndOrderFront(nil)
  let root = try #require(window.contentView)
  let editor = try #require(
    layoutDescendants(root).compactMap { $0 as? MenuBarCustomization }
      .first)
  let cpu = try #require(editor.chips[.cpu])
  var result: Settings?
  controller.onChange = { result = $0 }
  controller.updateMenuBarContext(
    appearance: nil, order: [.network, .cpu, .memory], height: 24, paused: false)
  #expect(editor.order == [.network, .cpu, .memory])
  #expect(cpu.canBecomeKeyView && window.makeFirstResponder(cpu))
  func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
    window.sendEvent(
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
  }
  try key(124, "\u{f703}")
  #expect((window.firstResponder as? MenuBarChip)?.module == .memory)
  try key(123, "\u{f702}")
  #expect(window.firstResponder === cpu)
  try key(123, "\u{f702}", .option)
  #expect(result?.readouts == [.cpu, .network, .memory])
  #expect(window.firstResponder === cpu)
  try key(124, "\u{f703}", [.command, .shift])
  #expect(result?.readouts == [.network, .memory, .cpu])
  try key(49, " ")
  #expect(result?.readouts == [.network, .memory] && window.firstResponder === cpu)
  try key(36, "\r")
  #expect(result?.readouts == [.network, .memory, .cpu] && window.firstResponder === cpu)
  window.selectNextKeyView(nil)
  #expect(window.firstResponder is NSView && window.firstResponder !== cpu)
}

@Test func menuBarNativeSlotsPreserveLegacyOrderAndMapExplicitReorders() {
  let original: [Module: Double] = [.cpu: 120, .network: 240, .memory: 180]
  let native = original.sorted { $0.value > $1.value }.map(\.key)
  #expect(native == [.network, .memory, .cpu])
  #expect(MenuBarNativeOrder.positions(order: native, existing: original) == original)
  let reordered = MenuBarNativeOrder.positions(
    order: [.cpu, .memory, .network], existing: original)
  #expect(reordered == [.cpu: 240, .memory: 180, .network: 120])
  #expect(
    MenuBarNativeOrder.positions(order: [.memory, .cpu], existing: original) == [
      .memory: 180, .cpu: 120,
    ])
  let added = MenuBarNativeOrder.positions(
    order: [.cpu, .gpu, .memory, .network], existing: original)
  #expect(added.sorted { $0.value > $1.value }.map(\.key) == [.cpu, .gpu, .memory, .network])
  let malformed = MenuBarNativeOrder.positions(
    order: [.cpu, .memory, .network], existing: [.cpu: .nan, .memory: -4, .gpu: .infinity])
  #expect(malformed.values.allSatisfy { $0.isFinite && $0 >= 0 })
  #expect(Set(malformed.values).count == 3)
}

/// Drives the real AppKit destination methods, including hover, stale/private payload rejection,
/// cancellation and accepted drops. No system pasteboard, mouse event injection or saved preferences.
@MainActor final class ReadoutDrag: NSObject, NSDraggingInfo {
  var draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation = .move
  var draggingLocation = NSPoint.zero
  var draggedImageLocation = NSPoint.zero
  nonisolated var draggedImage: NSImage? { nil }
  let draggingPasteboard = NSPasteboard.withUniqueName()
  var draggingSource: Any?
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL)
    -> [String]?
  { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}

@Test @MainActor func menuBarCustomizationDragDestinationsCommitOnlyValidAcceptedDrops() throws {
  _ = NSApplication.shared
  var settings = Settings()
  let editor = MenuBarCustomization(frame: .init(x: 0, y: 0, width: 640, height: 254))
  editor.update(order: settings.readouts)
  var writes = 0
  defer { editor.onAction = nil }
  editor.onAction = { module, action in
    let changed = settings.customizeReadout(module, action: action)
    if changed {
      writes += 1
      editor.update(order: settings.readouts)
    }
    return changed
  }
  let drag = ReadoutDrag()
  defer { drag.draggingPasteboard.releaseGlobally() }
  func payload(_ module: Module) throws {
    let chip = try #require(editor.chips[module])
    drag.draggingSource = chip
    drag.draggingPasteboard.clearContents()
    #expect(drag.draggingPasteboard.writeObjects([editor.pasteboardItem(for: module)]))
  }
  try payload(.gpu)
  let cpu = try #require(editor.chips[.cpu])
  #expect(editor.strip.insertionIndex(at: .init(x: cpu.frame.minX, y: 20)) == 0)
  drag.draggingLocation = editor.strip.convert(
    .init(x: cpu.frame.maxX + 2, y: cpu.frame.midY), to: nil)
  #expect(editor.strip.draggingEntered(drag) == .move)
  #expect(editor.strip.insertion == 1)
  #expect(settings.readouts == [.cpu, .memory, .network] && writes == 0)
  editor.strip.draggingExited(drag)
  editor.strip.draggingEnded(drag)
  #expect(editor.strip.insertion == nil && writes == 0)
  #expect(editor.strip.prepareForDragOperation(drag))
  #expect(editor.strip.performDragOperation(drag))
  #expect(settings.readouts == [.cpu, .gpu, .memory, .network] && writes == 1)
  #expect(editor.strip.insertion == nil)
  try payload(.network)
  drag.draggingLocation = editor.strip.convert(.init(x: 0, y: cpu.frame.midY), to: nil)
  #expect(editor.strip.performDragOperation(drag))
  #expect(settings.readouts == [.network, .cpu, .gpu, .memory])
  #expect(editor.palette.performDragOperation(drag))
  #expect(settings.readouts == [.cpu, .gpu, .memory])
  #expect(editor.palette.draggingEntered(drag).isEmpty)  // already available
  try payload(.cpu)
  drag.draggingPasteboard.clearContents()
  drag.draggingPasteboard.setString("external:cpu", forType: MenuBarCustomization.pasteboardType)
  #expect(editor.strip.draggingEntered(drag).isEmpty)
  #expect(!editor.strip.performDragOperation(drag))
  #expect(settings.readouts == [.cpu, .gpu, .memory])
  try payload(.cpu)
  // Matching text from a different pane is still not an authorized local source.
  let other = MenuBarCustomization(frame: .zero)
  drag.draggingSource = other.chips[.cpu]
  #expect(!editor.palette.prepareForDragOperation(drag))
  settings.readouts = [.cpu]
  editor.update(order: settings.readouts)
  try payload(.cpu)
  #expect(editor.palette.draggingUpdated(drag).isEmpty)
  #expect(!editor.palette.performDragOperation(drag))
  #expect(settings.readouts == [.cpu])
  #expect(!settings.weather.enabled)
  // Eight available chips wrap into two rows with full, uncompressed labels.
  #expect(editor.palette.chips.allSatisfy { editor.palette.bounds.contains($0.frame) })
  settings.readouts = Module.allCases.filter { $0 != .overview }
  editor.update(order: settings.readouts)
  #expect(editor.palette.chips.isEmpty)
  #expect(editor.strip.chips.allSatisfy { editor.strip.bounds.contains($0.frame) })
  try payload(.cpu)
  let last = try #require(editor.strip.chips.last)
  drag.draggingLocation = editor.strip.convert(
    .init(x: last.frame.maxX + 2, y: last.frame.midY), to: nil)
  #expect(editor.strip.draggingUpdated(drag) == .move)
  #expect(editor.strip.insertion == editor.order.count)
  #expect(writes == 3)  // hover still does not save settings
}

@MainActor private final class NativeReadoutTarget: NSObject {
  @objc func activate(_ sender: Any?) {}
}

/// Opt-in host integration probe. Creates real native status items only in an isolated test process.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TINYSTATS_NATIVE_ORDER_TEST"] == "1"))
@MainActor func menuBarNativeStatusItemOrderMigratesAndRebuildsOnHost() throws {
  let domain = try #require(ProcessInfo.processInfo.environment["TINYSTATS_PREFERENCES_DOMAIN"])
  #expect(domain.hasPrefix("TinyStats-native-order-test-"))
  guard domain.hasPrefix("TinyStats-native-order-test-") else { return }
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.accessory)
  NSApp.finishLaunching()
  let controller = StatusItemController()
  let target = NativeReadoutTarget()
  let modules: [Module] = [.cpu, .memory, .network, .gpu]
  func key(_ module: Module) -> String {
    "NSStatusItem Preferred Position " + domain + ".tinystats." + module.rawValue
  }
  defer {
    controller.removeAll()
    for module in modules { UserDefaults.standard.removeObject(forKey: key(module)) }
  }
  for (module, slot) in [(Module.cpu, 140), (.memory, 300), (.network, 500)] {
    UserDefaults.standard.set(slot, forKey: key(module))
  }
  var settings = Settings()
  func rebuild(enforce: Bool) {
    controller.rebuild(
      settings: settings, target: target, action: #selector(NativeReadoutTarget.activate(_:)),
      enforceOrder: enforce, onAppearanceChange: {})
    controller.update(
      snapshot: Snapshot(), history: [], settings: settings, clockDate: Date(), paused: false)
  }
  func expectNative(_ expected: [Module]) {
    let deadline = Date().addingTimeInterval(2)
    while controller.observedOrder != expected && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    #expect(controller.observedOrder == expected)
  }
  rebuild(enforce: false)
  expectNative([.network, .memory, .cpu])
  let adopted = settings.adoptNativeReadoutOrder(try #require(controller.observedOrder))
  #expect(adopted)
  settings.readouts = [.cpu, .network, .memory]
  rebuild(enforce: true)
  expectNative(settings.readouts)
  let originalSlots = Set(settings.readouts.map { UserDefaults.standard.double(forKey: key($0)) })
  // Repeated edits must preserve placement slots, without cumulative center/edge offset drift.
  for _ in 0..<8 {
    settings.readouts.reverse()
    rebuild(enforce: true)
    expectNative(settings.readouts)
    #expect(
      Set(settings.readouts.map { UserDefaults.standard.double(forKey: key($0)) }) == originalSlots)
  }
  settings.customizeReadout(.gpu, action: .add(at: 1))
  rebuild(enforce: true)
  expectNative(settings.readouts)
  settings.customizeReadout(.network, action: .remove)
  rebuild(enforce: true)
  expectNative(settings.readouts)
  // Restarts preserve the same explicit layout through native autosave slots and settings JSON.
  controller.removeAll()
  settings = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
  rebuild(enforce: false)
  expectNative(settings.readouts)
}

@Test func enforcedMenuBarOrderIgnoresCompleteTransitionalFrames() {
  var observation = MenuBarOrderObservation()
  let old: [Module] = [.cpu, .memory, .network]
  let requested: [Module] = [.network, .cpu, .memory]
  observation.enforce(requested)
  #expect(observation.accept(nil) == nil)
  #expect(observation.accept(old) == nil)
  // Incomplete frames break the consecutive-stability check.
  #expect(observation.accept([.cpu, .memory]) == nil)
  #expect(observation.accept(old) == nil)
  #expect(observation.pendingEnforcedOrder == requested)
  #expect(observation.accept(requested) == requested)
  #expect(observation.pendingEnforcedOrder == nil)
  #expect(observation.accept(old) == old)  // Later native ⌘-drag is eligible again.
  observation.enforce([.memory, .cpu])
  #expect(observation.accept(old) == nil)
}

@Test func nativeMenuBarSlotsRetainSurvivorsWhenAddingAndRemovingTogether() {
  #expect(
    MenuBarNativeOrder.positions(
      order: [.memory, .gpu], existing: [.cpu: 500, .network: 300, .memory: 100]
    ) == [.memory: 100, .gpu: 40])
}

@Test @MainActor func menuBarEmptyObservationAndInvalidActionDoNotChangeSavedOrDisplayedOrder()
  throws
{
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let editor = try #require(
    layoutDescendants(root).compactMap { $0 as? MenuBarCustomization }.first)
  var changes = 0
  controller.onChange = { _ in changes += 1 }
  for partial: [Module] in [[], [.network], [.network, .cpu]] {
    controller.updateMenuBarContext(appearance: nil, order: partial, height: 24, paused: false)
    #expect(editor.order == Settings().readouts)
  }
  controller.updateMenuBarContext(
    appearance: nil, order: [.network, .cpu, .memory], height: 24, paused: false)
  #expect(!editor.perform(.remove, for: .gpu))
  controller.updateMenuBarContext(appearance: nil, order: [], height: 24, paused: false)
  #expect(editor.order == Settings().readouts && changes == 0)
}

@Test @MainActor func menuBarEmptyEditorStillPositionsAvailableChipsAndExposesGroups() throws {
  let editor = MenuBarCustomization(frame: .init(x: 0, y: 0, width: 640, height: 254))
  let window = NSWindow(
    contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = editor
  defer {
    window.contentView = nil
    window.close()
  }
  editor.update(order: [])
  #expect(editor.strip.chips.isEmpty && editor.palette.chips.count == 9)
  #expect(editor.palette.chips.allSatisfy { $0.frame.width > 0 && $0.frame.height == 28 })
  #expect(editor.strip.accessibilityRole() == .group)
  #expect(editor.chips.values.allSatisfy { $0.accessibilityRole() == .group })
  #expect(editor.palette.accessibilityLabel() == "Available")
  let cpu = try #require(editor.chips[.cpu])
  cpu.appearance = NSAppearance(named: .aqua)
  let light = try #require(cpu.dragImage()?.tiffRepresentation)
  cpu.appearance = NSAppearance(named: .darkAqua)
  #expect(try #require(cpu.dragImage()?.tiffRepresentation) != light)
  editor.palette.needsDisplay = false
  NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
  #expect(editor.palette.needsDisplay && cpu.needsDisplay)
}

@Test func stableFailedPlacementReleasesPendingWithoutReplacingSavedIntent() {
  var observation = MenuBarOrderObservation()
  let requested: [Module] = [.network, .cpu, .memory]
  let placed: [Module] = [.cpu, .memory, .network]
  let dragged: [Module] = [.memory, .cpu, .network]
  observation.enforce(requested)
  #expect(observation.accept(placed) == nil)
  #expect(observation.pendingEnforcedOrder == requested)
  #expect(observation.accept(nil) == nil)  // Partial/overflow breaks consecutive stability.
  #expect(observation.accept(placed) == nil)
  #expect(observation.pendingEnforcedOrder == requested)
  #expect(observation.accept(placed) == nil)
  #expect(observation.pendingEnforcedOrder == nil)
  #expect(observation.accept(placed) == nil)  // Failed enforcement itself is never an edit.
  #expect(observation.accept(dragged) == dragged)
  observation.enforce(requested)
  #expect(observation.accept(placed) == nil)
  #expect(observation.accept(dragged) == nil)  // Changing frames cannot settle enforcement.
  #expect(observation.pendingEnforcedOrder == requested)
  #expect(observation.accept(requested) == requested)
}

@Test @MainActor func menuBarCustomizationWrapsEveryChipWithinBothWells() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.readouts = Module.allCases.filter { $0 != .overview }
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  root.layoutSubtreeIfNeeded()
  let views = layoutDescendants(root)
  let editor = try #require(views.compactMap { $0 as? MenuBarCustomization }.first)
  for width: CGFloat in [740, 884, 1000, 740] {
    controller.window?.setContentSize(.init(width: width, height: 660))
    for order in [settings.readouts, [.cpu], []] {
      editor.update(order: order)
      root.layoutSubtreeIfNeeded()
      for well in [editor.strip, editor.palette] {
        let parent = try #require(well.superview)
        #expect(parent.bounds.contains(well.frame))
        #expect(editor.bounds.contains(editor.convert(well.bounds, from: well)))
        #expect(well.chips.allSatisfy { well.bounds.insetBy(dx: 8, dy: 8).contains($0.frame) })
        #expect(
          well.chips.allSatisfy {
            well.hitTest(well.convert(.init(x: $0.frame.midX, y: $0.frame.midY), to: parent)) === $0
          })
      }
      let disclosure = try #require(
        views.compactMap { $0 as? NSButton }.first {
          $0.accessibilityLabel() == "Customize menu bar readouts and styles"
        })
      let nextFrame = editor.convert(disclosure.bounds, from: disclosure)
      #expect(nextFrame.minY >= editor.bounds.maxY + 8)
    }
  }
}

@Test @MainActor func menuBarRingFixtureKeepsMembershipAndOnlyDisablesFont() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.styles["cpu"] = .ring
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  root.layoutSubtreeIfNeeded()
  let views = layoutDescendants(root)
  let tray = try #require(views.compactMap { $0 as? MenuBarCustomization }.first)
  let style = try #require(
    views.compactMap { $0 as? MenuBarStylePicker }.first {
      $0.accessibilityLabel() == "CPU menu bar style"
    })
  let font = try #require(
    views.compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "CPU menu bar font size"
    })
  #expect(tray.order.contains(.cpu))
  #expect(style.isEnabled && style.titleOfSelectedItem == MenuBarStyle.ring.title)
  #expect(!font.isEnabled)
}

@Test @MainActor func menuBarWrappedRowsKeepDragKeyboardAndContextActions() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.readouts = Module.allCases.filter { $0 != .overview }
  let editor = MenuBarCustomization(frame: .init(x: 0, y: 0, width: 640, height: 300))
  let window = NSWindow(
    contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = editor
  defer { window.close() }
  editor.update(order: settings.readouts)
  editor.onAction = { module, action in
    let changed = settings.customizeReadout(module, action: action)
    if changed { editor.update(order: settings.readouts) }
    return changed
  }
  defer { editor.onAction = nil }
  let rowStart = try #require(editor.strip.chips.firstIndex { $0.frame.minY > 12 })
  let chip = editor.strip.chips[rowStart]
  let preceding = editor.strip.chips[rowStart - 1]
  #expect(
    editor.strip.insertionIndex(at: .init(x: chip.frame.minX, y: chip.frame.midY)) == rowStart)
  #expect(
    editor.strip.insertionIndex(at: .init(x: preceding.frame.maxX + 3, y: preceding.frame.midY))
      == rowStart)
  #expect(window.makeFirstResponder(chip))
  func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws {
    chip.keyDown(
      with: try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
  }
  try key(123, "", .option)
  #expect(editor.order[rowStart - 1] == chip.module && chip.frame.minY == 12)
  #expect(window.firstResponder === chip)
  try key(124, "", .option)
  #expect(editor.order[rowStart] == chip.module && chip.frame.minY > 12)
  try key(36, "\r")
  #expect(!editor.order.contains(chip.module) && chip.superview === editor.palette)
  try key(49, " ")
  #expect(editor.order.last == chip.module && chip.superview === editor.strip)
  let menu = try #require(chip.menu(for: NSEvent()))
  let start = try #require(menu.items.first { $0.title == "Move to start" })
  #expect(NSApp.sendAction(try #require(start.action), to: start.target, from: start))
  #expect(editor.order.first == chip.module && window.firstResponder === chip)
  let drag = ReadoutDrag()
  defer { drag.draggingPasteboard.releaseGlobally() }
  drag.draggingSource = chip
  #expect(drag.draggingPasteboard.writeObjects([editor.pasteboardItem(for: chip.module)]))
  let targetIndex = try #require(editor.strip.chips.firstIndex { $0.frame.minY > 12 })
  let target = editor.strip.chips[targetIndex]
  drag.draggingLocation = editor.strip.convert(
    .init(x: target.frame.minX, y: target.frame.midY), to: nil)
  #expect(editor.strip.draggingEntered(drag) == .move)
  #expect(editor.strip.insertion == targetIndex)
  let marker = try #require(editor.strip.insertionFrame)
  #expect(marker.minY == target.frame.minY + 2 && editor.strip.bounds.contains(marker))
  #expect(editor.strip.performDragOperation(drag))
  #expect(editor.order[targetIndex - 1] == chip.module)
  #expect(!settings.weather.enabled)
}

@Test @MainActor func darkMenuBarChipGlyphUsesFullOpacityLabelInk() throws {
  _ = NSApplication.shared
  let chip = MenuBarChip(module: .battery)
  chip.frame = .init(x: 0, y: 0, width: chip.chipWidth, height: 28)
  chip.appearance = NSAppearance(named: .darkAqua)
  let data = try #require(chip.dragImage()?.tiffRepresentation)
  let bitmap = try #require(NSBitmapImageRep(data: data))
  let scale = CGFloat(bitmap.pixelsHigh) / 28
  var peak: CGFloat = 0
  for y in Int(8 * scale)..<Int(20 * scale) {
    for x in Int(10 * scale)..<Int(23 * scale) {
      let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      peak = max(peak, min(color.redComponent, color.greenComponent, color.blueComponent))
    }
  }
  #expect(peak > 0.9)
}
