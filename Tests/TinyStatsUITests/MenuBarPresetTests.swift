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

@Test @MainActor func oldSpacingValuesUseCompactGeometryWithoutSpacingControls() throws {
  _ = NSApplication.shared
  for value in ["tight", "standard", "relaxed", "future"] {
    for separate in [true, false] {
      let settings = try JSONDecoder().decode(
        Settings.self,
        from: Data("{\"separateItems\":\(separate),\"menuBarSpacing\":\"\(value)\"}".utf8))
      let controller = PreferencesController(
        settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar
      )
      defer { controller.close() }
      let root = try #require(controller.window?.contentView)
      root.layoutSubtreeIfNeeded()
      let preview = try #require(layoutViews(root).compactMap { $0 as? MenuBarPreviewView }.first)
      #expect(preview.renderers.count == (separate ? 3 : 1))
      #expect(preview.renderers.allSatisfy { $0.sidePadding == 0 && $0.itemSpacing == 1 })
      for step in 0..<5 {
        let welcome = WelcomeController(settings: { settings }, initialStep: step)
        defer { welcome.close() }
        let welcomeRoot = try #require(welcome.window?.contentView)
        #expect(
          !layoutViews(welcomeRoot).contains {
            ($0.accessibilityLabel() ?? "").localizedCaseInsensitiveContains("spacing")
              || ($0 as? NSTextField)?.stringValue == "Spacing"
          })
        for preview in layoutViews(welcomeRoot).compactMap({ $0 as? MenuBarPreviewView }) {
          #expect(preview.renderers.allSatisfy { $0.sidePadding == 0 && $0.itemSpacing == 1 })
        }
      }
      #expect(
        !layoutViews(root).contains {
          ($0.accessibilityLabel() ?? "").localizedCaseInsensitiveContains("spacing")
            || ($0 as? NSTextField)?.stringValue == "Spacing"
        })
      let picker = try #require(
        layoutViews(root).compactMap { $0 as? MenuBarStylePicker }.first { $0.module == .cpu })
      let expected = MenuBarReadoutView()
      expected.readouts = [
        MenuBarStyleExample.readout(module: .cpu, style: picker.tiles[0].style, settings: settings)
      ]
      #expect(picker.tiles[0].previewWidth == expected.preferredWidth)
    }
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
  renderer.readouts = [Module.cpu, .memory].map {
    MenuBarStyleExample.readout(module: $0, style: .stacked, settings: Settings())
  }
  #expect(renderer.module(at: 0) == .cpu)
  #expect(renderer.module(at: renderer.preferredWidth - 1) == .memory)
  #expect(renderer.itemSpacing == 1 && renderer.sidePadding == 0)
}

@Test @MainActor func menuBarIconSegmentsExposeEveryChoiceName() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  for (label, titles) in [
    ("Menu bar layout", ["Separate", "One"])
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
  preview.update(groups: readouts.map { [$0] }, paused: false, height: 24)
  let separateWidth = preview.preferredWidth
  #expect(preview.renderers.first?.frame.minX == 1.5)
  for index in 1..<preview.renderers.count {
    // Each outline adds 1.5pt at both sides, outside the untouched compact renderer.
    #expect(preview.renderers[index].frame.minX - preview.renderers[index - 1].frame.maxX == 12)
  }
  #expect(separateWidth == preview.renderers.reduce(0) { $0 + $1.preferredWidth } + 27)
  preview.update(groups: [readouts], paused: false, height: 24)
  #expect(preview.renderers.count == 1)
  #expect(preview.preferredWidth - preview.renderers[0].frame.maxX == 1.5)
  #expect(separateWidth > preview.preferredWidth)
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
