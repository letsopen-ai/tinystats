import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func summaryHistory(_ seconds: Double) -> HistoryPoint {
  var s = Snapshot()
  s.timestamp = Date(timeIntervalSince1970: seconds)
  s.cpu = .init(usage: 50, cores: [50], load: [], user: 30, system: 20)
  return s.historyPoint
}

@Test @MainActor func networkSummaryDescribesMissingPrimaryRoute() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  var snapshot = Snapshot()
  view.update(snapshot, history: [], settings: Settings(), module: .network)
  #expect(try #require(view.cards.first { $0.title == "NETWORK" }).trailing == "No primary route")
  snapshot.selectedInterface = "en0"
  view.update(snapshot, history: [], settings: Settings(), module: .network)
  #expect(try #require(view.cards.first { $0.title == "NETWORK" }).trailing == "en0")
}

@Test @MainActor func compactCPUHistoryKeepsItsComponentsAndRealElapsedSpacing() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(
    Snapshot(), history: [summaryHistory(0), summaryHistory(1), summaryHistory(10)],
    settings: Settings(), module: .cpu)
  guard case .plot(let plot) = try #require(view.cards.first).content else {
    Issue.record("Expected CPU history")
    return
  }
  #expect(plot.first == [30, 30, 30] && plot.second == [20, 20, 20])
  #expect(plot.firstLabel == "User" && plot.secondLabel == "System")
  #expect(plot.xFractions == [0, 0.1, 1])
  var backwards = plot
  backwards.time = .init([Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 1)])
  #expect(backwards.xFractions == [nil, 1])
}

@Test @MainActor func gpuCardsKeepDeviceIdentityAndSeparateModelPowerFromRails() throws {
  var s = Snapshot()
  s.gpus = [
    .init(name: "Idle", usage: 10, memory: 1, coreCount: 2, rendererUsage: 5, tilerUsage: 3),
    .init(name: "Busy", usage: 70, memory: 99, coreCount: 8, rendererUsage: 60, tilerUsage: 50),
  ]
  s.sensors = [.init(key: "PGTR", name: "GPU rail", kind: .power, value: 90)]
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(s, history: [], settings: Settings(), module: .gpu)
  let spoken = view.cards.map(\.spoken).joined(separator: "\n")
  #expect(spoken.contains("Highest GPU: 70%") && spoken.contains("Shown device: Busy"))
  #expect(spoken.contains("Allocated memory: 99 B") && spoken.contains("8 GPU cores"))
  #expect(!spoken.contains("90 W"))
  s.sensors.append(.init(key: "ioreport:gpu", name: "GPU model power", kind: .power, value: 4))
  view.update(s, history: [], settings: Settings(), module: .battery)
  #expect(view.cards.map(\.spoken).joined().contains("GPU model power: 4.00 W"))
  #expect(view.cards.map(\.spoken).joined().contains("GPU rail: 90.00 W"))
}

@Test @MainActor func gpuProcessTimeCardsKeepUnitsMissingZeroAndResponsiveGeometry() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  var snapshot = Snapshot()
  snapshot.gpus = [
    .init(
      name: "GPU fixture", usage: 63, memory: 268_435_456, coreCount: 10, rendererUsage: 58,
      tilerUsage: 21)
  ]
  snapshot.sensors = [.init(key: "TG0D", name: "GPU", kind: .temperature, value: 73)]
  snapshot.sensors.append(.init(key: "F0Ac", name: "GPU fan", kind: .fan, value: 1200))
  snapshot.frequencies = [.init(name: "GPU", megahertz: 650)]
  let history = (0..<60).map { index in
    var sample = snapshot
    sample.timestamp = Date(timeIntervalSince1970: Double(index * 2))
    sample.gpus[0].usage = Double(35 + (index * 7) % 40)
    return sample.historyPoint
  }
  snapshot.gpuTime.status = .incomplete
  snapshot.gpuTime.rows = [
    .init(pid: 12, name: "Shader", millisecondsPerSecond: 2500),
    .init(pid: 13, name: "Shader", millisecondsPerSecond: 0),
    .init(pid: 14, name: "Other", millisecondsPerSecond: nil),
  ]
  for size in [NSSize(width: 520, height: 454), NSSize(width: 1040, height: 900)] {
    view.setFrameSize(size)
    view.update(snapshot, history: history, settings: Settings(), module: .gpu)
    #expect(view.cards.allSatisfy { view.bounds.contains($0.frame) })
    for a in view.cards.indices {
      for b in view.cards.indices where a < b {
        #expect(!view.cards[a].frame.intersects(view.cards[b].frame))
      }
    }
    let card = try #require(view.cards.first { $0.title == "METAL GPU TIME" })
    guard case .rows(let rows) = card.content else {
      Issue.record("Expected GPU time rows")
      return
    }
    #expect(rows.map(\.label) == ["Shader (12)", "Shader (13)", "Other"])
    #expect(rows.map(\.value) == ["2500 ms/s", "0.0 ms/s", "—"])
    #expect(rows.map(\.fraction) == [1, 0, nil])
    #expect(card.spoken.contains("2500.0 milliseconds of GPU time per second"))
    #expect(!card.spoken.contains(GPUProcessTimeSnapshot.explanation))
    let element = try #require(
      view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first {
        $0.accessibilityLabel() == "METAL GPU TIME"
      })
    #expect(element.accessibilityHelp() == GPUProcessTimeSnapshot.explanation)
    #expect(element.accessibilityHelp()?.contains("Inaccessible owners are omitted") == true)
    #expect(
      card.note.contains("Creating process") && card.note.contains("bars relative to largest"))
    #expect(
      view.cards.map(\.spoken).joined().localizedCaseInsensitiveContains(
        "usage per GPU core is not available"))
    #expect(view.accessibilityChildren()?.count == view.cards.count)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      view.appearance = NSAppearance(named: name)
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      if let directory = ProcessInfo.processInfo.environment["TINYSTATS_GPU_TIME_RENDER_PATH"] {
        let path = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: path.appendingPathComponent(
            "gpu-time-\(name.rawValue)-\(Int(size.width))x\(Int(size.height)).png"))
      }
    }
  }
}

@Test @MainActor func compactCardsFitAndExposeMissingCoresWithoutExtraViewTrees() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  var s = Snapshot()
  s.cpu = .init(usage: 0, cores: [nil], load: [], coreKinds: [.efficiency])
  for module in Module.allCases where SummaryDashboardView.supports(module) {
    view.update(s, history: [], settings: Settings(), module: module)
    #expect(view.cards.allSatisfy { view.bounds.contains($0.frame) })
    #expect(view.subviews.isEmpty && view.cards.count <= 6)
    #expect(view.accessibilityChildren()?.count == view.cards.count)
  }
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    view.appearance = NSAppearance(named: appearance)
    func pixels(_ reading: Double?) throws -> Data {
      s.cpu?.cores = [reading]
      view.update(s, history: [], settings: Settings(), module: .cpu)
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    let missing = try pixels(nil)
    let idle = try pixels(0)
    #expect(missing != idle)
    #expect(view.cards.map(\.spoken).joined().contains("Logical core 1, Efficiency: 0%"))
  }
  s.cpu = .init(
    usage: 0, cores: Array(repeating: 0, count: 128), load: [],
    coreKinds: Array(repeating: .performance, count: 128))
  view.update(s, history: [], settings: Settings(), module: .cpu)
  #expect(SummaryDashboardView.displayedCoreIndices(try #require(s.cpu)).count == 24)
}

@Test @MainActor func detailSummaryDefaultsAndAllReadingsRemainNativeAndReversible() throws {
  let detail = DetailController()
  detail.selected = .cpu
  let root = detail.view
  let summary = try #require(root.subviews.compactMap { $0 as? SummaryDashboardView }.first)
  let scroll = try #require(root.subviews.compactMap { $0 as? NSScrollView }.first)
  let button = try #require(
    root.subviews.compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel() == "Show all readings"
    })
  #expect(!summary.isHidden && scroll.isHidden)
  #expect(
    NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button))
  #expect(summary.isHidden && !scroll.isHidden && detail.showsAllReadings)
  #expect(
    NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button))
  #expect(!summary.isHidden && scroll.isHidden && !detail.showsAllReadings)
  detail.selected = .clock
  #expect(summary.isHidden && !button.isHidden && button.title == "Calendar…" && !scroll.isHidden)
}

@Test @MainActor func summaryAccessibilityChildrenStayStableWithoutRetainingTheirView() throws {
  var owner: SummaryDashboardView? = SummaryDashboardView(
    frame: .init(x: 0, y: 0, width: 520, height: 454))
  weak var observed: SummaryDashboardView?
  observed = owner
  owner?.update(Snapshot(), history: [], settings: Settings(), module: .cpu)
  let child = try #require(owner?.accessibilityChildren()?.first as? NSAccessibilityElement)
  #expect(child.isAccessibilityElement())
  owner?.update(Snapshot(), history: [], settings: Settings(), module: .cpu)
  #expect(child === owner?.accessibilityChildren()?.first as? NSAccessibilityElement)
  owner = nil
  #expect(observed == nil && child.accessibilityParent() == nil)
}

@Test @MainActor func coolingCardsShowTemperatureAndFanSpeedWithHonestOwnership() throws {
  var s = Snapshot()
  s.sensors = [
    .init(key: "Tp01", name: "CPU", kind: .temperature, value: 60),
    .init(key: "Tg01", name: "GPU", kind: .temperature, value: 70),
    .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 2200),
  ]
  var settings = Settings()
  settings.fahrenheit = true
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  for (module, temperature) in [(Module.cpu, "140°F"), (.gpu, "158°F")] {
    view.update(s, history: [], settings: settings, module: module)
    let card = try #require(view.cards.first { $0.title.contains("COOLING") })
    #expect(card.spoken.contains(temperature) && card.spoken.contains("2200 rpm"))
    #expect(card.note.contains("Shared / unassigned"))
    s.sensors[2].value = 0
    view.update(s, history: [], settings: settings, module: module)
    #expect(view.cards.first { $0.title.contains("COOLING") }?.spoken.contains("0 rpm") == true)
    s.sensors[2].value = 2200
  }
  #expect(!SummaryDashboardView.supports(.sensors))
}

@Test @MainActor func overviewAlwaysUsesSummaryAfterAnotherPagesAllReadings() throws {
  let detail = DetailController()
  detail.selected = .cpu
  _ = detail.view
  detail.showsAllReadings = true
  detail.selected = .overview
  let summary = try #require(detail.view.subviews.compactMap { $0 as? SummaryDashboardView }.first)
  let scroll = try #require(detail.view.subviews.compactMap { $0 as? NSScrollView }.first)
  let toggle = try #require(
    detail.view.subviews.compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel() == "Show summary"
    })
  #expect(!summary.isHidden && scroll.isHidden && toggle.isHidden)
  detail.selected = .cpu
  #expect(summary.isHidden && !scroll.isHidden && !toggle.isHidden)
}

@Test @MainActor func comparisonBarsShareOneFiniteScaleWithoutInventingMissingRates() {
  let values: [Double?] = [nil, -1, .nan, .infinity, 0, 20, 80]
  let fractions = SummaryDashboardView.relativeFractions(values)
  #expect(fractions.prefix(4).allSatisfy { $0 == nil })
  #expect(Array(fractions.suffix(3)) == [0, 0.25, 1])
  #expect(SummaryDashboardView.relativeFractions([0, nil, 0]) == [0, nil, 0])
  #expect(SummaryDashboardView.relativeFractions([.greatestFiniteMagnitude, 1])[0] == 1)
}

@Test @MainActor func miniChartsPreserveActualTimeGapsAndUnavailableSegments() throws {
  let dates = [0.0, 1, 2, 8, 10].map { Date(timeIntervalSince1970: $0) }
  var plot = SummaryDashboardView.Plot(
    first: [0, 50, nil, 25, 100], second: [], firstLabel: "CPU", secondLabel: "",
    firstValue: "100%", secondValue: "", percent: true, mirrored: false,
    time: .init(dates))
  let segments = SummaryDashboardView.historySegments(plot)
  #expect(segments.count == 2)
  #expect(segments[0] == [NSPoint(x: 0, y: 0), NSPoint(x: 0.1, y: 0.5)])
  #expect(segments[1] == [NSPoint(x: 0.8, y: 0.25), NSPoint(x: 1, y: 1)])
  #expect(SummaryDashboardView.historySegments(plot, upperBound: 200)[1].last?.y == 0.5)
  #expect(SummaryDashboardView.historySegments(plot, upperBound: .nan).isEmpty)
  plot.first = [.nan, .infinity, -1, nil, 0]
  #expect(SummaryDashboardView.historySegments(plot) == [[NSPoint(x: 1, y: 0)]])
  plot.time = .init(Array(plot.times.reversed()))
  #expect(SummaryDashboardView.historySegments(plot) == [[NSPoint(x: 1, y: 0)]])
}

@Test @MainActor func graphicalTilesKeepOverlappingMemoryCategoriesSeparateAndHistoryBounded()
  throws
{
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  var s = Snapshot()
  s.memory = .init(
    total: 1000, active: 400, inactive: 300, wired: 200, compressed: 100,
    free: 100, speculative: 0, purgeable: 50, swapUsed: 0, swapTotal: 0, pressure: 1)
  let history = (0..<200).map { summaryHistory(Double($0)) }
  view.update(s, history: history, settings: Settings(), module: .memory)
  let physical = try #require(view.cards.first { $0.title == "PHYSICAL MEMORY" })
  guard case .memory(let memory) = physical.content else {
    Issue.record("Expected one reconciled memory composition")
    return
  }
  let c = memory.composition
  #expect(c.app == 350 && c.wired == 200 && c.compressed == 100 && c.available == 350)
  #expect(c.app + c.wired + c.compressed + c.available == memory.total)
  #expect(physical.spoken.contains("App estimate") && physical.spoken.contains("including cache"))
  view.update(s, history: history, settings: Settings(), module: .overview)
  guard case .tiles(let tiles, _) = try #require(view.cards.first).content else {
    Issue.record("Expected overview charts")
    return
  }
  #expect(tiles.count == 4)
  #expect(tiles.allSatisfy { $0.trend?.first.count == 90 && $0.trend?.times.count == 90 })
  #expect(tiles.first?.trend?.times.first == history[110].time)
  #expect(view.subviews.isEmpty)
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    view.appearance = NSAppearance(named: appearance)
    for module in [Module.overview, .memory, .gpu, .sensors, .disks, .network, .battery] {
      view.update(s, history: history, settings: Settings(), module: module)
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    }
  }
}

@Test @MainActor func memoryProcessBarsCompareFootprintsWhileCategoryMetersUseTotalRAM() throws {
  var s = Snapshot()
  s.memory = .init(
    total: 1000, active: 400, inactive: 300, wired: 200, compressed: 100,
    free: 100, speculative: 0, purgeable: 50, swapUsed: 0, swapTotal: 0, pressure: 1)
  s.processes = [
    .init(pid: 1, name: "First", cpu: nil, memory: 200, read: nil, written: nil),
    .init(pid: 2, name: "Second", cpu: nil, memory: 100, read: nil, written: nil),
  ]
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  view.update(s, history: [], settings: Settings(), module: .memory)
  let card = try #require(view.cards.first { $0.title == "TOP PROCESSES" })
  guard case .rows(let processes) = card.content else {
    Issue.record("Expected processes")
    return
  }
  #expect(processes.map(\.fraction) == [1, 0.5])
  #expect(card.spoken.contains("Memory · bars relative to largest"))
}

@Test @MainActor func denseHistoryUsesAllRetainedSamplesWithThinSeparatedBars() throws {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  let history = (0..<450).map { index in
    var point = summaryHistory(Double(index) * 2)
    point.upload = index == 300 ? nil : Double(index % 23)
    point.download = Double(index % 47)
    return point
  }
  for module in [Module.overview, .cpu, .gpu, .disks, .network] {
    view.update(Snapshot(), history: history, settings: Settings(), module: module)
    let plots = view.cards.compactMap { card -> SummaryDashboardView.Plot? in
      if case .plot(let plot) = card.content { return plot }
      return nil
    }
    #expect(!plots.isEmpty)
    for plot in plots {
      #expect(plot.times.count == 300 && plot.first.count == 300)
      #expect(plot.times.first == history[150].time && plot.times.last == history[449].time)
      let layout = HistoryBarLayout(plot: plot, graphWidth: 496, scale: 2)
      let width = layout.barWidth
      #expect(layout.columns.count == 300)
      #expect(width > 0 && width < 1.3)
      let positions = plot.xFractions.compactMap { $0 }
      #expect(
        zip(positions, positions.dropFirst()).allSatisfy {
          ($1 - $0) * (496 - width) > width
        })
      if plot.firstLabel == "Upload" { #expect(plot.first[150] == nil) }
    }
  }
}

@Test @MainActor func disabledInvalidPingDraftDoesNotLeaveAConfigurationRowInNetworkSummary() {
  let view = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  var settings = Settings()
  settings.pingCheck = .init(enabled: false, destination: "router.local")
  #expect(settings.pingCheck.validationError != nil)
  var snapshot = Snapshot()
  snapshot.internetChecks.ping = .init(milliseconds: 1, checkedAt: 0, reason: "Echo reply")
  view.update(snapshot, history: [], settings: settings, module: .network)
  let spoken = view.cards.map(\.spoken).joined(separator: "\n")
  #expect(!spoken.contains("Ping ") && !spoken.contains("Configuration needed"))
  settings.pingCheck.enabled = true
  view.update(snapshot, history: [], settings: settings, module: .network)
  #expect(view.cards.map(\.spoken).joined().contains("Configuration needed"))
}
