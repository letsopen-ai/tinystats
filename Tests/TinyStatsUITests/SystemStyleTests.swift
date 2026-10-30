import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func systemDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + systemDescendants($0) }
}

@Test @MainActor func systemAccentTintsResolveInBothAppearancesAndKeepCoreClassification() throws {
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    let appearance = try #require(NSAppearance(named: name))
    appearance.performAsCurrentDrawingAppearance {
      let accent = SystemStyle.accent.usingColorSpace(.sRGB)
      let tint = SystemStyle.secondaryAccent.usingColorSpace(.sRGB)
      #expect(accent?.redComponent == tint?.redComponent)
      #expect(accent?.greenComponent == tint?.greenComponent)
      #expect(accent?.blueComponent == tint?.blueComponent)
      #expect(tint?.alphaComponent == (name == .darkAqua ? 0.5 : 0.45))
      #expect(CPUCoreKind.efficiency.chartColor == SystemStyle.secondaryAccent)
      #expect(CPUCoreKind.performance.chartColor == SystemStyle.accent)
      #expect(CPUCoreKind.unknown.chartColor == .secondaryLabelColor)
    }
  }
  #expect(
    SystemStyle.sectionTitle("TOP CPU · BARS = MAC CAPACITY") == "Top CPU · bars = mac capacity")
  #expect(SystemStyle.sectionTitle("METAL GPU TIME") == "Metal GPU time")
}

@Test @MainActor func systemColorNotificationInvalidatesMenuAndChartsWithoutRetainingViews() throws
{
  let window = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 344, height: 640), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  weak var released: MenuBarReadoutView?
  do {
    let menu = MenuBarReadoutView(frame: .init(x: 0, y: 0, width: 100, height: 24))
    window.contentView = menu
    var changes = 0
    menu.onAppearanceChange = { changes += 1 }
    menu.needsDisplay = false
    NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
    #expect(menu.needsDisplay && changes == 1)
    window.contentView = nil
  }
  autoreleasepool {
    let detached = MenuBarReadoutView()
    released = detached
    NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
  }
  #expect(released == nil)
  let chart = ChartView(frame: .init(x: 0, y: 0, width: 300, height: 150))
  window.contentView = chart
  chart.needsDisplay = false
  NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
  #expect(chart.needsDisplay)
  window.contentView = nil
  window.close()
}

@Test @MainActor func systemDropdownsKeepActionsTablesAndScrollablePlattersForEveryModule() throws {
  _ = NSApplication.shared
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.loadViewIfNeeded()
  controller.view.setFrameSize(SystemStyle.popoverSize)
  var opened = 0
  var histories: [Module] = []
  controller.onOpenInWindow = { opened += 1 }
  controller.onHistory = { histories.append($0) }
  for module in Module.allCases {
    for allReadings in [false, true] {
      controller.selected = module
      controller.showsAllReadings = allReadings
      controller.update(Snapshot(), history: [])
      controller.view.layoutSubtreeIfNeeded()
      let buttons = controller.view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
      let open = try #require(buttons.first { $0.title == "Open \(module.title) in TinyStats" })
      #expect(controller.view.bounds.contains(open.frame))
      #expect(open.frame.width == 316)
      #expect(NSApp.sendAction(try #require(open.action), to: open.target, from: open))
      for action in buttons.filter({ $0 is MenuActionRow }) {
        #expect(controller.view.bounds.contains(action.frame))
        #expect(action.frame.height == 26)
        for other in buttons where action !== other {
          #expect(!action.frame.intersects(other.frame))
        }
      }
      if let history = buttons.first(where: { $0.title == "History…" }) {
        #expect(NSApp.sendAction(try #require(history.action), to: history.target, from: history))
        #expect(histories.last == module)
      }
      let views = systemDescendants(controller.view)
      #expect(views.compactMap { $0 as? NSTableView }.count == 1)
      if let summary = views.compactMap({ $0 as? SummaryDashboardView }).first, !summary.isHidden {
        #expect(summary.usesPopoverLayout)
        #expect(summary.enclosingScrollView != nil)
        for card in summary.cards {
          #expect(card.frame.width == summary.bounds.width)
          #expect(summary.bounds.contains(card.frame))
        }
      }
    }
  }
  #expect(opened == Module.allCases.count * 2)
  controller.isPopoverPresentation = false
  controller.selected = .cpu
  controller.showsAllReadings = false
  controller.view.setFrameSize(MainWindow.minimumSize)
  controller.view.layoutSubtreeIfNeeded()
  let summary = try #require(
    controller.view.subviews.compactMap { $0 as? SummaryDashboardView }.first)
  #expect(!summary.usesPopoverLayout && summary.enclosingScrollView == nil)
  #expect(controller.view.subviews.first?.isHidden == false)
  controller.selected = .overview
  controller.view.layoutSubtreeIfNeeded()
  let title = try #require(
    controller.view.subviews.compactMap { $0 as? NSTextField }.first {
      $0.stringValue == "Overview"
    })
  #expect(title.frame.minX == 154)
}

@Test @MainActor func systemPopoverRenderingGalleryPreservesMissingAndZeroReadings() throws {
  _ = NSApplication.shared
  let savedIcon = NSApp.applicationIconImage
  let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
      "Resources/TinyStats.icns")
  NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
  defer { NSApp.applicationIconImage = savedIcon }
  let controller = DetailController()
  controller.isPopoverPresentation = true
  var snapshot = Snapshot()
  snapshot.cpu = .init(
    usage: 23, cores: [31, 28, 22, nil, 0, 12, 52, 39, 9, 4], load: [1.84, 2.1, 2.31],
    coreKinds: [
      .efficiency, .efficiency, .efficiency, .efficiency, .efficiency, .efficiency, .performance,
      .performance, .performance, .performance,
    ], user: 15, system: 8)
  snapshot.memory = .init(
    total: 24_000_000_000, active: 9_000_000_000, inactive: 2_000_000_000, wired: 2_600_000_000,
    compressed: 2_700_000_000, free: 7_700_000_000, speculative: 0, purgeable: 100_000_000,
    swapUsed: 400_000_000, swapTotal: 1_000_000_000, pressure: 1)
  snapshot.device = .init(model: "Mac mini", chip: "Apple M4", operatingSystem: "macOS 15.0")
  snapshot.uptime = 11 * 86_400 + 5 * 3600
  snapshot.gpus = [
    .init(name: "Apple M4", usage: 8, memory: nil, coreCount: 10, rendererUsage: 6, tilerUsage: 3)
  ]
  snapshot.volumes = [
    .init(name: "Macintosh HD", path: "/", total: 494_000_000_000, available: 193_000_000_000)
  ]
  snapshot.sensors = [
    .init(key: "Tp01", name: "CPU die", kind: .temperature, value: 52),
    .init(key: "F0Ac", name: "Fan 1", kind: .fan, value: 1034),
    .init(key: "PSTR", name: "System total power", kind: .power, value: 6.8),
  ]
  snapshot.disks = [.init(id: 1, name: "disk0", read: 2_100_000, written: 640_000)]
  snapshot.selectedInterface = "en0"
  snapshot.download = 1_200_000
  snapshot.upload = 48_000
  snapshot.sampleMilliseconds = 3
  snapshot.processes = [
    .init(pid: 42, name: "Xcode", cpu: 38.2, memory: 0, read: nil, written: nil)
  ]
  let history = (0..<150).map { index in
    var point = snapshot.historyPoint
    point.time = Date(timeIntervalSince1970: Double(index * 2))
    point.cpu = index == 75 ? nil : Double(10 + index % 53)
    point.gpu = index == 75 ? nil : Double(index % 19)
    point.download = index == 75 ? nil : Double(500_000 + (index * 127_333) % 4_000_000)
    point.upload = index == 75 ? nil : Double(10_000 + (index * 18_777) % 400_000)
    return point
  }
  controller.loadViewIfNeeded()
  controller.view.setFrameSize(SystemStyle.popoverSize)
  for module in Module.allCases {
    controller.selected = module
    controller.update(snapshot, history: history)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      controller.view.appearance = NSAppearance(named: name)
      controller.view.layoutSubtreeIfNeeded()
      let bitmap = try #require(
        controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      if let directory = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: url.appendingPathComponent("\(module.rawValue)-\(name.rawValue).png"))
      }
    }
  }
  controller.isPopoverPresentation = false
  controller.selected = .overview
  for size in [MainWindow.minimumSize, NSSize(width: 1000, height: 700)] {
    controller.view.setFrameSize(size)
    controller.update(snapshot, history: history)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      controller.view.appearance = NSAppearance(named: name)
      controller.view.layoutSubtreeIfNeeded()
      let bitmap = try #require(
        controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
      if let directory = ProcessInfo.processInfo.environment["TINYSTATS_SYSTEM_RENDER_PATH"] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let width = size.width == 1000 ? "" : "-\(Int(size.width))"
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: url.appendingPathComponent("overview-window\(width)-\(name.rawValue).png"))
      }
    }
  }
}
