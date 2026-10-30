import AppKit
import TinyStatsCore

/// Created only while editing. All edits remain local until Save changes.
@MainActor
final class RulesController: NSWindowController, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate
{
  var onSave: (([AlertRule]) -> Void)?
  var onClose: (() -> Void)?
  private var rules: [AlertRule]
  private var snapshot: Snapshot
  private let table = NSTableView()
  private let form = NSView()
  private let name = NSTextField(string: "")
  private let metric = NSPopUpButton(), source = NSPopUpButton(), comparison = NSPopUpButton()
  private let threshold = NSTextField(string: ""), stateThreshold = NSPopUpButton()
  private let hold = NSTextField(string: ""), cooldown = NSTextField(string: "")
  private let unit = NSTextField(labelWithString: "")
  private let enabled = SystemSettingSwitch(title: "Enable this rule", target: nil, action: nil)
  private let repeats = SystemSettingSwitch(
    title: "Repeat while condition remains true", target: nil, action: nil)
  private let sound = SystemSettingSwitch(
    title: "Play notification sound", target: nil, action: nil)
  private let draining = SystemSettingSwitch(
    title: "Only while on battery power", target: nil, action: nil)
  private let note = NSTextField(wrappingLabelWithString: "")
  private let error = NSTextField(wrappingLabelWithString: "")
  private let remove = NSButton(title: "Remove", target: nil, action: nil)
  private let add = NSButton(title: "Add rule", target: nil, action: nil)
  private let empty = NSTextField(
    wrappingLabelWithString: "No rules. Add one to choose a metric and condition.")
  private var selected: Int?
  private var changingSelection = false
  private struct SourceOption {
    var key: String, title: String
    var kind: SensorReading.Kind?
  }
  private var sources: [SourceOption] = []

  init(rules: [AlertRule], snapshot: Snapshot) {
    self.rules = rules
    self.snapshot = snapshot
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 760, height: 590),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "TinyStats Alert Rules"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    window.contentView = SystemSettingsBackgroundView(frame: window.contentView?.bounds ?? .zero)
    guard let content = window.contentView else { return }
    func place(_ view: NSView, _ x: Int, _ y: Int, _ w: Int, _ h: Int, parent: NSView? = nil) {
      view.frame = .init(x: x, y: y, width: w, height: h)
      (parent ?? content).addSubview(view)
    }
    let heading = NSTextField(labelWithString: "Notify me when…")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    place(heading, 24, 542, 700, 28)
    let intro = NSTextField(
      labelWithString: "Uses the shared sampler · missing readings never trigger · up to 32 rules")
    intro.font = .systemFont(ofSize: 11)
    intro.textColor = .secondaryLabelColor
    place(intro, 24, 518, 710, 20)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let column = NSTableColumn(identifier: .init("rule"))
    column.width = 198
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 42
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Alert rules")
    scroll.documentView = table
    place(scroll, 24, 108, 220, 392)
    add.target = self
    add.action = #selector(addRule)
    remove.target = self
    remove.action = #selector(removeRule)
    place(add, 24, 72, 105, 28)
    place(remove, 137, 72, 107, 28)
    place(form, 266, 82, 470, 418)
    func label(_ title: String, _ y: Int) {
      let text = NSTextField(labelWithString: title)
      text.font = .systemFont(ofSize: 12, weight: .medium)
      place(text, 0, y, 105, 22, parent: form)
    }
    place(enabled, 0, 390, 460, 24, parent: form)
    label("Name", 354)
    name.placeholderString = "Optional custom name"
    place(name, 112, 352, 350, 26, parent: form)
    label("Metric", 317)
    place(metric, 112, 315, 350, 26, parent: form)
    metric.addItems(withTitles: RuleMetric.allCases.map(\.title))
    metric.target = self
    metric.action = #selector(metricChanged)
    label("Source", 280)
    place(source, 112, 278, 350, 26, parent: form)
    source.target = self
    source.action = #selector(sourceChanged)
    label("Condition", 243)
    place(comparison, 112, 241, 350, 26, parent: form)
    comparison.addItems(withTitles: RuleComparison.allCases.map(\.title))
    label("Threshold", 206)
    place(threshold, 112, 204, 140, 26, parent: form)
    place(stateThreshold, 112, 204, 350, 26, parent: form)
    unit.font = .systemFont(ofSize: 11)
    unit.textColor = .secondaryLabelColor
    place(unit, 260, 206, 205, 24, parent: form)
    label("For at least", 169)
    place(hold, 112, 167, 140, 26, parent: form)
    label("Cooldown", 132)
    place(cooldown, 112, 130, 140, 26, parent: form)
    for y in [169, 132] {
      let seconds = NSTextField(labelWithString: "seconds")
      seconds.textColor = .secondaryLabelColor
      seconds.font = .systemFont(ofSize: 11)
      place(seconds, 260, y, 100, 22, parent: form)
    }
    place(repeats, 0, 94, 460, 24, parent: form)
    place(sound, 0, 64, 460, 24, parent: form)
    place(draining, 0, 34, 460, 24, parent: form)
    note.font = .systemFont(ofSize: 10)
    note.textColor = .secondaryLabelColor
    place(note, 0, -10, 460, 42, parent: form)
    place(empty, 290, 285, 420, 80)
    error.font = .systemFont(ofSize: 11)
    error.textColor = .systemRed
    place(error, 24, 20, 475, 42)
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
    cancel.keyEquivalent = "\u{1b}"
    place(cancel, 514, 24, 95, 30)
    let save = NSButton(title: "Save changes", target: self, action: #selector(saveChanges))
    save.keyEquivalent = "\r"
    place(save, 620, 24, 116, 30)
    for (view, title) in [
      (name, "Rule name"), (threshold, "Rule threshold"), (hold, "Rule duration in seconds"),
      (cooldown, "Rule cooldown in seconds"),
    ] {
      view.setAccessibilityLabel(title)
    }
    metric.setAccessibilityLabel("Rule metric")
    source.setAccessibilityLabel("Rule source")
    comparison.setAccessibilityLabel("Rule comparison")
    stateThreshold.setAccessibilityLabel("Rule threshold state")
    let layout = SystemSettingsForm.self
    let thresholdControls = NSView()
    thresholdControls.widthAnchor.constraint(equalToConstant: 260).isActive = true
    thresholdControls.heightAnchor.constraint(equalToConstant: 28).isActive = true
    for control in [threshold, stateThreshold, unit] {
      control.removeFromSuperview()
      thresholdControls.addSubview(control)
      control.autoresizingMask = []
    }
    threshold.frame = .init(x: 0, y: 1, width: 100, height: 26)
    unit.frame = .init(x: 108, y: 1, width: 152, height: 26)
    stateThreshold.frame = .init(x: 0, y: 1, width: 260, height: 26)
    _ = SystemSettingsForm(
      in: form,
      views: [
        layout.text("Condition", heading: true),
        layout.group([
          layout.row(enabled.title, enabled), layout.row("Name", name, width: 260),
          layout.row("Metric", metric, width: 260), layout.row("Source", source, width: 260),
          layout.row("Condition", comparison, width: 260),
          layout.row("Threshold", thresholdControls),
          layout.row("For at least", hold, width: 100),
          layout.row("Cooldown", cooldown, width: 100),
        ]), layout.text("Duration and cooldown are in seconds."),
        layout.text("Notification", heading: true),
        layout.group([
          layout.row(repeats.title, repeats), layout.row(sound.title, sound),
          layout.row(draining.title, draining),
        ]), note,
      ])
    reloadList()
    select(rules.isEmpty ? nil : 0)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(_ snapshot: Snapshot) { self.snapshot = snapshot }
  func windowWillClose(_ notification: Notification) { onClose?() }
  func numberOfRows(in tableView: NSTableView) -> Int { rules.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let label = NSTextField(
      wrappingLabelWithString: "\(rules[row].enabled ? "●" : "○") \(rules[row].title)")
    label.font = .systemFont(ofSize: 12)
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.textColor = rules[row].enabled ? .labelColor : .secondaryLabelColor
    return label
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !changingSelection else { return }
    let next = table.selectedRow >= 0 ? table.selectedRow : nil
    guard next != selected else { return }
    guard flush() else {
      selectTable(selected)
      return
    }
    select(next)
  }
  private func reloadList() {
    changingSelection = true
    table.reloadData()
    changingSelection = false
  }
  private func selectTable(_ index: Int?) {
    changingSelection = true
    table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
    changingSelection = false
  }
  private func select(_ index: Int?) {
    selected = index
    selectTable(index)
    form.isHidden = index == nil
    empty.isHidden = index != nil
    remove.isEnabled = index != nil
    add.isEnabled = rules.count < AlertRule.limit
    guard let index else { return }
    show(rules[index])
  }
  private func show(_ rule: AlertRule) {
    enabled.state = rule.enabled ? .on : .off
    name.stringValue = rule.name
    metric.selectItem(at: RuleMetric.allCases.firstIndex(of: rule.metric) ?? 0)
    comparison.selectItem(at: RuleComparison.allCases.firstIndex(of: rule.comparison) ?? 0)
    hold.stringValue = String(format: "%g", rule.hold)
    cooldown.stringValue = String(format: "%g", rule.cooldown)
    repeats.state = rule.repeatWhileActive ? .on : .off
    sound.state = rule.sound ? .on : .off
    draining.state = rule.onlyOnBattery ? .on : .off
    draining.superview?.isHidden = rule.metric != .batteryLevel
    configureSources(rule)
    configureThreshold(rule)
  }
  private func configureSources(_ rule: AlertRule) {
    switch rule.metric {
    case .gpuUsage:
      sources =
        [.init(key: "any", title: "Any GPU")]
        + Set(snapshot.gpus.map(\.name)).sorted().map {
          .init(key: "model:" + $0, title: "GPUs named " + $0)
        }
    case .volumeUsage:
      sources =
        [.init(key: "any", title: "Any local volume")]
        + snapshot.volumes.map { .init(key: $0.path, title: "\($0.name) · \($0.path)") }
    case .download, .upload, .interfaceState:
      sources =
        [.init(key: "selected", title: "Selected network interface")]
        + snapshot.interfaces.map { .init(key: $0.name, title: $0.name) }
    case .weatherTemperature, .weatherWind, .weatherPrecipitation:
      sources = [.init(key: "chosen-location", title: "Chosen weather location")]
    case .httpsState, .httpsLatency:
      sources = [.init(key: "apple", title: "Configured HTTPS endpoint")]
    case .publicIPChange:
      sources = [.init(key: "ipv4", title: "ipify IPv4"), .init(key: "ipv6", title: "ipify IPv6")]
    case .sensor:
      sources =
        [.init(key: "cpu", title: SensorCatalog.hottestCPULabel + " (°C)", kind: .temperature)]
        + snapshot.sensors.map {
          .init(key: $0.key, title: "\($0.name) (\($0.unit))", kind: $0.kind)
        }
    case .storageHealth:
      sources =
        [.init(key: "any", title: "Any drive")]
        + snapshot.storageHealth.drives.filter { !$0.stableID.isEmpty }.map {
          .init(key: "drive:" + $0.stableID, title: "\($0.name) · \($0.bsdName)")
        }
    default: sources = [.init(key: "any", title: "Whole Mac")]
    }
    if !sources.contains(where: { $0.key == rule.source }) {
      sources.append(
        .init(key: rule.source, title: "\(rule.source) · unavailable", kind: rule.sensorKind))
    }
    source.removeAllItems()
    source.addItems(withTitles: sources.map(\.title))
    source.selectItem(at: sources.firstIndex { $0.key == rule.source } ?? 0)
    source.isEnabled = sources.count > 1
  }
  private func configureThreshold(_ rule: AlertRule) {
    let discrete = !rule.metric.states.isEmpty
    threshold.isHidden = discrete
    stateThreshold.isHidden = !discrete
    unit.isHidden = discrete
    unit.stringValue = rule.unit
    threshold.stringValue = String(format: "%g", rule.threshold)
    stateThreshold.removeAllItems()
    stateThreshold.addItems(withTitles: rule.metric.states)
    if discrete { stateThreshold.selectItem(at: Int(rule.threshold)) }
    comparison.isEnabled = !rule.metric.equalityOnly
    hold.isEnabled = rule.metric != .publicIPChange
    repeats.isEnabled = rule.metric != .publicIPChange
    switch rule.metric {
    case .weatherTemperature, .weatherWind, .weatherPrecipitation:
      note.stringValue =
        "Requires Enable weather on the Weather tab. Uses fresh model forecasts for the chosen location; temperature thresholds are always Celsius. Precipitation requires an actual next-1h interval."
    case .httpsState, .httpsLatency:
      note.stringValue =
        "Requires Internet checks opt-in. This checks Apple's endpoint only; response time includes DNS/TLS/HTTP and is not ping."
    case .publicIPChange:
      note.stringValue =
        "Requires public-IP opt-in. One notification per observed change between successful replies; first baseline never triggers."
    case .storageHealth:
      note.stringValue =
        "Requires disk details open or background SMART polling enabled in Settings."
    case .interfaceState:
      note.stringValue =
        "Link state only. A missing interface is unavailable; this does not test internet connectivity."
    case .sensor:
      note.stringValue =
        rule.sensorKind == .temperature
        ? "Temperature thresholds use Celsius, independent of the menu bar display unit."
        : "Uses this sensor's measured units. A missing sensor never triggers."
    default:
      note.stringValue =
        "Duration restarts after missing data. Once-per-episode rules rearm after observed recovery."
    }
  }
  @discardableResult private func flush() -> Bool {
    guard let selected else { return true }
    var rule = rules[selected]
    rule.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    rule.enabled = enabled.state == .on
    rule.repeatWhileActive = repeats.state == .on
    rule.sound = sound.state == .on
    rule.onlyOnBattery = draining.state == .on
    guard let duration = Double(hold.stringValue), let delay = Double(cooldown.stringValue),
      let value = rule.metric.states.isEmpty
        ? Double(threshold.stringValue) : Double(stateThreshold.indexOfSelectedItem)
    else {
      error.stringValue = "Enter valid numbers for threshold, duration and cooldown."
      return false
    }
    rule.hold = duration
    rule.cooldown = delay
    rule.threshold = value
    rule.comparison = RuleComparison.allCases[max(0, comparison.indexOfSelectedItem)]
    if let problem = rule.validationError {
      error.stringValue = problem
      return false
    }
    rules[selected] = rule
    error.stringValue = ""
    reloadList()
    selectTable(selected)
    return true
  }
  @objc private func metricChanged() {
    guard let selected else { return }
    let nextMetric = RuleMetric.allCases[max(0, metric.indexOfSelectedItem)]
    guard flush() else {
      metric.selectItem(at: RuleMetric.allCases.firstIndex(of: rules[selected].metric) ?? 0)
      return
    }
    // Changing the metric deliberately resets its source/units/threshold.
    let old = rules[selected]
    var rule = AlertRule(
      id: old.id, metric: nextMetric)
    rule.name = name.stringValue
    rule.enabled = enabled.state == .on
    rule.repeatWhileActive = repeats.state == .on
    rule.sound = sound.state == .on
    rule.hold = nextMetric == .publicIPChange ? 0 : old.hold
    if nextMetric == .publicIPChange { rule.repeatWhileActive = false }
    rule.cooldown = old.cooldown
    rules[selected] = rule
    error.stringValue = ""
    show(rule)
  }
  @objc private func sourceChanged() {
    guard let selected, sources.indices.contains(source.indexOfSelectedItem) else { return }
    guard flush() else {
      source.selectItem(at: sources.firstIndex { $0.key == rules[selected].source } ?? 0)
      return
    }
    var rule = rules[selected]
    let choice = sources[source.indexOfSelectedItem]
    if let kind = choice.kind, kind != rule.sensorKind {
      rule.sensorKind = kind
      switch kind {
      case .temperature: rule.threshold = 80
      case .fan: rule.threshold = 2000
      case .power: rule.threshold = 20
      case .voltage: rule.threshold = 1
      case .current: rule.threshold = 1
      }
    }
    rule.source = choice.key
    rules[selected] = rule
    configureThreshold(rule)
  }
  @objc private func addRule() {
    guard rules.count < AlertRule.limit, flush() else { return }
    rules.append(AlertRule())
    reloadList()
    select(rules.count - 1)
    window?.makeFirstResponder(name)
  }
  @objc private func removeRule() {
    guard let selected else { return }
    rules.remove(at: selected)
    reloadList()
    select(rules.isEmpty ? nil : min(selected, rules.count - 1))
    error.stringValue = ""
  }
  @objc private func cancelEditing() { close() }
  @objc private func saveChanges() {
    window?.makeFirstResponder(nil)
    guard flush() else { return }
    onSave?(rules)
    close()
  }
}
