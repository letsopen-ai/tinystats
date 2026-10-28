import AppKit
import TinyStatsCore

/// One immediate-mode drawing per reused table cell. No layers, animations, or progress timers.
@MainActor final class UtilizationMeterCell: NSView {
  private(set) var reading: Double?
  private(set) var tint = NSColor.systemBlue
  private(set) var text = "—"
  private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  nonisolated static func normalized(_ value: Double?) -> Double? {
    value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
  }
  func update(label: String, reading: Double?, color: NSColor, text: String? = nil) {
    self.reading = Self.normalized(reading)
    tint = color
    self.text = self.reading == nil ? "—" : text ?? Display.percent(self.reading)
    setAccessibilityLabel(label)
    setAccessibilityValue(self.text)
    toolTip = "\(label): \(self.text)"
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(rect: bounds).addClip()
    let string = text as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.font, .foregroundColor: NSColor.labelColor,
    ]
    let size = string.size(withAttributes: attributes)
    let track = NSRect(
      x: 10, y: bounds.midY - 3,
      width: max(0, bounds.width - max(54, size.width) - 22), height: 6)
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
    if let reading, reading > 0 {
      tint.setFill()
      NSBezierPath(
        roundedRect: .init(
          x: track.minX, y: track.minY,
          width: track.width * reading / 100, height: track.height), xRadius: 3, yRadius: 3
      ).fill()
    }
    string.draw(
      at: .init(x: bounds.maxX - size.width - 2, y: bounds.midY - size.height / 2),
      withAttributes: attributes)
  }
}
