import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func presetDescendants(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + presetDescendants($0) }
}

@MainActor private func presetActivate(_ control: NSControl) throws {
  #expect(
    NSApplication.shared.sendAction(
      try #require(control.action), to: control.target, from: control))
}

@MainActor private func presetControl<T: NSView>(_ root: NSView, _ label: String) throws -> T {
  try #require(
    presetDescendants(root).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label })
}

@Test @MainActor func menuBarPresetsApplyImmediatelyAndRefreshExpandedControlsAndLivePreview()
  throws
{
  _ = NSApplication.shared
  // Exercise both explicit Weather choices without requesting permission or starting collectors.
  let cases: [(Bool, String, [Module], [MenuBarStyle])] = [
    (false, "cpu", [.sensors, .disks, .cpu], [.horizontal, .horizontal, .horizontal]),
    (
      true, "F0Ac", [.sensors, .disks, .cpu, .network, .clock, .weather],
      [.text, .horizontal, .horizontal, .text, .text, .text]
    ),
  ]
  for (weatherEnabled, sensorKey, enabledReadouts, compactStyles) in cases {
    var settings = Settings()
    settings.readouts = enabledReadouts
    settings.sensorKey = sensorKey
    for module in enabledReadouts {
      settings.styles[module.rawValue] = .value
      settings.appearances[module.rawValue] = .init(size: .large, color: .purple)
    }
    settings.styles[Module.gpu.rawValue] = .ring
    settings.appearances[Module.gpu.rawValue] = .init(size: .large, color: .purple)
    settings.interval = 10
    settings.persistHistory = false
    settings.weather = .currentLocationDefault
    settings.weather.enabled = weatherEnabled
    let controller = PreferencesController(
      settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
    defer { controller.close() }
    let root = try #require(controller.window?.contentView)
    let presets: SystemPresetChoices = try presetControl(root, "Menu bar presets")
    let disclosure: NSButton = try presetControl(root, "Customize menu bar readouts and styles")
    let preview = try #require(
      presetDescendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
    let cpuStyle: NSPopUpButton = try presetControl(root, "CPU menu bar style")
    #expect(presets.selectedSegment == -1 && !cpuStyle.isHiddenOrHasHiddenAncestor)
    #expect(
      (0..<presets.segmentCount).map { presets.label(forSegment: $0) } == [
        "Simple text", "Compact bars", "Separate",
      ])
    var changes: [Settings] = []
    controller.onChange = { changes.append($0) }
    #expect(presets.toolTip?.contains("Separate stacks label + value") == true)
    for (index, styles, size) in [
      (0, Array(repeating: MenuBarStyle.text, count: enabledReadouts.count), MenuBarSize.standard),
      (1, compactStyles, .compact),
      (2, Array(repeating: .stacked, count: enabledReadouts.count), .standard),
    ] {
      presets.selectedSegment = index
      try presetActivate(presets)
      #expect(changes.count == index + 1 && presets.selectedSegment == index)
      let result = try #require(changes.last)
      var expected = settings
      #expect(result.readouts == enabledReadouts)
      expected.separateItems = true
      for (module, style) in zip(expected.readouts, styles) {
        expected.styles[module.rawValue] = style
        expected.appearances[module.rawValue] = .init(size: size, color: .purple)
        let popup: NSPopUpButton = try presetControl(root, "\(module.title) menu bar style")
        let font: NSPopUpButton = try presetControl(root, "\(module.title) menu bar font size")
        #expect(popup.titleOfSelectedItem == style.title && font.titleOfSelectedItem == size.title)
        #expect(font.isEnabled == style.usesFont)
      }
      #expect(result == expected)
      #expect(preview.renderers.count == enabledReadouts.count)
      for (renderer, module) in zip(preview.renderers, expected.readouts) {
        let reading = try #require(renderer.readouts.first)
        #expect(renderer.readouts.count == 1)
        #expect(reading.style == expected.style(for: module))
        #expect(reading.appearance.size == size)
        let expectedReading = MenuBarReadout.make(
          module: module, snapshot: Snapshot(), settings: expected, history: [])
        #expect(reading.value == expectedReading.value)
        #expect(reading.progress == nil)
      }
      // A preset leaves disclosure alone; the next two choices update an already expanded matrix.
      #expect(!cpuStyle.isHiddenOrHasHiddenAncestor)
      #expect(disclosure.isAccessibilityExpanded())
    }
  }
}

@Test @MainActor func menuBarStyleDisclosureHidesTheWholeMatrixWithoutChangingDefaults() throws {
  _ = NSApplication.shared
  let defaults = Settings()
  #expect(defaults.readouts == [.cpu, .memory, .network] && defaults.separateItems)
  #expect(!defaults.weather.enabled)
  let controller = PreferencesController(
    settings: defaults, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let presets: SystemPresetChoices = try presetControl(root, "Menu bar presets")
  let disclosure: NSButton = try presetControl(root, "Customize menu bar readouts and styles")
  let cpu: NSPopUpButton = try presetControl(root, "CPU menu bar style")
  let toggles = presetDescendants(root).compactMap { $0 as? SystemSettingSwitch }
  #expect(toggles.filter { $0.state == .on }.map(\.title) == ["CPU", "Memory", "Network"])
  #expect(!cpu.isHiddenOrHasHiddenAncestor && presets.selectedSegment == 2)
  #expect(disclosure.isAccessibilityExpanded())
  var changes = 0
  controller.onChange = { _ in changes += 1 }
  disclosure.performClick(nil)
  #expect(cpu.isHiddenOrHasHiddenAncestor && !disclosure.isAccessibilityExpanded())
  controller.selectPage(.general)
  controller.selectMenuBarTab()
  #expect(cpu.isHiddenOrHasHiddenAncestor)
  disclosure.performClick(nil)
  #expect(!cpu.isHiddenOrHasHiddenAncestor && disclosure.isAccessibilityExpanded())
  #expect(changes == 0)

}

@Test @MainActor func manualMenuBarEditsClearAndRestoreOnlyMatchingPresetHighlights() throws {
  _ = NSApplication.shared
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let presets: SystemPresetChoices = try presetControl(root, "Menu bar presets")
  let disclosure: NSButton = try presetControl(root, "Customize menu bar readouts and styles")
  disclosure.performClick(nil)
  presets.selectedSegment = 0
  try presetActivate(presets)
  let style: NSPopUpButton = try presetControl(root, "CPU menu bar style")
  style.selectItem(withTitle: MenuBarStyle.icon.title)
  try presetActivate(style)
  #expect(presets.selectedSegment == -1)
  style.selectItem(withTitle: MenuBarStyle.text.title)
  try presetActivate(style)
  #expect(presets.selectedSegment == 0)
  let font: NSPopUpButton = try presetControl(root, "Memory menu bar font size")
  font.selectItem(withTitle: MenuBarSize.large.title)
  try presetActivate(font)
  #expect(presets.selectedSegment == -1)
  font.selectItem(withTitle: MenuBarSize.standard.title)
  try presetActivate(font)
  #expect(presets.selectedSegment == 0)
  let gpu = try #require(
    presetDescendants(root).compactMap { $0 as? SystemSettingSwitch }.first { $0.title == "GPU" })
  gpu.state = .on
  try presetActivate(gpu)
  #expect(presets.selectedSegment == -1)
  gpu.state = .off
  try presetActivate(gpu)
  #expect(presets.selectedSegment == 0)
  var external = Settings()
  external.readouts = [.network]
  controller.updateMenuBarSettings(external)
  #expect(presets.selectedSegment == 2)
  external.appearances[Module.network.rawValue] = .init(size: .large)
  controller.updateMenuBarSettings(external)
  #expect(presets.selectedSegment == -1)
  let networkSize: NSPopUpButton = try presetControl(root, "Network menu bar font size")
  #expect(networkSize.titleOfSelectedItem == MenuBarSize.large.title)
  external.appearances[Module.network.rawValue] = .init(size: .compact)
  external.styles[Module.network.rawValue] = .text
  // Inactive modules do not participate in matching.
  external.styles[Module.cpu.rawValue] = .ring
  controller.updateMenuBarSettings(external)
  #expect(presets.selectedSegment == 1)
  #expect(networkSize.titleOfSelectedItem == MenuBarSize.compact.title)
  let preview = try #require(
    presetDescendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(preview.renderers.first?.readouts.first?.appearance.size == .compact)
}

@Test @MainActor func menuBarPresetsClearReadoutErrorsAndRefreshOpenFormatEditors() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.readouts = [.battery, .clock]
  settings.styles[Module.battery.rawValue] = .value
  settings.styles[Module.clock.rawValue] = .value
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let disclosure: NSButton = try presetControl(root, "Customize menu bar readouts and styles")
  disclosure.performClick(nil)
  for label in ["Battery menu bar formats", "Clock menu bar formats"] {
    let button: NSButton = try presetControl(root, label)
    try presetActivate(button)
  }
  let battery = try #require(
    NSApp.windows.first { $0.title == "Battery Menu Bar Format" && $0.isVisible })
  let clock = try #require(
    NSApp.windows.first { $0.title == "Clock Menu Bar Formats" && $0.isVisible })
  let editors = try [battery, clock].map { window in
    try #require(window.contentView).subviews
      .flatMap { [$0] + presetDescendants($0) }
      .compactMap { $0 as? MenuBarPreviewView }.first
  }
  let previews = try editors.map { try #require($0) }
  #expect(previews.allSatisfy { $0.renderers.first?.readouts.first?.style == .value })
  let activeChecks = presetDescendants(root).compactMap { $0 as? SystemSettingSwitch }.filter {
    [Module.battery.title, Module.clock.title].contains($0.title)
  }
  for check in activeChecks { check.state = .off }
  try presetActivate(try #require(activeChecks.first))
  let helper = try #require(
    presetDescendants(root).compactMap { $0 as? NSTextField }.first {
      $0.stringValue.hasPrefix("Keep at least one readout")
    })
  let presets: SystemPresetChoices = try presetControl(root, "Menu bar presets")
  var result: Settings?
  controller.onChange = { result = $0 }
  for (index, style, size) in [
    (0, MenuBarStyle.text, MenuBarSize.standard),
    (1, .horizontal, .compact),
    (2, .stacked, .standard),
  ] {
    presets.selectedSegment = index
    try presetActivate(presets)
    #expect(result?.readouts == settings.readouts)
    #expect(helper.stringValue.hasPrefix("Each readout opens its own page."))
    #expect(previews[0].renderers.first?.readouts.first?.style == style)
    #expect(previews[1].renderers.first?.readouts.first?.style == (index == 1 ? .text : style))
    #expect(previews.allSatisfy { $0.renderers.first?.readouts.first?.appearance.size == size })
  }
}
