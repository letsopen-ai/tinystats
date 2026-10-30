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
@MainActor final class ProcessAppDisplayCache {
  struct Entry {
    var name: String
    var icon: NSImage
  }
  private var entries: [String: Entry] = [:]
  private var order: [String] = []
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

@MainActor final class ProcessAppLabelCell: NSView {
  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(icon)
    addSubview(name)
    icon.setAccessibilityElement(false)
    name.setAccessibilityElement(false)
    name.font = .systemFont(ofSize: 12)
    name.lineBreakMode = .byTruncatingTail
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(_ entry: ProcessAppDisplayCache.Entry, count: Int, path: String) {
    icon.image = entry.icon
    name.stringValue = "\(entry.name) · \(count) \(count == 1 ? "process" : "processes")"
    toolTip = name.stringValue + " · " + path
    setAccessibilityLabel(toolTip)
  }
  override func layout() {
    super.layout()
    icon.frame = .init(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
    name.frame = .init(
      x: 20, y: (bounds.height - 17) / 2, width: max(0, bounds.width - 20), height: 17)
  }
}
