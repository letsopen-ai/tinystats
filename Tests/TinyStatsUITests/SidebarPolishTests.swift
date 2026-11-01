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
  #expect(window.toolbarStyle == .unified)
  #expect(window.frame.size == NSSize(width: 884, height: 692))
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
    window.orderFrontRegardless()
    window.displayIfNeeded()
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
      let geometry = MainWindow.titlebarGeometry(in: root)
      let clearance = geometry.pageInset
      #expect(clearance > 0)
      let brandFrame = brand.convert(brand.bounds, to: root)
      #expect(abs(root.bounds.maxY - brandFrame.maxY - geometry.brandTop) < 0.5)
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
      let weather = try #require(
        sidebarDescendants(root).compactMap { $0 as? NavigationButton }.first {
          $0.module == .weather
        })
      let sensors = try #require(
        sidebarDescendants(root).compactMap { $0 as? NavigationButton }.first {
          $0.module == .sensors
        })
      let advanced = try #require(labels.first { $0.stringValue == "Advanced" })
      #expect(weather.frame.minY - advanced.frame.maxY == 16)
      #expect(advanced.frame.minY - sensors.frame.maxY == 6)
      let settings = try #require(labels.first { $0.stringValue == "Settings" })
      let general = try #require(
        sidebarDescendants(root).compactMap { $0 as? NavigationButton }.first {
          $0.title == "General"
        })
      #expect(settings.frame.minY - general.frame.maxY == 6)
      for module in Module.allCases {
        for all in [false, true] {
          detail.selected = module
          detail.showsAllReadings = all
          root.layoutSubtreeIfNeeded()
          let pageTitle = try #require(
            root.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == module.title }
          )
          #expect(abs(pageTitle.frame.maxY - brandFrame.maxY) < 0.5)
          for child in root.subviews
          where child !== sidebar && !child.isHidden && child.frame.minX >= 144 {
            #expect(child.frame.maxY <= root.bounds.maxY - clearance + 0.5)
            #expect(root.bounds.contains(child.frame))
            if child is NSControl {
              let point = child.convert(
                NSPoint(x: child.bounds.midX, y: child.bounds.midY), to: frameView.superview)
              let hit = try #require(frameView.hitTest(point))
              #expect(hit === child || hit.isDescendant(of: child))
            }
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
        let form = try #require(
          sidebarDescendants(content).compactMap { $0 as? SystemSettingsForm }.first {
            !$0.isHiddenOrHasHiddenAncestor
          })
        #expect(!form.automaticallyAdjustsContentInsets && form.contentInsets.top == 0)
        let document = try #require(form.documentView)
        let stack = try #require(document.subviews.compactMap { $0 as? NSStackView }.first)
        let first = try #require(stack.arrangedSubviews.first)
        #expect(abs(first.convert(first.bounds, to: root).maxY - brandFrame.maxY) <= 3)
      }
    }
  }
}

@Test @MainActor func sidebarSelectionFontsFollowActionsShortcutsAndSettingsWithoutFrameJitter()
  throws
{
  _ = NSApplication.shared
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
        (button.cell?.accessibilityValue() as? NSNumber)?.intValue == (button === selected ? 1 : 0))
      #expect(
        button.font
          == NSFont.systemFont(ofSize: 12, weight: button === selected ? .semibold : .regular))
    }
    #expect(buttons.map(\.frame) == frames)
  }
  for button in buttons {
    button.performClick(nil)
    check(button)
    button.performClick(nil)
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
  _ = NSApplication.shared
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
    let clearance = MainWindow.titlebarGeometry(in: root).brandTop
    clearances.append(clearance)
    #expect(root.bounds.size == size)
    #expect(
      abs(root.bounds.maxY - brand.convert(brand.bounds, to: root).maxY - clearance) < 0.5)
  }
  #expect(clearances[0] > clearances[1] && clearances[2] == clearances[0])
}

@Test @MainActor func fullScreenGeometryIgnoresForeignButtonsAndTracksToolbarReveal() throws {
  _ = NSApplication.shared
  let window = MainWindow()
  let other = MainWindow()
  defer {
    window.close()
    other.close()
  }
  let root = try #require(window.contentView)
  let local = try #require(window.standardWindowButton(.closeButton))
  let foreign = try #require(other.standardWindowButton(.closeButton))
  let localFrames = MainWindow.localButtonFrames(in: root, buttons: [foreign, local])
  #expect(localFrames == [root.convert(local.bounds, from: local)])
  local.isHidden = true
  #expect(MainWindow.localButtonFrames(in: root, buttons: [foreign, local]).isEmpty)
  let bounds = NSRect(x: 0, y: 0, width: 884, height: 692)
  var insets: [CGFloat] = []
  for toolbarHeight: CGFloat in [0, 52, 0] {
    let geometry = MainWindow.titlebarGeometry(
      bounds: bounds, layoutRect: NSRect(x: 0, y: 0, width: 884, height: 692 - toolbarHeight),
      isFullScreen: true, buttonFrames: [NSRect(x: 20, y: -10_000, width: 14, height: 14)])
    #expect(geometry.nativeInset == toolbarHeight)
    #expect(geometry.brandTop == toolbarHeight + 12)
    #expect(bounds.height - geometry.pageInset >= 650)
    #expect(geometry.brandTop + 400 < bounds.height - 120)
    insets.append(geometry.pageInset)
  }
  #expect(insets == [0, 42, 0])
}

@Test @MainActor func titleBandDoubleClickRespectsSystemAction() {
  _ = NSApplication.shared
  #expect(TitlebarDragRegion.doubleClickAction("Minimize") == .minimize)
  #expect(TitlebarDragRegion.doubleClickAction("Maximize") == .zoom)
  #expect(TitlebarDragRegion.doubleClickAction("None") == .none)
  #expect(TitlebarDragRegion.doubleClickAction(nil) == .zoom)
}
