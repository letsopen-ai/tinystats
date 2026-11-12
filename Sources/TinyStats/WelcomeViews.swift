import AppKit
import TinyStatsCore

/// Welcome fixtures never enter collection, history or saved preferences.
enum WelcomeFixture {
  static let historyCPU: [Double] = (0..<56).map { i in
    let wave = 14.0 * sin(Double(i) / 3.1) + 9.0 * sin(Double(i) / 1.3)
    return 30.0 + wave + (i % 9 == 4 ? 22.0 : 0.0)
  }
  static let historyMemory: [Double] = (0..<56).map { i in
    62 + 6 * sin(Double(i) / 7) + 3 * sin(Double(i) / 2.2)
  }
  static let historySize = String(
    format: "%.1f MiB", Double(SessionHistory.maximumCheckpointBytes) / 1_048_576)
}

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
    image.widthAnchor.constraint(equalToConstant: size).isActive = true
    image.heightAnchor.constraint(equalToConstant: size).isActive = true
    return image
  }
  static func text(
    _ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 11,
    color: NSColor = .labelColor, weight: NSFont.Weight = .regular
  ) {
    (value as NSString).draw(
      at: .init(x: x, y: y),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
      ])
  }
  static func symbol(_ name: String, in rect: NSRect, module: Module? = nil) {
    guard
      let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(
          .init(pointSize: rect.height, weight: .regular)
            .applying(
              .init(paletteColors: [module.map(SystemStyle.moduleAccent) ?? .secondaryLabelColor]))),
      image.size.width > 0, image.size.height > 0
    else { return }
    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(
      in: .init(
        x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
        width: size.width, height: size.height))
  }
  static func round(
    _ rect: NSRect, radius: CGFloat = 7, fill: NSColor, rim: NSColor? = nil, dashed: Bool = false
  ) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let rim {
      rim.setStroke()
      path.lineWidth = dashed ? 1 : 0.5
      if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
      path.stroke()
    }
  }
  static func chart(
    _ values: [Double], in rect: NSRect, color: NSColor, width: CGFloat = 2, fill: CGFloat = 0
  ) {
    guard values.count > 1 else { return }
    let line = NSBezierPath()
    for (i, value) in values.enumerated() {
      let point = NSPoint(
        x: rect.minX + CGFloat(i) / CGFloat(values.count - 1) * rect.width,
        y: rect.minY + CGFloat(value / 100) * rect.height)
      if i == 0 { line.move(to: point) } else { line.line(to: point) }
    }
    if fill > 0 {
      let area = line.copy() as! NSBezierPath
      area.line(to: .init(x: rect.maxX, y: rect.minY))
      area.line(to: rect.origin)
      area.close()
      color.withAlphaComponent(fill).setFill()
      area.fill()
    }
    color.setStroke()
    line.lineWidth = width
    line.stroke()
  }
  static func examples(_ settings: Settings) -> [[MenuBarReadout]] {
    let groups = settings.readouts.map {
      [MenuBarStyleExample.readout(module: $0, style: settings.style(for: $0), settings: settings)]
    }
    return settings.separateItems ? groups : [groups.flatMap { $0 }]
  }
  static var starterSettings: Settings {
    var settings = Settings()
    settings.readouts = [.cpu, .memory, .network]
    return settings
  }
  static func decorative(_ view: NSView) {
    view.setAccessibilityElement(false)
    for child in view.subviews { decorative(child) }
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

@MainActor class WelcomeStageView: SystemStyledView {
  let environment: () -> GlassSurface.Environment
  var platter = true
  var secondaryInk: NSColor {
    environment().treatment == .glass ? SystemStyle.glassSecondaryLabel : .secondaryLabelColor
  }
  init(label: String, group: Bool = false, environment: @escaping () -> GlassSurface.Environment) {
    self.environment = environment
    super.init(frame: .zero)
    setContentHuggingPriority(.init(1), for: .vertical)
    setContentCompressionResistancePriority(.init(1), for: .vertical)
    setAccessibilityElement(true)
    setAccessibilityRole(group ? .group : .image)
    setAccessibilityLabel(label)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    if platter { SystemStyle.drawPlatter(bounds, onGlass: true, environment: environment()) }
  }
  func drawBar() {
    let bar = NSRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 28)
    WelcomeGraphic.round(
      bar, radius: SystemStyle.Radius.platter, fill: .labelColor.withAlphaComponent(0.05))
    var x: CGFloat = 18
    for width: CGFloat in [34, 26, 30, 22] {
      WelcomeGraphic.round(
        .init(x: x, y: bar.midY - 3.5, width: width, height: 7), radius: 3.5,
        fill: .tertiaryLabelColor.withAlphaComponent(0.55))
      x += width + 14
    }
  }
}

/// Shared magnification composition: native production renderers at both scales.
@MainActor class WelcomeZoomStageView: WelcomeStageView {
  let preview = MenuBarPreviewView()
  let magnifiedPreview = MenuBarPreviewView()
  let zoomContainer = NSView()
  let scroll = NSScrollView()
  var scale: CGFloat = 2
  var lens = NSRect.zero
  var strip = NSRect.zero
  override init(
    label: String, group: Bool = false, environment: @escaping () -> GlassSurface.Environment
  ) {
    super.init(label: label, group: group, environment: environment)
    preview.clipsToBounds = true
    addSubview(preview)
    zoomContainer.addSubview(magnifiedPreview)
    scroll.documentView = zoomContainer
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.setAccessibilityLabel("Menu bar preview with example readings")
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(_ settings: Settings) {
    let groups = WelcomeGraphic.examples(settings)
    for view in [preview, magnifiedPreview] {
      // MenuBarPreviewView centres native-height renderers in a 36pt canvas.
      view.update(groups: groups, paused: false, height: NSStatusBar.system.thickness)
      WelcomeGraphic.decorative(view)
    }
    needsLayout = true
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    let nativeWidth = preview.preferredWidth
    preview.frame = .init(
      x: max(14, bounds.width - nativeWidth - 14), y: bounds.height - 36,
      width: min(nativeWidth, bounds.width - 28), height: 36)
    lens = .init(
      x: preview.frame.minX - 4, y: bounds.height - 26, width: preview.frame.width + 8, height: 24)
    let requested = scale
    let fit = min(requested, 612 / max(1, nativeWidth))
    let actual = requested == 2 ? 2 : max(1, fit)
    let width = min(612, nativeWidth * actual + 52)
    strip = .init(
      x: (bounds.width - width) / 2, y: bounds.height - (requested == 2 ? 112 : 44 + 36 * actual),
      width: width, height: requested == 2 ? 64 : 36 * actual)
    scroll.frame = strip.insetBy(dx: 26, dy: 0)
    zoomContainer.frame = .init(
      x: 0, y: 0, width: max(scroll.bounds.width, nativeWidth * actual), height: strip.height)
    zoomContainer.setBoundsSize(
      .init(width: zoomContainer.frame.width / actual, height: strip.height / actual))
    magnifiedPreview.frame = .init(
      x: 0, y: (zoomContainer.bounds.height - 36) / 2, width: nativeWidth, height: 36)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawBar()
    WelcomeGraphic.round(lens, radius: 6, fill: .clear, rim: .tertiaryLabelColor)
    let lines = NSBezierPath()
    lines.move(to: .init(x: lens.minX, y: lens.minY))
    lines.line(to: .init(x: strip.minX, y: strip.maxY))
    lines.move(to: .init(x: lens.maxX, y: lens.minY))
    lines.line(to: .init(x: strip.maxX, y: strip.maxY))
    NSColor.labelColor.withAlphaComponent(0.14).setStroke()
    lines.lineWidth = 1
    lines.stroke()
    WelcomeGraphic.round(strip, radius: 14, fill: .labelColor.withAlphaComponent(0.05))
  }
}

/// Frame-based composition keeps the visible glyph centred, without a stack's independent
/// intrinsic-size layout moving its arranged children after the stage has placed the row.
@MainActor private final class WelcomeReadoutIdentityView: NSView {
  let glyph: NSImageView
  private let title: NSTextField
  init(module: Module) {
    glyph = WelcomeGraphic.glyph(module.symbol, module: module, size: 30)
    title = WelcomeGraphic.label(module.title, size: 12)
    title.alignment = .center
    super.init(frame: .zero)
    identifier = .init(module.rawValue)
    addSubview(glyph)
    addSubview(title)
    WelcomeGraphic.decorative(self)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    glyph.frame = .init(x: (bounds.width - 30) / 2, y: 21, width: 30, height: 30)
    title.frame = .init(x: 0, y: 0, width: bounds.width, height: 15)
  }
}

@MainActor final class WelcomeHeroView: WelcomeZoomStageView {
  private var identities: [WelcomeReadoutIdentityView] = []
  init(environment: @escaping () -> GlassSurface.Environment) {
    super.init(
      label:
        "Example menu bar: CPU 42%, Memory 68%, Network upload 128 KB/s, download 2.4 MB/s. Example readings.",
      environment: environment)
    identifier = .init("welcome-hero")
    heightAnchor.constraint(equalToConstant: 196).isActive = true
    update(WelcomeGraphic.starterSettings)
    for module in WelcomeGraphic.starterSettings.readouts {
      let node = WelcomeReadoutIdentityView(module: module)
      addSubview(node)
      identities.append(node)
      WelcomeGraphic.decorative(node)
    }
    WelcomeGraphic.decorative(scroll)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    for (node, renderer) in zip(identities, magnifiedPreview.renderers) {
      let center = convert(renderer.bounds, from: renderer).midX
      node.frame = .init(x: center - 50, y: 26, width: 100, height: 51)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    WelcomeGraphic.text("Example readings", bounds.width - 104, 8, color: secondaryInk)
  }
}

@MainActor final class WelcomeMenuBarStageView: WelcomeZoomStageView {
  var layoutControl: NSSegmentedControl? {
    didSet { if let layoutControl { addSubview(layoutControl) } }
  }
  init(environment: @escaping () -> GlassSurface.Environment) {
    super.init(
      label: "Menu bar preview with example readings", group: true, environment: environment)
    scale = 1.5
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    layoutControl?.frame = .init(x: bounds.width - 96, y: 8, width: 82, height: 26)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    WelcomeGraphic.text(
      "Example readings · ⌘-drag readouts in the menu bar to reorder", 14, 14, color: secondaryInk)
  }
}

@MainActor final class WelcomeHistoryStageView: WelcomeStageView {
  init(environment: @escaping () -> GlassSurface.Environment) {
    super.init(
      label:
        "Example history chart: CPU and Memory over \(HistoryRange.fourWeeks.title). Saved locally, up to \(WelcomeFixture.historySize).",
      environment: environment)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    for (x, module) in [(CGFloat(18), Module.cpu), (100, .memory)] {
      WelcomeGraphic.symbol(
        module.symbol, in: .init(x: x, y: bounds.height - 36, width: 15, height: 15), module: module
      )
      WelcomeGraphic.text(module.title, x + 21, bounds.height - 32, size: 12)
    }
    let rect = NSRect(x: 18, y: 44, width: bounds.width - 36, height: max(0, bounds.height - 90))
    for fraction: CGFloat in [0.25, 0.5, 0.75] {
      NSColor.labelColor.withAlphaComponent(0.08).setFill()
      NSRect(x: rect.minX, y: rect.minY + rect.height * fraction, width: rect.width, height: 0.5)
        .fill()
    }
    let glass = environment().treatment == .glass
    WelcomeGraphic.chart(
      WelcomeFixture.historyCPU, in: rect, color: SystemStyle.moduleAccent(.cpu),
      width: glass ? 2 : 1.5, fill: glass ? 0.06 : 0.20)
    WelcomeGraphic.chart(
      WelcomeFixture.historyMemory, in: rect, color: SystemStyle.moduleAccent(.memory),
      width: glass ? 2 : 1.5)
    WelcomeGraphic.text("\(HistoryRange.fourWeeks.title) ago", 18, 26, color: secondaryInk)
    WelcomeGraphic.text("Now", bounds.width - 42, 26, color: secondaryInk)
    WelcomeGraphic.text("Example history", 18, 8, color: secondaryInk)
    WelcomeGraphic.symbol(
      "internaldrive", in: .init(x: bounds.width - 211, y: 9, width: 12, height: 12))
    WelcomeGraphic.text(
      "Saved locally · up to \(WelcomeFixture.historySize)", bounds.width - 193, 8,
      color: secondaryInk)
  }
}

@MainActor final class WelcomeBadge: NSView {
  var text: String {
    didSet {
      needsDisplay = true
      setAccessibilityLabel(text)
    }
  }
  init(_ text: String) {
    self.text = text
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(text)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    WelcomeGraphic.round(
      bounds.insetBy(dx: 0.5, dy: 0.5), radius: 8, fill: .windowBackgroundColor,
      rim: .tertiaryLabelColor)
    WelcomeGraphic.text(
      text, 7, (bounds.height - 13) / 2, size: 10, color: .secondaryLabelColor, weight: .medium)
  }
}

/// Top-aligned copy with a title accessory and a bottom-trailing native action.
@MainActor final class WelcomeTileView: WelcomeStageView {
  let titleLabel: NSTextField
  let captionLabel: NSTextField
  private let glyph: NSImageView
  private let cardHeight: CGFloat
  var lines: [String] = [] { didSet { needsDisplay = true } }
  var accessory: NSView? {
    didSet {
      oldValue?.removeFromSuperview()
      if let accessory { addSubview(accessory) }
      needsLayout = true
    }
  }
  var actionButton: NSButton? {
    didSet {
      oldValue?.removeFromSuperview()
      if let actionButton { addSubview(actionButton) }
      needsLayout = true
    }
  }
  private var ruleElement: NSAccessibilityElement?
  var rule = false {
    didSet {
      needsDisplay = true
      if rule {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.image)
        element.setAccessibilityLabel("Example rule: CPU above 90% for 5 minutes")
        element.setAccessibilityParent(self)
        ruleElement = element
      } else {
        ruleElement = nil
      }
    }
  }
  override func accessibilityChildren() -> [Any]? {
    let children = super.accessibilityChildren() ?? []
    return children + (ruleElement.map { [$0] } ?? [])
  }
  init(
    title: String, caption: String, symbol: String, module: Module? = nil, height: CGFloat,
    environment: @escaping () -> GlassSurface.Environment
  ) {
    titleLabel = WelcomeGraphic.label(title, size: height == 60 ? 13 : 15)
    titleLabel.font = .systemFont(ofSize: height == 60 ? 13 : 15, weight: .semibold)
    captionLabel = WelcomeGraphic.label(caption, size: 11, secondary: true)
    glyph = WelcomeGraphic.glyph(symbol, module: module, size: 28)
    cardHeight = height
    super.init(label: title, group: true, environment: environment)
    setAccessibilityHelp(caption)
    identifier = .init("welcome-tile")
    addSubview(glyph)
    addSubview(titleLabel)
    addSubview(captionLabel)
    heightAnchor.constraint(equalToConstant: height).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    ruleElement?.setAccessibilityFrameInParentSpace(
      .init(
        x: 25, y: 57, width: bounds.width - 41, height: 24))
    let short = cardHeight == 60
    glyph.frame = .init(x: 16, y: bounds.height - (short ? 44 : 45), width: 28, height: 28)
    titleLabel.frame = .init(
      x: 54, y: bounds.height - (short ? 28 : 36), width: bounds.width - 125, height: 19)
    captionLabel.frame = .init(
      x: 54, y: bounds.height - (short ? 44 : 58), width: bounds.width - 66, height: 14)
    if let accessory {
      let width: CGFloat =
        accessory is NSSwitch ? 38 : (accessory as? WelcomeBadge)?.text == "Advanced" ? 64 : 34
      accessory.frame = .init(
        x: bounds.width - width - 16, y: bounds.height - (short ? 40 : 38), width: width, height: 22
      )
    }
    if let actionButton {
      actionButton.sizeToFit()
      actionButton.frame.origin = .init(x: bounds.width - actionButton.frame.width - 16, y: 14)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    for (i, line) in lines.enumerated() {
      WelcomeGraphic.text(line, 54, bounds.height - 76 - CGFloat(i) * 17, color: secondaryInk)
    }
    if rule {
      let rect = NSRect(x: 25, y: 57, width: bounds.width - 41, height: 24)
      WelcomeGraphic.round(rect, radius: 12, fill: .clear, rim: .tertiaryLabelColor, dashed: true)
      WelcomeGraphic.symbol(
        Module.cpu.symbol, in: .init(x: 32, y: 62, width: 13, height: 13), module: .cpu)
      WelcomeGraphic.text("CPU above 90% for 5 min", 51, 62)
      let exampleX =
        51
        + ("CPU above 90% for 5 min" as NSString).size(withAttributes: [
          .font: NSFont.systemFont(ofSize: 11)
        ]).width + 5
      WelcomeGraphic.text("· example", exampleX, 62, color: secondaryInk)
    }
  }
}

@MainActor final class WelcomeOnlineStageView: WelcomeStageView {
  let weather: WelcomeTileView
  let internet: WelcomeTileView
  let weatherPill = WelcomeBadge("Off")
  let internetPill = WelcomeBadge("Off")
  let updates: WelcomeTileView
  let updatesPill = WelcomeBadge("Off")
  let promiseLabel = WelcomeGraphic.label("", size: 11, secondary: true)
  private(set) var updatesOn = false
  private var updateState: UpdatePresentation
  private(set) var weatherOn = false
  private(set) var internetOn = false
  init(
    settings: Settings, updates updateState: UpdatePresentation = .init(),
    environment: @escaping () -> GlassSurface.Environment
  ) {
    self.updateState = updateState
    updates = WelcomeTileView(
      title: "Updates · GitHub", caption: "Daily checks · app version only",
      symbol: "arrow.down.circle", height: 60, environment: environment)
    weather = WelcomeTileView(
      title: "Weather", caption: "MET Norway · api.met.no", symbol: Module.weather.symbol,
      module: .weather, height: 140, environment: environment)
    internet = WelcomeTileView(
      title: "Internet checks", caption: "Apple or your URL · ipify · your ping address",
      symbol: Module.network.symbol, module: .network, height: 140, environment: environment)
    super.init(
      label: "Online features. Weather and Internet checks are off until you turn them on.",
      group: true, environment: environment)
    platter = false
    weather.identifier = .init("welcome-weather")
    weather.lines = [
      "Sends rounded location and your IP"
    ]
    weather.captionLabel.textColor = .labelColor
    weather.setAccessibilityHelp(
      "Off until opt-in. Choose a city or allow location in setup. When enabled, MET Norway receives rounded coordinates and your public IP. Opening setup enables nothing. Saved choices stay yours."
    )
    internet.identifier = .init("welcome-internet")
    internet.lines = ["Each destination sees your IP"]
    internet.captionLabel.textColor = .labelColor
    internet.accessory = WelcomeBadge("Advanced")
    internet.setAccessibilityHelp(
      "Off by default. HTTPS uses Apple’s preset or your URL; public IP uses ipify; ping uses your numeric address. Each destination sees your source IP. Review destinations and cadence before enabling. Existing online choices are preserved."
    )
    updates.identifier = .init("welcome-updates")
    updates.setAccessibilityHelp(
      "Signed releases check GitHub daily by default, sending only the app version. Change automatic checks and downloads in Settings › General. Development builds never check. Saved Off choices are preserved."
    )
    promiseLabel.alignment = .center
    for view in [weather, internet, updates, weatherPill, internetPill, updatesPill, promiseLabel] {
      addSubview(view)
    }
    update(settings)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(_ settings: Settings, updates: UpdatePresentation? = nil) {
    if let updates { updateState = updates }
    updatesOn = updateState.eligible && updateState.preferences.automaticallyCheck
    updatesPill.text = updatesOn ? "On" : "Off"
    self.updates.captionLabel.stringValue =
      updateState.eligible
      ? "Daily checks · app version only" : "Signed releases · Settings › General"
    promiseLabel.stringValue =
      updatesOn
      ? "Updates on · Weather and internet checks are optional. Opening setup changes nothing."
      : "Update checks off. Opening setup changes nothing."
    weatherOn = settings.weather.enabled
    internetOn =
      settings.connectivityChecks || settings.publicIPChecks || settings.pingCheck.enabled
    weatherPill.text = weatherOn ? "On" : "Off"
    internetPill.text = internetOn ? "On" : "Off"
    setAccessibilityLabel(
      "Online features. Weather \(weatherPill.text). Internet checks \(internetPill.text). GitHub update checks \(updatesPill.text); daily by default on signed releases, disable in General. Opening setup changes nothing."
    )
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    weather.frame = .init(x: 310, y: bounds.height - 144, width: 350, height: 140)
    internet.frame = .init(x: 310, y: bounds.height - 298, width: 350, height: 140)
    updates.frame = .init(x: 310, y: 40, width: 350, height: 60)
    for (card, badge) in [(weather, weatherPill), (internet, internetPill), (updates, updatesPill)]
    {
      badge.frame = .init(x: 224, y: card.frame.midY - 10, width: 34, height: 20)
    }
    promiseLabel.frame = .init(x: 20, y: 4, width: bounds.width - 40, height: 16)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let mac = NSRect(x: 20, y: (bounds.height - 150) / 2 + 12, width: 150, height: 150)
    WelcomeGraphic.round(
      mac, radius: 75, fill: SystemStyle.cardFill(onGlass: true, environment: environment()),
      rim: .separatorColor)
    WelcomeGraphic.symbol(
      "laptopcomputer", in: .init(x: 75, y: mac.minY + 83, width: 40, height: 40))
    WelcomeGraphic.text("This Mac", 65, mac.minY + 52, size: 14, weight: .semibold)
    WelcomeGraphic.text("Your controls", 59, mac.minY + 31, color: secondaryInk)
    for (card, on, offset) in [
      (weather, weatherOn, CGFloat(28)), (internet, internetOn, 0), (updates, updatesOn, -28),
    ] {
      let path = NSBezierPath()
      path.move(to: .init(x: mac.maxX, y: mac.midY + offset))
      path.curve(
        to: .init(x: card.frame.minX, y: card.frame.midY),
        controlPoint1: .init(x: 240, y: mac.midY + offset),
        controlPoint2: .init(x: 240, y: card.frame.midY))
      if !on { path.setLineDash([4, 5], count: 2, phase: 0) }
      NSColor.labelColor.withAlphaComponent(0.35).setStroke()
      path.lineWidth = 1.5
      path.stroke()
    }

  }
}

@MainActor final class WelcomeReadyStageView: WelcomeStageView {
  static let menuTitles = StatusMenuTitles.tour
  let preview = MenuBarPreviewView()
  var overviewButton: NSButton? { didSet { if let overviewButton { addSubview(overviewButton) } } }
  var settingsButton: NSButton? { didSet { if let settingsButton { addSubview(settingsButton) } } }
  init(environment: @escaping () -> GlassSurface.Environment) {
    super.init(
      label:
        "Illustration: click a readout to open its details, with a sidebar for every module. Right-click a readout for Pause monitoring, Settings, Show welcome tour, Open Activity Monitor and Quit TinyStats.",
      group: true, environment: environment)
    preview.update(
      groups: WelcomeGraphic.examples(WelcomeGraphic.starterSettings), paused: false,
      height: NSStatusBar.system.thickness)
    addSubview(preview)
    WelcomeGraphic.decorative(preview)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    preview.frame = .init(
      x: bounds.width - preview.preferredWidth - 44, y: bounds.height - 36,
      width: preview.preferredWidth, height: 36)
    for (button, trailing) in [(overviewButton, CGFloat(318)), (settingsButton, 642)] {
      button?.sizeToFit()
      if let button { button.frame.origin = .init(x: trailing - button.frame.width, y: 34) }
    }
  }
  private func sketch(_ rect: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    if environment().treatment != .solid {
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
      shadow.shadowOffset = .init(width: 0, height: -8)
      shadow.shadowBlurRadius = 24
      shadow.set()
    }
    WelcomeGraphic.round(rect, radius: radius, fill: .windowBackgroundColor, rim: .separatorColor)
    NSGraphicsContext.restoreGraphicsState()
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawBar()
    let frames = preview.renderers.map { convert($0.bounds, from: $0) }
    for index in [0, 2] where frames.indices.contains(index) {
      WelcomeGraphic.round(
        frames[index].insetBy(dx: -2, dy: 0), radius: 4, fill: .labelColor.withAlphaComponent(0.12))
    }
    let cpuCenter = frames.first?.midX ?? 335
    let menu = NSRect(
      x: min(bounds.width - 186, frames.last?.minX ?? 474), y: bounds.height - 34 - 129, width: 172,
      height: 129)
    // Keep both teaching sketches legible while the bar retains native readout packing.
    let pop = NSRect(x: menu.minX - 266, y: bounds.height - 240, width: 250, height: 200)
    let notchCenter = min(cpuCenter, pop.maxX - 16)
    let guide = NSBezierPath()
    guide.move(to: .init(x: cpuCenter, y: bounds.height - 28))
    guide.line(to: .init(x: notchCenter, y: pop.maxY + 6))
    NSColor.labelColor.withAlphaComponent(0.14).setStroke()
    guide.lineWidth = 1
    guide.stroke()
    sketch(pop, radius: 12)
    let notch = NSBezierPath()
    notch.move(to: .init(x: notchCenter - 6, y: pop.maxY))
    notch.line(to: .init(x: notchCenter, y: pop.maxY + 6))
    notch.line(to: .init(x: notchCenter + 6, y: pop.maxY))
    NSColor.windowBackgroundColor.setFill()
    notch.fill()
    NSColor.separatorColor.setStroke()
    notch.lineWidth = 0.5
    notch.stroke()
    NSColor.separatorColor.setFill()
    NSRect(x: pop.minX + 40, y: pop.minY, width: 0.5, height: 200).fill()
    let modules: [Module] = [
      .overview, .cpu, .memory, .disks, .network, .battery, .clock, .weather, .sensors,
    ]
    for (i, module) in modules.enumerated() {
      let rect = NSRect(x: pop.minX + 12, y: pop.maxY - 25 - CGFloat(i) * 20, width: 15, height: 15)
      if module == .cpu {
        WelcomeGraphic.round(
          rect.insetBy(dx: -4, dy: -3), radius: 6, fill: .labelColor.withAlphaComponent(0.10))
      }
      WelcomeGraphic.symbol(
        module == .overview ? "square.grid.2x2" : module.symbol, in: rect,
        module: module == .overview ? nil : module)
    }
    let x = pop.minX + 54
    let reading = MenuBarStyleExample.readout(
      module: .cpu, style: .text, settings: WelcomeGraphic.starterSettings)
    WelcomeGraphic.text("CPU", x, pop.maxY - 28, size: 12, weight: .semibold)
    WelcomeGraphic.text(reading.value, x, pop.maxY - 64, size: 26, weight: .bold)
    WelcomeGraphic.chart(
      reading.values.compactMap { $0 }, in: .init(x: x, y: pop.maxY - 112, width: 180, height: 40),
      color: SystemStyle.moduleAccent(.cpu), fill: 0.10)
    for (i, width): (Int, CGFloat) in [160, 120, 140].enumerated() {
      WelcomeGraphic.round(
        .init(x: x, y: pop.maxY - 134 - CGFloat(i) * 17, width: width, height: 7), radius: 3.5,
        fill: .labelColor.withAlphaComponent(0.05))
    }
    sketch(menu, radius: 8)
    var y = menu.maxY - 26
    for (i, title) in Self.menuTitles.enumerated() {
      if i == 4 {
        NSColor.separatorColor.setFill()
        NSRect(x: menu.minX + 11, y: y + 12, width: 150, height: 0.5).fill()
        y -= 9
      }
      if i == 2 {
        WelcomeGraphic.round(
          .init(x: menu.minX + 5, y: y - 2, width: 162, height: 21), radius: 4,
          fill: .controlAccentColor)
      }
      WelcomeGraphic.text(
        title, menu.minX + 12, y + 2, size: 12,
        color: i == 2 ? .alternateSelectedControlTextColor : .labelColor)
      if i == 1 || i == 4 {
        WelcomeGraphic.text(
          i == 1 ? "⌘," : "⌘Q", menu.maxX - 30, y + 2, size: 12, color: secondaryInk)
      }
      y -= 21
    }
    for (offset, title, caption, symbol) in [
      (CGFloat(0), "Click a readout", "Details for every reading", "cursorarrow.click"),
      (330, "Right-click", "Settings, pause, replay this tour", "contextualmenu.and.cursorarrow"),
    ] {
      WelcomeGraphic.symbol(
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil
          ? "cursorarrow.and.square.on.square.dashed" : symbol,
        in: .init(x: offset + 18, y: 36, width: 22, height: 22))
      WelcomeGraphic.text(title, offset + 46, 43, size: 13, weight: .semibold)
      WelcomeGraphic.text(caption, offset + 46, 16, color: secondaryInk)
    }
  }
}

@MainActor final class WelcomeProgressDots: NSView {
  var step = 0 {
    didSet {
      needsDisplay = true
      setAccessibilityLabel("Step \(step + 1) of 5")
    }
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("Step 1 of 5")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    var x = (bounds.width - 70) / 2
    for i in 0..<5 {
      let width: CGFloat = i == step ? 18 : 6
      WelcomeGraphic.round(
        .init(x: x, y: (bounds.height - 6) / 2, width: width, height: 6), radius: 3,
        fill: i == step ? .labelColor : .tertiaryLabelColor)
      x += width + 7
    }
  }
}

@MainActor final class WelcomeMoreReadoutsButton: NSButton {
  override init(frame: NSRect) {
    super.init(frame: frame)
    configure()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private func configure() {
    isBordered = false
    setAccessibilityLabel("More readouts in Menu Bar settings")
    heightAnchor.constraint(equalToConstant: 38).isActive = true
  }
  override func draw(_ dirtyRect: NSRect) {
    WelcomeGraphic.round(
      bounds.insetBy(dx: 1, dy: 1), fill: .clear, rim: .tertiaryLabelColor, dashed: true)
    WelcomeGraphic.symbol("plus", in: .init(x: 10, y: 12, width: 14, height: 14))
    WelcomeGraphic.text("More readouts…", 32, 11, size: 12, color: .secondaryLabelColor)
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
