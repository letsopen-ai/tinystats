import AppKit

/// A normal persistent window. A retained closed NSWindow must not retain its page tree.
@MainActor final class MainWindow: NSWindow {
  private var contentLayoutObservation: NSKeyValueObservation?
  // Full-size content uses frame dimensions; preserve the pre-polish outer height.
  static let minimumSize = NSSize(width: 884, height: 692)
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
    // The empty unified native toolbar places traffic lights inside the floating
    // sidebar's rounded top inset and keeps that band draggable. No toolbar items.
    toolbarStyle = .unified
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
  struct TitlebarGeometry {
    let nativeInset: CGFloat
    let brandTop: CGFloat
    // Page titles have a 22pt internal top inset. Share their top line with the brand.
    var pageInset: CGFloat { max(0, brandTop - 22) }
  }

  /// Pure geometry seam: full-screen toolbar buttons belong to another window.
  static func titlebarGeometry(
    bounds: NSRect, layoutRect: NSRect, isFullScreen: Bool, buttonFrames: [NSRect]
  ) -> TitlebarGeometry {
    let nativeInset = min(bounds.height, max(0, bounds.maxY - layoutRect.maxY))
    let buttonBottom = isFullScreen ? nil : buttonFrames.map(\.minY).min()
    let lightsInset = buttonBottom.map { max(0, bounds.maxY - $0) } ?? nativeInset
    return .init(nativeInset: nativeInset, brandTop: lightsInset + 12)
  }

  static func localButtonFrames(in view: NSView, buttons: [NSButton]) -> [NSRect] {
    guard let window = view.window else { return [] }
    return buttons.filter { !$0.isHidden && $0.window === window }
      .map { view.convert($0.bounds, from: $0) }
  }

  static func titlebarGeometry(in view: NSView) -> TitlebarGeometry {
    guard let window = view.window, window.styleMask.contains(.fullSizeContentView) else {
      return .init(nativeInset: 0, brandTop: 17)
    }
    let layout = view.convert(window.contentLayoutRect, from: nil)
    let buttons =
      [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { window.standardWindowButton($0) }
    let fullScreen = window.styleMask.contains(.fullScreen)
    return titlebarGeometry(
      bounds: view.bounds, layoutRect: layout, isFullScreen: fullScreen,
      buttonFrames: fullScreen ? [] : localButtonFrames(in: view, buttons: buttons))
  }

  static func topContentInset(in view: NSView) -> CGFloat {
    titlebarGeometry(in: view).nativeInset
  }

  static func pageContentInset(in view: NSView) -> CGFloat {
    titlebarGeometry(in: view).pageInset
  }

  override func close() {
    super.close()
    contentViewController = nil
    contentView = nil
  }
}
