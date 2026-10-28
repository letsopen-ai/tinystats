import Foundation

public enum BatteryMenuState: String, CaseIterable, Codable, Sendable {
  case draining, charging, charged, externalPower
  public var title: String {
    switch self {
    case .draining: "On battery"
    case .charging: "Charging"
    case .charged: "Charged"
    case .externalPower: "On AC · not charging"
    }
  }
  public static func state(for reading: BatteryReading) -> Self {
    guard reading.externalPower else { return .draining }
    if reading.charging { return .charging }
    return reading.fullyCharged == true ? .charged : .externalPower
  }
}

public enum BatteryMenuFormat: String, CaseIterable, Codable, Sendable {
  case percent, time, percentAndTime, power, status
  public var title: String {
    switch self {
    case .percent: "Percentage"
    case .time: "Time remaining"
    case .percentAndTime: "Percentage + time"
    case .power: "Battery watts · signed"
    case .status: "Power status"
    }
  }
}

public struct BatteryMenuPreset: Codable, Equatable, Sendable {
  public var format: BatteryMenuFormat
  public var style: MenuBarStyle
  public init(format: BatteryMenuFormat = .percent, style: MenuBarStyle = .stacked) {
    self.format = format
    self.style = style
    validate()
  }
  private enum CodingKeys: String, CodingKey { case format, style }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    format = (try? values.decode(BatteryMenuFormat.self, forKey: .format)) ?? .percent
    style = (try? values.decode(MenuBarStyle.self, forKey: .style)) ?? .stacked
    validate()
  }
  public mutating func validate() {
    if !MenuBarStyle.available(for: .battery).contains(style) { style = .stacked }
  }
}

public struct BatteryMenuSettings: Codable, Equatable, Sendable {
  public var format: BatteryMenuFormat = .percent
  public var customizeStates = false
  public var draining = BatteryMenuPreset(format: .percentAndTime)
  public var charging = BatteryMenuPreset(format: .percentAndTime)
  public var charged = BatteryMenuPreset(format: .status, style: .battery)
  public var externalPower = BatteryMenuPreset(format: .status, style: .battery)
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case format, customizeStates, draining, charging, charged, externalPower
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    format = (try? values.decode(BatteryMenuFormat.self, forKey: .format)) ?? .percent
    customizeStates = (try? values.decode(Bool.self, forKey: .customizeStates)) ?? false
    draining = (try? values.decode(BatteryMenuPreset.self, forKey: .draining)) ?? draining
    charging = (try? values.decode(BatteryMenuPreset.self, forKey: .charging)) ?? charging
    charged = (try? values.decode(BatteryMenuPreset.self, forKey: .charged)) ?? charged
    externalPower =
      (try? values.decode(BatteryMenuPreset.self, forKey: .externalPower)) ?? externalPower
  }
  public subscript(state: BatteryMenuState) -> BatteryMenuPreset {
    get {
      switch state {
      case .draining: draining
      case .charging: charging
      case .charged: charged
      case .externalPower: externalPower
      }
    }
    set {
      switch state {
      case .draining: draining = newValue
      case .charging: charging = newValue
      case .charged: charged = newValue
      case .externalPower: externalPower = newValue
      }
    }
  }
  public mutating func validate() {
    for state in BatteryMenuState.allCases {
      var preset = self[state]
      preset.validate()
      self[state] = preset
    }
  }
  public func preset(for reading: BatteryReading?, defaultStyle: MenuBarStyle) -> BatteryMenuPreset
  {
    if customizeStates, let reading {
      let preset = self[BatteryMenuState.state(for: reading)]
      return .init(format: preset.format, style: preset.style)
    }
    return .init(format: format, style: defaultStyle)
  }
  public var needsHistory: Bool {
    customizeStates && BatteryMenuState.allCases.contains { self[$0].style.usesHistory }
  }
}

public struct BatteryMenuText: Equatable, Sendable {
  public let label: String, value: String, secondary: String?
  public init(reading: BatteryReading?, format: BatteryMenuFormat) {
    guard let reading else {
      label = "BAT"
      value = "AC"
      secondary = nil
      return
    }
    let state = BatteryMenuState.state(for: reading)
    let percent =
      reading.percent.isFinite && (0...100).contains(reading.percent)
      ? Display.percent(reading.percent) : "—"
    let time: String = {
      switch state {
      case .charged: return "Full"
      case .externalPower: return "AC"
      case .draining, .charging:
        guard let minutes = reading.minutesRemaining, (1...10_080).contains(minutes) else {
          return "—"
        }
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
      }
    }()
    switch format {
    case .percent:
      label = "BAT"
      value = percent
      secondary = nil
    case .time:
      label = state == .charging ? "TO FULL" : state == .draining ? "LEFT" : "BAT"
      value = time
      secondary = nil
    case .percentAndTime:
      label = "BAT"
      value = percent
      secondary =
        time == "—"
        ? time : state == .charging ? "↑ \(time)" : state == .draining ? "↓ \(time)" : time
    case .power:
      label = "BAT"
      value =
        reading.watts.flatMap { watts in
          watts.isFinite && abs(watts) <= 10_000 ? String(format: "%+.1f W", watts) : nil
        } ?? "—"
      secondary = nil
    case .status:
      label = "BAT"
      switch state {
      case .draining: value = "Battery"
      case .charging: value = "Charging"
      case .charged: value = "Full"
      case .externalPower: value = "On AC"
      }
      secondary = nil
    }
  }
}

extension MenuBarStyle {
  public var showsBatteryValue: Bool {
    switch self {
    case .text, .stacked, .value, .historyValue: true
    default: false
    }
  }
}
