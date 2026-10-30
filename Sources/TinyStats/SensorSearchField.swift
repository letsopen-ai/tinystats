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
  var horizontalCellInset: CGFloat = 0 { didSet { needsLayout = true } }
  var selectionRect: NSRect { bounds.insetBy(dx: 4, dy: 1) }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    for column in 0..<numberOfColumns {
      guard let field = view(atColumn: column) as? NSTextField,
        let table = superview as? NSTableView
      else { continue }
      let index = table.row(for: self)
      guard index >= 0 else { continue }
      // AppKit stretches a bare text field to the row height; its text stays top-aligned.
      // Keep the text's intrinsic height and centre it on the same rect we highlight.
      var frame = convert(table.frameOfCell(atColumn: column, row: index), from: table)
        .insetBy(dx: horizontalCellInset, dy: 0)
      frame.size.height = min(field.fittingSize.height, selectionRect.height)
      frame.origin.y = selectionRect.midY - frame.height / 2
      field.frame = frame
    }
  }

  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    (isEmphasized
      ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor)
      .setFill()
    NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6).fill()
  }
}
