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

/// Sensors use plain labels only; process app, meter and grouping cells keep their own layout.
@MainActor final class SensorBrowserTextField: NSTextField {
  override class var cellClass: AnyClass? {
    get { SensorBrowserTextFieldCell.self }
    set { super.cellClass = newValue }
  }
}

/// AppKit owns the field frame during tiling/reload; centre the text in every supplied frame.
@MainActor final class SensorBrowserTextFieldCell: NSTextFieldCell {
  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    var text = super.drawingRect(forBounds: rect.insetBy(dx: 12, dy: 0))
    // Keep the natural height, including for larger fonts, rather than clipping to the pill.
    let height = super.cellSize(
      forBounds: .init(x: 0, y: 0, width: text.width, height: .greatestFiniteMagnitude)
    ).height
    text.origin.y = rect.midY - height / 2
    text.size.height = height
    return text
  }
}

/// Plain table geometry keeps the value gutter intact, with native source-list selection ink.
@MainActor final class SensorBrowserRowView: NSTableRowView {
  var selectionRect: NSRect { bounds.insetBy(dx: 4, dy: 1) }

  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    (isEmphasized
      ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor)
      .setFill()
    NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6).fill()
  }
}
