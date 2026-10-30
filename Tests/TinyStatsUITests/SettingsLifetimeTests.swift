import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@Test @MainActor func closingSettingsReleasesPagesEvenIfNativeTabViewIsRetained() throws {
  _ = NSApplication.shared
  weak var parent: PreferencesController?
  weak var window: NSWindow?
  var retainedTabs: NSTabView?
  weak var generalPage: NSView?
  weak var menuBarPage: NSView?
  weak var preview: MenuBarPreviewView?
  weak var customization: MenuBarCustomization?
  weak var chip: MenuBarChip?
  weak var editor: NSWindowController?
  try autoreleasepool {
    let controller = PreferencesController(
      settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [], initialPage: .menuBar
    )
    parent = controller
    window = controller.window
    let root = try #require(controller.window?.contentView)
    let tabs = try #require(root.subviews.compactMap { $0 as? NSTabView }.first)
    // Model the native run-loop retention observed after the last window closes.
    retainedTabs = tabs
    generalPage = tabs.tabViewItems[0].view
    menuBarPage = tabs.tabViewItems[1].view
    @MainActor func descendants(_ view: NSView) -> [NSView] {
      var result = view.subviews
      for child in view.subviews { result.append(contentsOf: descendants(child)) }
      return result
    }
    preview = try #require(descendants(root).compactMap { $0 as? MenuBarPreviewView }.first)
    customization = try #require(descendants(root).compactMap { $0 as? MenuBarCustomization }.first)
    chip = customization?.chips[.cpu]
    // Materialize custom action closures as a VoiceOver client would before closing.
    #expect(chip?.accessibilityCustomActions()?.isEmpty == false)
    let battery = try #require(
      descendants(root).compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Battery menu bar formats"
      })
    let action = try #require(battery.action)
    #expect(NSApplication.shared.sendAction(action, to: battery.target, from: battery))
    editor = try #require(
      NSApp.windows.first {
        $0.title == "Battery Menu Bar Format" && $0.isVisible
      }?.windowController)
    let selector = try #require(root.subviews.compactMap { $0 as? NSSegmentedControl }.first)
    selector.selectedSegment = 0
    #expect(
      NSApplication.shared.sendAction(
        try #require(selector.action), to: selector.target, from: selector))
    controller.showWindow(nil)
    controller.window?.display()
    editor?.window?.display()
    controller.close()
  }
  #expect(parent == nil)
  #expect(editor == nil)
  #expect(window == nil)
  #expect(retainedTabs != nil)
  #expect(generalPage == nil)
  #expect(menuBarPage == nil)
  #expect(preview == nil)
  #expect(customization == nil && chip == nil)
}
