import AppKit
import TinyStatsCore

/// Welcome-only composition; examples stay separate from monitoring and saved choices.
@MainActor enum WelcomeGraphic {
  static func label(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    return label
  }
  static func glyph(_ symbol: String, module: Module? = nil, size: CGFloat = 32) -> NSImageView {
    let image = NSImageView()
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    image.contentTintColor = module.map(SystemStyle.moduleAccent) ?? .secondaryLabelColor
    image.imageScaling = .scaleProportionallyUpOrDown
    image.setAccessibilityElement(false)
    image.widthAnchor.constraint(equalToConstant: size + 4).isActive = true
    image.heightAnchor.constraint(equalToConstant: size + 4).isActive = true
    return image
  }
}

@MainActor final class WelcomeBackgroundView: SystemStyledView {
  private let surface: GlassSurface
  private let environment: () -> GlassSurface.Environment
  init(frame: NSRect, environment: @escaping () -> GlassSurface.Environment) {
    self.environment = environment
    surface = GlassSurface(environment: environment)
    super.init(frame: frame)
    surface.frame = bounds
    surface.autoresizingMask = [.width, .height]
    addSubview(surface)
    surface.onTreatmentChange = { [weak self] in self?.systemStyleDidChange() }
    systemStyleDidChange()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func systemStyleDidChange() {
    super.systemStyleDidChange()
    let glass = environment().treatment == .glass
    window?.isOpaque = !glass
    window?.backgroundColor = glass ? .clear : .windowBackgroundColor
    surface.isHidden = environment().treatment == .legacy
    func invalidate(_ view: NSView) {
      view.needsDisplay = true
      if let label = view as? NSTextField,
        label.textColor == .secondaryLabelColor
          || label.textColor == SystemStyle.glassSecondaryLabel
      {
        label.textColor =
          environment().treatment == .glass ? SystemStyle.glassSecondaryLabel : .secondaryLabelColor
      }
      for child in view.subviews { invalidate(child) }
    }
    for child in subviews { invalidate(child) }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    systemStyleDidChange()
  }
  override func draw(_ dirtyRect: NSRect) {
    if environment().treatment != .glass {
      NSColor.windowBackgroundColor.setFill()
      dirtyRect.fill()
    }
  }
}

/// Neutral native platter with a module identity glyph, short title and single-line captions.
@MainActor final class WelcomeTileView: NSStackView {
  let environment: () -> GlassSurface.Environment
  init(
    title: String, caption: String, symbol: String, module: Module? = nil,
    large: Bool = false, compact: Bool = false,
    environment: @escaping () -> GlassSurface.Environment
  ) {
    self.environment = environment
    super.init(frame: .zero)
    orientation = large ? .vertical : .horizontal
    alignment = large ? .leading : .centerY
    spacing = large ? 12 : 14
    edgeInsets = .init(top: compact ? 10 : 14, left: 18, bottom: compact ? 10 : 14, right: 18)
    addArrangedSubview(
      WelcomeGraphic.glyph(symbol, module: module, size: large ? 48 : compact ? 24 : 32))
    let titleLabel = WelcomeGraphic.label(title, size: large ? 17 : 13)
    titleLabel.font = .systemFont(ofSize: large ? 17 : 13, weight: .semibold)
    let copy = NSStackView(views: [
      titleLabel, WelcomeGraphic.label(caption, size: 11, secondary: true),
    ])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 5
    addArrangedSubview(copy)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(title)
    setAccessibilityHelp(caption)
    identifier = .init("welcome-tile")
    heightAnchor.constraint(greaterThanOrEqualToConstant: large ? 120 : compact ? 60 : 76)
      .isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    SystemStyle.drawPlatter(bounds, onGlass: true, environment: environment())
  }
}

/// Noninteractive keycap decoration; the text remains available to accessibility.
@MainActor final class WelcomeKeycapView: NSView {
  private let label: NSTextField
  private let environment: () -> GlassSurface.Environment
  init(_ key: String, environment: @escaping () -> GlassSurface.Environment) {
    self.environment = environment
    label = WelcomeGraphic.label(key, size: 11)
    super.init(frame: .zero)
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      widthAnchor.constraint(equalToConstant: label.intrinsicContentSize.width + 12),
      heightAnchor.constraint(equalToConstant: 20),
    ])
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    SystemStyle.cardFill(onGlass: true, environment: environment()).setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 0.5
    path.stroke()
  }
}

/// A neutral section keeps related controls and their preview in one composition.
@MainActor final class WelcomeSectionView: NSStackView {
  private let environment: () -> GlassSurface.Environment
  init(label: String, environment: @escaping () -> GlassSurface.Environment) {
    self.environment = environment
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 6
    edgeInsets = .init(top: 10, left: 12, bottom: 10, right: 12)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(label)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    SystemStyle.drawPlatter(bounds, onGlass: true, environment: environment())
  }
}

/// Native toggle semantics, a candy module glyph and an explicit checkmark, independent of colour.
@MainActor final class WelcomeReadoutButton: NSButton {
  let module: Module
  override var isFlipped: Bool { false }
  private let environment: () -> GlassSurface.Environment
  init(
    module: Module, target: AnyObject, action: Selector,
    environment: @escaping () -> GlassSurface.Environment = { .current }
  ) {
    self.module = module
    self.environment = environment
    super.init(frame: .zero)
    title = module.title
    self.target = target
    self.action = action
    setButtonType(.toggle)
    isBordered = false
    setAccessibilityRole(.checkBox)
    setAccessibilityLabel("Show \(module.title) in menu bar")
    heightAnchor.constraint(equalToConstant: 38).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var acceptsFirstResponder: Bool { isEnabled }
  override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 7, yRadius: 7).fill()
  }
  override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 1, dy: 1)
    let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
    let opacity: CGFloat = isEnabled ? 1 : 0.45
    SystemStyle.cardFill(onGlass: true, environment: environment()).setFill()
    path.fill()
    if state == .on || (isEnabled && isHighlighted) {
      NSColor.controlAccentColor.withAlphaComponent(isHighlighted && isEnabled ? 0.22 : 0.10)
        .setFill()
      path.fill()
    }
    let rim = state == .on ? NSColor.controlAccentColor : .separatorColor
    rim.withAlphaComponent(rim.alphaComponent * opacity).setStroke()
    path.lineWidth = state == .on ? 2 : 1
    path.stroke()
    let glyph = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
          .applying(.init(paletteColors: [SystemStyle.moduleAccent(module)])))
    glyph?.draw(
      in: .init(x: 10, y: (bounds.height - 20) / 2, width: 20, height: 20),
      from: .zero, operation: .sourceOver, fraction: opacity)
    (title as NSString).draw(
      at: .init(x: 36, y: (bounds.height - 15) / 2),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.labelColor.withAlphaComponent(opacity),
      ])
    if state == .on {
      NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))?
        .draw(
          in: .init(x: bounds.width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12),
          from: .zero, operation: .sourceOver, fraction: opacity)
    }
  }
}

/// An example menu bar above three evenly spaced identities; no implied data-flow connectors.
@MainActor final class WelcomeHeroView: SystemStyledView {
  let preview = MenuBarPreviewView()
  private let environment: () -> GlassSurface.Environment
  init(environment: @escaping () -> GlassSurface.Environment) {
    self.environment = environment
    super.init(frame: .zero)
    identifier = .init("welcome-hero")
    heightAnchor.constraint(equalToConstant: 250).isActive = true
    var settings = Settings()
    settings.readouts = [.cpu, .memory, .network]
    preview.update(
      groups: settings.readouts.map {
        [
          MenuBarStyleExample.readout(
            module: $0, style: settings.style(for: $0), settings: settings)
        ]
      }, paused: false, height: 24)
    preview.setAccessibilityLabel(
      "Example menu bar: CPU 42%, Memory 68%, Network upload 128 KB/s, download 2.4 MB/s")
    addSubview(preview)
    let nodes = settings.readouts.map { module in
      let stack = NSStackView(views: [
        WelcomeGraphic.glyph(module.symbol, module: module, size: 44),
        WelcomeGraphic.label(module.title, size: 13),
      ])
      stack.orientation = .vertical
      stack.spacing = 12
      stack.alignment = .centerX
      stack.identifier = .init(module.rawValue)
      return stack
    }
    let row = NSStackView(views: nodes)
    row.distribution = .fillEqually
    row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    let caption = WelcomeGraphic.label(
      "Example menu bar · Illustrative readings", size: 11, secondary: true)
    caption.translatesAutoresizingMaskIntoConstraints = false
    addSubview(caption)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -62),
      row.heightAnchor.constraint(equalToConstant: 86),
      caption.centerXAnchor.constraint(equalTo: centerXAnchor),
      caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    preview.frame = .init(
      x: bounds.width - preview.preferredWidth - 28, y: 198,
      width: preview.preferredWidth, height: 36)
  }
  override func draw(_ dirtyRect: NSRect) {
    SystemStyle.drawPlatter(bounds, onGlass: true, environment: environment())
    NSColor.labelColor.withAlphaComponent(0.05).setFill()
    NSBezierPath(
      roundedRect: .init(x: 12, y: 194, width: bounds.width - 24, height: 44),
      xRadius: 7, yRadius: 7
    ).fill()
    // The documented UI-native alternate wordmark: regular grey tiny, bold Stats.
    let regular = NSFont.systemFont(ofSize: 13, weight: .regular)
    let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
    let tiny = NSAttributedString(
      string: "tiny",
      attributes: [
        .font: NSFont(
          descriptor: regular.fontDescriptor.withDesign(.rounded) ?? regular.fontDescriptor,
          size: 13) ?? regular,
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
    tiny.draw(at: .init(x: 28, y: 208))
    ("Stats" as NSString).draw(
      at: .init(x: 28 + tiny.size().width, y: 208),
      withAttributes: [
        .font: NSFont(
          descriptor: bold.fontDescriptor.withDesign(.rounded) ?? bold.fontDescriptor, size: 13)
          ?? bold,
        .foregroundColor: NSColor.labelColor,
      ])
  }
}
