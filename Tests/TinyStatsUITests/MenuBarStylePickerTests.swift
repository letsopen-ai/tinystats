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
      #expect(picker.styles == MenuBarStyle.available(for: module, sensorKey: sensorKey))
      #expect(picker.tiles.map(\.style) == picker.styles)
      for tile in picker.tiles {
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
  settings.readouts = Module.allCases.filter { $0 != .overview }
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
    for tile in picker.tiles {
      tile.performClick(nil)
      let result = try #require(saved.last)
      #expect(result.style(for: module) == tile.style)
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

@Test @MainActor func menuBarBottomFormatToolsFitOneRowWithin36PointBudget() throws {
  let old = SystemSettingsForm.group([
    SystemSettingsForm.row(
      "Battery", NSButton(title: "Battery formats…", target: nil, action: nil)),
    SystemSettingsForm.row("Time", NSButton(title: "Clock formats…", target: nil, action: nil)),
  ])
  let host = NSView(frame: .init(x: 0, y: 0, width: 640, height: 200))
  host.addSubview(old)
  old.translatesAutoresizingMaskIntoConstraints = false
  old.widthAnchor.constraint(equalToConstant: 640).isActive = true
  host.layoutSubtreeIfNeeded()
  #expect(old.fittingSize.height == 72)
  let controller = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let root = try #require(controller.window?.contentView)
  root.layoutSubtreeIfNeeded()
  let tools = try #require(
    styleViews(root).first { $0.identifier?.rawValue == "menu-bar-format-tools" })
  #expect(
    tools.bounds.height == 36
      && tools.bounds.height <= PreferencesController.menuBarToolsHeightBudget)
  let buttons = styleViews(tools).compactMap { $0 as? NSButton }
  #expect(buttons.count == 2 && buttons.allSatisfy { $0.isEnabled && $0.frame.height >= 20 })
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
