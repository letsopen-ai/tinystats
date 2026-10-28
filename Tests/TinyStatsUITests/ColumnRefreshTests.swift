import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private final class RecordingColumn: NSTableColumn {
  private(set) var widthChanges: [CGFloat] = []
  override var width: CGFloat {
    get { super.width }
    set {
      let old = super.width
      super.width = newValue
      if super.width != old { widthChanges.append(super.width) }
    }
  }
  func resetRecording() { widthChanges.removeAll(keepingCapacity: true) }
}

@Test @MainActor func liveUpdatesDoNotCollapseAndReexpandResizedTableColumns() throws {
  _ = NSApplication.shared
  func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
  }
  for module in [Module.cpu, .network, .disks] {
    for allReadings in [false, true] {
      let window = MainWindow()
      let detail = DetailController()
      window.contentViewController = detail
      defer { window.close() }
      detail.selected = module
      detail.showsAllReadings = allReadings
      let table = try #require(tables(in: detail.view).first)
      var columns: [RecordingColumn] = []
      for original in table.tableColumns {
        let column = RecordingColumn(identifier: original.identifier)
        column.minWidth = original.minWidth
        column.maxWidth = original.maxWidth
        column.resizingMask = original.resizingMask
        column.width = original.width
        table.removeTableColumn(original)
        table.addTableColumn(column)
        columns.append(column)
      }
      var previousLabelWidth: CGFloat = 0
      for size in [
        NSSize(width: 884, height: 660), .init(width: 1200, height: 850),
        .init(width: 1920, height: 1000), .init(width: 3200, height: 1000),
      ] {
        window.setContentSize(size)
        detail.view.layoutSubtreeIfNeeded()
        let expected = columns.map(\.width)
        #expect(expected.count == 2 && expected[0] > (module == .network ? 240 : 280))
        #expect(expected[0] > previousLabelWidth)
        previousLabelWidth = expected[0]
        for column in columns { column.resetRecording() }
        for index in 0..<5 {
          var snapshot = Snapshot()
          snapshot.uptime = Double(index + 1)
          detail.update(snapshot, history: [])
          detail.view.layoutSubtreeIfNeeded()
          #expect(columns.map(\.width) == expected)
        }
        #expect(
          columns.allSatisfy { $0.widthChanges.isEmpty },
          "Steady \(module) samples at \(size.width)pt (all readings: \(allReadings)) resized columns: \(columns.map(\.widthChanges))"
        )
      }
    }
  }
}

@MainActor private final class FrameChanges {
  var count = 0
}

@Test @MainActor func steadySamplesDoNotResetResponsiveContentFrames() {
  _ = NSApplication.shared
  for module in Module.allCases {
    let window = MainWindow()
    let detail = DetailController()
    window.contentViewController = detail
    window.setContentSize(.init(width: 1200, height: 850))
    detail.selected = module
    detail.view.layoutSubtreeIfNeeded()
    let views = detail.view.subviews
    let expected = views.map(\.frame)
    let recorder = FrameChanges()
    for view in views { view.postsFrameChangedNotifications = true }
    let observers = views.map { view in
      NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: view, queue: .main
      ) { [weak recorder] _ in
        MainActor.assumeIsolated { recorder?.count += 1 }
      }
    }
    for index in 0..<5 {
      var snapshot = Snapshot()
      snapshot.uptime = Double(index + 1)
      detail.update(snapshot, history: [])
      detail.view.layoutSubtreeIfNeeded()
      #expect(views.map(\.frame) == expected)
    }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    #expect(
      recorder.count == 0, "Steady \(module) refreshes reset \(recorder.count) frames")
    window.close()
  }
}

@Test @MainActor func originalColumnsFollowPageAndForecastTransitionsAtResizedWidth() throws {
  _ = NSApplication.shared
  let window = MainWindow()
  let detail = DetailController()
  window.contentViewController = detail
  defer { window.close() }
  window.setContentSize(.init(width: 1200, height: 850))
  detail.showsAllReadings = true
  let root = detail.view
  let scroll = try #require(root.subviews.compactMap { $0 as? NSScrollView }.first)
  let table = try #require(scroll.documentView as? NSTableView)
  let chart = try #require(root.subviews.compactMap { $0 as? ChartView }.first)
  func checkSteady(_ snapshot: Snapshot) {
    let views = root.subviews
    let expected = views.map(\.frame)
    let widths = table.tableColumns.map(\.width)
    let recorder = FrameChanges()
    for view in views { view.postsFrameChangedNotifications = true }
    let observers = views.map { view in
      NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: view, queue: .main
      ) { [weak recorder] _ in
        MainActor.assumeIsolated { recorder?.count += 1 }
      }
    }
    for _ in 0..<5 {
      detail.update(snapshot, history: [])
      root.layoutSubtreeIfNeeded()
      #expect(views.map(\.frame) == expected && table.tableColumns.map(\.width) == widths)
    }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    #expect(recorder.count == 0)
  }
  var snapshot = Snapshot()
  snapshot.processes = [
    .init(
      pid: 101, name: "Geometry fixture", cpu: 12, memory: 4_096, read: 1_024,
      written: 2_048)
  ]
  detail.selected = .cpu
  detail.update(snapshot, history: [])
  root.layoutSubtreeIfNeeded()
  let cpuWidth = try #require(table.tableColumns.first?.width)
  checkSteady(snapshot)
  detail.selected = .network
  root.layoutSubtreeIfNeeded()
  #expect(try #require(table.tableColumns.first?.width) < cpuWidth)
  checkSteady(snapshot)
  detail.settings.weather = .currentLocationDefault
  detail.selected = .weather
  root.layoutSubtreeIfNeeded()
  #expect(table.tableColumns.first?.width == cpuWidth && chart.isHidden)
  let setupHeight = scroll.frame.height
  checkSteady(snapshot)
  detail.settings.weather.source = .manual
  detail.settings.weather.location = .init(
    latitude: 60, longitude: 10, name: "Geometry example", timeZone: "Europe/Oslo")
  detail.settings.weather.revision = "geometry-fixture"
  snapshot.timestamp = Date(timeIntervalSince1970: 1_792_670_400)
  snapshot.uptime = 10
  snapshot.weather.settings = detail.settings.weather
  snapshot.weather.receivedAt = 5
  snapshot.weather.reason = "Fixture forecast"
  snapshot.weather.forecast = .init(
    generatedAt: snapshot.timestamp,
    points: (0..<3).map {
      .init(
        date: snapshot.timestamp.addingTimeInterval(Double($0) * 3600), celsius: Double($0) + 12,
        humidity: 50, windMetersPerSecond: 2, symbol: "clearsky_day", precipitationMM: 0,
        periodHours: 1)
    })
  detail.update(snapshot, history: [])
  root.layoutSubtreeIfNeeded()
  #expect(!chart.isHidden && scroll.frame.height < setupHeight)
  #expect(scroll.frame.maxY + 10 <= chart.frame.minY)
  checkSteady(snapshot)
  snapshot.uptime = 11_000
  detail.update(snapshot, history: [])
  root.layoutSubtreeIfNeeded()
  #expect(chart.isHidden && scroll.frame.height == setupHeight)
  checkSteady(snapshot)
}
