import AppKit

/// Preserve the native search/edit/cancel control and its keyboard loop; only replace the bezel.
@MainActor final class SensorSearchField: NSSearchField {
  var usesNeutralFill = false
  var glassEnvironment: () -> GlassSurface.Environment = { .current }
  override func draw(_ dirtyRect: NSRect) {
    guard usesNeutralFill else {
      super.draw(dirtyRect)
      return
    }
    SystemStyle.drawPlatter(bounds, onGlass: true, environment: glassEnvironment())
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
  static func rowHeight(for font: NSFont) -> CGFloat {
    let cell = NSTextFieldCell(textCell: "Hg52")
    cell.font = font
    return ceil(cell.cellSize.height) + 10
  }
  private var centeredTitle: NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = lineBreakMode
    return NSAttributedString(
      string: stringValue,
      attributes: [
        .font: font ?? NSFont.systemFont(ofSize: 12),
        .foregroundColor: backgroundStyle == .emphasized
          ? NSColor.alternateSelectedControlTextColor : textColor ?? NSColor.labelColor,
        .paragraphStyle: style,
      ])
  }
  override func titleRect(forBounds rect: NSRect) -> NSRect {
    // Measure without paragraph alignment: a right-aligned measurement would include
    // the entire constraint width in its origin rather than just glyph bearings.
    let metrics = NSAttributedString(
      string: stringValue,
      attributes: [
        .font: font ?? NSFont.systemFont(ofSize: 12)
      ])
    let ink = metrics.boundingRect(
      with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesDeviceMetrics])
    let advance = metrics.size().width
    var text = rect.insetBy(dx: 12, dy: 0)
    // Align actual glyph ink, without NSTextFieldCell's extra drawing inset or side bearings.
    if alignment == .left || alignment == .natural {
      text.origin.x = (text.origin.x - ink.minX).rounded()
      text.size.width += ink.minX
    } else if alignment == .right {
      text.size.width += advance - ink.maxX
    }
    let height = ceil((font?.ascender ?? 0) - (font?.descender ?? 0) + (font?.leading ?? 0))
    text.origin.y = rect.midY - height / 2
    text.size.height = height
    return text
  }
  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    centeredTitle.draw(in: titleRect(forBounds: cellFrame))
  }
  override func select(
    withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
    delegate: Any?, start selStart: Int, length selLength: Int
  ) {
    super.select(
      withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj,
      delegate: delegate, start: selStart, length: selLength)
  }
  override func edit(
    withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
    delegate: Any?, event: NSEvent?
  ) {
    super.edit(
      withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj,
      delegate: delegate, event: event)
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
