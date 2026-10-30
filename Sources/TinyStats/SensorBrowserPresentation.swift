import AppKit
import TinyStatsCore

/// These identities never enter Settings, alerts or persisted history.
enum SensorBrowserIdentity: Equatable {
  enum Hottest: Equatable { case cpu, gpu }
  case reading(String)
  case hottest(Hottest)
}

/// Input-only formatting of the bounded, view-local sensor browser.
@MainActor
enum SensorBrowserPresentation {
  struct Presentation {
    var selection: SensorBrowserIdentity?
    var title: String
    var count: String
    var countAccessibilityLabel: String
    var value: String
    var subtitle: String
    var rows: [DetailRow]
    var series: [ChartView.Series]
    var unit: String
    var available: Bool
  }

  static func build(
    snapshot: Snapshot, timeline: SensorTimeline, settings: Settings, query: String,
    showsAll: Bool, selection: SensorBrowserIdentity?, paused: Bool = false
  ) -> Presentation {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    // Platform recognition already happened in the collector. Catalog entries are currently
    // platform-independent; group-only AS conventions deliberately have no friendly name.
    #if arch(arm64)
      let appleSilicon = true
    #else
      let appleSilicon = false
    #endif
    func friendly(_ reading: SensorReading) -> String? {
      SensorCatalog.friendlyName(for: reading.key, appleSilicon: appleSilicon)
    }
    func matches(_ fields: [String]) -> Bool {
      query.isEmpty
        || query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { word in
          fields.contains { $0.localizedCaseInsensitiveContains(String(word)) }
        }
    }
    func rawLabel(_ reading: SensorReading) -> String {
      reading.name == reading.key || reading.name.hasSuffix("· \(reading.key)")
        ? reading.name : reading.name + " · " + reading.key
    }
    func physicalRow(_ reading: SensorReading) -> DetailRow {
      .init(
        label: showsAll || !query.isEmpty ? rawLabel(reading) : friendly(reading) ?? reading.name,
        value: reading.formatted(fahrenheit: settings.fahrenheit),
        sensorIdentity: .reading(reading.key))
    }
    let physical = snapshot.sensors.filter {
      matches([
        $0.name, friendly($0) ?? "", $0.key, $0.component.title, $0.kind.unit, $0.kind.rawValue,
      ])
    }
    // Match the existing cpuTemperature/history recognition exactly; don't broaden it here.
    let cpu = snapshot.sensors.filter { $0.kind == .temperature && $0.name.hasPrefix("CPU") }
    let gpu = snapshot.sensors.filter { $0.kind == .temperature && $0.component == .gpu }
    func temperatures(_ type: SensorBrowserIdentity.Hottest) -> [SensorReading] {
      type == .cpu ? cpu : gpu
    }
    func hottest(_ type: SensorBrowserIdentity.Hottest) -> SensorReading? {
      temperatures(type).sorted { $0.key < $1.key }.max { $0.value < $1.value }
    }
    func hottestLabel(_ type: SensorBrowserIdentity.Hottest) -> String {
      type == .cpu ? SensorCatalog.hottestCPULabel : SensorCatalog.hottestGPULabel
    }
    var highlights: [DetailRow] = []
    for type in [SensorBrowserIdentity.Hottest.cpu, .gpu] {
      let current = hottest(type)
      let missingCPU = type == .cpu && snapshot.sensors.contains { $0.kind == .temperature }
      guard current != nil || missingCPU else { continue }
      guard matches([hottestLabel(type), "hottest", "max", "temperature", "temp", "°C", "°F"])
      else {
        continue
      }
      highlights.append(
        .init(
          label: type == .cpu ? "Hottest CPU sensor" : "Hottest GPU sensor",
          value: current?.formatted(fahrenheit: settings.fahrenheit) ?? "Unavailable",
          sensorIdentity: current == nil ? nil : .hottest(type),
          help: current == nil ? "No recognized CPU sensors · see All readings" : hottestLabel(type)
        ))
    }
    if snapshot.sensors.filter({ !$0.key.hasPrefix("ioreport:") }).count >= 128 {
      highlights.append(
        .init(
          label: "Sensors may be missing", value: "",
          help: "SMC scan limit: 128. See All readings for details."))
    }
    let highlightKeys =
      snapshot.sensors.filter { $0.kind == .fan }.sorted { $0.key < $1.key }
      + ["TB0T", "PSTR", "ioreport:cpu", "ioreport:gpu", "ioreport:ane", "ioreport:dram"]
      .compactMap { key in snapshot.sensors.first { $0.key == key } }
    // Prominent physical readings belong once in their component group; Highlights
    // contains only the distinct hottest-temperature projections.
    let prominentKeys = Set(highlightKeys.map(\.key))
    var rows: [DetailRow] = []
    if !highlights.isEmpty {
      rows.append(.init(label: "HIGHLIGHTS", value: "", heading: true))
      rows += highlights
    }
    for component in SensorComponent.allCases {
      let group = physical.filter { $0.component == component }.sorted { $0.key < $1.key }
      guard !group.isEmpty else { continue }
      rows.append(.init(label: component.title.uppercased(), value: "", heading: true))
      if showsAll || !query.isEmpty {
        rows += group.map(physicalRow)
      } else {
        rows += group.filter { friendly($0) != nil || prominentKeys.contains($0.key) }.map(
          physicalRow)
        let unnamed = group.filter { friendly($0) == nil && !prominentKeys.contains($0.key) }
        if unnamed.count == 1, let reading = unnamed.first {
          rows.append(physicalRow(reading))
        } else if !unnamed.isEmpty {
          let label = summaryLabel(unnamed, component: component, fahrenheit: settings.fahrenheit)
          let spoken = label.replacingOccurrences(of: "–", with: " to ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "°C", with: "degrees Celsius")
            .replacingOccurrences(of: "°F", with: "degrees Fahrenheit")
          rows.append(
            .init(
              label: "\(unnamed.count) more \(unnamed.count == 1 ? "sensor" : "sensors")",
              value: "All readings",
              accessibilityLabel: spoken + ", available in All readings", help: label))
        }
      }
    }
    if rows.isEmpty {
      rows.append(
        .init(
          label: snapshot.sensors.isEmpty ? "No readable sensors" : "No matching sensors", value: ""
        ))
    }
    let defaultSelection: SensorBrowserIdentity?
    if snapshot.sensor(for: settings.sensorKey) != nil {
      defaultSelection = settings.sensorKey == "cpu" ? .hottest(.cpu) : .reading(settings.sensorKey)
    } else if !cpu.isEmpty {
      defaultSelection = .hottest(.cpu)
    } else if !gpu.isEmpty {
      defaultSelection = .hottest(.gpu)
    } else {
      defaultSelection =
        highlights.compactMap(\.sensorIdentity).first
        ?? highlightKeys.first(where: { prominent in physical.contains { $0.key == prominent.key } }
        )
        .map { .reading($0.key) }
        ?? rows.compactMap { row -> SensorBrowserIdentity? in
          guard let identity = row.sensorIdentity else { return nil }
          if !showsAll, query.isEmpty, case .reading(let key) = identity,
            let reading = snapshot.sensor(for: key), friendly(reading) == nil,
            !prominentKeys.contains(key)
          {
            // Revealing a singleton must not silently replace the existing initial
            // focus with an unclassified reading. It remains explicitly selectable.
            return nil
          }
          return identity
        }.first
    }
    let selected = selection ?? defaultSelection
    var chosen: SensorReading?
    var subtitle = "Select a sensor below"
    var name = "Selected sensor"
    var chartName: String?
    var kind: SensorReading.Kind?
    var values = [Double?](repeating: nil, count: timeline.count)
    switch selected {
    case .reading(let key):
      chosen = snapshot.sensor(for: key)
      name = chosen?.name ?? key
      chartName = chosen.flatMap(friendly)
      subtitle =
        chosen.map {
          (showsAll ? rawLabel($0) : friendly($0) ?? $0.name)
        } ?? key + " · currently unavailable"
      kind = chosen?.kind ?? timeline.kind(for: key)
      values = timeline.values(for: key, fahrenheit: settings.fahrenheit, kind: kind)
    case .hottest(let type):
      chosen = hottest(type)
      name = hottestLabel(type)
      chartName = type == .cpu ? "Hottest CPU sensor" : "Hottest GPU sensor"
      kind = .temperature
      let component = type == .cpu ? "CPU" : "GPU"
      subtitle =
        chosen.map { reading in
          "Hottest \(component) sensor" + (showsAll ? " · now \(reading.key)" : "")
        } ?? name + " · currently unavailable"
      values = timeline.maximumValues(
        for: temperatures(type).map(\.key), fahrenheit: settings.fahrenheit)
    case nil: break
    }
    if !showsAll && query.isEmpty {
      // Keep every selectable identity and its row index stable across selection. Only
      // suppress the repeated number; AX still describes the reading in full.
      for index in rows.indices {
        let identity = rows[index].sensorIdentity
        let duplicatesHeadline =
          identity == selected
          || {
            if case .hottest = selected { return identity == chosen.map { .reading($0.key) } }
            return false
          }()
        if identity != nil && duplicatesHeadline {
          rows[index].accessibilityLabel = rows[index].label + ": " + rows[index].value
          rows[index].value = ""
        }
      }
    }
    return Presentation(
      selection: selected,
      title: "SENSORS" + (paused ? " · PAUSED" : ""),
      count: query.isEmpty
        ? "\(snapshot.sensors.count) sensors"
        : "\(physical.count) of \(snapshot.sensors.count) sensors",
      countAccessibilityLabel: query.isEmpty
        ? "\(snapshot.sensors.count) readable sensors"
        : "\(physical.count) of \(snapshot.sensors.count) readable sensors match the search",
      value: chosen?.formatted(fahrenheit: settings.fahrenheit) ?? "Sensor unavailable",
      subtitle: subtitle, rows: rows,
      series: [
        .init(name: name, color: SystemStyle.accent, values: values, displayName: chartName)
      ],
      unit: kind == .temperature && settings.fahrenheit ? "°F" : kind?.unit ?? "",
      available: chosen != nil)
  }

  private static func summaryLabel(
    _ readings: [SensorReading], component: SensorComponent, fahrenheit: Bool
  ) -> String {
    let noun = component == .other ? "readings" : "\(component.title) sensors"
    let prefix = "\(readings.count) more \(noun)"
    guard let first = readings.first else { return prefix }
    if readings.allSatisfy({ $0.kind == first.kind }),
      let minimum = readings.map(\.value).min(), let maximum = readings.map(\.value).max()
    {
      func value(_ number: Double) -> String {
        let converted = first.kind == .temperature && fahrenheit ? number * 1.8 + 32 : number
        return String(format: first.kind == .fan ? "%.0f" : "%.1f", converted)
      }
      let unit = first.kind == .temperature && fahrenheit ? "°F" : first.kind.unit
      return prefix + " · \(value(minimum))–\(value(maximum)) \(unit)"
    }
    let counts = [SensorReading.Kind.temperature, .fan, .power, .voltage, .current].compactMap {
      kind in
      let count = readings.filter { $0.kind == kind }.count
      return count == 0 ? nil : "\(kind.rawValue) \(count)"
    }
    return prefix + " · " + counts.joined(separator: " · ")
  }
}
