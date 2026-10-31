import AppKit
import TinyStatsCore

/// A live production-renderer preview; examples are explicit and never enter the sampler/settings.
@MainActor final class BatteryMenuController: NSWindowController {
  var onChange: ((BatteryMenuSettings) -> Void)?
  private var settings: Settings
  private var latest: Snapshot
  private var history: [HistoryPoint]
  private let format = NSPopUpButton()
  private let customize = SystemSettingSwitch(
    title: "Use different displays for each power state", target: nil, action: nil)
  private let example = NSPopUpButton()
  private let preview = MenuBarPreviewView(frame: .zero)
  private let scroll = NSScrollView()
  private let context = NSTextField(wrappingLabelWithString: "")
  private var formatMenus: [BatteryMenuState: NSPopUpButton] = [:]
  private var styleMenus: [BatteryMenuState: MenuBarStylePicker] = [:]
  private var barAppearance: NSAppearance?
  private var barHeight = NSStatusBar.system.thickness
  private var paused = false
  init(settings: Settings, snapshot: Snapshot, history: [HistoryPoint]) {
    self.settings = settings
    latest = snapshot
    self.history = history
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 660, height: 540),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Battery Menu Bar Format"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.appearance = settings.theme.nativeAppearance
    window.contentView = SystemSettingsBackgroundView(frame: window.contentView?.bounds ?? .zero)
    guard let root = window.contentView else { return }
    func add(_ view: NSView, _ x: Int, _ y: Int, _ width: Int, _ height: Int = 26) {
      view.frame = .init(x: x, y: y, width: width, height: height)
      root.addSubview(view)
    }
    func label(_ title: String, _ x: Int, _ y: Int, _ width: Int) {
      add(NSTextField(labelWithString: title), x, y, width)
    }
    label("Battery display", 24, 490, 350)
    label("Preview", 24, 450, 100)
    example.addItems(
      withTitles: ["Live reading"] + BatteryMenuState.allCases.map { "Example · \($0.title)" })
    example.setAccessibilityLabel("Battery preview source")
    example.target = self
    example.action = #selector(previewChanged)
    add(example, 150, 450, 330)
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = false
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = .windowBackgroundColor
    scroll.borderType = .bezelBorder
    scroll.documentView = preview
    scroll.setAccessibilityLabel("Battery live menu bar preview")
    add(scroll, 24, 390, 612, 50)
    label("Default format", 24, 348, 120)
    format.addItems(withTitles: BatteryMenuFormat.allCases.map(\.title))
    format.setAccessibilityLabel("Default battery menu bar format")
    format.target = self
    format.action = #selector(changed)
    add(format, 150, 348, 330)
    customize.target = self
    customize.action = #selector(changed)
    add(customize, 24, 310, 612)
    label("Power state", 24, 278, 120)
    label("Format", 150, 278, 190)
    label("Style", 354, 278, 260)
    for (index, state) in BatteryMenuState.allCases.enumerated() {
      let y = 244 - index * 36
      label(state == .externalPower ? "On AC" : state.title, 24, y, 126)
      let value = NSPopUpButton()
      value.addItems(withTitles: BatteryMenuFormat.allCases.map(\.title))
      value.setAccessibilityLabel("\(state.title) battery format")
      let style = MenuBarStylePicker(module: .battery, settings: settings, batteryState: state)
      style.setAccessibilityLabel("\(state.title) battery style")
      value.font = .systemFont(ofSize: 11)
      for control in [value as NSControl, style] {
        control.target = self
        control.action = #selector(changed)
      }
      formatMenus[state] = value
      styleMenus[state] = style
      add(value, 150, y, 194)
      add(style, 354, y, 282)
    }
    context.font = .systemFont(ofSize: 11)
    context.textColor = .secondaryLabelColor
    add(context, 24, 66, 612, 54)
    let hint = NSTextField(
      wrappingLabelWithString:
        "Changes apply immediately. Examples affect the preview only. Time estimates come from macOS; unavailable estimates stay —. Gauges and histories always show battery percentage."
    )
    hint.font = .systemFont(ofSize: 10)
    hint.textColor = .secondaryLabelColor
    add(hint, 24, 16, 612, 42)
    let form = SystemSettingsForm.self
    scroll.heightAnchor.constraint(equalToConstant: 50).isActive = true
    var stateRows: [SystemFormRow] = []
    for state in BatteryMenuState.allCases {
      if let value = formatMenus[state], let style = styleMenus[state] {
        let group = NSStackView(views: [
          form.controls(
            [SystemSettingsForm.text(state.title, heading: true), value], widths: [140, 180]),
          style,
        ])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        for child in group.arrangedSubviews {
          child.translatesAutoresizingMaskIntoConstraints = false
          child.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        stateRows.append(form.row("", group))
      }
    }
    _ = SystemSettingsForm(
      in: root,
      views: [
        form.text("Preview", heading: true),
        form.group([
          form.row("Source", example, width: 330), form.row("", scroll, height: 64),
        ]), context,
        form.text("Battery display", heading: true),
        form.group([
          form.row("Default format", format, width: 330), form.row(customize.title, customize),
        ]), form.text("Power state · format and style", heading: true), form.group(stateRows), hint,
      ])
    synchronizeControls()
    updatePreview()
  }
  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    updatePreview()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func updateSettings(_ value: Settings) {
    guard settings != value else { return }
    settings = value
    window?.appearance = settings.theme.nativeAppearance
    synchronizeControls()
    if window?.isVisible == true { updatePreview() }
  }
  func update(_ snapshot: Snapshot, history: [HistoryPoint]) {
    latest = snapshot
    self.history = history
    if window?.isVisible == true { updatePreview() }
  }
  func updateMenuBarContext(appearance: NSAppearance?, height: CGFloat, paused: Bool) {
    barAppearance = appearance
    if height > 0 && height <= 100 { barHeight = height }
    self.paused = paused
    if window?.isVisible == true { updatePreview() }
  }
  private func synchronizeControls() {
    format.selectItem(withTitle: settings.batteryMenu.format.title)
    customize.state = settings.batteryMenu.customizeStates ? .on : .off
    format.isEnabled =
      !settings.batteryMenu.customizeStates && settings.style(for: .battery).showsBatteryValue
    format.toolTip =
      "Value formats apply to text styles. Gauges, icons and plain histories show battery level."
    for state in BatteryMenuState.allCases {
      formatMenus[state]?.selectItem(withTitle: settings.batteryMenu[state].format.title)
      styleMenus[state]?.update(settings: settings)
      formatMenus[state]?.isEnabled =
        settings.batteryMenu.customizeStates && settings.batteryMenu[state].style.showsBatteryValue
      formatMenus[state]?.toolTip = "Choose a text style to display this value."
      styleMenus[state]?.isEnabled = settings.batteryMenu.customizeStates
    }
  }
  @objc private func changed() {
    var value = settings.batteryMenu
    value.format = BatteryMenuFormat.allCases[max(0, format.indexOfSelectedItem)]
    value.customizeStates = customize.state == .on
    for state in BatteryMenuState.allCases {
      if let field = formatMenus[state], let style = styleMenus[state] {
        value[state] = .init(
          format: BatteryMenuFormat.allCases[max(0, field.indexOfSelectedItem)],
          style: style.selectedStyle ?? settings.batteryMenu[state].style)
      }
    }
    value.validate()
    settings.batteryMenu = value
    synchronizeControls()
    updatePreview()
    onChange?(value)
  }
  @objc private func previewChanged() { updatePreview() }
  private func updatePreview() {
    var snapshot = latest
    let isExample = example.indexOfSelectedItem > 0
    if isExample {
      let state = BatteryMenuState.allCases[example.indexOfSelectedItem - 1]
      snapshot.batteries = [
        .init(
          name: "Example battery",
          percent: state == .charged ? 100 : state == .externalPower ? 80 : 72,
          charging: state == .charging, externalPower: state != .draining,
          minutesRemaining: state == .draining ? 195 : state == .charging ? 65 : nil,
          cycles: nil, health: nil,
          watts: state == .draining ? -8.4 : state == .charging ? 17.2 : 0,
          fullyCharged: state == .charged)
      ]
    }
    preview.appearance = barAppearance
    scroll.appearance = barAppearance
    let reading = MenuBarReadout.make(
      module: .battery, snapshot: snapshot, settings: settings,
      history: isExample ? [] : history)
    preview.update(
      groups: [[reading]], paused: isExample ? false : paused, height: barHeight,
      spacing: settings.menuBarSpacing)
    preview.frame.size = .init(width: max(610, preview.preferredWidth), height: max(36, barHeight))
    preview.needsDisplay = true
    let state =
      snapshot.batteries.first.map { BatteryMenuState.state(for: $0).title }
      ?? "No internal battery reading"
    context.stringValue =
      "\(isExample ? "Example" : "Live") · \(state)\n"
      + (settings.readouts.contains(.battery)
        ? "Enabled in the menu bar." : "Preview only · enable Battery in Menu Bar to display it.")
      + (settings.batteryMenu.customizeStates
        ? " Per-state styles override the main Battery style."
        : " Uses the main Battery style, font and color.")
  }
}
