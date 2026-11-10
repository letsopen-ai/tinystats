import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

/// All windows and cursor values are owned fixtures. Never creates a system status item,
/// posts an event, moves the real cursor, launches collectors or enables online settings.
@MainActor final class MenuBarRoutingFixture {
  var cursor = NSPoint.zero
  var presentations: [Bool] = []
  var cycles: [PopoverCycleProbe.Event] = []
  var statusWindows: [NSWindow] = []
  let unrelated: NSWindow
  private(set) var items: StatusItemController!
  private(set) var app: AppDelegate!

  init(
    combined: Bool, modules: [Module] = [.cpu, .memory], settings: Settings = Settings(),
    energyModes: EnergyModeController? = nil
  ) throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.main).frame
    func owned(_ x: CGFloat) -> NSWindow {
      let window = NSWindow(
        contentRect: .init(x: screen.minX + x, y: screen.maxY - 110, width: 240, height: 60),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.orderFrontRegardless()
      return window
    }
    unrelated = owned(700)
    var targets: [StatusItemController.Target] = []
    for (index, group) in (combined ? [modules] : modules.map { [$0] }).enumerated() {
      let window = owned(CGFloat(100 + index * 300))
      statusWindows.append(window)
      let renderer = MenuBarReadoutView()
      renderer.readouts = group.map {
        MenuBarStyleExample.readout(module: $0, style: .icon, settings: Settings())
      }
      let button = NSButton(frame: .init(x: 20, y: 20, width: renderer.preferredWidth, height: 24))
      renderer.frame = button.bounds
      button.addSubview(renderer)
      window.contentView?.addSubview(button)
      targets.append(.init(module: group[0], button: button, readout: renderer))
    }
    items = StatusItemController(
      targets: targets, combined: combined, mouseLocation: { [unowned self] in self.cursor })
    app = AppDelegate(
      statusItems: items,
      popoverInteraction: PopoverInteraction(mouseLocation: { [unowned self] in self.cursor }),
      settings: settings, clickTrace: MenuBarClickTrace(environment: [:]),
      presentationReporter: { [unowned self] in self.presentations.append($0) },
      cycleReporter: { [unowned self] in self.cycles.append($0) }, energyModes: energyModes)
  }

  func target(_ module: Module) throws -> StatusItemController.Target {
    try #require(items.targets.first { $0.readout.segments.contains { $0.module == module } })
  }

  func screenPoint(_ module: Module) throws -> NSPoint {
    let target = try target(module)
    let segment = try #require(target.readout.segments.first { $0.module == module })
    return try #require(target.button.window).convertPoint(
      toScreen: target.readout.convert(.init(x: segment.frame.midX, y: 12), to: nil))
  }

  func event(_ module: Module, source: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent
  {
    cursor = try screenPoint(module)
    let window: NSWindow?
    switch source {
    case 0: window = try target(module).button.window
    case 1: window = nil
    case 2: window = unrelated
    default: window = app.detail?.view.window
    }
    return try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: window?.convertPoint(fromScreen: cursor) ?? cursor,
        modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 1,
        clickCount: 1, pressure: 1))
  }

  func close() {
    app.popoverInteraction.stop()
    app.popover?.animates = false
    app.popover?.close()
    for window in statusWindows + [unrelated] { window.close() }
  }
}
