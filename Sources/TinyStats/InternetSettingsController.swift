import AppKit
import TinyStatsCore

@MainActor
final class InternetSettingsController: NSWindowController, NSWindowDelegate,
  NSTextFieldDelegate
{
  var onChange: ((Bool, Bool, HTTPSCheckConfiguration, ICMPCheckConfiguration) -> Void)?
  var onClose: (() -> Void)?
  private let connectivity = NSButton(
    checkboxWithTitle: "Enable HTTPS response check", target: nil, action: nil)
  private let publicIP = NSButton(
    checkboxWithTitle: "Discover public IPv4 and IPv6 with ipify", target: nil, action: nil)
  private let preset = NSPopUpButton()
  private let endpoint = NSTextField(string: "")
  private let status = NSTextField(string: "200")
  private let preview = NSTextField(labelWithString: "")
  private let expectedPreview = NSTextField(labelWithString: "")
  private let issue = NSTextField(wrappingLabelWithString: "")
  private let ping = NSButton(checkboxWithTitle: "Enable ICMP ping", target: nil, action: nil)
  private let pingAddress = NSTextField(string: "")
  private let pingPreview = NSTextField(wrappingLabelWithString: "")
  private let save = NSButton(title: "Save", target: nil, action: nil)
  init(
    connectivity: Bool, publicIP: Bool, httpsCheck: HTTPSCheckConfiguration = .init(),
    pingCheck: ICMPCheckConfiguration = .init()
  ) {
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 600, height: 740),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "TinyStats Internet Checks"
    window.isReleasedWhenClosed = false
    window.minSize = .init(width: 600, height: 580)
    window.center()
    super.init(window: window)
    window.delegate = self
    guard let content = window.contentView else { return }
    let scroll = NSScrollView(frame: .init(x: 0, y: 70, width: 600, height: 670))
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    let body = NSView(frame: .init(x: 0, y: 0, width: 600, height: 740))
    body.autoresizingMask = [.width]
    scroll.documentView = body
    content.addSubview(scroll)
    func add(_ view: NSView, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
      view.frame = .init(x: x, y: y + 170, width: w, height: h)
      if w > 300 { view.autoresizingMask = [.width] }
      body.addSubview(view)
    }
    func footer(_ view: NSView, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
      view.frame = .init(x: x, y: y, width: w, height: h)
      view.autoresizingMask = x > 365 ? [.minXMargin] : [.width]
      content.addSubview(view)
    }
    func label(_ text: String, _ y: Int, _ height: Int = 40) {
      let field = NSTextField(wrappingLabelWithString: text)
      field.font = .systemFont(ofSize: 11)
      field.textColor = .secondaryLabelColor
      add(field, 24, y, 552, height)
    }
    let heading = NSTextField(labelWithString: "Optional advanced internet checks")
    heading.font = .systemFont(ofSize: 19, weight: .semibold)
    add(heading, 24, 538, 552, 30)
    label(
      "Off by default; no requests until you enable and Save. Enabled checks continue with details closed. Each destination sees your source IP address. Changes take effect when you Save.",
      482, 48)
    self.connectivity.state = connectivity ? .on : .off
    self.publicIP.state = publicIP ? .on : .off
    add(self.connectivity, 24, 448, 552, 26)
    preset.addItems(withTitles: [
      "Apple success page · content verified", "Custom HTTPS endpoint · status verified",
    ])
    preset.selectItem(at: httpsCheck.isCustom ? 1 : 0)
    preset.target = self
    preset.action = #selector(changed(_:))
    add(preset, 24, 409, 552, 28)
    endpoint.placeholderString = "https://example.com/health"
    endpoint.stringValue = httpsCheck.customURL
    endpoint.setAccessibilityLabel("HTTPS endpoint URL")
    status.stringValue = String(httpsCheck.expectedStatus)
    status.setAccessibilityLabel("Expected HTTP status")
    for field in [endpoint, status] {
      field.delegate = self
      field.isAutomaticTextCompletionEnabled = false
      field.usesSingleLineMode = true
    }
    add(endpoint, 24, 370, 552, 26)
    let expected = NSTextField(labelWithString: "Expected status")
    add(expected, 24, 336, 130, 22)
    add(status, 159, 332, 76, 26)
    preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    preview.lineBreakMode = .byTruncatingMiddle
    preview.usesSingleLineMode = true
    add(preview, 24, 292, 552, 24)
    expectedPreview.font = .systemFont(ofSize: 11, weight: .medium)
    add(expectedPreview, 24, 264, 552, 24)
    label(
      "GET every 60 seconds; full HTTPS response time, not ping. Custom checks match one chosen 2xx status only, with a 1 KiB response limit. Use a small health endpoint. HTTPS port 443 only; no credentials, query or fragment. URLs are saved locally; keep secrets out of paths.",
      190, 65)
    add(self.publicIP, 24, 157, 552, 26)
    label(
      "GET https://api.ipify.org and https://api6.ipify.org every 5 minutes per family. HTTPS and public-IP requests follow the system route, proxy or VPN, independently of the selected link interface.",
      103, 49)
    label(
      "No cookies, stored credentials or redirects. Pause/sleep cancel requests. Network route changes may refresh sooner, at most once per 10 seconds per check.",
      57, 42)
    issue.font = .systemFont(ofSize: 11)
    issue.textColor = .systemRed
    issue.maximumNumberOfLines = 2
    ping.state = pingCheck.enabled ? .on : .off
    ping.target = self
    ping.action = #selector(changed(_:))
    add(ping, 24, 10, 552, 26)
    pingAddress.stringValue = pingCheck.destination
    pingAddress.placeholderString = "IPv4 or IPv6 address"
    pingAddress.setAccessibilityLabel("ICMP destination IP address")
    pingAddress.delegate = self
    pingAddress.isAutomaticTextCompletionEnabled = false
    pingAddress.usesSingleLineMode = true
    add(pingAddress, 24, -24, 552, 26)
    pingPreview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    add(pingPreview, 24, -57, 552, 30)
    label(
      "One ICMP echo every 30 seconds; 5-second reply window. No DNS lookup. Link-local IPv6 needs an interface name, such as %en0. No reply does not mean offline.",
      -110, 48)
    label(
      "ICMP follows the system route or VPN, bypasses HTTP proxies, and does not follow the selected link interface. Local destinations may request Local Network permission.",
      -163, 48)
    footer(issue, 24, 7, 365, 54)
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelled))
    cancel.keyEquivalent = "\u{1b}"
    footer(cancel, 400, 18, 80, 30)
    save.target = self
    save.action = #selector(saved)
    save.keyEquivalent = "\r"
    footer(save, 490, 18, 86, 30)
    scroll.contentView.scroll(
      to: .init(x: 0, y: max(0, body.bounds.height - scroll.contentView.bounds.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    refresh()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func windowWillClose(_ notification: Notification) { onClose?() }
  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard client is NSTextField else { return nil }
    return LiteralFieldEditor.prepare(in: sender)
  }
  func controlTextDidChange(_ notification: Notification) { refresh() }
  private var draft: HTTPSCheckConfiguration {
    preset.indexOfSelectedItem == 0
      ? .init()
      : .init(
        customURL: endpoint.stringValue, expectedStatus: Int(status.stringValue) ?? 0)
  }
  private func refresh() {
    let custom = preset.indexOfSelectedItem == 1
    endpoint.isEnabled = custom
    status.isEnabled = custom
    let configuration = draft
    let error =
      custom && configuration.customURL.isEmpty
      ? "Enter an HTTPS endpoint." : configuration.validationError
    let pingError = ping.state == .on ? pingDraft.validationError : nil
    issue.stringValue = error ?? pingError ?? ""
    save.isEnabled = error == nil && pingError == nil
    pingAddress.isEnabled = ping.state == .on
    pingPreview.stringValue =
      ping.state != .on
      ? "Ping off · no ICMP requests"
      : pingDraft.canonicalDestination.map { "ICMP echo → " + $0 }
        ?? "Invalid destination · no ICMP request"
    let requestURL = error == nil ? configuration.url : nil
    preview.stringValue =
      requestURL.map {
        "GET \($0.absoluteString)"
      } ?? "Invalid destination · no request"
    preview.toolTip = requestURL?.absoluteString
    expectedPreview.stringValue =
      error == nil
      ? "Expected: HTTP \(configuration.expectedStatus)\(custom ? " · status only" : " + Apple success content")"
      : "Correct the configuration before saving."
  }
  private var pingDraft: ICMPCheckConfiguration {
    .init(enabled: ping.state == .on, destination: pingAddress.stringValue)
  }
  @objc private func changed(_ sender: NSControl) {
    refresh()
    if sender === ping, ping.state == .on {
      // Bring the chosen destination and complete ICMP/privacy disclosure into view together.
      _ = pingAddress.superview?.scrollToVisible(.init(x: 0, y: 0, width: 500, height: 255))
    }
  }
  @objc private func saved() {
    refresh()
    guard save.isEnabled else { return }
    var savedPing = pingDraft
    if let canonical = savedPing.canonicalDestination { savedPing.destination = canonical }
    onChange?(connectivity.state == .on, publicIP.state == .on, draft, savedPing)
    close()
  }
  @objc private func cancelled() { close() }
}
