import CTinyStats
import Foundation
import Testing

@testable import TinyStatsCore

private func interface(_ name: String, index: UInt32, up: Bool = true) -> InterfaceReading {
  .init(
    name: name, address: "", up: up, received: 0, sent: 0, download: nil, upload: nil, index: index)
}

@Test func networkPrefixRejectsNoncontiguousMasks() {
  #expect(ts_network_prefix([255, 255, 255, 0], 4) == 24)
  #expect(ts_network_prefix([0, 0, 0, 0], 4) == 0)
  #expect(ts_network_prefix([255, 255, 255, 255], 4) == 32)
  #expect(ts_network_prefix([255, 0, 255, 0], 4) == -1)
  #expect(ts_network_prefix(Array(repeating: 255, count: 16), 16) == 128)
  #expect(
    ts_network_prefix(Array(repeating: 255, count: 8) + Array(repeating: 0, count: 8), 16) == 64)
  #expect(ts_network_prefix([255], 1) == -1)
  #expect(ts_network_prefix(nil, 4) == -1)
}

@Test func networkIPValidationAndScopeRetainZones() {
  #expect(NetworkIP.bytes("192.0.2.1") == [192, 0, 2, 1])
  #expect(NetworkIP.bytes("fe80::1%en0")?.count == 16)
  #expect(NetworkIP.bytes("fe80::1%5")?.count == 16)
  for invalid in [
    "example.com", "1.2.3.999", "192.0.2.1%en0", "fe80::1%", "fe80::1%en0%extra", "fe80::1%en0\n",
    "192.0.2.1\0other",
  ] {
    #expect(NetworkIP.valid(invalid) == nil)
  }
  var address = NetworkAddress(value: "fe80::1%en0", family: .ipv6, prefix: 64, destination: nil)
  #expect(address.label == "IPv6 · link-local")
  #expect(address.formatted == "fe80::1%en0/64")
  address.value = "fd00::1"
  address.temporary = true
  #expect(address.label == "IPv6 · unique-local")
  #expect(address.formatted.hasSuffix("temporary"))
  address.notReady = true
  #expect(address.formatted.hasSuffix("not ready"))
}

@Test func configurationUsesBatchedServiceRoutesAndBoundsDNS() {
  let raw: [String: [String: Any]] = [
    "State:/Network/Global/IPv4": ["PrimaryInterface": "en0", "PrimaryService": "wifi"],
    "State:/Network/Global/IPv6": ["PrimaryInterface": "utun2", "PrimaryService": "vpn"],
    "State:/Network/Global/DNS": [
      "ServerAddresses": ["192.0.2.53", "192.0.2.53", "invalid", "2001:db8::53"]
    ],
    "State:/Network/Service/wifi/IPv4": ["InterfaceName": "en0", "Router": "192.0.2.1"],
    "State:/Network/Service/wifi/DNS": [
      "ServerAddresses": ["192.0.2.53", "192.0.2.2", "192.0.2.53"]
    ],
    "Setup:/Network/Service/wifi": ["UserDefinedName": "Wi-Fi"],
    "Setup:/Network/Service/wifi/Interface": ["DeviceName": "en0", "Hardware": "AirPort"],
    "State:/Network/Service/vpn/IPv6": ["InterfaceName": "utun2", "Router": "fe80::1%utun2"],
  ]
  let state = NetworkConfiguration.decode(raw)
  #expect(state.available)
  #expect(state.ipv4 == .init(interface: "en0", router: "192.0.2.1"))
  #expect(state.ipv6 == .init(interface: "utun2", router: "fe80::1%utun2"))
  #expect(state.dns == ["192.0.2.53", "2001:db8::53"])
  #expect(state.interfaces["en0"]?.name == "Wi-Fi")
  #expect(state.interfaces["en0"]?.hardware == "AirPort")
  #expect(state.interfaces["en0"]?.dns == ["192.0.2.53", "192.0.2.2"])
  let many = NetworkConfiguration.decode([
    "State:/Network/Global/DNS": ["ServerAddresses": (1...100).map { "192.0.2.\($0)" }]
  ])
  #expect(many.dns.count == 8)
}

@Test func autoRoutePrefersIPv4ThenAvailableIPv6WithoutSumming() {
  let state = NetworkConfiguration.decode([
    "State:/Network/Global/IPv4": ["PrimaryInterface": "en0"],
    "State:/Network/Global/IPv6": ["PrimaryInterface": "utun2"],
  ])
  #expect(
    state.preferredInterface(in: [interface("en0", index: 4), interface("utun2", index: 8)])
      == "en0")
  #expect(
    state.preferredInterface(in: [
      interface("en0", index: 4, up: false), interface("utun2", index: 8),
    ]) == "utun2")
  #expect(state.preferredInterface(in: [interface("utun2", index: 8)]) == "utun2")
  #expect(state.preferredInterface(in: [interface("other", index: 10)]) == nil)
  #expect(
    NetworkConfiguration.decode([:]).preferredInterface(in: [interface("en0", index: 4)]) == nil)
  #expect(!NetworkConfiguration().available)
}

@Test func networkDiscoveryCoalescesAndInvalidatesOnIdentityAndEvents() {
  var schedule = NetworkDiscoverySchedule()
  var readings = [interface("en0", index: 4)]
  func refresh(_ time: Double, changed: Bool = false) -> Bool {
    schedule.shouldRefresh(at: time, interfaces: readings, changed: changed)
  }
  #expect(refresh(0, changed: false))
  #expect(!refresh(2, changed: false))
  #expect(refresh(4, changed: true))
  #expect(!refresh(6, changed: false))
  #expect(refresh(34, changed: false))
  readings[0].index = 5
  #expect(refresh(36, changed: false))
  readings[0].up = false
  #expect(refresh(38, changed: false))
  #expect(!refresh(40, changed: false))
  schedule.reset()
  #expect(refresh(42, changed: false))
}

@Test func networkRuleHoldResetsWhenAnInterfaceIsReplaced() {
  var rule = AlertRule(metric: .interfaceState)
  rule.source = "en0"
  rule.hold = 10
  rule.threshold = 1
  rule.enabled = true
  var settings = Settings()
  settings.rules = [rule]
  var engine = AlertEngine()
  engine.configure(settings.rules)
  var snapshot = Snapshot()
  snapshot.interfaces = [interface("en0", index: 4)]
  #expect(engine.evaluate(snapshot, now: 0).isEmpty)
  snapshot.interfaces[0].index = 5
  #expect(engine.evaluate(snapshot, now: 9).isEmpty)
  #expect(engine.evaluate(snapshot, now: 10).isEmpty)
  #expect(engine.evaluate(snapshot, now: 19).count == 1)
}

@Test func networkReaderClearsFailedDiscoveryAndProtectsReplacementIdentity() {
  let address = NetworkAddress(value: "192.0.2.10", family: .ipv4, prefix: 24, destination: nil)
  let configuration = NetworkConfiguration.decode([
    "State:/Network/Global/IPv4": ["PrimaryInterface": "en0", "Router": "192.0.2.1"]
  ])
  var discovery = NetworkDiscovery(
    configuration: configuration,
    details: [
      "en0": .init(index: 4, addresses: [address])
    ])
  var attempts = 0
  var changed = false
  let reader = NetworkConfigurationReader(
    read: {
      attempts += 1
      return discovery
    }, changed: { changed })
  var readings = [interface("en0", index: 4)]
  func read(_ time: Double) -> NetworkConfiguration { reader.read(at: time, interfaces: &readings) }
  #expect(read(0).ipv4?.router == "192.0.2.1")
  #expect(readings[0].addresses == [address])
  #expect(readings[0].addressesAvailable)
  _ = read(2)
  #expect(attempts == 1)

  // A stale discovery result for the old interface must not attach to its replacement.
  readings[0].index = 5
  _ = read(4)
  #expect(attempts == 2)
  #expect(readings[0].addresses.isEmpty)
  #expect(!readings[0].addressesAvailable)
  #expect(readings[0].address.isEmpty)
  discovery = NetworkDiscovery()
  changed = true
  #expect(!read(6).available)
  #expect(readings[0].addresses.isEmpty)
  #expect(reader.sampledAt == 6)

  // A successful empty address list is distinct from a failed attempt.
  discovery = NetworkDiscovery(
    configuration: configuration, details: ["en0": .init(index: 5, addresses: [])])
  _ = read(8)
  #expect(readings[0].addressesAvailable)
  #expect(readings[0].addresses.isEmpty)
  discovery.details?["en0"]?.addresses = [address]
  changed = false
  reader.reset()
  #expect(read(10).available)
  #expect(readings[0].addresses == [address])
  #expect(attempts == 5)
}
