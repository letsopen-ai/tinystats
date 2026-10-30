import AppKit

/// Preserve the native search/edit/cancel control and its keyboard loop; only replace the bezel.
@MainActor final class SensorSearchField: NSSearchField {
  var usesNeutralFill = false
  override func draw(_ dirtyRect: NSRect) {
    guard usesNeutralFill else {
      super.draw(dirtyRect)
      return
    }
    SystemStyle.drawPlatter(bounds)
    cell?.drawInterior(withFrame: bounds, in: self)
  }
}

/// Plain table geometry keeps the value gutter intact, with native source-list selection ink.
@MainActor final class SensorBrowserRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    (isEmphasized
      ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor)
      .setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
  }
}
