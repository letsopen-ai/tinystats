import Foundation

/// The power source a per-source macOS energy setting or Power-item visibility applies to.
public enum PowerSourceKind: String, CaseIterable, Codable, Sendable {
  case adapter, battery
  public var title: String { self == .adapter ? "Power Adapter" : "Battery" }
  public var symbol: String { self == .adapter ? "powerplug.fill" : "battery.75percent" }
  /// `pmset` source selector: `-c` charger (wall power) or `-b` battery.
  public var pmsetFlag: String { self == .adapter ? "-c" : "-b" }
  var pmsetSection: String { self == .adapter ? "AC Power" : "Battery Power" }

  /// The source an internal battery reading confirms; nil when there is no reading.
  public static func confirmed(_ batteries: [BatteryReading]) -> Self? {
    batteries.first.map { $0.externalPower ? .adapter : .battery }
  }

  /// The internal battery reading decides the source. With no reading, `lastKnown` (the last
  /// confirmed source this session) is kept, so a failed read on a laptop does not flip the
  /// source; a Mac that never reported a battery (desktop) is on external power.
  public static func current(_ batteries: [BatteryReading], lastKnown: Self? = nil) -> Self {
    confirmed(batteries) ?? lastKnown ?? .adapter
  }
}

/// macOS Energy Mode choices, matching System Settings › Battery/Energy › Energy Mode.
public enum EnergyMode: Int, CaseIterable, Codable, Sendable {
  case low = 1
  case automatic = 0
  case high = 2
  /// Display order: Low Power, Automatic, High Performance.
  public static let ordered: [Self] = [.low, .automatic, .high]
  public var title: String {
    switch self {
    case .low: "Low Power"
    case .automatic: "Automatic"
    case .high: "High Performance"
    }
  }
  public var symbol: String {
    switch self {
    case .low: "leaf.fill"
    case .automatic: "a.circle.fill"
    case .high: "hare.fill"
    }
  }
}

/// Which `pmset` keys this Mac exposes. Decided from key evidence, never a model list.
public enum EnergyModeKeyLayout: String, Sendable, Equatable {
  /// `powermode 0|1|2` (Automatic/Low/High).
  case unified
  /// Separate `lowpowermode 0|1` and `highpowermode 0|1`.
  case legacyHighPower
  /// `lowpowermode 0|1` only.
  case lowPowerOnly
  public var supportsHigh: Bool { self != .lowPowerOnly }
  public var modes: [EnergyMode] { supportsHigh ? EnergyMode.ordered : [.low, .automatic] }
}

/// One unprivileged reading of the per-source energy settings.
public struct EnergyModeStatus: Equatable, Sendable {
  public var layout: EnergyModeKeyLayout
  /// Sources macOS keeps a profile for, in display order (adapter first).
  public var sources: [PowerSourceKind]
  /// nil = the source exists but its current value could not be read.
  public var modes: [PowerSourceKind: EnergyMode]
  public init(
    layout: EnergyModeKeyLayout, sources: [PowerSourceKind], modes: [PowerSourceKind: EnergyMode]
  ) {
    self.layout = layout
    self.sources = sources
    self.modes = modes
  }
  public var supportsHigh: Bool { layout.supportsHigh }
}

public enum EnergyModeReading: Equatable, Sendable {
  case available(EnergyModeStatus)
  /// pmset ran and reported no energy-mode keys: hide the section.
  case unsupported
  /// pmset could not be read (missing, timeout, failure): offer only the Settings fallback.
  case unavailable
}

/// Parses `pmset -g custom` and `pmset -g cap` text. Pure; unknown lines are ignored.
public enum EnergyModeParser {
  static let maximumBytes = 64 * 1024

  public static func parse(custom: String, capabilities: String) -> EnergyModeReading {
    guard custom.utf8.count <= maximumBytes, capabilities.utf8.count <= maximumBytes else {
      return .unavailable
    }
    let sections = Self.sections(custom)
    let sources = PowerSourceKind.allCases.filter { sections[$0] != nil }
    var keys = Set(sections.values.flatMap(\.keys))
    for line in capabilities.split(whereSeparator: \.isNewline) {
      let token = line.trimmingCharacters(in: .whitespaces)
      if !token.contains(" ") && !token.hasSuffix(":") { keys.insert(token) }
    }
    let layout: EnergyModeKeyLayout
    if keys.contains("powermode") {
      layout = .unified
    } else if keys.contains("highpowermode") {
      layout = .legacyHighPower
    } else if keys.contains("lowpowermode") {
      layout = .lowPowerOnly
    } else {
      return .unsupported
    }
    // A capability without any readable source profile cannot be shown per source.
    guard !sources.isEmpty else { return .unsupported }
    var modes: [PowerSourceKind: EnergyMode] = [:]
    for source in sources {
      if let values = sections[source], let mode = mode(values, layout: layout) {
        modes[source] = mode
      }
    }
    return .available(.init(layout: layout, sources: sources, modes: modes))
  }

  static func mode(_ values: [String: Int], layout: EnergyModeKeyLayout) -> EnergyMode? {
    switch layout {
    case .unified:
      if let raw = values["powermode"] { return EnergyMode(rawValue: raw) }
      return legacy(values, high: true)
    case .legacyHighPower: return legacy(values, high: true)
    case .lowPowerOnly: return legacy(values, high: false)
    }
  }

  private static func legacy(_ values: [String: Int], high: Bool) -> EnergyMode? {
    let low = values["lowpowermode"]
    let highValue = high ? values["highpowermode"] : nil
    guard low != nil || highValue != nil else { return nil }
    guard [low, highValue].allSatisfy({ $0 == nil || $0 == 0 || $0 == 1 }) else { return nil }
    if low == 1 && highValue == 1 { return nil }
    if highValue == 1 { return .high }
    if low == 1 { return .low }
    // Automatic needs every relevant key read as 0: under the legacy pair a missing
    // counterpart could still mean Low Power or High Power.
    if high && (low == nil || highValue == nil) { return nil }
    return .automatic
  }

  /// `Battery Power:` / `AC Power:` headers followed by `key value` lines.
  static func sections(_ text: String) -> [PowerSourceKind: [String: Int]] {
    var result: [PowerSourceKind: [String: Int]] = [:]
    var current: PowerSourceKind?
    var inOtherSection = false
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if line.hasSuffix(":") {
        let name = String(line.dropLast())
        current = PowerSourceKind.allCases.first { $0.pmsetSection == name }
        inOtherSection = current == nil
        if let current, result[current] == nil { result[current] = [:] }
        continue
      }
      guard let current, !inOtherSection else { continue }
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2, let key = fields.first.map(String.init),
        ["lowpowermode", "highpowermode", "powermode"].contains(key)
      else { continue }
      result[current]?[key] = Int(fields[1])
    }
    return result
  }
}

/// Fixed `/usr/bin/pmset` argument vectors. Only these whitelisted tokens may ever be passed
/// to the privileged path; nothing user-controlled is interpolated.
public enum EnergyModeCommand {
  public static let executable = "/usr/bin/pmset"
  public static let allowedTokens: Set<String> = [
    "-b", "-c", "powermode", "lowpowermode", "highpowermode", "0", "1", "2",
  ]

  public static func arguments(
    mode: EnergyMode, source: PowerSourceKind, layout: EnergyModeKeyLayout
  ) -> [String]? {
    let flag = source.pmsetFlag
    switch layout {
    case .unified:
      return [flag, "powermode", String(mode.rawValue)]
    case .legacyHighPower:
      return [
        flag, "lowpowermode", mode == .low ? "1" : "0", "highpowermode", mode == .high ? "1" : "0",
      ]
    case .lowPowerOnly:
      guard mode != .high else { return nil }
      return [flag, "lowpowermode", mode == .low ? "1" : "0"]
    }
  }

  /// Every vector `arguments(mode:source:layout:)` can produce (at most 16).
  public static let generatedVectors: Set<[String]> = {
    var result = Set<[String]>()
    for layout in [EnergyModeKeyLayout.unified, .legacyHighPower, .lowPowerOnly] {
      for source in PowerSourceKind.allCases {
        for mode in EnergyMode.allCases {
          if let vector = arguments(mode: mode, source: source, layout: layout) {
            result.insert(vector)
          }
        }
      }
    }
    return result
  }()

  /// True only for an exact vector this module could have produced: shape, key order and
  /// key/value combinations included, not merely whitelisted tokens.
  public static func isAllowed(_ arguments: [String]) -> Bool {
    generatedVectors.contains(arguments)
      && arguments.allSatisfy(allowedTokens.contains)
  }
}

/// Power menu-bar item visibility per power source. Stored inside `batteryMenu` so the
/// internal `battery` key and all other Power choices stay unchanged.
public struct PowerItemVisibility: Codable, Equatable, Sendable {
  public var onAdapter = true
  public var onBattery = true
  public init(onAdapter: Bool = true, onBattery: Bool = true) {
    self.onAdapter = onAdapter
    self.onBattery = onBattery
  }
  private enum CodingKeys: String, CodingKey { case onAdapter, onBattery }
  /// Missing or malformed fields keep today's behaviour (shown); one bad field cannot hide
  /// the item or erase the other choice.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    onAdapter = (try? values.decode(Bool.self, forKey: .onAdapter)) ?? true
    onBattery = (try? values.decode(Bool.self, forKey: .onBattery)) ?? true
  }
  public subscript(source: PowerSourceKind) -> Bool {
    get { source == .adapter ? onAdapter : onBattery }
    set {
      if source == .adapter { onAdapter = newValue } else { onBattery = newValue }
    }
  }
  public var hidesEverywhere: Bool { !onAdapter && !onBattery }
  public func isVisible(on source: PowerSourceKind) -> Bool { self[source] }
}

extension Settings {
  /// Enabled modules hidden only because of the current power source (not disabled).
  public func powerHiddenModules(
    batteries: [BatteryReading], lastKnown: PowerSourceKind? = nil
  ) -> Set<Module> {
    guard readouts.contains(.battery),
      !batteryMenu.visibility.isVisible(
        on: PowerSourceKind.current(batteries, lastKnown: lastKnown))
    else { return [] }
    return [.battery]
  }

  /// The readouts actually presented in the menu bar for the current power source.
  public func presentedReadouts(
    batteries: [BatteryReading], lastKnown: PowerSourceKind? = nil
  ) -> [Module] {
    let hidden = powerHiddenModules(batteries: batteries, lastKnown: lastKnown)
    return readouts.filter { !hidden.contains($0) }
  }
}
