import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func legacySidebarControlsKeepVibrancyAndOriginalUnclippedGeometry() throws {
  let environment = GlassSurface.Environment(
    supportsGlass: false, reduceTransparency: false, increaseContrast: false)
  let navigation = DetailNavigationCoordinator(environment: { environment })
  navigation.layout(in: .init(x: 0, y: 0, width: 884, height: 660))
  let effect = try #require(navigation.sidebarMaterial.legacyContentView as? NSVisualEffectView)
  let buttons = effect.subviews.compactMap { $0 as? NavigationButton }
  #expect(buttons.count == 12)
  #expect(effect.subviews.compactMap { $0 as? NSTextField }.count == 3)
  #expect(navigation.sidebar.frame == NSRect(x: 0, y: 0, width: 132, height: 660))
  #expect(effect.frame == navigation.sidebar.bounds)
  let cpu = try #require(buttons.first { $0.title == "CPU" })
  #expect(cpu.frame == NSRect(x: 10, y: 542, width: 112, height: 31))
  #expect(cpu.keyEquivalent == "2" && cpu.accessibilityLabel() == "CPU")
  #expect(navigation.sidebarMaterial.hitTest(.init(x: cpu.frame.midX, y: cpu.frame.midY)) === cpu)
  let detail = DetailController()
  detail.glassEnvironment = { environment }
  #expect(!detail.view.clipsToBounds && detail.view.isOpaque)
}

@Test @MainActor func fullHeightSidebarUsesInjectedPolicyAndLiveGeometryAcrossAccessibilityChanges()
  throws
{
  guard #available(macOS 26, *) else { return }
  var environment = GlassSurface.Environment(
    supportsGlass: true, reduceTransparency: false, increaseContrast: false)
  let navigation = DetailNavigationCoordinator(environment: { environment })
  navigation.layout(in: .init(x: 0, y: 0, width: 884, height: 660))
  #expect(navigation.sidebar.frame == NSRect(x: 0, y: 0, width: 132, height: 660))
  let glass = try #require(navigation.sidebarMaterial.subviews.first as? NSGlassEffectView)
  #expect(glass.cornerRadius == 0)
  let root = MainContentView(frame: .init(x: 0, y: 0, width: 884, height: 660))
  root.glassEnvironment = { environment }
  // A deliberately different width verifies that the content starts at the live split edge.
  root.sidebarFrame = { NSRect(x: 0, y: 0, width: 180, height: 660) }
  #expect(!root.isOpaque)
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    root.appearance = NSAppearance(named: appearance)
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.effectiveAppearance.performAsCurrentDrawingAppearance {
      root.cacheDisplay(in: root.bounds, to: bitmap)
    }
    let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
    #expect(
      try #require(bitmap.colorAt(x: Int(170 * scale), y: Int(330 * scale))).alphaComponent == 0)
    #expect(
      try #require(bitmap.colorAt(x: Int(200 * scale), y: Int(330 * scale))).alphaComponent == 1)
    #expect(
      try #require(bitmap.colorAt(x: Int(2 * scale), y: Int(330 * scale))).alphaComponent == 0)
    for y in [0, 659] {
      #expect(try #require(bitmap.colorAt(x: 0, y: Int(CGFloat(y) * scale))).alphaComponent == 0)
      #expect(
        try #require(bitmap.colorAt(x: Int(200 * scale), y: Int(CGFloat(y) * scale)))
          .alphaComponent == 1)
    }
  }
  environment.increaseContrast = true
  NSWorkspace.shared.notificationCenter.post(
    name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  #expect(root.isOpaque && !root.clipsToBounds)
  #expect(navigation.sidebarMaterial.treatment == .solid)
  #expect(navigation.sidebarMaterial.subviews.isEmpty)
  #expect(navigation.sidebar.subviews.compactMap { $0 as? NavigationButton }.count == 12)
}

@Test @MainActor func chipGlassFollowsModuleIdentityThroughAnimatedReorder() async throws {
  guard #available(macOS 26, *) else { return }
  let editor = MenuBarCustomization(frame: .init(x: 0, y: 0, width: 620, height: 280))
  editor.update(order: [.cpu, .memory, .network])
  editor.layoutSubtreeIfNeeded()
  let container = try #require(editor.strip.glass.subviews.first as? NSGlassEffectContainerView)
  let content = try #require(container.contentView)
  let shapes = Dictionary(uniqueKeysWithValues: content.subviews.map { ($0.identifier, $0) })
  editor.update(order: [.network, .cpu, .memory], animated: true)
  try await Task.sleep(for: .milliseconds(220))
  for chip in editor.strip.chips {
    let shape = try #require(shapes[.init(chip.module.rawValue)])
    #expect(content.subviews.contains { $0 === shape })
    #expect(shape.frame == chip.frame)
  }
  #expect(container.spacing < 8)
}

@Test @MainActor func chipInsertionMarkerDrawsAboveGlassInBothAppearances() throws {
  guard #available(macOS 26, *) else { return }
  let editor = MenuBarCustomization(frame: .init(x: 0, y: 0, width: 620, height: 280))
  editor.update(order: [.cpu, .memory, .network])
  editor.layoutSubtreeIfNeeded()
  let area = editor.strip
  let chip = try #require(editor.chips[.cpu])
  let next = try #require(editor.chips[.memory])
  let drag = ReadoutDrag()
  defer { drag.draggingPasteboard.releaseGlobally() }
  drag.draggingSource = chip
  #expect(drag.draggingPasteboard.writeObjects([editor.pasteboardItem(for: .cpu)]))
  drag.draggingLocation = area.convert(.init(x: next.frame.minX, y: next.frame.midY), to: nil)
  #expect(area.draggingEntered(drag) == .move)
  let marker = try #require(area.insertionFrame)
  #expect(area.subviews.last === area.insertionOverlay)
  #expect(area.insertionOverlay.hitTest(marker.origin) == nil)
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    area.appearance = NSAppearance(named: appearance)
    let bitmap = try #require(area.bitmapImageRepForCachingDisplay(in: area.bounds))
    area.effectiveAppearance.performAsCurrentDrawingAppearance {
      area.cacheDisplay(in: area.bounds, to: bitmap)
    }
    let scale = CGFloat(bitmap.pixelsWide) / area.bounds.width
    let ink = try #require(
      bitmap.colorAt(x: Int(marker.midX * scale), y: Int(marker.midY * scale))?.usingColorSpace(
        .sRGB))
    var resolvedAccent: NSColor?
    area.effectiveAppearance.performAsCurrentDrawingAppearance {
      resolvedAccent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
    }
    let accent = try #require(resolvedAccent)
    #expect(abs(ink.redComponent - accent.redComponent) < 0.06)
    #expect(abs(ink.greenComponent - accent.greenComponent) < 0.06)
    #expect(abs(ink.blueComponent - accent.blueComponent) < 0.06)
  }
}

@Test @MainActor func namedSensorSummaryRetainsValuesAndExpandsSingletonWithoutLosingRows() throws {
  var snapshot = Snapshot()
  snapshot.sensors = [
    .init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 45),
    .init(key: "Tp01", name: "CPU die", kind: .temperature, value: 40),
  ]
  let p = SensorBrowserPresentation.build(
    snapshot: snapshot, timeline: SensorTimeline(), settings: Settings(), query: "",
    showsAll: false, selection: .hottest(.cpu))
  #expect(
    p.rows.contains {
      $0.label == "CPU proximity" && $0.value == "45.0°C"
    })
  #expect(p.rows.contains { $0.sensorIdentity == .reading("Tp01") && $0.value == "40.0°C" })
  #expect(!p.rows.contains { $0.value == "All readings" })
  #expect(ChartValueFormat.unit("°C").axisString(52.26) == "52.3 °C")
  #expect(ChartValueFormat.unit("°F").axisString(125.26) == "125.3 °F")
}

@Test @MainActor func overviewTemperatureCaptionAndDropdownHeaderFitTheirContent() throws {
  var snapshot = Snapshot()
  snapshot.sensors = [
    .init(key: "TC0P", name: "CPU proximity", kind: .temperature, value: 45),
    .init(key: "F0Ac", name: "Fan", kind: .fan, value: 1200),
  ]
  let summary = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 324, height: 600))
  summary.usesPopoverLayout = true
  summary.popoverHeadline = ("Overview", "Mac", "Fixture")
  summary.update(snapshot, history: [], settings: Settings(), module: .overview)
  #expect(summary.cards.first?.frame.height == 108)
  let temperature = try #require(summary.cards.first { $0.title == "CPU temperature" })
  guard case .overviewTile(let tile) = temperature.content else {
    Issue.record("Expected tile")
    return
  }
  #expect(tile.value.detail == "Hottest of 1 CPU sensor")
  #expect(temperature.spoken.contains("Fan 1200 rpm"))
  #expect(
    summary.hoverText(at: .init(x: temperature.frame.midX, y: temperature.frame.midY))?.contains(
      "Fan 1200 rpm") == true)
}
