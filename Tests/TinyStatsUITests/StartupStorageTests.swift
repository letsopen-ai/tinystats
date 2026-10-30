import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func verifyStartupStorage(
  _ volumes: [VolumeReading], expected: Double?, free: String
) throws {
  var snapshot = Snapshot()
  snapshot.volumes = volumes
  var settings = Settings()
  settings.styles[Module.disks.rawValue] = .historyValue
  let point = snapshot.historyPoint
  let readout = MenuBarReadout.make(
    module: .disks, snapshot: snapshot, settings: settings, history: [point])
  #expect(readout.progress == expected && readout.value == Display.percent(expected))
  #expect(readout.values == [expected] && point.diskUsed == expected)
  let overview = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  overview.update(snapshot, history: [point], settings: settings, module: .overview)
  let card = try #require(
    overview.cards.first {
      if case .overviewTile(let tile) = $0.content { return tile.symbol == "internaldrive" }
      return false
    })
  guard case .overviewTile(let storage) = card.content else {
    Issue.record("Missing overview capacity")
    return
  }
  #expect(
    storage.value.value == snapshot.startupVolume.map { Display.bytes(min($0.available, $0.total)) }
      ?? "—")
  #expect(storage.segments?.first?.fraction == expected.map { $0 / 100 })
  #expect(
    storage.composition == expected.map { Display.percent($0) + " used" }
      ?? "Storage capacity unavailable")
  #expect(
    storage.value.detail == snapshot.startupVolume.map { "available of " + Display.bytes($0.total) }
      ?? "Volume unavailable")
  let disks = SummaryDashboardView(frame: .init(x: 0, y: 0, width: 520, height: 454))
  disks.update(snapshot, history: [point], settings: settings, module: .disks)
  guard case .tiles(let capacity, _) = disks.cards.first?.content else {
    Issue.record("Missing disk capacity tiles")
    return
  }
  #expect(capacity.count == (volumes.contains { $0.path != "/" } ? 2 : 1))
  #expect(capacity.first?.fraction == expected.map { $0 / 100 })
  #expect(capacity.first?.label == (expected == nil ? "Startup" : "Example startup · Startup"))
  #expect(capacity.first?.value == (expected == nil ? "—" : free))
  if expected == nil { #expect(capacity.first?.detail == "Volume unavailable") }
  if let directory = ProcessInfo.processInfo.environment["TINYSTATS_STORAGE_FIXTURE_CAPTURES"],
    volumes.first?.path != "/"
  {
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (suffix, dashboard) in [("", overview), ("-disks", disks)] {
      for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let wrapper = NSView(frame: .init(x: 0, y: 0, width: 520, height: 486))
        wrapper.appearance = NSAppearance(named: appearance)
        dashboard.frame.origin = .zero
        wrapper.addSubview(dashboard)
        let caption = NSTextField(
          labelWithString: "TEST FIXTURE · "
            + (expected == nil
              ? "Root unavailable; external present" : "External enumerated before root"))
        caption.textColor = .systemBlue
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.frame = .init(x: 12, y: 460, width: 496, height: 20)
        wrapper.addSubview(caption)
        let bitmap = try #require(wrapper.bitmapImageRepForCachingDisplay(in: wrapper.bounds))
        wrapper.appearance?.performAsCurrentDrawingAppearance {
          wrapper.cacheDisplay(in: wrapper.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let state = expected == nil ? "missing" : "external-first"
        try png.write(to: folder.appendingPathComponent(state + suffix + "-" + name + ".png"))
      }
    }
  }
  let detail = DetailController()
  detail.selected = .disks
  detail.showsAllReadings = true
  detail.update(snapshot, history: [point])
  let header = try #require(
    detail.view.subviews.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 30 })
  #expect(header.stringValue == free)
  let table = try #require(
    detail.view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
  let labels = (0..<table.numberOfRows).compactMap { row in
    (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
  }
  for volume in volumes { #expect(labels.contains(volume.name)) }
}

@Test @MainActor func startupStorageLiveValuesMatchHistoryWithReorderedMounts() throws {
  _ = NSApplication.shared
  let external = VolumeReading(
    name: "Example external", path: "/Volumes/Example", total: 1000, available: 900)
  let startup = VolumeReading(name: "Example startup", path: "/", total: 100, available: 50)
  let another = VolumeReading(
    name: "Another external", path: "/Volumes/Another", total: 1000, available: 200)
  try verifyStartupStorage([external, another, startup], expected: 50, free: "50 B free")
  try verifyStartupStorage([external, startup], expected: 50, free: "50 B free")
  try verifyStartupStorage([startup, external], expected: 50, free: "50 B free")
  try verifyStartupStorage([startup], expected: 50, free: "50 B free")
}

@Test @MainActor func missingOrZeroCapacityStartupDoesNotSubstituteAnExternalDisk() throws {
  let external = VolumeReading(
    name: "Example external", path: "/Volumes/Example", total: 1000, available: 900)
  try verifyStartupStorage([], expected: nil, free: "Startup volume unavailable")
  try verifyStartupStorage([external], expected: nil, free: "Startup volume unavailable")
  let invalid = VolumeReading(name: "Unavailable startup", path: "/", total: 0, available: 0)
  try verifyStartupStorage([invalid, external], expected: nil, free: "Startup volume unavailable")
}
