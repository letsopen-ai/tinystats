import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test(arguments: MenuBarWeight.allCases) @MainActor
func menuBarFontsUseSelectedWeightAtTheirExistingSizes(weight: MenuBarWeight) {
  let typography = MenuBarTypography.forWeight(weight)
  let expected: NSFont.Weight =
    weight == .regular ? .regular : weight == .medium ? .medium : .semibold
  #expect(typography.verticalLabelFont == .systemFont(ofSize: 8, weight: expected))
  #expect(
    typography.small == .systemFont(ofSize: 9, weight: weight == .semibold ? .medium : expected))
  #expect(
    typography.calendarFont == .monospacedDigitSystemFont(ofSize: 11, weight: expected))
  #expect(
    typography.smallCalendarFont == .monospacedDigitSystemFont(ofSize: 7, weight: expected))
  #expect(
    StatusItemController.buttonFont(weight)
      == .monospacedDigitSystemFont(ofSize: 11, weight: expected))
  for size in MenuBarSize.allCases {
    #expect(
      typography.fonts[size]
        == .monospacedDigitSystemFont(ofSize: size.pointSize, weight: expected))
    #expect(
      typography.networkFonts[size]
        == .monospacedDigitSystemFont(
          ofSize: size == .compact ? 10 : size == .standard ? 10.5 : 11, weight: expected))
    // Every weight retains the tabular digits used by live values and reservations.
    for font in [typography.fonts[size]!, typography.networkFonts[size]!] {
      let widths = (0...9).map {
        (String($0) as NSString).size(withAttributes: [.font: font]).width
      }
      #expect(Set(widths).count == 1)
    }
  }
}

@Test(arguments: MenuBarWeight.allCases) @MainActor
func menuBarCachedSymbolsUseSelectedWeightAtNativePointSize(weight: MenuBarWeight) throws {
  let typography = MenuBarTypography.forWeight(weight)
  let expected: NSFont.Weight =
    weight == .regular ? .regular : weight == .medium ? .medium : .semibold
  let regular = NSImage.SymbolConfiguration(pointSize: 0, weight: expected)
  #expect(typography.symbolConfiguration.isEqual(regular))
  for name in Set(Module.allCases.map(\.symbol) + ["bolt.fill", "powerplug", "sun.max", "cloud"]) {
    #expect(typography.symbols[name] != nil)
  }
  for (name, image) in typography.symbols {
    let original = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil))
    #expect(image.symbolConfiguration.isEqual(regular))
    let configured = try #require(original.withSymbolConfiguration(regular))
    #expect(image.size == configured.size)
    if weight == .regular { #expect(image.size == original.size) }
  }
}

@Test(arguments: MenuBarWeight.allCases) @MainActor
func selectedWeightNetworkReservationsFitTheWidestFormattedRates(weight: MenuBarWeight) {
  let typography = MenuBarTypography.forWeight(weight)
  for size in MenuBarSize.allCases {
    for style in [MenuBarStyle.stacked, .historyValue, .text, .value] {
      let font =
        style == .stacked || style == .historyValue
        ? typography.networkFonts[size]! : typography.fonts[size]!
      let candidates =
        ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"].flatMap {
          ["↑ 999 \($0)", "↓ 10.0 \($0)"]
        } + ["↑ >999 EB/s", "↓ >999 EB/s"]
      let field = candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        .max()!
      var reading = MenuBarReadout(
        label: "NET", value: "↑ >999 EB/s", secondary: "↓ >999 EB/s", style: style)
      reading.isNetwork = true
      reading.appearance.size = size
      let renderer = MenuBarReadoutView()
      renderer.weight = weight
      renderer.readouts = [reading]
      switch style {
      case .stacked: #expect(renderer.preferredWidth >= ceil(field))
      case .historyValue: #expect(renderer.preferredWidth >= 49 + ceil(field))
      default:
        let prefix =
          style == .text ? ("NET " as NSString).size(withAttributes: [.font: font]).width : 0
        let gap = (" " as NSString).size(withAttributes: [.font: font]).width
        #expect(renderer.preferredWidth >= prefix + 2 * field + gap)
      }
    }
  }
}

@Test @MainActor func menuBarStrokeWeightsFollowTheApprovedMapping() {
  let expected: [(MenuBarWeight, [CGFloat])] = [
    (.regular, [1, 3, 1, 0.7, 1, 1, 0.7]),
    (.medium, [1.25, 3.5, 1.15, 0.85, 1.25, 1.15, 0.8]),
    (.semibold, [1.5, 4, 1.25, 1, 1.5, 1, 0.7]),
  ]
  for (weight, widths) in expected {
    let style = MenuBarTypography.forWeight(weight)
    #expect(
      [
        style.historyStroke, style.ringStroke, style.outlineStroke, style.tickStroke,
        style.hourStroke, style.minuteStroke, style.secondStroke,
      ] == widths)
  }
}

@MainActor private func weightViews(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + weightViews($0) }
}

@MainActor private final class WeightInvalidations {
  var count = 0
}

@MainActor private final class WeightTrackingButton: NSButton {
  var fontAssignments = 0
  override var font: NSFont? {
    didSet { fontAssignments += 1 }
  }
}

@Test(arguments: MenuBarWeight.allCases) @MainActor
func menuBarReadoutWeightOnlyInvalidatesWhenChanged(weight: MenuBarWeight) {
  let window = NSWindow(
    contentRect: .init(x: 0, y: 0, width: 120, height: 24),
    styleMask: [.borderless], backing: .buffered, defer: false)
  let view = MenuBarReadoutView(frame: .init(x: 0, y: 0, width: 120, height: 24))
  window.contentView = view
  defer { window.contentView = nil }
  view.weight = weight
  let invalidations = WeightInvalidations()
  let observation = view.observe(\.needsDisplay) { _, _ in
    MainActor.assumeIsolated { invalidations.count += 1 }
  }
  defer { observation.invalidate() }
  view.weight = weight
  #expect(invalidations.count == 0)
  view.weight = weight == .regular ? .medium : .regular
  #expect(invalidations.count == 1)
  #expect(view.needsDisplay)
}

@Test(arguments: MenuBarWeight.allCases) @MainActor
func menuBarClockOnlyUpdateSkipsUnchangedTypography(weight: MenuBarWeight) {
  _ = NSApplication.shared
  let modules: [Module] = [.cpu, .network, .clock]
  // Detached owned targets keep AppKit's needsDisplay flag clear. Observe requests too,
  // so a redundant invalidation cannot be hidden by the absence of a native window.
  let views = modules.map { _ in MenuBarReadoutView() }
  let buttons = modules.map { _ in WeightTrackingButton() }
  let invalidations = modules.map { _ in WeightInvalidations() }
  let observations = views.indices.map { index in
    views[index].observe(\.needsDisplay) { _, _ in
      MainActor.assumeIsolated { invalidations[index].count += 1 }
    }
  }
  defer { for observation in observations { observation.invalidate() } }
  let status = StatusItemController(
    targets: modules.indices.map {
      .init(module: modules[$0], button: buttons[$0], readout: views[$0])
    })
  var settings = Settings()
  settings.readouts = modules
  settings.menuBarWeight = weight
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  status.update(
    snapshot: Snapshot(), history: [], settings: settings, clockDate: date, paused: false)
  for view in views { view.needsDisplay = false }
  for invalidation in invalidations { invalidation.count = 0 }
  for button in buttons { button.fontAssignments = 0 }

  status.update(
    snapshot: Snapshot(), history: [], settings: settings,
    clockDate: date.addingTimeInterval(1), paused: false, clockOnly: true)
  for index in modules.indices where modules[index] != .clock {
    #expect(!views[index].needsDisplay)
  }
  #expect(buttons.allSatisfy { $0.fontAssignments == 0 })
  #expect(invalidations.allSatisfy { $0.count == 0 })

  settings.menuBarWeight = weight == .regular ? .medium : .regular
  status.update(
    snapshot: Snapshot(), history: [], settings: settings,
    clockDate: date.addingTimeInterval(2), paused: false, clockOnly: true)
  for view in views {
    #expect(view.weight == settings.menuBarWeight)
  }
  #expect(invalidations.allSatisfy { $0.count == 1 })
  for button in buttons {
    #expect(button.font == StatusItemController.buttonFont(settings.menuBarWeight))
    #expect(button.fontAssignments == 1)
    button.fontAssignments = 0
  }
  for view in views { view.needsDisplay = false }
  for invalidation in invalidations { invalidation.count = 0 }

  status.update(
    snapshot: Snapshot(), history: [], settings: settings,
    clockDate: date.addingTimeInterval(3), paused: false, clockOnly: true)
  for index in modules.indices where modules[index] != .clock {
    #expect(!views[index].needsDisplay)
  }
  #expect(buttons.allSatisfy { $0.fontAssignments == 0 })
  #expect(invalidations.allSatisfy { $0.count == 0 })
}

@Test @MainActor
func weightControlImmediatelyUpdatesPreviewAndStatusTypographyAndSurvivesReopening() throws {
  _ = NSApplication.shared
  var settings = Settings()
  settings.styles["cpu"] = .historyValue
  let controller = PreferencesController(
    settings: settings, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { controller.close() }
  let views = weightViews(try #require(controller.window?.contentView))
  let control = try #require(
    views.compactMap { $0 as? NSSegmentedControl }.first {
      $0.accessibilityLabel() == "Menu bar weight"
    })
  let layout = try #require(
    views.compactMap { $0 as? NSSegmentedControl }.first {
      $0.accessibilityLabel() == "Menu bar layout"
    })
  let preview = try #require(views.compactMap { $0 as? MenuBarPreviewView }.first)
  #expect(control.segmentCount == 3 && control.selectedSegment == 0)
  #expect(control.controlSize == .small && control.segmentStyle == .rounded)
  #expect((0..<3).map { control.toolTip(forSegment: $0) } == MenuBarWeight.allCases.map(\.title))
  #expect(
    (0..<3).map { control.image(forSegment: $0)?.accessibilityDescription }
      == MenuBarWeight.allCases.map { Optional($0.title) })
  let statusView = MenuBarReadoutView()
  let button = NSButton()
  let status = StatusItemController(targets: [
    .init(module: .cpu, button: button, readout: statusView)
  ])
  var changed: Settings?
  controller.onChange = { value in
    changed = value
    status.update(
      snapshot: Snapshot(), history: [], settings: value, clockDate: Date(), paused: false)
  }
  for separate in [true, false] {
    layout.selectedSegment = separate ? 0 : 1
    #expect(NSApp.sendAction(try #require(layout.action), to: layout.target, from: layout))
    for (index, weight) in MenuBarWeight.allCases.enumerated() {
      control.selectedSegment = index
      #expect(NSApp.sendAction(try #require(control.action), to: control.target, from: control))
      #expect(changed?.menuBarWeight == weight && changed?.separateItems == separate)
      #expect(preview.renderers.count == (separate ? settings.readouts.count : 1))
      #expect(preview.renderers.allSatisfy { $0.weight == weight })
      #expect(statusView.weight == weight)
      #expect(button.font == MenuBarTypography.forWeight(weight).buttonFont)
    }
  }
  let restored = try JSONDecoder().decode(
    Settings.self, from: JSONEncoder().encode(try #require(changed)))
  let reopened = PreferencesController(
    settings: restored, interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar)
  defer { reopened.close() }
  let restoredRoot = try #require(reopened.window?.contentView)
  let restoredControl = try #require(
    weightViews(restoredRoot)
      .compactMap { $0 as? NSSegmentedControl }.first {
        $0.accessibilityLabel() == "Menu bar weight"
      })
  #expect(restoredControl.selectedSegment == 2)
  var external = restored
  external.menuBarWeight = .medium
  reopened.updateMenuBarSettings(external)
  #expect(restoredControl.selectedSegment == 1)
}

@Test @MainActor func selectedWeightChangesProductionReadoutPixels() throws {
  _ = NSApplication.shared
  let renderer = MenuBarReadoutView(frame: .init(x: 0, y: 0, width: 110, height: 24))
  renderer.appearance = NSAppearance(named: .aqua)
  for style in [MenuBarStyle.stacked, .icon, .history, .ring, .bar] {
    renderer.readouts = [
      .init(
        label: "CPU", value: "42%", secondary: nil, style: style,
        progress: 42, values: [10, 30, 20, 40])
    ]
    var images: [Data] = []
    for weight in MenuBarWeight.allCases {
      renderer.weight = weight
      let rep = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 220, pixelsHigh: 48,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      rep.size = renderer.bounds.size
      renderer.cacheDisplay(in: renderer.bounds, to: rep)
      images.append(try #require(rep.representation(using: .png, properties: [:])))
    }
    #expect(Set(images).count == 3)
  }
}
