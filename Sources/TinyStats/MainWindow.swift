import AppKit

/// A normal persistent window. A retained closed NSWindow must not retain its page tree.
@MainActor final class MainWindow: NSWindow {
  private var contentLayoutObservation: NSKeyValueObservation?
  static let minimumSize = NSSize(width: 884, height: 660)
  init() {
    super.init(
      contentRect: .init(origin: .zero, size: Self.minimumSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    title = "TinyStats"
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    // The empty compact native toolbar places traffic lights inside the floating
    // sidebar's rounded top inset and keeps that band draggable. No toolbar items.
    toolbarStyle = .unifiedCompact
    let titlebar = NSToolbar(identifier: "TinyStatsMainTitlebar")
    titlebar.showsBaselineSeparator = false
    toolbar = titlebar
    // Let the sidebar glass sample behind the window; the root paints all other regions.
    isOpaque = false
    backgroundColor = .clear
    contentMinSize = Self.minimumSize
    isReleasedWhenClosed = false
    // Toolbar/full-screen layout can change without changing the content bounds.
    contentLayoutObservation = observe(\.contentLayoutRect) { window, _ in
      MainActor.assumeIsolated { window.contentView?.needsLayout = true }
    }
  }
  /// Native titlebar geometry includes toolbar/full-screen changes. Buttons are converted
  /// through their actual ancestors rather than assuming the host OS's titlebar height.
  static func topContentInset(in view: NSView) -> CGFloat {
    guard let window = view.window, window.styleMask.contains(.fullSizeContentView) else {
      return 0
    }
    let layout = view.convert(window.contentLayoutRect, from: nil)
    let buttonBottom =
      [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { window.standardWindowButton($0) }
      .filter { !$0.isHidden }
      .map { view.convert($0.bounds, from: $0).minY }.min() ?? view.bounds.maxY
    return max(0, view.bounds.maxY - min(layout.maxY, buttonBottom))
  }

  override func close() {
    super.close()
    contentViewController = nil
    contentView = nil
  }
}
