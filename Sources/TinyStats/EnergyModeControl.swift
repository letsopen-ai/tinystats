import AppKit
import TinyStatsCore

/// Compact per-source Energy Mode rows for the Power dropdown. One native segmented control
/// per source; the current source's row is subtly emphasised. Reused across refreshes.
@MainActor final class EnergyModeControl: NSView {
  static let rowHeight: CGFloat = 28
  static let rowGap: CGFloat = 4
  static let footerHeight: CGFloat = 24

  var onSelect: ((PowerSourceKind, EnergyMode) -> Void)?
  var onOpenSettings: (() -> Void)?
  private(set) var presentation = EnergyModePresentation.hidden
  private(set) var segments: [PowerSourceKind: NSSegmentedControl] = [:]
  private var icons: [PowerSourceKind: NSImageView] = [:]
  private var labels: [PowerSourceKind: NSTextField] = [:]
  private var modes: [PowerSourceKind: [EnergyMode]] = [:]
  let message = NSTextField(labelWithString: "")
  private(set) lazy var fallback: NSButton = {
    let button = NSButton(
      title: "Settings…", target: self, action: #selector(openSettings))
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.font = .systemFont(ofSize: 11)
    button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.toolTip = "Open Energy Mode in System Settings"
    button.setAccessibilityLabel("Open Energy Mode settings")
    return button
  }()

  override init(frame: NSRect) {
    super.init(frame: frame)
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    message.lineBreakMode = .byTruncatingTail
    addSubview(message)
    addSubview(fallback)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Energy mode")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }

  /// Content height below the card header for a presentation.
  static func contentHeight(_ value: EnergyModePresentation) -> CGFloat {
    let rows = CGFloat(value.rows.count) * (rowHeight + rowGap)
    let footer = value.message != nil || value.showsFallback ? footerHeight : 0
    return max(0, rows + footer - (footer == 0 && rows > 0 ? rowGap : 0))
  }

  func update(_ value: EnergyModePresentation) {
    let structure = value.rows.map { "\($0.source.rawValue):\($0.modes.map(\.rawValue))" }
    let previous = presentation.rows.map { "\($0.source.rawValue):\($0.modes.map(\.rawValue))" }
    presentation = value
    if structure != previous { rebuildRows() }
    for row in value.rows {
      guard let control = segments[row.source] else { continue }
      let index = row.selected.flatMap { modes[row.source]?.firstIndex(of: $0) } ?? -1
      if control.selectedSegment != index { control.selectedSegment = index }
      control.isEnabled = !value.busy
      labels[row.source]?.textColor = row.isCurrentSource ? .labelColor : .secondaryLabelColor
      labels[row.source]?.font = .systemFont(
        ofSize: 12, weight: row.isCurrentSource ? .medium : .regular)
      icons[row.source]?.contentTintColor =
        SystemStyle.moduleAccent(.battery).withAlphaComponent(row.isCurrentSource ? 1 : 0.6)
      let current = row.isCurrentSource ? ", current power source" : ""
      control.setAccessibilityLabel("\(row.source.title) energy mode\(current)")
      icons[row.source]?.toolTip = row.isCurrentSource ? "Now on \(row.source.title)" : nil
    }
    message.stringValue = value.message ?? ""
    message.isHidden = value.message == nil
    fallback.isHidden = !value.showsFallback
    needsLayout = true
    needsDisplay = true
  }

  private func rebuildRows() {
    for view in Array(segments.values) as [NSView] + Array(icons.values) + Array(labels.values) {
      view.removeFromSuperview()
    }
    segments = [:]
    icons = [:]
    labels = [:]
    modes = [:]
    for row in presentation.rows {
      let icon = NSImageView(
        image: NSImage(systemSymbolName: row.source.symbol, accessibilityDescription: nil)
          ?? NSImage())
      icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
      icon.setAccessibilityElement(false)
      let label = NSTextField(labelWithString: row.source.title)
      label.font = .systemFont(ofSize: 12)
      label.setAccessibilityElement(false)
      let control = NSSegmentedControl()
      control.segmentCount = row.modes.count
      control.trackingMode = .selectOne
      control.controlSize = .small
      // Keep the chosen mode in the system accent even when glass or an inactive window
      // would otherwise draw the selected segment grey on grey.
      control.selectedSegmentBezelColor = .controlAccentColor
      for (index, mode) in row.modes.enumerated() {
        control.setImage(
          NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title),
          forSegment: index)
        control.setWidth(34, forSegment: index)
        control.setToolTip("\(mode.title) on \(row.source.title)", forSegment: index)
      }
      control.target = self
      control.action = #selector(segmentChanged(_:))
      control.identifier = NSUserInterfaceItemIdentifier("energy-mode-\(row.source.rawValue)")
      for view in [icon, label, control] as [NSView] { addSubview(view) }
      segments[row.source] = control
      icons[row.source] = icon
      labels[row.source] = label
      modes[row.source] = row.modes
    }
  }

  /// Horizontal inset of row content inside the row highlight; with the control placed
  /// `inset` inside the card edge, glyphs and segments align with the card title and trailing text.
  static let inset: CGFloat = 6

  override func layout() {
    super.layout()
    let inset = Self.inset
    for (index, row) in presentation.rows.enumerated() {
      let y = CGFloat(index) * (Self.rowHeight + Self.rowGap)
      guard let control = segments[row.source] else { continue }
      let size = control.intrinsicContentSize
      control.frame = .init(
        x: bounds.width - size.width - inset, y: y + (Self.rowHeight - size.height) / 2,
        width: size.width, height: size.height)
      icons[row.source]?.frame = .init(x: inset, y: y + 5, width: 20, height: 18)
      labels[row.source]?.frame = .init(
        x: inset + 26, y: y + 6, width: max(0, control.frame.minX - inset - 32), height: 16)
    }
    let footerY = CGFloat(presentation.rows.count) * (Self.rowHeight + Self.rowGap)
    let buttonSize = fallback.isHidden ? .zero : fallback.intrinsicContentSize
    fallback.frame = .init(
      x: bounds.width - buttonSize.width - inset, y: footerY + 1, width: buttonSize.width,
      height: buttonSize.height)
    message.frame = .init(
      x: inset, y: footerY + 4,
      width: max(0, (fallback.isHidden ? bounds.width : fallback.frame.minX) - 16), height: 16)
  }

  override func draw(_ dirtyRect: NSRect) {
    for (index, row) in presentation.rows.enumerated() where row.isCurrentSource {
      let y = CGFloat(index) * (Self.rowHeight + Self.rowGap)
      let rect = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
      // Neutral, so it never muddies the candy glyph in dark mode.
      NSColor.labelColor.withAlphaComponent(0.07).setFill()
      NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
  }

  override func accessibilityChildren() -> [Any]? {
    presentation.rows.compactMap { segments[$0.source] }
      + (message.isHidden ? [] : [message]) + (fallback.isHidden ? [] : [fallback])
  }

  @objc private func segmentChanged(_ sender: NSSegmentedControl) {
    guard let source = segments.first(where: { $0.value === sender })?.key,
      let choices = modes[source], choices.indices.contains(sender.selectedSegment)
    else { return }
    onSelect?(source, choices[sender.selectedSegment])
  }

  @objc private func openSettings() { onOpenSettings?() }
}
