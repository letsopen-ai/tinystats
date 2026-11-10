import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

struct MenuBarClickRouterTests {
  @Test func gapsEdgesAndRTLUsePhysicalSegmentFrames() {
    let segments: [MenuBarClickRouter.Segment] = [
      .init(module: .network, frame: .init(x: 80, y: 0, width: 60, height: 24)),
      .init(module: .memory, frame: .init(x: 40, y: 0, width: 30, height: 24)),
      .init(module: .cpu, frame: .init(x: 0, y: 0, width: 30, height: 24)),
    ]
    for (x, module) in [
      (-10.0, Module.cpu), (0, .cpu), (29, .cpu), (34, .cpu), (36, .memory),
      (40, .memory), (70, .memory), (74, .memory), (76, .network), (140, .network),
      (200, .network),
    ] {
      #expect(MenuBarClickRouter.module(at: x, segments: segments) == module)
    }
    #expect(MenuBarClickRouter.module(at: 75, segments: segments) == .network)
    #expect(MenuBarClickRouter.module(at: .nan, segments: segments) == nil)
    #expect(MenuBarClickRouter.module(at: .infinity, segments: segments) == nil)
    #expect(MenuBarClickRouter.module(at: 0, segments: []) == nil)
  }

  @Test func openSwitchToggleAndOutsideAreSingleTransitions() {
    #expect(MenuBarClickRouter.transition(open: nil, clicked: .cpu) == .open(.cpu))
    #expect(
      MenuBarClickRouter.transition(open: .cpu, clicked: .network)
        == .switchModule(from: .cpu, to: .network))
    #expect(MenuBarClickRouter.transition(open: .network, clicked: .network) == .close)
    #expect(MenuBarClickRouter.transition(open: .memory, clicked: nil) == .close)
    #expect(MenuBarClickRouter.transition(open: nil, clicked: nil) == .none)
  }
}

@Suite(.serialized) @MainActor struct StatusItemClickRoutingTests {
  @Test(arguments: [MenuBarStyle.stacked, .icon, .historyValue, .text, .ring], [false, true])
  func renderedSegmentsMatchClicks(style: MenuBarStyle, reversed: Bool) throws {
    let renderer = MenuBarReadoutView()
    let modules: [Module] =
      reversed ? [.network, .battery, .memory, .cpu] : [.cpu, .memory, .network, .battery]
    renderer.readouts = modules.map {
      var readout = MenuBarStyleExample.readout(module: $0, style: style, settings: Settings())
      readout.appearance.size = reversed ? .compact : .standard
      return readout
    }
    renderer.frame = .init(x: 0, y: 0, width: renderer.preferredWidth, height: 24)
    for (segment, module) in zip(renderer.segments, modules) {
      for x in [segment.frame.minX, segment.frame.midX, segment.frame.maxX] {
        #expect(renderer.module(at: x) == module)
      }
    }
    for pair in zip(renderer.segments, renderer.segments.dropFirst()) {
      #expect(renderer.module(at: pair.0.frame.maxX + 0.25) == pair.0.module)
      #expect(renderer.module(at: pair.1.frame.minX - 0.25) == pair.1.module)
    }
    #expect(renderer.module(at: -10) == modules.first)
    #expect(renderer.module(at: renderer.preferredWidth + 10) == modules.last)
    let unpaused = renderer.segments
    renderer.paused = true
    #expect(renderer.module(at: 3) == modules.first)
    for (before, after) in zip(unpaused, renderer.segments) {
      #expect(after.frame.minX == before.frame.minX + 12)
      #expect(after.frame.width == before.frame.width)
      #expect(renderer.module(at: after.frame.midX) == after.module)
    }
  }

  @Test func repeatedClocksAndMissingModulesRouteWithoutInventingIdentity() {
    let renderer = MenuBarReadoutView()
    renderer.readouts = [Module.cpu, .clock, .clock, .memory].map {
      MenuBarStyleExample.readout(module: $0, style: .icon, settings: Settings())
    }
    for index in [1, 2] {
      #expect(renderer.module(at: renderer.segments[index].frame.midX) == .clock)
    }
    renderer.readouts = [MenuBarReadout(label: "", value: "", secondary: nil, style: .icon)]
    #expect(renderer.module(at: 3) == nil)
  }

  @Test func buttonInputHandlesMouseDownUpProxyAndAccessibility() throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: .init(x: 300, y: 200, width: 400, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let proxy = NSWindow(
      contentRect: .init(x: 250, y: 150, width: 400, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    proxy.isReleasedWhenClosed = false
    defer {
      window.close()
      proxy.close()
    }
    let button = NSButton(frame: .init(x: 30, y: 10, width: 200, height: 24))
    let renderer = MenuBarReadoutView(frame: .init(x: 7, y: 0, width: 180, height: 24))
    renderer.readouts = [Module.cpu, .memory, .network].map {
      MenuBarStyleExample.readout(module: $0, style: .icon, settings: Settings())
    }
    button.addSubview(renderer)
    window.contentView?.addSubview(button)
    window.orderFrontRegardless()
    let x = renderer.segments[2].frame.midX
    let point = window.convertPoint(toScreen: renderer.convert(.init(x: x, y: 12), to: nil))
    for source in [window, proxy, nil] {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(
          NSEvent.mouseEvent(
            with: type, location: source?.convertPoint(fromScreen: point) ?? point,
            modifierFlags: [], timestamp: 1, windowNumber: source?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(
          StatusItemController.module(
            for: event, button: button, readout: renderer,
            fallback: .cpu, combined: true, mouseLocation: point) == .network)
        #expect(
          StatusItemController.module(
            for: event, button: button, readout: renderer,
            fallback: .memory, combined: false) == .memory)
      }
    }
    let key = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    for event in [key, nil] {
      #expect(
        StatusItemController.module(
          for: event, button: button, readout: renderer,
          fallback: .cpu, combined: true) == .cpu)
    }
  }
  @Test(arguments: [false, true], [0, 1, 2, 3])
  func appDelegateRoutesRealEntries(combined: Bool, source: Int) throws {
    let fixture = try MenuBarRoutingFixture(combined: combined)
    defer { fixture.close() }
    let app = try #require(fixture.app)
    // Closed native action path also uses the actual delegate adapter.
    let first = try fixture.event(.cpu, source: source)
    app.activateStatusButton(try fixture.target(.cpu).button, event: first)
    #expect(app.detail?.selected == .cpu && app.popover?.isShown == true)
    app.popover?.animates = false
    let originalDetail = app.detail
    let originalPopover = app.popover
    if source == 2 {
      let point = try fixture.screenPoint(.memory)
      fixture.unrelated.setFrameOrigin(.init(x: point.x - 10, y: point.y - 10))
      #expect(fixture.unrelated.frame.contains(point))
    }
    let second = try fixture.event(.memory, source: source)
    switch source {
    case 0: #expect(second.window === (try fixture.target(.memory).button.window))
    case 1: #expect(second.window == nil)
    case 2: #expect(second.window === fixture.unrelated)
    default: #expect(second.window === app.detail?.view.window)
    }
    if source == 2 {
      // Even when its screen point overlaps the status button, an unrelated owned
      // window keeps its event. Reopen before testing an eligible source below.
      #expect(app.popoverInteraction.handle(second) === second)
      #expect(app.detail?.selected == .cpu)
      app.activateStatusButton(try fixture.target(.cpu).button, event: nil)
      app.popover?.animates = false
    } else {
      #expect(app.popoverInteraction.handle(second) == nil)
      #expect(app.detail?.selected == .memory && app.popover?.isShown == true)
      #expect(app.detail === originalDetail && app.popover === originalPopover)
      #expect(fixture.presentations == [true])
      let toggle = try fixture.event(.memory, source: source)
      #expect(app.popoverInteraction.handle(toggle) == nil)
      #expect(app.popover?.isShown == false && !app.popoverInteraction.isMonitoring)
      #expect(fixture.presentations == [true, false])
      app.activateStatusButton(try fixture.target(.cpu).button, event: nil)
      app.popover?.animates = false
    }
    let dropdown = try #require(app.detail?.view.window)
    // Deliberate overlap: dropdown controls take precedence over a button behind them.
    let statusPoint = try fixture.screenPoint(.memory)
    dropdown.setFrameOrigin(.init(x: statusPoint.x - 20, y: statusPoint.y - 20))
    let inside = try fixture.event(.memory, source: 3)
    #expect(app.popoverInteraction.handle(inside) === inside)
    #expect(app.detail?.selected == .cpu && app.popover?.isShown == true)
  }

  @Test func closingPopoverRetainsClickAndAccountsBeforeReopening() throws {
    let fixture = try MenuBarRoutingFixture(combined: true)
    defer { fixture.close() }
    let app = try #require(fixture.app)
    let now = ProcessInfo.processInfo.systemUptime
    app.activateStatusButton(try fixture.target(.cpu).button, event: nil)
    let closing = try #require(app.popover)
    closing.animates = false
    // Set up the probe at the close boundary; initial CPU selection would intentionally
    // interrupt a diagnostic probe configured for Network. No timer or real-time wait.
    var probe = PopoverCycleProbe(
      configuration: .init(count: 1, baselineSeconds: 20, openSeconds: 4, closedSeconds: 4))
    _ = probe.tick(at: now - 30)
    _ = probe.tick(at: now - 10)
    _ = probe.didShow(true, at: now - 10)
    #expect(probe.tick(at: now - 5)?.command == .close)
    app.previewCycleProbe = probe
    app.popoverWillClose(.init(name: NSPopover.willCloseNotification, object: closing))
    let click = try fixture.event(.memory, source: 1)
    #expect(app.popoverInteraction.handle(click) == nil)
    #expect(app.detail?.selected == .cpu)  // Do not switch into a closing presentation.
    closing.close()
    #expect(fixture.presentations == [true, false, true])
    #expect(fixture.cycles.contains { $0.kind == .closed })
    #expect(app.popover?.isShown == true && app.detail?.selected == .memory)
    #expect(app.popoverInteraction.isMonitoring)
  }

  @Test func shownCloseCallbackStillReportsWithoutTearingDownCurrentPresentation() throws {
    let fixture = try MenuBarRoutingFixture(combined: true)
    defer { fixture.close() }
    let app = try #require(fixture.app)
    app.activateStatusButton(try fixture.target(.cpu).button, event: nil)
    let popover = try #require(app.popover)
    let now = ProcessInfo.processInfo.systemUptime
    var probe = PopoverCycleProbe(
      configuration: .init(count: 1, baselineSeconds: 20, openSeconds: 4, closedSeconds: 4))
    _ = probe.tick(at: now - 30)
    _ = probe.tick(at: now - 10)
    _ = probe.didShow(true, at: now - 10)
    _ = probe.tick(at: now - 5)
    app.previewCycleProbe = probe
    app.popoverDidClose(.init(name: NSPopover.didCloseNotification, object: popover))
    #expect(fixture.presentations == [true, false])
    #expect(fixture.cycles.map(\.kind) == [.closed])
    app.previewCycleProbe = nil
    #expect(app.popover?.isShown == true && app.popoverInteraction.isMonitoring)
    #expect(app.detail?.selected == .cpu)
  }

  @Test func nativeCommandKeyboardAndOffButtonMouseFallback() throws {
    let fixture = try MenuBarRoutingFixture(combined: true)
    defer { fixture.close() }
    let app = try #require(fixture.app)
    let button = try fixture.target(.cpu).button
    let command = try fixture.event(.memory, source: 0, modifiers: [.command])
    app.activateStatusButton(button, event: command)
    #expect(app.popover == nil)
    #expect(!app.routeStatusEvent(command))
    let key = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: fixture.statusWindows[0].windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    for event in [key, nil] {
      fixture.cursor = try fixture.screenPoint(.memory)
      app.activateStatusButton(button, event: event)
      #expect(app.detail?.selected == .cpu && app.popover?.isShown == true)
      app.popover?.animates = false
      app.popover?.close()
    }
    let stale = try fixture.event(.memory, source: 1)
    fixture.cursor = .init(x: -100_000, y: -100_000)
    app.activateStatusButton(button, event: stale)
    #expect(app.detail?.selected == .cpu)
  }

  @Test func invisibleDetachedAndOverflowedButtonsCannotHit() throws {
    let fixture = try MenuBarRoutingFixture(combined: true)
    defer { fixture.close() }
    let event = try fixture.event(.memory, source: 1)
    #expect(fixture.items.entry(for: event)?.module == .memory)
    let button = try fixture.target(.memory).button
    button.isHidden = true
    #expect(fixture.items.entry(for: event) == nil)
    button.isHidden = false
    fixture.statusWindows[0].orderOut(nil)
    #expect(fixture.items.entry(for: event) == nil)
    fixture.statusWindows[0].orderFrontRegardless()
    fixture.statusWindows[0].setFrameOrigin(.init(x: -100_000, y: -100_000))
    #expect(fixture.items.entry(for: event) == nil)
    button.removeFromSuperview()
    #expect(fixture.items.entry(for: event) == nil)
  }

  @Test func proxyWindowLocalCoordinatesAreNeverGuessedAndOwnWindowIsCrossChecked() throws {
    let fixture = try MenuBarRoutingFixture(combined: true)
    defer { fixture.close() }
    let app = try #require(fixture.app)
    app.activateStatusButton(try fixture.target(.cpu).button, event: nil)
    app.popover?.animates = false
    fixture.cursor = try fixture.screenPoint(.memory)
    // A nil/foreign process window can carry unusable local coordinates. The injected
    // handling-time mouse position is the sole coordinate source for this shape.
    let ambiguous = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .init(x: 3, y: 7), modifierFlags: [], timestamp: 1,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    #expect(app.popoverInteraction.handle(ambiguous) == nil)
    #expect(app.detail?.selected == .memory)
    let own = try fixture.event(.cpu, source: 0)
    fixture.cursor = try fixture.screenPoint(.memory)
    // Disagreement is observable, but the handling-time cursor wins rather than
    // trusting even a plausible local coordinate from another status window.
    #expect(
      PopoverInteraction.statusWindowPoint(own, statusButtons: fixture.items.targets.map(\.button))
        == (try fixture.screenPoint(.cpu)))
    #expect(fixture.items.entry(for: own)?.module == .memory)
    let invalidOwn = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .init(x: -900, y: -900), modifierFlags: [], timestamp: 1,
        windowNumber: fixture.statusWindows[0].windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 1))
    // A failed own-window cross-check falls back to the handling-time screen point.
    #expect(fixture.items.entry(for: invalidOwn)?.module == .memory)
  }

  @Test func clickTraceRequiresExactEnvironmentOptIn() {
    for environment in [[:], ["TINYSTATS_CLICK_TRACE": "0"], ["TINYSTATS_CLICK_TRACE": "true"]] {
      #expect(!MenuBarClickTrace(environment: environment).isEnabled)
    }
    #expect(MenuBarClickTrace(environment: ["TINYSTATS_CLICK_TRACE": "1"]).isEnabled)
  }
}
