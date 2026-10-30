import Foundation

/// All customization paths edit the existing ordered `readouts` setting.
public enum MenuBarLayoutAction: Equatable, Sendable {
  case add(at: Int)
  case remove
  case move(to: Int)
  case toggle, left, right, start, end
}

extension Settings {
  /// Adopt only a complete native arrangement; partial/offscreen/duplicate frames are not a layout.
  /// Used on the existing refresh to migrate and retain native ⌘-drag positions in `readouts`.
  @discardableResult
  public mutating func adoptNativeReadoutOrder(_ order: [Module]) -> Bool {
    guard order != readouts, order.count == readouts.count, Set(order) == Set(readouts) else {
      return false
    }
    readouts = order
    return true
  }

  /// Drop indices are insertion boundaries in the original list (before removing the source).
  @discardableResult
  public mutating func customizeReadout(_ module: Module, action: MenuBarLayoutAction) -> Bool {
    guard module != .overview else { return false }
    let old = readouts
    let index = readouts.firstIndex(of: module)
    switch action {
    case .remove:
      guard index != nil, readouts.count > 1 else { return false }
      readouts.removeAll { $0 == module }
    case .toggle:
      return customizeReadout(module, action: index == nil ? .add(at: readouts.count) : .remove)
    case .add(let boundary), .move(let boundary):
      let boundary = min(max(0, boundary), readouts.count)
      readouts.removeAll { $0 == module }
      let destination = boundary - ((index.map { $0 < boundary } ?? false) ? 1 : 0)
      readouts.insert(module, at: min(destination, readouts.count))
    case .left, .right, .start, .end:
      guard let index else { return false }
      let boundary: Int
      switch action {
      case .left: boundary = max(0, index - 1)
      case .right: boundary = min(readouts.count, index + 2)
      case .start: boundary = 0
      default: boundary = readouts.count
      }
      return customizeReadout(module, action: .move(to: boundary))
    }
    return readouts != old
  }
}
