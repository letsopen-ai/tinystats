import AppKit

/// One material layer for the dropdown, including the footer. Inset cards stay neutral.
/// Keep the policy separate so older-OS and accessibility choices can be tested on a new OS.
@MainActor final class GlassSurface: NSView {
  enum Treatment: Equatable {
    case legacy, glass, solid
  }

  struct Environment {
    var supportsGlass: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool

    var treatment: Treatment {
      guard supportsGlass else { return .legacy }
      return reduceTransparency || increaseContrast ? .solid : .glass
    }

    static var current: Environment {
      let supportsGlass: Bool
      if #available(macOS 27, *) {
        supportsGlass = true
      } else {
        supportsGlass = false
      }
      return Environment(
        supportsGlass: supportsGlass,
        reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
  }

  private let environment: () -> Environment
  private(set) var treatment: Treatment?
  private var material: NSView?

  init(environment: @escaping () -> Environment = { .current }) {
    self.environment = environment
    super.init(frame: .zero)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(displayOptionsChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    updateTreatment()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

  @objc private func displayOptionsChanged() { updateTreatment() }

  private func updateTreatment() {
    let next = environment().treatment
    guard next != treatment else { return }
    material?.removeFromSuperview()
    material = nil
    treatment = next
    switch next {
    case .glass:
      if #available(macOS 27, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = SystemStyle.Radius.platter
        // Only the documented contentView belongs inside the native effect. The existing
        // controller content remains above this background as siblings, with unchanged focus/AX.
        glass.contentView = LegibilityBacking()
        material = glass
      }
    case .legacy:
      let effect = NSVisualEffectView()
      effect.material = .popover
      effect.blendingMode = .behindWindow
      effect.state = .active
      material = effect
    case .solid:
      break
    }
    if let material {
      material.frame = bounds
      material.autoresizingMask = [.width, .height]
      addSubview(material)
    }
    needsDisplay = true
  }

  override var isOpaque: Bool { treatment == .solid }
  override func draw(_ dirtyRect: NSRect) {
    guard treatment == .solid else { return }
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }

  /// Bound backdrop colour behind small monitoring text. Resolve semantic ink at draw time;
  /// a copied native tint can otherwise keep its initial appearance across theme changes.
  @MainActor private final class LegibilityBacking: NSView {
    override func draw(_ dirtyRect: NSRect) {
      NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
      dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      needsDisplay = true
    }
  }
}
