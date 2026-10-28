import AppKit

/// Resolve one row's color once; replace only its alpha without deriving a new NSColor per cell.
@MainActor struct HistoryHeatmapFill {
  private let color: NSColor
  private let context: CGContext?
  private let colorSpace: CGColorSpace?
  private var components: [CGFloat]
  init(_ color: NSColor) {
    self.color = color
    let resolved = color.cgColor
    let values = resolved.components ?? []
    if let context = NSGraphicsContext.current?.cgContext, let space = resolved.colorSpace,
      space.model != .pattern, values.count == space.numberOfComponents + 1
    {
      self.context = context
      colorSpace = space
      components = values
    } else {
      context = nil
      colorSpace = nil
      components = []
    }
  }
  mutating func fill(_ rect: NSRect, opacity: CGFloat) {
    if let context, let colorSpace {
      components[components.count - 1] = opacity
      context.setFillColorSpace(colorSpace)
      components.withUnsafeBufferPointer { context.setFillColor($0.baseAddress!) }
    } else {
      color.withAlphaComponent(opacity).setFill()
    }
    rect.fill()
  }
}
