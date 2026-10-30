import AppKit
import TinyStatsCore

/// Styling follows metric identity, never paint order or the presence of other readings.
enum ChartSeriesRole {
  case primary, secondary
  var dashed: Bool { self == .secondary }
  var legendMarker: SummaryDashboardView.SeriesLegendMarker { self == .primary ? .first : .second }
  var legendGlyph: String { self == .primary ? "● " : "○ " }
}

@MainActor final class ChartView: ChartHoverView {
  var usesPanelGlass = false
  var glassEnvironment: () -> GlassSurface.Environment = { .current }
  private var secondaryInk: NSColor {
    usesPanelGlass && glassEnvironment().treatment == .glass
      ? SystemStyle.glassSecondaryLabel : .secondaryLabelColor
  }
  struct Series {
    var name: String
    var color: NSColor
    var values: [Double?]
    var role: ChartSeriesRole = .primary
    var displayName: String? = nil
  }
  var series: [Series] = [] {
    didSet {
      needsDisplay = true
      refreshHover()
    }
  }
  var fitsDataRange = false
  var plotArea: NSRect {
    fitsDataRange
      ? .init(
        x: bounds.minX + 70, y: bounds.minY + 36, width: max(1, bounds.width - 72),
        height: max(1, bounds.height - 56))
      : bounds.insetBy(dx: 1, dy: 19)
  }
  var plotDomain: GraphDomain {
    GraphDomain(
      values: series.flatMap(\.values), fixedUpper: fitsDataRange ? nil : upperBound,
      fitToData: fitsDataRange)
  }
  var recordedSummary: String {
    let values = series.flatMap(\.values).compactMap { $0 }.filter(\.isFinite)
    let span = HistoryTimeline(times: times).span
    return "Min " + valueFormat.string(values.min()) + " · Max " + valueFormat.string(values.max())
      + " · " + span + " · " + String(values.count) + " readings"
  }
  var valueFormat: ChartValueFormat = .percent
  var times: [Date] = [] {
    didSet { refreshHover() }
  }
  var upperBound: Double? = 100
  var emptyMessage = "No readings yet"
  var newestValueLabel = "Latest"
  var showsSummaryDecorations = true
  var caption: String?
  var inspectionDateLabel: ((Date) -> String)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Metric history chart")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func accessibilityValue() -> Any? {
    let timeline = HistoryTimeline(times: times)
    let summaries = series.map {
      valueFormat.summary($0.values, indices: timeline.indices, newestLabel: newestValueLabel)
    }
    guard summaries.contains(where: { $0 != nil }) else { return emptyMessage }
    let values = zip(series, summaries).map { line, summary in
      line.name + ": " + (summary ?? "No recorded values in this window")
    }.joined(separator: "; ")
    return values + (timeline.duration > 0 ? "; window " + timeline.span : "")
  }
  override func hoverText(at point: NSPoint) -> String? {
    let area = plotArea
    guard area.contains(point), !times.isEmpty, !series.isEmpty else { return nil }
    let timeline = HistoryTimeline(times: times)
    let fraction = Double((point.x - area.minX) / max(1, area.width))
    guard
      let index = timeline.indices.min(by: {
        abs((timeline.positions[$0] ?? 0) - fraction)
          < abs((timeline.positions[$1] ?? 0) - fraction)
      })
    else { return "No recorded observations" }
    let distance = abs((timeline.positions[index] ?? 0) - fraction)
    let tolerance = max(
      1 / max(1, Double(area.width)), 1 / Double(max(1, timeline.indices.count - 1)))
    guard distance <= tolerance else { return "No recorded observations here" }
    return
      ([inspectionDateLabel?(times[index]) ?? Self.hoverDate(times[index])]
      + series.map { line in
        line.name + ": "
          + valueFormat.string(line.values.indices.contains(index) ? line.values[index] : nil)
      }).joined(separator: "\n")
  }
  var hasPlottableData: Bool {
    let timeline = HistoryTimeline(times: times)
    let domain = plotDomain
    return series.contains { line in
      timeline.indices.contains { index in
        line.values.indices.contains(index) && domain.fraction(line.values[index]) != nil
          && timeline.positions[index] != nil
      }
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let area = plotArea
    NSColor.quaternaryLabelColor.setStroke()
    let drawsGrid = hasPlottableData
    for fraction in [0.0, 0.5, 1.0] where drawsGrid {
      let y = area.minY + area.height * fraction
      let path = NSBezierPath()
      path.move(to: .init(x: area.minX, y: y))
      path.line(to: .init(x: area.maxX, y: y))
      path.lineWidth = 0.5
      path.stroke()
    }
    let domain = plotDomain
    if domain.lower < 0 && domain.upper >= 0, let zero = domain.fraction(0) {
      let baseline = NSBezierPath()
      let y = area.minY + area.height * zero
      baseline.move(to: .init(x: area.minX, y: y))
      baseline.line(to: .init(x: area.maxX, y: y))
      secondaryInk.setStroke()
      baseline.lineWidth = 0.8
      baseline.stroke()
    }
    var hasData = false
    let timeline = HistoryTimeline(times: times)
    let duration = max(1, timeline.duration)
    for line in series {
      let path = NSBezierPath()
      var previous = false
      for i in timeline.indices {
        guard line.values.indices.contains(i), let fraction = domain.fraction(line.values[i]),
          let position = timeline.positions[i]
        else {
          previous = false
          continue
        }
        let x = area.minX + area.width * position
        let point = NSPoint(x: x, y: area.minY + area.height * fraction)
        if previous { path.line(to: point) } else { path.move(to: point) }
        previous = true
        hasData = true
      }
      SystemStyle.chartTraceColor(
        line.color, role: line.role,
        glass: usesPanelGlass && glassEnvironment().treatment == .glass
      ).setStroke()
      if line.role.dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
      path.lineWidth = 1.5
      path.lineJoinStyle = .round
      path.stroke()
    }
    let font = NSFont.systemFont(ofSize: 10)
    var x = 0.0
    for line in series where showsSummaryDecorations && (!fitsDataRange || hasData) {
      let label =
        line.role.legendGlyph + (line.displayName ?? line.name)
        + (fitsDataRange ? " · " + valueFormat.string(line.values.last.flatMap { $0 }) : "")
      let string = NSMutableAttributedString(
        string: label, attributes: [.font: font, .foregroundColor: secondaryInk])
      string.addAttribute(
        .foregroundColor,
        value: SystemStyle.chartTraceColor(
          line.color, role: line.role,
          glass: usesPanelGlass && glassEnvironment().treatment == .glass),
        range: NSRange(location: 0, length: 1))
      string.draw(at: NSPoint(x: x, y: bounds.height - 13))
      x += string.size().width + 14
    }
    if fitsDataRange && hasData {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
        .foregroundColor: secondaryInk,
      ]
      for (value, y) in [(domain.upper, area.maxY - 11), (domain.lower, area.minY)] {
        (valueFormat.axisString(value) as NSString).draw(
          in: .init(x: 0, y: y, width: 64, height: 13), withAttributes: attrs)
      }
      if showsSummaryDecorations {
        (recordedSummary as NSString).draw(
          in: .init(x: 0, y: 15, width: bounds.width, height: 13),
          withAttributes: [.font: font, .foregroundColor: secondaryInk])
      }
    }
    if !hasData {
      (emptyMessage as NSString).draw(
        in: NSRect(x: 0, y: area.midY - 8, width: bounds.width, height: 18),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondaryInk,
          .paragraphStyle: {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            return style
          }(),
        ])
    }
    guard !fitsDataRange || hasData else { return }
    var label =
      caption
      ?? (times.count > 1 ? "\(Int(duration))s history · newest →" : "Waiting for the next reading")
    if !fitsDataRange && domain.lower < 0 {
      label += String(format: " · %.2f to %.2f", domain.lower, domain.upper)
    }
    (label as NSString).draw(
      at: .init(x: 0, y: 0),
      withAttributes: [.font: font, .foregroundColor: secondaryInk])
  }
}
