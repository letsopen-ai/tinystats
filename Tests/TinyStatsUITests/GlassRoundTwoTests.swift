import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func legacySidebarEmptyMaterialPassesThroughButButtonsReceiveHits() throws {
  let navigation = DetailNavigationCoordinator(environment: {
    .init(supportsGlass: false, reduceTransparency: false, increaseContrast: false)
  })
  navigation.layout(in: .init(origin: .zero, size: MainWindow.minimumSize))
  let surface = navigation.sidebarMaterial
  let effect = try #require(surface.legacyContentView)
  let button = try #require(effect.subviews.compactMap { $0 as? NSButton }.first)
  #expect(surface.hitTest(.init(x: 4, y: 4)) == nil)
  #expect(surface.hitTest(.init(x: button.frame.midX, y: button.frame.midY)) === button)
}

@Test @MainActor func sensorDefaultFallsBackToAvailableUnnamedIdentityWithoutChangingPriority() {
  let unknown = SensorReading(key: "IX00", name: "Unknown current", kind: .current, value: -0.5)
  var snapshot = Snapshot()
  snapshot.sensors = [unknown]
  func build(_ query: String = "") -> SensorBrowserPresentation.Presentation {
    SensorBrowserPresentation.build(
      snapshot: snapshot, timeline: SensorTimeline(), settings: Settings(), query: query,
      showsAll: false, selection: nil)
  }
  #expect(build().selection == .reading("IX00"))
  #expect(build().available && build().value == "-0.50 A")
  snapshot.sensors.append(.init(key: "TA0P", name: "Ambient", kind: .temperature, value: 20))
  #expect(build().selection == .reading("TA0P"))
  #expect(build("IX00").selection == .reading("IX00"))
  snapshot.sensors = [unknown, .init(key: "IX01", name: "Other current", kind: .current, value: 0)]
  #expect(build().selection == .reading("IX00") && build().available)
  #expect(build("nothing").selection == nil)
  snapshot.sensors = []
  #expect(build().selection == nil && !build().available)
}

@Test @MainActor func allSidebarControlsFitActualMinimumWindowInEveryTreatment() throws {
  let window = MainWindow()
  defer { window.close() }
  #expect(window.contentMinSize == MainWindow.minimumSize)
  for supported in [false, true] {
    for solid in [false, true] {
      let navigation = DetailNavigationCoordinator(environment: {
        .init(supportsGlass: supported, reduceTransparency: solid, increaseContrast: false)
      })
      navigation.layout(in: .init(origin: .zero, size: window.contentMinSize))
      let host = navigation.sidebarMaterial.legacyContentView ?? navigation.sidebar
      let controls = host.subviews.filter { $0 is NSButton || $0 is NSTextField }
      #expect(controls.count == 15)
      for control in controls {
        #expect(navigation.sidebar.bounds.insetBy(dx: 0, dy: 8).contains(control.frame))
      }
      let ordered = controls.sorted { $0.frame.minY < $1.frame.minY }
      for pair in zip(ordered, ordered.dropFirst()) {
        #expect(pair.0.frame.maxY <= pair.1.frame.minY)
      }
    }
  }
}

@Test @MainActor func chipGlassStartsAtConvertedOldFrameWhenMovingBetweenAreas() async throws {
  guard #available(macOS 26, *) else { return }
  let editor = MenuBarCustomization(frame: .init(x: 0, y: 0, width: 620, height: 280))
  editor.update(order: [.cpu, .memory, .network])
  editor.layoutSubtreeIfNeeded()
  let chip = try #require(editor.chips[.memory])
  for order in [[Module.cpu, .network], [.cpu, .memory, .network]] {
    let oldFrame = chip.convert(chip.bounds, to: editor)
    editor.update(order: order, animated: true)
    let area = try #require(chip.superview as? MenuBarDropArea)
    let container = try #require(area.glass.subviews.first as? NSGlassEffectContainerView)
    let shape = try #require(
      container.contentView?.subviews.first {
        $0.identifier?.rawValue == Module.memory.rawValue
      })
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      #expect(area.convert(shape.frame, to: editor) == oldFrame)
      #expect(shape.frame == chip.frame)
    }
    try await Task.sleep(for: .milliseconds(220))
    #expect(shape.frame == chip.frame)
    let other = area === editor.strip ? editor.palette : editor.strip
    let otherContainer = try #require(other.glass.subviews.first as? NSGlassEffectContainerView)
    #expect(
      otherContainer.contentView?.subviews.contains {
        $0.identifier?.rawValue == Module.memory.rawValue
      } == false)
  }
}

@MainActor private func roundTwoBitmap(_ view: NSView) throws -> NSBitmapImageRep {
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: view.bounds, to: bitmap)
  }
  return bitmap
}

@MainActor private func roundTwoColor(_ color: NSColor, in appearance: NSAppearance) throws
  -> NSColor
{
  var resolved: NSColor?
  appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
  return try #require(resolved)
}

@Test @MainActor func solidAndIncreaseContrastSidebarDrawDistinctFillAndRimInBothAppearances()
  throws
{
  for contrast in [false, true] {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let surface = GlassSurface(
        role: .sidebar,
        environment: {
          .init(supportsGlass: true, reduceTransparency: !contrast, increaseContrast: contrast)
        })
      surface.frame = .init(x: 0, y: 0, width: 132, height: 644)
      surface.appearance = NSAppearance(named: name)
      let bitmap = try roundTwoBitmap(surface)
      let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
      func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
        try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
      }
      let fill = try pixel(66, 322)
      let rim = try pixel(0.5, 322)
      let expected = try roundTwoColor(.controlBackgroundColor, in: surface.effectiveAppearance)
      #expect(surface.treatment == .solid && surface.subviews.isEmpty)
      #expect(try pixel(0, 0).alphaComponent == 0)
      #expect(fill.alphaComponent == 1 && rim.alphaComponent == 1)
      for component in [0, 1, 2] {
        #expect(abs(fill.component(component) - expected.component(component)) < 0.02)
      }
      let separator = try roundTwoColor(.separatorColor, in: surface.effectiveAppearance)
      for component in [0, 1, 2] {
        let composite =
          separator.component(component) * separator.alphaComponent
          + fill.component(component) * (1 - separator.alphaComponent)
        #expect(abs(rim.component(component) - composite) < 0.04)
      }
      #expect((0..<3).contains { abs(rim.component($0) - fill.component($0)) > 0.02 })
    }
  }
}

extension NSColor {
  fileprivate func component(_ index: Int) -> CGFloat {
    [redComponent, greenComponent, blueComponent][index]
  }
}

@Test @MainActor func modernSidebarSelectionUsesReadableNativeAccentFillInBothAppearances() throws {
  let navigation = DetailNavigationCoordinator(environment: {
    .init(supportsGlass: true, reduceTransparency: false, increaseContrast: false)
  })
  navigation.updateSelection(.overview)
  let button = try #require(
    navigation.sidebar.subviews.compactMap { $0 as? NavigationButton }
      .first { $0.title == "Overview" })
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    button.appearance = NSAppearance(named: name)
    let bitmap = try roundTwoBitmap(button)
    let scale = CGFloat(bitmap.pixelsWide) / button.bounds.width
    let fill = try #require(
      bitmap.colorAt(x: Int(108 * scale), y: Int(15 * scale))?.usingColorSpace(.sRGB))
    let expected = try roundTwoColor(
      .selectedContentBackgroundColor, in: button.effectiveAppearance)
    #expect(fill.alphaComponent == 1)
    for component in [0, 1, 2] {
      #expect(abs(fill.component(component) - expected.component(component)) < 0.02)
    }
    // The selected title/icon uses the native contrasting ink, not accent over accent.
    let ink = try roundTwoColor(.alternateSelectedControlTextColor, in: button.effectiveAppearance)
    func luminance(_ color: NSColor) -> Double {
      let channels = (0..<3).map { Double(color.component($0)) }.map {
        $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
      }
      return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
    let values = [luminance(fill), luminance(ink)]
    #expect((values.max()! + 0.05) / (values.min()! + 0.05) >= 3)
  }
}

@Test @MainActor
func sensorsKeepNativeSearchKeyboardEligibilityAndRoundedSelectionAcrossNavigation() throws {
  let table = NSTableView()
  let detail = DetailController(table: table)
  detail.isPopoverPresentation = true
  detail.loadViewIfNeeded()
  detail.selected = .sensors
  detail.view.layoutSubtreeIfNeeded()
  #expect(table.style == .plain)
  #expect(detail.tableView(table, rowViewForRow: 0) is SensorBrowserRowView)
  func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
  let search = try #require(descendants(detail.view).compactMap { $0 as? NSSearchField }.first)
  let platter = try #require(
    detail.view.subviews.compactMap { $0 as? PlatterView }.first { !$0.isHidden })
  #expect(search.frame.minX == platter.frame.minX && search.frame.width == platter.frame.width)
  let field = try #require(search as? SensorSearchField)
  #expect(field.usesNeutralFill && search.delegate === detail)
  #expect(search.isEditable && search.isSelectable && search.acceptsFirstResponder)
  #expect(search.placeholderString == "Search sensors or SMC keys")
  detail.selected = .cpu
  #expect(table.style == .plain)
  detail.selected = .sensors
  #expect(table.style == .plain)
  #expect(detail.tableView(table, rowViewForRow: 0) is SensorBrowserRowView)
  detail.isPopoverPresentation = false
  #expect(table.style == .automatic && !field.usesNeutralFill)
}

@Test @MainActor func sensorSelectionHasRoundedInsetCornersInBothAppearances() throws {
  let row = SensorBrowserRowView(frame: .init(x: 0, y: 0, width: 300, height: 25))
  row.isSelected = true
  row.selectionHighlightStyle = .regular
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    row.appearance = NSAppearance(named: name)
    for emphasized in [false, true] {
      row.isEmphasized = emphasized
      let bitmap = try roundTwoBitmap(row)
      let scale = CGFloat(bitmap.pixelsWide) / row.bounds.width
      func alpha(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
        try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))).alphaComponent
      }
      #expect(try alpha(150, 12) == 1)
      #expect(try alpha(1, 12) == 0)
      #expect(try alpha(4, 1) == 0)
      #expect(try alpha(150, 0) == 0)
    }
  }
}
