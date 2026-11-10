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
      let advanced = try #require(
        controls.compactMap { $0 as? NSTextField }.first {
          $0.stringValue == "Advanced"
        })
      let weather = try #require(
        controls.compactMap { $0 as? NSButton }.first { $0.title == "Weather" })
      #expect(weather.frame.minY - advanced.frame.maxY == 16)
      let sensors = try #require(
        controls.compactMap { $0 as? NSButton }.first { $0.title == "Sensors" })
      #expect(advanced.frame.minY - sensors.frame.maxY == 6)
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

@Test @MainActor func solidAndIncreaseContrastSidebarFillEveryEdgeWithoutACardRimInBothAppearances()
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
      let expected = try roundTwoColor(.controlBackgroundColor, in: surface.effectiveAppearance)
      #expect(surface.treatment == .solid && surface.subviews.isEmpty)
      for point in [
        NSPoint(x: 0, y: 0), .init(x: 131, y: 0), .init(x: 0, y: 643),
        .init(x: 131, y: 643), .init(x: 66, y: 322),
      ] {
        let fill = try pixel(point.x, point.y)
        #expect(fill.alphaComponent == 1)
        for component in [0, 1, 2] {
          #expect(abs(fill.component(component) - expected.component(component)) < 0.02)
        }
      }
    }
  }
}

extension NSColor {
  fileprivate func component(_ index: Int) -> CGFloat {
    [redComponent, greenComponent, blueComponent][index]
  }
}

@Test @MainActor func modernSidebarSelectionUsesNeutralFillAndModuleGlyphsInBothAppearances() throws
{
  let navigation = DetailNavigationCoordinator(environment: {
    .init(supportsGlass: true, reduceTransparency: false, increaseContrast: false)
  })
  navigation.updateSelection(.cpu)
  let button = try #require(
    navigation.sidebar.subviews.compactMap { $0 as? NavigationButton }
      .first { $0.module == .cpu })
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    button.appearance = NSAppearance(named: name)
    let bitmap = try roundTwoBitmap(button)
    let scale = CGFloat(bitmap.pixelsWide) / button.bounds.width
    let fill = try #require(
      bitmap.colorAt(x: Int(108 * scale), y: Int(15 * scale))?.usingColorSpace(.sRGB))
    let expected = try roundTwoColor(
      .labelColor, in: button.effectiveAppearance)
    #expect(abs(fill.alphaComponent - 0.10) < 0.01)
    for component in [0, 1, 2] {
      #expect(abs(fill.component(component) - expected.component(component)) < 0.02)
    }
    // Selection is neutral so the fixed module identity glyph remains readable.
    #expect(button.module == .cpu)
    let ink = try roundTwoColor(SystemStyle.moduleAccent(.cpu), in: button.effectiveAppearance)
    let background = try roundTwoColor(.windowBackgroundColor, in: button.effectiveAppearance)
    let composite = NSColor(
      srgbRed: fill.redComponent * 0.1 + background.redComponent * 0.9,
      green: fill.greenComponent * 0.1 + background.greenComponent * 0.9,
      blue: fill.blueComponent * 0.1 + background.blueComponent * 0.9, alpha: 1)
    func luminance(_ color: NSColor) -> Double {
      let channels = (0..<3).map { Double(color.component($0)) }.map {
        $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
      }
      return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
    let values = [luminance(composite), luminance(ink)]
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
  #expect(table.style == .plain && !field.usesNeutralFill)
  detail.selected = .cpu
  #expect(table.style == .automatic)
  detail.selected = .sensors
  #expect(table.style == .plain)
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

@Test @MainActor func sensorSelectionContainsAndCentersRealizedTextCells() throws {
  let environments = [
    GlassSurface.Environment(
      supportsGlass: true, reduceTransparency: false, increaseContrast: false),
    .init(supportsGlass: true, reduceTransparency: true, increaseContrast: false),
    .init(supportsGlass: true, reduceTransparency: false, increaseContrast: true),
    .init(supportsGlass: false, reduceTransparency: false, increaseContrast: false),
  ]
  for environment in environments {
    for theme in [AppTheme.light, .dark] {
      for dropdown in [true, false] {
        let table = NSTableView()
        let detail = DetailController(table: table)
        detail.glassEnvironment = { environment }
        detail.isPopoverPresentation = dropdown
        detail.selected = .sensors
        detail.view.appearance = theme.nativeAppearance
        detail.view.setFrameSize(dropdown ? SystemStyle.popoverSize : MainWindow.minimumSize)
        var snapshot = Snapshot()
        snapshot.sensors = [
          .init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 45),
          .init(key: "F0Ac", name: "Fan", kind: .fan, value: 1200),
        ]
        detail.update(snapshot, history: [])
        for all in [false, true] {
          detail.showsAllReadings = all
          detail.view.layoutSubtreeIfNeeded()
          table.layoutSubtreeIfNeeded()
          // Exercise both the initial highlight and a later row, including row reuse.
          let indices = (0..<table.numberOfRows).filter {
            detail.tableView(table, shouldSelectRow: $0)
          }
          #expect(!indices.isEmpty)
          for index in indices {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.layoutSubtreeIfNeeded()
            let row = try #require(
              table.rowView(atRow: index, makeIfNecessary: true) as? SensorBrowserRowView)
            row.layoutSubtreeIfNeeded()
            func assertTextGeometry() throws {
              let selection = row.selectionRect
              #expect(row.isSelected)
              #expect(abs(selection.minX - row.bounds.minX - 4) <= 0.01)
              #expect(abs(row.bounds.maxX - selection.maxX - 4) <= 0.01)
              #expect(selection.minY >= row.bounds.minY && selection.maxY <= row.bounds.maxY)
              for column in 0..<table.numberOfColumns {
                let field = try #require(
                  table.view(atColumn: column, row: index, makeIfNecessary: true) as? NSTextField)
                let cell = try #require(field.cell)
                let text = row.convert(cell.titleRect(forBounds: field.bounds), from: field)
                #expect(selection.contains(text))
                #expect(abs(selection.midY - text.midY) <= 0.5)
                #expect(abs(text.height - field.fittingSize.height) <= 0.5)
                let ink = row.convert(try sensorInkBounds(field), from: field)
                let inset = column == 0 ? ink.minX - selection.minX : selection.maxX - ink.maxX
                #expect(abs(inset - 8) <= (column == 0 ? 0.75 : 0.5))
              }
              if dropdown {
                let highlight = row.convert(selection, to: detail.view)
                let card = try #require(
                  detail.view.subviews.compactMap { $0 as? PlatterView }.first {
                    !$0.isHidden && $0.frame.contains(highlight)
                  })
                #expect(abs(highlight.minX - card.frame.minX - 4) <= 0.5)
                #expect(abs(card.frame.maxX - highlight.maxX - 4) <= 0.5)
              }
            }
            try assertTextGeometry()
            // A live tick replaces cells without changing row width or requesting row layout.
            table.reloadData(
              forRowIndexes: IndexSet(integer: index),
              columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            try assertTextGeometry()
            let width = row.frame.width
            let first = try #require(table.tableColumns.first)
            let last = try #require(table.tableColumns.last)
            first.width += 16
            last.width -= 16
            table.tile()
            #expect(abs(row.frame.width - width) <= 0.01)
            try assertTextGeometry()
          }
        }
      }
    }
  }
}

@Test @MainActor func sensorTextInkCentersInAppKitFramesWithoutClampingLargerFonts() throws {
  let field = SensorBrowserTextField(labelWithString: "Hg52")
  field.appearance = NSAppearance(named: .aqua)
  for size in [12.0, 22.0] {
    field.font = .systemFont(ofSize: size)
    let naturalHeight = field.fittingSize.height
    let cell = try #require(field.cell)
    let short = NSRect(x: 0, y: 0, width: 180, height: 25)
    let text = cell.titleRect(forBounds: short)
    #expect(abs(text.height - naturalHeight) <= 1)
    #expect(abs(text.midY - short.midY) <= 0.01)
    var inkCenters: [CGFloat] = []
    var inkHeights: [CGFloat] = []
    for extra in [8.0, 28.0] {
      // Simulate AppKit assigning the complete cell frame; no row layout participates.
      field.frame = .init(x: 0, y: 0, width: 180, height: naturalHeight + extra)
      let bitmap = try roundTwoBitmap(field)
      let scale = CGFloat(bitmap.pixelsHigh) / field.bounds.height
      let inkRows = (0..<bitmap.pixelsHigh).filter { y in
        (0..<bitmap.pixelsWide).contains { x in
          (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
        }
      }
      let first = try #require(inkRows.first)
      let last = try #require(inkRows.last)
      inkCenters.append(CGFloat(first + last + 1) / (2 * scale))
      inkHeights.append(CGFloat(last - first + 1) / scale)
    }
    #expect(abs(inkCenters[1] - inkCenters[0] - 10) <= 0.5)
    #expect(abs(inkHeights[0] - inkHeights[1]) <= 0.01)
  }
}
