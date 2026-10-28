import AppKit
import TinyStatsCore

/// Bounded draft editing with the production renderer. No window-owned clock or sampling timer.
@MainActor
final class ClockMenuController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
  var onChange: ((ClockMenuSettings) -> Void)?
  var onPreviewDemand: ((Bool?) -> Void)?
  private var settings: Settings
  private var drafts: [ClockMenuEntry]
  private var selected = 0
  private var date: Date
  private var barAppearance: NSAppearance?
  private var barHeight = NSStatusBar.system.thickness
  private var paused = false
  private let preview = MenuBarPreviewView(frame: .zero), scroll = NSScrollView()
  private let custom = NSButton(
    checkboxWithTitle: "Use custom clock formats", target: nil, action: nil)
  private let clocks = NSPopUpButton(), zones = NSPopUpButton(), presets = NSPopUpButton()
  private let tokens = NSPopUpButton(), targetLine = NSPopUpButton()
  private let name = NSTextField(), zone = NSTextField(), first = NSTextField(),
    second = NSTextField()
  private let message = NSTextField(wrappingLabelWithString: "")
  private let save = NSButton(title: "Save clocks", target: nil, action: nil)
  private let addClock = NSButton(title: "+", target: nil, action: nil)
  private let removeClock = NSButton(title: "−", target: nil, action: nil)
  private let left = NSButton(title: "‹", target: nil, action: nil)
  private let right = NSButton(title: "›", target: nil, action: nil)
  private var suggestedZones = [String]()
  private var lastDemand: Bool?
  private static let clockPresets: [(title: String, first: String, second: String)] = [
    ("24-hour time", "{hour24}:{minute}", ""),
    ("12-hour time", "{hour12}:{minute} {period}", ""),
    ("Date + time", "{weekday} {day} {monthName}", "{hour24}:{minute}"),
    ("Time with seconds", "{weekdayUpper}", "{hour24}:{minute}:{second}"),
    ("System time", "{systemTime}", ""),
    ("System time with seconds", "{systemTimeSeconds}", ""),
    ("Analogue clock", "{analog}", ""),
    ("Analogue with seconds", "{analogSeconds}", ""),
    ("Calendar + time", "{calendar} {hour24}:{minute}", ""),
    ("Calendar + analogue", "{calendar} {analog}", ""),
    ("Fuzzy time", "{fuzzy}", ""),
    ("Time difference", "{name} {localOffset}", "{hour24}:{minute}"),
  ]
  init(settings: Settings, date: Date) {
    self.settings = settings
    drafts = settings.clockMenu.entries
    self.date = date
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Clock Menu Bar Formats"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    window.appearance = settings.theme.nativeAppearance
    guard let root = window.contentView else { return }
    func add(_ view: NSView, _ x: Int, _ y: Int, _ width: Int, _ height: Int = 26) {
      view.frame = .init(x: x, y: y, width: width, height: height)
      root.addSubview(view)
    }
    func label(_ title: String, _ y: Int) { add(NSTextField(labelWithString: title), 24, y, 112) }
    let heading = NSTextField(labelWithString: "Clock displays")
    heading.font = .systemFont(ofSize: 18, weight: .semibold)
    add(heading, 24, 592, 650, 30)
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = false
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.borderType = .bezelBorder
    scroll.documentView = preview
    scroll.setAccessibilityLabel("Clock live menu bar preview")
    add(scroll, 24, 532, 672, 50)
    custom.target = self
    custom.action = #selector(draftChanged)
    add(custom, 24, 490, 650)
    label("Clock", 450)
    clocks.target = self
    clocks.action = #selector(selectClock)
    clocks.setAccessibilityLabel("Clock to edit")
    add(clocks, 140, 450, 300)
    for (button, action, title, x) in [
      (addClock, #selector(addEntry), "Add clock", 456),
      (removeClock, #selector(removeEntry), "Remove clock", 500),
      (left, #selector(moveEntry(_:)), "Move clock left", 544),
      (right, #selector(moveEntry(_:)), "Move clock right", 588),
    ] {
      button.target = self
      button.action = action
      button.bezelStyle = .rounded
      button.setAccessibilityLabel(title)
      add(button, x, 450, 38)
    }
    for (field, title, y) in [
      (name, "Clock name", 404), (zone, "Time zone", 364), (first, "First line", 324),
      (second, "Second line", 284),
    ] {
      label(title, y)
      field.delegate = self
      field.setAccessibilityLabel(title)
      field.placeholderString =
        field === zone
        ? "local or IANA zone, e.g. Europe/London"
        : field === second ? "Leave empty for one line" : ""
      add(field, 140, y, field === zone ? 400 : 556)
    }
    suggestedZones = ["local", "UTC"]
    for value in settings.worldClocks where !suggestedZones.contains(value) {
      suggestedZones.append(value)
    }
    zones.addItems(
      withTitles: ["Choose zone…"] + suggestedZones.map { $0 == "local" ? "Local" : $0 })
    zones.target = self
    zones.action = #selector(chooseZone)
    zones.setAccessibilityLabel("Clock time zone suggestions")
    add(zones, 548, 364, 148)
    label("Preset", 244)
    presets.addItems(withTitles: ["Choose preset…"] + Self.clockPresets.map(\.title))
    presets.target = self
    presets.action = #selector(choosePreset)
    presets.setAccessibilityLabel("Clock format preset")
    add(presets, 140, 244, 300)
    label("Add token", 204)
    tokens.addItems(withTitles: ClockToken.allCases.map(\.title))
    tokens.setAccessibilityLabel("Clock format token")
    add(tokens, 140, 204, 264)
    targetLine.addItems(withTitles: ["First line", "Second line"])
    targetLine.setAccessibilityLabel("Clock token destination")
    add(targetLine, 412, 204, 142)
    let insert = NSButton(title: "Insert", target: self, action: #selector(insertToken))
    insert.bezelStyle = .rounded
    add(insert, 562, 204, 134)
    let hint = NSTextField(
      wrappingLabelWithString:
        "Type literal text and {tokens}. Use {{ and }} for braces. Up to six clocks; 96 UTF-16 units per line. Seconds update visually without collecting hardware each second."
    )
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    add(hint, 24, 142, 672, 48)
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    add(message, 24, 72, 672, 58)
    let revert = NSButton(title: "Revert draft", target: self, action: #selector(revertDraft))
    revert.bezelStyle = .rounded
    add(revert, 430, 24, 128)
    save.target = self
    save.action = #selector(saveDraft)
    save.bezelStyle = .rounded
    add(save, 566, 24, 130)
    custom.state = settings.clockMenu.custom ? .on : .off
    synchronizeFields()
  }
  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let field = client as? NSTextField,
      [name, zone, first, second].contains(where: { $0 === field })
    else { return nil }
    return LiteralFieldEditor.prepare(in: sender)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    updatePreview()
  }
  func windowWillClose(_ notification: Notification) {
    lastDemand = nil
    onPreviewDemand?(nil)
  }
  func updateSettings(_ settings: Settings) {
    let clockChanged = self.settings.clockMenu != settings.clockMenu
    self.settings = settings
    window?.appearance = settings.theme.nativeAppearance
    if clockChanged {
      drafts = settings.clockMenu.entries
      selected = min(selected, drafts.count - 1)
      custom.state = settings.clockMenu.custom ? .on : .off
      synchronizeFields()
    }
    if window?.isVisible == true { updatePreview() }
  }
  func updateClock(_ date: Date) {
    self.date = date
    if window?.isVisible == true { updatePreview() }
  }
  func updateMenuBarContext(appearance: NSAppearance?, height: CGFloat, paused: Bool) {
    barAppearance = appearance
    if height > 0 && height <= 100 { barHeight = height }
    self.paused = paused
    if window?.isVisible == true { updatePreview() }
  }
  private func capture() {
    drafts[selected] = .init(
      name: name.stringValue.trimmingCharacters(in: .whitespaces),
      zone: zone.stringValue.trimmingCharacters(in: .whitespaces), firstLine: first.stringValue,
      secondLine: second.stringValue)
  }
  private func refreshChoices() {
    clocks.removeAllItems()
    clocks.addItems(withTitles: drafts.enumerated().map { "\($0.offset + 1). \($0.element.title)" })
    clocks.selectItem(at: selected)
  }
  private func synchronizeFields() {
    let entry = drafts[selected]
    name.stringValue = entry.name
    zone.stringValue = entry.zone
    first.stringValue = entry.firstLine
    second.stringValue = entry.secondLine
    refreshChoices()
    updatePreview()
  }
  func controlTextDidChange(_ obj: Notification) {
    capture()
    refreshChoices()
    updatePreview()
  }
  @objc private func draftChanged() {
    capture()
    updatePreview()
  }
  @objc private func selectClock() {
    capture()
    selected = max(0, clocks.indexOfSelectedItem)
    synchronizeFields()
  }
  @objc private func addEntry() {
    capture()
    guard drafts.count < ClockMenuSettings.limit else { return }
    drafts.append(.init(zone: "UTC", firstLine: "{name}", secondLine: "{hour24}:{minute}"))
    selected = drafts.count - 1
    synchronizeFields()
  }
  @objc private func removeEntry() {
    guard drafts.count > 1 else { return }
    drafts.remove(at: selected)
    selected = min(selected, drafts.count - 1)
    synchronizeFields()
  }
  @objc private func moveEntry(_ sender: NSButton) {
    capture()
    let next = selected + (sender === left ? -1 : 1)
    guard drafts.indices.contains(next) else { return }
    drafts.swapAt(selected, next)
    selected = next
    synchronizeFields()
  }
  @objc private func chooseZone() {
    let index = zones.indexOfSelectedItem - 1
    guard suggestedZones.indices.contains(index) else { return }
    zone.stringValue = suggestedZones[index]
    zones.selectItem(at: 0)
    capture()
    updatePreview()
  }
  @objc private func choosePreset() {
    let index = presets.indexOfSelectedItem - 1
    guard Self.clockPresets.indices.contains(index) else { return }
    first.stringValue = Self.clockPresets[index].first
    second.stringValue = Self.clockPresets[index].second
    presets.selectItem(at: 0)
    capture()
    updatePreview()
  }
  @objc private func insertToken() {
    let field = targetLine.indexOfSelectedItem == 1 ? second : first
    field.stringValue += ClockToken.allCases[tokens.indexOfSelectedItem].text
    capture()
    updatePreview()
  }
  @objc private func revertDraft() {
    drafts = settings.clockMenu.entries
    selected = min(selected, drafts.count - 1)
    custom.state = settings.clockMenu.custom ? .on : .off
    synchronizeFields()
  }
  @objc private func saveDraft() {
    capture()
    guard drafts.allSatisfy(\.isValid) else {
      updatePreview()
      return
    }
    settings.clockMenu = .init(custom: custom.state == .on, entries: drafts)
    onChange?(settings.clockMenu)
    updatePreview()
  }
  private func updatePreview() {
    let valid = drafts.allSatisfy(\.isValid)
    let enabled = custom.state == .on
    save.isEnabled = valid
    addClock.isEnabled = drafts.count < ClockMenuSettings.limit
    removeClock.isEnabled = drafts.count > 1
    left.isEnabled = selected > 0
    right.isEnabled = selected + 1 < drafts.count
    guard window?.isVisible == true else { return }
    let style = settings.style(for: .clock)
    let demand: Bool? =
      style.showsClockTime || (!enabled && style == .label)
      ? enabled && valid && drafts.contains(where: \.includesSeconds) : nil
    if demand != lastDemand {
      lastDemand = demand
      onPreviewDemand?(demand)
    }
    var settings = settings
    settings.clockMenu = .init(custom: enabled, entries: drafts)
    var snapshot = Snapshot()
    snapshot.timestamp = date
    let readouts =
      valid
      ? MenuBarReadout.makeAll(
        module: .clock, snapshot: snapshot, settings: settings, history: [], clockDate: date) : []
    preview.appearance = barAppearance
    scroll.appearance = barAppearance
    preview.update(groups: [readouts], paused: paused, height: barHeight)
    preview.frame.size = .init(width: max(670, preview.preferredWidth), height: max(36, barHeight))
    preview.needsDisplay = true
    message.stringValue =
      valid
      ? "Draft preview · Save clocks applies all entries together. \(settings.readouts.contains(.clock) ? "Time is enabled in the menu bar." : "Preview only · enable Time in Menu Bar to display it.")\n\(style.showsClockTime ? "Stacked uses two lines; single-line styles join both." : "Choose a Time text style to display formatted times.") Text fonts and all colors follow Time. Graphics fit each line; fuzzy time is English."
      : "Invalid draft · use a valid IANA zone (or local), a name up to 48 UTF-16 units and supported {tokens} in single-line formats up to 96 units. First line must contain text. Saved clocks are unchanged."
  }
}
