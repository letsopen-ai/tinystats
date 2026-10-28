import AppKit

/// Per-view immutable text attributes using the supplied colors, without caching strings or geometry.
@MainActor final class TextDrawingStyles {
  static let capacity = 64
  private struct Key: Hashable {
    let color: NSColor
    let size: CGFloat
    let weight: CGFloat
    let alignment: Int
  }
  private var entries: [Key: [NSAttributedString.Key: Any]] = [:]
  var count: Int { entries.count }

  func reset() { entries.removeAll(keepingCapacity: true) }

  func attributes(
    color: NSColor, size: CGFloat, weight: NSFont.Weight, alignment: NSTextAlignment
  ) -> [NSAttributedString.Key: Any] {
    let key = Key(
      color: color, size: size, weight: weight.rawValue, alignment: alignment.rawValue)
    if let cached = entries[key] { return cached }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
      .foregroundColor: color, .paragraphStyle: paragraph.copy() as! NSParagraphStyle,
    ]
    // An unusual style still draws correctly after the bound; it just isn't retained.
    if entries.count < Self.capacity { entries[key] = attributes }
    return attributes
  }
}
