import AppKit
import TinyStatsCore

/// Bounded, local-only toolbar customization. Hover/cancellation never edits preferences.
@MainActor final class MenuBarCustomization: SystemStyledView {
  static let pasteboardType = NSPasteboard.PasteboardType("com.tinystats.private.readout")
  private let token = UUID().uuidString
  private let stripScroll = NSScrollView()
  let strip = MenuBarDropArea(inMenuBar: true)
  let palette = MenuBarDropArea(inMenuBar: false)
  private(set) var chips: [Module: MenuBarChip] = [:]
  private(set) var order: [Module] = []
  var onAction: ((Module, MenuBarLayoutAction) -> Bool)?
  private let stripLabel = SystemSettingsForm.text("In menu bar", heading: true)
  private let paletteLabel = SystemSettingsForm.text("Available", heading: true)
  private let hint = SystemSettingsForm.text(
    "Drag to rearrange; drop on Available to hide an item. Press Option + arrow keys to move the selected item. Right-click for all actions."
  )
  private(set) var lastAnnouncement = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    heightAnchor.constraint(equalToConstant: 254).isActive = true
    strip.owner = self
    palette.owner = self
    stripScroll.documentView = strip
    stripScroll.hasHorizontalScroller = true
    stripScroll.autohidesScrollers = true
    stripScroll.scrollerStyle = .overlay
    stripScroll.drawsBackground = false
    stripScroll.setAccessibilityLabel("In menu bar")
    for view in [stripLabel, stripScroll, paletteLabel, palette, hint] { addSubview(view) }
    for module in Module.allCases where module != .overview {
      let chip = MenuBarChip(module: module)
      chip.owner = self
      chips[module] = chip
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    stripLabel.frame = .init(x: 12, y: 10, width: bounds.width - 24, height: 18)
    stripScroll.frame = .init(x: 12, y: 33, width: bounds.width - 24, height: 54)
    strip.frame.size = .init(width: max(stripScroll.bounds.width, strip.contentWidth), height: 54)
    paletteLabel.frame = .init(x: 12, y: 99, width: bounds.width - 24, height: 18)
    palette.frame = .init(x: 12, y: 122, width: bounds.width - 24, height: 84)
    hint.frame = .init(x: 12, y: 217, width: bounds.width - 24, height: 30)
  }
  override func draw(_ dirtyRect: NSRect) {
    SystemStyle.drawPlatter(bounds)
  }
  func update(order: [Module], animated: Bool = false) {
    guard self.order != order || chips.values.contains(where: { $0.superview == nil }) else {
      return
    }
    let focused = window?.firstResponder as? MenuBarChip
    let oldFrames = chips.mapValues { ($0.superview, $0.frame) }
    self.order = order
    strip.setChips(order.compactMap { chips[$0] })
    palette.setChips(
      Module.allCases.filter { $0 != .overview && !order.contains($0) }.compactMap {
        chips[$0]
      })
    for chip in chips.values { chip.refreshActions() }
    needsLayout = true
    layoutSubtreeIfNeeded()
    if animated {
      for (module, chip) in chips {
        if let old = oldFrames[module], old.0 === chip.superview { chip.frame = old.1 }
      }
    }
    strip.positionChips(animated: animated)
    palette.positionChips(animated: animated)
    if let focused, focused.owner === self { window?.makeFirstResponder(focused) }
    window?.recalculateKeyViewLoop()
  }
  @discardableResult func perform(_ action: MenuBarLayoutAction, for module: Module) -> Bool {
    let changed = onAction?(module, action) ?? false
    if changed {
      if let index = order.firstIndex(of: module) {
        lastAnnouncement = "\(module.title) in menu bar, position \(index + 1) of \(order.count)."
      } else {
        lastAnnouncement = "\(module.title) removed from menu bar."
      }
    } else if order == [module] && (action == .remove || action == .toggle) {
      lastAnnouncement = "Keep at least one readout enabled so TinyStats remains accessible."
    } else {
      return false
    }
    NSAccessibility.post(
      element: NSApplication.shared, notification: .announcementRequested,
      userInfo: [
        .announcement: lastAnnouncement, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
    return changed
  }
  func pasteboardItem(for module: Module) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(token + ":" + module.rawValue, forType: Self.pasteboardType)
    return item
  }
  func draggedModule(from sender: NSDraggingInfo) -> Module? {
    guard let source = sender.draggingSource as? MenuBarChip, source.owner === self,
      sender.draggingPasteboard.pasteboardItems?.count == 1,
      sender.draggingPasteboard.string(forType: Self.pasteboardType) == token + ":"
        + source.module.rawValue
    else { return nil }
    return source.module
  }
}

@MainActor final class MenuBarDropArea: SystemStyledView {
  weak var owner: MenuBarCustomization?
  let inMenuBar: Bool
  private(set) var chips: [MenuBarChip] = []
  private(set) var insertion: Int?
  private var targetFrames: [Module: NSRect] = [:]
  var contentWidth: CGFloat { chips.reduce(20) { $0 + $1.chipWidth + 8 } }
  override var isFlipped: Bool { true }
  init(inMenuBar: Bool) {
    self.inMenuBar = inMenuBar
    super.init(frame: .zero)
    registerForDraggedTypes([MenuBarCustomization.pasteboardType])
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(inMenuBar ? "In menu bar" : "Available")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func setChips(_ chips: [MenuBarChip]) {
    self.chips = chips
    targetFrames = targetFrames.filter { module, _ in chips.contains { $0.module == module } }
    for chip in chips where chip.superview !== self {
      chip.removeFromSuperview()
      addSubview(chip)
    }
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    positionChips(animated: false)
  }
  func positionChips(animated: Bool) {
    var x: CGFloat = 12
    var y: CGFloat = 12
    NSAnimationContext.runAnimationGroup { context in
      context.duration =
        animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0
      for chip in chips {
        let width = chip.chipWidth
        if !inMenuBar && x > 12 && x + width > bounds.width - 8 {
          x = 12
          y += 36
        }
        let frame = NSRect(x: x, y: y, width: width, height: 28)
        if animated || targetFrames[chip.module] != frame {
          targetFrames[chip.module] = frame
          if context.duration > 0 && chip.frame.width > 0 {
            chip.animator().frame = frame
          } else {
            chip.frame = frame
          }
        }
        x += width + 8
      }
    }
  }
  func insertionIndex(at point: NSPoint) -> Int {
    chips.firstIndex { point.x < $0.frame.midX } ?? chips.count
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    NSColor.labelColor.withAlphaComponent(0.06).setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 0.5
    path.stroke()
    if let insertion {
      NSColor.controlAccentColor.setFill()
      if inMenuBar {
        let x =
          insertion < chips.count
          ? chips[insertion].frame.minX - 5 : (chips.last?.frame.maxX ?? 12) + 3
        NSBezierPath(
          roundedRect: .init(x: x, y: 14, width: 2, height: 24), xRadius: 1, yRadius: 1
        ).fill()
      } else {
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
      }
    }
    if chips.isEmpty {
      let text = inMenuBar ? "Drop readouts here" : "Drag items here to hide them"
      (text as NSString).draw(
        at: .init(x: 12, y: 18),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdated(sender)
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let owner, let module = owner.draggedModule(from: sender),
      inMenuBar || (owner.order.contains(module) && owner.order.count > 1)
    else {
      clearInsertion()
      return []
    }
    if inMenuBar, let scroll = enclosingScrollView {
      // AppKit's drag updates drive edge scrolling; no view-owned timer is needed.
      let point = convert(sender.draggingLocation, from: nil)
      let visible = visibleRect
      let step: CGFloat = point.x < visible.minX + 24 ? -12 : (point.x > visible.maxX - 24 ? 12 : 0)
      if step != 0 {
        scroll.contentView.scroll(
          to: .init(
            x: min(max(0, visible.minX + step), max(0, bounds.width - visible.width)), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
    }
    insertion = inMenuBar ? insertionIndex(at: convert(sender.draggingLocation, from: nil)) : 0
    needsDisplay = true
    return .move
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { clearInsertion() }
  override func draggingEnded(_ sender: NSDraggingInfo) { clearInsertion() }
  private func clearInsertion() {
    insertion = nil
    needsDisplay = true
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    draggingUpdated(sender) == .move
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { clearInsertion() }
    guard let owner, let module = owner.draggedModule(from: sender),
      draggingUpdated(sender) == .move
    else { return false }
    let action: MenuBarLayoutAction = inMenuBar ? .add(at: insertion ?? chips.count) : .remove
    // A drop at the current position is still a valid, harmless drop.
    return owner.perform(action, for: module) || inMenuBar
  }
}

@MainActor final class MenuBarChip: NSButton, NSDraggingSource {
  let module: Module
  weak var owner: MenuBarCustomization?
  private var dragOrigin: NSPoint?
  var chipWidth: CGFloat {
    max(
      78,
      (module.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        + 39)
  }
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
  init(module: Module) {
    self.module = module
    super.init(frame: .zero)
    cell = MenuBarChipCell(textCell: module.title)
    title = module.title
    font = .systemFont(ofSize: 12)
    contentTintColor = .labelColor
    image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    imagePosition = .imageLeading
    imageScaling = .scaleProportionallyDown
    isBordered = false
    setAccessibilityLabel("\(module.title) menu bar item")
    setAccessibilityRole(.button)
    toolTip =
      "Drag to customize; Return/Space to add or remove; ⌥←/→ to move; right-click for more."
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  var availableActions: [(String, MenuBarLayoutAction, Bool)] {
    guard let order = owner?.order, let index = order.firstIndex(of: module) else {
      return [("Add to menu bar", .add(at: owner?.order.count ?? 0), true)]
    }
    return [
      ("Remove from menu bar", .remove, order.count > 1),
      ("Move left", .left, index > 0), ("Move right", .right, index < order.count - 1),
      ("Move to start", .start, index > 0), ("Move to end", .end, index < order.count - 1),
    ]
  }
  func refreshActions() {
    let inBar = owner?.order.contains(module) == true
    setAccessibilityValue(
      inBar
        ? "In menu bar, position \((owner?.order.firstIndex(of: module) ?? 0) + 1)" : "Available")
    setAccessibilityHelp(toolTip)
    setAccessibilityCustomActions(
      availableActions.filter(\.2).map { title, action, _ in
        NSAccessibilityCustomAction(name: title) { [weak self] in
          guard let self else { return false }
          return self.owner?.perform(action, for: self.module) ?? false
        }
      })
    needsDisplay = true
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for entry in availableActions {
      let item = NSMenuItem(title: entry.0, action: #selector(menuAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = entry.1
      item.isEnabled = entry.2
      menu.addItem(item)
    }
    return menu
  }
  @objc private func menuAction(_ sender: NSMenuItem) {
    guard sender.isEnabled, let action = sender.representedObject as? MenuBarLayoutAction else {
      return
    }
    owner?.perform(action, for: module)
  }
  override func accessibilityPerformPress() -> Bool {
    // Exploring a chip must not change the enabled set. Named custom actions mutate it.
    false
  }
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if [123, 124].contains(event.keyCode), !modifiers.intersection([.option, .command]).isEmpty {
      let action: MenuBarLayoutAction = event.keyCode == 123 ? .left : .right
      if owner?.perform(
        modifiers.contains(.shift) ? (event.keyCode == 123 ? .start : .end) : action, for: module)
        != true
      {
        NSSound.beep()
      }
    } else if [123, 124].contains(event.keyCode),
      modifiers.intersection([.option, .command, .control, .shift]).isEmpty,
      let owner
    {
      let peers = owner.strip.chips + owner.palette.chips
      if let index = peers.firstIndex(where: { $0 === self }) {
        let next = min(max(0, index + (event.keyCode == 123 ? -1 : 1)), peers.count - 1)
        window?.makeFirstResponder(peers[next])
      }
    } else if [36, 49, 76].contains(event.keyCode),
      modifiers.intersection([.command, .option, .control]).isEmpty
    {
      owner?.perform(.toggle, for: module)
    } else {
      super.keyDown(with: event)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    NSColor.controlBackgroundColor.setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 0.5
    path.stroke()
    super.draw(dirtyRect)
  }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { scrollToVisible(bounds) }
    return accepted
  }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
  }
  override var focusRingMaskBounds: NSRect { bounds }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    dragOrigin = convert(event.locationInWindow, from: nil)
  }
  override func mouseUp(with event: NSEvent) { dragOrigin = nil }
  override func mouseDragged(with event: NSEvent) {
    guard let origin = dragOrigin else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard hypot(point.x - origin.x, point.y - origin.y) >= 4,
      let owner, let image = dragImage()
    else { return }
    dragOrigin = nil
    let item = NSDraggingItem(pasteboardWriter: owner.pasteboardItem(for: module))
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
      .animatesToStartingPositionsOnCancelOrFail = true
  }
  /// Capture afresh for each drag, including current appearance/accent; no cached drag image.
  func dragImage() -> NSImage? {
    guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    cacheDisplay(in: bounds, to: bitmap)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(bitmap)
    return image
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// Keep native button text/symbol drawing, with enough inset for a rounded draggable chip.
@MainActor private final class MenuBarChipCell: NSButtonCell {
  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    guard let button = controlView as? NSButton else { return }
    let symbol = NSRect(x: cellFrame.minX + 10, y: cellFrame.midY - 6.5, width: 13, height: 13)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    image?.draw(in: symbol)
    NSColor.labelColor.setFill()
    symbol.fill(using: .sourceIn)
    NSGraphicsContext.current?.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
    let text = button.title as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: button.font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: .init(x: symbol.maxX + 6, y: floor(cellFrame.midY - size.height / 2)),
      withAttributes: attributes)
  }
}
