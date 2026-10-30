import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

/// Render at actual small-marker sizes, without depending on font glyphs or hue.
@MainActor private func legendBitmap(
  appearance: NSAppearance.Name, scale: Int, size: NSSize = .init(width: 16, height: 16),
  flipped: Bool = false, draw: () -> Void
) throws -> NSBitmapImageRep {
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
      pixelsHigh: Int(size.height) * scale,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: flipped)
  context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  if flipped {
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
  }
  try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
    NSColor.windowBackgroundColor.setFill()
    NSRect(origin: .zero, size: size).fill()
    draw()
  }
  return bitmap
}

@MainActor private func brightness(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
  let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.genericGray))
  return color.whiteComponent
}

@MainActor private func legendMask(
  _ bitmap: NSBitmapImageRep, rect: NSRect, scale: Int
) throws -> [Bool] {
  let background = try brightness(bitmap, x: 0, y: 0)
  return try (Int(rect.minY) * scale..<Int(rect.maxY) * scale).flatMap { y in
    try (Int(rect.minX) * scale..<Int(rect.maxX) * scale).map { x in
      abs(try brightness(bitmap, x: x, y: y) - background) > 0.1
    }
  }
}

@MainActor private func legendColorDistance(_ first: NSColor, _ second: NSColor) throws -> CGFloat {
  let first = try #require(first.usingColorSpace(.deviceRGB))
  let second = try #require(second.usingColorSpace(.deviceRGB))
  return max(
    abs(first.redComponent - second.redComponent),
    abs(first.greenComponent - second.greenComponent),
    abs(first.blueComponent - second.blueComponent))
}

@MainActor private func legendPixel(_ bitmap: NSBitmapImageRep, at point: NSPoint) throws -> NSColor
{
  // Rendered view coordinates and bitmap rows both start at the top.
  try #require(bitmap.colorAt(x: Int(point.x), y: Int(point.y)))
}

@Test @MainActor func seriesLegendMarkersRemainDistinctWithoutHueInLightAndDark() throws {
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for scale in [1, 2] {
      let rect = NSRect(x: 4, y: 4, width: 7, height: 7)
      let filled = try legendBitmap(appearance: appearance, scale: scale) {
        SummaryDashboardView.SeriesLegendMarker.first.draw(in: rect, color: .labelColor)
      }
      let hollow = try legendBitmap(appearance: appearance, scale: scale) {
        SummaryDashboardView.SeriesLegendMarker.second.draw(in: rect, color: .labelColor)
      }
      let background = try brightness(hollow, x: 0, y: 0)
      let firstCenter = try brightness(filled, x: 7 * scale, y: 7 * scale)
      let secondCenter = try brightness(hollow, x: 7 * scale, y: 7 * scale)
      let secondEdge = try brightness(hollow, x: 4 * scale, y: 7 * scale)
      #expect(abs(firstCenter - background) > 0.5)
      #expect(abs(secondCenter - background) < 0.05)
      #expect(abs(secondEdge - background) > 0.3)
    }
  }
}

@Test @MainActor func coreMarkersKeepDistinctOvalRectangleAndDiamondSilhouettes() throws {
  let view = SummaryDashboardView(frame: .zero)
  #expect(CPUCoreKind.allCases.map(\.chartTitle) == ["Efficiency", "Performance", "Unclassified"])
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    let bitmaps = try CPUCoreKind.allCases.map { kind in
      try legendBitmap(appearance: appearance, scale: 2) {
        view.drawCoreMarker(kind, rect: .init(x: 4, y: 4, width: 7, height: 7))
      }
    }
    // Compare silhouettes rather than colored pixels: three distinct occupancy masks.
    let masks = try bitmaps.map { bitmap in
      let background = try brightness(bitmap, x: 0, y: 0)
      return try (0..<32).flatMap { y in
        try (0..<32).map { x in
          abs(try brightness(bitmap, x: x, y: y) - background) > 0.1
        }
      }
    }
    #expect(masks[0] != masks[1] && masks[1] != masks[2] && masks[0] != masks[2])
  }
}

@Test @MainActor func drawCoresKeepsClassifiedLegendsAndOmitsTheUnclassifiedCaption() throws {
  let view = SummaryDashboardView(frame: .zero)
  let cpu = CPUReading(
    usage: 30, cores: [12, 48, nil], load: [],
    coreKinds: [.efficiency, .performance, .unknown])
  let area = NSRect(x: 12, y: 12, width: 480, height: 80)
  let size = NSSize(width: 504, height: 104)
  let titles = ["Efficiency", "Performance"]
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for scale in [1, 2] {
      let actual = try legendBitmap(
        appearance: appearance, scale: scale, size: size, flipped: true
      ) {
        view.drawCores(cpu, in: area)
      }
      let expected = try legendBitmap(
        appearance: appearance, scale: scale, size: size, flipped: true
      ) {
        for (index, kind) in [CPUCoreKind.efficiency, .performance].enumerated() {
          let x = area.minX + CGFloat(index) * 240
          view.drawCoreMarker(kind, rect: .init(x: x, y: area.maxY - 9, width: 7, height: 7))
          view.text(
            titles[index] + " " + Display.percent(cpu.cores[index]),
            rect: .init(x: x + 12, y: area.maxY - 12, width: 226, height: 14),
            color: .labelColor, size: 10)
        }
      }
      for index in titles.indices {
        let x = area.minX + CGFloat(index) * 240
        for rect in [
          NSRect(x: x, y: area.maxY - 9, width: 7, height: 7),
          NSRect(x: x + 12, y: area.maxY - 12, width: 226, height: 14),
        ] {
          let mask = try legendMask(actual, rect: rect, scale: scale)
          #expect(mask.contains(true))
          #expect(mask == (try legendMask(expected, rect: rect, scale: scale)))
        }
      }
    }
  }
}

@Test @MainActor func narrowRightAlignedSeriesLegendOmitsMarkerAndLabelTogether() throws {
  let view = SummaryDashboardView(frame: .zero)
  let rect = NSRect(x: 4, y: 0, width: 10, height: 14)
  let bitmap = try legendBitmap(appearance: .aqua, scale: 2) {
    view.drawSeriesLegend(
      "System", marker: .second, color: .systemPink, rect: rect, size: 10, alignment: .right)
  }
  #expect(
    !(try legendMask(bitmap, rect: .init(x: 0, y: 0, width: 16, height: 16), scale: 2))
      .contains(true))
}

@Test @MainActor func pairedSummaryAndHistoryCardsSpeakBothSeriesIncludingUnavailable() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  for available in [false, true] {
    var snapshot = Snapshot()
    snapshot.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    snapshot.cpu = .init(
      usage: available ? 50 : nil, cores: [0, 25, nil], load: [],
      coreKinds: [.efficiency, .performance, .unknown],
      user: available ? 30 : nil, system: available ? 20 : nil)
    snapshot.upload = available ? 1024 : nil
    snapshot.download = available ? 2048 : nil
    snapshot.disks = [
      .init(id: 1, name: "Fixture", read: available ? 4096 : nil, written: available ? 8192 : nil)
    ]
    let history = [snapshot.historyPoint]
    for module in [Module.cpu, .overview, .network, .disks] {
      view.update(snapshot, history: history, settings: Settings(), module: module)
      let pairs = view.cards.filter {
        if case .plot(let plot) = $0.content { return !plot.secondLabel.isEmpty }
        return false
      }
      #expect(pairs.count == 1)
      for card in pairs {
        guard case .plot(let plot) = card.content, !plot.secondLabel.isEmpty else { continue }
        #expect(card.spoken.contains(plot.firstLabel + ": " + plot.firstValue))
        #expect(card.spoken.contains(plot.secondLabel + ": " + plot.secondValue))
        let element = try #require(
          view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first {
            $0.accessibilityLabel() == card.title
          })
        #expect(element.accessibilityValue() as? String == card.spoken)
        if !available {
          #expect(plot.firstValue == "—" && plot.secondValue == "—")
        }
        if module == .cpu {
          #expect(plot.firstLabel == "User" && plot.secondLabel == "System")
        }
      }
    }
    var archive = SessionHistory()
    archive.append(history[0], uptime: 1)
    for module in [Module.network, .disks] {
      view.updateHistory(archive.projection(.tenMinutes), module: module, fahrenheit: false)
      let card = try #require(view.cards.first)
      guard case .plot(let plot) = card.content else {
        Issue.record("Expected paired History plot")
        continue
      }
      #expect(!plot.secondLabel.isEmpty)
      #expect(card.spoken.contains(plot.firstLabel + ": " + plot.firstValue))
      #expect(card.spoken.contains(plot.secondLabel + ": " + plot.secondValue))
    }
  }
}

@Test @MainActor func seriesLegendsRenderInPairedAndCoreCards() throws {
  var snapshot = Snapshot()
  snapshot.cpu = .init(
    usage: 50, cores: [12, 48, nil], load: [],
    coreKinds: [.efficiency, .performance, .unknown], user: 30, system: 20)
  snapshot.upload = 1024
  snapshot.download = 2048
  let history = (0..<30).map { index in
    var point = snapshot.historyPoint
    point.time = Date(timeIntervalSince1970: Double(index * 2))
    point.sampleInterval = 2
    return point
  }
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for height in [CGFloat(454), 900] {
      let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: height))
      view.appearance = NSAppearance(named: appearance)
      for module in [Module.cpu, .overview] {
        view.update(snapshot, history: history, settings: Settings(), module: module)
        let bitmap = try legendBitmap(appearance: appearance, scale: 1, size: view.bounds.size) {
          if let context = NSGraphicsContext.current {
            view.displayIgnoringOpacity(view.bounds, in: context)
          } else {
            Issue.record("Missing bitmap drawing context")
          }
        }
        let card = try #require(
          view.cards.first {
            if case .plot(let plot) = $0.content { return !plot.secondLabel.isEmpty }
            return false
          })
        guard case .plot(let plot) = card.content else {
          Issue.record("Expected paired plot")
          continue
        }
        let area = card.contentRect
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let styles = TextDrawingStyles()
        let overview = module == .overview
        let labelSize: CGFloat = overview ? 13 : 10
        let attributes = styles.attributes(
          color: .labelColor, size: labelSize, weight: overview ? .semibold : .regular,
          alignment: .left)
        let firstLabel = overview ? "↓ " + plot.firstValue : plot.firstLabel
        let secondLabel = overview ? "↑ " + plot.secondValue : plot.secondLabel
        let secondWidth = ceil((secondLabel as NSString).size(withAttributes: attributes).width)
        let firstWidth = ceil((firstLabel as NSString).size(withAttributes: attributes).width)
        let markerY = overview ? card.frame.minY + 40 : area.minY + 28.5
        let labelY = overview ? card.frame.minY + 36 : area.minY + 26
        let left = overview ? card.frame.minX + 14 : area.minX
        let right = overview ? card.frame.maxX - 14 : area.maxX
        let markers = [
          NSRect(x: left, y: markerY, width: 7, height: 7),
          NSRect(x: right - secondWidth - 11, y: markerY, width: 7, height: 7),
        ]
        let labels = [
          NSRect(x: markers[0].maxX + 4, y: labelY, width: firstWidth, height: 14),
          NSRect(x: markers[1].maxX + 4, y: labelY, width: secondWidth, height: 14),
        ]
        let background = try legendPixel(
          bitmap, at: .init(x: area.midX * scale, y: (markerY + 3.5) * scale))
        for (index, marker) in markers.enumerated() {
          #expect(area.contains(marker) && area.contains(labels[index]))
          let center = try legendPixel(
            bitmap, at: .init(x: marker.midX * scale, y: marker.midY * scale))
          let edge = try legendPixel(
            bitmap, at: .init(x: marker.minX * scale, y: marker.midY * scale))
          var resolvedColor: NSColor?
          try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolvedColor = (index == 0 ? plot.firstColor : plot.secondColor)
              .usingColorSpace(.deviceRGB)
          }
          let rawColor = try #require(resolvedColor)
          let alpha = rawColor.alphaComponent
          let expectedColor = NSColor(
            deviceRed: rawColor.redComponent * alpha + background.redComponent * (1 - alpha),
            green: rawColor.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: rawColor.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
          if index == 0 {
            #expect(try legendColorDistance(center, background) > 0.2)
            #expect(try legendColorDistance(center, expectedColor) < 0.1)
          } else {
            #expect(try legendColorDistance(center, background) < 0.05)
            #expect(try legendColorDistance(edge, background) > 0.2)
            #expect(try legendColorDistance(edge, expectedColor) < 0.2)
          }
        }
        if module == .cpu {
          let coreCard = try #require(
            view.cards.first {
              if case .cores = $0.content { return true }
              return false
            })
          let coreArea = coreCard.contentRect
          for index in 0..<2 {
            let x = coreArea.minX + CGFloat(index) * coreArea.width / 2
            let markerCenter = try legendPixel(
              bitmap, at: .init(x: (x + 3.5) * scale, y: (coreArea.maxY - 5.5) * scale))
            let rowBackground = try legendPixel(
              bitmap, at: .init(x: (x + 9) * scale, y: (coreArea.maxY - 5.5) * scale))
            #expect(try legendColorDistance(markerCenter, rowBackground) > 0.12)
          }
        }
        if let directory = ProcessInfo.processInfo.environment[
          "TINYSTATS_SERIES_LEGEND_RENDER_PATH"]
        {
          let path = URL(fileURLWithPath: directory, isDirectory: true)
          try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: path.appendingPathComponent("\(module)-\(appearance.rawValue)-\(Int(height)).png"))
        }
      }
    }
  }
}

@Test @MainActor func readingsChartLegendColorsOnlyItsMarkerInBothAppearances() throws {
  _ = NSApplication.shared
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    let chart = ChartView(frame: .init(x: 0, y: 0, width: 300, height: 100))
    chart.appearance = NSAppearance(named: appearance)
    func render(_ color: NSColor) throws -> NSBitmapImageRep {
      chart.series = [.init(name: "Working set %", color: color, values: [])]
      return try legendBitmap(appearance: appearance, scale: 1, size: chart.bounds.size) {
        chart.draw(chart.bounds)
      }
    }
    let red = try render(.systemRed)
    let blue = try render(.systemBlue)
    var markerChanged = false
    var textUnchanged = true
    for y in 0..<100 {
      for x in 0..<150 {
        let differs = red.colorAt(x: x, y: y) != blue.colorAt(x: x, y: y)
        if x < 12 {
          markerChanged = markerChanged || differs
        } else {
          textUnchanged = textUnchanged && !differs
        }
      }
    }
    #expect(markerChanged && textUnchanged)
  }
}
