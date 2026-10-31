import AppKit
import TinyStatsCore

/// Bounded, illustrative readouts. These never enter monitoring, history or saved preferences.
@MainActor enum MenuBarStyleExample {
  static func readout(
    module: Module, style: MenuBarStyle, settings: Settings,
    batteryState: BatteryMenuState? = nil
  ) -> MenuBarReadout {
    var result = MenuBarReadout(
      label: module.title.uppercased(), value: "42%", secondary: nil, style: style,
      appearance: settings.appearance(for: module), symbol: module.symbol,
      progress: 42, cores: [24, 38, 30, 46, 62, 52],
      coreKinds: [.efficiency, .efficiency, .efficiency, .efficiency, .performance, .performance],
      isNetwork: module == .network, module: module)
    switch module {
    case .memory:
      result.label = "MEM"
      result.value = "68%"
      result.progress = 68
    case .gpu:
      result.value = "36%"
      result.progress = 36
    case .disks:
      result.label = "SSD"
      result.value = "64%"
      result.progress = 64
    case .network:
      result.label = "NET"
      result.value = "↑ 128 KB/s"
      result.secondary = "↓ 2.4 MB/s"
    case .sensors:
      let temperature = settings.sensorKey == "cpu" || settings.sensorKey.hasPrefix("T")
      switch settings.sensorKey.first {
      case "F":
        result.label = "FAN"
        result.value = "1200 rpm"
      case "V":
        result.label = "VOLT"
        result.value = "1.2V"
      case "I":
        result.label = "CUR"
        result.value = "2.4A"
      default:
        result.label = temperature ? "CPU" : "PWR"
        result.value = temperature ? (settings.fahrenheit ? "126°" : "52°") : "6.8W"
      }
      result.progress = temperature ? 52 / 120 * 100 : nil
      result.historyMaximum = temperature ? 100 : nil
    case .battery:
      let state = batteryState ?? .draining
      var example = settings
      example.styles[Module.battery.rawValue] = style
      if let batteryState {
        example.batteryMenu[batteryState].style = style
      } else {
        example.batteryMenu.customizeStates = false
      }
      var snapshot = Snapshot()
      snapshot.batteries = [
        .init(
          name: "Example", percent: state == .charged ? 100 : 72,
          charging: state == .charging, externalPower: state != .draining,
          minutesRemaining: state == .charging ? 65 : 195, cycles: nil, health: nil,
          watts: state == .draining ? -8.4 : state == .charging ? 17.2 : 0,
          fullyCharged: state == .charged)
      ]
      result = MenuBarReadout.make(
        module: .battery, snapshot: snapshot, settings: example, history: [])
    case .clock:
      var example = settings
      example.styles[Module.clock.rawValue] = style
      result = MenuBarReadout.make(
        module: .clock, snapshot: Snapshot(), settings: example, history: [],
        clockDate: Date(timeIntervalSince1970: 1_700_000_000))
    case .weather:
      result.label = "Sunny"
      result.value = settings.fahrenheit ? "72°F" : "22°C"
      result.symbol = "sun.max"
    case .cpu, .overview: break
    }
    result.values = [18, 24, 21, 36, 32, 48, 40, 54, 38, 42]
    if module == .network {
      result.values = result.values.map { $0.map { $0 * 60_000 } }
      result.secondValues = [8, 12, 10, 18, 12, 20, 14, 24, 16, 12].map { Double($0) * 10_000 }
      result.historyMaximum = nil
    }
    return result
  }
}

/// Picture-only native buttons. One cached image per tile, replaced on appearance/settings changes.
@MainActor final class MenuBarStylePicker: NSControl {
  let module: Module
  private(set) var tiles: [MenuBarStyleTile] = []
  private(set) var styles: [MenuBarStyle] = []
  private var heightConstraint: NSLayoutConstraint!
  private struct PreviewKey: Equatable {
    let appearance: MenuBarAppearance
    let fahrenheit: Bool
    let sensorKey: String
    let battery: BatteryMenuSettings?
    let clock: ClockMenuSettings?
  }
  private var previewKey: PreviewKey?
  private let batteryState: BatteryMenuState?
  var selectedStyle: MenuBarStyle? {
    styles.indices.contains(indexOfSelectedItem) ? styles[indexOfSelectedItem] : nil
  }
  private(set) var indexOfSelectedItem = 0
  var titleOfSelectedItem: String? { selectedStyle?.title }
  override var isEnabled: Bool {
    didSet { for tile in tiles { tile.isEnabled = isEnabled } }
  }
  override var toolTip: String? {
    didSet {
      for tile in tiles {
        tile.toolTip = toolTip.map { "\(tile.style.title). \($0)" } ?? tile.style.title
      }
    }
  }
  init(module: Module, settings: Settings, batteryState: BatteryMenuState? = nil) {
    self.module = module
    self.batteryState = batteryState
    super.init(frame: .zero)
    heightConstraint = heightAnchor.constraint(equalToConstant: 44)
    heightConstraint.isActive = true
    setAccessibilityElement(true)
    setAccessibilityRole(.radioGroup)
    setAccessibilityLabel("\(module.title) menu bar style")
    update(settings: settings)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  func update(settings: Settings) {
    let available = MenuBarStyle.available(for: module, sensorKey: settings.sensorKey)
    if available != styles {
      for tile in tiles { tile.removeFromSuperview() }
      styles = available
      tiles = styles.map { style in
        let tile = MenuBarStyleTile(style: style)
        tile.target = self
        tile.action = #selector(selected(_:))
        tile.isEnabled = isEnabled
        tile.toolTip = toolTip.map { "\(style.title). \($0)" } ?? style.title
        addSubview(tile)
        return tile
      }
    }
    let key = PreviewKey(
      appearance: settings.appearance(for: module),
      fahrenheit: settings.fahrenheit,
      sensorKey: settings.sensorKey,
      battery: module == .battery ? settings.batteryMenu : nil,
      clock: module == .clock ? settings.clockMenu : nil)
    if previewKey != key {
      for tile in tiles {
        tile.update(
          MenuBarStyleExample.readout(
            module: module, style: tile.style, settings: settings, batteryState: batteryState))
      }
      previewKey = key
      needsLayout = true
    }
    selectItem(
      withTitle: (batteryState.map { settings.batteryMenu[$0].style } ?? settings.style(for: module))
        .title)
  }
  func selectItem(withTitle title: String) {
    guard let index = styles.firstIndex(where: { $0.title == title }) else { return }
    guard
      index != indexOfSelectedItem
        || tiles.enumerated().contains(where: {
          $0.element.state != ($0.offset == index ? .on : .off)
        })
    else { return }
    indexOfSelectedItem = index
    for (offset, tile) in tiles.enumerated() {
      let state: NSControl.StateValue = offset == index ? .on : .off
      if tile.state != state {
        tile.state = state
        tile.needsDisplay = true
        NSAccessibility.post(element: tile, notification: .valueChanged)
      }
    }
    window?.recalculateKeyViewLoop()
  }
  override func layout() {
    super.layout()
    guard bounds.width > 0, !tiles.isEmpty else { return }
    // Pane width alone determines columns, keeping tile widths stable between modules.
    let columns = min(7, max(1, Int((bounds.width + 8) / 72)))
    let rows = (tiles.count + columns - 1) / columns
    let width = max(0, (bounds.width - CGFloat(columns - 1) * 8) / CGFloat(columns))
    for (index, tile) in tiles.enumerated() {
      tile.frame = .init(
        x: CGFloat(index % columns) * (width + 8), y: CGFloat(index / columns) * 48,
        width: width, height: 40)
    }
    let height = CGFloat(rows) * 48 - 8
    if heightConstraint.constant != height { heightConstraint.constant = height }
  }
  @objc private func selected(_ sender: MenuBarStyleTile) {
    guard isEnabled else { return }
    selectItem(withTitle: sender.style.title)
    if let action { NSApp.sendAction(action, to: target, from: self) }
  }
  func moveFocus(from tile: MenuBarStyleTile, key: UInt16) {
    guard let index = tiles.firstIndex(of: tile) else { return }
    let candidate: MenuBarStyleTile?
    if key == 123 || key == 124 {
      let next = index + (key == 123 ? -1 : 1)
      candidate = tiles.indices.contains(next) ? tiles[next] : nil
    } else {
      let direction: CGFloat = key == 126 ? -1 : 1
      candidate = tiles.filter { ($0.frame.midY - tile.frame.midY) * direction > 1 }
        .min { a, b in
          let da = abs(a.frame.midY - tile.frame.midY) * 1000 + abs(a.frame.midX - tile.frame.midX)
          let db = abs(b.frame.midY - tile.frame.midY) * 1000 + abs(b.frame.midX - tile.frame.midX)
          return da < db
        }
    }
    if let candidate {
      window?.makeFirstResponder(candidate)
      candidate.scrollToVisible(candidate.bounds)
    }
  }
}

@MainActor final class MenuBarStyleTile: NSButton {
  let style: MenuBarStyle
  let renderer = MenuBarReadoutView()
  // NSButton is flipped; keep the production renderer's bitmap upright.
  override var isFlipped: Bool { false }
  var increaseContrast: () -> Bool = {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  }
  private(set) var cachedPreview: NSImage?
  var previewWidth: CGFloat { renderer.preferredWidth }
  init(style: MenuBarStyle) {
    self.style = style
    super.init(frame: .zero)
    title = ""
    isBordered = false
    setButtonType(.toggle)
    setAccessibilityLabel(style.title)
    setAccessibilityRole(.radioButton)
    toolTip = style.title
    NotificationCenter.default.addObserver(
      self, selector: #selector(invalidatePreview), name: NSColor.systemColorsDidChangeNotification,
      object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(invalidatePreview),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit {
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }
  func update(_ readout: MenuBarReadout) {
    renderer.readouts = [readout]
    renderer.frame = .init(x: 0, y: 0, width: renderer.preferredWidth, height: 24)
    invalidatePreview()
  }
  @objc private func invalidatePreview() {
    cachedPreview = nil
    needsDisplay = true
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    invalidatePreview()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    invalidatePreview()
  }
  override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
  func previewImage() -> NSImage? {
    if let cachedPreview { return cachedPreview }
    renderer.appearance = effectiveAppearance
    let scale = window?.backingScaleFactor ?? 2
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(ceil(renderer.bounds.width * scale)),
        pixelsHigh: Int(ceil(renderer.bounds.height * scale)), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
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
  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool {
    isEnabled && !isHiddenOrHasHiddenAncestor && state == .on
  }
  override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 7, yRadius: 7).fill()
  }
  override func keyDown(with event: NSEvent) {
    if [123, 124, 125, 126].contains(event.keyCode) {
      (superview as? MenuBarStylePicker)?.moveFocus(from: self, key: event.keyCode)
    } else if event.keyCode == 49 {
      performClick(nil)
    } else {
      super.keyDown(with: event)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
    NSColor.controlBackgroundColor.setFill()
    path.fill()
    if state == .on {
      SystemStyle.accent.withAlphaComponent(0.12).setFill()
      path.fill()
    }
    // A faint neutral strip evokes the menu bar without adding another material.
    NSColor.labelColor.withAlphaComponent(0.04).setFill()
    NSRect(x: 3, y: 8, width: max(0, bounds.width - 6), height: 24).fill()
    let contrast =
      increaseContrast()
      || [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua].contains(
        effectiveAppearance.name)
    (state == .on ? SystemStyle.accent : contrast ? NSColor.secondaryLabelColor : .separatorColor)
      .setStroke()
    path.lineWidth = state == .on ? 2 : contrast ? 1 : 0.5
    path.stroke()
    // User-formatted clock literals can exceed the pane width. Fit their real render as a
    // single image, preserving its aspect ratio instead of clipping or changing the readout.
    let scale = min(1, max(0, bounds.width - 16) / max(1, previewWidth))
    let size = NSSize(width: previewWidth * scale, height: 24 * scale)
    previewImage()?.draw(
      in: .init(
        x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
        width: size.width, height: size.height),
      from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45)
  }
}

/// Module tools share the header when space permits; narrow panes get one borderless row.
@MainActor final class MenuBarStyleHeader: NSView {
  private let identity: NSView
  private let size: NSPopUpButton
  let tool: NSView?
  private let section: NSView
  private var contentHeight: NSLayoutConstraint!
  init(identity: NSView, size: NSPopUpButton, tool: NSView?) {
    self.identity = identity
    self.size = size
    self.tool = tool
    let controls = SystemSettingsForm.controls([identity, NSView(), size])
    size.widthAnchor.constraint(equalToConstant: 96).isActive = true
    section = SystemSettingsForm.group([SystemSettingsForm.row("", controls, height: 38)])
    super.init(frame: .zero)
    addSubview(section)
    if let tool {
      tool.translatesAutoresizingMaskIntoConstraints = true
      tool.autoresizingMask = []
      addSubview(tool)
    }
    // Keep the existing narrow pane minimum independent of the selected module's contents.
    widthAnchor.constraint(greaterThanOrEqualToConstant: 328).isActive = true
    contentHeight = heightAnchor.constraint(equalToConstant: 38)
    contentHeight.isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    guard bounds.width > 0 else { return }
    section.frame = .init(x: 0, y: 0, width: bounds.width, height: 38)
    section.layoutSubtreeIfNeeded()
    guard let tool else { return }
    let leading = identity.convert(identity.bounds, to: self).maxX + 8
    let trailing = size.convert(size.bounds, to: self).minX - 8
    let width = min(tool.fittingSize.width, max(0, bounds.width - 24))
    let inline = width <= trailing - leading
    let height = min(PreferencesController.menuBarToolsHeightBudget, tool.fittingSize.height)
    tool.frame = .init(
      x: inline ? trailing - width : 12, y: inline ? (38 - height) / 2 : 46,
      width: width, height: height)
    let total: CGFloat = inline ? 38 : PreferencesController.menuBarHeaderHeightBudget
    if contentHeight.constant != total { contentHeight.constant = total }
  }
}
