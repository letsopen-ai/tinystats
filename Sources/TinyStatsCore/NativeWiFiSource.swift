import CoreWLAN
import Foundation

/// Read current radio telemetry only. Do not call scanning, association, power/configuration,
/// SSID/BSSID/country-code, location, keychain or private preferences APIs.
final class NativeWiFiSource: WiFiSource {
  private let client = CWWiFiClient()
  func read(names: [String]) -> WiFiSnapshot {
    var result = WiFiSnapshot()
    guard let available = client.interfaceNames() else {
      result.state = .unavailable
      return result
    }
    let discovered = Set(available).intersection(names).sorted()
    result.truncated = discovered.count > 8
    result.state = .ready
    result.interfaces = discovered.prefix(8).map { name in
      guard let interface = client.interface(withName: name) else {
        return WiFiReading(interface: name)
      }
      let powered = interface.powerOn()
      let mode = interface.interfaceMode().rawValue
      guard powered, (1...3).contains(mode) else {
        return .decode(interface: name, powered: powered, mode: mode)
      }
      let channel = interface.wlanChannel()
      let row = WiFiReading.decode(
        interface: name, powered: powered, mode: mode,
        rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
        transmitMbps: interface.transmitRate(), channel: channel?.channelNumber ?? 0,
        band: channel?.channelBand.rawValue ?? 0, width: channel?.channelWidth.rawValue ?? 0,
        phy: interface.activePHYMode().rawValue, security: interface.security().rawValue)
      // These IPC calls aren't atomic. Withhold a visibly changing link rather than mix epochs.
      let confirmed = interface.wlanChannel()
      guard interface.powerOn(), interface.interfaceMode().rawValue == mode,
        channel?.channelNumber == confirmed?.channelNumber,
        channel?.channelBand == confirmed?.channelBand,
        channel?.channelWidth == confirmed?.channelWidth
      else { return WiFiReading(interface: name) }
      return row
    }
    return result
  }
}
