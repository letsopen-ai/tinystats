import Darwin
import Foundation
import IOKit

/// Local, non-personal identity, read once on the sampler's serial worker queue.
/// Never reads the computer/user name, serial number or hardware UUID.
public struct DeviceIdentity: Sendable {
  public var model: String?, chip: String?, operatingSystem: String?
  public init(model: String? = nil, chip: String? = nil, operatingSystem: String? = nil) {
    self.model = model
    self.chip = chip
    self.operatingSystem = operatingSystem
  }

  static func text(_ data: Data) -> String? {
    guard data.count <= 1024,
      let value = String(data: data.prefix { $0 != 0 }, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }

  static func read() -> Self {
    func sysctlText(_ name: String) -> String? {
      var count = 0
      guard sysctlbyname(name, nil, &count, nil, 0) == 0, (1...1024).contains(count) else {
        return nil
      }
      var bytes = [UInt8](repeating: 0, count: count)
      guard sysctlbyname(name, &bytes, &count, nil, 0) == 0 else { return nil }
      return text(Data(bytes.prefix(count)))
    }
    var model: String?
    let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/")
    if root != 0 {
      defer { IOObjectRelease(root) }
      if let data = property(root, "product-name") as? Data { model = text(data) }
    }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return .init(
      model: model ?? sysctlText("hw.model"), chip: sysctlText("machdep.cpu.brand_string"),
      operatingSystem:
        "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
  }
}
