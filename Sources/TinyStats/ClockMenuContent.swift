import Foundation
import TinyStatsCore

/// Immediate-mode vector atoms, shared by the preview and the real status item. No images or layers.
struct ClockMenuLine: Equatable {
  enum Part: Equatable {
    case text(String)
    case dial(ClockDialReading)
    case calendar(Int)
    var length: Int {
      if case .text(let text) = self { return text.count }
      return 1
    }
    var accessibleText: String {
      switch self {
      case .text(let text): text
      case .dial(let reading): "Analogue " + reading.accessibleTime
      case .calendar(let day): "Calendar day \(day)"
      }
    }
  }
  let parts: [Part]
  init(_ parts: [Part], limit: Int = 128) {
    let limit = min(257, max(1, limit))
    var bounded: [Part] = []
    var remaining = limit - 1
    if parts.reduce(0, { $0 + $1.length }) <= limit {
      bounded = parts
    } else {
      for part in parts {
        guard remaining > 0 else { break }
        if case .text(let text) = part {
          bounded.append(.text(String(text.prefix(remaining))))
        } else {
          bounded.append(part)
        }
        remaining -= min(remaining, part.length)
      }
      bounded.append(.text("…"))
    }
    var merged: [Part] = []
    for part in bounded where part.length > 0 {
      if case .text(let value) = part, case .text(let previous) = merged.last {
        merged[merged.count - 1] = .text(previous + value)
      } else {
        merged.append(part)
      }
    }
    self.parts = merged
  }
  var isEmpty: Bool { parts.allSatisfy { $0.length == 0 } }
  var text: String {
    let text = parts.map(\.accessibleText).joined()
    return text.count > 128 ? String(text.prefix(127)) + "…" : text
  }
}
struct ClockMenuContent: Equatable {
  var first: ClockMenuLine, second: ClockMenuLine?
  var joined: ClockMenuLine {
    ClockMenuLine(first.parts + (second.map { [.text(" ")] + $0.parts } ?? []), limit: 257)
  }
}
