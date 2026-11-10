import AppKit
import Testing

@testable import TinyStats

@Suite(.serialized) @MainActor struct PopoverInteractionTests {
  private func window() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }
  private func mouse(_ window: NSWindow, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent
  {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: .init(x: 10, y: 10), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    )
  }
  private func key(_ window: NSWindow, code: UInt16) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code))
  }

  @Test func statusItemsAndPopoverChildrenKeepTheirOriginalClick() throws {
    let popover = window()
    let firstItem = window()
    let secondItem = window()
    let child = window()
    defer { for view in [popover, firstItem, secondItem, child] { view.close() } }
    popover.addChildWindow(child, ordered: .above)
    let interaction = PopoverInteraction(mouseLocation: { .init(x: -10_000, y: -10_000) })
    defer { interaction.stop() }
    var dismissed = 0
    interaction.start(
      window: popover, statusEvent: { $0.window === firstItem || $0.window === secondItem },
      onDismiss: { dismissed += 1 })
    for target in [firstItem, secondItem, popover, child] {
      for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
        let event = try mouse(target, type: type)
        #expect(interaction.handle(event) === event)
        #expect(interaction.isMonitoring && dismissed == 0)
      }
    }
  }

  @Test func outsideClickClosesOnceAndStillReachesItsDestination() throws {
    let popover = window()
    let outside = window()
    defer {
      popover.close()
      outside.close()
    }
    let interaction = PopoverInteraction(mouseLocation: { .init(x: -10_000, y: -10_000) })
    var dismissed = 0
    interaction.start(window: popover, statusEvent: { _ in false }, onDismiss: { dismissed += 1 })
    let event = try mouse(outside)
    #expect(interaction.handle(event) === event)
    #expect(dismissed == 1 && !interaction.isMonitoring)
    #expect(interaction.handle(event) === event)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    #expect(dismissed == 1)
  }

  @Test func proxyScreenCoordinatesAndGlobalClicksRespectStatusItemBounds() throws {
    let popover = window()
    let status = window()
    let other = window()
    defer { for view in [popover, status, other] { view.close() } }
    other.setFrameOrigin(.init(x: 900, y: 500))
    let button = NSButton(frame: .init(x: 20, y: 20, width: 40, height: 24))
    status.contentView?.addSubview(button)
    status.orderFrontRegardless()
    let point = status.convertPoint(toScreen: .init(x: 30, y: 30))
    let proxy = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    #expect(
      proxy.window == nil && PopoverInteraction.hits(proxy, view: button, mouseLocation: point))
    let outside = other.convertPoint(toScreen: .init(x: 10, y: 10))
    #expect(!PopoverInteraction.hits(try mouse(other), view: button, mouseLocation: outside))
    let interaction = PopoverInteraction(mouseLocation: { .init(x: -10_000, y: -10_000) })
    defer { interaction.stop() }
    var dismissed = 0
    var cursor = point
    interaction.start(
      window: popover,
      statusEvent: { PopoverInteraction.hits($0, view: button, mouseLocation: cursor) },
      onDismiss: { dismissed += 1 })
    interaction.handleGlobal(proxy)
    #expect(dismissed == 0 && interaction.isMonitoring)
    cursor = outside
    interaction.handleGlobal(try mouse(other))
    #expect(dismissed == 1 && !interaction.isMonitoring)
  }

  @Test func forwardedMouseCoordinatesReachOwnedStatusButton() throws {
    let status = window()
    let proxy = window()
    defer {
      status.close()
      proxy.close()
    }
    status.setFrameOrigin(.init(x: 400, y: 300))
    proxy.setFrameOrigin(.init(x: 360, y: 280))
    let button = NSButton(frame: .init(x: 20, y: 20, width: 80, height: 24))
    status.contentView?.addSubview(button)
    status.orderFrontRegardless()
    let screenPoint = status.convertPoint(toScreen: button.convert(.init(x: 60, y: 12), to: nil))
    let event = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: proxy.convertPoint(fromScreen: screenPoint),
        modifierFlags: [], timestamp: 1, windowNumber: proxy.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    #expect(event.window === proxy)
    #expect(PopoverInteraction.hits(event, view: button, mouseLocation: screenPoint))
  }

  @Test func statusMouseDownRoutesOnceBeforeTrackingAndRightClickPassesThrough() throws {
    let popover = window()
    let status = window()
    defer {
      popover.close()
      status.close()
    }
    let interaction = PopoverInteraction(mouseLocation: { .init(x: -10_000, y: -10_000) })
    defer { interaction.stop() }
    var clicks = 0
    var dismissed = 0
    interaction.start(
      window: popover, statusEvent: { $0.window === status },
      onStatusClick: { _ in clicks += 1 }, onDismiss: { dismissed += 1 })
    let down = try mouse(status)
    #expect(interaction.handle(down) == nil)
    #expect(clicks == 1 && dismissed == 0 && interaction.isMonitoring)
    let right = try mouse(status, type: .rightMouseDown)
    #expect(interaction.handle(right) === right)
    #expect(clicks == 1 && dismissed == 0)
    let drag = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .init(x: 10, y: 10), modifierFlags: [.command], timestamp: 1,
        windowNumber: status.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    )
    #expect(interaction.handle(drag) === drag)
    #expect(clicks == 1 && dismissed == 0)
  }

  @Test func escapeOnlyDismissesThePopoverAndOtherKeysPassThrough() throws {
    let popover = window()
    let other = window()
    defer {
      popover.close()
      other.close()
    }
    let interaction = PopoverInteraction(mouseLocation: { .init(x: -10_000, y: -10_000) })
    defer { interaction.stop() }
    var dismissed = 0
    interaction.start(window: popover, statusEvent: { _ in false }, onDismiss: { dismissed += 1 })
    for event in [try key(other, code: 53), try key(popover, code: 36)] {
      #expect(interaction.handle(event) === event)
    }
    #expect(dismissed == 0)
    #expect(interaction.handle(try key(popover, code: 53)) == nil)
    #expect(dismissed == 1 && !interaction.isMonitoring)
  }

  @Test func restartAndPromotionRemoveOldObserversAndCapturedContent() throws {
    let popover = window()
    defer { popover.close() }
    let interaction = PopoverInteraction(mouseLocation: { .init(x: -10_000, y: -10_000) })
    var first = 0
    var second = 0
    interaction.start(window: popover, statusEvent: { _ in false }, onDismiss: { first += 1 })
    interaction.start(window: popover, statusEvent: { _ in false }, onDismiss: { second += 1 })
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    #expect(first == 0 && second == 1 && !interaction.isMonitoring)
    weak var released: NSObject?
    do {
      let content = NSObject()
      released = content
      interaction.start(
        window: popover,
        statusEvent: { [content] _ in
          _ = content
          return false
        },
        onDismiss: { [content] in _ = content })
    }
    #expect(released != nil)
    interaction.stop()  // Settings promotion or closing must leave no transient handlers.
    #expect(released == nil && !interaction.isMonitoring)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    #expect(first == 0 && second == 1)
  }

  @Test func fieldEditorKeepsEscapeForPlainAndMarkedText() throws {
    let popover = window()
    defer { popover.close() }
    let editor = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 50))
    editor.isFieldEditor = true
    popover.contentView?.addSubview(editor)
    #expect(popover.makeFirstResponder(editor))
    let interaction = PopoverInteraction(mouseLocation: { .init(x: -10_000, y: -10_000) })
    defer { interaction.stop() }
    var dismissed = 0
    interaction.start(window: popover, statusEvent: { _ in false }, onDismiss: { dismissed += 1 })
    for marked in [false, true] {
      if marked {
        editor.setMarkedText(
          "拼", selectedRange: .init(location: 0, length: 1),
          replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
      }
      let escape = try key(popover, code: 53)
      #expect(interaction.handle(escape) === escape)
      #expect(interaction.isMonitoring && dismissed == 0)
    }
  }
}
