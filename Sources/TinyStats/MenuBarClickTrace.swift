import AppKit
import OSLog

/// Session-only, explicit maintainer diagnostics. No defaults, files or event history.
@MainActor struct MenuBarClickTrace {
  static func enabled(environment: [String: String]) -> Bool {
    environment["TINYSTATS_CLICK_TRACE"] == "1"
  }

  let isEnabled: Bool
  private let logger = Logger(subsystem: "com.niechen.tinystats", category: "MenuBarClick")

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    isEnabled = Self.enabled(environment: environment)
  }

  func record(_ event: NSEvent, buttons: [StatusItemController.Target], result: String) {
    guard isEnabled, PopoverInteraction.isMouse(event) else { return }
    let window =
      event.window.map {
        "\(NSStringFromClass(type(of: $0)))#\($0.windowNumber) frame=\($0.frame)"
      } ?? "nil#\(event.windowNumber)"
    let rects = buttons.map {
      "\($0.module.rawValue)=\(PopoverInteraction.screenRect(of: $0.button).map(String.init(describing:)) ?? "unavailable")"
    }.joined(separator: ";")
    let ownWindowPoint =
      PopoverInteraction.statusWindowPoint(event, statusButtons: buttons.map(\.button))
      .map(String.init(describing:)) ?? "unavailable"
    let line =
      "type=\(event.type)(\(event.type.rawValue)) window=\(window) locationInWindow=\(event.locationInWindow) mouseLocation=\(NSEvent.mouseLocation) statusWindowScreenPoint=\(ownWindowPoint) buttons=[\(rects)] result=\(result)"
    logger.notice("\(line, privacy: .public)")
  }
}
