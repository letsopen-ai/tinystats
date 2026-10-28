import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func barPlot(_ first: [Double?], _ second: [Double?] = [])
  -> SummaryDashboardView.Plot
{
  .init(
    first: first, second: second, firstLabel: "Upload",
    secondLabel: second.isEmpty ? "" : "Download",
    firstValue: "Fixture", secondValue: "Fixture", percent: false, mirrored: !second.isEmpty,
    time: .init(
      first.indices.map { Date(timeIntervalSince1970: Double($0) * 2) },
      intervals: first.map { _ in 2 }))
}

@Test @MainActor func historyColumnsStayPixelAlignedAndRetainPeaksAtBothScales() throws {
  let values: [Double?] = (0..<300).map { $0 == 151 ? 999 : Double($0 % 13) }
  var plot = barPlot(values, values.reversed())
  plot.first[0] = nil
  for scale in [CGFloat(1), 2] {
    let layout = HistoryBarLayout(plot: plot, graphWidth: 496, scale: scale)
    #expect(layout.columns.reduce(0) { $0 + $1.samples } == 300)
    #expect(layout.columns.count == (scale == 1 ? 248 : 300))
    #expect(layout.grouped == (scale == 1))
    #expect(layout.maximum == 999)
    #expect(layout.columns.contains { $0.firstMissing })
    #expect(layout.columns.compactMap(\.first).max() == 999)
    #expect(layout.columns.compactMap(\.second).max() == 999)
    let origins = layout.columns.map { layout.x($0) * scale }
    #expect(origins.allSatisfy { $0 == $0.rounded() })
    #expect(
      zip(origins, origins.dropFirst()).allSatisfy { $1 - $0 >= CGFloat(layout.barPixels + 1) })
    #expect((origins.last ?? 0) + CGFloat(layout.barPixels) <= 496 * scale)
  }
  let empty = HistoryBarLayout(plot: plot, graphWidth: .nan, scale: .nan)
  #expect(empty.columns.isEmpty && !empty.hasData)
  #expect(HistoryBarLayout(plot: plot, graphWidth: -1, scale: 1).columns.isEmpty)
  #expect(HistoryBarLayout(plot: plot, graphWidth: 1, scale: 1).columns.count == 1)
}

@Test @MainActor func stackedColumnsKeepOneObservationAndDistinguishZeroFromMissing() throws {
  var plot = barPlot([nil, 0, 90, 10], [nil, 0, 5, 80])
  plot.percent = true
  plot.mirrored = false
  let layout = HistoryBarLayout(plot: plot, graphWidth: 3, scale: 1)
  #expect(layout.columns.count == 2)
  let zero = try #require(layout.columns.first)
  #expect(zero.first == 0 && zero.second == 0)
  #expect(zero.firstMissing && zero.secondMissing && zero.samples == 2)
  let busy = try #require(layout.columns.last)
  #expect(busy.first == 90 && busy.second == 5)
  #expect(layout.maximum == 100 && layout.hasData)
  let missing = HistoryBarLayout(
    plot: barPlot([nil, .nan, -1, .infinity]), graphWidth: 496, scale: 2)
  #expect(!missing.hasData && missing.columns.allSatisfy { $0.firstMissing && $0.first == nil })
  let idle = HistoryBarLayout(plot: barPlot([0]), graphWidth: 496, scale: 2)
  #expect(
    idle.hasData && idle.columns.first?.first == 0 && idle.columns.first?.firstMissing == false)
}

@Test @MainActor func orderedBinsMergeClampedEndpointsAndScaleFinalWeightedValues() throws {
  var plot = barPlot([10, 30, nil, 40, 20, 0])
  plot.time = .init(
    [-20.0, -10, 10, 20, 30, 40].map { Date(timeIntervalSince1970: $0) },
    intervals: Array(repeating: 2, count: 6),
    domain: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 20))
  plot.statistic = .average
  plot.firstWeights = [2, 3, 4, 5, 6, 7]
  plot.partialFirst = [false, true]
  plot.gapBuckets = [false, false, false, false, true]
  let layout = HistoryBarLayout(plot: plot, graphWidth: 5, scale: 1)
  #expect(layout.columns.map(\.slot) == [0, 1, 2])
  #expect(layout.columns.map(\.samples) == [2, 1, 3])
  #expect(layout.columns.map(\.firstIndex) == [0, 2, 3])
  #expect(layout.columns.map(\.lastIndex) == [1, 2, 5])
  #expect(layout.columns.map(\.firstWeight) == [5, 0, 18])
  #expect(layout.columns.map(\.firstMissing) == [true, true, false])
  #expect(layout.columns.map(\.gap) == [false, false, true])
  #expect(layout.columns[0].first == 22)
  #expect(layout.columns[1].first == nil)
  let last = try #require(layout.columns[2].first)
  #expect(abs(last - 320.0 / 18) < 1e-12)
  #expect(layout.hasData && layout.grouped && layout.maximum == 22)
  #expect(layout.columns.map { layout.x($0) } == [0, 2, 4])
}

@Test @MainActor func timelineRecoversFromResetsAndDisclosesCadenceWithoutInventingSamples() {
  func dates(_ values: [Double]) -> [Date] { values.map { Date(timeIntervalSince1970: $0) } }
  for (values, start, duration) in [
    ([10.0, 10, 20, 22], 1, 12.0), ([10.0, 1, 20, 22], 1, 21.0),
    ([10.0, .nan, 20, 22], 2, 2.0),
  ] {
    let timeline = HistoryTimeline(times: dates(values), intervals: [2, 2, 2, 2])
    #expect(timeline.reset && timeline.indices == start..<4)
    #expect(timeline.positions[start] == 0 && timeline.positions.last == 1)
    #expect(timeline.duration == duration)
  }
  let changed = HistoryTimeline(times: dates([0, 2, 12, 22]), intervals: [2, 2, 10, 10])
  #expect(changed.gaps.isEmpty && changed.cadence == 2...10)
  #expect(changed.cadenceDescription == "~2s–10s cadence")
  var paused = barPlot([10, 10, 10, 10])
  paused.time = .init(dates([0, 2, 102, 104]), intervals: [2, 2, 2, 2])
  #expect(paused.timeline.gaps.count == 1 && paused.timeline.span == "1m 44s")
  #expect(SummaryDashboardView.historySegments(paused).map(\.count) == [2, 2])
  #expect(HistoryTimeline(times: dates([0, .infinity])).indices.isEmpty)
  #expect(HistoryTimeline(times: []).positions.isEmpty)
  #expect(HistoryTimeline(times: dates([0, 598])).span == "9m 58s")
}

@Test @MainActor func nativeHistoryRendersSeparatedBarsWithoutConnectingOverlays() throws {
  let view = SummaryDashboardView(frame: NSRect(x: 0, y: 0, width: 520, height: 454))
  var snapshot = Snapshot()
  snapshot.upload = 100
  snapshot.download = 80
  snapshot.cpu = .init(usage: 60, cores: [60], load: [], user: 40, system: 20)
  let history = (0..<300).map { index in
    var sample = snapshot
    sample.timestamp = Date(timeIntervalSince1970: Double(index) * 2)
    sample.upload = index % 53 == 0 ? 1000 : index % 37 == 0 ? nil : Double(40 + index % 23)
    sample.download = index % 71 == 0 ? 900 : Double(70 + index % 29)
    var point = sample.historyPoint
    point.sampleInterval = 2
    return point
  }
  for scale in [1, 2] {
    for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      view.appearance = NSAppearance(named: appearance)
      for module in [Module.network, .cpu, .gpu, .memory, .disks, .battery] {
        view.update(snapshot, history: history, settings: Settings(), module: module)
        let bitmap = try #require(
          NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 520 * scale, pixelsHigh: 454 * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        if module == .network {
          // The history graph lies at x12...508, y75...146 (flipped coordinates).
          // A colored connecting line/area would paint the gaps between bars.
          let plot = try #require(
            view.cards.compactMap { card -> SummaryDashboardView.Plot? in
              if case .plot(let value) = card.content { return value }
              return nil
            }.first)
          let layout = HistoryBarLayout(plot: plot, graphWidth: 496, scale: CGFloat(scale))
          for column in layout.columns.dropLast() {
            let x = 12 * scale + Int(layout.x(column) * CGFloat(scale)) + layout.barPixels
            let color = try #require(
              bitmap.colorAt(x: x, y: 100 * scale)?.usingColorSpace(.deviceRGB))
            // In either appearance the empty graph/grid is neutral, never pink/blue.
            #expect(abs(color.redComponent - color.blueComponent) < 0.08)
          }
        }
        if module == .cpu {
          let plot = try #require(
            view.cards.compactMap { card -> SummaryDashboardView.Plot? in
              if case .plot(let value) = card.content { return value }
              return nil
            }.first)
          let layout = HistoryBarLayout(plot: plot, graphWidth: 496, scale: CGFloat(scale))
          let card = try #require(view.cards.first)
          let area = NSRect(
            x: card.frame.minX + 12, y: card.frame.minY + 31,
            width: card.frame.width - 24, height: card.frame.height - 37)
          let graph = SummaryDashboardView.plotGraphRect(plot, area: area)
          for column in layout.columns {
            let x = 12 * scale + Int(layout.x(column) * CGFloat(scale)) + layout.barPixels / 2
            // Test the actual series, in both halves, not just the neutral gaps.
            let user = try #require(
              bitmap.colorAt(x: x, y: Int((graph.maxY - graph.height * 0.2) * CGFloat(scale)))?
                .usingColorSpace(.deviceRGB))
            let system = try #require(
              bitmap.colorAt(x: x, y: Int((graph.maxY - graph.height * 0.5) * CGFloat(scale)))?
                .usingColorSpace(.deviceRGB))
            #expect(user.blueComponent > user.redComponent + 0.3)
            #expect(system.redComponent > system.blueComponent + 0.3)
          }
        }
        if let folder = ProcessInfo.processInfo.environment["TINYSTATS_CHART_CAPTURE_DIR"] {
          let url = URL(fileURLWithPath: folder).appendingPathComponent(
            "synthetic-\(module.rawValue)-\(theme)-\(scale)x.png")
          try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
      }
    }
  }
}

@Test @MainActor func preparedPlotTimeReplacementPreservesCopiesAndGapDomainSemantics() throws {
  func dates(_ values: [Double]) -> [Date] { values.map { Date(timeIntervalSince1970: $0) } }
  var samples = dates([0, 2, 102, 104])
  var intervals: [Double?] = [2, 2, 2, 2]
  var plot = barPlot([10, 20, 30, 40])
  plot.time = .init(samples, intervals: intervals)
  let copy = plot
  samples[0] = Date(timeIntervalSince1970: -100)
  intervals[0] = 500
  #expect(plot.times == dates([0, 2, 102, 104]))
  #expect(plot.timeline.cadence == 2...2)
  #expect(plot.timeline.gaps == [(3.0 / 104)...(101.0 / 104)])
  #expect(plot.xFractions == [0, 2.0 / 104, 102.0 / 104, 1])
  plot.time = .init(
    dates([10, 10, 20, 22]), intervals: [2, 2, 10, 10],
    domain: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 40))
  #expect(plot.times == dates([10, 10, 20, 22]))
  #expect(plot.timeline.reset && plot.timeline.indices == 1..<4)
  #expect(plot.timeline.cadence == 2...10 && plot.timeline.gaps.isEmpty)
  #expect(plot.duration == 40 && plot.xFractions == [nil, 0.25, 0.5, 0.55])
  #expect(copy.duration == 104 && copy.timeline.gaps.count == 1 && !copy.timeline.reset)
  for width: CGFloat in [1, 7.25, 496, 1200] {
    for scale: CGFloat in [1, 2] {
      let layout = HistoryBarLayout(plot: plot, graphWidth: width, scale: scale)
      #expect(layout.columns.reduce(0) { $0 + $1.samples } == 3)
      #expect(layout.columns.first?.firstIndex == 1 && layout.columns.last?.lastIndex == 3)
      #expect(layout.timeline.positions == [nil, 0.25, 0.5, 0.55])
    }
  }
  plot.time = .init([])
  #expect(plot.times.isEmpty && plot.xFractions.isEmpty)
  #expect(HistoryBarLayout(plot: plot, graphWidth: 496, scale: 2).columns.isEmpty)
  #expect(copy.times.count == 4 && copy.xFractions.last == 1)
}
