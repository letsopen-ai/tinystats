import AppKit
import TinyStatsCore

/// Immediate-mode card content and drawing, shared by summary and history presentations.
/// Uses the owning view's text styles, mini charts, and coordinate transform; adds no state.
extension SummaryDashboardView {
  /// Stable non-color keys for paired plots, independent of font glyphs and series hues.
  enum SeriesLegendMarker {
    case first, second

    func draw(in rect: NSRect, color: NSColor) {
      let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
      color.setFill()
      color.setStroke()
      switch self {
      case .first: path.fill()
      case .second:
        path.lineWidth = 1.5
        path.stroke()
      }
    }
  }

  struct Reading {
    var label: String, value: String
    var second: String? = nil
    var fraction: Double? = nil
    var color: NSColor = SystemStyle.accent
    var secondFraction: Double? = nil
    var secondColor: NSColor = SystemStyle.secondaryAccent
    var accessibilityValue: String? = nil
  }
  struct Gauge {
    var label: String, value: String
    var percent: Double?
    var color: NSColor
    var showsTrack = true
  }
  struct TileTextLayout {
    let valueY: CGFloat, valueHeight: CGFloat, detailY: CGFloat?
    init(height: CGFloat) {
      valueY = height < 38 ? 15 : 17
      valueHeight = min(height < 65 ? 22 : 29, height - valueY - 2)
      let next = valueY + valueHeight + 2
      detailY = height >= next + 16 ? next : nil
    }
  }
  struct Tile {
    var label: String, value: String
    var detail: String = ""
    var color: NSColor = SystemStyle.accent
    var fraction: Double? = nil
    var trend: Plot? = nil
  }
  /// All comparison bars use one disclosed scale; unavailable data stays unavailable.
  nonisolated static func relativeFractions(_ values: [Double?]) -> [Double?] {
    let valid = values.map { $0.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    let maximum = valid.compactMap { $0 }.max() ?? 0
    return valid.map { $0.map { maximum > 0 ? $0 / maximum : 0 } }
  }
  enum Content {
    case none
    case device(DeviceHeader)
    case overviewTile(OverviewTile)
    case message(String)
    case rows([Reading])
    case tiles([Tile], columns: Int)
    case gauges([Gauge])
    case cores(CPUReading)
    case memory(MemoryReading)
    case coreHistory(CoreHistoryMatrix)
    case plot(Plot)
  }
  struct Card {
    var frame: NSRect, title: String, trailing: String = "", content: Content, note: String = ""
    var headerHeight: CGFloat = 31
    var contentRect: NSRect {
      .init(
        x: frame.minX + 12, y: frame.minY + headerHeight, width: frame.width - 24,
        height: max(0, frame.height - headerHeight - 6 - (note.isEmpty ? 0 : 17)))
    }
    var spoken: String {
      var parts = [title, trailing]
      switch content {
      case .none: break
      case .device(let header): parts += header.spoken
      case .overviewTile(let tile):
        parts += [tile.value.label + ": " + tile.value.value, tile.value.detail, tile.composition]
        if let trend = tile.value.trend {
          parts.append(
            "\(trend.timeline.span) of recent trend history, "
              + (trend.valueFormat.summary(
                trend.first, indices: trend.timeline.indices, newestLabel: "Newest recorded")
                ?? "No recorded values in this window"))
        }
      case .message(let message): parts.append(message)
      case .rows(let rows):
        parts += rows.map {
          $0.label + ": " + ($0.accessibilityValue ?? $0.value)
            + ($0.second.map { ", " + $0 } ?? "")
        }
      case .tiles(let tiles, _):
        parts += tiles.map { tile in
          let history =
            tile.trend.map {
              ", \($0.timeline.span) of recent trend history, "
                + ($0.valueFormat.summary(
                  $0.first, indices: $0.timeline.indices, newestLabel: "Newest recorded")
                  ?? "No recorded values in this window")
            } ?? ""
          return tile.label + ": " + tile.value
            + (tile.detail.isEmpty ? "" : ", " + tile.detail) + history
        }
      case .gauges(let gauges): parts += gauges.map { $0.label + ": " + $0.value }
      case .memory(let memory):
        let c = memory.composition
        parts += [
          "Memory used: " + Display.percent(memory.percent),
          "App estimate: " + Display.bytes(c.app), "Wired: " + Display.bytes(c.wired),
          "Compressed: " + Display.bytes(c.compressed),
          "Available including cache: " + Display.bytes(c.available),
          "Memory pressure: " + memory.pressureDescription,
        ]
      case .cores(let cpu):
        parts += SummaryDashboardView.displayedCoreIndices(cpu).map {
          "Logical core \($0 + 1), \(cpu.kind(at: $0).title): \(Display.percent(UtilizationMeterCell.normalized(cpu.cores[$0])))"
        }
      case .coreHistory(let matrix):
        parts.append(
          "\(matrix.kinds.count) logical cores; each core is a separate accessibility item")
        parts.append("Counts are valid recorded observations, not continuous time coverage")
        if matrix.statistic == .average {
          parts.append("Sample averages weight valid observations, not elapsed time")
        }
        parts.append(
          "Gray means missing, orange outlines mark collection gaps; incompatible layouts show missing cells"
        )
      case .plot(let plot):
        let timeline = plot.timeline
        let summaryScope =
          plot.bucketSeconds == nil
          ? ", recorded samples in visible window: " : ", recorded buckets in visible window: "
        parts += [
          plot.firstLabel + ": " + plot.firstValue
            + (plot.firstCoverage?.badge.map { ", " + $0 } ?? "")
            + summaryScope
            + (plot.valueFormat.summary(
              plot.first, indices: timeline.indices, newestLabel: "Newest recorded")
              ?? "No recorded values in this window"),
          "\(plot.historySpan ?? timeline.span) history, \(timeline.indices.count) \(plot.bucketSeconds == nil ? "recorded samples" : plot.statistic.singular + " buckets"), \(plot.bucketSeconds.map { String(format: "%.0f second buckets", $0) } ?? timeline.cadenceDescription)",
          plot.drawsTrace
            ? "Traces break at unavailable observations and collection gaps"
            : plot.statistic == .average
              ? "Pixel columns combine sample averages by valid observation counts; not time averages"
              : plot.statistic == .minimum
                ? "Pixel columns retain recorded minima when grouped"
                : "Pixel columns retain sample peaks when grouped; CPU components stay from one observation",
          plot.drawsTrace
            ? "The full five-minute domain includes unsampled time"
            : "Gray markers mean missing or unsampled data; positive readings have a one-pixel minimum",
        ]
        parts += plot.coverage
        if plot.uncollectedFraction.map({ $0 > 0 }) == true {
          parts.append(
            "Shaded area: no recorded data; chart uses the selected full time range")
        }
        if timeline.reset { parts.append("History restarted after a timestamp reset") }
        if !plot.secondLabel.isEmpty {
          parts.append(
            plot.secondLabel + ": " + plot.secondValue
              + (plot.secondCoverage?.badge.map { ", " + $0 } ?? "")
              + summaryScope
              + (plot.valueFormat.summary(
                plot.second, indices: timeline.indices, newestLabel: "Newest recorded")
                ?? "No recorded values in this window"))
        }
      }
      return (parts + [note]).filter { !$0.isEmpty }.joined(separator: ". ")
    }
  }
  nonisolated static func displayedCoreIndices(_ cpu: CPUReading) -> [Int] {
    Array(
      CPUCoreKind.allCases.flatMap { kind in cpu.cores.indices.filter { cpu.kind(at: $0) == kind } }
        .prefix(24))
  }
  private func meter(_ fraction: Double?, rect: NSRect, color: NSColor) {
    NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    guard let fraction, fraction.isFinite, fraction >= 0 else { return }
    color.withAlphaComponent(0.85).setFill()
    NSBezierPath(
      roundedRect: NSRect(
        x: rect.minX, y: rect.minY,
        width: rect.width * min(1, fraction), height: rect.height), xRadius: 2, yRadius: 2
    ).fill()
  }
  struct PairedRowLayout {
    let textHeight: CGFloat
    let meterY: CGFloat
    init(height: CGFloat) {
      textHeight = max(0, height - 7)
      meterY = max(0, height - 3)
    }
  }
  func drawRows(_ rows: ArraySlice<Reading>, in area: NSRect) {
    guard !rows.isEmpty else {
      if area.height >= 14 {
        text("No readings to show", rect: area, color: .secondaryLabelColor, size: 11)
      }
      return
    }
    let height = min(25, area.height / CGFloat(rows.count))
    for (index, row) in rows.enumerated() {
      let y = area.minY + CGFloat(index) * height
      let paired = row.second != nil
      let pairedLayout = PairedRowLayout(height: height)
      if !paired, let fraction = row.fraction, fraction.isFinite, fraction >= 0 {
        row.color.withAlphaComponent(0.13).setFill()
        NSBezierPath(
          roundedRect: NSRect(
            x: area.minX, y: y,
            width: area.width * min(1, fraction), height: max(1, height - 2)),
          xRadius: 3, yRadius: 3
        ).fill()
      }
      let valueStart = area.minX + area.width * (paired ? 0.43 : 0.56)
      if paired {
        let barWidth = area.width * 0.27
        meter(
          row.fraction,
          rect: NSRect(
            x: valueStart + 2, y: y + pairedLayout.meterY,
            width: barWidth - 4, height: 2), color: row.color)
        meter(
          row.secondFraction,
          rect: NSRect(
            x: area.minX + area.width * 0.73 + 2,
            y: y + pairedLayout.meterY, width: barWidth - 4, height: 2), color: row.secondColor)
      }
      let textHeight = paired ? pairedLayout.textHeight : max(12, height)
      text(
        row.label,
        rect: NSRect(
          x: area.minX + 3, y: y,
          width: area.width * (paired ? 0.42 : 0.55) - 3, height: textHeight),
        size: height < 18 ? 10 : 11)
      text(
        row.value,
        rect: NSRect(
          x: valueStart, y: y,
          width: area.width * (paired ? 0.27 : 0.44) - 3, height: textHeight),
        color: .labelColor, size: height < 18 ? 10 : 11,
        weight: .medium, alignment: .right)
      if let second = row.second {
        text(
          second,
          rect: NSRect(
            x: area.minX + area.width * 0.73, y: y,
            width: area.width * 0.27 - 3, height: textHeight), color: .labelColor,
          size: height < 18 ? 10 : 11, weight: .medium, alignment: .right)
      }
    }
  }
  func drawTiles(_ tiles: [Tile], columns: Int, in area: NSRect) {
    guard !tiles.isEmpty else {
      text("No readings to show", rect: area, color: .secondaryLabelColor, size: 11)
      return
    }
    let columns = max(1, min(columns, tiles.count))
    let rows = (tiles.count + columns - 1) / columns
    let gap: CGFloat = 5
    let width = (area.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
    let height = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
    guard height > 20, width > 20 else { return }
    for (index, tile) in tiles.enumerated() {
      let frame = NSRect(
        x: area.minX + CGFloat(index % columns) * (width + gap),
        y: area.minY + CGFloat(index / columns) * (height + gap), width: width, height: height)
      NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
      NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
      let compact = height < 65
      let hasRing = tile.fraction != nil && width > 95
      let diameter: CGFloat = compact ? 26 : 30
      if hasRing {
        ring(
          tile.fraction.map { $0 * 100 },
          rect: NSRect(
            x: frame.maxX - diameter - 7,
            y: frame.minY + (compact ? 15 : 19), width: diameter, height: diameter),
          color: tile.color, lineWidth: 3)
      }
      text(
        tile.label,
        rect: NSRect(
          x: frame.minX + 7, y: frame.minY + 3,
          width: width - 14 - (tile.trend == nil ? 0 : 36), height: 13),
        color: .secondaryLabelColor, size: 9,
        weight: .medium)
      if let trend = tile.trend {
        text(
          trend.timeline.span,
          rect: NSRect(
            x: frame.maxX - 43, y: frame.minY + 4,
            width: 36, height: 11), color: .secondaryLabelColor, size: 7, alignment: .right)
      }
      let textLayout = TileTextLayout(height: height)
      text(
        tile.value,
        rect: NSRect(
          x: frame.minX + 7, y: frame.minY + textLayout.valueY,
          width: width - 14 - (hasRing ? diameter + 5 : 0),
          height: textLayout.valueHeight),
        color: .labelColor, size: height < 38 ? 13 : compact ? 17 : 23, weight: .semibold)
      if let trend = tile.trend {
        let trendHeight: CGFloat = compact ? 12 : 25
        drawMiniHistory(
          trend,
          in: NSRect(
            x: frame.minX + 7, y: frame.maxY - trendHeight - 4,
            width: width - 14, height: trendHeight))
      } else if let detailY = textLayout.detailY, !tile.detail.isEmpty {
        text(
          tile.detail,
          rect: NSRect(
            x: frame.minX + 7, y: frame.minY + detailY,
            width: width - 14, height: 12), color: .secondaryLabelColor, size: 8)
      }
      if tile.trend == nil, tile.fraction != nil, height >= 44 {
        meter(
          tile.fraction,
          rect: NSRect(
            x: frame.minX + 7, y: frame.maxY - 3,
            width: width - 14, height: 2), color: tile.color)
      }
    }
  }
  private func ring(_ percent: Double?, rect: NSRect, color: NSColor, lineWidth: CGFloat = 4) {
    let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let track = NSBezierPath(ovalIn: inset)
    track.lineWidth = lineWidth
    NSColor.quaternaryLabelColor.setStroke()
    track.stroke()
    guard let percent = UtilizationMeterCell.normalized(percent), percent > 0 else { return }
    let path = NSBezierPath()
    path.appendArc(
      withCenter: .init(x: inset.midX, y: inset.midY), radius: inset.width / 2,
      startAngle: -90, endAngle: -90 + 360 * percent / 100)
    path.lineWidth = lineWidth
    color.setStroke()
    path.stroke()
  }
  func drawGauges(_ gauges: [Gauge], in area: NSRect) {
    guard !gauges.isEmpty else {
      text("No readings to show", rect: area, color: .secondaryLabelColor, size: 11)
      return
    }
    let width = area.width / CGFloat(gauges.count)
    let diameter = min(width - 12, area.height - 18, 92)
    guard diameter > 12 else { return }
    for (index, gauge) in gauges.enumerated() {
      let x = area.minX + width * CGFloat(index)
      let rect = NSRect(
        x: x + (width - diameter) / 2, y: area.minY, width: diameter, height: diameter)
      if gauge.showsTrack { ring(gauge.percent, rect: rect, color: gauge.color) }
      text(
        gauge.value,
        rect: .init(x: rect.minX + 3, y: rect.midY - 8, width: rect.width - 6, height: 20),
        size: diameter < 50 ? 12 : 17, weight: .semibold, alignment: .center)
      text(
        gauge.label, rect: .init(x: x, y: rect.maxY + 3, width: width, height: 16), size: 10,
        alignment: .center)
    }
  }
  func drawMemory(_ memory: MemoryReading, in area: NSRect) {
    let c = memory.composition
    let segments: [(String, UInt64, NSColor)] = [
      ("App · estimate", c.app, SystemStyle.accent),
      ("Wired", c.wired, SystemStyle.secondaryAccent),
      ("Compressed", c.compressed, SystemStyle.neutralSeries),
      ("Available · incl. cache", c.available, SystemStyle.availableSeries),
    ]
    if usesPopoverLayout {
      SegmentedBarView.draw(
        segments.map { _, bytes, color in
          .init(
            fraction: memory.total > 0 ? Double(bytes) / Double(memory.total) : nil, color: color)
        }, in: .init(x: area.minX, y: area.minY + 8, width: area.width, height: 8))
      for (index, segment) in segments.enumerated() {
        let y = area.minY + 30 + CGFloat(index) * 23
        segment.2.setFill()
        let marker = NSBezierPath(ovalIn: .init(x: area.minX, y: y + 4, width: 7, height: 7))
        marker.fill()
        if index == 3 {
          NSColor.secondaryLabelColor.setStroke()
          marker.lineWidth = 1
          marker.stroke()
        }
        text(
          segment.0,
          rect: .init(x: area.minX + 14, y: y, width: area.width * 0.65 - 14, height: 18), size: 12)
        text(
          Display.bytes(segment.1, precise: true),
          rect: .init(x: area.minX + area.width * 0.65, y: y, width: area.width * 0.35, height: 18),
          size: 12, alignment: .right)
      }
      text(
        "Pressure · " + memory.pressureDescription,
        rect: .init(x: area.minX, y: area.minY + 132, width: area.width, height: 20),
        color: memory.pressure == 1
          ? SystemStyle.nominal
          : memory.pressure == 2
            ? SystemStyle.warning
            : memory.pressure == 4 ? SystemStyle.critical : .secondaryLabelColor, size: 12)
      return
    }
    let diameter: CGFloat = 140
    let rect = NSRect(x: area.minX + 12, y: area.minY + 8, width: diameter, height: diameter)
    ring(0, rect: rect, color: SystemStyle.accent, lineWidth: 11)
    var start: CGFloat = -90
    if memory.total > 0 {
      for (_, bytes, color) in segments {
        let angle = CGFloat(Double(bytes) / Double(memory.total) * 360)
        let path = NSBezierPath()
        path.appendArc(
          withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: (diameter - 11) / 2,
          startAngle: start, endAngle: start + angle, clockwise: false)
        path.lineWidth = 11
        color.setStroke()
        path.stroke()
        start += angle
      }
    }
    text(
      Display.percent(memory.total > 0 ? memory.percent : nil),
      rect: .init(x: rect.minX, y: rect.midY - 21, width: diameter, height: 32), size: 27,
      weight: .semibold, alignment: .center)
    text(
      "Memory used", rect: .init(x: rect.minX, y: rect.midY + 13, width: diameter, height: 16),
      color: .secondaryLabelColor, size: 10, alignment: .center)
    let x = area.minX + 180
    for (index, segment) in segments.enumerated() {
      let y = area.minY + 10 + CGFloat(index) * 32
      segment.2.setFill()
      let marker = NSBezierPath(ovalIn: .init(x: x, y: y + 4, width: 9, height: 9))
      marker.fill()
      if index == 3 {
        NSColor.secondaryLabelColor.setStroke()
        marker.lineWidth = 1
        marker.stroke()
      }
      text(segment.0, rect: .init(x: x + 17, y: y, width: area.maxX - x - 95, height: 20), size: 12)
      text(
        Display.bytes(segment.1, precise: true),
        rect: .init(x: area.maxX - 83, y: y, width: 83, height: 20),
        size: 12, weight: .semibold, alignment: .right)
    }
    let pressureColor: NSColor =
      memory.pressure == 1
      ? .systemGreen
      : memory.pressure == 2
        ? .systemOrange : memory.pressure == 4 ? .systemRed : .secondaryLabelColor
    text(
      "Pressure", rect: .init(x: area.minX + 12, y: area.minY + 164, width: 100, height: 20),
      color: .secondaryLabelColor)
    text(
      memory.pressureDescription,
      rect: .init(x: area.minX + 110, y: area.minY + 164, width: 140, height: 20),
      color: pressureColor, weight: .semibold)
    text(
      Display.bytes(memory.used, precise: true) + " used",
      rect: .init(x: area.midX, y: area.minY + 164, width: area.width / 2, height: 20),
      alignment: .right)
  }
  func drawCoreMarker(_ kind: CPUCoreKind, rect: NSRect) {
    kind.chartColor.setFill()
    switch kind {
    case .efficiency: NSBezierPath(ovalIn: rect).fill()
    case .performance: rect.fill()
    case .unknown:
      let path = NSBezierPath()
      path.move(to: .init(x: rect.midX, y: rect.minY))
      path.line(to: .init(x: rect.maxX, y: rect.midY))
      path.line(to: .init(x: rect.midX, y: rect.maxY))
      path.line(to: .init(x: rect.minX, y: rect.midY))
      path.close()
      path.fill()
    }
  }
  static func coreCells(_ cpu: CPUReading, area: NSRect, capsules: Bool = false) -> [(Int, NSRect)]
  {
    let order = displayedCoreIndices(cpu)
    guard !order.isEmpty else { return [] }
    if capsules {
      let columns = min(12, order.count)
      let cellWidth = area.width / CGFloat(columns)
      let rows = (order.count + columns - 1) / columns
      let rowHeight = max(24, (area.height - 16) / CGFloat(rows))
      return order.enumerated().map { position, index in
        (
          index,
          NSRect(
            x: area.minX + CGFloat(position % columns) * cellWidth + (cellWidth - 12) / 2,
            y: area.minY + CGFloat(position / columns) * rowHeight,
            width: 12, height: max(10, rowHeight - 18))
        )
      }
    }
    let columns = order.count > 12 ? (order.count + 1) / 2 : order.count
    let rows = (order.count + columns - 1) / columns
    let width = area.width / CGFloat(columns)
    let diameter = min(rows == 1 ? 44 : 32, width - 4, (area.height - 16) / CGFloat(rows) - 4)
    guard diameter > 8 else { return [] }
    return order.enumerated().map { position, index in
      (
        index,
        NSRect(
          x: area.minX + CGFloat(position % columns) * width + (width - diameter) / 2,
          y: area.minY + CGFloat(position / columns) * (diameter + 7), width: diameter,
          height: diameter)
      )
    }
  }
  func drawCores(_ cpu: CPUReading, in area: NSRect) {
    if usesPopoverLayout {
      let order = Self.displayedCoreIndices(cpu)
      let columns = min(12, max(1, order.count))
      let cellWidth = area.width / CGFloat(columns)
      for (index, bar) in Self.coreCells(cpu, area: area, capsules: true) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        if let value = UtilizationMeterCell.normalized(cpu.cores[index]), value > 0 {
          let height = bar.height * value / 100
          SystemStyle.core(cpu.kind(at: index)).setFill()
          NSBezierPath(
            roundedRect: .init(x: bar.minX, y: bar.maxY - height, width: bar.width, height: height),
            xRadius: min(6, height / 2), yRadius: min(6, height / 2)
          ).fill()
        }
        text(
          cpu.cores[index].map { String(format: "%.0f", $0) } ?? "—",
          rect: .init(x: bar.midX - cellWidth / 2, y: bar.maxY + 2, width: cellWidth, height: 12),
          color: .secondaryLabelColor, size: 9, alignment: .center)
      }
      let kinds = CPUCoreKind.allCases.filter { kind in order.contains { cpu.kind(at: $0) == kind }
      }
      let width = area.width / CGFloat(max(1, kinds.count))
      for (index, kind) in kinds.enumerated() {
        let x = area.minX + CGFloat(index) * width
        drawCoreMarker(kind, rect: .init(x: x, y: area.maxY - 9, width: 7, height: 7))
        text(
          kind.chartTitle, rect: .init(x: x + 11, y: area.maxY - 12, width: width - 11, height: 14),
          color: .secondaryLabelColor, size: 9)
      }
      return
    }
    let order = Self.displayedCoreIndices(cpu)
    for (index, rect) in Self.coreCells(cpu, area: area) {
      let kind = cpu.kind(at: index)
      let color = kind.chartColor
      ring(cpu.cores[index], rect: rect, color: color, lineWidth: 3)
      text(
        Display.percent(UtilizationMeterCell.normalized(cpu.cores[index])),
        rect: .init(x: rect.minX, y: rect.midY - 6, width: rect.width, height: 12), size: 8,
        weight: .medium, alignment: .center)
    }
    let kinds = CPUCoreKind.allCases.filter { kind in order.contains { cpu.kind(at: $0) == kind } }
    let legendWidth = area.width / CGFloat(max(1, kinds.count))
    for (position, kind) in kinds.enumerated() {
      let values = cpu.cores.indices.filter { cpu.kind(at: $0) == kind }.compactMap {
        cpu.cores[$0]
      }
      let x = area.minX + CGFloat(position) * legendWidth
      drawCoreMarker(kind, rect: .init(x: x, y: area.maxY - 9, width: 7, height: 7))
      let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
      text(
        kind.chartTitle + " " + Display.percent(average),
        rect: .init(x: x + 12, y: area.maxY - 12, width: legendWidth - 14, height: 14),
        color: .labelColor, size: 10)
    }
  }
}
