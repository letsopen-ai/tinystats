import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func styleViews(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + styleViews($0) }
}

@Test @MainActor func pictureStylesMatchEveryModulesAvailabilityAndHaveOnlyAccessibleTitles() throws
{
  for sensorKey in ["cpu", "Tp01", "F0Ac", "PSTR"] {
    var settings = Settings()
    settings.sensorKey = sensorKey
    for module in Module.allCases where module != .overview {
      let picker = MenuBarStylePicker(module: module, settings: settings)
      picker.frame.size = .init(width: 640, height: 180)
      picker.layoutSubtreeIfNeeded()
      #expect(picker.isAccessibilityElement() && picker.accessibilityRole() == .radioGroup)
      #expect(picker.accessibilityLabel() == "\(module.title) menu bar style")
      #expect(picker.styles == MenuBarStyle.available(for: module, sensorKey: sensorKey))
      #expect(picker.tiles.map(\.style) == picker.styles)
      for tile in picker.tiles {
        #expect(!tile.isFlipped)
        #expect(tile.accessibilityRole() == .radioButton)
        #expect(tile.accessibilityParent() as? MenuBarStylePicker === picker)
        #expect(tile.accessibilityValue() as? Int == (tile.state == .on ? 1 : 0))
        #expect(tile.title.isEmpty && tile.attributedTitle.string.isEmpty)
        #expect(tile.accessibilityLabel() == tile.style.title)
        #expect(tile.toolTip == tile.style.title)
        #expect(!styleViews(tile).contains { $0 is NSTextField })
        #expect(tile.frame.minX >= 0 && tile.frame.maxX <= picker.bounds.width)
        #expect(tile.frame.height >= 32)
      }
    }
  }
}

@Test @MainActor func pictureTileClicksWriteOnlyStyleAndModuleSelectionDoesNotWriteSettings() throws
{
  var settings = Settings()
  settings.readouts = Module.allCases.filter { $0 != .overview && $0 != .gpu }
  settings.styles[Module.gpu.rawValue] = .ring
  settings.batteryMenu[.charged].style = .pie
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  var saved: [Settings] = []
  controller.onChange = { saved.append($0) }
  for module in settings.readouts {
    controller.selectStyleModule(module)
    root.layoutSubtreeIfNeeded()
    let picker = try #require(
      styleViews(root).compactMap { $0 as? MenuBarStylePicker }.first { $0.module == module })
    #expect(!picker.isHiddenOrHasHiddenAncestor)
    #expect(abs(picker.bounds.width - (picker.superview?.bounds.width ?? 0)) < 1)
    for tile in picker.tiles {
      let before = saved.last ?? settings
      tile.performClick(nil)
      let result = try #require(saved.last)
      #expect(result.style(for: module) == tile.style)
      for other in Module.allCases where other != .overview && other != module {
        #expect(result.style(for: other) == before.style(for: other))
      }
      #expect(result.batteryMenu == settings.batteryMenu)
      #expect(picker.tiles.filter { $0.state == .on }.map(\.style) == [tile.style])
      #expect(
        result.readouts == settings.readouts && !result.weather.enabled && !result.calendarEvents)
    }
    let count = saved.count
    controller.selectStyleModule(.cpu)
    #expect(saved.count == count)
  }
}

@Test @MainActor func picturePreviewsRenderRealInkInBothAppearancesAndInvalidateTheirBoundedCache()
  throws
{
  for theme in [AppTheme.light, .dark] {
    for module in Module.allCases where module != .overview {
      var settings = Settings()
      let picker = MenuBarStylePicker(module: module, settings: settings)
      picker.appearance = theme.nativeAppearance
      for tile in picker.tiles {
        let image = try #require(tile.previewImage())
        #expect(tile.previewImage() === image)
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
          for x in 0..<bitmap.pixelsWide {
            if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
          }
        }
        #expect(ink > 8, "\(module.title) · \(tile.style.title) · \(theme.rawValue)")
        #expect(tile.renderer.readouts.first?.style == tile.style)
        #expect(tile.renderer.readouts.first?.module == module)
      }
      let first = try #require(picker.tiles.first)
      let before = try #require(first.previewImage())
      settings.appearances[module.rawValue] = .init(size: .large)
      picker.update(settings: settings)
      #expect(first.cachedPreview == nil)
      #expect(first.renderer.readouts.first?.appearance.size == .large)
      #expect(first.previewImage() !== before)
      let resized = first.cachedPreview
      picker.appearance = (theme == .light ? AppTheme.dark : .light).nativeAppearance
      #expect(first.cachedPreview == nil)
      #expect(first.previewImage() !== resized)
      NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
      #expect(first.cachedPreview == nil)
    }
  }
}

@Test @MainActor func pictureTileKeyboardMovesFocusAndSpaceSelectsWithoutTouchingTheRealMenuBar()
  throws
{
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let window = try #require(controller.window)
  let root = try #require(window.contentView)
  root.layoutSubtreeIfNeeded()
  let picker = try #require(
    styleViews(root).compactMap { $0 as? MenuBarStylePicker }.first { $0.module == .cpu })
  let first = try #require(picker.tiles.first)
  #expect(picker.tiles.filter(\.canBecomeKeyView).count == 1)
  #expect(window.makeFirstResponder(first))
  func key(_ code: UInt16) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: code == 49 ? " " : "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  var result: Settings?
  controller.onChange = { result = $0 }
  first.keyDown(with: try key(124))
  #expect(window.firstResponder === picker.tiles[1])
  picker.tiles[1].keyDown(with: try key(49))
  #expect(result?.style(for: .cpu) == picker.tiles[1].style)
  #expect(picker.tiles.filter(\.canBecomeKeyView) == [picker.tiles[1]])
  picker.tiles[1].keyDown(with: try key(125))
  let focused = try #require(window.firstResponder as? MenuBarStyleTile)
  #expect(focused.frame.minY > picker.tiles[1].frame.minY)
}

@Test @MainActor func batteryStateEditorsUsePictureTilesForEveryAvailableStyle() throws {
  var settings = Settings()
  settings.batteryMenu.customizeStates = true
  let controller = BatteryMenuController(settings: settings, snapshot: Snapshot(), history: [])
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  let pickers = styleViews(root).compactMap { $0 as? MenuBarStylePicker }
  #expect(pickers.count == BatteryMenuState.allCases.count)
  for picker in pickers {
    #expect(picker.styles == MenuBarStyle.available(for: .battery))
    #expect(
      picker.tiles.allSatisfy { $0.title.isEmpty && $0.accessibilityLabel() == $0.style.title })
  }
}

@Test @MainActor func moduleToolsAppearOnlyAfterTheirOwnTilesAndCPUEndsAtTheGrid() throws {
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  for module in [Module.cpu, .memory, .battery, .clock, .sensors, .cpu] {
    controller.selectStyleModule(module)
    root.layoutSubtreeIfNeeded()
    let views = styleViews(root)
    let picker = try #require(
      views.compactMap { $0 as? MenuBarStylePicker }.first { $0.module == module })
    let editor = try #require(picker.superview as? NSStackView)
    let options = try #require(editor.superview)
    #expect(abs(picker.bounds.width - options.bounds.width) < 1)
    let tools = views.filter {
      $0.identifier?.rawValue.hasPrefix("menu-bar-") == true
        && $0.identifier?.rawValue.hasSuffix("-tools") == true && !$0.isHiddenOrHasHiddenAncestor
    }
    if module == .cpu || module == .memory {
      #expect(tools.isEmpty && editor.arrangedSubviews.last === picker)
      let document = try #require(options.enclosingScrollView?.documentView)
      let bottom = picker.convert(picker.bounds, to: document).maxY
      #expect(
        document.bounds.height - bottom <= PreferencesController.menuBarCPUBottomChromeBudget + 0.5)
      #expect(options.bounds.height <= PreferencesController.menuBarCPUOptionsHeightBudget)
    } else {
      #expect(tools.count == 1)
      let tool = try #require(tools.first)
      #expect(editor.arrangedSubviews.last === tool)
      #expect(tool.bounds.height <= PreferencesController.menuBarToolsHeightBudget)
      if module == .sensors {
        let label = try #require(
          styleViews(tool).compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "Menu bar sensor"
          })
        #expect(label.bounds.width >= label.intrinsicContentSize.width - 1)
      }
    }
  }
}

@Test @MainActor func chipsSelectEditorsByClickFocusAndVoiceOverWithoutChangingMembership() throws {
  var settings = Settings()
  settings.readouts = [.network, .cpu]
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let window = try #require(controller.window)
  let root = try #require(window.contentView)
  let tray = try #require(styleViews(root).compactMap { $0 as? MenuBarCustomization }.first)
  #expect(controller.selectedStyleModule == .network && tray.selectedModule == .network)
  #expect(!styleViews(root).contains { $0.accessibilityLabel() == "Readout to customize" })
  var writes = 0
  controller.onChange = { _ in writes += 1 }
  for module in [Module.cpu, .memory, .battery, .network] {
    let chip = try #require(tray.chips[module])
    chip.performClick(nil)
    #expect(controller.selectedStyleModule == module && chip.isAccessibilitySelected())
    #expect(tray.chips.values.filter { $0.isAccessibilitySelected() }.count == 1)
    #expect(window.makeFirstResponder(chip))
    #expect(controller.selectedStyleModule == module)
    #expect(chip.accessibilityPerformPress())
    #expect(tray.order == settings.readouts && writes == 0)
  }
}

@Test @MainActor func unchangedSelectionDoesNotRedrawAndZeroWidthKeepsInitialHeight() throws {
  let picker = MenuBarStylePicker(module: .cpu, settings: Settings())
  let height = picker.fittingSize.height
  picker.layoutSubtreeIfNeeded()
  #expect(picker.fittingSize.height == height)
  for tile in picker.tiles { tile.needsDisplay = false }
  picker.update(settings: Settings())
  #expect(picker.tiles.allSatisfy { !$0.needsDisplay })
  let tile = try #require(picker.tiles.first)
  let image = try #require(tile.previewImage())
  let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
  #expect(bitmap.pixelsHigh == 48)
  tile.viewDidChangeBackingProperties()
  #expect(tile.cachedPreview == nil)
  picker.toolTip = "Per-state styles"
  #expect(picker.tiles.allSatisfy { $0.toolTip?.contains("Per-state styles") == true })
  picker.toolTip = nil
  #expect(picker.tiles.allSatisfy { $0.toolTip == $0.style.title })
}

@Test @MainActor func electricalSensorExamplesKeepTheirRealUnits() {
  for (key, value) in [("VC0C", "1.2V"), ("IC0C", "2.4A"), ("PSTR", "6.8W")] {
    var settings = Settings()
    settings.sensorKey = key
    #expect(
      MenuBarStyleExample.readout(module: .sensors, style: .value, settings: settings).value
        == value)
  }
}

@Test @MainActor func clockPictureUsesRealSingleLineFallbackAndFitsLongConfiguredLiterals() throws {
  var settings = Settings()
  settings.clockMenu.custom = true
  settings.clockMenu.entries = [
    .init(
      name: "Example", zone: "UTC", firstLine: String(repeating: "Clock ", count: 12),
      secondLine: "")
  ]
  let picker = MenuBarStylePicker(module: .clock, settings: settings)
  picker.frame.size = .init(width: 320, height: 200)
  picker.layoutSubtreeIfNeeded()
  for tile in picker.tiles {
    #expect(tile.frame.width <= 320 && tile.frame.maxX <= 320)
    var candidate = settings
    candidate.styles[Module.clock.rawValue] = tile.style
    let actual = MenuBarReadout.make(
      module: .clock, snapshot: Snapshot(), settings: candidate, history: [],
      clockDate: Date(timeIntervalSince1970: 1_700_000_000))
    let example = try #require(tile.renderer.readouts.first)
    #expect(
      example.style == actual.style && example.label == actual.label
        && example.value == actual.value)
    #expect(tile.previewImage() != nil)
  }
  let stacked = try #require(picker.tiles.first { $0.style == .stacked })
  #expect(stacked.renderer.readouts.first?.style == .value)
}

@Test @MainActor func pictureSelectionReusesImagesAndAccessibilityNotificationsInvalidateThem()
  throws
{
  var settings = Settings()
  let picker = MenuBarStylePicker(module: .cpu, settings: settings)
  let tile = try #require(picker.tiles.first)
  let image = try #require(tile.previewImage())
  settings.styles[Module.cpu.rawValue] = .ring
  picker.update(settings: settings)
  #expect(picker.selectedStyle == .ring && tile.previewImage() === image)
  NSWorkspace.shared.notificationCenter.post(
    name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  #expect(tile.cachedPreview == nil)
}

@Test @MainActor func pictureGridBalancesEqualColumnsWithoutOrphanRows() {
  for width: CGFloat in [328, 426, 640, 788] {
    let picker = MenuBarStylePicker(module: .cpu, settings: Settings())
    picker.frame.size = .init(width: width, height: 200)
    picker.layoutSubtreeIfNeeded()
    let rows = Dictionary(grouping: picker.tiles, by: { $0.frame.minY })
    #expect(rows.values.allSatisfy { $0.count >= 2 })
    #expect(Set(picker.tiles.map { $0.frame.width }).count == 1)
  }
}
