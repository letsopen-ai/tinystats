import AppKit
import TinyStatsCore

/// Central material policy. Content cards stay neutral; glass belongs to navigation surfaces.
@MainActor final class GlassSurface: NSView {
  enum Treatment: Equatable { case legacy, glass, solid }
  enum Role { case panel, sidebar, chips }
  struct Environment {
    var supportsGlass: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var treatment: Treatment {
      guard supportsGlass else { return .legacy }
      return reduceTransparency || increaseContrast ? .solid : .glass
    }
    static var current: Environment {
      let supported: Bool
      if #available(macOS 26, *) { supported = true } else { supported = false }
      return .init(
        supportsGlass: supported,
        reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
  }

  let role: Role
  private let environment: () -> Environment
  private(set) var treatment: Treatment?
  private var material: NSView?
  private var shapes: [Module: NSView] = [:]
  private var shapeFrames: [Module: NSRect] = [:]
  var onTreatmentChange: (() -> Void)?
  /// Legacy sidebar controls must remain descendants of the effect for vibrancy.
  var legacyContentView: NSView? { treatment == .legacy ? material : nil }
  static let sidebarCornerRadius: CGFloat = 18

  init(role: Role = .panel, environment: @escaping () -> Environment = { .current }) {
    self.role = role
    self.environment = environment
    super.init(frame: .zero)
    setAccessibilityElement(false)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(displayOptionsChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    updateTreatment()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
  override var isFlipped: Bool { role == .chips }
  // Decoration never intercepts drag, focus, pointer or AX interaction with its sibling controls.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard role == .sidebar, treatment == .legacy else { return nil }
    let hit = super.hitTest(point)
    return hit === self || hit === material ? nil : hit
  }
  @objc private func displayOptionsChanged() { updateTreatment() }

  private func updateTreatment() {
    let next = environment().treatment
    guard next != treatment else { return }
    material?.removeFromSuperview()
    material = nil
    shapes = [:]
    treatment = next
    switch next {
    case .glass:
      if #available(macOS 26, *) {
        if role == .chips {
          let container = NSGlassEffectContainerView()
          container.spacing = 2
          container.contentView = FlippedContent()
          material = container
        } else {
          let glass = NSGlassEffectView()
          glass.style = .regular
          glass.cornerRadius =
            role == .panel ? SystemStyle.Radius.platter : Self.sidebarCornerRadius
          glass.contentView = LegibilityBacking(role: role)
          material = glass
        }
      }
    case .legacy:
      if role != .chips {
        let effect = NSVisualEffectView()
        effect.material = role == .panel ? .popover : .sidebar
        effect.blendingMode = role == .panel ? .behindWindow : .withinWindow
        if role == .panel { effect.state = .active }
        material = effect
      }
    case .solid: break
    }
    if let material {
      material.frame = bounds
      material.autoresizingMask = [.width, .height]
      addSubview(material)
    }
    updateShapes()
    needsDisplay = true
    onTreatmentChange?()
  }

  /// Each drag area batches its neighbouring chip shapes in one native container. Controls
  /// remain siblings with their original identity/parentage. No glass under the container.
  func setChipFrames(_ frames: [Module: NSRect], animated: Bool = false) {
    guard frames != shapeFrames else { return }
    shapeFrames = frames
    updateShapes(animated: animated)
  }
  private func updateShapes(animated: Bool = false) {
    guard #available(macOS 26, *), treatment == .glass,
      let container = material as? NSGlassEffectContainerView, let content = container.contentView
    else { return }
    for module in Array(shapes.keys) where shapeFrames[module] == nil {
      shapes.removeValue(forKey: module)?.removeFromSuperview()
    }
    for module in Module.allCases {
      guard let frame = shapeFrames[module] else { continue }
      let shape: NSView
      if let existing = shapes[module] {
        shape = existing
      } else {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = SystemStyle.Radius.control
        glass.identifier = .init(module.rawValue)
        content.addSubview(glass)
        shapes[module] = glass
        shape = glass
      }
      if animated && shape.frame.width > 0 {
        shape.animator().frame = frame
      } else {
        shape.frame = frame
      }
    }
  }
  override var isOpaque: Bool { treatment == .solid && role == .panel }
  override func draw(_ dirtyRect: NSRect) {
    guard treatment == .solid, role != .chips else { return }
    (role == .sidebar ? NSColor.controlBackgroundColor : .windowBackgroundColor).setFill()
    if role == .sidebar {
      NSBezierPath(
        roundedRect: bounds, xRadius: Self.sidebarCornerRadius,
        yRadius: Self.sidebarCornerRadius
      ).fill()
      NSColor.separatorColor.setStroke()
      let rim = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
        xRadius: Self.sidebarCornerRadius, yRadius: Self.sidebarCornerRadius)
      rim.lineWidth = 1
      rim.stroke()
    } else {
      dirtyRect.intersection(bounds).fill()
    }
  }
  static func washOpacity(role: Role, dark: Bool) -> CGFloat {
    role == .panel ? (dark ? 0.94 : 0.88) : (dark ? 0.85 : 0.80)
  }
  @MainActor private final class FlippedContent: NSView {
    override var isFlipped: Bool { true }
  }
  @MainActor private final class LegibilityBacking: NSView {
    let role: Role
    init(role: Role) {
      self.role = role
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.windowBackgroundColor.withAlphaComponent(
        GlassSurface.washOpacity(role: role, dark: SystemStyle.isDark(effectiveAppearance))
      ).setFill()
      dirtyRect.intersection(bounds).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      needsDisplay = true
    }
  }
}
