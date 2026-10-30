import AppKit
import TinyStatsCore

/// A text-only table preview, driven by the app's shared clock deliveries.
@MainActor
final class WorldClockController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
  NSTableViewDataSource, NSTableViewDelegate
{
  var onChange: ((String) -> Void)?
  var onPreviewDemand: ((Bool?) -> Void)?
  private var settings: Settings
  private var date: Date
  private var lastDemand: Bool?
  private let format = NSTextField(), presets = NSPopUpButton(), tokens = NSPopUpButton()
  private let table = NSTableView()
  private var rows: [(label: String, value: String)] = []
  private let message = NSTextField(wrappingLabelWithString: "")
  private let save = NSButton(title: "Save format", target: nil, action: nil)
  private static let formats: [(String, String)] = [
    ("Default · weekday, time and zone", WorldClockFormat.standard),
    ("24-hour time", "{hour24}:{minute}"),
    ("12-hour time", "{hour12}:{minute} {period}"),
    ("Time with seconds", "{hour24}:{minute}:{second} · {zone}"),
    ("System time", "{systemTime} · {zone}"),
    ("Date + time", "{day} {monthName} · {hour24}:{minute}"),
    ("Time difference", "{hour24}:{minute} · {localOffset}"),
    ("Fuzzy time", "{fuzzy}"),
  ]
  init(settings: Settings, date: Date) {
    self.settings = settings
    self.date = date
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 580, height: 480), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "World Clock Format"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    window.appearance = settings.theme.nativeAppearance
    window.contentView = SystemSettingsBackgroundView(frame: window.contentView?.bounds ?? .zero)
    guard let root = window.contentView else { return }
    func add(_ view: NSView, _ x: Int, _ y: Int, _ width: Int, _ height: Int = 26) {
      view.frame = .init(x: x, y: y, width: width, height: height)
      root.addSubview(view)
    }
    let heading = NSTextField(labelWithString: "World clocks · detail table preview")
    heading.font = .systemFont(ofSize: 15, weight: .semibold)
    add(heading, 24, 432, 532)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let label = NSTableColumn(identifier: .init("label"))
    label.width = 280
    let value = NSTableColumn(identifier: .init("value"))
    value.width = 230
    table.addTableColumn(label)
    table.addTableColumn(value)
    table.headerView = nil
    table.backgroundColor = .clear
    table.rowHeight = 25
    table.intercellSpacing = .init(width: 0, height: 1)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.delegate = self
    table.dataSource = self
    table.setAccessibilityLabel("World clock detail table preview")
    scroll.documentView = table
    add(scroll, 24, 262, 532, 164)
    format.stringValue = settings.worldClockFormat
    format.delegate = self
    format.setAccessibilityLabel("World clock format")
    add(format, 24, 220, 532)
    presets.addItems(withTitles: ["Choose preset…"] + Self.formats.map(\.0))
    presets.target = self
    presets.action = #selector(choosePreset)
    presets.setAccessibilityLabel("World clock format preset")
    add(presets, 24, 180, 532)
    tokens.addItems(withTitles: WorldClockFormat.tokens.map(\.title))
    tokens.setAccessibilityLabel("World clock format token")
    add(tokens, 24, 140, 400)
    let insert = NSButton(title: "Insert", target: self, action: #selector(insertToken))
    insert.bezelStyle = .rounded
    add(insert, 436, 140, 120)
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    add(message, 24, 58, 532, 68)
    let revert = NSButton(title: "Revert draft", target: self, action: #selector(revertDraft))
    revert.bezelStyle = .rounded
    add(revert, 292, 20, 128)
    save.target = self
    save.action = #selector(saveDraft)
    save.bezelStyle = .rounded
    add(save, 428, 20, 128)
    let form = SystemSettingsForm.self
    scroll.heightAnchor.constraint(equalToConstant: 164).isActive = true
    _ = SystemSettingsForm(
      in: root,
      views: [
        form.text("World clocks · detail table preview", heading: true),
        form.group([form.row("", scroll, height: 180)]),
        form.text("Display format", heading: true),
        form.group([
          form.row("Format", format, width: 350), form.row("Preset", presets, width: 350),
          form.row("Add token", form.controls([tokens, insert], widths: [250, 92])),
        ]), message, form.actions([revert, save]),
      ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    refresh()
  }
  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let field = client as? NSTextField, field === format else { return nil }
    return LiteralFieldEditor.prepare(in: sender)
  }
  func windowWillClose(_ notification: Notification) {
    lastDemand = nil
    onPreviewDemand?(nil)
  }
  func updateSettings(_ settings: Settings) {
    if self.settings.worldClockFormat != settings.worldClockFormat {
      format.stringValue = settings.worldClockFormat
    }
    self.settings = settings
    window?.appearance = settings.theme.nativeAppearance
    if window?.isVisible == true { refresh() }
  }
  func updateClock(_ date: Date) {
    self.date = date
    if window?.isVisible == true { refresh() }
  }
  func controlTextDidChange(_ obj: Notification) { refresh() }
  @objc private func choosePreset() {
    let index = presets.indexOfSelectedItem - 1
    guard Self.formats.indices.contains(index) else { return }
    format.stringValue = Self.formats[index].1
    presets.selectItem(at: 0)
    refresh()
  }
  @objc private func insertToken() {
    guard WorldClockFormat.tokens.indices.contains(tokens.indexOfSelectedItem) else { return }
    format.stringValue += WorldClockFormat.tokens[tokens.indexOfSelectedItem].text
    refresh()
  }
  @objc private func revertDraft() {
    format.stringValue = settings.worldClockFormat
    refresh()
  }
  @objc private func saveDraft() {
    guard WorldClockFormat.parse(format.stringValue) != nil else {
      refresh()
      return
    }
    settings.worldClockFormat = format.stringValue
    onChange?(settings.worldClockFormat)
    refresh()
  }
  private func refresh() {
    let parsed = WorldClockFormat.parse(format.stringValue)
    save.isEnabled = parsed != nil
    guard window?.isVisible == true else { return }
    let demand = settings.worldClockEntries.isEmpty ? nil : parsed.map(\.includesSeconds)
    if lastDemand != demand {
      lastDemand = demand
      onPreviewDemand?(demand)
    }
    var draft = settings
    draft.worldClockFormat = format.stringValue
    rows = parsed == nil ? [] : ClockMenuRenderer.worldClockRows(settings: draft, at: date)
    table.reloadData()
    message.stringValue =
      parsed == nil
      ? "Invalid draft · use supported text {tokens}, up to 96 UTF-16 units on one line. Use {{ and }} for literal braces. Saved clocks are unchanged."
      : "Draft preview · Save format applies to all world clocks in Date & Time. Text, alignment and clipping match the detail table.\n\(rows.isEmpty ? "No world clocks selected · add zones in General." : "Edit city names and zones in General. Seconds update the display without collecting hardware each second.")"
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let isValue = tableColumn?.identifier.rawValue == "value"
    let id = NSUserInterfaceItemIdentifier(isValue ? "value" : "label")
    let cell =
      table.makeView(withIdentifier: id, owner: self) as? NSTextField
      ?? NSTextField(labelWithString: "")
    cell.identifier = id
    cell.stringValue = isValue ? rows[row].value : rows[row].label
    cell.font =
      isValue
      ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
    cell.alignment = isValue ? .right : .left
    cell.lineBreakMode = .byTruncatingTail
    cell.toolTip = cell.stringValue
    return cell
  }
}
