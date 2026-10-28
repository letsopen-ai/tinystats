import AppKit

@MainActor final class WeakView {
  weak var value: NSView?
  init(_ value: NSView) { self.value = value }
}
@MainActor final class Probe: NSObject, NSApplicationDelegate {
  var controller: NSWindowController?
  var retained: [[WeakView]] = []
  var pass = 0
  func applicationDidFinishLaunching(_ notification: Notification) { cycle() }
  func descendants(_ view: NSView) -> [NSView] {
    var result = [view]
    for child in view.subviews { result.append(contentsOf: descendants(child)) }
    return result
  }
  func cycle() {
    pass += 1
    autoreleasepool {
      let window = NSWindow(
        contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      controller = NSWindowController(window: window)
      let tabs = NSTabView(frame: window.contentView!.bounds)
      tabs.tabViewType = .noTabsBezelBorder
      window.contentView!.addSubview(tabs)
      var tracked = [NSView]()
      for name in ["General", "Menu Bar"] {
        let item = NSTabViewItem(identifier: name)
        let view = NSView(frame: tabs.bounds)
        let button = NSPopUpButton(frame: .init(x: 20, y: 100, width: 180, height: 24))
        button.addItems(withTitles: ["Percentage", "Time"])
        view.addSubview(button)
        item.view = view
        item.label = name
        tabs.addTabViewItem(item)
        tracked.append(contentsOf: descendants(view))
      }
      tabs.selectTabViewItem(at: 1)
      tabs.selectTabViewItem(at: 0)
      retained.append(([tabs] + tracked).map(WeakView.init))
      window.center()
      controller?.showWindow(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
      if CommandLine.arguments.contains("--detach-tabs"), let root = controller?.window?.contentView
      {
        for tabs in root.subviews.compactMap({ $0 as? NSTabView }) {
          for item in tabs.tabViewItems {
            tabs.removeTabViewItem(item)
            item.view = nil
          }
        }
      }
      controller?.close()
      Task { @MainActor [self] in controller = nil }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
        print(
          "cycle=\(pass) live_views_by_cycle=\(retained.map { $0.filter { $0.value != nil }.count })"
        )
        fflush(stdout)
        if pass < 3 { cycle() } else { NSApp.terminate(nil) }
      }
    }
  }
}
let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
