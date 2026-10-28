import Foundation
import Testing

@testable import TinyStatsCore

@Test func wifiDecodingPreservesUnitsAndRejectsUnavailableSentinels() {
  let row = WiFiReading.decode(
    interface: "en0", powered: true, mode: 1, rssi: -52, noise: -91,
    transmitMbps: 1200.5, channel: 37, band: 3, width: 3, phy: 6, security: 11)
  #expect(row.state == .station && row.rssi == -52 && row.noise == -91)
  #expect(row.signalToNoise == 39 && row.transmitMbps == 1200.5)
  #expect(row.channel == 37 && row.band == "6 GHz" && row.widthMHz == 80)
  #expect(row.phy == "802.11ax" && row.security == "WPA3 Personal")
  let empty = WiFiReading.decode(interface: "en0", powered: true, mode: 1)
  #expect(empty.rssi == nil && empty.noise == nil && empty.transmitMbps == nil)
  #expect(empty.channel == nil && empty.band == nil && empty.widthMHz == nil)
  #expect(empty.phy == nil && empty.security == nil && empty.signalToNoise == nil)
  for value in [Double.nan, .infinity, -.infinity, -1, 0, 100_001] {
    #expect(
      WiFiReading.decode(interface: "en0", powered: true, mode: 1, transmitMbps: value).transmitMbps
        == nil)
  }
  for value in [Int.min, -129, 0, 1, Int.max] {
    let invalid = WiFiReading.decode(
      interface: "en0", powered: true, mode: 1, rssi: value, noise: value)
    #expect(invalid.rssi == nil && invalid.noise == nil && invalid.signalToNoise == nil)
  }
  let unknown = WiFiReading.decode(
    interface: "en0", powered: true, mode: 1, channel: -1,
    band: 99, width: 99, phy: 99, security: 99)
  #expect(unknown.channel == nil && unknown.band == nil && unknown.widthMHz == nil)
  #expect(unknown.phy == nil && unknown.security == nil)
  var overflow = row
  overflow.rssi = Int.min
  overflow.noise = Int.max
  #expect(overflow.signalToNoise == nil)
}

@Test func wifiDisconnectedAndUnknownModesNeverInheritAssociatedCounters() {
  for (powered, mode, state): (Bool, Int, WiFiReading.State) in [
    (false, 1, .offOrUnavailable), (true, 0, .notAssociatedOrUnavailable),
    (true, 999, .notAssociatedOrUnavailable),
  ] {
    let row = WiFiReading.decode(
      interface: "en0", powered: powered, mode: mode, rssi: -60,
      noise: -90, transmitMbps: 600, channel: 44, band: 2, width: 2, phy: 5, security: 4)
    #expect(row.state == state)
    #expect(row.rssi == nil && row.noise == nil && row.transmitMbps == nil && row.channel == nil)
    #expect(row.phy == nil && row.security == nil)
  }
  #expect(WiFiReading.decode(interface: "en0", powered: true, mode: 2).state == .ibss)
  #expect(WiFiReading.decode(interface: "en0", powered: true, mode: 3).state == .accessPoint)
  #expect(
    WiFiReading.decode(interface: "en0", powered: true, mode: 1, security: 0).security == "Open")
  #expect(WiFiReading.decode(interface: "en0", powered: true, mode: 1, phy: 7).phy == "802.11be")
}

private func wifiInterface(index: UInt32 = 1, name: String = "en0") -> InterfaceReading {
  .init(
    name: name, address: "", up: true, received: 0, sent: 0, download: nil, upload: nil,
    index: index)
}

/// Test controls are locked; source construction/destruction/read happen on the reader's worker.
private final class WiFiProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var counts = (made: 0, read: 0, released: 0)
  var blockCall = 1
  var failCall = 0
  let began = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
  var current: (made: Int, read: Int, released: Int) {
    lock.lock()
    defer { lock.unlock() }
    return counts
  }
  func made() {
    lock.lock()
    counts.made += 1
    lock.unlock()
  }
  func released() {
    lock.lock()
    counts.released += 1
    lock.unlock()
  }
  func read(_ names: [String]) -> WiFiSnapshot {
    lock.lock()
    counts.read += 1
    let call = counts.read
    lock.unlock()
    began.signal()
    if call == blockCall { _ = gate.wait(timeout: .now() + 3) }
    var result = WiFiSnapshot()
    result.state = call == failCall ? .unavailable : .ready
    result.interfaces =
      call == failCall
      ? []
      : names.map {
        .decode(interface: $0, powered: true, mode: 1, rssi: -40 - call)
      }
    return result
  }
}
private final class FakeWiFiSource: WiFiSource {
  let probe: WiFiProbe
  init(_ probe: WiFiProbe) {
    self.probe = probe
    probe.made()
  }
  deinit { probe.released() }
  func read(names: [String]) -> WiFiSnapshot { probe.read(names) }
}
private func wifiEventually(_ condition: () -> Bool) -> Bool {
  let until = ProcessInfo.processInfo.systemUptime + 2
  while ProcessInfo.processInfo.systemUptime < until {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.001)
  }
  return condition()
}

@Test func wifiReaderIsLazyCoalescesSlowCallsAndRejectsResultsAfterStopAndRestart() {
  let probe = WiFiProbe()
  let reader = WiFiReader { FakeWiFiSource(probe) }
  let interfaces = [wifiInterface()]
  reader.stop()
  reader.stop()
  #expect(probe.current.made == 0)
  #expect(reader.read(at: 100, interfaces: interfaces).state == .loading)
  #expect(probe.began.wait(timeout: .now() + 2) == .success)
  for _ in 0..<100 { #expect(reader.read(at: 104, interfaces: interfaces).state == .loading) }
  #expect(probe.current.read == 1)
  reader.stop()
  #expect(reader.read(at: 105, interfaces: interfaces).state == .loading)
  probe.gate.signal()
  var leakedOldResult = false
  #expect(
    wifiEventually {
      let value = reader.read(at: 105, interfaces: interfaces)
      if value.interfaces.first?.rssi == -41 { leakedOldResult = true }
      return value.interfaces.first?.rssi == -42
    })
  #expect(!leakedOldResult && probe.current.read == 2)
  #expect(probe.current.made == 1)
  reader.stop()
  #expect(wifiEventually { probe.current.released == 1 })
}

@Test func wifiCacheExpiresDuringSlowRefreshAndDropsFailedOrReplacedInterfaceValues() {
  let probe = WiFiProbe()
  probe.blockCall = 2
  probe.failCall = 3
  let reader = WiFiReader { FakeWiFiSource(probe) }
  let interfaces = [wifiInterface()]
  _ = reader.read(at: 0, interfaces: interfaces)
  #expect(wifiEventually { reader.read(at: 0, interfaces: interfaces).state == .ready })
  #expect(reader.read(at: 4.999, interfaces: interfaces).sampledAt == 0)
  #expect(probe.current.read == 1)
  #expect(reader.read(at: 16, interfaces: interfaces).state == .unavailable)
  #expect(probe.began.wait(timeout: .now() + 2) == .success)
  // Consume the signal from the first read too; the second call stays in flight.
  #expect(wifiEventually { probe.current.read == 2 })
  for _ in 0..<100 { #expect(reader.read(at: 20, interfaces: interfaces).interfaces.isEmpty) }
  probe.gate.signal()
  #expect(wifiEventually { reader.read(at: 20, interfaces: interfaces).sampledAt == 16 })
  let replaced = [wifiInterface(index: 2)]
  #expect(reader.read(at: 20, interfaces: replaced).interfaces.isEmpty)
  #expect(wifiEventually { reader.read(at: 20, interfaces: replaced).state == .unavailable })
  #expect(reader.read(at: 20, interfaces: replaced).interfaces.isEmpty)
  // A backwards clock invalidates old data and allows a fresh request.
  #expect(reader.read(at: 1, interfaces: replaced).interfaces.isEmpty)
  #expect(wifiEventually { reader.read(at: 1, interfaces: replaced).state == .ready })
  reader.stop()
  #expect(wifiEventually { probe.current.released == 1 })
}

@Test func wifiReaderBoundsInventoriesAndDoesNotRetainOldValuesAfterDisappearance() {
  let probe = WiFiProbe()
  probe.blockCall = 0
  let reader = WiFiReader { FakeWiFiSource(probe) }
  let interfaces = (0..<200).map { wifiInterface(index: UInt32($0), name: "en\($0)") }
  _ = reader.read(at: 1, interfaces: interfaces)
  #expect(wifiEventually { reader.read(at: 1, interfaces: interfaces).state == .ready })
  #expect(reader.read(at: 1, interfaces: interfaces).interfaces.count == 8)
  #expect(reader.read(at: 2, interfaces: []).interfaces.isEmpty)
  #expect(wifiEventually { reader.read(at: 2, interfaces: []).state == .ready })
  #expect(reader.read(at: 2, interfaces: []).interfaces.isEmpty)
  #expect(reader.read(at: .nan, interfaces: interfaces).state == .inactive)
  #expect(wifiEventually { probe.current.released == 1 })
}

@Test func wifiStopDuringBlockedIPCReleasesTheSourceWithoutAnotherSampleOrQueuedRead() {
  let probe = WiFiProbe()
  let reader = WiFiReader { FakeWiFiSource(probe) }
  _ = reader.read(at: 1, interfaces: [wifiInterface()])
  #expect(probe.began.wait(timeout: .now() + 2) == .success)
  reader.stop()
  for _ in 0..<100 { reader.stop() }
  #expect(probe.current.read == 1 && probe.current.released == 0)
  probe.gate.signal()
  #expect(wifiEventually { probe.current.released == 1 })
  #expect(probe.current.read == 1)
}
