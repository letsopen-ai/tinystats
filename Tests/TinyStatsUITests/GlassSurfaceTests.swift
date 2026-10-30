import AppKit
import Testing

@testable import TinyStats

@Test @MainActor func glassPolicyPreservesLegacyThroughMacOS26AndHonorsAccessibilityOn27() {
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
  if #available(macOS 27, *) { expected = true } else { expected = false }
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
  guard #available(macOS 27, *) else { return }
  var environment = GlassSurface.Environment(
    supportsGlass: true, reduceTransparency: false, increaseContrast: false)
  weak var released: GlassSurface?
  autoreleasepool {
    let surface = GlassSurface(environment: { environment })
    released = surface
    surface.setFrameSize(.init(width: 344, height: 640))
    let glass = surface.subviews.first as? NSGlassEffectView
    #expect(glass?.style == .regular && glass?.tintColor == nil)
    #expect(glass?.contentView != nil && glass?.effectIsInteractive == false)
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
