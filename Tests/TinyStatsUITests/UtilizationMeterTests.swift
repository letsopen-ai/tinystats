import AppKit
import Testing

@testable import TinyStats

@Test @MainActor func utilizationMetersPreserveMissingReadingsAndReuseAccessibleCells() throws {
  let cell = UtilizationMeterCell(frame: .init(x: 0, y: 0, width: 230, height: 25))
  for invalid in [nil, Double.nan, .infinity, -1, 101] as [Double?] {
    cell.update(label: "Logical core 1", reading: invalid, color: .systemBlue)
    #expect(cell.reading == nil && cell.text == "—")
    #expect(cell.accessibilityValue() as? String == "—")
  }
  cell.update(label: "Logical core 2", reading: 0, color: .systemTeal)
  #expect(cell.reading == 0 && cell.text == "0%")
  #expect(cell.accessibilityLabel() == "Logical core 2")
  #expect(cell.toolTip == "Logical core 2: 0%")
  cell.update(label: "Wired", reading: 25, color: .systemOrange, text: "4 GiB")
  #expect(cell.reading == 25 && cell.text == "4 GiB")
  #expect(cell.accessibilityValue() as? String == "4 GiB")
  cell.update(label: "Missing capacity", reading: nil, color: .systemOrange, text: "0 B")
  #expect(cell.text == "—")
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    cell.appearance = NSAppearance(named: appearance)
    func coloredPixels(_ reading: Double) throws -> Int {
      cell.update(
        label: "Example", reading: reading, color: .init(srgbRed: 1, green: 0, blue: 0, alpha: 1))
      let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
      cell.cacheDisplay(in: cell.bounds, to: bitmap)
      var count = 0
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
            color.alphaComponent > 0.5, color.redComponent > 0.8,
            color.greenComponent < 0.2, color.blueComponent < 0.2
          {
            count += 1
          }
        }
      }
      return count
    }
    let low = try coloredPixels(10)
    let high = try coloredPixels(100)
    #expect(low > 0 && high > low * 5)
  }
}
