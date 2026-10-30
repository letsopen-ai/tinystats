import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func chartAccessibilitySummarizesEachSeriesAndTracksReplacementAndUnits() {
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 302, height: 100))
  #expect(chart.accessibilityRole() == .image)
  #expect(chart.accessibilityLabel() == "Metric history chart")
  #expect(chart.accessibilityValue() as? String == "No readings yet")
  chart.times = [epoch, epoch + 2, epoch + 4]
  chart.valueFormat = .rate
  chart.series = [
    .init(name: "Download", color: .systemBlue, values: [0, 2048, 1024]),
    .init(name: "Upload", color: .systemPink, values: [4096, 0, nil]),
  ]
  #expect(
    chart.accessibilityValue() as? String
      == "Download: Latest 1.0 KiB/s, min 0 B/s, max 2.0 KiB/s; Upload: Latest Unavailable, min 0 B/s, max 4.0 KiB/s; window 4s"
  )
  chart.series = [.init(name: "Temperature", color: .systemOrange, values: [-10, 0, 20])]
  chart.valueFormat = .temperature(fahrenheit: true)
  #expect(
    chart.accessibilityValue() as? String
      == "Temperature: Latest 68.0°F, min 14.0°F, max 68.0°F; window 4s")
  chart.valueFormat = .temperature(fahrenheit: false)
  #expect(
    chart.accessibilityValue() as? String
      == "Temperature: Latest 20.0°C, min -10.0°C, max 20.0°C; window 4s")
  chart.series = []
  chart.emptyMessage = "No sensor readings to chart"
  #expect(chart.accessibilityValue() as? String == "No sensor readings to chart")
}

@Test @MainActor func chartAccessibilityUsesOnlyDrawnTimelineAndNeverInventsMissingValues() {
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  let chart = ChartView(frame: .zero)
  chart.times = [epoch, epoch + 2, epoch + 1, epoch + 3]
  chart.series = [.init(name: "CPU", color: .systemBlue, values: [100, 90, 0, 20, 999])]
  #expect(
    chart.accessibilityValue() as? String == "CPU: Latest 20.0%, min 0.0%, max 20.0%; window 2s")
  // Changing only the time window must immediately change AXValue too.
  chart.times = [epoch, epoch + 2]
  #expect(
    chart.accessibilityValue() as? String == "CPU: Latest 90.0%, min 90.0%, max 100.0%; window 2s")
  chart.times = (0..<301).map { epoch + Double($0) }
  chart.series = [
    .init(name: "CPU", color: .systemBlue, values: [100] + Array(repeating: 0, count: 300))
  ]
  #expect(
    chart.accessibilityValue() as? String == "CPU: Latest 0.0%, min 0.0%, max 0.0%; window 4m 59s")
  chart.times = [epoch, epoch + 2, epoch + 4]
  chart.series[0].values = [10]  // A short series has a missing newest observation.
  #expect(
    chart.accessibilityValue() as? String
      == "CPU: Latest Unavailable, min 10.0%, max 10.0%; window 4s")
  chart.series[0].values = [.nan, .infinity, -.infinity]
  #expect(
    chart.accessibilityValue() as? String
      == "No readings yet")
  chart.times = []
  chart.series[0].values = [50]
  #expect(
    chart.accessibilityValue() as? String
      == "No readings yet")
  chart.times = [epoch, epoch + 1, epoch, epoch + 1]
  chart.series[0].values = [100, 90, nil, nil]
  #expect(chart.accessibilityValue() as? String == "No readings yet")
}

@Test @MainActor func chartAccessibilityEmptyOverviewMatchesDrawnMessage() throws {
  let presentation = try #require(
    DetailReadingsBuilder.build(
      module: .overview, snapshot: Snapshot(), history: [], settings: Settings(), paused: false))
  let chart = ChartView(frame: .zero)
  chart.series = presentation.series
  #expect(!chart.series.isEmpty && chart.times.isEmpty)
  #expect(chart.accessibilityValue() as? String == chart.emptyMessage)
}

@Test @MainActor func chartAccessibilityIncludesKnownWindowAndKeepsUnavailableSeriesDistinct() {
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  let chart = ChartView(frame: .zero)
  chart.series = [
    .init(name: "CPU", color: .systemBlue, values: [10, 20]),
    .init(name: "GPU", color: .systemTeal, values: [nil, .nan]),
  ]
  for (duration, span) in [(60.0, "1m 0s"), (3600, "1h 0m")] {
    chart.times = [epoch, epoch + duration]
    #expect(
      chart.accessibilityValue() as? String
        == "CPU: Latest 20.0%, min 10.0%, max 20.0%; GPU: No recorded values in this window; window \(span)"
    )
  }
  chart.times = [epoch]
  #expect(
    chart.accessibilityValue() as? String
      == "CPU: Latest 10.0%, min 10.0%, max 10.0%; GPU: No recorded values in this window")
}

@Test @MainActor func historyAccessibilityTracksRangeStatisticAndBothRateSeries() throws {
  var archive = SessionHistory()
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  // The first two observations share a bucket; the oldest is outside ten minutes.
  for (offset, rate) in [(0.0, 8192.0), (1200, 1024), (1200.5, 3072), (1204, 0)] {
    var point = Snapshot().historyPoint
    point.time = epoch + offset
    point.sampleInterval = 1
    point.upload = rate
    point.download = rate * 2
    archive.append(point, uptime: offset + 1)
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 275))
  func spoken() throws -> String {
    let element = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
    return try #require(element.accessibilityValue() as? String)
  }
  view.updateHistory(archive.projection(.tenMinutes), module: .network, fahrenheit: false)
  let peak = try spoken()
  #expect(
    peak.contains(
      "recorded buckets in visible window: Newest recorded 0 B/s, min 0 B/s, max 3.0 KiB/s"))
  #expect(
    peak.contains(
      "recorded buckets in visible window: Newest recorded 0 B/s, min 0 B/s, max 6.0 KiB/s"))
  view.updateHistory(
    archive.projection(.tenMinutes), module: .network, fahrenheit: false, statistic: .average)
  let average = try spoken()
  #expect(
    average.contains(
      "recorded buckets in visible window: Newest recorded 0 B/s, min 0 B/s, max 2.0 KiB/s"))
  #expect(
    average.contains(
      "recorded buckets in visible window: Newest recorded 0 B/s, min 0 B/s, max 4.0 KiB/s"))
  view.updateHistory(
    archive.projection(.tenMinutes), module: .network, fahrenheit: false, statistic: .minimum)
  #expect(
    try spoken().contains(
      "recorded buckets in visible window: Newest recorded 0 B/s, min 0 B/s, max 1.0 KiB/s"))
  view.updateHistory(archive.projection(.hour), module: .network, fahrenheit: false)
  #expect(try spoken().contains("max 8.0 KiB/s"))
}

@Test @MainActor func summaryMiniChartAccessibilityUsesOnlyItsNinetyVisibleSamples() throws {
  let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  var snapshot = Snapshot()
  var history: [HistoryPoint] = []
  for index in 0..<91 {
    snapshot.timestamp = epoch + Double(index * 2)
    snapshot.cpu = .init(usage: index == 0 ? 99 : 20, cores: [], load: [])
    history.append(snapshot.historyPoint)
  }
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(snapshot, history: history, settings: Settings(), module: .overview)
  let element = try #require(
    view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first {
      ($0.accessibilityValue() as? String)?.contains("recent trend history") == true
    })
  #expect(
    (element.accessibilityValue() as? String)?.contains(
      "Newest recorded 20.0%, min 20.0%, max 20.0%")
      == true)
  let tiles = view.cards.filter {
    if case .overviewTile = $0.content { return true }
    return false
  }.map(\.spoken).joined(separator: "\n")
  for label in ["GPU", "Disk read", "Disk write"] {
    #expect(tiles.contains("\(label):"))
  }
  #expect(tiles.components(separatedBy: "No recorded values in this window").count - 1 == 3)
  #expect(!tiles.contains("min Unavailable"))
}
