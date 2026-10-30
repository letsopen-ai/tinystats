import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func transparencyViews(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + transparencyViews($0) }
}

@MainActor private func transparencyBitmap(_ view: NSView) throws -> NSBitmapImageRep {
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: view.bounds, to: bitmap)
  }
  return bitmap
}

@Test @MainActor func glassWashAndComposingCardTintsPreserveBothFallbacks() throws {
  for dark in [false, true] {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    #expect(abs(GlassSurface.washOpacity(role: .panel, dark: dark) - (dark ? 0.70 : 0.60)) < 0.001)
    #expect(
      abs(GlassSurface.washOpacity(role: .sidebar, dark: dark) - (dark ? 0.65 : 0.55)) < 0.001)
    #expect(GlassSurface.washOpacity(role: .chips, dark: dark) == 0)
    #expect(abs(GlassSurface.plotFillOpacity(glass: true) - 0.06) < 0.001)
    #expect(abs(GlassSurface.plotFillOpacity(glass: false) - 0.20) < 0.001)
    #expect(abs(GlassSurface.traceWidth(glass: true) - 2) < 0.001)
    #expect(abs(GlassSurface.traceWidth(glass: false) - 1.5) < 0.001)
    for supported in [false, true] {
      for reduced in [false, true] {
        for contrast in [false, true] {
          let environment = GlassSurface.Environment(
            supportsGlass: supported, reduceTransparency: reduced, increaseContrast: contrast)
          appearance.performAsCurrentDrawingAppearance {
            let fill = SystemStyle.cardFill(onGlass: true, environment: environment)
              .usingColorSpace(.sRGB)!
            let normal = SystemStyle.cardFill(onGlass: false, environment: environment)
              .usingColorSpace(.sRGB)!
            switch environment.treatment {
            case .glass:
              #expect(abs(fill.alphaComponent - (dark ? 0.24 : 0.025)) < 0.001)
              #expect(normal == SystemStyle.platterFill.usingColorSpace(.sRGB))
            case .solid:
              #expect(fill == NSColor.controlBackgroundColor.usingColorSpace(.sRGB))
              #expect(fill.alphaComponent == 1)
            case .legacy:
              #expect(fill == SystemStyle.platterFill.usingColorSpace(.sRGB))
              #expect(abs(fill.alphaComponent - (dark ? 0.08 : 0.62)) < 0.001)
            }
          }
        }
      }
    }
  }
}

@Test @MainActor func sensorsGrowRowsFromNaturalFontMetricsAndAlignWindowInkWithTitle() throws {
  for dropdown in [false, true] {
    let table = NSTableView()
    let detail = DetailController(table: table)
    detail.isPopoverPresentation = dropdown
    detail.selected = .sensors
    detail.view.setFrameSize(dropdown ? SystemStyle.popoverSize : MainWindow.minimumSize)
    var snapshot = Snapshot()
    snapshot.sensors = [.init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 52)]
    detail.update(snapshot, history: [])
    for size in [12.0, 28.0] {
      detail.sensorFont = .systemFont(ofSize: size)
      detail.view.layoutSubtreeIfNeeded()
      table.tile()
      let natural = NSTextField(labelWithString: "Hg52")
      natural.font = detail.sensorFont
      #expect(table.rowHeight >= ceil(natural.fittingSize.height) + 9)
      #expect(size == 12 ? abs(table.rowHeight - 25) <= 1 : table.rowHeight > 35)
      let index = try #require(
        (0..<table.numberOfRows).first { detail.tableView(table, shouldSelectRow: $0) })
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.layoutSubtreeIfNeeded()
      let field = try #require(
        table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTextField)
      let cell = try #require(field.cell)
      let title = cell.titleRect(forBounds: field.bounds)
      #expect(abs(title.midY - field.bounds.midY) < 0.01)
      let row = try #require(
        table.rowView(atRow: index, makeIfNecessary: true) as? SensorBrowserRowView)
      #expect(row.selectionRect.contains(row.convert(title, from: field)))
      if !dropdown {
        let title = try #require(
          detail.view.subviews.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "Sensors"
          })
        func inkX(_ field: NSTextField) throws -> CGFloat {
          let bitmap = try transparencyBitmap(field)
          let first = try #require(
            (0..<bitmap.pixelsWide).first { x in
              (0..<bitmap.pixelsHigh).contains { y in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
              }
            })
          return field.convert(
            .init(x: CGFloat(first) * field.bounds.width / CGFloat(bitmap.pixelsWide), y: 0),
            to: detail.view
          ).x
        }
        #expect(abs(try inkX(field) - inkX(title)) <= 0.5)
      }
    }
  }
}

@Test @MainActor func sensorCellInkStartsTwelvePointsInsideBothHostRows() throws {
  for dropdown in [false, true] {
    let field = SensorBrowserTextField(labelWithString: "Hg52")
    field.font = .systemFont(ofSize: 12)
    field.appearance = NSAppearance(named: .aqua)
    field.frame = .init(x: 0, y: 0, width: dropdown ? 178 : 381, height: 25)
    let bitmap = try transparencyBitmap(field)
    let scale = CGFloat(bitmap.pixelsWide) / field.bounds.width
    let columns = (0..<bitmap.pixelsWide).filter { x in
      (0..<bitmap.pixelsHigh).contains { y in
        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
      }
    }
    let first = CGFloat(try #require(columns.first)) / scale
    #expect(abs(first - 12) <= 0.5)
  }
}

@Test @MainActor func appCountsAnchorBesideValuesAndOverviewMemoryCaptionGainsSpace() {
  for width in [300.0, 700.0] {
    let area = NSRect(x: 12, y: 0, width: width, height: 100)
    let valueStart = area.maxX - SummaryDashboardView.rowValueWidth
    let count = SummaryDashboardView.appCountRect(valueStart: valueStart, y: 0)
    #expect(abs(count.maxX + 3 - valueStart) <= 0.01)
    #expect(
      count.width >= ("1234" as NSString).size(withAttributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
      ]).width + 4)
  }
  let rect = NSRect(x: 0, y: 0, width: 324, height: 148)
  let bar = SummaryDashboardView.overviewMemoryBar(in: rect)
  let caption = SummaryDashboardView.overviewMemoryCaption(in: rect)
  #expect(abs(caption.minY - bar.maxY - 6) <= 0.01)
  #expect(caption.maxY < rect.maxY - 34)  // Preserve the existing legend clearance.

}

@Test @MainActor func menuBarShowSwitchesUseNativeDrawingAndInheritHostAppearance() throws {
  for theme in [AppTheme.light, .dark] {
    let detail = DetailController()
    detail.view.appearance = theme.nativeAppearance
    let editor = PreferencesController(
      settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar
    )
    defer {
      editor.disposeEmbedded()
      editor.close()
    }
    detail.showSettingsView(try #require(editor.embeddedView(page: .menuBar)), page: .menuBar)
    let switches = transparencyViews(detail.view).compactMap { $0 as? SystemSettingSwitch }
    #expect(switches.count == 9)
    for control in switches {
      #expect(control.appearance == nil)
      #expect(SystemStyle.isDark(control.effectiveAppearance) == (theme == .dark))
      #expect(control.isEnabled && control.controlSize == .small)
    }
  }
}

@Test @MainActor func sensorTitleKeepsNativeContrastingInkForEmphasizedSelection() throws {
  let field = SensorBrowserTextField(labelWithString: "HHHH")
  field.font = .systemFont(ofSize: 12)
  field.appearance = NSAppearance(named: .aqua)
  field.frame = .init(x: 0, y: 0, width: 180, height: 25)
  let cell = try #require(field.cell)
  for emphasized in [false, true] {
    cell.backgroundStyle = emphasized ? .emphasized : .normal
    let bitmap = try transparencyBitmap(field)
    var inks: [NSColor] = []
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
          color.alphaComponent > 0.5
        {
          inks.append(color)
        }
      }
    }
    let ink = try #require(inks.max { $0.alphaComponent < $1.alphaComponent })
    #expect(emphasized ? ink.redComponent > 0.9 : ink.redComponent < 0.2)
  }
}
