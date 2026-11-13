import AppKit
import TinyStatsCore

@MainActor enum MenuBarWeightControl {
  static func control() -> NSSegmentedControl {
    let control = NSSegmentedControl(
      images: MenuBarWeight.allCases.map { weight in
        let typography = MenuBarTypography.forWeight(weight)
        let image = NSImage(size: .init(width: 21, height: 18), flipped: false) { _ in
          ("Aa" as NSString).draw(
            at: .init(x: 1, y: 3),
            withAttributes: [
              .font: NSFont.systemFont(ofSize: 12, weight: typography.textWeight),
              .foregroundColor: NSColor.black,
            ])
          NSColor.black.setStroke()
          let line = NSBezierPath()
          line.move(to: .init(x: 2, y: 2))
          line.line(to: .init(x: 19, y: 2))
          line.lineWidth = typography.historyStroke
          line.stroke()
          return true
        }
        image.isTemplate = true
        image.accessibilityDescription = weight.title
        return image
      }, trackingMode: .selectOne, target: nil, action: nil)
    control.controlSize = .small
    control.segmentStyle = .rounded
    control.setAccessibilityLabel("Menu bar weight")
    for (index, weight) in MenuBarWeight.allCases.enumerated() {
      control.setWidth(34, forSegment: index)
      control.setToolTip(weight.title, forSegment: index)
    }
    return control
  }
}
