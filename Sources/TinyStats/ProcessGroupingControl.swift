import AppKit
import TinyStatsCore

/// One native control moves with the process section in summary and readings views.
@MainActor final class ProcessGroupingControl: NSSegmentedControl {
  init(target: AnyObject, action: Selector) {
    super.init(frame: .zero)
    segmentCount = 2
    setLabel("Processes", forSegment: 0)
    setLabel("Apps", forSegment: 1)
    setWidth(74, forSegment: 0)
    setWidth(44, forSegment: 1)
    trackingMode = .selectOne
    controlSize = .small
    font = .systemFont(ofSize: 11, weight: .regular)
    self.target = target
    self.action = action
    setAccessibilityLabel("Process list grouping")
    toolTip = "Group by outermost app bundle. Shared services and unresolved paths stay separate."
  }
  override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
  override var canBecomeKeyView: Bool { acceptsFirstResponder }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  static let width: CGFloat = 122
}

/// Main-actor display metadata only, requested by rows that are actually drawn/realized.
/// Fixed FIFO bound also caches failures. Never consulted by the worker or hidden lists.
/// Accepted first-paint main-actor Bundle/NSWorkspace lookup, keyed by path for this
/// presentation lifetime. Updates at the same path become visible on eviction or reopen.
/// Avoid per-paint filesystem stats and asynchronous icon work with a second lifetime.
@MainActor final class ProcessAppDisplayCache {
  struct Entry {
    var name: String
    var icon: NSImage
  }
  private var entries: [String: Entry] = [:]
  private var order: [String] = []
  static let placeholder: NSImage = {
    let image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    return image.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? image
  }()
  static let capacity = 32
  func entry(path: String, fallback: String) -> Entry {
    if let entry = entries[path] { return entry }
    let bundle = Bundle(path: path)
    let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
    let entry = Entry(
      name: [displayName, name].compactMap { $0 }.first { !$0.isEmpty } ?? fallback,
      icon: NSWorkspace.shared.icon(forFile: path))
    if order.count == Self.capacity { entries.removeValue(forKey: order.removeFirst()) }
    entries[path] = entry
    order.append(path)
    return entry
  }
}

@MainActor final class ProcessAppLabelCell: SystemStyledView {
  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private let countLabel = NSTextField(labelWithString: "")
  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(icon)
    addSubview(name)
    addSubview(countLabel)
    countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    countLabel.textColor = .labelColor
    countLabel.alignment = .right
    countLabel.setAccessibilityElement(false)
    icon.setAccessibilityElement(false)
    name.setAccessibilityElement(false)
    name.font = .systemFont(ofSize: 12)
    name.lineBreakMode = .byTruncatingTail
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(_ entry: ProcessAppDisplayCache.Entry, count: Int, path: String?, provenance: String)
  {
    icon.image = entry.icon
    name.stringValue = entry.name
    countLabel.stringValue = String(count)
    let countText = "\(count) \(count == 1 ? "process" : "processes")"
    countLabel.toolTip = countText
    toolTip =
      ([entry.name + " · " + countText, path, path == nil ? provenance : nil].compactMap { $0 })
      .joined(separator: " · ")
    setAccessibilityLabel(toolTip)
  }
  static let countWidth: CGFloat = 30
  override func layout() {
    super.layout()
    icon.frame = .init(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
    name.frame = .init(
      x: 20, y: (bounds.height - 17) / 2, width: max(0, bounds.width - 20 - Self.countWidth - 3),
      height: 17)
    countLabel.frame = .init(
      x: max(20, bounds.width - Self.countWidth), y: (bounds.height - 17) / 2,
      width: Self.countWidth, height: 17)
  }
}

/// A measured subset is a lower bound; unavailable totals never receive a numeric cue.
extension ProcessAppReading {
  var cpuDisplayValue: String {
    (cpu.map { $0.isFinite && $0 >= 0 } == true && cpuIncomplete > 0 ? "≥" : "")
      + Display.processPercent(cpu)
  }
  var cpuMeasurementHelp: String? {
    guard cpuIncomplete > 0 else { return nil }
    return "Sum of measured members · \(cpuIncomplete) unmeasured processes"
  }
}
