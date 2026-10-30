import AppKit
import TinyStatsCore

/// Owns module assembly, layout, accessibility lifetime, and history charts.
/// Card presentation lives in SummaryDashboardCards.swift and draws in this same view.
/// No layers, per-card controls or timers. Overview draws the existing app icon.
@MainActor final class SummaryDashboardView: ChartHoverView {
  /// Availability of a statistic among valid readings, not coverage of elapsed time.
  struct ObservationCoverage {
    let recorded: UInt64, valid: UInt64
    var label: String { "\(recorded)/\(valid) readings" }
    var isPartial: Bool { recorded > 0 && recorded < valid }
    var badge: String? {
      if valid == 0 { return "No readings" }
      if recorded == 0 { return "Unavailable" }
      return isPartial ? "Partial" : nil
    }
  }
  struct Plot {
    var first: [Double?], second: [Double?]
    var firstLabel: String, secondLabel: String
    var firstValue: String, secondValue: String
    var percent: Bool, mirrored: Bool
    var firstColor: NSColor = SystemStyle.accent, secondColor: NSColor = SystemStyle.secondaryAccent
    var firstRole: ChartSeriesRole = .primary, secondRole: ChartSeriesRole = .secondary
    /// Immutable inputs and their derived positions move together; no width/statistic cache.
    struct TimeAxis {
      let times: [Date]
      let domain: ClosedRange<Date>?
      let timeline: HistoryTimeline
      init(_ times: [Date], intervals: [Double?] = [], domain: ClosedRange<Date>? = nil) {
        self.times = times
        self.domain = domain
        timeline = HistoryTimeline(times: times, intervals: intervals, domain: domain)
      }
    }
    var time: TimeAxis
    var times: [Date] { time.times }
    var domain: ClosedRange<Date>? { time.domain }
    var bucketSeconds: Double? = nil
    var historySpan: String? = nil
    var uncollectedFraction: Double? = nil
    var axisLabels: (String, String)? = nil
    var partialFirst: [Bool] = [], partialSecond: [Bool] = []
    var gapBuckets: [Bool] = []
    var statistic: HistoryStatistic = .peak
    var firstWeights: [UInt32] = [], secondWeights: [UInt32] = []
    var sampleBounds: [ClosedRange<Date>] = []
    var valueFormat: ChartValueFormat = .number
    var alignsCoreHistory = false
    var drawsTrace = false
    var coverage: [String] = []
    var firstCoverage: ObservationCoverage? = nil, secondCoverage: ObservationCoverage? = nil
    var timeline: HistoryTimeline { time.timeline }
    var duration: Double { timeline.duration }
    var xFractions: [Double?] { timeline.positions }
  }

  /// Trace and bar modes disclose the same observed time span and availability.
  /// The trace's unsigned range uses the exact maximum passed to its renderer.
  struct PlotCaptions {
    let emptyMessage: String?
    let span: String
    let scale: String
    init(_ plot: Plot, layout: HistoryBarLayout, trace: Bool) {
      emptyMessage =
        layout.hasData
        ? nil
        : layout.timeline.indices.isEmpty
          ? "No readings yet" : "No readings to show for this period"
      let count = layout.timeline.indices.count
      let noun =
        plot.bucketSeconds == nil
        ? (count == 1 ? "sample" : "samples") : (count == 1 ? "bucket" : "buckets")
      span = "\(plot.historySpan ?? layout.timeline.span) · \(count) \(noun)"
      scale =
        plot.percent
        ? "0–100%"
        : !layout.hasData
          ? "Scale unavailable"
          : (trace ? "Scale 0–" : "Scale ± ") + Display.rate(layout.maximum)
    }
  }

  private(set) var cards: [Card] = []
  var usesPopoverLayout = false
  private(set) var isOverview = false
  var usesOverviewLayout: Bool { isOverview && !usesPopoverLayout }
  var popoverHeadline: (title: String, value: String, subtitle: String)?
  var popoverDocumentHeight: CGFloat {
    canonicalFrames.enumerated().reduce(0) { total, pair in
      total + popoverCardHeight(cards[pair.offset], canonical: pair.element)
        + (pair.offset == 0 && popoverHeadline != nil ? 27 : 0) + 8
    }
  }
  private func popoverCardHeight(_ card: Card, canonical: NSRect) -> CGFloat {
    switch card.content {
    case .rows(let rows):
      return max(
        canonical.height, 38 + CGFloat(min(7, rows.count)) * 25 + (card.note.isEmpty ? 0 : 17))
    case .none where card.title == "TOP PROCESSES": return 56
    case .none
    where card.title.contains("TRAFFIC · PARTIAL") || card.title == "APP BUNDLES · PARTIAL":
      return 96
    case .memory: return 204
    case .tiles(_, let columns): return max(canonical.height, columns > 2 ? 150 : 134)
    default: return canonical.height
    }
  }
  private var scalesSummaryLayout = true
  /// Grow graphics and type together, with a cap so maximized views remain readable.
  var contentScale: CGFloat {
    guard scalesSummaryLayout, !usesPopoverLayout, !usesOverviewLayout else { return 1 }
    return min(1.5, max(1, sqrt(min(bounds.width / 520, bounds.height / 454))))
  }
  private var canonicalFrames: [NSRect] = []
  private let textStyles = TextDrawingStyles()
  private var textStyleModule: Module?
  private func prepareTextStyles(for module: Module) {
    if textStyleModule != module {
      textStyleModule = module
      textStyles.reset()
    }
  }
  override func systemStyleDidChange() {
    super.systemStyleDidChange()
    textStyles.reset()
  }
  private func isExpandable(_ card: Card) -> Bool {
    if case .plot = card.content { return true }
    return card.title == "TOP PROCESSES" || card.title == "METAL GPU TIME"
      || card.title.contains("TRAFFIC · PARTIAL")
      || card.title == "APP BUNDLES · PARTIAL"
  }
  func displayedRows(in card: Card) -> ArraySlice<Reading> {
    guard case .rows(let rows) = card.content else { return [] }
    guard isExpandable(card) else { return rows[...] }
    let available = max(0, card.frame.height / contentScale - 54)
    let height: CGFloat = rows.contains { $0.second != nil } ? 20 : 14
    return rows.prefix(min(12, max(0, Int(available / height))))
  }
  private func layoutHistoryCards() {
    if cards.count == 1 {
      cards[0].frame = bounds
    } else if cards.count == 2, case .coreHistory = cards[1].content {
      // Keep each logical-core row readable; the aggregate chart takes the
      // remaining viewport height without changing or copying its observations.
      let coreHeight = cards[1].frame.height
      let plotHeight = max(190, bounds.height - coreHeight - 8)
      cards[0].frame = .init(x: 0, y: 0, width: bounds.width, height: plotHeight)
      cards[1].frame = .init(
        x: 0, y: plotHeight + 8, width: bounds.width, height: coreHeight)
    }
  }
  private func layoutSummaryCards() {
    guard canonicalFrames.count == cards.count else { return }
    if usesOverviewLayout {
      for (index, frame) in Self.overviewFrames(in: bounds).enumerated()
      where cards.indices.contains(index) {
        cards[index].frame = frame
      }
      return
    }
    if usesPopoverLayout {
      var y: CGFloat = 0
      for index in cards.indices {
        let header = index == 0 && popoverHeadline != nil
        cards[index].headerHeight = header ? 58 : 31
        let height =
          popoverCardHeight(cards[index], canonical: canonicalFrames[index]) + (header ? 27 : 0)
        cards[index].frame = .init(x: 0, y: y, width: bounds.width, height: height)
        y += height + SystemStyle.Space.gap
      }
      return
    }
    let scale = contentScale
    let flexible = Set(
      cards.indices.filter { isExpandable(cards[$0]) }.map { canonicalFrames[$0].minY })
    let extra = flexible.isEmpty ? 0 : max(0, bounds.height - 454 * scale) / CGFloat(flexible.count)
    for index in cards.indices {
      let frame = canonicalFrames[index]
      let preceding = flexible.filter { $0 < frame.minY }.count
      cards[index].frame = .init(
        x: frame.minX * bounds.width / 520,
        y: frame.minY * scale + CGFloat(preceding) * extra,
        width: frame.width * bounds.width / 520,
        height: frame.height * scale + (flexible.contains(frame.minY) ? extra : 0))
    }
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if scalesSummaryLayout {
      layoutSummaryCards()
    } else {
      layoutHistoryCards()
    }
    refreshHover()
    needsDisplay = true
  }
  private var accessibleCards: [NSAccessibilityElement] = []
  /// One reused element per logical counter, bounded by CPUCoreHistorySample.maximumCores.
  private var accessibleCoreRows: [CoreHistoryAccessibilityRow] = []
  override var isFlipped: Bool { true }
  static func supports(_ module: Module) -> Bool {
    module != .clock && module != .weather && module != .sensors
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Statistics summary")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func accessibilityChildren() -> [Any]? {
    for (child, card) in zip(accessibleCards, cards) {
      child.setAccessibilityFrame(
        window.map { $0.convertToScreen(convert(card.frame, to: nil)) } ?? card.frame)
    }
    return accessibleCards + (hoverAccessibilityElement.map { [$0] } ?? [])
  }
  func update(_ s: Snapshot, history: [HistoryPoint], settings: Settings, module: Module) {
    prepareTextStyles(for: module)
    isOverview = module == .overview
    scalesSummaryLayout = true
    cards.removeAll(keepingCapacity: true)
    canonicalFrames.removeAll(keepingCapacity: true)
    let recent = Array(history.suffix(300))
    let miniRecent = Array(recent.suffix(90))
    let selectedGPU = s.gpus.max { ($0.usage ?? -1) < ($1.usage ?? -1) }
    func card(
      _ title: String, _ y: CGFloat, _ height: CGFloat, _ content: Content,
      trailing: String = "", note: String = "", x: CGFloat = 0, width: CGFloat = 520
    ) {
      let frame = NSRect(x: x, y: y, width: width, height: height)
      canonicalFrames.append(frame)
      cards.append(
        .init(
          frame: frame, title: title,
          trailing: trailing, content: content, note: note))
    }
    func plot(
      _ first: KeyPath<HistoryPoint, Double?>, _ second: KeyPath<HistoryPoint, Double?>,
      labels: (String, String), values: (String, String), percent: Bool = false,
      mirrored: Bool = false
    ) -> Content {
      .plot(
        .init(
          first: recent.map { $0[keyPath: first] },
          second: labels.1.isEmpty ? [] : recent.map { $0[keyPath: second] },
          firstLabel: labels.0, secondLabel: labels.1, firstValue: values.0, secondValue: values.1,
          percent: percent, mirrored: mirrored,
          firstColor: module == .network ? SystemStyle.secondaryAccent : SystemStyle.accent,
          secondColor: module == .network ? SystemStyle.accent : SystemStyle.secondaryAccent,
          firstRole: module == .network ? .secondary : .primary,
          secondRole: module == .network ? .primary : .secondary,
          time: .init(recent.map(\.time), intervals: recent.map(\.sampleInterval)),
          valueFormat: percent ? .percent : .rate))
    }
    let temperatureScale = settings.fahrenheit ? "32–212°F display scale" : "0–100°C display scale"
    func temperature(_ value: Double?) -> String {
      value.map {
        String(
          format: "%.0f°%@", settings.fahrenheit ? $0 * 1.8 + 32 : $0,
          settings.fahrenheit ? "F" : "C")
      } ?? "—"
    }
    func sensor(_ component: SensorComponent, _ kind: SensorReading.Kind) -> Double? {
      s.sensors.filter { $0.component == component && $0.kind == kind }.map(\.value).max()
    }
    func frequency(_ name: String) -> String {
      s.frequencies.first { $0.name == name }?.formatted ?? "—"
    }
    let duplicateNames = Set(
      Dictionary(grouping: s.processes, by: \.name).filter { $0.value.count > 1 }.keys)
    func processName(_ process: ProcessReading) -> String {
      duplicateNames.contains(process.name) ? "\(process.name) (\(process.pid))" : process.name
    }
    func cpuProcesses() -> [Reading] {
      let processes = Array(
        s.processes.filter { $0.cpu != nil }.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(12)
      )
      let fractions = Self.relativeFractions(processes.map(\.cpu))
      return zip(processes, fractions).map { process, fraction in
        Reading(
          label: processName(process), value: Display.processPercent(process.cpu),
          fraction: fraction)
      }
    }
    func rateRows(_ names: [String], _ first: [Double?], _ second: [Double?]) -> [Reading] {
      let fractions = Self.relativeFractions(first + second)
      return names.indices.map { index in
        Reading(
          label: names[index], value: Display.rate(first[index]),
          second: Display.rate(second[index]), fraction: fractions[index],
          color: module == .network ? SystemStyle.secondaryAccent : SystemStyle.accent,
          secondFraction: fractions[index + first.count],
          secondColor: module == .network ? SystemStyle.accent : SystemStyle.secondaryAccent)
      }
    }
    func tile(
      _ label: String, _ value: String, _ color: NSColor,
      key: KeyPath<HistoryPoint, Double?>? = nil, fraction: Double? = nil,
      detail: String = "", percent: Bool = false
    ) -> Tile {
      var trend: Plot?
      if let key {
        trend = Plot(
          first: miniRecent.map { $0[keyPath: key] }, second: [], firstLabel: label,
          secondLabel: "", firstValue: value, secondValue: "", percent: percent,
          mirrored: false, firstColor: SystemStyle.accent,
          time: .init(miniRecent.map(\.time), intervals: miniRecent.map(\.sampleInterval)),
          valueFormat: key == \.temperature
            ? .temperature(fahrenheit: settings.fahrenheit) : percent ? .percent : .rate)
      }
      return Tile(
        label: label, value: value, detail: detail, color: color,
        fraction: fraction, trend: trend)
    }
    func gpuGauges() -> [Gauge] {
      let gpu = selectedGPU
      return [
        Gauge(
          label: "Device", value: Display.percent(gpu?.usage), percent: gpu?.usage,
          color: SystemStyle.accent),
        Gauge(
          label: "Renderer", value: Display.percent(gpu?.rendererUsage),
          percent: gpu?.rendererUsage, color: SystemStyle.accent),
        Gauge(
          label: "Tiler", value: Display.percent(gpu?.tilerUsage), percent: gpu?.tilerUsage,
          color: SystemStyle.secondaryAccent),
      ]
    }
    func trafficRows() -> [Reading] {
      guard s.networkTraffic.grouping == settings.networkTrafficGrouping,
        s.networkTraffic.revision == settings.networkTrafficRevision
      else { return [] }
      if settings.networkTrafficGrouping == .bundles {
        let bundles = Array(s.networkTraffic.bundles.prefix(12))
        return rateRows(bundles.map(\.label), bundles.map(\.upload), bundles.map(\.download))
      }
      let processes = Array(s.networkTraffic.processes.prefix(12))
      return rateRows(processes.map(\.name), processes.map(\.upload), processes.map(\.download))
    }
    func coolingRows(_ component: SensorComponent) -> [Reading] {
      let hottest = s.sensors.filter { $0.kind == .temperature && $0.component == component }
        .max { $0.value < $1.value }
      var readings: [Reading] = [
        .init(
          label: "Hottest temperature",
          value: temperature(hottest?.value), color: SystemStyle.secondaryAccent)
      ]
      let fans = s.sensors.filter {
        $0.kind == .fan && ($0.fanOwner == component || $0.fanOwner == nil)
      }
      readings += fans.prefix(3).map {
        .init(
          label: $0.name, value: $0.formatted(fahrenheit: false), color: SystemStyle.secondaryAccent
        )
      }
      if fans.isEmpty { readings.append(.init(label: "Fan speed", value: "Unavailable")) }
      return readings
    }
    func coolingNote(_ component: SensorComponent) -> String {
      let fans = s.sensors.filter {
        $0.kind == .fan && ($0.fanOwner == component || $0.fanOwner == nil)
      }
      return fans.isEmpty
        ? "No fan readings; this Mac may be fanless"
        : fans.contains { $0.fanOwner == nil }
          ? "Shared / unassigned system fans · read-only" : "Read-only fan speeds"
    }
    switch module {
    case .cpu:
      card(
        "CPU · \(Display.percent(s.cpu?.usage))", 0, 156,
        plot(
          \.cpuUser, \.cpuSystem,
          labels: ("User", "System"),
          values: (Display.percent(s.cpu?.user), Display.percent(s.cpu?.system)), percent: true),
        trailing: "\(frequency("Performance")) · \(temperature(s.cpuTemperature))")
      if let cpu = s.cpu {
        card("LOGICAL CORES", 164, 112, .cores(cpu), trailing: "\(cpu.cores.count) cores")
      } else {
        card(
          "LOGICAL CORES", 164, 112, .rows([.init(label: "CPU readings", value: "Unavailable")]))
      }
      let cpuRows = cpuProcesses()
      card(
        "TOP PROCESSES", 284, 108, cpuRows.isEmpty ? .none : .rows(cpuRows),
        note: cpuRows.isEmpty
          ? "No process readings yet" : "Bars relative to largest · % of one core", width: 252
      )
      card(
        "CPU COOLING", 284, 108, .rows(coolingRows(.cpu)),
        note: coolingNote(.cpu), x: 260, width: 260)
      card(
        "SYSTEM", 400, 54,
        .rows([
          .init(
            label: "Load · 1 / 5 / 15m",
            value: s.cpu?.load.map { String(format: "%.2f", $0) }.joined(separator: "  ") ?? "—")
        ]), trailing: "Uptime: " + Display.duration(s.uptime))
    case .gpu:
      card(
        "GPU ACTIVITY", 0, 156,
        plot(
          \.gpu, \.gpu,
          labels: (s.gpus.count > 1 ? "Highest GPU" : "Device", ""),
          values: (Display.percent(s.gpus.compactMap(\.usage).max()), ""),
          percent: true),
        trailing: s.gpus.count > 1 ? "\(s.gpus.count) devices" : selectedGPU?.name ?? "Unavailable")
      card(
        "DRIVER ENGINES", 164, 134, .gauges(gpuGauges()),
        note: "Usage per GPU core is not available", width: 252)
      let hardware: [Tile] = [
        tile(
          "GPU cores", selectedGPU?.coreCount.map(String.init) ?? "—", .systemGray,
          detail: "Hardware count"),
        tile("Active frequency", frequency("GPU"), SystemStyle.accent),
        tile(
          "Hottest GPU sensor", temperature(sensor(.gpu, .temperature)),
          SystemStyle.secondaryAccent,
          fraction: sensor(.gpu, .temperature).map { $0 / 100 }, detail: temperatureScale),
        tile("Allocated memory", selectedGPU?.memory.map(Display.bytes) ?? "—", SystemStyle.accent),
      ]
      card(
        "HARDWARE", 164, 134, .tiles(hardware, columns: 2),
        note: s.gpus.count > 1
          ? "Shown device: \(selectedGPU?.name ?? "Unavailable") · \(selectedGPU?.coreCount.map { "\($0) GPU cores" } ?? "Core count unavailable")"
          : "Power consumption is in Power", x: 260, width: 260
      )
      let duplicateGPUOwners = Set(
        Dictionary(grouping: s.gpuTime.rows, by: \.name).filter { $0.value.count > 1 }.keys)
      let fractions = Self.relativeFractions(s.gpuTime.rows.map(\.millisecondsPerSecond))
      let gpuRows = zip(s.gpuTime.rows, fractions).map { process, fraction in
        Reading(
          label: duplicateGPUOwners.contains(process.name)
            ? "\(process.name) (\(process.pid))" : process.name,
          value: GPUProcessTimeSnapshot.formatted(process.millisecondsPerSecond),
          fraction: fraction,
          color: SystemStyle.secondaryAccent,
          accessibilityValue: process.millisecondsPerSecond.map {
            String(format: "%.1f milliseconds of GPU time per second", $0)
          } ?? "Unavailable")
      }
      card(
        "METAL GPU TIME", 306, 148, gpuRows.isEmpty ? .message(s.gpuTime.message) : .rows(gpuRows),
        trailing: s.gpuTime.status == .incomplete
          ? "ms/s · partial" : s.gpuTime.status == .collecting ? "ms/s · first" : "ms/s",
        note: s.gpus.count > 1
          ? "Creating process · all reported GPUs" : "Creating process · bars relative to largest",
        width: 252)
      card(
        "GPU COOLING", 306, 148, .rows(coolingRows(.gpu)), note: coolingNote(.gpu), x: 260,
        width: 260)
    case .memory:
      if let memory = s.memory {
        card(
          "PHYSICAL MEMORY", 0, 280, .memory(memory),
          trailing: Display.bytes(memory.total) + " RAM",
          note: "App = active − purgeable · Available = cache + free")
      } else {
        card("PHYSICAL MEMORY", 0, 280, .none, trailing: "Unavailable")
      }
      let processes = Array(
        s.processes.sorted { $0.memory > $1.memory }.prefix(12))
      let fractions = Self.relativeFractions(processes.map { Double($0.memory) })
      let rows = zip(processes, fractions).map { process, fraction in
        Reading(
          label: processName(process), value: Display.bytes(process.memory),
          fraction: fraction, color: SystemStyle.accent)
      }
      card(
        "TOP PROCESSES", 288, 124, rows.isEmpty ? .none : .rows(rows),
        trailing: rows.isEmpty ? "No readings" : "Memory",
        note: rows.isEmpty ? "No process readings yet" : "Bars relative to largest footprint")
      card(
        "SWAP", 420, 34, .none,
        trailing: s.memory.map { Display.bytes($0.swapUsed) + " / " + Display.bytes($0.swapTotal) }
          ?? "—")
    case .disks:
      func capacityTile(_ volume: VolumeReading, startup: Bool = false) -> Tile {
        tile(
          volume.name + (startup && volume.name != "Startup disk" ? " · Startup" : ""),
          Display.bytes(volume.available) + " free", SystemStyle.secondaryAccent,
          fraction: volume.total > 0 ? volume.percent / 100 : nil,
          detail: (volume.total > 0 ? Display.percent(volume.percent) + " used · " : "")
            + Display.bytes(volume.total) + " capacity")
      }
      let startup = s.startupVolume
      var volumes = [
        startup.map { capacityTile($0, startup: true) }
          ?? tile("Startup", "—", SystemStyle.secondaryAccent, detail: "Volume unavailable")
      ]
      volumes += s.volumes.lazy.filter { $0.path != "/" }.prefix(1).map { capacityTile($0) }
      let storageHeight: CGFloat = 106
      card(
        "STORAGE", 0, storageHeight, .tiles(volumes, columns: volumes.count),
        note: "APFS volumes may share space · See All readings")
      card(
        "DISK ACTIVITY", storageHeight + 8, 238 - storageHeight,
        plot(
          \.diskRead, \.diskWrite,
          labels: ("Read", "Write"), values: (Display.rate(s.diskRead), Display.rate(s.diskWrite)),
          mirrored: true))
      let processes = Array(
        s.processes.filter { $0.read != nil || $0.written != nil }.sorted {
          ($0.diskActivity ?? -1) > ($1.diskActivity ?? -1)
        }.prefix(12))
      let rows = rateRows(
        processes.map(processName), processes.map(\.read), processes.map(\.written))
      card(
        "TOP PROCESSES", 254, 146, rows.isEmpty ? .none : .rows(rows), trailing: "Read / Write",
        note: processes.isEmpty
          ? "No readable process I/O intervals yet · access varies by process"
          : "Paired bars / largest visible rate · filled read / outlined write")
      card(
        "DRIVE HEALTH", 408, 46, .none,
        trailing: s.storageHealth.refreshing
          ? "Checking…"
          : s.storageHealth.checkedAt == nil
            ? "Not checked" : s.storageHealth.drives.first?.status ?? "Unavailable",
        note: "Read-only SMART · All readings shows device details")
    case .network:
      card(
        "NETWORK", 0, 180,
        plot(
          \.upload, \.download,
          labels: ("Upload", "Download"),
          values: (Display.rate(s.upload), Display.rate(s.download)), mirrored: true),
        trailing: s.selectedInterface.isEmpty ? "No primary route" : s.selectedInterface)
      let selected = s.interfaces.first { $0.name == s.selectedInterface }
      let address = selected?.addresses.first { $0.family == .ipv4 }?.formatted ?? "Unavailable"
      let trafficMessage =
        s.networkTraffic.availability == .inactive
        ? "Collecting process traffic…" : s.networkTraffic.message
      let publicIP =
        settings.publicIPChecks ? (s.internetChecks.ipv4?.address ?? "Waiting") : "Checks off"
      let radio = s.wifi.interfaces.first
      let radioName = radio.map { "Wi-Fi \($0.interface)" } ?? "Wi-Fi"
      let signal = radio?.rssi.map { "\($0) dBm" } ?? "—"
      let linkRate = radio?.transmitMbps.map { String(format: "%.0f Mbps", $0) } ?? "—"
      let interfaceTotals =
        selected.map {
          Display.bytes($0.sent) + " / " + Display.bytes($0.received)
        } ?? "—"
      var connectionRows: [Reading] = [
        Reading(label: "Local IPv4", value: address),
        Reading(label: "Public IPv4", value: publicIP),
        Reading(
          label: radioName, value: radio == nil ? "No reading yet" : signal + " · " + linkRate),
        Reading(label: "Interface totals ↑ / ↓", value: interfaceTotals),
      ]
      let showsPing = settings.pingCheck.enabled
      let pingHeight: CGFloat = showsPing ? 24 : 0
      if showsPing {
        let result = s.internetChecks.ping
        let value =
          settings.pingCheck.validationError != nil
          ? "Configuration needed"
          : result.map {
            ($0.milliseconds.map { String(format: "%.1f ms", $0) }
              ?? $0.reason.components(separatedBy: " · ")[0])
              + " · \(Int(max(0, s.uptime - $0.checkedAt)))s ago"
          } ?? "Waiting"
        connectionRows.append(
          Reading(label: "Ping " + (settings.pingCheck.canonicalDestination ?? ""), value: value))
      }
      card("CONNECTION", 188, 104 + pingHeight, .rows(connectionRows))
      let networkRows = trafficRows()
      card(
        settings.networkTrafficGrouping == .bundles
          ? "APP BUNDLES · PARTIAL" : "PROCESS TRAFFIC · PARTIAL",
        300 + pingHeight, 154 - pingHeight, networkRows.isEmpty ? .none : .rows(networkRows),
        trailing: "↑ / ↓",
        note: settings.networkTrafficGrouping == .bundles
          ? (s.networkTraffic.availability == .ready
            ? (s.networkTraffic.bundles.isEmpty ? "No active TCP/UDP · " : "TCP/UDP · ")
              + "bundle paths; shared / unresolved separate · all interfaces + loopback"
            : trafficMessage)
          : s.networkTraffic.availability == .ready
            ? (networkRows.isEmpty
              ? "No active accessible TCP/UDP owners in this interval"
              : "Bars relative to largest · TCP/UDP · all interfaces + loopback")
            : trafficMessage)
    case .sensors: break
    case .battery:
      if let battery = s.batteries.first {
        card(
          "BATTERY", 0, 104,
          .gauges([
            .init(
              label: "Charge", value: Display.percent(battery.percent), percent: battery.percent,
              color: SystemStyle.accent),
            .init(
              label: "Health", value: Display.percent(battery.health), percent: battery.health,
              color: SystemStyle.secondaryAccent),
          ]),
          trailing: BatteryMenuState.state(for: battery).title)
        card(
          "BATTERY DETAILS", 112, 90,
          .tiles(
            [
              tile(
                "Remaining",
                battery.minutesRemaining.map { "\($0 / 60)h \($0 % 60)m" }
                  ?? "—", SystemStyle.accent),
              tile(
                "Battery power · signed",
                battery.watts.map { String(format: "%.1f W", $0) }
                  ?? "—", SystemStyle.secondaryAccent),
              tile(
                "Cycle count", battery.cycles.map(String.init) ?? "—", SystemStyle.secondaryAccent),
              tile(
                "Battery temperature", temperature(sensor(.battery, .temperature)),
                SystemStyle.secondaryAccent),
            ], columns: usesPopoverLayout ? 2 : 4))
      } else {
        card(
          "POWER SOURCE", 0, 54, .none, trailing: "AC · No internal battery")
      }
      let priority = [
        "PSTR", "ioreport:cpu", "ioreport:gpu", "ioreport:dram", "ioreport:ane", "PCPC", "PGTR",
      ]
      let powerReadings = s.sensors.filter { $0.kind == .power }.sorted {
        let a = priority.firstIndex(of: $0.key) ?? priority.count
        let b = priority.firstIndex(of: $1.key) ?? priority.count
        return a == b ? $0.key < $1.key : a < b
      }
      let shownPower = Array(powerReadings.filter { $0.name != $0.key }.prefix(4))
      let accessoryHeight: CGFloat = s.peripherals.isEmpty ? 62 : 124
      let powerTop: CGFloat = s.batteries.isEmpty ? 62 : 210
      let powerHeight = min(454 - accessoryHeight - 8 - powerTop, shownPower.count <= 2 ? 112 : 186)
      let accessoryTop = powerTop + powerHeight + 8
      let powerContent: Content
      if powerHeight < 144 && shownPower.count > 2 {
        powerContent = .rows(
          shownPower.map {
            .init(
              label: $0.name, value: $0.formatted(fahrenheit: false),
              color: SystemStyle.secondaryAccent)
          })
      } else {
        powerContent = .tiles(
          shownPower.map { reading in
            tile(
              reading.name, reading.formatted(fahrenheit: false), SystemStyle.secondaryAccent,
              detail: reading.key.hasPrefix("ioreport:")
                ? "macOS model estimate" : "Hardware sensor")
          }, columns: min(2, max(1, shownPower.count)))
      }
      card(
        "POWER CONSUMPTION", powerTop, powerHeight, powerContent,
        trailing: s.lowPower ? "Low Power Mode" : "Standard energy mode",
        note: shownPower.isEmpty
          ? "No known power readings · see All readings for raw sensors"
          : "Showing \(shownPower.count) of \(powerReadings.count) power sensors · totals may overlap · All readings for more"
      )
      card(
        "ACCESSORY BATTERIES", accessoryTop, accessoryHeight,
        s.peripherals.isEmpty
          ? .none
          : .gauges(
            s.peripherals.prefix(4).map {
              .init(
                label: $0.name, value: Display.percent($0.percent), percent: $0.percent,
                color: SystemStyle.accent)
            }),
        note: s.peripherals.isEmpty
          ? "No accessory battery readings"
          : "See All readings for every reported accessory")
    default:
      cards = Self.overviewCards(s, history: recent, settings: settings)
      canonicalFrames = Self.overviewFrames(in: .init(x: 0, y: 0, width: 520, height: 554))
    }
    layoutSummaryCards()
    setAccessibilityLabel(module.title + " summary")
    refreshAccessibility()
  }
  private func refreshAccessibility() {
    while accessibleCards.count < cards.count {
      let element = NSAccessibilityElement()
      element.setAccessibilityElement(true)
      element.setAccessibilityRole(.staticText)
      element.setAccessibilityParent(self)
      accessibleCards.append(element)
    }
    if accessibleCards.count > cards.count {
      for element in accessibleCards.dropFirst(cards.count) {
        element.setAccessibilityChildren(nil)
        element.setAccessibilityParent(nil)
      }
      accessibleCards.removeLast(accessibleCards.count - cards.count)
    }
    for (element, card) in zip(accessibleCards, cards) {
      element.setAccessibilityRole(.staticText)
      element.setAccessibilityChildren(nil)
      element.setAccessibilityLabel(card.title)
      element.setAccessibilityValue(card.spoken)
      element.setAccessibilityHelp(
        card.title == "METAL GPU TIME" ? GPUProcessTimeSnapshot.explanation : nil)
    }
    if let index = cards.firstIndex(where: {
      if case .coreHistory = $0.content { true } else { false }
    }),
      case .coreHistory(let matrix) = cards[index].content
    {
      let group = accessibleCards[index]
      group.setAccessibilityRole(.group)
      group.setAccessibilityValue(nil)
      group.setAccessibilityHelp(cards[index].spoken)
      while accessibleCoreRows.count < matrix.kinds.count {
        let row = CoreHistoryAccessibilityRow(owner: self)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        accessibleCoreRows.append(row)
      }
      if accessibleCoreRows.count > matrix.kinds.count {
        for row in accessibleCoreRows.dropFirst(matrix.kinds.count) {
          row.geometry.owner = nil
          row.setAccessibilityParent(nil)
        }
        accessibleCoreRows.removeLast(accessibleCoreRows.count - matrix.kinds.count)
      }
      // Match the visible E/P/unknown order while preserving each Mach logical identity.
      let order = CPUCoreKind.allCases.flatMap { kind in
        matrix.kinds.indices.filter { matrix.kinds[$0] == kind }
      }
      let observations = matrix.history.samples
      for (position, core) in order.enumerated() {
        let row = accessibleCoreRows[core]
        row.geometry.cardIndex = index
        row.geometry.position = position
        row.setAccessibilityParent(group)
        row.setAccessibilityLabel("Logical core \(core + 1), \(matrix.kinds[core].title)")
        let value = matrix.values[core].map { Display.percent($0) } ?? "Unavailable"
        let partial = matrix.values[core] != nil && matrix.counts[core] < observations
        row.setAccessibilityValue(
          "\(matrix.statistic.title): \(value), \(matrix.counts[core]) of \(observations) observations"
            + (partial ? "; partial coverage" : ""))
      }
      group.setAccessibilityChildren(order.map { accessibleCoreRows[$0] })
    } else {
      for row in accessibleCoreRows {
        row.geometry.owner = nil
        row.setAccessibilityParent(nil)
      }
      accessibleCoreRows.removeAll()
    }
    needsDisplay = true
    refreshHover()
  }
  func updateHistory(
    _ projection: HistoryProjection, module: Module, fahrenheit: Bool,
    statistic: HistoryStatistic = .peak
  ) {
    let first: HistoryMetric
    let second: HistoryMetric?
    let labels: (String, String)
    let percent: Bool
    switch module {
    case .cpu:
      first = .cpu
      second = nil
      labels = ("CPU \(statistic.singular)", "")
      percent = true
    case .gpu:
      first = .gpu
      second = nil
      labels = ("GPU \(statistic.singular)", "")
      percent = true
    case .memory:
      first = .memory
      second = nil
      labels = ("Memory \(statistic.singular)", "")
      percent = true
    case .network:
      first = .upload
      second = .download
      labels = ("Upload \(statistic.singular)", "Download \(statistic.singular)")
      percent = false
    case .disks:
      first = .diskRead
      second = .diskWrite
      labels = ("Read \(statistic.singular)", "Write \(statistic.singular)")
      percent = false
    case .battery:
      first = .battery
      second = nil
      labels = ("Battery \(statistic.singular)", "")
      percent = true
    default:
      first = .diskUsed
      second = nil
      labels = ("Startup volume used \(statistic.singular)", "")
      percent = true
    }
    func values(_ metric: HistoryMetric) -> [Double?] {
      projection.buckets.map { bucket in
        bucket.value(metric, statistic: statistic).map {
          metric == .temperature && fahrenheit ? $0 * 1.8 + 32 : $0
        }
      }
    }
    func text(_ metric: HistoryMetric) -> String {
      guard let value = projection.value(metric, statistic: statistic) else { return "—" }
      if metric == .temperature {
        return String(
          format: "%.0f°%@", fahrenheit ? value * 1.8 + 32 : value, fahrenheit ? "F" : "C")
      }
      return percent ? Display.percent(value) : Display.rate(value)
    }
    let end = projection.buckets.last?.last
    let beginning = end?.addingTimeInterval(-Double(projection.range.rawValue))
    func dateText(_ date: Date) -> String {
      DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
    let domain = beginning.flatMap { first in end.map { first...$0 } }
    let uncollected = beginning.flatMap { first in
      projection.buckets.first.map {
        max(0, min(1, $0.first.timeIntervalSince(first) / Double(projection.range.rawValue)))
      }
    }
    func coverage(_ metric: HistoryMetric) -> ObservationCoverage {
      .init(
        recorded: projection.validSamples(metric, statistic: statistic),
        valid: projection.validSamples(metric, statistic: .peak))
    }
    let firstCoverage = coverage(first)
    let secondCoverage = second.map(coverage)
    var metrics = [(first, firstCoverage)]
    if let second, let secondCoverage { metrics.append((second, secondCoverage)) }
    let spokenCoverage = metrics.map { metric, counts in
      "\(metric.aggregateColumn): \(counts.recorded) of \(counts.valid) valid observations have \(statistic.plural); \(projection.samples) total observations"
    }
    let plot = Plot(
      first: values(first), second: second.map(values) ?? [], firstLabel: labels.0,
      secondLabel: labels.1,
      firstValue: text(first), secondValue: second.map(text) ?? "", percent: percent,
      mirrored: module == .network || module == .disks,
      firstColor: module == .network ? SystemStyle.secondaryAccent : SystemStyle.accent,
      secondColor: module == .network ? SystemStyle.accent : SystemStyle.secondaryAccent,
      firstRole: module == .network ? .secondary : .primary,
      secondRole: module == .network ? .primary : .secondary,
      time: .init(
        module == .cpu ? projection.bucketCenters : projection.buckets.map(\.last),
        intervals: projection.buckets.map {
          max(projection.range.resolution, $0.maximumSampleInterval)
        }, domain: domain),
      bucketSeconds: projection.range.resolution,
      historySpan: HistoryTimeline(
        times: [projection.buckets.first?.first, projection.buckets.last?.last].compactMap { $0 }
      ).span,
      uncollectedFraction: uncollected,
      axisLabels: domain.map { (dateText($0.lowerBound), dateText($0.upperBound)) },
      partialFirst: projection.buckets.map {
        $0.validSamples(first, statistic: statistic) < $0.samples || $0.hasGap
      },
      partialSecond: projection.buckets.map { bucket in
        second.map {
          bucket.validSamples($0, statistic: statistic) < bucket.samples || bucket.hasGap
        } ?? false
      }, gapBuckets: projection.buckets.map(\.hasGap), statistic: statistic,
      firstWeights: projection.buckets.map { $0.validSamples(first, statistic: statistic) },
      secondWeights: second.map { metric in
        projection.buckets.map { $0.validSamples(metric, statistic: statistic) }
      } ?? [],
      sampleBounds: projection.buckets.map { $0.first...$0.last },
      valueFormat: percent ? .percent : .rate,
      alignsCoreHistory: module == .cpu && projection.latestCPUCoreKinds != nil,
      coverage: spokenCoverage, firstCoverage: firstCoverage, secondCoverage: secondCoverage)
    prepareTextStyles(for: module)
    scalesSummaryLayout = false
    isOverview = false
    let kinds = module == .cpu ? projection.latestCPUCoreKinds : nil
    let plotHeight: CGFloat = kinds == nil ? bounds.height : 190
    cards = [
      .init(
        frame: .init(x: 0, y: 0, width: bounds.width, height: plotHeight),
        title: "RECORDED " + statistic.plural.uppercased(),
        trailing: "Statistic / valid readings", content: .plot(plot))
    ]
    if let kinds {
      let changed = projection.buckets.contains { bucket in
        bucket.coreLayoutChanged || (bucket.cpuCores.map { $0.kinds != kinds } ?? false)
      }
      cards.append(
        .init(
          frame: .init(
            x: 0, y: 198, width: bounds.width,
            height: CGFloat(kinds.count) * Self.coreHistoryRowPitch + 77 + (changed ? 17 : 0)),
          title: "LOGICAL CORES · LATEST LAYOUT", trailing: statistic.title + " · 0–100%",
          content: .coreHistory(CoreHistoryMatrix(projection, kinds: kinds, statistic: statistic)),
          note: changed ? "Core layout changed: see CSV" : ""
        ))
    }
    layoutHistoryCards()
    setAccessibilityLabel(module.title + " recorded history, " + statistic.singular + " buckets")
    setAccessibilityHelp(
      "Counts show readings with this statistic / all valid readings for each series. Partial means some valid readings lack this statistic. Unavailable means none have it. Valid readings exclude unavailable samples; total observations include all collection attempts. These counts do not claim continuous coverage of the time range; missing readings, uncollected time and gaps are shown separately."
    )
    refreshAccessibility()
    refreshHover()
  }
  private func statisticGrouping(_ statistic: HistoryStatistic) -> String {
    switch statistic {
    case .peak: " · column peaks"
    case .average: " · weighted columns"
    case .minimum: " · column minima"
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(rect: bounds).addClip()
    let zoom = contentScale
    let transform = NSAffineTransform()
    transform.scale(by: zoom)
    transform.concat()
    for original in cards where original.frame.intersects(dirtyRect) {
      var card = original
      card.frame = .init(
        x: original.frame.minX / zoom, y: original.frame.minY / zoom,
        width: original.frame.width / zoom, height: original.frame.height / zoom)
      SystemStyle.drawPlatter(card.frame)
      if isOverview {
        drawOverviewCard(card)
        continue
      }
      if usesPopoverLayout, original.frame.minY == 0, let headline = popoverHeadline {
        text(
          headline.title,
          rect: .init(
            x: card.frame.minX + 12, y: card.frame.minY + 12, width: card.frame.width * 0.38 - 12,
            height: 20), size: 13, weight: .semibold)
        text(
          headline.value,
          rect: .init(
            x: card.frame.minX + card.frame.width * 0.38, y: card.frame.minY + 6,
            width: card.frame.width * 0.62 - 12, height: 34),
          size: headline.value.count > 16 ? 17 : 26, weight: .semibold, alignment: .right)
        text(
          headline.subtitle,
          rect: .init(
            x: card.frame.minX + 12, y: card.frame.minY + 37, width: card.frame.width - 24,
            height: 16), color: .secondaryLabelColor, size: 11)
      } else {
        text(
          SystemStyle.sectionTitle(card.title),
          rect: .init(
            x: card.frame.minX + 12, y: card.frame.minY + 9,
            width: card.frame.width * (usesPopoverLayout ? 0.62 : 0.55) - 12, height: 16),
          color: .secondaryLabelColor, size: 12,
          weight: .semibold)
        text(
          card.trailing,
          rect: .init(
            x: card.frame.minX + card.frame.width * (usesPopoverLayout ? 0.62 : 0.5),
            y: card.frame.minY + 9,
            width: card.frame.width * (usesPopoverLayout ? 0.38 : 0.5) - 12, height: 16), size: 11,
          weight: .medium,
          alignment: .right)
      }
      let content = card.contentRect
      switch card.content {
      case .device(let header): drawDeviceHeader(header, in: card.frame)
      case .overviewTile(let tile): drawOverviewTile(tile, in: card.frame)
      case .message(let message):
        text(message, rect: content, color: .secondaryLabelColor, size: 11)
      case .none: break
      case .rows: drawRows(displayedRows(in: original), in: content)
      case .tiles(let tiles, let columns): drawTiles(tiles, columns: columns, in: content)
      case .gauges(let gauges): drawGauges(gauges, in: content)
      case .cores(let cpu): drawCores(cpu, in: content)
      case .memory(let memory): drawMemory(memory, in: content)
      case .coreHistory(let matrix):
        drawCoreHistory(matrix, in: content)
      case .plot(let plot): drawPlot(plot, in: content)
      }
      if !card.note.isEmpty {
        text(
          card.note,
          rect: .init(
            x: card.frame.minX + 12, y: card.frame.maxY - 20,
            width: card.frame.width - 24, height: 14), color: .secondaryLabelColor, size: 9)
      }
    }
  }
  func text(
    _ value: String, rect: NSRect, color: NSColor = .labelColor,
    size: CGFloat = 12, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left
  ) {
    guard rect.width > 0, rect.height > 0 else { return }
    (value as NSString).draw(
      in: rect,
      withAttributes: textStyles.attributes(
        color: color, size: size, weight: weight, alignment: alignment))
  }
  /// Segment at every unavailable sample; never draw an invented bridge through a gap.
  static func historySegments(_ plot: Plot, upperBound: Double? = nil) -> [[NSPoint]] {
    let maximum =
      upperBound
      ?? (plot.percent
        ? 100
        : max(
          1,
          plot.first.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }.max() ?? 1))
    guard maximum.isFinite, maximum > 0 else { return [] }
    let timeline = plot.timeline
    let positions = timeline.positions
    var segments: [[NSPoint]] = []
    var current: [NSPoint] = []
    for (index, value) in plot.first.enumerated() {
      guard positions.indices.contains(index), let x = positions[index],
        let value, value.isFinite, value >= 0
      else {
        if !current.isEmpty {
          segments.append(current)
          current.removeAll(keepingCapacity: true)
        }
        continue
      }
      if let previous = current.last,
        timeline.gaps.contains(where: { $0.lowerBound > previous.x && $0.upperBound < x })
      {
        segments.append(current)
        current.removeAll(keepingCapacity: true)
      }
      current.append(NSPoint(x: min(1, max(0, x)), y: min(1, value / maximum)))
    }
    if !current.isEmpty { segments.append(current) }
    return segments
  }
  func drawMiniHistory(
    _ plot: Plot, in area: NSRect, upperBound: Double? = nil, filled: Bool? = nil
  ) {
    NSColor.quaternaryLabelColor.withAlphaComponent(0.3).setFill()
    NSRect(x: area.minX, y: area.maxY - 0.5, width: area.width, height: 0.5).fill()
    let segments = Self.historySegments(plot, upperBound: upperBound)
    let baseline = area.maxY
    for segment in segments {
      let points = segment.map {
        NSPoint(
          x: area.minX + $0.x * area.width,
          y: baseline - $0.y * (area.height - 2))
      }
      guard let first = points.first, let last = points.last else { continue }
      let line = NSBezierPath()
      line.move(to: first)
      for point in points.dropFirst() { line.line(to: point) }
      let fill = line.copy() as! NSBezierPath
      fill.line(to: NSPoint(x: last.x, y: baseline))
      fill.line(to: NSPoint(x: first.x, y: baseline))
      fill.close()
      plot.firstColor.withAlphaComponent(0.2).setFill()
      if filled ?? !plot.firstRole.dashed { fill.fill() }
      plot.firstColor.setStroke()
      if plot.firstRole.dashed { line.setLineDash([4, 3], count: 2, phase: 0) }
      line.lineWidth = 1.5
      line.stroke()
      if points.count == 1 {
        let dot = NSBezierPath(ovalIn: NSRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4))
        plot.firstRole.legendMarker.draw(in: dot.bounds, color: plot.firstColor)
      }
    }
  }
  private func drawCoreHistory(_ matrix: CoreHistoryMatrix, in area: NSRect) {
    let kinds = matrix.kinds
    let order = CPUCoreKind.allCases.flatMap { kind in kinds.indices.filter { kinds[$0] == kind } }
    let graph = Self.coreHistoryGraphRect(
      area: area, count: order.count, scale: window?.backingScaleFactor ?? 1)
    for (position, index) in order.enumerated() {
      let row = Self.coreHistoryRowRect(area: area, graph: graph, position: position)
      let y = row.minY
      guard row.intersects(visibleRect), needsToDraw(row) else { continue }
      let color = kinds[index].chartColor
      drawCoreMarker(kinds[index], rect: .init(x: area.minX, y: y + 4, width: 7, height: 7))
      if let first = matrix.history.buckets.first?.first,
        let end = matrix.history.buckets.last?.last
      {
        let fraction = min(
          1, max(0, 1 - end.timeIntervalSince(first) / Double(matrix.history.range.rawValue)))
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        NSRect(x: graph.minX, y: y, width: graph.width * fraction, height: 14).fill()
      }
      let layout = coreHistoryBars(
        matrix, core: index, width: graph.width,
        scale: window?.backingScaleFactor ?? 1)
      var fill = HistoryHeatmapFill(color)
      for column in layout.columns {
        let cell = NSRect(
          x: graph.minX + layout.x(column), y: y, width: layout.barWidth, height: 14)
        if let value = column.first {
          fill.fill(cell, opacity: 0.12 + 0.88 * value / 100)
          if column.firstMissing {
            NSColor.secondaryLabelColor.setFill()
            NSRect(x: cell.minX, y: y, width: cell.width, height: 2).fill()
          }
        } else {
          NSColor.tertiaryLabelColor.setFill()
          cell.fill()
        }
        if column.gap {
          NSColor.systemOrange.setStroke()
          let outline = NSBezierPath(rect: cell.insetBy(dx: 0.25, dy: 0.5))
          outline.lineWidth = 0.5
          outline.stroke()
        }
      }
      text(
        Display.percent(matrix.values[index]),
        rect: .init(x: graph.maxX + 6, y: y, width: 44, height: 15), size: 10, weight: .medium,
        alignment: .right)
    }
    var x = graph.minX
    for kind in CPUCoreKind.allCases where kinds.contains(kind) {
      drawCoreMarker(kind, rect: .init(x: x, y: graph.maxY + 6, width: 7, height: 7))
      let width = (kind.chartTitle as NSString).size(withAttributes: [
        .font: NSFont.systemFont(ofSize: 9)
      ]).width
      text(
        kind.chartTitle, rect: .init(x: x + 11, y: graph.maxY + 3, width: width + 2, height: 13),
        color: .labelColor, size: 9)
      x += width + 24
    }
    x = graph.minX
    for (label, style) in [("Unrecorded", 0), ("Missing", 1), ("Partial", 2), ("Gap", 3)] {
      let swatch = NSRect(x: x, y: graph.maxY + 23, width: 9, height: 7)
      switch style {
      case 0:
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        swatch.fill()
      case 1:
        NSColor.tertiaryLabelColor.setFill()
        swatch.fill()
      case 2:
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: swatch.minX, y: swatch.minY, width: swatch.width, height: 2).fill()
      default:
        NSColor.systemOrange.setStroke()
        let path = NSBezierPath(rect: swatch)
        path.lineWidth = 0.5
        path.stroke()
      }
      let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)])
        .width
      text(
        label, rect: .init(x: x + 13, y: graph.maxY + 20, width: width + 2, height: 13),
        color: .secondaryLabelColor, size: 9)
      x += width + 26
    }
  }
  private func plotValue(
    _ value: String, coverage: ObservationCoverage?, rect: NSRect, color: NSColor,
    alignment: NSTextAlignment
  ) {
    guard let badge = coverage?.badge, rect.width > 0 else {
      text(value, rect: rect, color: color, size: 21, weight: .semibold, alignment: alignment)
      return
    }
    let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    let badgeWidth = min(
      rect.width / 2, (badge as NSString).size(withAttributes: [.font: badgeFont]).width + 10)
    let gap = min(6, rect.width - badgeWidth)
    let available = max(0, rect.width - badgeWidth - gap)
    let valueWidth = min(
      available,
      (value as NSString).size(withAttributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
      ]).width)
    // The right-aligned value keeps its original right edge even when truncated.
    let numberRect = NSRect(
      x: alignment == .right ? rect.maxX - available : rect.minX,
      y: rect.minY, width: available, height: rect.height)
    text(value, rect: numberRect, color: color, size: 21, weight: .semibold, alignment: alignment)
    let badgeRect = NSRect(
      x: alignment == .right
        ? rect.maxX - valueWidth - gap - badgeWidth : rect.minX + valueWidth + gap,
      y: rect.minY + 4, width: badgeWidth, height: 17)
    let ink: NSColor = coverage?.isPartial == true ? .systemOrange : .secondaryLabelColor
    ink.withAlphaComponent(0.16).setFill()
    NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
    text(
      badge, rect: badgeRect.insetBy(dx: 5, dy: 1), color: .labelColor, size: 10,
      weight: .medium)
  }
  static func snappedTimeColumn(_ rect: NSRect, scale: CGFloat) -> NSRect {
    let scale = scale.isFinite && scale > 0 ? scale : 1
    let left = ceil(rect.minX * scale) / scale
    let right = floor(rect.maxX * scale) / scale
    return .init(x: left, y: rect.minY, width: max(0, right - left), height: rect.height)
  }
  private static let coreHistoryRowPitch: CGFloat = 18
  static func coreHistoryGraphRect(area: NSRect, count: Int, scale: CGFloat = 1) -> NSRect {
    snappedTimeColumn(
      .init(
        x: area.minX + 13, y: area.minY, width: max(0, area.width - 65),
        height: CGFloat(count) * coreHistoryRowPitch
      ), scale: scale)
  }
  /// Includes the marker and trailing value as well as the snapped heatmap column.
  static func coreHistoryRowRect(area: NSRect, graph: NSRect, position: Int) -> NSRect {
    .init(
      x: area.minX, y: graph.minY + CGFloat(position) * coreHistoryRowPitch,
      width: max(0, graph.maxX + 50 - area.minX), height: 16)
  }
  static func plotGraphRect(_ plot: Plot, area: NSRect) -> NSRect {
    let headline = area.height >= 90
    let coverage = headline && (plot.firstCoverage != nil || plot.secondCoverage != nil)
    let offset: CGFloat = headline ? (coverage ? 58 : 44) : 22
    return .init(
      x: area.minX + (plot.alignsCoreHistory ? 13 : 0), y: area.minY + offset,
      width: max(0, area.width - (plot.alignsCoreHistory ? 65 : 0)),
      height: max(1, area.height - offset - (plot.axisLabels == nil ? 28 : 42)))
  }
  static func hoveredColumn(_ layout: HistoryBarLayout, x: CGFloat) -> HistoryBarLayout.Column? {
    guard
      let nearest = layout.columns.min(by: {
        abs(layout.x($0) + layout.barWidth / 2 - x) < abs(layout.x($1) + layout.barWidth / 2 - x)
      })
    else { return nil }
    let spacing =
      layout.slotCount > 1
      ? CGFloat(layout.pixelWidth - layout.barPixels) / layout.scale / CGFloat(layout.slotCount - 1)
      : CGFloat(layout.pixelWidth) / layout.scale
    return abs(layout.x(nearest) + layout.barWidth / 2 - x) <= max(layout.barWidth, spacing) / 2
      + 0.5 ? nearest : nil
  }
  private func hoverPlot(_ plot: Plot, graph: NSRect, point: NSPoint, mini: Bool = false) -> String?
  {
    guard graph.contains(point) else { return nil }
    let format: ChartValueFormat = plot.percent ? .percent : plot.valueFormat
    if mini {
      let timeline = plot.timeline
      let fraction = Double((point.x - graph.minX) / max(1, graph.width))
      guard
        let index = timeline.indices.min(by: {
          abs((timeline.positions[$0] ?? 0) - fraction)
            < abs((timeline.positions[$1] ?? 0) - fraction)
        })
      else { return "No recorded observations" }
      let distance = abs((timeline.positions[index] ?? 0) - fraction)
      let sampleTolerance =
        plot.domain == nil
        ? 1 / Double(max(1, timeline.indices.count - 1))
        : (timeline.cadence?.lowerBound ?? 0) / max(1, timeline.duration)
      let tolerance = max(1 / max(1, Double(graph.width)), sampleTolerance)
      guard distance <= tolerance else { return "No recorded observations here" }
      var result =
        Self.hoverDate(plot.times[index]) + "\n" + plot.firstLabel + ": "
        + format.string(plot.first.indices.contains(index) ? plot.first[index] : nil)
      if !plot.secondLabel.isEmpty {
        result +=
          "\n" + plot.secondLabel + ": "
          + format.string(plot.second.indices.contains(index) ? plot.second[index] : nil)
      }
      return result
    }
    let scale = (window?.backingScaleFactor ?? 1) * contentScale
    let graph = Self.snappedTimeColumn(graph, scale: scale)
    let left = graph.minX
    let right = graph.maxX
    let layout = HistoryBarLayout(plot: plot, graphWidth: right - left, scale: scale)
    guard let column = Self.hoveredColumn(layout, x: point.x - left) else {
      return "No recorded observations here"
    }
    let first = column.firstIndex
    let last = column.lastIndex
    guard plot.times.indices.contains(first), plot.times.indices.contains(last) else { return nil }
    let start =
      plot.sampleBounds.indices.contains(first)
      ? plot.sampleBounds[first].lowerBound : plot.times[first]
    let end =
      plot.sampleBounds.indices.contains(last)
      ? plot.sampleBounds[last].upperBound : plot.times[last]
    var result = Self.hoverDate(start) + (end == start ? "" : " – " + Self.hoverDate(end))
    result += "\n" + plot.firstLabel + ": " + format.string(column.first)
    if !plot.secondLabel.isEmpty {
      result += "\n" + plot.secondLabel + ": " + format.string(column.second)
    }
    if plot.percent && !plot.mirrored && !plot.secondLabel.isEmpty {
      let total = column.first.flatMap { a in column.second.map { min(100, a + $0) } }
      result += "\nTotal: " + ChartValueFormat.percent.string(total)
    }
    if plot.bucketSeconds != nil {
      result +=
        "\n" + plot.statistic.title + " · " + String(column.samples)
        + (column.samples == 1 ? " bucket" : " buckets")
    }
    if column.firstMissing || column.secondMissing { result += " · Partial / missing" }
    if column.gap { result += " · Collection gap" }
    return result
  }
  override func hoverText(at point: NSPoint) -> String? {
    guard let card = cards.first(where: { $0.frame.contains(point) }) else { return nil }
    let zoom = contentScale
    let point = NSPoint(x: point.x / zoom, y: point.y / zoom)
    let frame = NSRect(
      x: card.frame.minX / zoom, y: card.frame.minY / zoom, width: card.frame.width / zoom,
      height: card.frame.height / zoom)
    var unscaledCard = card
    unscaledCard.frame = frame
    let area = unscaledCard.contentRect
    switch card.content {
    case .plot(let plot):
      return hoverPlot(
        plot,
        graph: isOverview
          ? Self.overviewNetworkGraph(in: frame) : Self.plotGraphRect(plot, area: area),
        point: point, mini: isOverview)
    case .coreHistory(let matrix):
      let order = CPUCoreKind.allCases.flatMap { kind in
        matrix.kinds.indices.filter { matrix.kinds[$0] == kind }
      }
      let graph = Self.coreHistoryGraphRect(
        area: area, count: order.count, scale: window?.backingScaleFactor ?? 1)
      guard graph.contains(point) else { return nil }
      let position = Int((point.y - graph.minY) / Self.coreHistoryRowPitch)
      guard order.indices.contains(position) else { return nil }
      let index = order[position]
      let layout = coreHistoryBars(
        matrix, core: index, width: graph.width, scale: window?.backingScaleFactor ?? 1)
      guard let column = Self.hoveredColumn(layout, x: point.x - graph.minX) else {
        return "No recorded observations here"
      }
      let first = matrix.history.buckets[column.firstIndex]
      let last = matrix.history.buckets[column.lastIndex]
      var text =
        Self.hoverDate(first.first)
        + (first.first == last.last ? "" : " – " + Self.hoverDate(last.last))
      text +=
        "\n" + matrix.kinds[index].chartTitle + " core · " + matrix.statistic.title + ": "
        + ChartValueFormat.percent.string(column.first)
      text +=
        "\n" + String(column.firstWeight)
        + (column.firstWeight == 1 ? " valid observation" : " valid observations")
      if matrix.history.buckets[column.firstIndex...column.lastIndex].contains(
        where: \.coreLayoutChanged)
      {
        text += " · Core layout changed"
      }
      if column.firstMissing { text += " · Partial / missing" }
      if column.gap { text += " · Collection gap" }
      return text
    case .overviewTile(let tile):
      if let trend = tile.value.trend,
        let text = hoverPlot(
          trend, graph: Self.overviewSparkline(in: frame), point: point, mini: true)
      {
        return text
      }
      return card.spoken
    case .device: return card.spoken
    case .tiles(let tiles, let requestedColumns):
      let columns = max(1, min(requestedColumns, tiles.count))
      let rows = (tiles.count + columns - 1) / columns
      guard rows > 0 else { return nil }
      let width = (area.width - CGFloat(columns - 1) * 5) / CGFloat(columns)
      let height = (area.height - CGFloat(rows - 1) * 5) / CGFloat(rows)
      for (index, tile) in tiles.enumerated() {
        let frame = NSRect(
          x: area.minX + CGFloat(index % columns) * (width + 5),
          y: area.minY + CGFloat(index / columns) * (height + 5), width: width, height: height)
        guard frame.contains(point) else { continue }
        if let trend = tile.trend {
          let h: CGFloat = height < 65 ? 12 : 25
          let graph = NSRect(x: frame.minX + 7, y: frame.maxY - h - 4, width: width - 14, height: h)
          if let text = hoverPlot(trend, graph: graph, point: point, mini: true) { return text }
        }
        return tile.label + ": " + tile.value
      }
      return nil
    case .cores(let cpu):
      guard
        let cell = Self.coreCells(cpu, area: area, capsules: usesPopoverLayout).first(where: {
          $0.1.contains(point)
        })
      else {
        return nil
      }
      return cpu.kind(at: cell.0).chartTitle + " core: "
        + ChartValueFormat.percent.string(UtilizationMeterCell.normalized(cpu.cores[cell.0]))
    case .gauges(let gauges):
      guard area.contains(point), !gauges.isEmpty else { return nil }
      let index = min(
        gauges.count - 1, Int((point.x - area.minX) / max(1, area.width) * CGFloat(gauges.count)))
      return gauges[index].label + ": " + gauges[index].value
    case .rows:
      let rows = displayedRows(in: card)
      guard area.contains(point), !rows.isEmpty else { return nil }
      let height = min(25, area.height / CGFloat(rows.count))
      guard height > 0 else { return nil }
      let index = Int((point.y - area.minY) / height)
      guard rows.indices.contains(index) else { return nil }
      return rows[index].label + ": " + rows[index].value
        + (rows[index].second.map { " / " + $0 } ?? "")
    case .memory(let memory):
      let composition = memory.composition
      return "Physical memory\nApp: " + Display.bytes(composition.app, precise: true) + "\nWired: "
        + Display.bytes(composition.wired, precise: true) + "\nCompressed: "
        + Display.bytes(composition.compressed, precise: true) + "\nAvailable: "
        + Display.bytes(composition.available, precise: true)
    default: return nil
    }
  }
  /// Fits the marker and label in the existing legend row, including right-aligned pairs.
  func drawSeriesLegend(
    _ label: String, marker: SeriesLegendMarker, color: NSColor, rect: NSRect, size: CGFloat,
    weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left
  ) {
    let markerWidth: CGFloat = 7
    let gap: CGFloat = 4
    guard rect.width > markerWidth + gap, rect.height > 0 else { return }
    let labelWidth = rect.width - markerWidth - gap
    let attributes = textStyles.attributes(
      color: .labelColor, size: size, weight: weight, alignment: .left)
    let width = min(labelWidth, ceil((label as NSString).size(withAttributes: attributes).width))
    let x = alignment == .right ? rect.maxX - width - gap - markerWidth : rect.minX
    // Align the marker optically with the 10/12-point label glyphs, 1 pt below the em center.
    marker.draw(
      in: .init(x: x, y: rect.minY + (size - markerWidth) / 2 + 1, width: 7, height: 7),
      color: color)
    text(
      label,
      rect: .init(x: x + markerWidth + gap, y: rect.minY, width: width, height: rect.height),
      color: .labelColor, size: size, weight: weight)
  }
  private func drawPlot(_ plot: Plot, in area: NSRect) {
    guard area.height > 20 else { return }
    let paired = !plot.secondLabel.isEmpty
    let firstColor = plot.firstColor
    let secondColor = plot.secondColor
    let headline = area.height >= 90
    if headline {
      plotValue(
        plot.firstValue,
        coverage: plot.firstCoverage,
        rect: NSRect(
          x: area.minX, y: area.minY,
          width: area.width * (paired ? 0.5 : 1), height: 26), color: .labelColor,
        alignment: .left)
      drawSeriesLegend(
        plot.firstLabel, marker: plot.firstRole.legendMarker, color: firstColor,
        rect: NSRect(
          x: area.minX, y: area.minY + 26,
          width: area.width / 2, height: 14), size: 10)
      if paired {
        plotValue(
          plot.secondValue,
          coverage: plot.secondCoverage,
          rect: NSRect(
            x: area.midX, y: area.minY,
            width: area.width / 2, height: 26), color: .labelColor,
          alignment: .right)
        drawSeriesLegend(
          plot.secondLabel, marker: plot.secondRole.legendMarker, color: secondColor,
          rect: NSRect(
            x: area.midX, y: area.minY + 26,
            width: area.width / 2, height: 14), size: 10,
          alignment: .right)
      }
      if let coverage = plot.firstCoverage {
        text(
          coverage.label,
          rect: .init(
            x: area.minX, y: area.minY + 41,
            width: area.width * (paired ? 0.5 : 1), height: 13),
          color: .secondaryLabelColor, size: 10)
      }
      if paired, let coverage = plot.secondCoverage {
        text(
          coverage.label,
          rect: .init(x: area.midX, y: area.minY + 41, width: area.width / 2, height: 13),
          color: .secondaryLabelColor, size: 10, alignment: .right)
      }
    } else {
      drawSeriesLegend(
        "\(plot.firstLabel)  \(plot.firstValue)", marker: plot.firstRole.legendMarker,
        color: firstColor,
        rect: NSRect(
          x: area.minX, y: area.minY, width: area.width * (paired ? 0.5 : 1), height: 18),
        size: 12, weight: .medium)
      if paired {
        drawSeriesLegend(
          "\(plot.secondLabel)  \(plot.secondValue)", marker: plot.secondRole.legendMarker,
          color: secondColor,
          rect: NSRect(x: area.midX, y: area.minY, width: area.width / 2, height: 18),
          size: 12, weight: .medium, alignment: .right)
      }
    }
    let rawGraph = Self.plotGraphRect(plot, area: area)
    let deviceWidth =
      NSGraphicsContext.current?.cgContext.convertToDeviceSpace(
        CGSize(width: 1, height: 1)
      ).width ?? 1
    let scale = deviceWidth.isFinite && deviceWidth != 0 ? abs(deviceWidth) : 1
    let pixel = 1 / scale
    let graph = Self.snappedTimeColumn(rawGraph, scale: scale)
    let left = graph.minX
    let right = graph.maxX
    let layout = HistoryBarLayout(plot: plot, graphWidth: right - left, scale: scale)
    let midY = (plot.mirrored ? graph.midY : graph.maxY)
    let baseline = (midY * scale).rounded() / scale
    let height =
      floor(
        (plot.mirrored
          ? min(baseline - graph.minY, graph.maxY - baseline)
          : baseline - graph.minY) * scale) / scale
    NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setStroke()
    for fraction in [0.0, 0.5, 1.0] {
      let grid = NSBezierPath()
      let y = graph.minY + graph.height * fraction
      grid.move(to: NSPoint(x: graph.minX, y: y))
      grid.line(to: NSPoint(x: graph.maxX, y: y))
      grid.lineWidth = pixel
      grid.stroke()
    }
    if let fraction = plot.uncollectedFraction, fraction > 0 {
      let empty = NSRect(
        x: graph.minX, y: graph.minY, width: graph.width * fraction, height: graph.height)
      NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
      NSBezierPath(rect: empty).fill()
      if empty.width > 110 {
        text(
          "No recorded data",
          rect: NSRect(x: empty.minX + 12, y: empty.minY + 10, width: empty.width - 24, height: 16),
          color: .secondaryLabelColor, size: 10)
      }
    }
    if let labels = plot.axisLabels {
      text(
        labels.0, rect: .init(x: graph.minX, y: area.maxY - 40, width: graph.width / 2, height: 13),
        color: .secondaryLabelColor, size: 9)
      text(
        labels.1, rect: .init(x: graph.midX, y: area.maxY - 40, width: graph.width / 2, height: 13),
        color: .secondaryLabelColor, size: 9, alignment: .right)
    }
    if plot.domain != nil {
      let bands = NSBezierPath()
      for gap in layout.timeline.gaps {
        bands.appendRect(
          NSRect(
            x: left + (right - left) * gap.lowerBound, y: graph.minY,
            width: max(2 * pixel, (right - left) * (gap.upperBound - gap.lowerBound)),
            height: graph.height))
      }
      NSColor.systemOrange.withAlphaComponent(0.22).setFill()
      bands.fill()
      bands.removeAllPoints()
      for index in layout.timeline.indices
      where plot.gapBuckets.indices.contains(index) && plot.gapBuckets[index] {
        guard let position = layout.timeline.positions[index] else { continue }
        bands.appendRect(
          NSRect(
            x: min(right - 2 * pixel, left + (right - left) * position),
            y: graph.minY, width: 2 * pixel, height: graph.height))
      }
      let marker =
        NSColor.systemOrange.blended(withFraction: 0.25, of: .labelColor) ?? .systemOrange
      marker.withAlphaComponent(0.85).setFill()
      bands.fill()
    }
    if usesPopoverLayout {
      var first = plot
      if textStyleModule == .cpu {
        first.first = zip(plot.first, plot.second).map { a, b in
          guard let a, let b else { return nil }
          return a + b
        }
      }
      first.percent = false
      drawMiniHistory(first, in: graph, upperBound: layout.maximum)
      if !plot.secondLabel.isEmpty {
        var second = plot
        second.first = plot.second
        second.firstColor = plot.secondColor
        second.firstRole = plot.secondRole
        second.percent = false
        drawMiniHistory(second, in: graph, upperBound: layout.maximum)
      }
    } else {
      let firstBars = NSBezierPath()
      let secondBars = NSBezierPath()
      let missing = NSBezierPath()
      func barHeight(_ value: Double?) -> CGFloat {
        guard let value, value > 0 else { return 0 }
        return min(
          height,
          max(pixel, floor(CGFloat(min(1, value / layout.maximum)) * height * scale) / scale))
      }
      for column in layout.columns {
        let x = left + layout.x(column)
        let a = barHeight(column.first)
        let b = barHeight(column.second)
        if a > 0 {
          firstBars.appendRect(NSRect(x: x, y: baseline - a, width: layout.barWidth, height: a))
        }
        if b > 0 {
          let available = plot.mirrored ? b : min(b, max(0, height - a))
          secondBars.appendRect(
            NSRect(
              x: x,
              y: plot.mirrored ? baseline : baseline - a - available,
              width: layout.barWidth, height: available))
        }
        if column.firstMissing {
          missing.appendRect(
            NSRect(
              x: x, y: max(graph.minY, baseline - 3 * pixel),
              width: layout.barWidth, height: pixel))
        }
        if column.secondMissing {
          missing.appendRect(
            NSRect(
              x: x,
              y: plot.mirrored
                ? min(graph.maxY - pixel, baseline + 2 * pixel)
                : max(graph.minY, baseline - 5 * pixel), width: layout.barWidth, height: pixel))
        }
      }
      firstColor.setFill()
      firstBars.fill()
      secondColor.setFill()
      secondBars.fill()
      NSColor.secondaryLabelColor.setFill()
      missing.fill()
      let gaps = NSBezierPath()
      for gap in layout.timeline.gaps {
        let y = max(graph.minY + pixel, baseline - 3 * pixel)
        gaps.move(to: NSPoint(x: left + (right - left) * gap.lowerBound, y: y))
        gaps.line(to: NSPoint(x: left + (right - left) * gap.upperBound, y: y))
      }
      gaps.setLineDash([pixel, 2 * pixel], count: 2, phase: 0)
      gaps.lineWidth = pixel
      NSColor.secondaryLabelColor.setStroke()
      gaps.stroke()
    }
    let captions = PlotCaptions(plot, layout: layout, trace: usesPopoverLayout)
    if let message = captions.emptyMessage {
      text(
        message,
        rect: graph, color: .secondaryLabelColor, size: 10)
    }
    text(
      captions.span,
      rect: NSRect(x: area.minX, y: area.maxY - 25, width: area.width / 2, height: 13),
      color: .secondaryLabelColor, size: 9)
    text(
      captions.scale,
      rect: NSRect(x: area.midX, y: area.maxY - 25, width: area.width / 2, height: 13),
      color: .secondaryLabelColor, size: 9, alignment: .right)
    let reset = layout.timeline.reset ? " · timeline reset" : ""
    text(
      (plot.bucketSeconds == nil
        ? "Gaps mark missing readings" : "Gray: partial/missing · orange: gaps") + reset,
      rect: NSRect(x: area.minX, y: area.maxY - 12, width: area.width * 0.62, height: 13),
      color: .secondaryLabelColor, size: 8)
    let grouping =
      layout.grouped
      ? statisticGrouping(plot.statistic) : ""
    text(
      (plot.bucketSeconds.map { String(format: "%.0fs buckets", $0) }
        ?? layout.timeline.cadenceDescription) + grouping,
      rect: NSRect(
        x: area.minX + area.width * 0.62, y: area.maxY - 12,
        width: area.width * 0.38, height: 13), color: .secondaryLabelColor, size: 8,
      alignment: .right)
  }
}

/// Virtual rows follow current geometry without retaining a window or projection.
private final class CoreHistoryAccessibilityRow: NSAccessibilityElement {
  // The named AppKit constant is macOS 26+, but the AX action is also used on older systems.
  private static let scrollToVisibleAction = NSAccessibility.Action(rawValue: "AXScrollToVisible")
  let geometry: CoreHistoryAccessibilityGeometry
  @MainActor init(owner: SummaryDashboardView) {
    geometry = CoreHistoryAccessibilityGeometry(owner: owner)
    super.init()
  }
  override func accessibilityFrame() -> NSRect {
    let geometry = geometry
    return MainActor.assumeIsolated { geometry.screenFrame }
  }
  override func setAccessibilityFocused(_ focused: Bool) {
    let geometry = geometry
    MainActor.assumeIsolated {
      if focused { geometry.owner?.scrollToVisible(geometry.localFrame) }
    }
    super.setAccessibilityFocused(focused)
  }
  // There is no scroll-to-visible method in the modern NSAccessibility protocol.
  // VoiceOver can request this action without setting AXFocused on static text.
  override func accessibilityActionNames() -> [NSAccessibility.Action] {
    [Self.scrollToVisibleAction]
  }
  override func accessibilityActionDescription(_ action: NSAccessibility.Action) -> String? {
    action.description
  }
  override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
    if action == Self.scrollToVisibleAction {
      let geometry = geometry
      MainActor.assumeIsolated {
        guard let owner = geometry.owner else { return }
        owner.scrollToVisible(geometry.localFrame)
      }
    }
  }
}

/// AppKit's synchronous AX callbacks arrive on the main thread; assumeIsolated
/// checks that contract before accessing UI state at the nonisolated ObjC boundary.
@MainActor private final class CoreHistoryAccessibilityGeometry {
  weak var owner: SummaryDashboardView?
  var cardIndex = 0
  var position = 0
  init(owner: SummaryDashboardView) { self.owner = owner }
  var localFrame: NSRect {
    guard let owner, owner.cards.indices.contains(cardIndex),
      case .coreHistory(let matrix) = owner.cards[cardIndex].content,
      matrix.kinds.indices.contains(position)
    else { return .zero }
    let area = owner.cards[cardIndex].contentRect
    let graph = SummaryDashboardView.coreHistoryGraphRect(
      area: area, count: matrix.kinds.count, scale: owner.window?.backingScaleFactor ?? 1)
    return SummaryDashboardView.coreHistoryRowRect(area: area, graph: graph, position: position)
  }
  var screenFrame: NSRect {
    guard let owner else { return .zero }
    let frame = localFrame
    return owner.window.map { $0.convertToScreen(owner.convert(frame, to: nil)) } ?? frame
  }
}
