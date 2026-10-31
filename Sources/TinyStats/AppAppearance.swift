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

/// Same renderers and dimensions as the real status items, including individual-item padding.
@MainActor final class MenuBarPreviewView: NSView {
  private(set) var renderers: [MenuBarReadoutView] = []
  private(set) var preferredWidth: CGFloat = 0
  func update(
    groups: [[MenuBarReadout]], paused: Bool, height: CGFloat, spacing: MenuBarSpacing = .standard
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
    for (renderer, readings) in zip(renderers, groups) {
      renderer.spacing = spacing
      renderer.readouts = readings
      renderer.paused = paused
      renderer.frame = .init(
        x: x, y: max(0, (36 - height) / 2), width: renderer.preferredWidth, height: height)
      renderer.needsDisplay = true
      x += renderer.preferredWidth
    }
    preferredWidth = x
  }
}
