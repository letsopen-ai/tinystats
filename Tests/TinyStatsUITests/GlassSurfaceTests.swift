import AppKit
import Testing

@testable import TinyStats

@Test @MainActor func glassPolicyPreservesLegacyBelowMacOS26AndHonorsAccessibility() {
  for supported in [false, true] {
    for reduced in [false, true] {
      for contrast in [false, true] {
        let environment = GlassSurface.Environment(
          supportsGlass: supported, reduceTransparency: reduced, increaseContrast: contrast)
        #expect(
          environment.treatment == (supported ? (reduced || contrast ? .solid : .glass) : .legacy))
      }
    }
  }
  let expected: Bool
  if #available(macOS 26, *) { expected = true } else { expected = false }
  #expect(GlassSurface.Environment.current.supportsGlass == expected)
}

@Test @MainActor func glassLegacySurfaceKeepsTheOriginalMaterialAndResizes() throws {
  let surface = GlassSurface(environment: {
    .init(supportsGlass: false, reduceTransparency: false, increaseContrast: false)
  })
  surface.setFrameSize(.init(width: 344, height: 640))
  let material = try #require(surface.subviews.first as? NSVisualEffectView)
  #expect(surface.subviews.count == 1 && surface.treatment == .legacy)
  #expect(material.material == .popover && material.blendingMode == .behindWindow)
  #expect(material.state == .active && material.frame == surface.bounds && !surface.isOpaque)
}

@Test @MainActor func glassAccessibilityChangesReplaceMaterialWithoutRetainingOldViews() throws {
  guard #available(macOS 26, *) else { return }
  var environment = GlassSurface.Environment(
    supportsGlass: true, reduceTransparency: false, increaseContrast: false)
  weak var released: GlassSurface?
  autoreleasepool {
    let surface = GlassSurface(environment: { environment })
    released = surface
    surface.setFrameSize(.init(width: 344, height: 640))
    let glass = surface.subviews.first as? NSGlassEffectView
    #expect(glass?.style == .regular && glass?.tintColor == nil)
    #expect(glass?.contentView != nil)
    #expect(glass?.frame == surface.bounds && surface.treatment == .glass)
    NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
    #expect(surface.subviews.first === glass)
    for mode in 0..<3 {
      environment.reduceTransparency = mode == 0
      environment.increaseContrast = mode == 1
      NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
      #expect(surface.treatment == (mode == 2 ? .glass : .solid))
      #expect(surface.isOpaque == (mode != 2))
      #expect(surface.subviews.count == (mode == 2 ? 1 : 0))
      #expect(glass?.superview == nil)
    }
  }
  #expect(released == nil)
  // A stale selector registration must not outlive a closed detail surface.
  NSWorkspace.shared.notificationCenter.post(
    name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
}

@Test @MainActor func glassDropdownUsesOneSurfaceAndHidesItOnWindowPromotion() throws {
  let controller = DetailController()
  controller.isPopoverPresentation = true
  controller.view.setFrameSize(SystemStyle.popoverSize)
  controller.view.layoutSubtreeIfNeeded()
  let surface = try #require(controller.view.subviews.compactMap { $0 as? GlassSurface }.first)
  #expect(!surface.isHidden && surface.frame == controller.view.bounds)
  #expect(surface.treatment == GlassSurface.Environment.current.treatment)
  controller.isPopoverPresentation = false
  controller.view.setFrameSize(MainWindow.minimumSize)
  controller.view.layoutSubtreeIfNeeded()
  #expect(surface.isHidden)
  controller.isPopoverPresentation = true
  controller.view.setFrameSize(SystemStyle.popoverSize)
  controller.view.layoutSubtreeIfNeeded()
  #expect(!surface.isHidden && surface.frame == controller.view.bounds)
  #expect(controller.view.subviews.filter { $0 is GlassSurface }.count == 1)
}

@Test @MainActor func glassSidebarRetainsLegacyMaterialAndAllRolesObserveDisplayOptions() throws {
  let legacy = GlassSurface(
    role: .sidebar,
    environment: {
      .init(supportsGlass: false, reduceTransparency: true, increaseContrast: true)
    })
  let effect = try #require(legacy.subviews.first as? NSVisualEffectView)
  #expect(effect.material == .sidebar && effect.blendingMode == .withinWindow)
  #expect(effect.state == .followsWindowActiveState)
  var environment = GlassSurface.Environment(
    supportsGlass: true, reduceTransparency: false, increaseContrast: false)
  let surfaces = [GlassSurface.Role.panel, .sidebar, .chips].map { role in
    GlassSurface(role: role, environment: { environment })
  }
  for option in 0..<3 {
    environment.reduceTransparency = option == 0
    environment.increaseContrast = option == 1
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    #expect(surfaces.allSatisfy { $0.treatment == (option == 2 ? .glass : .solid) })
    if option < 2 { #expect(surfaces.allSatisfy { $0.subviews.isEmpty }) }
  }
  #expect(
    GlassSurface.washOpacity(role: .panel, dark: true)
      > GlassSurface.washOpacity(role: .panel, dark: false))
}

@Test @MainActor func glassChipShapesShareOneContainerWithoutChangingControls() throws {
  guard #available(macOS 26, *) else { return }
  let editor = MenuBarCustomization(frame: .init(x: 0, y: 0, width: 620, height: 280))
  editor.update(order: [.cpu, .memory, .network])
  editor.layoutSubtreeIfNeeded()
  for area in [editor.strip, editor.palette] {
    area.layoutSubtreeIfNeeded()
    let container = try #require(area.glass.subviews.first as? NSGlassEffectContainerView)
    #expect(container.spacing == 8)
    let content = try #require(container.contentView)
    #expect(content.subviews.count == area.chips.count)
    for (shape, chip) in zip(content.subviews, area.chips) {
      #expect(shape is NSGlassEffectView && shape.frame == chip.frame)
      #expect(chip.superview === area && chip.acceptsFirstResponder)
      #expect(area.glass.hitTest(chip.frame.origin) == nil)
      #expect(chip.accessibilityLabel() == "\(chip.module.title) menu bar item")
    }
  }
}

@Test @MainActor func glassDropdownCardsContainNoNestedEffectsAndWindowHasOneSidebar() throws {
  let detail = DetailController()
  detail.isPopoverPresentation = true
  detail.selected = .cpu
  detail.view.layoutSubtreeIfNeeded()
  func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
  let surfaces = descendants(detail.view).compactMap { $0 as? GlassSurface }
  #expect(surfaces.filter { $0.role == .panel }.count == 1)
  #expect(surfaces.filter { $0.role == .sidebar }.count == 1)
  let summary = try #require(
    descendants(detail.view).compactMap { $0 as? SummaryDashboardView }.first)
  if #available(macOS 26, *) {
    #expect(!descendants(summary).contains { $0 is NSGlassEffectView })
  }
  detail.isPopoverPresentation = false
  #expect(surfaces.first { $0.role == .sidebar }?.isHiddenOrHasHiddenAncestor == false)
}
