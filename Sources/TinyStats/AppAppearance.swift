import AppKit
import TinyStatsCore

extension CPUCoreKind {
  var chartColor: NSColor {
    SystemStyle.core(self)
  }
  var chartTitle: String { self == .unknown ? "Unclassified" : title }
}

extension AppTheme {
  /// Apply to TinyStats content windows, never to macOS's menu bar hosting window.
  var nativeAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

/// Shared template glyphs: detached native items versus readouts inside a single item.
@MainActor enum MenuBarLayoutIcons {
  static func control() -> NSSegmentedControl {
    let control = NSSegmentedControl(
      images: [image(separate: true), image(separate: false)],
      trackingMode: .selectOne, target: nil, action: nil)
    control.controlSize = .small
    control.segmentStyle = .rounded
    for (index, title) in ["Separate", "One"].enumerated() {
      control.setWidth(34, forSegment: index)
      control.setToolTip(title, forSegment: index)
    }
    control.setAccessibilityLabel("Menu bar layout")
    return control
  }

  private static func image(separate: Bool) -> NSImage {
    let image = NSImage(size: .init(width: 21, height: 14), flipped: false) { _ in
      NSColor.black.setFill()
      NSColor.black.setStroke()
      if separate {
        for x in [1.0, 8.0, 15.0] {
          NSBezierPath(
            roundedRect: .init(x: x, y: 2, width: 5, height: 10), xRadius: 1.5, yRadius: 1.5
          ).fill()
        }
      } else {
        let outline = NSBezierPath(
          roundedRect: .init(x: 0.5, y: 1.5, width: 20, height: 11), xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1
        outline.stroke()
        for x in [4.0, 9.0, 14.0] {
          NSBezierPath(
            roundedRect: .init(x: x, y: 4, width: 3, height: 6), xRadius: 0.5, yRadius: 0.5
          ).fill()
        }
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = separate ? "Separate" : "One"
    return image
  }
}

/// Production readout dimensions with preview-only native-item gaps and boundary outlines.
@MainActor final class MenuBarPreviewView: NSView {
  private(set) var renderers: [MenuBarReadoutView] = []
  private(set) var preferredWidth: CGFloat = 0
  static let nativeItemGap: CGFloat = 9
  /// Keep preview ink clear of its outline without changing production readout geometry.
  private static let outlineInset: CGFloat = 1.5
  func update(
    groups: [[MenuBarReadout]], paused: Bool, height: CGFloat, weight: MenuBarWeight = .regular
  ) {
    if renderers.count != groups.count {
      for renderer in renderers { renderer.removeFromSuperview() }
      renderers = groups.map { _ in
        let view = MenuBarReadoutView()
        addSubview(view)
        return view
      }
    }
    var x: CGFloat = 0
    for (index, pair) in zip(renderers, groups).enumerated() {
      let (renderer, readings) = pair
      if index > 0 { x += Self.nativeItemGap }
      x += Self.outlineInset
      renderer.weight = weight
      renderer.readouts = readings
      renderer.paused = paused
      renderer.frame = .init(
        x: x, y: max(0, (36 - height) / 2), width: renderer.preferredWidth, height: height)
      renderer.needsDisplay = true
      x += renderer.preferredWidth + Self.outlineInset
    }
    preferredWidth = x
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.labelColor.withAlphaComponent(0.06).setStroke()
    for renderer in renderers {
      let outline = NSBezierPath(
        roundedRect: renderer.frame.insetBy(dx: 0.5 - Self.outlineInset, dy: 0.5),
        xRadius: 4, yRadius: 4)
      outline.lineWidth = 1
      outline.stroke()
    }
  }
}
