import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func layoutViews(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + layoutViews($0) }
}
@MainActor private func layoutControl(_ root: NSView, _ label: String) throws -> NSSegmentedControl
{
  try #require(
    layoutViews(root).compactMap { $0 as? NSSegmentedControl }.first {
      $0.accessibilityLabel() == label
    })
}
@MainActor private func layoutActivate(_ control: NSControl) throws {
  #expect(NSApp.sendAction(try #require(control.action), to: control.target, from: control))
}

@Test @MainActor func menuBarLayoutsPreserveCompactPresetMigrationAndPersistOne() throws {
  _ = NSApplication.shared
  let settings = try JSONDecoder().decode(
    Settings.self,
    from: Data(
      #"{"readouts":["cpu","memory","network"],"styles":{"cpu":"horizontal","memory":"horizontal","network":"text","gpu":"ring"},"appearances":{"cpu":{"size":"compact"},"memory":{"size":"compact"},"network":{"size":"compact"}}}"#
        .utf8))
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let control = try layoutControl(root, "Menu bar layout")
  #expect(control.selectedSegment == 0)
  #expect(control.segmentCount == 2)
  #expect((0..<2).map { control.toolTip(forSegment: $0) } == ["Separate", "One"])
  #expect(
    (0..<2).allSatisfy {
      control.label(forSegment: $0)?.isEmpty != false && control.image(forSegment: $0) != nil
    })
  let preview = try #require(layoutViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
  var changed: Settings?
  controller.onChange = { changed = $0 }
  for index in [1, 0, 1] {
    control.selectedSegment = index
    try layoutActivate(control)
    var expected = settings
    expected.separateItems = index == 0
    #expect(changed == expected)
    #expect(preview.renderers.count == (index == 0 ? 3 : 1))
    #expect(
      preview.renderers.flatMap(\.readouts).map(\.style) == [.horizontal, .horizontal, .text])
    #expect(preview.renderers.flatMap(\.readouts).allSatisfy { $0.appearance.size == .compact })
    #expect(
      StatusItemController.groups(for: expected)
        == (index == 0 ? [[.cpu], [.memory], [.network]] : [[.cpu, .memory, .network]]))
  }
  let restored = try JSONDecoder().decode(
    Settings.self, from: JSONEncoder().encode(try #require(changed)))
  let reopened = PreferencesController(
    settings: restored, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { reopened.close() }
  #expect(
    try layoutControl(#require(reopened.window?.contentView), "Menu bar layout").selectedSegment
      == 1)
}

@Test @MainActor func menuBarSpacingControlChangesGeometryInBothLayoutsAndStylePictures() throws {
  _ = NSApplication.shared
  for separate in [true, false] {
    var settings = Settings()
    settings.separateItems = separate
    let controller = PreferencesController(
      settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
    defer { controller.close() }
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    let spacing = try layoutControl(root, "Menu bar spacing")
    #expect(
      spacing.selectedSegment == 1
        && spacing.frame.height <= PreferencesController.menuBarToolsHeightBudget)
    let row = try #require(spacing.superview as? SystemFormRow)
    #expect(row.frame.height <= PreferencesController.menuBarLayoutRowHeightBudget)
    let preview = try #require(layoutViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
    let picker = try #require(
      layoutViews(root).compactMap { $0 as? MenuBarStylePicker }.first { $0.module == .cpu })
    var changed: Settings?
    controller.onChange = { changed = $0 }
    var widths: [CGFloat] = []
    var tileWidths: [CGFloat] = []
    for index in 0..<3 {
      spacing.selectedSegment = index
      try layoutActivate(spacing)
      #expect(changed?.menuBarSpacing == MenuBarSpacing.allCases[index])
      #expect(changed?.separateItems == separate && changed?.styles == settings.styles)
      #expect(preview.renderers.allSatisfy { $0.spacing == MenuBarSpacing.allCases[index] })
      widths.append(preview.preferredWidth)
      tileWidths.append(try #require(picker.tiles.first).previewWidth)
      let decoded = try JSONDecoder().decode(
        Settings.self, from: JSONEncoder().encode(try #require(changed)))
      #expect(decoded == changed)
    }
    #expect(widths[0] < widths[1] && widths[1] < widths[2])
    #expect(tileWidths[0] < tileWidths[1] && tileWidths[1] < tileWidths[2])
    #expect(widths[2] - widths[0] == 18)
    #expect(preview.renderers[0].preferredWidth > 0)
    controller.updateMenuBarSettings(settings)
    #expect(spacing.selectedSegment == 1)
  }
}

@Test @MainActor func menuBarStyleEditsAndDisclosurePreserveLayoutChoice() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.separateItems = false
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let layout = try layoutControl(root, "Menu bar layout")
  let disclosure = try #require(
    layoutViews(root).compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel() == "Customize menu bar styles"
    })
  let picker = try #require(
    layoutViews(root).compactMap { $0 as? MenuBarStylePicker }.first { $0.module == .cpu })
  var changed: Settings?
  controller.onChange = { changed = $0 }
  picker.selectItem(withTitle: MenuBarStyle.ring.title)
  try layoutActivate(picker)
  #expect(changed?.separateItems == false && changed?.style(for: .cpu) == .ring)
  #expect(layout.selectedSegment == 1)
  disclosure.performClick(nil)
  #expect(picker.isHiddenOrHasHiddenAncestor)
  controller.selectPage(.general)
  controller.selectMenuBarTab()
  #expect(picker.isHiddenOrHasHiddenAncestor && layout.selectedSegment == 1)
  disclosure.performClick(nil)
  #expect(!picker.isHiddenOrHasHiddenAncestor)
  var external = settings
  external.separateItems = true
  controller.updateMenuBarSettings(external)
  #expect(layout.selectedSegment == 0)
}

@Test @MainActor func combinedReadoutRoutesSegmentsWithoutRealStatusItems() {
  let renderer = MenuBarReadoutView()
  renderer.spacing = .relaxed
  renderer.readouts = [Module.cpu, .memory].map {
    MenuBarStyleExample.readout(module: $0, style: .stacked, settings: Settings())
  }
  #expect(renderer.module(at: 0) == .cpu)
  #expect(renderer.module(at: renderer.preferredWidth - 1) == .memory)
  #expect(renderer.itemSpacing == 7 && renderer.sidePadding == 3)
}

@Test @MainActor func menuBarIconSegmentsExposeEveryChoiceName() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  for (label, titles) in [
    ("Menu bar layout", ["Separate", "One"]),
    ("Menu bar spacing", ["Tight", "Standard", "Relaxed"]),
  ] {
    let control = try layoutControl(root, label)
    #expect(
      (0..<control.segmentCount).map { control.image(forSegment: $0)?.accessibilityDescription }
        == titles)
    // AppKit exposes the radio buttons through the segmented cell's radio group.
    func segmentNames(_ element: any NSAccessibilityProtocol) -> [String?] {
      if element.accessibilityRole() == .radioButton { return [element.accessibilityLabel()] }
      return (element.accessibilityChildren() ?? [])
        .compactMap { $0 as? any NSAccessibilityProtocol }.flatMap { segmentNames($0) }
    }
    #expect(segmentNames(control) == titles)
  }
}

@Test @MainActor func menuBarSeparatePreviewHasFixedNativeItemGaps() throws {
  let preview = MenuBarPreviewView(frame: .init(x: 0, y: 0, width: 420, height: 36))
  let readouts = [Module.cpu, .memory, .network].map {
    MenuBarStyleExample.readout(module: $0, style: .stacked, settings: Settings())
  }
  for spacing in MenuBarSpacing.allCases {
    preview.update(groups: readouts.map { [$0] }, paused: false, height: 24, spacing: spacing)
    let separateWidth = preview.preferredWidth
    for index in 1..<preview.renderers.count {
      #expect(preview.renderers[index].frame.minX - preview.renderers[index - 1].frame.maxX == 9)
    }
    #expect(separateWidth == preview.renderers.reduce(0) { $0 + $1.preferredWidth } + 18)
    preview.update(groups: [readouts], paused: false, height: 24, spacing: spacing)
    #expect(preview.renderers.count == 1)
    #expect(separateWidth > preview.preferredWidth)
  }
}

@Test @MainActor func separateLayoutRestoresSavedNativeSlotsWithoutRealStatusItems() throws {
  let suite = "TinyStats.LayoutSlots." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  func autosave(_ module: Module) -> String { "fixture.tinystats." + module.rawValue }
  func key(_ module: Module) -> String { "NSStatusItem Preferred Position " + autosave(module) }
  let original: [Module: Double] = [.cpu: 731.5, .memory: 472, .network: 263]
  for (module, position) in original { defaults.set(position, forKey: key(module)) }
  defaults.set(99, forKey: key(.overview))  // The One item has its own slot.
  defaults.set(1000, forKey: key(.gpu))  // Disabled modules cannot donate their slots.
  let order: [Module] = [.cpu, .memory, .network]
  let saved = MenuBarNativeOrder.savedPositions(
    order: order, defaults: defaults, autosaveName: autosave)
  #expect(saved == original)
  #expect(MenuBarNativeOrder.positions(order: order, existing: saved) == original)
  defaults.set(true, forKey: key(.cpu))
  defaults.set(-1, forKey: key(.memory))
  defaults.set(Double.infinity, forKey: key(.network))
  #expect(
    MenuBarNativeOrder.savedPositions(order: order, defaults: defaults, autosaveName: autosave)
      .isEmpty)
}
