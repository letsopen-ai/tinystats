import AppKit
import TinyStatsCore
import UniformTypeIdentifiers

/// On-demand projections reuse the shared collector; closing releases all UI and export state.
@MainActor final class HistoryController: NSWindowController, NSWindowDelegate {
  static let modules: [Module] = [.cpu, .gpu, .memory, .network, .disks, .battery]
  var onRange: ((HistoryRange?) -> Void)?
  var onPersistence: ((Bool) -> Void)?
  var onClear: (() -> Void)?
  var onClose: (() -> Void)?
  private(set) var range: HistoryRange = .tenMinutes
  private(set) var module: Module
  private(set) var statistic: HistoryStatistic = .peak
  private let statisticPicker = NSPopUpButton()
  private var projection = HistoryProjection(range: .tenMinutes)
  private let rangePicker = NSPopUpButton()
  private let modulePicker = NSPopUpButton()
  private let graph = SummaryDashboardView(frame: .zero)
  private let graphScroll = NSScrollView(frame: .zero)
  private var minimumGraphHeight: CGFloat = 0
  private let status = NSTextField(wrappingLabelWithString: "No readings yet")
  private let keepButton = NSButton(
    checkboxWithTitle: "Keep history between launches", target: nil, action: nil)
  private let clearButton = NSButton(title: "Clear history…", target: nil, action: nil)
  private let storageLabel = NSTextField(wrappingLabelWithString: "")
  private let persistenceAvailable: Bool
  private var storageBusy = false
  private(set) var clearPrompt: NSAlert?
  private let exportButton = NSButton(title: "Export CSV…", target: nil, action: nil)
  private var exporting = false
  private(set) var exportMessage: String?
  init(module: Module, settings: Settings, persistenceAvailable: Bool = true) {
    self.persistenceAvailable = persistenceAvailable
    self.module = Self.modules.contains(module) ? module : .cpu
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 560, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "TinyStats History"
    window.minSize = .init(width: 560, height: 490)
    window.isReleasedWhenClosed = false
    window.appearance = settings.theme.nativeAppearance
    super.init(window: window)
    window.delegate = self
    guard let root = window.contentView else { return }
    modulePicker.addItems(withTitles: Self.modules.map(\.title))
    modulePicker.selectItem(at: Self.modules.firstIndex(of: self.module) ?? 0)
    modulePicker.target = self
    modulePicker.action = #selector(selectModule)
    modulePicker.frame = .init(x: 20, y: 637, width: 170, height: 26)
    modulePicker.setAccessibilityLabel("History metric")
    root.addSubview(modulePicker)
    statisticPicker.addItems(withTitles: HistoryStatistic.allCases.map(\.title))
    statisticPicker.target = self
    statisticPicker.action = #selector(selectStatistic)
    statisticPicker.frame = .init(x: 198, y: 637, width: 142, height: 26)
    statisticPicker.setAccessibilityLabel("History statistic")
    statisticPicker.toolTip =
      "Sample average weights valid recorded observations, not time. Older peak-only data has no minimum or average."
    root.addSubview(statisticPicker)
    rangePicker.addItems(withTitles: HistoryRange.allCases.map(\.title))
    rangePicker.target = self
    rangePicker.action = #selector(selectRange)
    rangePicker.frame = .init(x: 350, y: 637, width: 190, height: 26)
    rangePicker.setAccessibilityLabel("History range")
    root.addSubview(rangePicker)
    for picker in [modulePicker, statisticPicker, rangePicker] {
      picker.autoresizingMask = [.minYMargin]
    }
    rangePicker.autoresizingMask = [.minXMargin, .minYMargin]
    graphScroll.frame = .init(x: 20, y: 160, width: 520, height: 465)
    graphScroll.autoresizingMask = [.width, .height]
    graphScroll.hasVerticalScroller = true
    graphScroll.drawsBackground = false
    graphScroll.documentView = graph
    root.addSubview(graphScroll)
    status.frame = .init(x: 24, y: 99, width: 512, height: 54)
    status.autoresizingMask = [.width, .maxYMargin]
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    root.addSubview(status)
    exportButton.target = self
    exportButton.action = #selector(exportCSV)
    exportButton.bezelStyle = .rounded
    exportButton.frame = .init(x: 420, y: 7, width: 120, height: 28)
    exportButton.autoresizingMask = [.minXMargin, .maxYMargin]
    root.addSubview(exportButton)
    keepButton.target = self
    keepButton.action = #selector(changePersistence)
    keepButton.state = settings.persistHistory ? .on : .off
    keepButton.frame = .init(x: 20, y: 65, width: 360, height: 24)
    keepButton.toolTip =
      "Save only numeric system history locally, up to 28 days. No processes, addresses, locations or account events. Turning this off pauses saving and keeps the existing checkpoint until you explicitly Clear history. Timestamps and gaps can reveal activity. Per-core checkpoints require TinyStats 0.31 or later; scalar-only checkpoints require 0.28 or later. Turn saving off before launching an older version; it cannot read the new checkpoint, which remains until Clear."
    root.addSubview(keepButton)
    storageLabel.frame = .init(x: 24, y: 36, width: 512, height: 28)
    storageLabel.autoresizingMask = [.width, .maxYMargin]
    storageLabel.font = .systemFont(ofSize: 11)
    storageLabel.textColor = .secondaryLabelColor
    storageLabel.lineBreakMode = .byWordWrapping
    storageLabel.maximumNumberOfLines = 2
    root.addSubview(storageLabel)
    clearButton.target = self
    clearButton.action = #selector(clearHistory)
    clearButton.bezelStyle = .rounded
    clearButton.frame = .init(x: 20, y: 7, width: 130, height: 28)
    clearButton.toolTip =
      "Clear recorded History in memory and its saved checkpoint. Recent live menu-bar graphs stay available."
    root.addSubview(clearButton)
    projection.storage.enabled = settings.persistHistory
    setStorageBusy(false)
    window.center()
    refresh()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(_ projection: HistoryProjection) {
    guard projection.range == range else { return }
    self.projection = projection
    refresh()
  }
  func select(_ module: Module) {
    guard let index = Self.modules.firstIndex(of: module) else { return }
    self.module = module
    modulePicker.selectItem(at: index)
    refresh()
  }
  @objc private func selectModule() {
    guard Self.modules.indices.contains(modulePicker.indexOfSelectedItem) else { return }
    module = Self.modules[modulePicker.indexOfSelectedItem]
    refresh()
  }
  @objc private func selectStatistic() {
    guard HistoryStatistic.allCases.indices.contains(statisticPicker.indexOfSelectedItem) else {
      return
    }
    statistic = HistoryStatistic.allCases[statisticPicker.indexOfSelectedItem]
    refresh()
  }
  @objc private func selectRange() {
    guard HistoryRange.allCases.indices.contains(rangePicker.indexOfSelectedItem) else { return }
    range = HistoryRange.allCases[rangePicker.indexOfSelectedItem]
    exportMessage = nil
    let storage = projection.storage
    projection = .init(range: range)
    projection.storage = storage
    refresh()
    onRange?(range)
  }
  private func refresh() {
    let kinds = module == .cpu ? projection.latestCPUCoreKinds : nil
    let changed =
      kinds.map { kinds in
        projection.buckets.contains {
          $0.coreLayoutChanged || ($0.cpuCores.map { $0.kinds != kinds } ?? false)
        }
      } ?? false
    minimumGraphHeight = kinds.map { 275 + CGFloat($0.count) * 18 + (changed ? 17 : 0) } ?? 0
    layoutGraph()
    graph.updateHistory(projection, module: module, fahrenheit: false, statistic: statistic)
    let span = HistoryTimeline(
      times: [projection.buckets.first?.first, projection.buckets.last?.last].compactMap { $0 }
    ).span
    let end =
      projection.buckets.last.map {
        DateFormatter.localizedString(from: $0.last, dateStyle: .short, timeStyle: .medium)
      } ?? "waiting for samples"
    let gaps = projection.gapBuckets == 1 ? "1 gap bucket" : "\(projection.gapBuckets) gap buckets"
    let observations =
      projection.samples == 1 ? "1 observation" : "\(projection.samples) observations"
    let resets = projection.resets == 1 ? "1 reset" : "\(projection.resets) resets"
    status.stringValue =
      "Span \(span) · \(observations) · \(gaps) · \(resets)\n"
      + "Ending \(end) · Recorded \(statistic.plural)"
    if statistic == .average { status.stringValue += " · samples, not time" }
    if module == .cpu && kinds == nil {
      status.stringValue += "\nPer-core history unavailable for these observations"
    }
    if let exportMessage { status.stringValue += "\n" + exportMessage }
    status.toolTip =
      "Only valid observed readings are shown. Sample averages weight observations, not elapsed time or transfer totals. Short sessions do not fill the chosen range. Older peak-only history has no recorded minimum or average; partial coverage is marked gray. Missing values are not zero. CSV retains all three statistics, their counts and exact sample bounds."
    let storage = projection.storage
    let explanation: String
    if !persistenceAvailable {
      explanation = "Saving history is unavailable · readings stay in memory"
    } else if let issue = storage.issue {
      explanation =
        (storage.removalFailed ? "Could not remove saved history: " : "")
        + issue.message
    } else if !storage.enabled {
      explanation = "Saving off · any saved checkpoint stays until Clear"
    } else if let saved = storage.savedAt {
      explanation =
        "Checkpointed "
        + DateFormatter.localizedString(from: saved, dateStyle: .none, timeStyle: .medium)
        + " · every 5 minutes · best-effort quit"
    } else {
      explanation =
        (storage.restored ? "Loaded local history" : "Local numeric history")
        + " · every 5 minutes · best-effort quit"
    }
    storageLabel.stringValue = explanation
    storageLabel.toolTip =
      explanation
      + "\nAbnormal termination can lose readings since the last checkpoint. No power-loss durability guarantee. Timestamps and gaps can reveal activity. Other backups may retain copies. Normal sleep saves are best effort."
      + (storage.excludedFromBackup == true
        ? " This folder is excluded from Time Machine."
        : " Backup exclusion could not be verified.")
    exportButton.isEnabled = !projection.buckets.isEmpty && !exporting
    exportButton.toolTip =
      "Export all numeric system metrics for this range, including peaks, minima, sample averages and validity counts, regardless of the selected statistic. No processes, locations or addresses."
  }
  private func layoutGraph() {
    let size = NSSize(
      width: graphScroll.contentSize.width,
      height: max(graphScroll.contentSize.height, minimumGraphHeight))
    if graph.frame.size != size { graph.setFrameSize(size) }
  }
  func windowDidResize(_ notification: Notification) { layoutGraph() }
  func setStorageBusy(_ busy: Bool) {
    storageBusy = busy
    keepButton.isEnabled = persistenceAvailable && !busy
    clearButton.isEnabled = !busy
  }
  @objc private func changePersistence() {
    guard !storageBusy else { return }
    onPersistence?(keepButton.state == .on)
  }
  @objc private func clearHistory() {
    guard !storageBusy else { return }
    guard let window else { return }
    let prompt = NSAlert()
    prompt.messageText = "Clear recorded history?"
    prompt.informativeText =
      "Permanently remove all retained History readings (up to 28 days) and the checkpoint on this Mac. Recent live menu-bar graphs stay available. Existing backup copies are unaffected."
    prompt.addButton(withTitle: "Cancel")
    prompt.addButton(withTitle: "Clear history")
    prompt.buttons.last?.hasDestructiveAction = true
    clearPrompt = prompt
    setStorageBusy(true)
    prompt.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.clearPrompt = nil
      self.setStorageBusy(false)
      if response == .alertSecondButtonReturn { self.onClear?() }
    }
  }
  @objc private func exportCSV() {
    guard let window, !exporting, !projection.buckets.isEmpty else { return }
    // Freeze the selected range before the save dialog; newer samples do not change the export.
    let value = projection
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue =
      "TinyStats-history-\(range.rawValue)s-\(Int(Date().timeIntervalSince1970)).csv"
    panel.message =
      "Exports all numeric system metrics in this range: peaks, minima, sample averages, UTC bounds and validity counts, regardless of the selected statistic. No process names, network addresses, locations or account events."
    exportMessage = nil
    exporting = true
    refresh()
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.exporting = false
      self.refresh()
      guard response == .OK, let url = panel.url else { return }
      self.saveExport(value, to: url)
    }
  }
  func saveExport(_ value: HistoryProjection, to url: URL) {
    do {
      try value.csv.write(to: url, atomically: true, encoding: .utf8)
      exportMessage = "Saved \(url.lastPathComponent)"
    } catch { exportMessage = "Could not save CSV: \(error.localizedDescription)" }
    refresh()
  }
  func windowDidMiniaturize(_ notification: Notification) { onRange?(nil) }
  func windowDidDeminiaturize(_ notification: Notification) { onRange?(range) }
  func windowWillClose(_ notification: Notification) {
    onRange?(nil)
    // AppKit may retain a closed window after its controller is released.
    window?.contentView = nil
    onClose?()
  }
}
