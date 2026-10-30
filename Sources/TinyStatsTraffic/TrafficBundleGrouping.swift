import CTinyStatsTraffic
import Foundation

/// Executable bundle paths are observed now, not delegated network responsibility.
/// No filesystem reads, icons, IPC, timers or retained path/identity caches.
enum TrafficBundleGrouping {
  typealias Bundle = ExecutableBundle.Bundle
  static func bundle(for path: String) -> Bundle? { ExecutableBundle.bundle(for: path) }
  static func rows(_ owners: [ProcessTrafficReading]) -> [TrafficBundleReading]? {
    var buffer = [CChar](repeating: 0, count: 4096)
    return rows(owners) { owner in
      guard ts_traffic_process_path(owner.pid, owner.uniqueID, &buffer, buffer.count) else {
        return nil
      }
      return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
  }
  static func rows(
    _ owners: [ProcessTrafficReading], path: (ProcessTrafficReading) -> String?
  ) -> [TrafficBundleReading]? {
    // Full bounded ledger comes first. A duplicate/invalid owner invalidates this projection.
    guard owners.count <= 1024 else { return nil }
    struct Owner: Hashable { var pid: Int32, uniqueID: UInt64 }
    enum Key: Hashable {
      case bundle(String)
      case process(Int32, UInt64)
    }
    var seen = Set<Owner>()
    var groups: [Key: TrafficBundleReading] = [:]
    for owner in owners {
      guard owner.download.isFinite, owner.upload.isFinite,
        owner.download >= 0, owner.upload >= 0,
        seen.insert(Owner(pid: owner.pid, uniqueID: owner.uniqueID)).inserted
      else { return nil }
      guard owner.download > 0 || owner.upload > 0 else { continue }
      let bundle = owner.pid > 0 && owner.uniqueID > 0 ? path(owner).flatMap(bundle(for:)) : nil
      let key = bundle.map { Key.bundle($0.path) } ?? .process(owner.pid, owner.uniqueID)
      var row =
        groups[key]
        ?? .init(
          name: bundle?.name ?? owner.name, processCount: 0, pid: bundle == nil ? owner.pid : nil,
          download: 0, upload: 0, bundlePath: bundle?.path)
      row.processCount += 1
      row.download += owner.download
      row.upload += owner.upload
      guard row.download.isFinite, row.upload.isFinite, (row.download + row.upload).isFinite else {
        return nil
      }
      groups[key] = row
    }
    func order(_ key: Key) -> String {
      switch key {
      case .bundle(let path): return "b:" + path
      case .process(let pid, let unique): return "p:\(pid):\(unique)"
      }
    }
    return groups.sorted {
      let a = $0.value.download + $0.value.upload
      let b = $1.value.download + $1.value.upload
      if a != b { return a > b }
      if $0.value.name != $1.value.name { return $0.value.name < $1.value.name }
      return order($0.key) < order($1.key)
    }.prefix(8).map(\.value)
  }
}
