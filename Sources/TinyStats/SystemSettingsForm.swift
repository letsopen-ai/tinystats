import AppKit
import TinyStatsCore

/// The title is also the switch's stable accessibility identity; AppKit supplies switch semantics.
@MainActor final class SystemSettingSwitch: NSSwitch {
  let title: String
  init(title: String, target: AnyObject? = nil, action: Selector? = nil) {
    self.title = title
    super.init(frame: .zero)
    controlSize = .small
    self.target = target
    self.action = action
    setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func performClick(_ sender: Any?) {
    guard isEnabled else { return }
    state = state == .on ? .off : .on
    if let action { NSApp.sendAction(action, to: target, from: self) }
  }
}

/// One scrolling, inset form. Reuses the original controls, targets and permission handlers.
@MainActor final class SystemSettingsForm: NSScrollView {
  private let stack = NSStackView()
  init(in root: NSView, views: [NSView]) {
    super.init(frame: root.bounds)
    autoresizingMask = [.width, .height]
    drawsBackground = true
    backgroundColor = .windowBackgroundColor
    hasVerticalScroller = true
    autohidesScrollers = true
    borderType = .noBorder
    let document = SystemFormDocument()
    document.translatesAutoresizingMaskIntoConstraints = false
    documentView = document
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.detachesHiddenViews = true
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.autoresizingMask = []
      stack.addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    NSLayoutConstraint.activate([
      document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
      document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: contentView.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
    ])
    for child in root.subviews { child.removeFromSuperview() }
    root.addSubview(self)
    root.layoutSubtreeIfNeeded()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  static func text(_ text: String, heading: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: heading ? 13 : 11, weight: heading ? .medium : .regular)
    field.textColor = .secondaryLabelColor
    return field
  }
  static func controls(_ views: [NSView], widths: [CGFloat] = []) -> NSStackView {
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.distribution = .fill
    row.spacing = 8
    row.alignment = .centerY
    for (index, view) in views.enumerated() {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.autoresizingMask = []
      if widths.indices.contains(index) {
        view.widthAnchor.constraint(equalToConstant: widths[index]).isActive = true
      }
    }
    return row
  }
  static func actions(_ buttons: [NSButton]) -> NSStackView {
    let spacer = NSView()
    for button in buttons { button.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
    return controls([spacer] + buttons)
  }
  static func row(
    _ label: String, _ control: NSView, width: CGFloat? = nil,
    height: CGFloat = 36
  ) -> SystemFormRow {
    control.translatesAutoresizingMaskIntoConstraints = false
    control.autoresizingMask = []
    if let width { control.widthAnchor.constraint(equalToConstant: width).isActive = true }
    return SystemFormRow(label: label, control: control, minimumHeight: height)
  }
  static func group(_ rows: [SystemFormRow]) -> SystemFormSection {
    SystemFormSection(rows: rows)
  }
}

@MainActor private final class SystemFormDocument: NSView {
  override var isFlipped: Bool { true }
}

/// Neutral, appearance-aware scenery, without reading the user's wallpaper or adding a request.
@MainActor final class SystemWallpaperStrip: SystemStyledView {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: .windowBackgroundColor, ending: .tertiaryLabelColor)?
      .draw(in: bounds, angle: -25)
    NSColor.separatorColor.setStroke()
    path.lineWidth = 0.5
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// Picture choices use the production renderer, with illustrative placeholders when data is absent.
@MainActor final class SystemPresetChoices: NSControl {
  private var choices: [NSButton] = []
  var selectedSegment: Int = -1 {
    didSet {
      for (index, button) in choices.enumerated() {
        button.state = index == selectedSegment ? .on : .off
      }
    }
  }
  var segmentCount: Int { choices.count }
  func label(forSegment index: Int) -> String { choices[index].title }
  init(titles: [String], settings: [Settings], snapshot: Snapshot) {
    super.init(frame: .zero)
    for (index, title) in titles.enumerated() {
      let button = SystemPresetPicture(title: title, settings: settings[index], snapshot: snapshot)
      button.tag = index
      button.target = self
      button.action = #selector(selected(_:))
      choices.append(button)
      addSubview(button)
    }
    heightAnchor.constraint(equalToConstant: 74).isActive = true
    setAccessibilityLabel("Menu bar presets")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    let width = (bounds.width - 20) / 3
    for (index, choice) in choices.enumerated() {
      choice.frame = .init(x: CGFloat(index) * (width + 10), y: 0, width: width, height: 74)
    }
  }
  @objc private func selected(_ sender: NSButton) {
    selectedSegment = sender.tag
    if let action { NSApp.sendAction(action, to: target, from: self) }
  }
}

@MainActor private final class SystemPresetPicture: NSButton {
  override var isFlipped: Bool { false }
  private let renderer = MenuBarReadoutView()
  init(title: String, settings: Settings, snapshot: Snapshot) {
    super.init(frame: .zero)
    self.title = title
    setAccessibilityLabel(title)
    setButtonType(.toggle)
    isBordered = false
    renderer.readouts = [.cpu, .memory].map {
      MenuBarReadout.make(module: $0, snapshot: snapshot, settings: settings, history: [])
    }
    addSubview(renderer)
    renderer.onAppearanceChange = { [weak self] in self?.needsDisplay = true }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(convert(point, from: superview)) ? self : nil
  }
  override func layout() {
    super.layout()
    renderer.frame = .init(
      x: max(4, (bounds.width - renderer.preferredWidth) / 2), y: 32,
      width: renderer.preferredWidth, height: 24)
  }
  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
  }
  override func draw(_ dirtyRect: NSRect) {
    let picture = NSRect(x: 1, y: 25, width: bounds.width - 2, height: 46)
    let path = NSBezierPath(roundedRect: picture, xRadius: 7, yRadius: 7)
    NSColor.controlBackgroundColor.setFill()
    path.fill()
    (state == .on ? SystemStyle.accent : NSColor.separatorColor).setStroke()
    path.lineWidth = state == .on ? 2 : 0.5
    path.stroke()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (title as NSString).draw(
      in: .init(x: 0, y: 2, width: bounds.width, height: 18),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
      ])
  }
}

@MainActor final class SystemSettingsBackgroundView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.intersection(bounds).fill()
  }
}
