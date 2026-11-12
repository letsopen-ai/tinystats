import AppKit
import TinyStatsCore

@MainActor final class UpdateSettingsView: NSStackView {
  let check = SystemSettingSwitch(title: "Check for updates automatically")
  let download = SystemSettingSwitch(title: "Download updates automatically")
  let status = SystemSettingsForm.text("")
  let note = SystemSettingsForm.text("")
  let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
  let restart = NSButton(title: "Restart to Update", target: nil, action: nil)
  var onPreferences: ((Bool, Bool) -> Void)?
  var onCheck: (() -> Void)?
  var onRestart: (() -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    check.target = self
    check.action = #selector(changed)
    download.target = self
    download.action = #selector(changed)
    check.toolTip = "Check GitHub once a day. Sends the app version and no personal identifiers."
    download.toolTip = "Prepare verified updates in the background and install them on normal quit."
    checkNow.target = self
    checkNow.action = #selector(checkClicked)
    restart.target = self
    restart.action = #selector(restartClicked)
    for button in [checkNow, restart] { button.bezelStyle = .rounded }
    let form = SystemSettingsForm.self
    for child in [
      form.group([
        form.row(check.title, check), form.row(download.title, download),
        form.row("", form.controls([status, checkNow, restart])),
      ]), note,
    ] {
      addArrangedSubview(child)
      child.translatesAutoresizingMaskIntoConstraints = false
      child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    checkNow.setContentHuggingPriority(.required, for: .horizontal)
    restart.setContentHuggingPriority(.required, for: .horizontal)
    update(UpdatePresentation())
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(_ value: UpdatePresentation) {
    check.state = value.preferences.automaticallyCheck ? .on : .off
    download.state = value.preferences.automaticallyDownload ? .on : .off
    check.isEnabled = value.eligible
    download.isEnabled = value.eligible && value.preferences.automaticallyCheck
    checkNow.isEnabled = !value.busy
    checkNow.isHidden = value.readyIdentifier != nil
    restart.isHidden = value.readyVersion == nil
    restart.isEnabled = !value.busy
    restart.title = value.canInstall ? "Restart to Update" : "Open Release Page"
    restart.setAccessibilityLabel(value.canInstall ? value.restartTitle : "Open Release Page")
    status.stringValue = value.status
    note.stringValue =
      value.eligible
      ? value.preferences.automaticallyCheck
        ? "Checks GitHub daily · sends only the app version"
        : "Automatic checks off · Check Now contacts GitHub"
      : "This build doesn’t receive updates. Install a signed release from GitHub."
    restart.toolTip = value.restartTitle
  }
  @objc private func changed() { onPreferences?(check.state == .on, download.state == .on) }
  @objc private func checkClicked() { onCheck?() }
  @objc private func restartClicked() { onRestart?() }
}
