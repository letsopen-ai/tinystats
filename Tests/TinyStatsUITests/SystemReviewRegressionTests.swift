import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func reviewDescendants(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + reviewDescendants($0) }
}

@MainActor private func reviewPopover(_ module: Module, snapshot: Snapshot) -> DetailController {
  _ = NSApplication.shared
  let detail = DetailController(snapshot: snapshot, history: [])
  detail.isPopoverPresentation = true
  detail.selected = module
  detail.loadViewIfNeeded()
  detail.view.setFrameSize(SystemStyle.popoverSize)
  detail.update(snapshot, history: [])
  detail.view.layoutSubtreeIfNeeded()
  return detail
}

@Test @MainActor func populatedSixteenCorePopoverInspectsEveryDrawnCapsule() throws {
  var snapshot = Snapshot()
  let kinds: [CPUCoreKind] = (0..<16).map { $0.isMultiple(of: 2) ? .performance : .efficiency }
  var values: [Double?] = (0..<16).map { Double($0 * 5) }
  values[7] = nil
  snapshot.cpu = .init(usage: 37, cores: values, load: [], coreKinds: kinds)
  let detail = reviewPopover(.cpu, snapshot: snapshot)
  let summary = try #require(
    reviewDescendants(detail.view).compactMap { $0 as? SummaryDashboardView }.first)
  let area = try #require(summary.cards.first { $0.title == "LOGICAL CORES" }).contentRect
  let order =
    (0..<16).filter { kinds[$0] == .efficiency } + (0..<16).filter { kinds[$0] == .performance }
  // Independent coordinates from the approved 12-column capsule layout, including row two.
  let width = area.width / 12
  let rowHeight = max(24, (area.height - 16) / 2)
  for (position, index) in order.enumerated() {
    let point = NSPoint(
      x: area.minX + (CGFloat(position % 12) + 0.5) * width,
      y: area.minY + CGFloat(position / 12) * rowHeight + max(10, rowHeight - 18) / 2)
    #expect(
      summary.hoverText(at: point) == kinds[index].chartTitle + " core: "
        + ChartValueFormat.percent.string(values[index]))
  }
  #expect(summary.hoverText(at: .init(x: area.minX + width, y: area.minY + 2)) == nil)
  #expect(
    summary.hoverText(at: .init(x: area.maxX - width / 2, y: area.minY + rowHeight + 2)) == nil)
}

@Test @MainActor func internalBatteryPopoverFitsLabelsSignedPowerAndRemainingTime() throws {
  var snapshot = Snapshot()
  snapshot.batteries = [
    .init(
      name: "Internal battery", percent: 63, charging: false, externalPower: false,
      minutesRemaining: 754, cycles: 1234, health: 87, watts: -123.4)
  ]
  snapshot.sensors = [.init(key: "TB0T", name: "Battery", kind: .temperature, value: 31)]
  let detail = reviewPopover(.battery, snapshot: snapshot)
  let summary = try #require(
    reviewDescendants(detail.view).compactMap { $0 as? SummaryDashboardView }.first)
  let card = try #require(summary.cards.first { $0.title == "BATTERY DETAILS" })
  guard case .tiles(let tiles, let columns) = card.content else {
    Issue.record("Expected battery detail tiles")
    return
  }
  #expect(columns == 2)
  #expect(tiles.map(\.value) == ["12h 34m", "-123.4 W", "1234", "31°C"])
  let width = (card.contentRect.width - CGFloat(columns - 1) * 5) / CGFloat(columns)
  let rows = (tiles.count + columns - 1) / columns
  let height = (card.contentRect.height - CGFloat(rows - 1) * 5) / CGFloat(rows)
  let valueSize: CGFloat = height < 38 ? 13 : height < 65 ? 17 : 23
  for (index, tile) in tiles.enumerated() {
    for (text, size, weight) in [
      (tile.label, CGFloat(9), NSFont.Weight.medium), (tile.value, valueSize, .semibold),
    ] {
      let measured = (text as NSString).size(withAttributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
      ])
      #expect(measured.width <= width - 14)
    }
    let point = NSPoint(
      x: card.contentRect.minX + CGFloat(index % columns) * (width + 5) + width / 2,
      y: card.contentRect.minY + CGFloat(index / columns) * (height + 5) + height / 2)
    #expect(summary.hoverText(at: point) == tile.label + ": " + tile.value)
  }
  detail.isPopoverPresentation = false
  detail.update(snapshot, history: [])
  guard
    case .tiles(_, let windowColumns) = try #require(
      summary.cards.first { $0.title == "BATTERY DETAILS" }
    ).content
  else {
    Issue.record("Expected battery details after promotion")
    return
  }
  #expect(windowColumns == 4)
}

@Test @MainActor func sensorHeadlineUsesSentenceCaseAndKeepsItsAccessibilityIdentity() throws {
  var snapshot = Snapshot()
  snapshot.sensors = [.init(key: "T", name: "CPU", kind: .temperature, value: 52)]
  let detail = reviewPopover(.sensors, snapshot: snapshot)
  let labels = reviewDescendants(detail.view).compactMap { $0 as? NSTextField }
  let title = try #require(
    labels.first { $0.stringValue == "Sensors" })
  #expect(title.stringValue == "Sensors")
  #expect(title.accessibilityLabel() == "SENSORS")
  detail.paused = true
  #expect(title.stringValue == "Sensors · paused")
  #expect(title.accessibilityLabel() == "SENSORS · PAUSED")
  detail.selected = .cpu
  #expect(title.stringValue == "CPU · Paused")
  #expect(title.accessibilityLabel() != "SENSORS · PAUSED")
}

@Test @MainActor func popoverTraceCaptionsDiscloseScaleSpanEmptyUnavailableAndZero() throws {
  _ = NSApplication.shared
  for module in [Module.cpu, .gpu, .network, .disks] {
    for reading: Double? in [nil, 0, 4096] {
      for empty in [true, false] {
        var snapshot = Snapshot()
        snapshot.timestamp = Date(timeIntervalSince1970: 100)
        snapshot.cpu = .init(
          usage: reading, cores: [reading], load: [], user: reading, system: reading)
        snapshot.gpus = [.init(name: "GPU", usage: reading, memory: nil)]
        snapshot.upload = reading
        snapshot.download = reading.map { $0 * 2 }
        snapshot.disks = [
          .init(id: 1, name: "disk0", read: reading, written: reading.map { $0 * 2 })
        ]
        var first = snapshot.historyPoint
        first.time -= 60
        let history = empty ? [] : [first, snapshot.historyPoint]
        let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 316, height: 640))
        view.usesPopoverLayout = true
        view.update(snapshot, history: history, settings: Settings(), module: module)
        let card = try #require(
          view.cards.first {
            if case .plot = $0.content { return true }
            return false
          })
        guard case .plot(let plot) = card.content else {
          Issue.record("Expected \(module) plot")
          continue
        }
        let layout = HistoryBarLayout(plot: plot, graphWidth: card.contentRect.width, scale: 1)
        let captions = SummaryDashboardView.PlotCaptions(plot, layout: layout, trace: true)
        #expect(captions.span == (empty ? "0s · 0 samples" : "1m 0s · 2 samples"))
        #expect(
          captions.emptyMessage
            == (empty
              ? "No readings yet" : reading == nil ? "No readings to show for this period" : nil))
        if plot.percent {
          #expect(captions.scale == "0–100%")
        } else {
          #expect(
            captions.scale
              == (empty || reading == nil
                ? "Scale unavailable" : "Scale 0–" + Display.rate(max(1, (reading ?? 0) * 2))))
        }
        #expect(layout.hasData == (!empty && reading != nil))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
          view.appearance = NSAppearance(named: name)
          view.needsDisplay = true
          let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
          view.cacheDisplay(in: view.bounds, to: bitmap)
          // A flat interior platter has no ink here if trace mode returns before its captions.
          var bands = [
            NSRect(
              x: card.contentRect.minX, y: card.contentRect.maxY - 25,
              width: card.contentRect.width / 2, height: 12),
            NSRect(
              x: card.contentRect.midX, y: card.contentRect.maxY - 25,
              width: card.contentRect.width / 2, height: 12),
          ]
          if captions.emptyMessage != nil {
            let graph = SummaryDashboardView.plotGraphRect(plot, area: card.contentRect)
            bands.append(
              .init(x: graph.minX + 1, y: graph.minY + 2, width: graph.width - 2, height: 12))
          }
          for band in bands {
            var colors = Set<UInt32>()
            let sx = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let sy = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            for y in Int(band.minY * sy)..<Int(band.maxY * sy) {
              for x in Int(band.minX * sx)..<Int(band.maxX * sx) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let rgba = [
                  color.redComponent, color.greenComponent, color.blueComponent,
                  color.alphaComponent,
                ].reduce(
                  UInt32(0)
                ) { ($0 << 8) | UInt32(($1 * 255).rounded()) }
                colors.insert(rgba)
              }
            }
            #expect(
              colors.count > 8,
              "\(module), \(name), empty=\(empty), reading=\(String(describing: reading)), band=\(band)"
            )
          }
        }
      }
    }
  }
}
