import AppKit
import TinyStatsCore

/// Two picture toggles: show the Power item on Power Adapter / on Battery. A small labelled
/// group (eye glyph) with eye / eye-slash marks, so it reads as two independent on/off switches
/// rather than another style choice. Never touches monitoring or the real menu bar.
@MainActor final class PowerVisibilityPicker: NSControl {
  static let tileHeight: CGFloat = 62
  static let headerHeight: CGFloat = 20
  /// Space under the group so it separates clearly (≥16pt with the stack gap) from the styles.
  static let bottomPadding: CGFloat = 10
  private(set) var tiles: [PowerVisibilityTile] = []
  private(set) var visibility = PowerItemVisibility()
  private(set) var hasBattery = true
  let caption = NSTextField(labelWithString: "")
  let header = NSTextField(labelWithString: "Show in menu bar")
  private let headerIcon = NSImageView()
  private var heightConstraint: NSLayoutConstraint!

  init(
    visibility: PowerItemVisibility, hasBattery: Bool,
    previews: [PowerSourceKind: MenuBarReadout] = [:]
  ) {
    super.init(frame: .zero)
    headerIcon.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
    headerIcon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
    headerIcon.contentTintColor = .secondaryLabelColor
    headerIcon.setAccessibilityElement(false)
    header.font = .systemFont(ofSize: 11, weight: .medium)
    header.textColor = .secondaryLabelColor
    header.setAccessibilityElement(false)
    addSubview(headerIcon)
    addSubview(header)
    tiles = PowerSourceKind.allCases.map { source in
      let tile = PowerVisibilityTile(source: source)
      tile.target = self
      tile.action = #selector(toggled(_:))
      addSubview(tile)
      return tile
    }
    caption.font = .systemFont(ofSize: 10)
    caption.textColor = .secondaryLabelColor
    addSubview(caption)
    heightConstraint = heightAnchor.constraint(equalToConstant: height(captioned: false))
    heightConstraint.isActive = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Show Power in the menu bar")
    update(visibility: visibility, hasBattery: hasBattery, previews: previews)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }

  private func height(captioned: Bool) -> CGFloat {
    Self.headerHeight + Self.tileHeight + (captioned ? 18 : 0) + Self.bottomPadding
  }

  func tile(_ source: PowerSourceKind) -> PowerVisibilityTile? {
    tiles.first { $0.source == source }
  }

  /// "Hidden" means on every source this Mac can be on; the module itself stays enabled.
  static func captionText(_ visibility: PowerItemVisibility, hasBattery: Bool) -> String? {
    let hiddenEverywhere = !visibility.onAdapter && (!visibility.onBattery || !hasBattery)
    return hiddenEverywhere ? "Hidden on every power source · Power stays enabled" : nil
  }

  /// `previews` are the chosen Power style per source, drawn in each tile's tiny menu bar.
  func update(
    visibility: PowerItemVisibility, hasBattery: Bool,
    previews: [PowerSourceKind: MenuBarReadout] = [:]
  ) {
    self.visibility = visibility
    self.hasBattery = hasBattery
    for tile in tiles {
      tile.state = visibility[tile.source] ? .on : .off
      tile.available = tile.source == .adapter || hasBattery
      if let preview = previews[tile.source] { tile.update(preview) }
      tile.needsDisplay = true
    }
    caption.stringValue = Self.captionText(visibility, hasBattery: hasBattery) ?? ""
    caption.isHidden = caption.stringValue.isEmpty
    let height = height(captioned: !caption.isHidden)
    if heightConstraint.constant != height { heightConstraint.constant = height }
    needsLayout = true
  }

  /// Each tile spans whole style-tile columns (same column maths as MenuBarStylePicker).
  static func tileWidth(for width: CGFloat) -> CGFloat {
    let columns = min(7, max(1, Int((width + 8) / 72)))
    let column = max(0, (width - CGFloat(columns - 1) * 8) / CGFloat(columns))
    let span = max(1, min(columns, Int(ceil((150 + 8) / (column + 8)))))
    let spanned = CGFloat(span) * column + CGFloat(span - 1) * 8
    return min(spanned, max(0, (width - 8) / 2))
  }

  override func layout() {
    super.layout()
    headerIcon.frame = .init(x: 1, y: 2, width: 14, height: 12)
    header.frame = .init(x: 19, y: 0, width: max(0, bounds.width - 19), height: 15)
    let width = Self.tileWidth(for: bounds.width)
    for (index, tile) in tiles.enumerated() {
      tile.frame = .init(
        x: CGFloat(index) * (width + 8), y: Self.headerHeight, width: width,
        height: Self.tileHeight)
    }
    caption.frame = .init(
      x: 2, y: Self.headerHeight + Self.tileHeight + 3, width: max(0, bounds.width - 4),
      height: 14)
  }

  @objc private func toggled(_ sender: PowerVisibilityTile) {
    guard sender.available else {
      sender.state = visibility[sender.source] ? .on : .off
      return
    }
    var value = visibility
    value[sender.source] = sender.state == .on
    update(visibility: value, hasBattery: hasBattery)
    if let action { NSApp.sendAction(action, to: target, from: self) }
  }
}

@MainActor final class PowerVisibilityTile: NSButton {
  let source: PowerSourceKind
  /// False on a Mac without an internal battery: shown dimmed with "No battery".
  var available = true {
    didSet {
      guard available != oldValue else { return }
      updateDescription()
      needsDisplay = true
    }
  }
  var increaseContrast: () -> Bool = {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  }
  override var state: NSControl.StateValue {
    didSet { if state != oldValue { updateDescription() } }
  }

  /// The chosen Power style, rendered by the production menu-bar renderer (never attached).
  let renderer = MenuBarReadoutView()
  private var cachedPreview: NSImage?

  init(source: PowerSourceKind) {
    self.source = source
    super.init(frame: .zero)
    title = ""
    isBordered = false
    setButtonType(.toggle)
    setAccessibilityRole(.checkBox)
    updateDescription()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }

  func update(_ readout: MenuBarReadout) {
    renderer.readouts = [readout]
    renderer.frame = .init(x: 0, y: 0, width: renderer.preferredWidth, height: 22)
    cachedPreview = nil
    needsDisplay = true
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    cachedPreview = nil
  }
  private func previewImage() -> NSImage? {
    if let cachedPreview { return cachedPreview }
    guard !renderer.readouts.isEmpty, renderer.bounds.width > 0 else { return nil }
    renderer.appearance = effectiveAppearance
    let scale = window?.backingScaleFactor ?? 2
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(ceil(renderer.bounds.width * scale)),
        pixelsHigh: Int(ceil(renderer.bounds.height * scale)), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    bitmap.size = renderer.bounds.size
    effectiveAppearance.performAsCurrentDrawingAppearance {
      renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
    }
    let image = NSImage(size: renderer.bounds.size)
    image.addRepresentation(bitmap)
    cachedPreview = image
    return image
  }

  var caption: String {
    available ? (source == .adapter ? "On Power Adapter" : "On Battery") : "No Battery"
  }

  private func updateDescription() {
    setAccessibilityLabel("Show Power on \(source.title)")
    toolTip =
      available
      ? "Show Power in the menu bar on \(source.title.lowercased()) · click to toggle"
      : "This Mac has no internal battery"
    setAccessibilityHelp(available ? nil : "This Mac has no internal battery")
  }
  override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
  override func isAccessibilityEnabled() -> Bool { available && isEnabled }
  override var acceptsFirstResponder: Bool { available && isEnabled }
  override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 7, yRadius: 7).fill()
  }

  private func symbol(
    _ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular,
    secondary: NSColor? = nil
  ) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
      .applying(.init(paletteColors: [color] + (secondary.map { [$0] } ?? [])))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  }

  /// Aspect-fit, upright in this flipped view.
  private func draw(_ image: NSImage?, in rect: NSRect) {
    guard let image, image.size.width > 0, image.size.height > 0 else { return }
    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(
      in: .init(
        x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
        height: size.height),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  override func draw(_ dirtyRect: NSRect) {
    let shown = state == .on
    let alpha: CGFloat = available ? 1 : 0.45
    // Neutral card in both states: the eye mark and the icon-or-gap carry the on/off meaning,
    // so it never borrows the style grid's accent selection look.
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
    NSColor.controlBackgroundColor.setFill()
    path.fill()
    let contrast =
      increaseContrast()
      || [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua].contains(
        effectiveAppearance.name)
    (contrast ? NSColor.secondaryLabelColor : .separatorColor).setStroke()
    path.lineWidth = contrast ? 1 : 0.5
    path.stroke()

    // Header: source glyph, short neutral caption, eye / eye-slash mark.
    draw(
      symbol(
        source.symbol, size: 10,
        color: SystemStyle.moduleAccent(.battery).withAlphaComponent(alpha), weight: .regular),
      in: .init(x: 10, y: 8, width: 17, height: 11))
    let text = NSAttributedString(
      string: caption,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
      ])
    text.draw(at: .init(x: 32, y: 6))
    if available {
      draw(
        shown
          ? symbol("eye.fill", size: 11, color: SystemStyle.accent, weight: .medium)
          : symbol(
            "eye.slash.fill", size: 11, color: .secondaryLabelColor, weight: .semibold,
            secondary: .secondaryLabelColor),
        in: .init(x: bounds.width - 27, y: 6, width: 18, height: 14))
    }

    // A tiny menu bar: neutral strip, two neutral item pills, the chosen Power icon or its gap.
    let strip = NSRect(x: 8, y: 30, width: bounds.width - 16, height: 22)
    NSColor.labelColor.withAlphaComponent(0.06 * alpha).setFill()
    NSBezierPath(roundedRect: strip, xRadius: 5, yRadius: 5).fill()
    NSColor.labelColor.withAlphaComponent(0.22 * alpha).setFill()
    for x in [strip.maxX - 54, strip.maxX - 30] {
      NSBezierPath(
        roundedRect: .init(x: x, y: strip.minY + 7, width: 20, height: 8), xRadius: 4, yRadius: 4
      ).fill()
    }
    // A Mac without a battery can never be on battery: no icon and no gap.
    guard available else { return }
    let image = previewImage()
    let width = min(max(26, image?.size.width ?? 26), max(26, strip.width - 72))
    let slot = NSRect(x: strip.maxX - 62 - width, y: strip.minY, width: width, height: strip.height)
    if shown {
      if let image {
        let size = NSSize(
          width: min(image.size.width, slot.width), height: min(image.size.height, slot.height))
        image.draw(
          in: .init(
            x: slot.minX, y: slot.midY - size.height / 2, width: size.width, height: size.height),
          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      } else {
        draw(
          symbol("battery.75percent", size: 13, color: SystemStyle.moduleAccent(.battery)),
          in: slot.insetBy(dx: 0, dy: 5))
      }
    } else {
      let gap = NSBezierPath(roundedRect: slot.insetBy(dx: 0, dy: 4), xRadius: 4, yRadius: 4)
      gap.lineWidth = 1
      gap.setLineDash([3, 2], count: 2, phase: 0)
      NSColor.tertiaryLabelColor.setStroke()
      gap.stroke()
    }
  }
}
