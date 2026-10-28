import AppKit
import Testing
import TinyStatsCore

@testable import TinyStats

@Test @MainActor func internetChildPreferencesSurviveUnrelatedParentEdits() throws {
  let preferences = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  let custom = HTTPSCheckConfiguration(customURL: "https://health.invalid/", expectedStatus: 204)
  preferences.updateInternetSettings(
    connectivity: true, publicIP: true, revision: "new-choice", httpsCheck: custom,
    pingCheck: .init(enabled: true, destination: "127.0.0.1"))
  var saved: Settings?
  preferences.onChange = { saved = $0 }
  func descendants(_ root: NSView) -> [NSView] {
    var result = root.subviews
    for child in root.subviews { result.append(contentsOf: descendants(child)) }
    return result
  }
  let content = try #require(preferences.window?.contentView)
  let control = try #require(
    descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Use Fahrenheit" })
  let action = try #require(control.action)
  control.state = .on
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
  #expect(saved?.connectivityChecks == true && saved?.publicIPChecks == true)
  #expect(saved?.internetRevision == "new-choice" && saved?.httpsCheck == custom)
  #expect(saved?.pingCheck == .init(enabled: true, destination: "127.0.0.1"))
  preferences.updateInternetSettings(
    connectivity: false, publicIP: false, revision: "off-choice", httpsCheck: custom,
    pingCheck: .init())
  control.state = .off
  #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
  #expect(saved?.connectivityChecks == false && saved?.publicIPChecks == false)
  #expect(saved?.internetRevision == "off-choice")
}

@MainActor private func internetViews(_ root: NSView) -> [NSView] {
  root.subviews.flatMap { [$0] + internetViews($0) }
}
@MainActor private func internetAction(_ control: NSControl) throws {
  #expect(
    NSApplication.shared.sendAction(try #require(control.action), to: control.target, from: control)
  )
}
@Test @MainActor func customHTTPSDraftRequiresValidExplicitSaveAndCancelDoesNotApply() throws {
  let controller = InternetSettingsController(connectivity: false, publicIP: false)
  defer { controller.close() }
  let nativeWindow = try #require(controller.window)
  #expect(controller.windowWillReturnFieldEditor(nativeWindow, to: nil) == nil)
  #expect(controller.windowWillReturnFieldEditor(nativeWindow, to: NSButton()) == nil)
  var changes: [(Bool, Bool, HTTPSCheckConfiguration, ICMPCheckConfiguration)] = []
  controller.onChange = { changes.append(($0, $1, $2, $3)) }
  let views = internetViews(try #require(controller.window?.contentView))
  let preset = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
  let endpoint = try #require(
    views.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "HTTPS endpoint URL"
    })
  let status = try #require(
    views.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "Expected HTTP status"
    })
  let enable = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Enable HTTPS response check" })
  let save = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Save" })
  #expect(!endpoint.isEnabled && !status.isEnabled)
  preset.selectItem(at: 1)
  try internetAction(preset)
  #expect(endpoint.isEnabled && !save.isEnabled)
  #expect(
    views.compactMap { $0 as? NSTextField }.contains {
      $0.stringValue == "Invalid destination · no request"
    })
  enable.state = .on
  endpoint.stringValue = "http://health.invalid/"
  controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(!save.isEnabled && changes.isEmpty)
  try internetAction(save)
  #expect(changes.isEmpty)
  endpoint.stringValue = "https://health.invalid/ready"
  status.stringValue = "204"
  controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(save.isEnabled && changes.isEmpty)
  try internetAction(save)
  #expect(changes.count == 1 && changes[0].0 && !changes[0].1)
  #expect(changes[0].2 == .init(customURL: "https://health.invalid/ready", expectedStatus: 204))
  let cancelled = InternetSettingsController(
    connectivity: true, publicIP: false, httpsCheck: changes[0].2)
  defer { cancelled.close() }
  cancelled.onChange = { changes.append(($0, $1, $2, $3)) }
  let cancelledContent = try #require(cancelled.window?.contentView)
  let cancel = try #require(
    internetViews(cancelledContent).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
  try internetAction(cancel)
  #expect(changes.count == 1)
}

@Test @MainActor func pingDraftHasNoImplicitDestinationAndAppliesOnlyWithValidSave() throws {
  let controller = InternetSettingsController(connectivity: false, publicIP: false)
  defer { controller.close() }
  let views = internetViews(try #require(controller.window?.contentView))
  let toggle = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Enable ICMP ping" })
  let destination = try #require(
    views.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "ICMP destination IP address"
    })
  let save = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Save" })
  var saved: ICMPCheckConfiguration?
  controller.onChange = { _, _, _, ping in saved = ping }
  #expect(destination.stringValue.isEmpty && !destination.isEnabled && saved == nil)
  toggle.state = .on
  try internetAction(toggle)
  #expect(destination.isEnabled && !save.isEnabled && saved == nil)
  destination.stringValue = "example.com"
  controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(!save.isEnabled)
  destination.stringValue = "2001:0DB8::1"
  controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(save.isEnabled && saved == nil)
  try internetAction(save)
  #expect(saved == .init(enabled: true, destination: "2001:db8::1"))
  let cancelled = InternetSettingsController(
    connectivity: false, publicIP: false, pingCheck: try #require(saved))
  defer { cancelled.close() }
  cancelled.onChange = { _, _, _, ping in saved = ping }
  let cancelledContent = try #require(cancelled.window?.contentView)
  let cancel = try #require(
    internetViews(cancelledContent).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
  try internetAction(cancel)
  #expect(saved == .init(enabled: true, destination: "2001:db8::1"))
}

@Test @MainActor func internetSettingsOpensWithViewportInsideItsDocument() throws {
  let controller = InternetSettingsController(connectivity: false, publicIP: false)
  defer { controller.close() }
  let content = try #require(controller.window?.contentView)
  let scroll = try #require(internetViews(content).compactMap { $0 as? NSScrollView }.first)
  let document = try #require(scroll.documentView)
  let visible = scroll.documentVisibleRect
  #expect(visible.intersects(document.bounds))
  #expect(visible.minY >= document.bounds.minY && visible.maxY <= document.bounds.maxY)
  let toggle = try #require(
    internetViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Enable ICMP ping" })
  toggle.state = .on
  try internetAction(toggle)
  let disclosure = try #require(
    internetViews(content).compactMap { $0 as? NSTextField }.first {
      $0.stringValue.contains("Local destinations may request Local Network permission")
    })
  #expect(scroll.documentVisibleRect.contains(disclosure.frame))
}

@Test @MainActor func turningOffAnInvalidPingDraftCanSaveWithoutEnablingTraffic() throws {
  let controller = InternetSettingsController(connectivity: false, publicIP: false)
  defer { controller.close() }
  let views = internetViews(try #require(controller.window?.contentView))
  let toggle = try #require(
    views.compactMap { $0 as? NSButton }.first { $0.title == "Enable ICMP ping" })
  let destination = try #require(
    views.compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "ICMP destination IP address"
    })
  let save = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Save" })
  var saved: ICMPCheckConfiguration?
  controller.onChange = { _, _, _, ping in saved = ping }
  toggle.state = .on
  try internetAction(toggle)
  destination.stringValue = "router.local"
  controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(!save.isEnabled)
  toggle.state = .off
  try internetAction(toggle)
  #expect(save.isEnabled && !destination.isEnabled)
  try internetAction(save)
  #expect(saved == .init(enabled: false, destination: "router.local"))
}
