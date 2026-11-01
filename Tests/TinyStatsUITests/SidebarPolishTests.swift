import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func sidebarDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + sidebarDescendants($0) }
}

@Test @MainActor func mainWindowSidebarClearsNativeTitlebarAndAlignsSubsections() throws {
  _ = NSApplication.shared
  let window = MainWindow()
  defer { window.close() }
  #expect(window.title == "TinyStats" && window.titleVisibility == .hidden)
  #expect(window.styleMask.contains(.fullSizeContentView))
  #expect(window.titlebarAppearsTransparent && window.titlebarSeparatorStyle == .none)
  #expect(!window.isMovableByWindowBackground)
  #expect(window.toolbar?.items.isEmpty == true)
  #expect(window.toolbar?.showsBaselineSeparator == false)
  for policy in ["glass", "solid", "contrast", "legacy"] {
    let detail = DetailController()
    detail.glassEnvironment = {
      .init(
        supportsGlass: policy != "legacy", reduceTransparency: policy == "solid",
        increaseContrast: policy == "contrast")
    }
    window.contentViewController = detail
    for size in [MainWindow.minimumSize, NSSize(width: 1200, height: 850)] {
      window.setContentSize(size)
      window.contentView?.layoutSubtreeIfNeeded()
      detail.view.layoutSubtreeIfNeeded()
      let root = detail.view
      let labels = sidebarDescendants(root).compactMap { $0 as? NSTextField }
      let brand = try #require(labels.first { $0.stringValue == "TinyStats" })
      let sidebar = try #require(brand.superview)
      let navigation = try #require(
        sidebarDescendants(root).compactMap { $0 as? NavigationButton }.first)
      let icon = try #require(navigation.subviews.compactMap { $0 as? NSImageView }.first)
      let iconX = icon.convert(icon.bounds, to: root).minX
      for title in ["Advanced", "Settings"] {
        let header = try #require(labels.first { $0.stringValue == title })
        #expect(abs(header.convert(header.bounds, to: root).minX - iconX) <= 0.5)
        #expect(header.font == NSFont.systemFont(ofSize: 11, weight: .regular))
      }
      // Both halves of the transparent top band retain native window dragging.
      let frameView = try #require(root.superview)
      for x: CGFloat in [110, 500] {
        let point = root.convert(.init(x: x, y: root.bounds.maxY - 20), to: frameView.superview)
        let hit = try #require(frameView.hitTest(point))
        #expect(hit.mouseDownCanMoveWindow)
      }
      let clearance = MainWindow.topContentInset(in: root)
      #expect(clearance > 0)
      let brandFrame = brand.convert(brand.bounds, to: root)
      #expect(abs(root.bounds.maxY - brandFrame.maxY - clearance - 12) < 0.5)
      for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(type))
        let frame = root.convert(button.bounds, from: button)
        let point = button.convert(
          NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView.superview)
        let hit = try #require(frameView.hitTest(point))
        #expect(hit === button || hit.isDescendant(of: button))
        #expect(!brandFrame.intersects(frame))
        #expect(brandFrame.maxY + 12 <= frame.minY)
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: root)
        #expect(sidebarFrame.minX <= frame.minX && sidebarFrame.maxX >= frame.maxX)
      }
      for module in Module.allCases {
        for all in [false, true] {
          detail.selected = module
          detail.showsAllReadings = all
          root.layoutSubtreeIfNeeded()
          for child in root.subviews
          where child !== sidebar && !child.isHidden && child.frame.minX >= 144 {
            #expect(child.frame.maxY <= root.bounds.maxY - clearance + 0.5)
            #expect(root.bounds.contains(child.frame))
          }
        }
      }
      let preferences = PreferencesController(
        settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
      defer {
        preferences.disposeEmbedded()
        preferences.close()
      }
      for page in [PreferencesController.Page.general, .menuBar] {
        let content = try #require(preferences.embeddedView(page: page))
        detail.showSettingsView(content, page: page)
        root.layoutSubtreeIfNeeded()
        #expect(content.frame.maxY <= root.bounds.maxY - clearance + 0.5)
        #expect(root.bounds.contains(content.frame))
      }
    }
  }
}

@Test @MainActor func sidebarSelectionFontsFollowActionsShortcutsAndSettingsWithoutFrameJitter()
  throws
{
  let detail = DetailController()
  let window = MainWindow()
  window.contentViewController = detail
  defer { window.close() }
  let preferences = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  defer {
    preferences.disposeEmbedded()
    preferences.close()
  }
  detail.onSettingsPage = { page in
    if let content = preferences.embeddedView(page: page) {
      detail.showSettingsView(content, page: page)
    }
  }
  detail.view.layoutSubtreeIfNeeded()
  let buttons = sidebarDescendants(detail.view).compactMap { $0 as? NavigationButton }
  #expect(buttons.count == 12)
  let frames = buttons.map(\.frame)
  func check(_ selected: NavigationButton) {
    detail.view.layoutSubtreeIfNeeded()
    for button in buttons {
      #expect(button.state == (button === selected ? .on : .off))
      #expect(
        button.font
          == NSFont.systemFont(ofSize: 12, weight: button === selected ? .semibold : .regular))
    }
    #expect(buttons.map(\.frame) == frames)
  }
  for button in buttons {
    #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    check(button)
  }
  // The native key-equivalent path shares the same action; no global event or real menu bar.
  for button in buttons where !button.keyEquivalent.isEmpty {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: button.keyEquivalent,
        charactersIgnoringModifiers: button.keyEquivalent, isARepeat: false, keyCode: 0))
    #expect(button.performKeyEquivalent(with: event))
    check(button)
  }
  detail.selected = .overview
  check(try #require(buttons.first { $0.module == .overview }))
}

@Test @MainActor func nativeTitlebarGeometryChangesRelayoutWithoutChangingRootSize() throws {
  let window = MainWindow()
  let detail = DetailController()
  window.contentViewController = detail
  defer { window.close() }
  let root = detail.view
  let size = root.bounds.size
  let brand = try #require(
    sidebarDescendants(root).compactMap { $0 as? NSTextField }.first {
      $0.stringValue == "TinyStats"
    })
  var clearances: [CGFloat] = []
  for visible in [true, false, true] {
    window.toolbar?.isVisible = visible
    window.displayIfNeeded()
    root.layoutSubtreeIfNeeded()
    let clearance = MainWindow.topContentInset(in: root)
    clearances.append(clearance)
    #expect(root.bounds.size == size)
    #expect(
      abs(root.bounds.maxY - brand.convert(brand.bounds, to: root).maxY - clearance - 12) < 0.5)
  }
  #expect(clearances[0] > clearances[1] && clearances[2] == clearances[0])
}
