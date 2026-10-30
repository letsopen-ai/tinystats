import AppKit
import TinyStatsCore

enum ChartValueFormat: Equatable {
  case number, percent, rate
  case unit(String)
  case temperature(fahrenheit: Bool)
  func string(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "Unavailable" }
    switch self {
    case .number: return String(format: "%.2f", value)
    case .percent: return String(format: "%.1f%%", value)
    case .rate: return Display.rate(value)
    case .unit(let unit): return String(format: "%.2f %@", value, unit)
    case .temperature(let fahrenheit):
      return String(
        format: "%.1f°%@", fahrenheit ? value * 1.8 + 32 : value, fahrenheit ? "F" : "C")
    }
  }

  /// Summarize the retained timeline's samples or buckets, including an unavailable
  /// newest observation rather than substituting an older valid reading.
  func summary(
    _ values: [Double?], indices: Range<Int>, newestLabel: String = "Latest"
  ) -> String? {
    var minimum: Double?
    var maximum: Double?
    for index in indices where values.indices.contains(index) {
      guard let value = values[index], value.isFinite else { continue }
      minimum = minimum.map { min($0, value) } ?? value
      maximum = maximum.map { max($0, value) } ?? value
    }
    guard minimum != nil else { return nil }
    let latest = indices.last.flatMap { values.indices.contains($0) ? values[$0] : nil }
    return newestLabel + " " + string(latest) + ", min " + string(minimum) + ", max "
      + string(maximum)
  }
}

/// One tracking area and one lazily created bubble per visible chart, no timers or event monitors.
@MainActor class ChartHoverView: SystemStyledView {
  private var hoverTracking: NSTrackingArea?
  private var hoverScreenPoint: NSPoint?
  private var bubble: ChartHoverBubble?
  private weak var hoverClipView: NSClipView?
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()
  static func hoverDate(_ date: Date) -> String { dateFormatter.string(from: date) }
  func hoverText(at point: NSPoint) -> String? { nil }
  var hoverAccessibilityElement: NSView? { bubble.flatMap { $0.isHidden ? nil : $0 } }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let tracking = NSTrackingArea(
      rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
      owner: self)
    addTrackingArea(tracking)
    hoverTracking = tracking
    refreshHover()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.acceptsMouseMovedEvents = true
    observeScrolling()
  }
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    observeScrolling()
  }
  private func stopObservingScrolling() {
    if let hoverClipView {
      NotificationCenter.default.removeObserver(
        self, name: NSView.boundsDidChangeNotification, object: hoverClipView)
    }
    hoverClipView = nil
  }
  private func observeScrolling() {
    let clip = window == nil ? nil : enclosingScrollView?.contentView
    guard clip !== hoverClipView else { return }
    stopObservingScrolling()
    guard let clip else { return }
    hoverClipView = clip
    NotificationCenter.default.addObserver(
      self, selector: #selector(clipBoundsChanged(_:)),
      name: NSView.boundsDidChangeNotification, object: clip)
    clip.postsBoundsChangedNotifications = true
  }
  @objc private func clipBoundsChanged(_ notification: Notification) {
    refreshHover()
  }
  override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
  // The charts have no destructive click action. A click/drag also inspects the
  // same reading, useful with pointing devices that suppress hover movement.
  override func mouseDown(with event: NSEvent) { mouseMoved(with: event) }
  override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  override func mouseMoved(with event: NSEvent) {
    // Use the event's position: targeted native events need not move the global cursor.
    // Screen coordinates also survive clip scrolling and window movement.
    hoverScreenPoint = window?.convertPoint(toScreen: event.locationInWindow)
    refreshHover()
  }
  override func mouseExited(with event: NSEvent) {
    hoverScreenPoint = nil
    bubble?.isHidden = true
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    stopObservingScrolling()
    if newWindow == nil {
      hoverScreenPoint = nil
      bubble?.removeFromSuperview()
      bubble = nil
    }
    super.viewWillMove(toWindow: newWindow)
  }
  func refreshHover() {
    guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
      let hoverScreenPoint
    else {
      bubble?.isHidden = true
      return
    }
    let point = convert(window.convertPoint(fromScreen: hoverScreenPoint), from: nil)
    guard visibleRect.contains(point), let text = hoverText(at: point), !text.isEmpty
    else {
      bubble?.isHidden = true
      return
    }
    let view = bubble ?? ChartHoverBubble(frame: .zero)
    if bubble == nil {
      bubble = view
      addSubview(view)
    }
    view.message = text
    let visible = visibleRect.insetBy(dx: 4, dy: 4)
    let size = view.fittingSize(maximumWidth: min(360, visible.width))
    let preferredY = isFlipped ? point.y + 14 : point.y - size.height - 14
    let preferredX =
      point.x + 12 + size.width <= visible.maxX
      ? point.x + 12 : point.x - size.width - 12
    let x = min(max(visible.minX, preferredX), max(visible.minX, visible.maxX - size.width))
    let y = min(max(visible.minY, preferredY), max(visible.minY, visible.maxY - size.height))
    view.frame = .init(origin: .init(x: x, y: y), size: size)
    view.isHidden = false
  }
}

@MainActor private final class ChartHoverBubble: NSView {
  static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
  var message = "" {
    didSet {
      if oldValue != message {
        needsDisplay = true
        setAccessibilityValue(message)
      }
    }
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("Chart reading")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func fittingSize(maximumWidth: CGFloat) -> NSSize {
    let width = max(1, maximumWidth - 16)
    let rect = (message as NSString).boundingRect(
      with: .init(width: width, height: 200), options: [.usesLineFragmentOrigin],
      attributes: [.font: Self.font])
    return .init(width: min(maximumWidth, ceil(rect.width) + 16), height: ceil(rect.height) + 14)
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
    NSColor.windowBackgroundColor.setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 1
    path.stroke()
    (message as NSString).draw(
      in: bounds.insetBy(dx: 8, dy: 7),
      withAttributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
  }
}
