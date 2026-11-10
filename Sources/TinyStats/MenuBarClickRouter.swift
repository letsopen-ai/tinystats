import Foundation
import TinyStatsCore

/// Pure routing shared by native status input and owned-window regression fixtures.
/// Segments use physical renderer coordinates, so RTL never requires guessing an order.
enum MenuBarClickRouter {
  struct Segment {
    var module: Module?
    var frame: CGRect
  }

  /// Includes the whole icon/value segment. Gaps and outer padding select the nearest edge;
  /// an exact tie goes to the first segment in renderer order. Repeated clocks share Time.
  static func module(at x: CGFloat, segments: [Segment]) -> Module? {
    guard x.isFinite else { return nil }
    return segments.filter { $0.module != nil }.min {
      distance(x, from: $0.frame) < distance(x, from: $1.frame)
    }?.module
  }

  private static func distance(_ x: CGFloat, from frame: CGRect) -> CGFloat {
    max(frame.minX - x, x - frame.maxX, 0)
  }

  enum Transition: Equatable {
    case open(Module)
    case switchModule(from: Module, to: Module)
    case close
    case none
  }

  /// A switch replaces the visible page in one event, keeping its controller and presentation.
  /// nil input represents outside dismissal; keyboard input supplies the item's first module.
  static func transition(open: Module?, clicked: Module?) -> Transition {
    guard let clicked else { return open == nil ? .none : .close }
    guard let open else { return .open(clicked) }
    return open == clicked ? .close : .switchModule(from: open, to: clicked)
  }
}
