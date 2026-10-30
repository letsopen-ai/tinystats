import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func overviewPlattersKeepValuesSegmentsAndUnavailableStatesDistinct() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 564))
  var snapshot = Snapshot()
  view.update(snapshot, history: [], settings: Settings(), module: .overview)
  func tile(_ title: String) throws -> SummaryDashboardView.OverviewTile {
    let card = try #require(view.cards.first { $0.title == title })
    guard case .overviewTile(let tile) = card.content else {
      throw NSError(domain: "Expected overview tile", code: 1)
    }
    return tile
  }
  #expect(try tile("CPU").value.value == "—")
  #expect(try tile("GPU").value.value == "—")
  #expect(try tile("Memory").segments?.isEmpty == true)
  #expect(try tile("Startup disk").segments?.isEmpty == true)
  #expect(try tile("Disk read").value.value == "—")
  #expect(try tile("System power").value.value == "—")
  #expect(view.cards.first?.spoken.contains("Memory pressure: Unavailable") == true)
  snapshot.device = .init(
    model: "Model fixture", chip: "Chip fixture", operatingSystem: "macOS fixture")
  snapshot.cpu = .init(usage: 0, cores: [0], load: [], user: 0, system: 0)
  snapshot.memory = .init(
    total: 1000, active: 400, inactive: 300, wired: 200, compressed: 100,
    free: 100, speculative: 0, purgeable: 50, swapUsed: 0, swapTotal: 0, pressure: 1)
  snapshot.volumes = [
    .init(name: "External", path: "/Volumes/other", total: 9999, available: 1),
    .init(name: "Startup", path: "/", total: 1000, available: 400),
  ]
  snapshot.disks = [.init(id: 1, name: "Disk", read: 0, written: nil)]
  view.update(snapshot, history: [], settings: Settings(), module: .overview)
  #expect(try tile("CPU").value.value == "0%")
  #expect(try tile("Memory").segments?.compactMap(\.fraction) == [0.35, 0.2, 0.1])
  #expect(
    try tile("Memory").segments?.map(\.color) == [
      SystemStyle.accent, SystemStyle.secondaryAccent, SystemStyle.neutralSeries,
    ])
  #expect(try tile("Memory").composition.contains("available including cache 350 B"))
  #expect(try tile("Startup").segments?.first?.fraction == 0.6)
  #expect(try tile("Startup").value.value == "400 B")
  #expect(try tile("Swap used").value.value == "0 B")
  #expect(try tile("Disk read").value.value == Display.rate(0))
  #expect(try tile("Disk write").value.value == "—")
  let header = try #require(view.cards.first)
  #expect(header.spoken.contains("Model fixture") && header.spoken.contains("Chip fixture"))
  #expect(header.spoken.contains("Memory pressure: Normal"))
  let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
  #expect(children.count == 11)
  #expect(children[0].accessibilityValue() as? String == header.spoken)
  snapshot.memory?.total = 0
  view.update(snapshot, history: [], settings: Settings(), module: .overview)
  #expect(try tile("Memory").value.value == "—")
  #expect(try tile("Memory").segments?.isEmpty == true)
  #expect(children[0] === view.accessibilityChildren()?.first as? NSAccessibilityElement)
}

@Test @MainActor func overviewStateColoursAreSemanticAndUnknownStatesStayNeutral() {
  for (state, color) in [
    ("Nominal", SystemStyle.nominal), ("Fair", SystemStyle.warning),
    ("Serious", SystemStyle.warning), ("Critical", SystemStyle.critical),
    ("Unavailable", NSColor.secondaryLabelColor),
  ] {
    #expect(SummaryDashboardView.thermalColor(state) == color)
  }
  for (state, color) in [
    (1, SystemStyle.nominal), (2, SystemStyle.warning), (4, SystemStyle.critical),
    (0, NSColor.secondaryLabelColor),
  ] {
    #expect(SummaryDashboardView.pressureColor(state) == color)
  }
  #expect(SummaryDashboardView.pressureColor(nil) == .secondaryLabelColor)
}

@Test @MainActor func overviewNetworkUsesFiveMinutesAndPreservesGapsZeroAndBothHoverSeries() throws
{
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 704, height: 564))
  var snapshot = Snapshot()
  let history = (0..<450).map { index in
    var point = snapshot.historyPoint
    point.time = Date(timeIntervalSince1970: Double(index * 2))
    point.sampleInterval = 2
    point.download = index == 400 ? nil : Double(index)
    point.upload = index == 401 ? 0 : Double(index * 2)
    return point
  }
  snapshot.download = 449
  snapshot.upload = 898
  view.update(snapshot, history: history, settings: Settings(), module: .overview)
  let card = try #require(view.cards.first { $0.title == "NETWORK" })
  guard case .plot(let plot) = card.content else {
    Issue.record("Expected network plot")
    return
  }
  #expect(plot.domain == Date(timeIntervalSince1970: 598)...Date(timeIntervalSince1970: 898))
  #expect(plot.times.count == 151 && plot.first.count == 151 && plot.second.count == 151)
  #expect(plot.first[101] == nil && plot.second[102] == 0)
  #expect(plot.firstColor == SystemStyle.accent && plot.secondColor == SystemStyle.secondaryAccent)
  #expect(plot.drawsTrace && !plot.mirrored)
  let segments = SummaryDashboardView.historySegments(plot)
  #expect(segments.count == 2)
  let graph = SummaryDashboardView.overviewNetworkGraph(in: card.frame)
  let hover = try #require(view.hoverText(at: .init(x: graph.maxX - 0.1, y: graph.midY)))
  #expect(
    hover.contains("Download: " + Display.rate(449))
      && hover.contains("Upload: " + Display.rate(898)))
  #expect(card.spoken.contains("Traces break at unavailable"))
  view.update(snapshot, history: [history.last!], settings: Settings(), module: .overview)
  #expect(
    view.hoverText(at: .init(x: graph.minX + 1, y: graph.midY)) == "No recorded observations here")
  #expect(
    view.hoverText(at: .init(x: graph.maxX - 0.1, y: graph.midY))?.contains("Upload:") == true)
}

@Test @MainActor func overviewResizingKeepsPlattersSeparateAndNavigationRestoresModuleCharts()
  throws
{
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(Snapshot(), history: [], settings: Settings(), module: .overview)
  for size in [
    NSSize(width: 520, height: 454), .init(width: 704, height: 564),
    .init(width: 1020, height: 754),
  ] {
    view.setFrameSize(size)
    #expect(view.contentScale == 1 && view.cards.count == 11)
    for (index, card) in view.cards.enumerated() {
      #expect(view.bounds.insetBy(dx: -0.01, dy: -0.01).contains(card.frame))
      for other in view.cards.dropFirst(index + 1) { #expect(!card.frame.intersects(other.frame)) }
    }
  }
  view.update(Snapshot(), history: [], settings: Settings(), module: .cpu)
  #expect(!view.usesOverviewLayout && view.contentScale > 1)
  view.update(Snapshot(), history: [], settings: Settings(), module: .overview)
  #expect(view.usesOverviewLayout && view.contentScale == 1)
}
