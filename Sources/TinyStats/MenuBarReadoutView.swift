import AppKit
import TinyStatsCore

struct MenuBarReadout {
  var label: String, value: String, secondary: String?
  var style: MenuBarStyle
  var appearance = MenuBarAppearance()
  var symbol = "cpu"
  var charging = false
  var batteryAbsent = false
  var progress: Double?
  var historyMaximum: Double? = 100
  var values: [Double?] = []
  var secondValues: [Double?] = []
  var cores: [Double?] = []
  var coreKinds: [CPUCoreKind] = []
  var clock: ClockMenuContent?
  var isNetwork = false
  var module: Module? = nil

  func coreKind(at index: Int) -> CPUCoreKind {
    guard coreKinds.count == cores.count, coreKinds.indices.contains(index) else { return .unknown }
    return coreKinds[index]
  }
  /// An extra gap separates verified core-kind runs without relying on hue.
  func coreGap(before index: Int) -> CGFloat {
    index > 0 && coreKind(at: index) != coreKind(at: index - 1) ? 2 : 0
  }
  var coreBarsWidth: CGFloat {
    let count = min(32, cores.count)
    return max(18, CGFloat(count) * 3 + (0..<count).reduce(0) { $0 + coreGap(before: $1) })
  }

  @MainActor static func make(
    module: Module, snapshot s: Snapshot, settings: Settings, history: [HistoryPoint],
    clockDate: Date? = nil
  ) -> Self {
    var style = settings.style(for: module)
    var label = module.title.uppercased()
    var symbol = module.symbol
    var value = "—"
    var secondary: String?
    var progress: Double?
    var key: KeyPath<HistoryPoint, Double?>?
    switch module {
    case .cpu:
      progress = s.cpu?.usage
      value = Display.percent(progress)
      key = \.cpu
    case .gpu:
      progress = s.gpus.compactMap(\.usage).max()
      value = Display.percent(progress)
      key = \.gpu
    case .memory:
      label = "MEM"
      progress = s.memory?.percent
      value = Display.percent(progress)
      key = \.memory
    case .disks:
      label = "SSD"
      progress = s.startupVolume?.percent
      value = Display.percent(progress)
    case .network:
      label = "NET"
      value = "↑ " + rate(s.upload)
      secondary = "↓ " + rate(s.download)
      key = \.download
    case .sensors:
      if let sensor = s.sensor(for: settings.sensorKey) {
        label = sensor.menuLabel
        value = sensor.formatted(fahrenheit: settings.fahrenheit, compact: true)
        if sensor.kind == .temperature { progress = sensor.value / 120 * 100 }
      } else {
        label = "SENSOR"
      }
    case .battery:
      let reading = s.batteries.first
      let preset = settings.batteryMenu.preset(for: reading, defaultStyle: style)
      style = preset.style
      let text = BatteryMenuText(reading: reading, format: preset.format)
      label = style.showsBatteryValue ? text.label : "BAT"
      value = text.value
      secondary = text.secondary
      progress = reading?.percent
      if let level = progress, !level.isFinite || !(0...100).contains(level) { progress = nil }
      key = \.battery
    case .clock:
      if settings.clockMenu.custom,
        let clock = ClockMenuRenderer.readouts(settings: settings, at: clockDate ?? s.timestamp)
          .first
      {
        var result = clock
        result.module = .clock
        return result
      }
      let date = clockDate ?? s.timestamp
      let components = Calendar.current.dateComponents([.hour, .minute], from: date)
      label = Calendar.current.shortWeekdaySymbols[
        Calendar.current.component(.weekday, from: date) - 1
      ].uppercased()
      value = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    case .weather:
      let weather = s.weather.filtered(settings: settings.weather)
      label =
        !settings.weather.enabled
        ? "Off"
        : settings.weather.source == .currentLocation && settings.weather.location == nil
          ? "Set location" : weather.checking ? "Updating" : "Unavailable"
      symbol = "questionmark.circle"
      if let current = weather.current(
        at: s.uptime, date: s.timestamp)
      {
        if let celsius = current.celsius {
          value = String(
            format: "%.0f°%@", settings.fahrenheit ? celsius * 1.8 + 32 : celsius,
            settings.fahrenheit ? "F" : "C")
        }
        symbol = current.systemSymbol
        switch current.condition {
        case "Clear": label = current.symbol?.hasSuffix("_day") == true ? "Sunny" : "Clear"
        case "Rain": label = "Rainy"
        case "Snow": label = "Snowy"
        case "Fog": label = "Foggy"
        case "Condition unavailable": label = "Unknown"
        default: label = current.condition
        }
      }
    case .overview: label = "TinyStats"
    }
    var values = key.map { path in Array(history.suffix(40)).map { $0[keyPath: path] } } ?? []
    if module == .disks { values = Array(history.suffix(40)).map(\.diskUsed) }
    var historyMaximum: Double? = module == .network ? nil : 100
    if module == .sensors {
      values = history.suffix(40).map { $0.sensorKey == settings.sensorKey ? $0.sensorValue : nil }
      if settings.sensorKey == "cpu" || settings.sensorKey.hasPrefix("T") {
        values = values.map { $0.map { $0 / 120 * 100 } }
      } else {
        historyMaximum = nil
      }
    }
    return .init(
      label: label, value: value, secondary: secondary, style: style,
      appearance: settings.appearance(for: module), symbol: symbol,
      charging: module == .battery
        && s.batteries.first.map { BatteryMenuState.state(for: $0) == .charging } == true,
      batteryAbsent: module == .battery && s.batteries.isEmpty,
      progress: progress, historyMaximum: historyMaximum,
      values: values,
      secondValues: module == .network ? Array(history.suffix(40)).map(\.upload) : [],
      cores: module == .cpu ? s.cpu?.cores ?? [] : [],
      coreKinds: module == .cpu ? s.cpu?.coreKinds ?? [] : [], isNetwork: module == .network,
      module: module)
  }
  private static func rate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"]
    var amount = value
    var index = 0
    while amount >= 999.5 && index < units.count - 1 {
      amount /= 1000
      index += 1
    }
    if amount >= 999.5 { return ">999 EB/s" }
    return String(format: amount < 10 && index > 0 ? "%.1f %@" : "%.0f %@", amount, units[index])
  }
}

/// One immediate-mode view per status button. Symbols and fonts are bounded shared caches;
/// graphs reuse the sampled history. No layers, animations or additional timers.
@MainActor final class MenuBarReadoutView: SystemStyledView {
  var readouts: [MenuBarReadout] = []
  var paused = false
  // Shared compact geometry for native items, previews and segment hit testing.
  let sidePadding: CGFloat = 0
  let itemSpacing: CGFloat = 1
  private static let verticalLabelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
  private static let fonts = Dictionary(
    uniqueKeysWithValues: MenuBarSize.allCases.map {
      ($0, NSFont.monospacedDigitSystemFont(ofSize: $0.pointSize, weight: .semibold))
    })
  private static let networkFonts = Dictionary(
    uniqueKeysWithValues: MenuBarSize.allCases.map {
      (
        $0,
        NSFont.monospacedDigitSystemFont(
          ofSize: $0 == .compact ? 10 : $0 == .standard ? 10.5 : 11, weight: .semibold)
      )
    })
  private static func rateWidth(_ font: NSFont) -> CGFloat {
    let candidates =
      ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"].flatMap {
        ["↑ 999 \($0)", "↓ 10.0 \($0)"]
      } + ["↑ >999 EB/s", "↓ >999 EB/s"]
    return ceil(
      candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
  }
  private static let networkStackWidths = networkFonts.mapValues { rateWidth($0) }
  private static let networkInlineWidths = fonts.mapValues { rateWidth($0) }
  private static let small = NSFont.systemFont(ofSize: 9, weight: .medium)
  private static let calendarFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
  private static let smallCalendarFont = NSFont.monospacedDigitSystemFont(
    ofSize: 7, weight: .semibold)
  private static let symbols = Dictionary(
    uniqueKeysWithValues: (Module.allCases.map(\.symbol) + [
      "bolt.fill", "powerplug", "cloud", "cloud.bolt.rain", "cloud.sleet", "cloud.snow",
      "cloud.rain", "cloud.fog", "moon.stars", "sun.max", "cloud.moon", "questionmark.circle",
    ]).compactMap {
      name in
      NSImage(systemSymbolName: name, accessibilityDescription: nil).map { (name, $0) }
    })
  // Preserve the parent status button's click behavior.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  private func font(_ item: MenuBarReadout) -> NSFont { Self.fonts[item.appearance.size]! }
  private func size(_ value: String, font: NSFont) -> NSSize {
    (value as NSString).size(withAttributes: [.font: font])
  }
  private func stackWidth(_ item: MenuBarReadout) -> CGFloat {
    if item.isNetwork { return Self.networkStackWidths[item.appearance.size]! }
    return max(
      29,
      ceil(
        max(
          size(
            item.secondary == nil ? item.label : item.value,
            font: item.secondary == nil ? Self.small : stackedFont(item)
          ).width,
          size(item.secondary ?? item.value, font: stackedFont(item)).width)))
  }
  private func stackedFont(_ item: MenuBarReadout) -> NSFont {
    // Two value lines fit in the same native menu bar height as a label/value pair.
    item.secondary == nil ? font(item) : Self.networkFonts[item.appearance.size]!
  }
  private func line(_ item: MenuBarReadout, label: Bool) -> String {
    (label ? item.label + " " : "") + item.value + (item.secondary.map { " " + $0 } ?? "")
  }
  private func width(_ item: MenuBarReadout) -> CGFloat {
    if item.isNetwork, item.style == .text || item.style == .value {
      let prefix = item.style == .text ? ceil(size(item.label + " ", font: font(item)).width) : 0
      return ceil(
        prefix + 2 * Self.networkInlineWidths[item.appearance.size]!
          + size(" ", font: font(item)).width)
    }
    if let clock = item.clock {
      switch item.style {
      case .text:
        return ceil(size(item.label + " ", font: font(item)).width)
          + clockWidth(clock.joined, font: font(item), stacked: false)
      case .value: return clockWidth(clock.joined, font: font(item), stacked: false)
      case .stacked:
        return max(
          29,
          max(
            clockWidth(clock.first, font: stackedFont(item), stacked: true),
            clock.second.map { clockWidth($0, font: stackedFont(item), stacked: true) } ?? 0))
      default: break
      }
    }
    switch item.style {
    case .text: return ceil(size(line(item, label: true), font: font(item)).width)
    case .value: return ceil(size(line(item, label: false), font: font(item)).width)
    case .label: return max(16, ceil(size(item.label, font: font(item)).width))
    case .icon: return 18
    case .stacked: return stackWidth(item)
    case .history: return 43
    case .historyValue: return 49 + stackWidth(item)
    case .bar: return 13
    case .labeledBar: return 28
    case .horizontal: return max(30, ceil(size(item.label, font: Self.small).width))
    case .pie, .ring: return 19
    case .cores: return item.coreBarsWidth
    case .battery: return item.charging ? 39 : 27
    }
  }
  var preferredWidth: CGFloat {
    var total = 2 * sidePadding
    if paused { total += 12 }
    for readout in readouts { total += width(readout) }
    if readouts.count > 1 { total += CGFloat(readouts.count - 1) * itemSpacing }
    return total
  }
  /// Native clicks can select a segment in One; accessibility activation uses the first module.
  func module(at x: CGFloat) -> Module? {
    var edge = sidePadding + (paused ? 12 : 0)
    for readout in readouts {
      edge += width(readout) + itemSpacing
      if x < edge { return readout.module }
    }
    return readouts.last?.module
  }
  var onAppearanceChange: (() -> Void)?

  override func systemStyleDidChange() {
    super.systemStyleDidChange()
    needsDisplay = true
    onAppearanceChange?()
  }

  override func draw(_ dirtyRect: NSRect) {
    let palette = MenuBarPalette.resolve(effectiveAppearance)
    var x = sidePadding
    if paused {
      text(
        palette: palette,
        "Ⅱ", in: .init(x: x, y: 0, width: 12, height: bounds.height), font: Self.fonts[.standard]!)
      x += 12
    }
    for item in readouts {
      let w = width(item)
      let tint = palette.graphic(item.module)
      let whole = NSRect(x: x, y: 0, width: w, height: bounds.height)
      let rect = NSRect(x: x, y: floor((bounds.height - 16) / 2), width: w, height: 16)
      switch item.style {
      case .text, .value, .label:
        if let clock = item.clock, item.style != .label {
          var target = whole
          if item.style == .text {
            let prefix = item.label + " "
            text(palette: palette, prefix, in: target, font: font(item))
            let shift = ceil(size(prefix, font: font(item)).width)
            target.origin.x += shift
            target.size.width -= shift
          }
          drawClock(
            palette: palette, clock.joined, in: target, font: font(item), color: tint,
            stacked: false)
        } else if item.isNetwork, item.style != .label {
          let prefix = item.style == .text ? item.label + " " : ""
          let offset = ceil(size(prefix, font: font(item)).width)
          let fieldWidth = Self.networkInlineWidths[item.appearance.size]!
          text(palette: palette, prefix, in: whole, font: font(item))
          networkText(
            palette: palette,
            item.value,
            in: .init(
              x: whole.minX + offset, y: whole.minY, width: fieldWidth, height: whole.height),
            font: font(item))
          let secondX = whole.minX + offset + fieldWidth + size(" ", font: font(item)).width
          networkText(
            palette: palette,
            item.secondary ?? "↓ —",
            in: .init(x: secondX, y: whole.minY, width: fieldWidth, height: whole.height),
            font: font(item))
        } else {
          text(
            palette: palette,
            item.style == .label ? item.label : line(item, label: item.style == .text),
            in: whole, font: font(item))
        }
      case .icon:
        symbol(item.symbol, in: rect, color: tint)
      case .stacked:
        stack(palette: palette, item, in: whole, color: tint)
      case .history, .historyValue:
        let chart = NSRect(x: rect.minX, y: rect.minY, width: 43, height: 16)
        let domain = GraphDomain(
          values: item.values + item.secondValues, fixedUpper: item.historyMaximum)
        tint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: chart, xRadius: 2, yRadius: 2).fill()
        if domain.lower < 0, let zero = domain.fraction(0) {
          tint.withAlphaComponent(0.35).setFill()
          NSRect(
            x: chart.minX, y: chart.minY + chart.height * zero, width: chart.width, height: 0.5
          ).fill()
        }
        drawHistory(item.values, in: chart, domain: domain, color: tint)
        drawHistory(
          item.secondValues, in: chart, domain: domain, color: palette.secondary, dashed: true)
        if (item.values + item.secondValues).compactMap({ $0 }).isEmpty {
          text(palette: palette, "—", in: chart, font: Self.small, centered: true)
        }
        if item.style == .historyValue {
          stack(
            palette: palette,
            item, in: NSRect(x: x + 49, y: 0, width: w - 49, height: bounds.height), color: tint)
        }
      case .bar:
        gauge(
          palette: palette, item.progress, in: rect.insetBy(dx: 1, dy: 0.5), vertical: true,
          color: tint)
      case .labeledBar:
        let letters = Array(item.label.prefix(3))
        let height = min(22, bounds.height - 2)
        let bottom = (bounds.height - height) / 2
        for (index, letter) in letters.enumerated() {
          text(
            palette: palette,
            String(letter),
            in: .init(
              x: x,
              y: bottom + height - CGFloat(index + 1) * height / CGFloat(max(1, letters.count)),
              width: 9, height: height / CGFloat(max(1, letters.count)) + 2),
            font: Self.verticalLabelFont, centered: true)
        }
        gauge(
          palette: palette,
          item.progress, in: .init(x: x + 13, y: bottom, width: 12, height: height), vertical: true,
          color: tint)
      case .horizontal:
        let height = min(22, bounds.height)
        let y = floor((bounds.height - height) / 2)
        text(
          palette: palette,
          item.label, in: .init(x: x, y: y + 9, width: w, height: height - 9), font: Self.small)
        gauge(
          palette: palette,
          item.progress, in: .init(x: x, y: y + 1, width: w, height: 7), vertical: false,
          color: tint)
      case .pie, .ring:
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = item.style == .ring ? 6.5 : 8
        let background = NSBezierPath(
          ovalIn: .init(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if item.style == .ring {
          tint.withAlphaComponent(0.2).setStroke()
          background.lineWidth = 3
          background.stroke()
        } else {
          tint.withAlphaComponent(0.2).setFill()
          background.fill()
        }
        if let progress = item.progress, progress.isFinite {
          if progress > 0 {
            let path = NSBezierPath()
            if item.style == .pie { path.move(to: center) }
            path.appendArc(
              withCenter: center, radius: radius, startAngle: 90,
              endAngle: 90 - CGFloat(min(100, max(0, progress))) * 3.6, clockwise: true)
            if item.style == .ring {
              tint.setStroke()
              path.lineWidth = 3
              path.stroke()
            } else {
              path.close()
              tint.setFill()
              path.fill()
            }
          }
        } else {
          text(palette: palette, "—", in: rect, font: Self.small, centered: true)
        }
      case .cores:
        var coreX = x
        for (index, value) in item.cores.prefix(32).enumerated() {
          coreX += item.coreGap(before: index)
          let coreTint = palette.core(item.coreKind(at: index))
          let bar = NSRect(x: coreX, y: rect.minY, width: 2, height: rect.height)
          coreX += 3
          coreTint.withAlphaComponent(0.2).setFill()
          bar.fill()
          if let value, value.isFinite {
            coreTint.setFill()
            NSRect(
              x: bar.minX, y: bar.minY, width: 2,
              height: bar.height * min(1, max(0, value / 100))
            ).fill()
          }
        }
        if item.cores.compactMap({ $0 }).isEmpty {
          text(palette: palette, "—", in: rect, font: Self.small, centered: true)
        }
      case .battery:
        if item.batteryAbsent {
          symbol("powerplug", in: rect, color: tint)
        } else {
          let body = NSRect(x: rect.minX, y: rect.minY + 2, width: 23, height: 12)
          gauge(palette: palette, item.progress, in: body, vertical: false, color: tint)
          tint.setFill()
          NSRect(x: body.maxX + 1, y: body.minY + 4, width: 2, height: 4).fill()
          if item.charging {
            symbol(
              "bolt.fill", in: .init(x: body.maxX + 5, y: rect.minY + 1, width: 10, height: 14),
              color: tint)
          }
        }
      }
      x += w + itemSpacing
    }
  }
  private func stack(
    palette: MenuBarPalette, _ item: MenuBarReadout, in rect: NSRect, color: NSColor
  ) {
    let height = min(24, rect.height)
    let bottom = floor(rect.midY - height / 2)
    let split = item.secondary == nil ? height * 0.55 : height / 2
    if let clock = item.clock {
      drawClock(
        palette: palette,
        clock.first,
        in: .init(x: rect.minX, y: bottom + split, width: rect.width, height: height - split),
        font: stackedFont(item), color: color, stacked: true)
      if let second = clock.second {
        drawClock(
          palette: palette,
          second, in: .init(x: rect.minX, y: bottom, width: rect.width, height: split),
          font: stackedFont(item), color: color, stacked: true)
      }
      return
    }
    if item.isNetwork {
      networkText(
        palette: palette,
        item.value,
        in: .init(x: rect.minX, y: bottom + split, width: rect.width, height: height - split),
        font: stackedFont(item))
      networkText(
        palette: palette,
        item.secondary ?? "↓ —",
        in: .init(x: rect.minX, y: bottom, width: rect.width, height: split),
        font: stackedFont(item))
      return
    }
    text(
      palette: palette,
      item.secondary == nil ? item.label : item.value,
      in: .init(x: rect.minX, y: bottom + split, width: rect.width, height: height - split),
      font: item.secondary == nil ? Self.small : stackedFont(item),
      rightAligned: item.isNetwork)
    text(
      palette: palette,
      item.secondary ?? item.value,
      in: .init(x: rect.minX, y: bottom, width: rect.width, height: split),
      font: stackedFont(item), rightAligned: item.isNetwork)
  }
  // Keep direction markers at the leading edge so short rates do not look like
  // inter-item padding. The numeric field still has a fixed, right-aligned edge.
  private func networkText(palette: MenuBarPalette, _ value: String, in rect: NSRect, font: NSFont)
  {
    guard let direction = value.first, direction == "↑" || direction == "↓" else {
      text(palette: palette, value, in: rect, font: font, rightAligned: true)
      return
    }
    text(palette: palette, String(direction), in: rect, font: font)
    text(palette: palette, String(value.dropFirst()), in: rect, font: font, rightAligned: true)
  }
  private func clockWidth(_ line: ClockMenuLine, font: NSFont, stacked: Bool) -> CGFloat {
    ceil(
      line.parts.reduce(CGFloat.zero) { width, part in
        if case .text(let text) = part { return width + size(text, font: font).width }
        return width + (stacked ? 14 : 22)
      })
  }
  private func drawClock(
    palette: MenuBarPalette,
    _ line: ClockMenuLine, in rect: NSRect, font: NSFont, color: NSColor, stacked: Bool
  ) {
    var x = rect.minX
    for part in line.parts {
      switch part {
      case .text(let value):
        let width = size(value, font: font).width
        text(
          palette: palette,
          value, in: .init(x: x, y: rect.minY, width: width, height: rect.height), font: font)
        x += width
      case .dial(let reading):
        let width: CGFloat = stacked ? 14 : 22
        let side = min(width - 2, rect.height - 2)
        guard side > 0 else {
          x += width
          continue
        }
        let box = NSRect(
          x: x + (width - side) / 2, y: rect.midY - side / 2, width: side, height: side)
        drawDial(reading, in: box, color: color)
        x += width
      case .calendar(let day):
        let width: CGFloat = stacked ? 14 : 22
        let side = min(width - 2, rect.height - 2)
        guard side > 0 else {
          x += width
          continue
        }
        let box = NSRect(
          x: x + (width - side) / 2, y: rect.midY - side / 2, width: side, height: side)
        color.setStroke()
        color.withAlphaComponent(0.1).setFill()
        let outline = NSBezierPath(
          roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.fill()
        outline.stroke()
        let rule = NSBezierPath()
        rule.move(to: .init(x: box.minX + 1, y: box.maxY - (stacked ? 2 : 4)))
        rule.line(to: .init(x: box.maxX - 1, y: box.maxY - (stacked ? 2 : 4)))
        rule.lineWidth = 1
        rule.stroke()
        text(
          palette: palette,
          String(day), in: box.offsetBy(dx: 0, dy: stacked ? -0.5 : -1.5),
          font: stacked ? Self.smallCalendarFont : Self.calendarFont, centered: true)
        x += width
      }
    }
  }
  private func drawDial(_ reading: ClockDialReading, in rect: NSRect, color: NSColor) {
    color.setStroke()
    let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
    circle.lineWidth = 1
    circle.stroke()
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width / 2
    let ticks = NSBezierPath()
    for angle in [0.0, 90, 180, 270] {
      let radians = angle * .pi / 180
      ticks.move(
        to: .init(
          x: center.x + CGFloat(sin(radians)) * radius * 0.8,
          y: center.y + CGFloat(cos(radians)) * radius * 0.8))
      ticks.line(
        to: .init(
          x: center.x + CGFloat(sin(radians)) * radius * 0.95,
          y: center.y + CGFloat(cos(radians)) * radius * 0.95))
    }
    ticks.lineWidth = 0.7
    ticks.stroke()
    func hand(_ angle: Double, _ length: CGFloat, _ width: CGFloat) {
      let radians = angle * .pi / 180
      let path = NSBezierPath()
      path.move(to: center)
      path.line(
        to: .init(
          x: center.x + CGFloat(sin(radians)) * radius * length,
          y: center.y + CGFloat(cos(radians)) * radius * length))
      path.lineWidth = width
      path.lineCapStyle = .round
      path.stroke()
    }
    hand(reading.hourDegrees, 0.48, 1.5)
    hand(reading.minuteDegrees, 0.76, 1)
    if let second = reading.secondDegrees {
      color.withAlphaComponent(0.6).setStroke()
      hand(second, 0.82, 0.7)
    }
  }
  private func gauge(
    palette: MenuBarPalette, _ value: Double?, in rect: NSRect, vertical: Bool, color: NSColor
  ) {
    palette.gaugeOutline.setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
    path.lineWidth = 1
    path.stroke()
    if let value, value.isFinite {
      let inner = rect.insetBy(dx: 2, dy: 2)
      let fraction = min(1, max(0, value / 100))
      color.setFill()
      NSRect(
        x: inner.minX, y: inner.minY, width: inner.width * (vertical ? 1 : fraction),
        height: inner.height * (vertical ? fraction : 1)
      ).fill()
    } else {
      text(palette: palette, "—", in: rect, font: Self.small, centered: true)
    }
  }
  // Labels and numbers follow the host bar; metric colors carry graphical readings.
  private func text(
    palette: MenuBarPalette,
    _ value: String, in rect: NSRect, font: NSFont, centered: Bool = false,
    rightAligned: Bool = false
  ) {
    let extent = size(value, font: font)
    let attributes: [NSAttributedString.Key: Any]
    if let shadow = palette.textShadow {
      attributes = [.font: font, .foregroundColor: palette.text, .shadow: shadow]
    } else {
      attributes = [.font: font, .foregroundColor: palette.text]
    }
    (value as NSString).draw(
      at: .init(
        x: centered
          ? rect.midX - extent.width / 2 : rightAligned ? rect.maxX - extent.width : rect.minX,
        y: floor(rect.midY - extent.height / 2)),
      withAttributes: attributes)
  }
  private func symbol(_ name: String, in rect: NSRect, color: NSColor) {
    guard let image = Self.symbols[name] else { return }
    let target = NSRect(
      x: rect.midX - min(16, rect.width) / 2,
      y: rect.midY - min(16, rect.height) / 2, width: min(16, rect.width),
      height: min(16, rect.height))
    // Tint with a graphics operation instead of allocating a new image on every sample.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    image.draw(in: target)
    color.setFill()
    target.fill(using: .sourceIn)
    NSGraphicsContext.current?.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
  }
  private func drawHistory(
    _ values: [Double?], in rect: NSRect, domain: GraphDomain, color: NSColor, dashed: Bool = false
  ) {
    let path = NSBezierPath()
    var continuing = false
    for (index, value) in values.enumerated() {
      guard let fraction = domain.fraction(value) else {
        continuing = false
        continue
      }
      let point = NSPoint(
        x: rect.minX + rect.width * CGFloat(index) / CGFloat(max(1, values.count - 1)),
        y: rect.minY + rect.height * fraction)
      if continuing { path.line(to: point) } else { path.move(to: point) }
      continuing = true
    }
    color.setStroke()
    if dashed { path.setLineDash([3, 2], count: 2, phase: 0) }
    path.lineWidth = 1
    path.stroke()
  }
}
