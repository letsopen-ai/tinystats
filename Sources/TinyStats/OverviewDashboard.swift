import AppKit
import TinyStatsCore

/// Overview uses the shared immediate-mode dashboard, platters, traces and segmented bars.
/// No new views, timers, collection or retained history are owned by this presentation.
extension SummaryDashboardView {
  struct DeviceHeader {
    var model: String, subtitle: String, uptime: String, thermal: String, pressure: String
    var thermalColor: NSColor, pressureColor: NSColor
    var spoken: [String] {
      [
        model, subtitle, "Uptime: " + uptime, "Thermal state: " + thermal,
        "Memory pressure: " + pressure,
      ]
    }
  }
  struct OverviewTile {
    var value: Tile
    var symbol: String
    var segments: [SegmentedBarView.Segment]? = nil
    var composition = ""
    var barCaption: String? = nil
  }

  static func thermalColor(_ state: String) -> NSColor {
    switch state.lowercased() {
    case "nominal": SystemStyle.nominal
    case "fair", "serious": SystemStyle.warning
    case "critical": SystemStyle.critical
    default: .secondaryLabelColor
    }
  }
  static func pressureColor(_ pressure: Int?) -> NSColor {
    switch pressure {
    case 1: SystemStyle.nominal
    case 2: SystemStyle.warning
    case 4: SystemStyle.critical
    default: .secondaryLabelColor
    }
  }

  static func overviewFrames(in bounds: NSRect) -> [NSRect] {
    let w = bounds.width
    let h = bounds.height
    let gap: CGFloat = 10
    let header: CGFloat = w < 650 ? 86 : 74
    let bottom: CGFloat = h < 500 ? 72 : 88
    let tile = min(160, max(132, (h - header - bottom - 30) * 0.45))
    let middle = max(0, h - header - tile - bottom - gap * 3)
    let tileY = header + gap
    let middleY = tileY + tile + gap
    let quarter = max(0, (w - 3 * gap) / 4)
    let third = max(0, (w - 2 * gap) / 3)
    let side = max(0, (w - gap) / 3)
    return [NSRect(x: 0, y: 0, width: w, height: header)]
      + (0..<4).map {
        NSRect(x: CGFloat($0) * (quarter + gap), y: tileY, width: quarter, height: tile)
      }
      + [
        NSRect(x: 0, y: middleY, width: w - side - gap, height: middle),
        NSRect(x: w - side, y: middleY, width: side, height: (middle - gap) / 2),
        NSRect(
          x: w - side, y: middleY + (middle + gap) / 2, width: side, height: (middle - gap) / 2),
      ]
      + (0..<3).map {
        NSRect(x: CGFloat($0) * (third + gap), y: h - bottom, width: third, height: bottom)
      }
  }

  static func overviewCards(_ s: Snapshot, history: [HistoryPoint], settings: Settings) -> [Card] {
    // A real five-minute time domain, including unsampled time and sleep gaps. The worker
    // already bounds input history; cap again here for standalone presentation callers.
    let end = history.last?.time ?? s.timestamp
    let domain = end.addingTimeInterval(-300)...end
    let recent = history.suffix(300).filter { domain.contains($0.time) }
    let mini = Array(recent.suffix(90))
    func trend(_ key: KeyPath<HistoryPoint, Double?>, label: String, value: String, percent: Bool)
      -> Plot
    {
      .init(
        first: mini.map { $0[keyPath: key] }, second: [], firstLabel: label, secondLabel: "",
        firstValue: value, secondValue: "", percent: percent, mirrored: false,
        time: .init(mini.map(\.time), intervals: mini.map(\.sampleInterval)),
        valueFormat: percent ? .percent : .rate)
    }
    func tile(
      _ label: String, _ value: String, _ detail: String, _ symbol: String,
      key: KeyPath<HistoryPoint, Double?>? = nil, percent: Bool = false,
      segments: [SegmentedBarView.Segment]? = nil, composition: String = "",
      barCaption: String? = nil
    ) -> Card {
      .init(
        frame: .zero, title: label,
        content: .overviewTile(
          .init(
            value: .init(
              label: label, value: value, detail: detail,
              trend: key.map { trend($0, label: label, value: value, percent: percent) }),
            symbol: symbol, segments: segments, composition: composition, barCaption: barCaption)))
    }
    let memory = s.memory.flatMap { $0.total > 0 ? $0 : nil }
    let volume = s.startupVolume
    let gpu = s.gpus.max { ($0.usage ?? -1) < ($1.usage ?? -1) }
    let subtitle = [
      s.device.chip, memory.map { Display.bytes($0.total) + " RAM" }, s.device.operatingSystem,
    ]
    .compactMap { $0 }.joined(separator: ", ")
    let header = DeviceHeader(
      model: s.device.model ?? "Mac",
      subtitle: subtitle.isEmpty ? "Device information unavailable" : subtitle,
      uptime: Display.duration(s.uptime), thermal: s.thermalState,
      pressure: memory?.pressureDescription ?? "Unavailable",
      thermalColor: thermalColor(s.thermalState), pressureColor: pressureColor(memory?.pressure))
    let composition = memory?.composition
    let memorySegments: [SegmentedBarView.Segment] =
      memory.map { m in
        let c = m.composition
        return [
          .init(fraction: Double(c.app) / Double(m.total), color: SystemStyle.accent),
          .init(fraction: Double(c.wired) / Double(m.total), color: SystemStyle.secondaryAccent),
          .init(
            fraction: Double(c.compressed) / Double(m.total), color: SystemStyle.neutralSeries),
        ]
      } ?? []
    let memoryCaption =
      composition.map {
        "App estimate \(Display.bytes($0.app)), wired \(Display.bytes($0.wired)), compressed \(Display.bytes($0.compressed)); available including cache \(Display.bytes($0.available))"
      } ?? "Memory composition unavailable"
    let fans = s.sensors.filter { $0.kind == .fan && ($0.fanOwner == .cpu || $0.fanOwner == nil) }
    let cpuSensors = s.sensors.filter { $0.kind == .temperature && $0.name.hasPrefix("CPU") }
    let temperature =
      s.cpuTemperature.map {
        String(
          format: "%.0f°%@", settings.fahrenheit ? $0 * 1.8 + 32 : $0,
          settings.fahrenheit ? "F" : "C")
      } ?? "—"
    let fanCaption =
      fans.first.map { "\($0.name) \($0.formatted(fahrenheit: false))" } ?? "Fan speed unavailable"
    let power = s.sensors.first { $0.key == "PSTR" && $0.kind == .power }
    let battery = s.batteries.first
    let network = Plot(
      first: recent.map(\.download), second: recent.map(\.upload),
      firstLabel: "Download", secondLabel: "Upload", firstValue: Display.rate(s.download),
      secondValue: Display.rate(s.upload),
      percent: false, mirrored: false, secondColor: SystemStyle.secondaryAccent,
      time: .init(recent.map(\.time), intervals: recent.map(\.sampleInterval), domain: domain),
      valueFormat: .rate, drawsTrace: true)
    return [
      .init(frame: .zero, title: "Your Mac", content: .device(header)),
      tile(
        "CPU", Display.percent(s.cpu?.usage),
        "User \(Display.percent(s.cpu?.user)), system \(Display.percent(s.cpu?.system))", "cpu",
        key: \.cpu, percent: true),
      tile(
        "GPU", Display.percent(gpu?.usage),
        "Renderer \(Display.percent(gpu?.rendererUsage)), tiler \(Display.percent(gpu?.tilerUsage))",
        "square.3.layers.3d", key: \.gpu, percent: true),
      tile(
        "Memory", memory.map { Display.bytes($0.used) } ?? "—",
        memory.map { "used of \(Display.bytes($0.total))" } ?? "Memory unavailable", "memorychip",
        segments: memorySegments, composition: memoryCaption,
        barCaption: composition.map {
          "App \(Display.bytes($0.app)) · wired \(Display.bytes($0.wired))\nCompressed \(Display.bytes($0.compressed))"
        } ?? "Unavailable"),
      tile(
        volume?.name ?? "Startup disk",
        volume.map { Display.bytes(min($0.available, $0.total)) } ?? "—",
        volume.map { "available of \(Display.bytes($0.total))" } ?? "Volume unavailable",
        "internaldrive",
        segments: volume.map { [.init(fraction: $0.percent / 100, color: SystemStyle.accent)] }
          ?? [],
        composition: volume.map { "\(Display.percent($0.percent)) used" }
          ?? "Storage capacity unavailable"),
      .init(
        frame: .zero, title: "NETWORK",
        trailing: s.selectedInterface.isEmpty ? "No primary route" : s.selectedInterface,
        content: .plot(network)),
      tile(
        "CPU temperature", temperature,
        "\(cpuSensors.isEmpty ? "CPU sensors unavailable" : "Hottest of \(cpuSensors.count) CPU sensors"), \(fanCaption)",
        "thermometer.medium"),
      tile(
        battery == nil ? "System power" : "Battery",
        battery.map { Display.percent($0.percent) } ?? power.map { $0.formatted(fahrenheit: false) }
          ?? "—",
        battery.map { BatteryMenuState.state(for: $0).title } ?? "AC power · no internal battery",
        "bolt"),
      tile(
        "Disk read", Display.rate(s.diskRead), "All physical disks", "internaldrive",
        key: \.diskRead),
      tile(
        "Disk write", Display.rate(s.diskWrite), "All physical disks", "internaldrive",
        key: \.diskWrite),
      tile(
        "Swap used", memory.map { Display.bytes($0.swapUsed) } ?? "—",
        memory.map { "Compressed \(Display.bytes($0.compressed))" } ?? "Memory unavailable",
        "memorychip"),
    ]
  }

  func drawOverviewCard(_ card: Card) {
    switch card.content {
    case .device(let header): drawDeviceHeader(header, in: card.frame)
    case .overviewTile(let tile): drawOverviewTile(tile, in: card.frame)
    case .plot(let plot): drawOverviewNetwork(plot, title: card.trailing, in: card.frame)
    default: break
    }
  }

  func drawDeviceHeader(_ header: DeviceHeader, in rect: NSRect) {
    let compact = rect.width < 650
    let deviceWidth = compact ? rect.width - 76 : max(180, rect.width - 440)
    NSApp.applicationIconImage?.draw(
      in: .init(x: rect.minX + 14, y: rect.minY + 12, width: 40, height: 40),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    text(
      header.model,
      rect: .init(x: rect.minX + 66, y: rect.minY + 14, width: deviceWidth - 8, height: 20),
      size: 15, weight: .semibold)
    text(
      header.subtitle,
      rect: .init(x: rect.minX + 66, y: rect.minY + 36, width: deviceWidth - 8, height: 16),
      color: .secondaryLabelColor, size: 11)
    let statsX = compact ? rect.minX + 16 : rect.maxX - 366
    let statsWidth = compact ? rect.width - 32 : rect.maxX - statsX - 16
    for (index, item) in [
      ("Uptime", header.uptime, NSColor.labelColor),
      ("Thermal state", header.thermal, header.thermalColor),
      ("Memory pressure", header.pressure, header.pressureColor),
    ].enumerated() {
      let width: CGFloat = compact ? statsWidth / 3 : [80, 106, 136][index]
      let x = compact ? statsX + CGFloat(index) * width : statsX + [0, 94, 214][index]
      let y = compact ? rect.minY + 62 : rect.minY + 17
      text(
        item.0, rect: .init(x: x, y: y, width: compact ? width * 0.58 : width, height: 15),
        color: .secondaryLabelColor, size: 11, alignment: compact ? .left : .right)
      text(
        item.1,
        rect: .init(
          x: compact ? x + width * 0.55 : x, y: compact ? y : y + 19,
          width: compact ? width * 0.45 - 10 : width, height: 18), color: item.2,
        size: compact ? 11 : 13, weight: .semibold, alignment: .right)
    }
  }

  func drawOverviewSymbol(_ symbol: String, label: String, in rect: NSRect) {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(
        .init(pointSize: 13, weight: .regular).applying(
          .init(paletteColors: [.secondaryLabelColor])))
    image?.draw(
      in: .init(x: rect.minX + 14, y: rect.minY + 12, width: 15, height: 15), from: .zero,
      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    text(
      label, rect: .init(x: rect.minX + 35, y: rect.minY + 12, width: rect.width - 45, height: 17),
      color: .secondaryLabelColor, size: 12, weight: .medium)
  }

  /// Values retain monospaced digits; units recede like the approved board.
  func drawOverviewValue(_ value: String, in rect: NSRect, size: CGFloat) {
    let suffix = value.firstIndex { !$0.isNumber && $0 != "." && $0 != "," && $0 != "−" }
    let number = suffix.map { String(value[..<$0]) } ?? value
    guard !number.isEmpty, let suffix else {
      text(value, rect: rect, size: size, weight: .semibold)
      return
    }
    let numberFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    let unitFont = NSFont.systemFont(ofSize: size > 24 ? 16 : 13)
    let text = NSMutableAttributedString(
      string: number, attributes: [.font: numberFont, .foregroundColor: NSColor.labelColor])
    text.append(
      NSAttributedString(
        string: String(value[suffix...]),
        attributes: [.font: unitFont, .foregroundColor: NSColor.secondaryLabelColor]))
    text.draw(in: rect)
  }

  static func overviewSparkline(in rect: NSRect) -> NSRect {
    .init(x: rect.minX, y: rect.maxY - 34, width: rect.width, height: 34)
  }
  func drawOverviewTile(_ tile: OverviewTile, in rect: NSRect) {
    drawOverviewSymbol(tile.symbol, label: tile.value.label, in: rect)
    let large = rect.height >= 120
    drawOverviewValue(
      tile.value.value,
      in: .init(
        x: rect.minX + 14, y: rect.minY + (large ? 41 : 31), width: rect.width - 28,
        height: large ? 37 : 28), size: large ? 30 : 22)
    let detailRect = NSRect(
      x: rect.minX + 14, y: rect.minY + (large ? 81 : 59), width: rect.width - 28,
      height: large ? 29 : max(0, rect.height - 61))
    text(tile.value.detail, rect: detailRect, color: .secondaryLabelColor, size: 11)
    if let segments = tile.segments {
      SegmentedBarView.draw(
        segments, in: .init(x: rect.minX + 14, y: rect.maxY - 47, width: rect.width - 28, height: 8)
      )
      let caption = tile.barCaption ?? tile.composition
      let lines = caption.components(separatedBy: "\n").flatMap {
        rect.width < 190 ? $0.components(separatedBy: " · ") : [$0]
      }
      let threeLines = lines.count > 2
      for (index, line) in lines.prefix(3).enumerated() {
        text(
          String(line),
          rect: .init(
            x: rect.minX + 14,
            y: rect.maxY - (threeLines ? 37 : 34) + CGFloat(index) * (threeLines ? 11 : 13),
            width: rect.width - 28,
            height: 14), color: .secondaryLabelColor, size: 10)
      }
    } else if large, let trend = tile.value.trend {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(
        roundedRect: rect, xRadius: SystemStyle.Radius.platter, yRadius: SystemStyle.Radius.platter
      ).addClip()
      drawMiniHistory(trend, in: Self.overviewSparkline(in: rect))
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  static func overviewNetworkGraph(in rect: NSRect) -> NSRect {
    .init(
      x: rect.minX + 14, y: rect.minY + 62, width: max(0, rect.width - 28),
      height: max(0, rect.height - 86))
  }
  func drawOverviewNetwork(_ plot: Plot, title: String, in rect: NSRect) {
    drawOverviewSymbol("network", label: "Network", in: rect)
    text(
      title, rect: .init(x: rect.midX, y: rect.minY + 12, width: rect.width / 2 - 14, height: 17),
      color: .secondaryLabelColor, size: 11, alignment: .right)
    drawSeriesLegend(
      "↓ " + plot.firstValue, marker: plot.firstRole.legendMarker, color: plot.firstColor,
      rect: .init(x: rect.minX + 14, y: rect.minY + 36, width: rect.width / 2 - 14, height: 18),
      size: 13, weight: .semibold)
    drawSeriesLegend(
      "↑ " + plot.secondValue, marker: plot.secondRole.legendMarker, color: plot.secondColor,
      rect: .init(x: rect.midX, y: rect.minY + 36, width: rect.width / 2 - 14, height: 18),
      size: 13, weight: .semibold, alignment: .right)
    let graph = Self.overviewNetworkGraph(in: rect)
    let maximum = max(
      1, (plot.first + plot.second).compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }.max() ?? 1)
    NSColor.separatorColor.withAlphaComponent(0.5).setFill()
    for fraction in [0.25, 0.5, 0.75] {
      NSRect(
        x: graph.minX, y: graph.minY + graph.height * fraction, width: graph.width, height: 0.5
      ).fill()
    }
    drawMiniHistory(plot, in: graph, upperBound: maximum)
    if (plot.first + plot.second).allSatisfy({ $0 == nil || !($0?.isFinite ?? false) }) {
      text(
        plot.times.isEmpty ? "No readings yet" : "Readings unavailable",
        rect: graph.insetBy(dx: 8, dy: max(0, graph.height / 2 - 8)), color: .secondaryLabelColor,
        size: 12, alignment: .center)
    }
    var upload = plot
    upload.first = plot.second
    upload.firstColor = plot.secondColor
    upload.firstRole = plot.secondRole
    drawMiniHistory(upload, in: graph, upperBound: maximum)
    text(
      "5 minutes ago",
      rect: .init(x: graph.minX, y: rect.maxY - 20, width: graph.width / 2, height: 14),
      color: .secondaryLabelColor, size: 10)
    text(
      "Now · 0–" + Display.rate(maximum),
      rect: .init(x: graph.midX, y: rect.maxY - 20, width: graph.width / 2, height: 14),
      color: .secondaryLabelColor, size: 10, alignment: .right)
  }
}
