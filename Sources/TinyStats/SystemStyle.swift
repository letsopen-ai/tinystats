import AppKit
import TinyStatsCore

/// Direction 2 · System. Colour is resolved at drawing time, including non-blue accents.
enum SystemStyle {
  enum Radius {
    static let platter: CGFloat = 12
    static let group: CGFloat = 10
    static let control: CGFloat = 7
  }
  enum Space {
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8
    static let popoverInset: CGFloat = 10
    static let row: CGFloat = 36
    static let action: CGFloat = 28
    static let actionBar: CGFloat = 34
  }
  enum TypeSize {
    static let value: CGFloat = 30
    static let heading: CGFloat = 13
    static let body: CGFloat = 13
    static let caption: CGFloat = 11
  }
  static let popoverSize = NSSize(width: 344, height: 640)
  static let accent = NSColor(name: nil) { appearance in
    resolvedPalette(in: appearance).primary
  }
  static let secondaryAccent = NSColor(name: nil) { appearance in
    resolvedPalette(in: appearance).secondary
  }
  /// The sole exception to semantic/system colours: owner-requested module identity graphics.
  /// Opaque sRGB pairs resolve per drawing appearance; text and state colours stay semantic.
  struct ModulePalette {
    let light: UInt32, dark: UInt32, lightSecondary: UInt32, darkSecondary: UInt32
    let primary: NSColor, secondary: NSColor
    init(
      _ name: String, _ light: UInt32, _ dark: UInt32, _ lightSecondary: UInt32,
      _ darkSecondary: UInt32
    ) {
      self.light = light
      self.dark = dark
      self.lightSecondary = lightSecondary
      self.darkSecondary = darkSecondary
      primary = NSColor(name: NSColor.Name("TinyStats.\(name).primary")) { appearance in
        SystemStyle.sRGB(isDark(appearance) ? dark : light)
      }
      secondary = NSColor(name: NSColor.Name("TinyStats.\(name).secondary")) { appearance in
        SystemStyle.sRGB(isDark(appearance) ? darkSecondary : lightSecondary)
      }
    }
  }
  static let modulePalettes: [Module: ModulePalette] = [
    .cpu: .init("CPU", 0xEF2F8E, 0xFF84CE, 0x0A88D1, 0x85F8E9),
    .memory: .init("Memory", 0xA65CF4, 0xB8A0FF, 0xC55F00, 0xFFF29A),
    .network: .init("Network", 0x00946F, 0x4CF5B0, 0x9B66E8, 0xA891FF),
    .disks: .init("Disk", 0xB87000, 0xFFE93D, 0x9450DF, 0xB0A0FF),
    .sensors: .init("Sensors", 0xDD5545, 0xFFC266, 0x6455F4, 0xA58CFF),
    .battery: .init("Power", 0x549200, 0xBDFA35, 0xA960E4, 0xAD99FF),
    .gpu: .init("GPU", 0x0079FF, 0x65CCFF, 0xBC5700, 0xFFF29A),
    .clock: .init("Time", 0xCF40DF, 0xF5A1FF, 0xC55F00, 0xFFF59A),
    .weather: .init("Weather", 0x008CBA, 0x50EFFF, 0x8340F5, 0xA891FF),
  ]
  static func moduleAccent(_ module: Module) -> NSColor {
    modulePalettes[module]?.primary ?? .labelColor
  }
  static func moduleSecondary(_ module: Module) -> NSColor {
    modulePalettes[module]?.secondary ?? neutralSeries
  }
  private static func sRGB(_ hex: UInt32) -> NSColor {
    NSColor(
      srgbRed: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
  }
  /// Measured module colours keep their vivid ink; unmeasured system/custom colours retain
  /// the conservative light-glass brightness cap.
  static func chartTraceColor(_ color: NSColor, role: ChartSeriesRole, glass: Bool) -> NSColor {
    guard glass, role == .secondary else { return color }
    if modulePalettes.values.contains(where: { $0.primary == color || $0.secondary == color }) {
      return color
    }
    return NSColor(name: nil) { appearance in
      guard !isDark(appearance) else { return color }
      var resolved: NSColor = color
      appearance.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
      }
      guard let rgb = resolved.usingColorSpace(.sRGB) else { return color }
      let factor = min(1, 0.60 / max(0.001, rgb.brightnessComponent))
      return NSColor(
        srgbRed: rgb.redComponent * factor, green: rgb.greenComponent * factor,
        blue: rgb.blueComponent * factor, alpha: rgb.alphaComponent)
    }
  }
  static let neutralSeries = NSColor(name: nil) { appearance in
    (isDark(appearance) ? NSColor.white : NSColor.black).withAlphaComponent(0.55)
  }
  static let availableSeries = NSColor(name: nil) { appearance in
    (isDark(appearance) ? NSColor.white : NSColor.black).withAlphaComponent(0.12)
  }
  static let platterFill = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor.white.withAlphaComponent(0.08)
      : NSColor.controlBackgroundColor.withAlphaComponent(0.62)
  }
  static let nominal = NSColor.systemGreen
  static let warning = NSColor.systemOrange
  static let critical = NSColor.systemRed

  static func isDark(_ appearance: NSAppearance) -> Bool {
    let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
    return match == .darkAqua || match == .vibrantDark
  }
  static func resolvedAccent(in appearance: NSAppearance) -> NSColor {
    var result = NSColor.controlAccentColor
    appearance.performAsCurrentDrawingAppearance {
      result = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
    }
    return result
  }
  static func resolvedPalette(in appearance: NSAppearance) -> (primary: NSColor, secondary: NSColor)
  {
    let raw = resolvedAccent(in: appearance)
    let pair = paletteCache.resolve(
      .init(Double(raw.redComponent), Double(raw.greenComponent), Double(raw.blueComponent)),
      dark: isDark(appearance))
    func color(_ rgb: AccentPalette.RGB) -> NSColor {
      NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
    return (color(pair.primary), color(pair.secondary))
  }
  // Dynamic NSColor providers can resolve off-main. Four entries cover mixed light/dark accents without
  // retaining appearance objects; the pure derivation stays independent of this drawing cache.
  private static let paletteCache = PaletteCache()
  private final class PaletteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(AccentPalette.RGB, Bool, AccentPalette.Pair)] = []
    func resolve(_ rgb: AccentPalette.RGB, dark: Bool) -> AccentPalette.Pair {
      lock.withLock {
        if let entry = entries.first(where: { $0.0 == rgb && $0.1 == dark }) { return entry.2 }
        let pair = AccentPalette.derive(from: rgb, dark: dark)
        if entries.count == 4 { entries.removeFirst() }
        entries.append((rgb, dark, pair))
        return pair
      }
    }
  }
  /// Preserve the user's hue; lift dark-bar graphics slightly like the approved board.
  static func menuBarAccent(_ accent: NSColor, dark: Bool) -> NSColor {
    dark ? accent.blended(withFraction: 0.18, of: .white) ?? accent : accent
  }
  static func core(_ kind: CPUCoreKind) -> NSColor {
    switch kind {
    case .efficiency: moduleSecondary(.cpu)
    case .performance: moduleAccent(.cpu)
    case .unknown: .secondaryLabelColor
    }
  }
  @MainActor static func cardFill(onGlass: Bool, environment: GlassSurface.Environment) -> NSColor {
    if environment.treatment == .solid { return .controlBackgroundColor }
    guard onGlass && environment.treatment == .glass else { return platterFill }
    return glassCardFill
  }
  private static let glassCardFill = NSColor(name: nil) { appearance in
    let dark = isDark(appearance)
    return (dark ? NSColor.windowBackgroundColor : .labelColor)
      .withAlphaComponent(GlassSurface.cardTintOpacity(dark: dark))
  }
  static let glassSecondaryLabel = NSColor(name: nil) { _ in
    NSColor.labelColor.withAlphaComponent(GlassSurface.secondaryInkOpacity)
  }
  @MainActor static func drawPlatter(
    _ rect: NSRect, onGlass: Bool = false, environment: GlassSurface.Environment = .current
  ) {
    let path = NSBezierPath(
      roundedRect: rect.insetBy(dx: 0.25, dy: 0.25),
      xRadius: Radius.platter, yRadius: Radius.platter)
    let solid = environment.treatment == .solid
    cardFill(onGlass: onGlass, environment: environment).setFill()
    path.fill()
    NSColor.separatorColor.withAlphaComponent(solid ? 1 : 0.35).setStroke()
    path.lineWidth = 0.5
    path.stroke()
  }
  /// Keep acronyms and units intact while removing legacy all-caps section styling.
  static func sectionTitle(_ title: String) -> String {
    let acronyms: Set<String> = [
      "CPU", "GPU", "SMC", "RAM", "SMART", "TCP/UDP", "AC", "I/O", "MET", "CC", "BY",
    ]
    return title.split(separator: " ", omittingEmptySubsequences: false).enumerated().map {
      index, word in
      let value = String(word)
      if value == "NORWAY" { return "Norway" }
      if acronyms.contains(value) || value != value.uppercased() { return value }
      return index == 0
        ? value.lowercased().prefix(1).uppercased() + value.lowercased().dropFirst()
        : value.lowercased()
    }.joined(separator: " ")
  }
}

/// Selector observation is weak; no timer, owning callback or retained notification token.
@MainActor class SystemStyledView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    NotificationCenter.default.addObserver(
      self, selector: #selector(systemColorsChanged),
      name: NSColor.systemColorsDidChangeNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(systemColorsChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit {
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }
  @objc private func systemColorsChanged() { systemStyleDidChange() }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    systemStyleDidChange()
  }
  func systemStyleDidChange() {
    needsDisplay = true
    for child in subviews { child.needsDisplay = true }
  }
}

@MainActor final class PlatterView: SystemStyledView {
  var glassEnvironment: () -> GlassSurface.Environment = { .current }
  override func draw(_ dirtyRect: NSRect) {
    SystemStyle.drawPlatter(bounds, onGlass: true, environment: glassEnvironment())
  }
}

/// Native inset group foundation for the later Settings panes.
@MainActor final class SystemFormSection: SystemStyledView {
  private let stack = NSStackView()
  init(rows: [SystemFormRow]) {
    super.init(frame: .zero)
    stack.orientation = .vertical
    stack.spacing = 0
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    for (index, row) in rows.enumerated() {
      row.showsSeparator = index > 0
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    let solid = GlassSurface.Environment.current.treatment == .solid
    let fill =
      solid
      ? NSColor.controlBackgroundColor
      : SystemStyle.isDark(effectiveAppearance)
        ? NSColor.white.withAlphaComponent(0.08) : NSColor.textBackgroundColor
    fill.setFill()
    NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: SystemStyle.Radius.group,
      yRadius: SystemStyle.Radius.group
    ).fill()
    NSColor.separatorColor.withAlphaComponent(solid ? 1 : 0.35).setStroke()
    let outline = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: SystemStyle.Radius.group,
      yRadius: SystemStyle.Radius.group)
    outline.lineWidth = 0.5
    outline.stroke()
  }
}

@MainActor final class SystemFormRow: SystemStyledView {
  var showsSeparator = false
  init(label title: String, control: NSView, minimumHeight: CGFloat = SystemStyle.Space.row) {
    super.init(frame: .zero)
    control.translatesAutoresizingMaskIntoConstraints = false
    control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    addSubview(control)
    let preferredHeight = heightAnchor.constraint(equalToConstant: minimumHeight)
    preferredHeight.priority = .defaultLow
    NSLayoutConstraint.activate([
      preferredHeight,
      heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
      control.centerYAnchor.constraint(equalTo: centerYAnchor),
      control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
      control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
      control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    ])
    if title.isEmpty {
      if control is NSButton {
        control.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12)
          .isActive = true
      } else {
        control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12).isActive = true
      }
    } else {
      let label = NSTextField(wrappingLabelWithString: title)
      label.font = .systemFont(ofSize: SystemStyle.TypeSize.body)
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      NSLayoutConstraint.activate([
        label.centerYAnchor.constraint(equalTo: centerYAnchor),
        label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
        label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        label.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -12),
      ])
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    guard showsSeparator else { return }
    NSColor.separatorColor.setFill()
    NSRect(x: 12, y: bounds.maxY - 0.5, width: max(0, bounds.width - 24), height: 0.5).fill()
  }
}

@MainActor final class SegmentedBarView: SystemStyledView {
  struct Segment {
    let fraction: Double?
    let color: NSColor
  }
  var segments: [Segment] = [] { didSet { needsDisplay = true } }
  static func draw(_ segments: [Segment], in rect: NSRect) {
    guard rect.width > 0, rect.height > 0 else { return }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    NSColor.quaternaryLabelColor.setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 0.5
    path.stroke()
    path.addClip()
    var offset = 0.0
    for segment in segments {
      guard let value = segment.fraction, value.isFinite, value >= 0 else { continue }
      let width = min(value, max(0, 1 - offset))
      segment.color.setFill()
      NSRect(
        x: rect.minX + rect.width * offset, y: rect.minY, width: rect.width * width,
        height: rect.height
      ).fill()
      offset += width
    }
  }
  override func draw(_ dirtyRect: NSRect) { Self.draw(segments, in: bounds) }
}

/// Shared native action control: compact icons in dropdowns, standard buttons in windows.
@MainActor final class MenuActionRow: NSButton {
  private var hoverTracking: NSTrackingArea?
  private var hovering = false
  private var iconName: String?
  private(set) var usesBrandIcon = false
  var accentModule: Module = .overview { didSet { updateTint() } }
  var showsAccent = false { didSet { updateTint() } }
  func refreshTint() { updateTint() }
  private func updateTint() {
    contentTintColor =
      usesBrandIcon
      ? nil
      : usesIconPresentation
        ? (showsAccent
          ? SystemStyle.moduleAccent(accentModule)
          : hovering
            ? SystemStyle.moduleAccent(accentModule)
            : glassEnvironment().treatment == .glass
              ? SystemStyle.glassSecondaryLabel : .secondaryLabelColor)
        : .labelColor
  }
  var glassEnvironment: () -> GlassSurface.Environment = { .current }
  var usesIconPresentation = false {
    didSet {
      guard oldValue != usesIconPresentation else { return }
      imagePosition = usesIconPresentation ? .imageOnly : .imageLeading
      if !usesIconPresentation { image = nil }
      hovering = false
      updateTint()
      needsDisplay = true
      noteFocusRingMaskChanged()
    }
  }
  func setIcon(_ name: String, fallback: String) {
    // AppKit can restore image-leading placement when a button's title changes.
    defer { imagePosition = .imageOnly }
    guard iconName != name || image == nil else { return }
    usesBrandIcon = false
    iconName = name
    image = Self.symbolImage(name, fallback: fallback)
  }
  func setBrandIcon() {
    defer { imagePosition = .imageOnly }
    guard !usesBrandIcon || image == nil else { return }
    usesBrandIcon = true
    iconName = nil
    if let icon = NSApp.applicationIconImage.copy() as? NSImage {
      icon.size = .init(width: 16, height: 16)
      icon.isTemplate = false
      image = icon
    }
    imageScaling = .scaleNone
    imagePosition = .imageOnly
    updateTint()
  }
  static func symbolImage(_ name: String, fallback: String) -> NSImage? {
    (NSImage(systemSymbolName: name, accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil))?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
  }
  override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
  override var canBecomeKeyView: Bool { acceptsFirstResponder }
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers.isEmpty, [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers),
      isEnabled
    {
      performClick(nil)
    } else {
      super.keyDown(with: event)
    }
  }
  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() {
    NSBezierPath(
      roundedRect: bounds, xRadius: SystemStyle.Radius.control,
      yRadius: SystemStyle.Radius.control
    ).fill()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let tracking = NSTrackingArea(
      rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
      owner: self)
    addTrackingArea(tracking)
    hoverTracking = tracking
  }
  override func mouseEntered(with event: NSEvent) {
    hovering = true
    updateTint()
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovering = false
    updateTint()
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    if usesIconPresentation {
      if isEnabled && (hovering || isHighlighted) {
        let dark = SystemStyle.isDark(effectiveAppearance)
        (dark ? NSColor.white : NSColor.black)
          .withAlphaComponent(isHighlighted ? 0.14 : dark ? 0.12 : 0.10).setFill()
        NSBezierPath(
          roundedRect: bounds, xRadius: SystemStyle.Radius.control,
          yRadius: SystemStyle.Radius.control
        ).fill()
      }
      if usesBrandIcon, let image {
        // Crop to the mark's content plus a small paper inset: the old full-paper crop
        // left only 7.5pt of letter ink beside 12.5–14pt symbol ink at 2x. A 15pt tile
        // with this tighter crop gives the mark comparable optical weight. Snap only
        // the origin to device pixels: retain 15pt at 1x/2x and the existing 2x result.
        // The 28pt target and hover/focus geometry stay intact.
        // NSButton is flipped: explicitly preserve the source image’s upright orientation.
        var tile = NSRect(x: bounds.midX - 7.5, y: bounds.midY - 7.5, width: 15, height: 15)
        if let context = NSGraphicsContext.current?.cgContext {
          var pixels = context.convertToDeviceSpace(tile)
          pixels.origin.x = pixels.origin.x.rounded()
          pixels.origin.y = pixels.origin.y.rounded()
          tile = context.convertToUserSpace(pixels)
        }
        let dark = SystemStyle.isDark(effectiveAppearance)
        let paper = NSBezierPath(roundedRect: tile, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        paper.addClip()
        if dark {
          NSColor.black.setFill()
          paper.fill()
        }
        // A standalone 32px icon uses the dedicated pixel-snapped master: its foot
        // and dot end at 25/32, below the large master's baseline. Retain paper around
        // that geometry when AppKit supplies only the small representation.
        let smallMaster = image.representations.map(\.pixelsWide).max() == 32
        let crop =
          smallMaster
          ? NSRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70)
          : NSRect(x: 0.22, y: 0.26, width: 0.56, height: 0.56)
        image.draw(
          in: tile,
          from: .init(
            x: image.size.width * crop.minX, y: image.size.height * crop.minY,
            width: image.size.width * crop.width, height: image.size.height * crop.height),
          operation: .sourceOver, fraction: dark ? 0.9 : 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        let edge = NSBezierPath(
          roundedRect: tile.insetBy(dx: 0.25, dy: 0.25), xRadius: 2.75, yRadius: 2.75)
        edge.lineWidth = 0.5
        edge.stroke()
      } else {
        cell?.drawInterior(withFrame: bounds, in: self)
      }
      return
    }
    guard !isBordered else {
      super.draw(dirtyRect)
      return
    }
    let selected = isEnabled && (hovering || isHighlighted)
    if selected {
      SystemStyle.accent.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let ink: NSColor =
      !isEnabled
      ? .disabledControlTextColor : selected ? .alternateSelectedControlTextColor : .labelColor
    (title as NSString).draw(
      in: bounds.insetBy(dx: 6, dy: 4),
      withAttributes: [
        .font: font ?? .systemFont(ofSize: 13), .foregroundColor: ink, .paragraphStyle: style,
      ])
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    bezelStyle = .recessed
    alignment = .left
    font = .systemFont(ofSize: SystemStyle.TypeSize.body)
    setButtonType(.momentaryPushIn)
    focusRingType = .exterior
    contentTintColor = .labelColor
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
