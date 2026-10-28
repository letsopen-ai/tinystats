import AppKit

/// A normal persistent window. A retained closed NSWindow must not retain its page tree.
@MainActor final class MainWindow: NSWindow {
  static let minimumSize = NSSize(width: 884, height: 660)
  init() {
    super.init(
      contentRect: .init(origin: .zero, size: Self.minimumSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    contentMinSize = Self.minimumSize
    isReleasedWhenClosed = false
  }
  override func close() {
    super.close()
    contentViewController = nil
    contentView = nil
  }
}
