import Foundation

/// Pure drawing palette. No AppKit state, settings, cached appearance, or collection work.
enum AccentPalette {
  struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
      self.red = red
      self.green = green
      self.blue = blue
    }
    init(hex: UInt32) {
      self.init(
        Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
    }
    var hex: String {
      String(
        format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
        Int((blue * 255).rounded()))
    }
    private var linear: RGB {
      func decode(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
      }
      return RGB(decode(red), decode(green), decode(blue))
    }
    var luminance: Double {
      let c = linear
      return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }
    func contrast(against background: RGB) -> Double {
      (max(luminance, background.luminance) + 0.05) / (min(luminance, background.luminance) + 0.05)
    }
    // Original Swift implementation of Björn Ottosson's published 2021-01-25 matrices.
    // https://bottosson.github.io/posts/oklab/ (public-domain equations).
    var lab: Lab {
      let c = linear
      let l = cbrt(0.4122214708 * c.red + 0.5363325363 * c.green + 0.0514459929 * c.blue)
      let m = cbrt(0.2119034982 * c.red + 0.6806995451 * c.green + 0.1073969566 * c.blue)
      let s = cbrt(0.0883024619 * c.red + 0.2817188376 * c.green + 0.6299787005 * c.blue)
      return Lab(
        lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
  }
  struct Lab {
    var lightness: Double
    var a: Double
    var b: Double
    var chroma: Double { hypot(a, b) }
    var hue: Double { atan2(b, a) }
    func distance(to other: Lab) -> Double {
      sqrt(pow(lightness - other.lightness, 2) + pow(a - other.a, 2) + pow(b - other.b, 2))
    }
    private var linear: RGB {
      let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
      let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
      let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
      return RGB(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }
    /// Reduce chroma at fixed hue/lightness instead of clipping channels and shifting hue.
    var gamutMapped: RGB {
      var low = 0.0
      var high = 1.0
      for _ in 0..<20 {
        let scale = (low + high) / 2
        let c = Lab(lightness: lightness, a: a * scale, b: b * scale).linear
        if [c.red, c.green, c.blue].allSatisfy({ $0 >= 0 && $0 <= 1 }) {
          low = scale
        } else {
          high = scale
        }
      }
      let c = Lab(lightness: lightness, a: a * low, b: b * low).linear
      func encode(_ c: Double) -> Double {
        let c = min(1, max(0, c))
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
      }
      return RGB(encode(c.red), encode(c.green), encode(c.blue))
    }
  }
  struct Pair {
    let primary: RGB
    let secondary: RGB
  }
  // Conservative neutral surfaces: light window is darker than its white platter;
  // dark platter is lighter than the window. Also covers the board's #2A2A2D platter.
  static func background(dark: Bool) -> RGB { RGB(hex: dark ? 0x343436 : 0xECECEE) }

  static func derive(from accent: RGB, dark: Bool) -> Pair {
    let source = accent.lab
    let primary = readable(accent, dark: dark)
    // A quarter turn keeps a relation to the user's hue while separating paired series.
    // Graphite/unknown neutral hues have no stable angle: use a chromatic blue companion.
    let hue = source.chroma < 0.025 ? 250 * .pi / 180 : source.hue + .pi / 2
    let chroma = min(dark ? 0.18 : 0.20, max(0.14, source.chroma))
    let secondary = Lab(
      lightness: dark ? 0.75 : 0.55, a: chroma * cos(hue), b: chroma * sin(hue)
    ).gamutMapped
    return Pair(primary: primary, secondary: readable(secondary, dark: dark))
  }
  private static func readable(_ color: RGB, dark: Bool) -> RGB {
    let background = background(dark: dark)
    // Margin above 3:1 keeps the documented rounded 8-bit hex colors readable too.
    guard color.contrast(against: background) < 3.05 else { return color }
    let source = color.lab
    var failing = source.lightness
    var passing = dark ? 1.0 : 0.0
    for _ in 0..<20 {
      let lightness = (failing + passing) / 2
      let candidate = Lab(lightness: lightness, a: source.a, b: source.b).gamutMapped
      if candidate.contrast(against: background) >= 3.05 {
        passing = lightness
      } else {
        failing = lightness
      }
    }
    return Lab(lightness: passing, a: source.a, b: source.b).gamutMapped
  }
}
