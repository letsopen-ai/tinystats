// Single source of truth for TinyStats brand artwork ("Lowercase t."). The icon geometry, in
// a 1024-unit y-down grid, is filled with CoreGraphics and serialized to SVG; the wordmark
// is laid out with CoreText and outlined into the SVGs.
//
//   swift scripts/create-icon.swift <dir>.iconset   10 app icon PNGs (16-512@2x)
//   swift scripts/create-icon.swift --svg <dir>     logo.svg, logo-dark.svg, logo-mark.svg
//   swift scripts/create-icon.swift --brand <dir>   social-preview.png, preview.png
//   swift scripts/create-icon.swift --check <dir>   16 and 32 px at 16x, for review (not committed)
//
// scripts/generate-brand.sh runs the first three and rebuilds Resources/TinyStats.icns.
import AppKit
import CoreText

struct Point { var x: Double, y: Double }
func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
func * (k: Double, a: Point) -> Point { Point(x: k * a.x, y: k * a.y) }

enum Segment {
  case move(Point)
  case line(Point)
  case curve(Point, Point, Point)
  case close
}

/// Rounded rectangle with Figma-style corner smoothing (0 = circular, 0.6 = Apple-like
/// continuous corners). Every segment is a cubic, so SVG and CoreGraphics match exactly.
func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, r: Double, smoothing: Double)
  -> [Segment]
{
  let theta = 90 * (1 - smoothing) * .pi / 180  // circular arc sweep
  let alpha = (.pi / 2 - theta) / 2  // angle covered by each smoothing curve
  let p = min((1 + smoothing) * r, min(w, h) / 2)
  let arcLength = sin(theta / 2) * r * 2.0.squareRoot()
  let beta = .pi / 4 * smoothing
  let c = r * tan(alpha / 2) * cos(beta)
  let d = c * tan(beta)
  let b = (p - arcLength - c - d) / 3
  let a = 2 * b
  let k = 4.0 / 3 * tan(theta / 4)
  // Corners clockwise from top-right: corner point, incoming edge direction u, outgoing v.
  let corners: [(Point, Point, Point)] = [
    (Point(x: x + w, y: y), Point(x: 1, y: 0), Point(x: 0, y: 1)),
    (Point(x: x + w, y: y + h), Point(x: 0, y: 1), Point(x: -1, y: 0)),
    (Point(x: x, y: y + h), Point(x: -1, y: 0), Point(x: 0, y: -1)),
    (Point(x: x, y: y), Point(x: 0, y: -1), Point(x: 1, y: 0)),
  ]
  var path: [Segment] = []
  for (index, (corner, u, v)) in corners.enumerated() {
    let start = corner + (-p) * u
    path.append(index == 0 ? .move(start) : .line(start))
    let center = corner + (-r) * u + r * v
    func onArc(_ phi: Double) -> Point { center + (r * sin(phi)) * u + (-r * cos(phi)) * v }
    func tangent(_ phi: Double) -> Point { cos(phi) * u + sin(phi) * v }
    let e1 = onArc(alpha)
    let e2 = onArc(alpha + theta)
    if smoothing > 0 {
      path.append(.curve(start + a * u, start + (a + b) * u, e1))
    }
    path.append(.curve(e1 + (k * r) * tangent(alpha), e2 + (-k * r) * tangent(alpha + theta), e2))
    if smoothing > 0 {
      let end = corner + p * v
      path.append(.curve(e2 + d * u + c * v, e2 + d * u + (b + c) * v, end))
    }
  }
  path.append(.close)
  return path
}

func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Segment] {
  [
    .move(Point(x: x, y: y)), .line(Point(x: x + w, y: y)), .line(Point(x: x + w, y: y + h)),
    .line(Point(x: x, y: y + h)), .close,
  ]
}

struct RGB {
  var hex: String
  var ns: NSColor {
    let v = Int(hex.dropFirst(), radix: 16)!
    return NSColor(
      srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
      blue: CGFloat(v & 255) / 255, alpha: 1)
  }
}

// Palette (docs/brand/README.md).
let paperTop = RGB(hex: "#FFFFFF")
let paperBottom = RGB(hex: "#E2E6EA")
let guideGrey = RGB(hex: "#C9D0D7")
let ink = RGB(hex: "#1D2228")
let frost = RGB(hex: "#F3F5F7")
let mintDeep = RGB(hex: "#17A673")
let tinyGreyLight = RGB(hex: "#6E7781")
let tinyGreyDark = RGB(hex: "#9AA3AE")
let paperBackground = RGB(hex: "#F5F6F8")  // light presentation background
let nightBackground = RGB(hex: "#15181C")  // dark presentation background

enum Paint {
  case solid(RGB)
  case vertical(RGB, RGB, Double, Double)
}
struct Shape { var name: String, path: [Segment], paint: Paint, shadow: Bool = false }

let regularBody = roundedRect(100, 100, 824, 824, r: 185.4, smoothing: 0.6)
let smallBody = roundedRect(64, 64, 896, 896, r: 200, smoothing: 0.6)

/// A square-cut lowercase t in 1024 units (y-down). The stem rises above the crossbar; at
/// the baseline it turns right into a foot. Radii of 0 leave the foot's corners square.
struct TGlyph {
  var stemX: Double, stemW: Double
  var top: Double  // ascender top
  var xTop: Double, barH: Double  // crossbar top (= x-height) and thickness
  var barL: Double, barR: Double  // crossbar left and right ends
  var base: Double  // baseline
  var footEnd: Double, footH: Double  // foot right end and thickness
  var rOuter: Double, rInner: Double  // foot corner radii

  var bar: [Segment] { box(barL, xTop, barR - barL, barH) }

  /// Stem and foot as one outline, clockwise from the stem's top-left corner.
  var stem: [Segment] {
    let k = 0.5522847498  // quarter circle as a cubic
    let r = stemX + stemW
    let footTop = base - footH
    var path: [Segment] = [
      .move(Point(x: stemX, y: top)), .line(Point(x: r, y: top)),
      .line(Point(x: r, y: footTop - rInner)),
    ]
    if rInner > 0 {
      path.append(
        .curve(
          Point(x: r, y: footTop - rInner * (1 - k)), Point(x: r + rInner * (1 - k), y: footTop),
          Point(x: r + rInner, y: footTop)))
    }
    path += [.line(Point(x: footEnd, y: footTop)), .line(Point(x: footEnd, y: base))]
    path.append(.line(Point(x: stemX + rOuter, y: base)))
    if rOuter > 0 {
      path.append(
        .curve(
          Point(x: stemX + rOuter * (1 - k), y: base), Point(x: stemX, y: base - rOuter * (1 - k)),
          Point(x: stemX, y: base - rOuter)))
    }
    path.append(.close)
    return path
  }
}

let masterT = TGlyph(
  stemX: 376, stemW: 96, top: 248, xTop: 340, barH: 96, barL: 280, barR: 584, base: 700,
  footEnd: 584, footH: 96, rOuter: 120, rInner: 36)

/// The icon drawn at `pixels` (the 1024 master for anything over 32). Guide ticks mark the
/// cap height and baseline; the t's ascender stops short of the cap line and its crossbar
/// sits at x-height.
func icon(_ pixels: Int, guides: Bool = true) -> [Shape] {
  if pixels <= 32 {
    // Dedicated pixel-snapped masters (16 px: 64 units = 1 px; 32 px: 32 units = 1 px).
    // Every glyph edge lands on a whole pixel, so the turn has no antialiased notch.
    let tiny = pixels <= 16
    let u = tiny ? 64.0 : 32.0
    // 16 px: 2 px stem and crossbar, a 2 px deep foot continuous with the stem (no
    // missing corner pixel), 2 x 2 px dot a full 2 px clear of the foot. 32 px: 3 px
    // strokes, square foot, 3 x 3 px dot.
    let t =
      tiny
      ? TGlyph(
        stemX: 5 * u, stemW: 2 * u, top: 3 * u, xTop: 5 * u, barH: 2 * u, barL: 3 * u,
        barR: 9 * u, base: 12 * u, footEnd: 9 * u, footH: 2 * u, rOuter: 0, rInner: 0)
      : TGlyph(
        stemX: 11 * u, stemW: 3 * u, top: 7 * u, xTop: 11 * u, barH: 3 * u, barL: 8 * u,
        barR: 18 * u, base: 25 * u, footEnd: 18 * u, footH: 3 * u, rOuter: 0, rInner: 0)
    let dot = tiny ? box(11 * u, 10 * u, 2 * u, 2 * u) : box(21 * u, 22 * u, 3 * u, 3 * u)
    return [
      Shape(name: "body", path: smallBody, paint: .vertical(paperTop, paperBottom, 64, 960)),
      Shape(name: "bar", path: t.bar, paint: .solid(ink)),
      Shape(name: "stem", path: t.stem, paint: .solid(ink)),
      Shape(name: "dot", path: dot, paint: .solid(mintDeep)),
    ]
  }
  var shapes = [
    Shape(
      name: "body", path: regularBody, paint: .vertical(paperTop, paperBottom, 100, 924),
      shadow: true)
  ]
  if guides && pixels >= 64 {
    var ticks: [Segment] = []
    for y in [176.0, 696.0] { ticks += box(196, y, 60, 8) + box(768, y, 60, 8) }
    shapes.append(Shape(name: "guides", path: ticks, paint: .solid(guideGrey)))
  }
  shapes += [
    Shape(name: "bar", path: masterT.bar, paint: .solid(ink)),
    Shape(name: "stem", path: masterT.stem, paint: .solid(ink)),
    Shape(
      name: "dot", path: roundedRect(648, 604, 96, 96, r: 22, smoothing: 0.6),
      paint: .solid(mintDeep)),
  ]
  return shapes
}

// MARK: CoreGraphics

func cgPath(_ segments: [Segment]) -> CGPath {
  let path = CGMutablePath()
  for segment in segments {
    switch segment {
    case .move(let p): path.move(to: CGPoint(x: p.x, y: p.y))
    case .line(let p): path.addLine(to: CGPoint(x: p.x, y: p.y))
    case .curve(let c1, let c2, let p):
      path.addCurve(
        to: CGPoint(x: p.x, y: p.y), control1: CGPoint(x: c1.x, y: c1.y),
        control2: CGPoint(x: c2.x, y: c2.y))
    case .close: path.closeSubpath()
    }
  }
  return path
}

/// Draws shapes (1024 grid) into a y-up context at `origin` with side `size` (points).
func draw(_ shapes: [Shape], in cg: CGContext, origin: CGPoint, size: CGFloat, deviceScale: CGFloat)
{
  let s = size / 1024
  for shape in shapes {
    cg.saveGState()
    cg.translateBy(x: origin.x, y: origin.y + size)
    cg.scaleBy(x: s, y: -s)
    let path = cgPath(shape.path)
    if shape.shadow {
      // Shadow offsets/blur are in device space. SVG twin: dy 10, stdDeviation 12.
      cg.setShadow(
        offset: CGSize(width: 0, height: -10 * s * deviceScale), blur: 24 * s * deviceScale,
        color: NSColor(white: 0, alpha: 0.3).cgColor)
      cg.addPath(path)
      cg.setFillColor(paperBottom.ns.cgColor)
      cg.fillPath()
      cg.setShadow(offset: .zero, blur: 0, color: nil)
    }
    cg.addPath(path)
    switch shape.paint {
    case .solid(let color):
      cg.setFillColor(color.ns.cgColor)
      cg.fillPath()
    case .vertical(let top, let bottom, let y0, let y1):
      cg.clip()
      let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [top.ns.cgColor, bottom.ns.cgColor] as CFArray, locations: [0, 1])!
      cg.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    }
    cg.restoreGState()
  }
}

func bitmapRep(_ width: Int, _ height: Int, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = context
  body(context.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

func bitmap(_ width: Int, _ height: Int, _ body: (CGContext) -> Void) -> Data {
  bitmapRep(width, height, body).representation(using: .png, properties: [:])!
}

func iconRep(pixels: Int) -> NSBitmapImageRep {
  bitmapRep(pixels, pixels) { cg in
    draw(icon(pixels), in: cg, origin: .zero, size: CGFloat(pixels), deviceScale: 1)
  }
}

func iconPNG(pixels: Int) -> Data {
  iconRep(pixels: pixels).representation(using: .png, properties: [:])!
}

/// Nearest-neighbour enlargement of the pixels in `rep`, for checking whole-pixel edges.
func enlarged(_ rep: NSBitmapImageRep, by factor: Int) -> Data {
  bitmap(rep.pixelsWide * factor, rep.pixelsHigh * factor) { cg in
    cg.interpolationQuality = .none
    cg.draw(
      rep.cgImage!,
      in: CGRect(x: 0, y: 0, width: rep.pixelsWide * factor, height: rep.pixelsHigh * factor))
  }
}

// MARK: Type

enum Face { case serif, rounded }

struct WordmarkSpec {
  var face: Face
  var tinyWeight: NSFont.Weight
  var statsWeight: NSFont.Weight
  var label: String
}

// "tiny" is real lowercase in a lighter weight and grey; "Stats" is heavier and Ink/Frost.
let primary = WordmarkSpec(
  face: .serif, tinyWeight: .regular, statsWeight: .semibold, label: "Primary · New York")
let alternate = WordmarkSpec(
  face: .rounded, tinyWeight: .regular, statsWeight: .bold, label: "Alternate · SF Pro Rounded")
let tinyScale: CGFloat = 0.94  // "tiny" size relative to "Stats"
let tinyTracking: CGFloat = 0.01  // em of the "Stats" size
// New York picks its optical cut from the point size, so outlines come from this one size
// (the text-size cut of the review sheet) and are scaled for every output.
let wordmarkSize: CGFloat = 91

func makeFont(_ face: Face, _ weight: NSFont.Weight, _ size: CGFloat) -> CTFont {
  let system = NSFont.systemFont(ofSize: size, weight: weight)
  let design: NSFontDescriptor.SystemDesign = face == .rounded ? .rounded : .serif
  if let d = system.fontDescriptor.withDesign(design), let f = NSFont(descriptor: d, size: size) {
    return f as CTFont
  }
  return system as CTFont
}

func makeLine(_ s: String, _ font: CTFont, _ color: CGColor, kern: CGFloat = 0) -> CTLine {
  let a = NSMutableAttributedString(
    string: s,
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
  let length = (s as NSString).length
  if kern != 0 && length > 1 {
    // Track between letters only, so no trailing space is added after the last one.
    a.addAttribute(
      NSAttributedString.Key(kCTKernAttributeName as String), value: kern,
      range: NSRange(location: 0, length: length - 1))
  }
  return CTLineCreateWithAttributedString(a)
}

/// One glyph's outline in line coordinates (y-up, baseline 0) and its ink bounds.
struct PlacedGlyph {
  var path: CGPath
  var rect: CGRect
}

func placedGlyphs(_ line: CTLine) -> [PlacedGlyph] {
  var out: [PlacedGlyph] = []
  for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let n = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: n)
    var positions = [CGPoint](repeating: .zero, count: n)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
    for i in 0..<n {
      var t = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
      let path = CTFontCreatePathForGlyph(font, glyphs[i], &t) ?? CGMutablePath()
      out.append(PlacedGlyph(path: path, rect: path.boundingBoxOfPath))
    }
  }
  return out
}

// MARK: Optical spacing

/// Side space of a glyph over a horizontal band, HT-Letterspacer style: for each row, the
/// white between the glyph's ink-bounds edge and its outline, clamped at `depth` (rows with
/// no ink count as `depth`). Returns the mean.
func sideSpace(
  _ g: PlacedGlyph, right: Bool, band: ClosedRange<CGFloat>, depth: CGFloat
) -> CGFloat {
  let rows = 48
  let step = depth / 120
  var total: CGFloat = 0
  for i in 0..<rows {
    let y =
      band.lowerBound + (band.upperBound - band.lowerBound) * (CGFloat(i) + 0.5) / CGFloat(rows)
    var d: CGFloat = 0
    while d < depth {
      let x = right ? g.rect.maxX - d : g.rect.minX + d
      if g.path.contains(CGPoint(x: x, y: y)) { break }
      d += step
    }
    total += min(d, depth)
  }
  return total / CGFloat(rows)
}

/// Optical gap between two placed glyphs: ink-bounds distance plus both side spaces.
func opticalGap(_ a: PlacedGlyph, _ b: PlacedGlyph, band: ClosedRange<CGFloat>, depth: CGFloat)
  -> CGFloat
{
  (b.rect.minX - a.rect.maxX) + sideSpace(a, right: true, band: band, depth: depth)
    + sideSpace(b, right: false, band: band, depth: depth)
}

/// Closest horizontal ink-to-ink distance between two placed glyphs over a band (rows where
/// both have ink). Catches near-collisions, such as a y's arm and an S's bowl, that an
/// area measure averages away.
func closestGap(_ a: PlacedGlyph, _ b: PlacedGlyph, band: ClosedRange<CGFloat>) -> CGFloat {
  func edge(_ g: PlacedGlyph, right: Bool, _ y: CGFloat) -> CGFloat? {
    let step = max(g.rect.width / 300, 0.01)
    var d: CGFloat = 0
    while d <= g.rect.width {
      let x = right ? g.rect.maxX - d : g.rect.minX + d
      if g.path.contains(CGPoint(x: x, y: y)) { return x }
      d += step
    }
    return nil
  }
  var best = CGFloat.greatestFiniteMagnitude
  let rows = 64
  for i in 0..<rows {
    let y =
      band.lowerBound + (band.upperBound - band.lowerBound) * (CGFloat(i) + 0.5) / CGFloat(rows)
    if let ar = edge(a, right: true, y), let bl = edge(b, right: false, y) {
      best = min(best, bl - ar)
    }
  }
  return best
}

func shifted(_ g: PlacedGlyph, _ dx: CGFloat) -> PlacedGlyph {
  PlacedGlyph(
    path: g.path.copy(using: [CGAffineTransform(translationX: dx, y: 0)])!,
    rect: g.rect.offsetBy(dx: dx, dy: 0))
}

// MARK: Wordmark

struct Wordmark {
  var tiny: CTLine
  var stats: CTLine
  var statsX: CGFloat  // "Stats" origin; both words share the baseline y = 0
  var ink: CGRect  // glyph ink bounds relative to the origin, including overhang
  var cap: CGFloat
}

/// Lays out "tiny" + "Stats" on one baseline at `wordmarkSize`. The space between them is
/// solved so the y→S optical gap equals the mean optical gap inside the two words (each word
/// weighted equally), then opened by half of any shortfall against the median closest-ink
/// distance. Every output scales this one layout, so the glyph outlines never change.
func layout(_ spec: WordmarkSpec, dark: Bool) -> Wordmark {
  let size = wordmarkSize
  let statsFont = makeFont(spec.face, spec.statsWeight, size)
  let tinyFont = makeFont(spec.face, spec.tinyWeight, size * tinyScale)
  let tiny = makeLine(
    "tiny", tinyFont, (dark ? tinyGreyDark : tinyGreyLight).ns.cgColor, kern: tinyTracking * size)
  let stats = makeLine("Stats", statsFont, (dark ? frost : ink).ns.cgColor)
  let tg = placedGlyphs(tiny)
  let sg = placedGlyphs(stats)
  // Band: baseline to the x-height of "tiny", where both words have ink. A shallow depth
  // limit keeps open shapes (the y's arm, the S's bowls) from claiming white the eye
  // doesn't count.
  let xh = placedGlyphs(makeLine("x", tinyFont, ink.ns.cgColor))[0].rect.maxY
  let band: ClosedRange<CGFloat> = 0...xh
  let depth = 0.05 * size
  func gaps(_ g: [PlacedGlyph]) -> [CGFloat] {
    (0..<(g.count - 1)).map { opticalGap(g[$0], g[$0 + 1], band: band, depth: depth) }
  }
  let mean = { (v: [CGFloat]) in v.reduce(0, +) / CGFloat(v.count) }
  let target = (mean(gaps(tg)) + mean(gaps(sg))) / 2
  let y = tg.last!
  let s = sg.first!
  let sides =
    sideSpace(y, right: true, band: band, depth: depth)
    + sideSpace(s, right: false, band: band, depth: depth)
  let opticalX = y.rect.maxX + (target - sides) - s.rect.minX
  var closest: [CGFloat] = []
  for g in [tg, sg] {
    for i in 0..<(g.count - 1) { closest.append(closestGap(g[i], g[i + 1], band: band)) }
  }
  closest.sort()
  let atOptical = closestGap(y, shifted(s, opticalX), band: band)
  let statsX = opticalX + max(0, closest[closest.count / 2] - atOptical) / 2
  let ink = CTLineGetImageBounds(tiny, nil).union(
    CTLineGetImageBounds(stats, nil).offsetBy(dx: statsX, dy: 0))
  return Wordmark(
    tiny: tiny, stats: stats, statsX: statsX, ink: ink, cap: CTFontGetCapHeight(statsFont))
}

/// Draws the wordmark with its baseline origin at `o`, scaled by `scale` from the canonical size.
func drawWordmark(_ cg: CGContext, _ l: Wordmark, at o: CGPoint, scale: CGFloat) {
  cg.saveGState()
  cg.translateBy(x: o.x, y: o.y)
  cg.scaleBy(x: scale, y: scale)
  cg.textMatrix = .identity
  cg.textPosition = .zero
  CTLineDraw(l.tiny, cg)
  cg.textPosition = CGPoint(x: l.statsX, y: 0)
  CTLineDraw(l.stats, cg)
  cg.restoreGState()
}

/// Draws the wordmark scaled to fit a y-up rect with margins, capped at `maxCap`. Centres
/// the cap height (not the ink box) so the descender of "y" doesn't push it up.
func drawFittedWordmark(
  _ cg: CGContext, _ spec: WordmarkSpec, dark: Bool, in rect: CGRect, margin: CGFloat,
  maxCap: CGFloat
) {
  let l = layout(spec, dark: dark)
  let scale = min(
    (rect.width - 2 * margin) / l.ink.width, (rect.height - 2 * margin) / l.ink.height,
    maxCap / l.cap)
  drawWordmark(
    cg, l, at: CGPoint(x: rect.midX - l.ink.midX * scale, y: rect.midY - l.cap * scale / 2),
    scale: scale)
}

// MARK: SVG

func number(_ v: Double) -> String {
  let rounded = (v * 100).rounded() / 100
  return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

func svgPath(_ segments: [Segment]) -> String {
  segments.map { segment in
    switch segment {
    case .move(let p): "M\(number(p.x)) \(number(p.y))"
    case .line(let p): "L\(number(p.x)) \(number(p.y))"
    case .curve(let c1, let c2, let p):
      "C\(number(c1.x)) \(number(c1.y)) \(number(c2.x)) \(number(c2.y)) \(number(p.x)) \(number(p.y))"
    case .close: "Z"
    }
  }.joined()
}

func svg(_ shapes: [Shape], viewBox: String, title: String) -> String {
  var defs: [String] = []
  var body: [String] = []
  for shape in shapes {
    var fill: String
    switch shape.paint {
    case .solid(let color): fill = color.hex
    case .vertical(let top, let bottom, let y0, let y1):
      defs.append(
        "<linearGradient id=\"\(shape.name)-fill\" x1=\"0\" y1=\"\(number(y0))\" x2=\"0\" "
          + "y2=\"\(number(y1))\" gradientUnits=\"userSpaceOnUse\"><stop offset=\"0\" "
          + "stop-color=\"\(top.hex)\"/><stop offset=\"1\" stop-color=\"\(bottom.hex)\"/>"
          + "</linearGradient>")
      fill = "url(#\(shape.name)-fill)"
    }
    var filter = ""
    if shape.shadow {
      defs.append(
        "<filter id=\"shadow\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"125%\">"
          + "<feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-color=\"#000\" "
          + "flood-opacity=\"0.3\"/></filter>")
      filter = " filter=\"url(#shadow)\""
    }
    body.append(
      "<path id=\"\(shape.name)\" fill=\"\(fill)\"\(filter) d=\"\(svgPath(shape.path))\"/>")
  }
  return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(viewBox)" role="img" aria-label="\(title)">
    <title>\(title)</title>
    <!-- Generated by scripts/create-icon.swift; edit the script, not this file. -->
    <defs>\(defs.joined())</defs>
    \(body.joined(separator: "\n"))
    </svg>

    """
}

/// Outline of a CoreText line as SVG segments: y-up line coordinates become y-down, with the
/// baseline origin at (`dx`, `dy`), scaled by `scale`.
func outline(_ line: CTLine, dx: Double, dy: Double, scale: Double) -> [Segment] {
  var out: [Segment] = []
  var current = Point(x: 0, y: 0)
  func map(_ p: CGPoint) -> Point { Point(x: dx + p.x * scale, y: dy - p.y * scale) }
  let path = CGMutablePath()
  for glyph in placedGlyphs(line) { path.addPath(glyph.path) }
  path.applyWithBlock { element in
    let p = element.pointee.points
    switch element.pointee.type {
    case .moveToPoint:
      current = map(p[0])
      out.append(.move(current))
    case .addLineToPoint:
      current = map(p[0])
      out.append(.line(current))
    case .addQuadCurveToPoint:
      let c = map(p[0])
      let end = map(p[1])
      out.append(.curve(current + (2.0 / 3) * (c - current), end + (2.0 / 3) * (c - end), end))
      current = end
    case .addCurveToPoint:
      current = map(p[2])
      out.append(.curve(map(p[0]), map(p[1]), current))
    case .closeSubpath: out.append(.close)
    @unknown default: break
    }
  }
  return out
}

/// Icon plus wordmark on one 1024-unit-high canvas. The icon body is 1.7x the cap height,
/// centred on it, with a 0.55 cap gap; the icon's 100-unit margin is repeated on the right.
func lockup(_ spec: WordmarkSpec, dark: Bool) -> (shapes: [Shape], viewBox: String) {
  let cap = 824 / 1.7
  let l = layout(spec, dark: dark)
  let scale = cap / Double(l.cap)
  let originX = 924 + 0.55 * cap - Double(l.ink.minX) * scale
  let baseline = 512 + cap / 2
  let width = originX + Double(l.ink.maxX) * scale + 100
  let shapes =
    icon(1024, guides: false) + [
      Shape(
        name: "tiny", path: outline(l.tiny, dx: originX, dy: baseline, scale: scale),
        paint: .solid(dark ? tinyGreyDark : tinyGreyLight)),
      Shape(
        name: "stats",
        path: outline(
          l.stats, dx: originX + Double(l.statsX) * scale, dy: baseline, scale: scale),
        paint: .solid(dark ? frost : ink)),
    ]
  return (shapes, "0 0 \(number(width.rounded())) 1024")
}

// MARK: Brand images

func text(
  _ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0
) -> NSAttributedString {
  NSAttributedString(
    string: string,
    attributes: [
      .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
      .kern: kern,
    ])
}

func fill(_ cg: CGContext, _ rect: CGRect, top: RGB, bottom: RGB) {
  let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [top.ns.cgColor, bottom.ns.cgColor] as CFArray, locations: [0, 1])!
  cg.saveGState()
  cg.clip(to: rect)
  cg.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
  cg.restoreGState()
}

/// 1280 x 640 GitHub social preview. Text is rasterized; no font file is distributed.
func socialPreview() -> Data {
  bitmap(1280, 640) { cg in
    fill(
      cg, CGRect(x: 0, y: 0, width: 1280, height: 640), top: RGB(hex: "#191D23"),
      bottom: RGB(hex: "#0C0F12"))
    draw(
      icon(1024, guides: false), in: cg, origin: CGPoint(x: 120, y: 156), size: 328,
      deviceScale: 1)
    let word = layout(primary, dark: true)
    let scale = 136 / wordmarkSize
    drawWordmark(cg, word, at: CGPoint(x: 498 - word.ink.minX * scale, y: 296), scale: scale)
    text("Your Mac, at a glance.", size: 42, weight: .regular, color: RGB(hex: "#A3ADB7").ns)
      .draw(at: CGPoint(x: 498, y: 220))
    text(
      "Native macOS menu bar monitor  ·  MIT", size: 26, weight: .medium, color: mintDeep.ns,
      kern: 0.5
    ).draw(at: CGPoint(x: 498, y: 162))
  }
}

/// Review sheet on light and dark: the icon at every shipped size, then both wordmarks.
func preview() -> Data {
  bitmap(1600, 800) { cg in
    for (x, dark) in [(CGFloat(0), false), (800, true)] {
      let label = dark ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.35, alpha: 1)
      cg.setFillColor((dark ? nightBackground : paperBackground).ns.cgColor)
      cg.fill(CGRect(x: x, y: 0, width: 800, height: 800))
      text(dark ? "Dark" : "Light", size: 18, weight: .medium, color: label)
        .draw(at: CGPoint(x: x + 48, y: 748))
      draw(icon(1024), in: cg, origin: CGPoint(x: x + 48, y: 408), size: 320, deviceScale: 1)
      var cursor = x + 416
      for size in [128, 64, 32, 16] {
        draw(
          icon(size), in: cg, origin: CGPoint(x: cursor, y: 408), size: CGFloat(size),
          deviceScale: 1)
        text("\(size)", size: 14, weight: .regular, color: label)
          .draw(at: CGPoint(x: cursor, y: 380))
        cursor += CGFloat(size) + 32
      }
      for (row, spec) in [primary, alternate].enumerated() {
        let top = 330 - CGFloat(row) * 150
        text(spec.label, size: 14, weight: .regular, color: label)
          .draw(at: CGPoint(x: x + 48, y: top - 4))
        drawFittedWordmark(
          cg, spec, dark: dark, in: CGRect(x: x + 48, y: top - 140, width: 704, height: 130),
          margin: 8, maxCap: 64)
      }
    }
  }
}

// MARK: Main

let arguments = Array(CommandLine.arguments.dropFirst())
func write(_ data: Data, _ path: String) throws { try data.write(to: URL(fileURLWithPath: path)) }
func directory(_ path: String) throws -> String {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}
switch arguments.first {
case "--svg" where arguments.count == 2:
  let output = try directory(arguments[1])
  for (name, dark) in [("logo", false), ("logo-dark", true)] {
    let l = lockup(primary, dark: dark)
    try svg(l.shapes, viewBox: l.viewBox, title: "TinyStats")
      .write(toFile: "\(output)/\(name).svg", atomically: true, encoding: .utf8)
  }
  try svg(icon(1024), viewBox: "0 0 1024 1024", title: "TinyStats")
    .write(toFile: "\(output)/logo-mark.svg", atomically: true, encoding: .utf8)
case "--brand" where arguments.count == 2:
  let output = try directory(arguments[1])
  try write(socialPreview(), "\(output)/social-preview.png")
  try write(preview(), "\(output)/preview.png")
case "--check" where arguments.count == 2:
  let output = try directory(arguments[1])
  for size in [16, 32] {
    try write(enlarged(iconRep(pixels: size), by: 16), "\(output)/icon-\(size)-x16.png")
  }
case let path? where arguments.count == 1 && !path.hasPrefix("-"):
  let output = try directory(path)
  for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
      try write(
        iconPNG(pixels: size * scale),
        "\(output)/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png")
    }
  }
default:
  FileHandle.standardError.write(
    "usage: create-icon.swift <dir>.iconset | --svg <dir> | --brand <dir> | --check <dir>\n"
      .data(using: .utf8)!)
  exit(2)
}
