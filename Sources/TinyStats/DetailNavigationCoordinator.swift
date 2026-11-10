import AppKit
import TinyStatsCore

/// Owns sidebar presentation and weak Settings hosting, never preference drafts or collection.
@MainActor
final class DetailNavigationCoordinator: NSObject {
  static let mainModules: [Module] = [
    .overview, .cpu, .gpu, .memory, .disks, .network, .battery, .clock, .weather,
  ]
  static let advancedModules: [Module] = [.sensors]
  static let rowLeading: CGFloat = 10
  static var sectionLeading: CGFloat { rowLeading + NavigationButton.iconLeading }
  static let sidebarWidth: CGFloat = 132
  let sidebar = NSView()
  let divider = SidebarDividerView()
  let sidebarMaterial: GlassSurface
  private let advancedLabel = NSTextField(labelWithString: "Advanced")
  private let brand = NSTextField(labelWithString: "TinyStats")
  private var controls: [NSView] = []
  var onSelectModule: ((Module) -> Void)?
  var onSettingsPage: ((PreferencesController.Page) -> Void)?
  private var moduleButtons: [Module: NSButton] = [:]
  private var settingsButtons: [PreferencesController.Page: NSButton] = [:]
  private weak var embeddedSettings: NSView?
  private(set) var settingsPage: PreferencesController.Page?
  var showsSettings: Bool { settingsPage != nil }

  init(environment: @escaping () -> GlassSurface.Environment = { .current }) {
    sidebarMaterial = GlassSurface(role: .sidebar, environment: environment)
    super.init()
    sidebar.identifier = .init("main-window-sidebar")
    sidebar.addSubview(sidebarMaterial)
    sidebarMaterial.autoresizingMask = [.width, .height]
    sidebar.frame = .init(x: 0, y: 0, width: 132, height: 560)
    sidebarMaterial.frame = sidebar.bounds
    brand.font = .systemFont(ofSize: 15, weight: .bold)
    sidebar.addSubview(brand)
    brand.frame = .init(x: 15, y: 520, width: 106, height: 23)
    for module in Self.mainModules + Self.advancedModules {
      guard let index = Module.allCases.firstIndex(of: module) else { continue }
      if module == Self.advancedModules.first {
        advancedLabel.font = .systemFont(ofSize: 11, weight: .regular)
        advancedLabel.textColor = .tertiaryLabelColor
        advancedLabel.setAccessibilityLabel("ADVANCED")
        sidebar.addSubview(advancedLabel)
      }
      let button = NavigationButton(
        title: module.title, target: self, action: #selector(selectModule(_:)))
      button.module = module
      button.image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)
      button.setAccessibilityLabel(module.title)
      button.imagePosition = .imageLeading
      button.alignment = .left
      button.isBordered = false
      button.setButtonType(.toggle)
      button.font = .systemFont(ofSize: 12, weight: .regular)
      button.tag = index
      button.keyEquivalent = index == 9 ? "0" : "\(index+1)"
      button.keyEquivalentModifierMask = [.command]
      button.frame = .init(x: Self.rowLeading, y: CGFloat(477 - index * 39), width: 112, height: 31)
      sidebar.addSubview(button)
      moduleButtons[module] = button
    }
    let group = NSTextField(labelWithString: "Settings")
    group.font = .systemFont(ofSize: 11, weight: .regular)
    group.textColor = .tertiaryLabelColor
    group.frame = .init(x: Self.sectionLeading, y: 96, width: 100, height: 15)
    sidebar.addSubview(group)
    for (page, title, symbol) in [
      (PreferencesController.Page.general, "General", "gearshape"),
      (.menuBar, "Menu Bar", "menubar.rectangle"),
    ] {
      let button = NavigationButton(
        title: title, target: self, action: #selector(selectSettings(_:)))
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.imagePosition = .imageLeading
      button.setAccessibilityLabel(title)
      button.isBordered = false
      button.setButtonType(.toggle)
      button.font = .systemFont(ofSize: 12, weight: .regular)
      button.tag = page.rawValue
      button.frame = .init(
        x: Self.rowLeading, y: page == .general ? 59 : 22, width: 112, height: 31)
      sidebar.addSubview(button)
      settingsButtons[page] = button
    }
    controls = sidebar.subviews.filter { $0 !== sidebarMaterial }
    sidebar.addSubview(divider)
    sidebarMaterial.onTreatmentChange = { [weak self] in self?.updateControlHost() }
    updateControlHost()
  }

  private func updateControlHost() {
    let host = sidebarMaterial.legacyContentView ?? sidebar
    for control in controls {
      if control.superview !== host { host.addSubview(control) }
      (control as? NavigationButton)?.usesGlassInk = sidebarMaterial.treatment == .glass
      if let label = control as? NSTextField, label !== brand {
        label.textColor =
          sidebarMaterial.treatment == .glass
          ? SystemStyle.glassSecondaryLabel.withAlphaComponent(0.60) : .tertiaryLabelColor
      }
    }
    layout(in: sidebar.superview?.bounds ?? .init(x: 0, y: 0, width: 700, height: 560))
    sidebar.superview?.needsDisplay = true
  }

  @objc private func selectModule(_ sender: NSButton) {
    onSelectModule?(Module.allCases[sender.tag])
    // AppKit may toggle the cell directly before sending the action, bypassing
    // the Swift state observer. Real click/key actions still refresh their ink.
    (sender as? NavigationButton)?.updateSelectionPresentation()
  }
  @objc private func selectSettings(_ sender: NSButton) {
    guard let page = PreferencesController.Page(rawValue: sender.tag) else { return }
    onSettingsPage?(page)
    (sender as? NavigationButton)?.updateSelectionPresentation()
  }

  func leaveSettings() {
    settingsPage = nil
    embeddedSettings?.isHidden = true
  }

  func selectSettingsPage(_ page: PreferencesController.Page) { settingsPage = page }

  func embedSettings(_ content: NSView, in root: NSView) {
    if embeddedSettings !== content {
      embeddedSettings?.removeFromSuperview()
      embeddedSettings = content
      root.addSubview(content)
    }
    for child in root.subviews where child !== sidebar { child.isHidden = child !== content }
    content.frame = .init(
      x: 144, y: 0, width: min(740, max(0, root.bounds.width - 144)),
      height: max(0, root.bounds.height - MainWindow.pageContentInset(in: root)))
    content.isHidden = false
    for button in moduleButtons.values {
      button.state = .off
      button.contentTintColor = .secondaryLabelColor
    }
    for (key, button) in settingsButtons { button.state = key == settingsPage ? .on : .off }
  }

  func updateSelection(_ selected: Module) {
    for button in settingsButtons.values { button.state = .off }
    for (module, button) in moduleButtons {
      button.state = selected == module ? .on : .off
      button.contentTintColor = selected == module ? .controlAccentColor : .secondaryLabelColor
    }
  }

  func layoutSettings(in bounds: NSRect) {
    embeddedSettings?.frame = .init(
      x: 144, y: 0, width: min(740, max(0, bounds.width - 144)),
      height: max(0, bounds.height - MainWindow.pageContentInset(in: sidebar.superview ?? sidebar)))
  }

  func layout(in bounds: NSRect) {
    sidebar.frame = .init(x: 0, y: 0, width: Self.sidebarWidth, height: max(0, bounds.height))
    divider.frame = .init(x: Self.sidebarWidth - 1, y: 0, width: 1, height: sidebar.bounds.height)
    let height = sidebar.bounds.height
    // Measure the light bottoms, not the taller empty toolbar's layout band.
    let topPadding = MainWindow.titlebarGeometry(in: sidebar).brandTop
    let offset = topPadding - 17
    brand.frame.origin.y = height - 40 - offset
    for (index, module) in Self.mainModules.enumerated() {
      moduleButtons[module]?.frame.origin.y = height - 83 - offset - CGFloat(index * 35)
    }
    let weatherBottom = moduleButtons[.weather]?.frame.minY ?? height - 363 - offset
    advancedLabel.frame = .init(
      x: Self.sectionLeading, y: weatherBottom - 16 - 15, width: 100, height: 15)
    for (index, module) in Self.advancedModules.enumerated() {
      moduleButtons[module]?.frame.origin.y =
        advancedLabel.frame.minY - 6 - 31 - CGFloat(index * 35)
    }
  }
}

/// One semantic separator spans the window, including the transparent titlebar band.
@MainActor final class SidebarDividerView: SystemStyledView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    dirtyRect.intersection(bounds).fill()
  }
}

/// Fixed icon slot and text baseline keep every sidebar label aligned.
@MainActor final class NavigationButton: NSButton {
  static let iconLeading: CGFloat = 6
  private let iconView = NavigationIconView()
  var module: Module? { didSet { updateIcon() } }
  var usesGlassInk = false {
    didSet {
      updateIcon()
      needsDisplay = true
    }
  }
  override var image: NSImage? { didSet { updateIcon() } }
  override var state: NSControl.StateValue {
    didSet {
      guard state != oldValue else { return }
      updateSelectionPresentation()
    }
  }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    font = .systemFont(ofSize: 12, weight: .regular)
    iconView.setAccessibilityElement(false)
    addSubview(iconView)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func updateSelectionPresentation() {
    font = .systemFont(ofSize: 12, weight: state == .on ? .semibold : .regular)
    updateIcon()
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    iconView.frame = .init(x: Self.iconLeading, y: (bounds.height - 18) / 2, width: 18, height: 18)
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateIcon()
  }
  private var labelColor: NSColor {
    state == .on
      ? .labelColor : usesGlassInk ? SystemStyle.glassSecondaryLabel : .secondaryLabelColor
  }
  private func updateIcon() {
    guard let image else {
      iconView.image = nil
      return
    }
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
      .applying(.init(paletteColors: [module.map { SystemStyle.moduleAccent($0) } ?? labelColor]))
    iconView.image = image.withSymbolConfiguration(configuration) ?? image
    iconView.imageScaling = .scaleProportionallyUpOrDown
  }
  override func draw(_ dirtyRect: NSRect) {
    if state == .on {
      NSColor.labelColor.withAlphaComponent(0.10).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    let color = labelColor
    let font = font ?? .systemFont(ofSize: 12, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let height = (title as NSString).size(withAttributes: attrs).height
    (title as NSString).draw(
      in: .init(x: 32, y: (bounds.height - height) / 2, width: bounds.width - 34, height: height),
      withAttributes: attrs)
  }
}

/// Decoration stays outside hit testing; the owning native button retains its actions.
@MainActor private final class NavigationIconView: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
