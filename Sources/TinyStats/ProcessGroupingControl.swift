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
  static var placeholder: NSImage {
    let image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    return image.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? image
  }
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
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 3
    icon.layer?.borderWidth = 0.5
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
    updateIconRim()
    name.stringValue = entry.name
    countLabel.stringValue = String(count)
    let countText = "\(count) \(count == 1 ? "process" : "processes")"
    countLabel.toolTip = countText
    toolTip =
      ([entry.name + " · " + countText, path, path == nil ? provenance : nil].compactMap { $0 })
      .joined(separator: " · ")
    setAccessibilityLabel(toolTip)
  }
  private func updateIconRim() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      icon.layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }
  override func systemStyleDidChange() {
    super.systemStyleDidChange()
    updateIconRim()
  }
  override func layout() {
    super.layout()
    icon.frame = .init(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
    name.frame = .init(
      x: 20, y: (bounds.height - 17) / 2, width: max(0, bounds.width - 45), height: 17)
    countLabel.frame = .init(
      x: max(20, bounds.width - 22), y: (bounds.height - 17) / 2, width: 22, height: 17)
  }
}
