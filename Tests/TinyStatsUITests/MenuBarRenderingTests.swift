import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func fixture(_ style: MenuBarStyle) -> MenuBarReadout {
  .init(
    label: style == .battery ? "BAT" : "CPU", value: "52%", secondary: nil,
    style: style, charging: style == .battery, progress: 52,
    values: [0, 20, 35, nil, 75, 55, 52], cores: [5, 15, 35, 70, 55, 92, 22, 52])
}

@MainActor private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
  _ = NSApplication.shared
  let rep = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(ceil(view.bounds.width * 2)), pixelsHigh: Int(ceil(view.bounds.height * 2)),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  rep.size = view.bounds.size
  view.cacheDisplay(in: view.bounds, to: rep)
  return rep
}

@MainActor private func png(_ view: NSView) throws -> Data {
  try #require(try bitmap(view).representation(using: .png, properties: [:]))
}

@Test @MainActor func menuRenderingHandlesStylesSizesAppearancesAndMissingData() throws {
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for size in MenuBarSize.allCases {
      for style in MenuBarStyle.allCases {
        let view = MenuBarReadoutView()
        var reading = fixture(style)
        reading.appearance.size = size
        view.appearance = NSAppearance(named: appearance)
        view.readouts = [reading]
        for height in [22.0, 24, 37] {
          view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: height)
          #expect(view.preferredWidth.isFinite && view.preferredWidth > 12)
          let populated = try png(view)
          #expect(!populated.isEmpty)
          if [
            .bar, .labeledBar, .horizontal, .pie, .ring, .battery, .cores, .history, .historyValue,
          ].contains(
            style)
          {
            var missing = reading
            missing.value = "—"
            missing.progress = nil
            missing.values = [nil, nil]
            missing.cores = []
            missing.charging = false
            view.readouts = [missing]
            let unavailable = try png(view)
            #expect(unavailable != populated)
            missing.progress = 0
            missing.values = [0, 0]
            missing.cores = [0, 0]
            view.readouts = [missing]
            let idle = try png(view)
            #expect(idle != unavailable)
            #expect(idle != populated)
            view.readouts = [reading]
          }
        }
      }
    }
  }
}

@Test @MainActor func menuNetworkWidthAndCombinedLayoutRetainFullValues() throws {
  let view = MenuBarReadoutView()
  var network = MenuBarReadout(
    label: "NET", value: "↑ 3.1 MB/s", secondary: "↓ 93 KB/s", style: .stacked)
  network.isNetwork = true
  view.readouts = [network]
  let compactWidth = view.preferredWidth
  network.value = "↑ 999 GB/s"
  network.secondary = "↓ 999 GB/s"
  view.readouts = [network]
  #expect(view.preferredWidth == compactWidth)
  view.readouts = [fixture(.ring), network, fixture(.value)]
  let combined = view.preferredWidth
  view.paused = true
  #expect(view.preferredWidth == combined + 12)
  view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: 24)
  #expect(!(try png(view)).isEmpty)
}

@Test @MainActor func networkRatesKeepStatusWidthAcrossDigitsUnitsAndMissingSamples() throws {
  for style in [MenuBarStyle.stacked, .historyValue, .text, .value] {
    for size in MenuBarSize.allCases {
      var settings = Settings()
      settings.styles["network"] = style
      settings.appearances["network"] = .init(size: size, color: .automatic)
      let view = MenuBarReadoutView()
      var widths: [CGFloat] = []
      for rate: Double? in [
        nil, -1, .nan, .infinity, 0, 9, 999, 999.9, 1_000, 9_999, 999_999, 1e9, 1e12,
        .greatestFiniteMagnitude,
      ] {
        var snapshot = Snapshot()
        snapshot.upload = rate
        snapshot.download = rate.map { $0 * 2 }
        let item = MenuBarReadout.make(
          module: .network, snapshot: snapshot, settings: settings, history: [])
        if rate == nil || rate.map({ !$0.isFinite || $0 < 0 }) == true {
          #expect(item.value == "↑ —" && item.secondary == "↓ —")
        }
        view.readouts = [fixture(.ring), item, fixture(.value)]
        widths.append(view.preferredWidth)
      }
      #expect(Set(widths).count == 1)
      view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: 24)
      #expect(!(try png(view)).isEmpty)
    }
  }
}

@MainActor private final class Gallery: NSView {
  override func draw(_ rect: NSRect) {
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 380, height: bounds.height).fill()
    NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
    NSRect(x: 380, y: 0, width: 380, height: bounds.height).fill()
    for column in 0..<2 {
      let color: NSColor = column == 0 ? .black : .white
      for (index, style) in MenuBarStyle.allCases.enumerated() {
        (style.title as NSString).draw(
          at: .init(x: column * 380 + 20, y: Int(bounds.height) - 112 - index * 46),
          withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
      }
    }
  }
}

/// Explicit opt-in artifact: uses the production renderer with deterministic, local fixtures.
@Test @MainActor func menuStyleGallery() throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_RENDER_GALLERY"] else { return }
  let gallery = Gallery(frame: .init(x: 0, y: 0, width: 760, height: 730))
  for column in 0..<2 {
    let appearance = NSAppearance(named: column == 0 ? .aqua : .darkAqua)
    var reference: [MenuBarReadout] = [
      .init(label: "CPU", value: "52°", secondary: nil, style: .stacked),
      .init(label: "NET", value: "↑ 3.1 MB/s", secondary: "↓ 93 KB/s", style: .stacked),
      .init(label: "SSD", value: "73%", secondary: nil, style: .stacked),
      .init(label: "CPU", value: "18%", secondary: nil, style: .stacked),
      .init(label: "MEM", value: "47%", secondary: nil, style: .stacked),
    ]
    for index in reference.indices { reference[index].appearance.size = .standard }
    let top = MenuBarReadoutView(frame: .init(x: column * 380 + 14, y: 680, width: 352, height: 24))
    top.appearance = appearance
    top.readouts = reference
    gallery.addSubview(top)
    for (index, style) in MenuBarStyle.allCases.enumerated() {
      let row = MenuBarReadoutView(
        frame: .init(x: column * 380 + 184, y: 614 - index * 46, width: 182, height: 24))
      row.appearance = appearance
      var reading = fixture(style)
      reading.appearance.color = index.isMultiple(of: 2) ? .automatic : .blue
      row.readouts = [reading]
      gallery.addSubview(row)
    }
  }
  try png(gallery).write(to: URL(fileURLWithPath: path))
}

@Test @MainActor func chargingIndicatorRemainsDistinctOnAFullAutomaticBattery() throws {
  let view = MenuBarReadoutView(frame: .init(x: 0, y: 0, width: 55, height: 24))
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    view.appearance = NSAppearance(named: appearance)
    var reading = fixture(.battery)
    reading.progress = 100
    reading.charging = false
    view.readouts = [reading]
    let charged = try png(view)
    reading.charging = true
    view.readouts = [reading]
    #expect(try png(view) != charged)
  }
}

@Test @MainActor func perCoreColorsUseVerifiedTopologyWithAutomaticMetricColors() throws {
  let view = MenuBarReadoutView()
  var reading = MenuBarReadout(
    label: "CPU", value: "30%", secondary: nil, style: .cores,
    cores: [10, 20, 30, 40], coreKinds: [.efficiency, .efficiency, .performance, .performance])
  view.appearance = NSAppearance(named: .aqua)
  view.readouts = [reading]
  view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: 24)
  let classified = try png(view)
  reading.coreKinds = []
  view.readouts = [reading]
  #expect(try png(view) != classified)
  reading.appearance.color = .green
  view.readouts = [reading]
  let green = try png(view)
  reading.coreKinds = Array(repeating: .unknown, count: reading.cores.count)
  view.readouts = [reading]
  #expect(try png(view) == green)
  reading.coreKinds = [.efficiency]
  view.readouts = [reading]
  #expect(try png(view) == green)
  reading.coreKinds = [.efficiency, .efficiency, .performance, .performance]
  view.readouts = [reading]
  #expect(try png(view) != green)
}

@Test @MainActor func batteryIconDoesNotConfuseAHeldACBatteryWithAbsentReadings() throws {
  for presets in [false, true] {
    var settings = Settings()
    settings.styles["battery"] = .battery
    settings.batteryMenu.format = .time
    settings.batteryMenu.customizeStates = presets
    settings.batteryMenu.externalPower = .init(format: .time, style: .battery)
    var snapshot = Snapshot()
    snapshot.batteries = [
      .init(
        name: "Held charge", percent: 80, charging: false, externalPower: true,
        minutesRemaining: nil, cycles: nil, health: nil, watts: 0, fullyCharged: false)
    ]
    let present = MenuBarReadout.make(
      module: .battery, snapshot: snapshot, settings: settings, history: [])
    snapshot.batteries = []
    let absent = MenuBarReadout.make(
      module: .battery, snapshot: snapshot, settings: settings, history: [])
    #expect(present.value == "AC" && absent.value == "AC")
    #expect(present.progress == 80 && absent.progress == nil)
    #expect(!present.batteryAbsent && absent.batteryAbsent)
    let view = MenuBarReadoutView()
    view.appearance = NSAppearance(named: .aqua)
    view.readouts = [present]
    view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: 24)
    let batteryImage = try png(view)
    view.readouts = [absent]
    #expect(try png(view) != batteryImage)
  }
}

@Test @MainActor func menuBarTextContrastsWithHostAppearance() throws {
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    for style in [MenuBarStyle.text, .value, .label, .stacked] {
      let view = MenuBarReadoutView()
      view.appearance = NSAppearance(named: name)
      view.readouts = [Module.cpu, .gpu, .memory, .network, .weather].map { module in
        var reading = MenuBarReadout.make(
          module: module, snapshot: Snapshot(), settings: Settings(), history: [])
        reading.style = style
        return reading
      }
      view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: 24)
      let rep = try bitmap(view)
      var visible = 0
      var foreground = 0
      for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
          let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          if color.alphaComponent > 0.2 {
            visible += 1
            let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
            let maximum = max(color.redComponent, color.greenComponent, color.blueComponent)
            #expect(maximum - minimum < 0.02)
            if name == .darkAqua ? minimum > 0.97 : maximum < 0.5 { foreground += 1 }
          }
        }
      }
      #expect(visible > 30 && foreground > 30)
    }
  }
}

@Test @MainActor func compactMenuBarPaddingPreservesGraphAndCombinedBounds() throws {
  let view = MenuBarReadoutView()
  view.appearance = NSAppearance(named: .darkAqua)
  var cpu = fixture(.labeledBar)
  cpu.module = .cpu
  view.readouts = [cpu]
  #expect(view.preferredWidth == 30)
  let single = view.preferredWidth
  view.readouts = [cpu, cpu, cpu]
  #expect(view.preferredWidth == 3 * single + 2)
  view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: 24)
  let rep = try bitmap(view)
  var white = 0
  for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide {
      let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      if color.alphaComponent > 0.9 {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        #expect(channels.max()! - channels.min()! < 0.02)
        if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.97 { white += 1 }
      }
      if x == 0 || x == rep.pixelsWide - 1 { #expect(color.alphaComponent == 0) }
    }
  }
  #expect(white > 40)
}

@Test @MainActor func networkDirectionMarkersStayAtLeadingEdgeForShortAndLongRates() throws {
  for style in [MenuBarStyle.stacked, .value, .text, .historyValue] {
    for size in MenuBarSize.allCases {
      var item = MenuBarReadout(
        label: "NET", value: "↑ —", secondary: "↓ —", style: style)
      item.appearance.size = size
      item.isNetwork = true
      let view = MenuBarReadoutView()
      view.appearance = NSAppearance(named: .darkAqua)
      var expectedWidth: CGFloat?
      for rates in [("↑ —", "↓ —"), ("↑ 1 B/s", "↓ 9 KB/s"), ("↑ >999 EB/s", "↓ 999 MB/s")] {
        item.value = rates.0
        item.secondary = rates.1
        view.readouts = [item]
        let width = view.preferredWidth
        #expect(expectedWidth == nil || expectedWidth == width)
        expectedWidth = width
        view.frame = .init(x: 0, y: 0, width: width, height: 24)
        let rep = try bitmap(view)
        let font = NSFont.monospacedDigitSystemFont(
          ofSize: size == .compact ? 10 : size == .standard ? 10.5 : 11, weight: .semibold)
        let prefix =
          style == .text
          ? ceil(
            ("NET " as NSString).size(withAttributes: [
              .font: NSFont.monospacedDigitSystemFont(ofSize: size.pointSize, weight: .semibold)
            ]).width) : 0
        let start = Int((1 + prefix + (style == .historyValue ? 49 : 0)) * 2)
        var visible = 0
        for y in 0..<rep.pixelsHigh {
          for x
            in start..<min(
              start + Int(ceil(("↑" as NSString).size(withAttributes: [.font: font]).width * 2)),
              rep.pixelsWide)
          {
            let pixel = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            if pixel.alphaComponent > 0.8 && pixel.redComponent > 0.9 { visible += 1 }
          }
        }
        #expect(visible > 4)
      }
    }
  }
}

@MainActor private final class MenuBarLegibilityGallery: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ rect: NSRect) {
    let backgrounds = [
      NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.58, alpha: 1),
      NSColor(calibratedWhite: 0.13, alpha: 1),
      NSColor(calibratedRed: 0.49, green: 0.42, blue: 0.24, alpha: 1),
      NSColor(calibratedWhite: 0.94, alpha: 1),
    ]
    for (i, color) in backgrounds.enumerated() {
      color.setFill()
      NSRect(x: CGFloat(i) * 340, y: 0, width: 340, height: bounds.height).fill()
    }
  }
}

/// Synthetic production-renderer sample, not a native status-bar screenshot.
@Test @MainActor func menuBarLegibilityGallery() throws {
  guard let path = ProcessInfo.processInfo.environment["TINYSTATS_LEGIBILITY_GALLERY"] else {
    return
  }
  let gallery = MenuBarLegibilityGallery(frame: .init(x: 0, y: 0, width: 1360, height: 160))
  for column in 0..<4 {
    func readout(_ module: Module, _ label: String, _ value: String, _ style: MenuBarStyle)
      -> MenuBarReadout
    {
      var result = fixture(style)
      result.module = module
      result.label = label
      result.value = value
      if value.hasSuffix("%"), let progress = Double(value.dropLast()) {
        result.progress = progress
        result.values = [0, 20, 35, nil, 75, 55, progress]
      }
      result.coreKinds = [
        .efficiency, .efficiency, .performance, .performance, .performance, .performance,
        .performance, .performance,
      ]
      return result
    }
    var net = readout(.network, "NET", "↑ 1.3 MB/s", .stacked)
    net.secondary = "↓ 114 KB/s"
    net.isNetwork = true
    var clock = readout(.clock, "MON", "11:42", .stacked)
    clock.secondary = "11:42"
    clock.clock = .init(
      first: .init([.calendar(26), .text(" MON")]),
      second: .init([.dial(try #require(ClockDialReading(hour: 11, minute: 42))), .text(" 11:42")]))
    let rows: [[MenuBarReadout]] = [
      [
        readout(.cpu, "CPU", "17%", .stacked), readout(.memory, "MEM", "74%", .stacked), net,
        readout(.weather, "Set location", "—", .stacked),
      ],
      [
        readout(.cpu, "CPU", "17%", .labeledBar), readout(.memory, "MEM", "74%", .labeledBar),
        readout(.disks, "SSD", "91%", .labeledBar), net,
      ],
      [
        readout(.cpu, "CPU", "17%", .historyValue), readout(.gpu, "GPU", "47%", .ring),
        readout(.memory, "MEM", "74%", .horizontal), net,
      ],
      [
        readout(.cpu, "CPU", "17%", .cores), readout(.battery, "BAT", "52%", .battery),
        clock, readout(.weather, "Cloudy", "24°", .stacked),
      ],
    ]
    for (index, row) in rows.enumerated() {
      let view = MenuBarReadoutView()
      view.appearance = NSAppearance(named: column == 3 ? .aqua : .darkAqua)
      view.readouts = row
      view.frame = .init(
        x: CGFloat(column) * 340 + 12, y: CGFloat(8 + index * 38), width: ceil(view.preferredWidth),
        height: 24)
      gallery.addSubview(view)
    }
  }
  let output = URL(fileURLWithPath: path)
  try png(gallery).write(to: output)
  // A full-size column prevents image viewers from downscaling the tiny clock/label graphics.
  gallery.setFrameSize(.init(width: 340, height: 160))
  try png(gallery).write(to: output.deletingPathExtension().appendingPathExtension("detail.png"))
}

@Test @MainActor func calendarAndDialFollowHostAccentWithLabelColoredText() throws {
  let dial = try #require(ClockDialReading(hour: 11, minute: 42))
  for name in [NSAppearance.Name.aqua, .darkAqua] {
    for part: ClockMenuLine.Part in [.calendar(26), .dial(dial)] {
      var reading = MenuBarReadout(label: "Time", value: "", secondary: nil, style: .value)
      reading.module = .clock
      reading.clock = .init(first: .init([part]), second: nil)
      let view = MenuBarReadoutView()
      view.appearance = NSAppearance(named: name)
      view.readouts = [reading]
      view.frame = .init(x: 0, y: 0, width: view.preferredWidth, height: 24)
      let rep = try bitmap(view)
      let expected = try #require(
        MenuBarPalette.resolve(view.effectiveAppearance).graphic(.clock).usingColorSpace(.deviceRGB)
      )
      var accentPixels = 0
      for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
          let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          if color.alphaComponent > 0.9,
            abs(color.redComponent - expected.redComponent) < 0.05,
            abs(color.greenComponent - expected.greenComponent) < 0.05,
            abs(color.blueComponent - expected.blueComponent) < 0.05
          {
            accentPixels += 1
          }
        }
      }
      #expect(accentPixels > 15)
    }
  }
}
