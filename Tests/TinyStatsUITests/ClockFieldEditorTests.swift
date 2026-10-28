import AppKit
import Testing

@testable import TinyStats
@testable import TinyStatsCore

@MainActor private func editableFields(_ view: NSView) -> [NSTextField] {
  var fields = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
  fields += view.subviews.flatMap { editableFields($0) }
  return fields
}

@Test @MainActor func clockLiteralEditingKeepsUnicodeTokensUndoAndReleasesItsWindow() throws {
  _ = NSApplication.shared
  weak var releasedEditor: NSTextView?
  weak var releasedController: NSWindowController?
  weak var releasedWindow: NSWindow?
  try autoreleasepool {
    let controller = ClockMenuController(settings: Settings(), date: Date())
    releasedController = controller
    releasedWindow = controller.window
    defer { controller.close() }
    let window = try #require(controller.window)
    let root = try #require(window.contentView)
    let input = try #require(
      editableFields(root).first { $0.accessibilityLabel() == "First line" })
    controller.showWindow(nil)
    #expect(window.makeFirstResponder(input))
    let editor = try #require(input.currentEditor() as? NSTextView)
    releasedEditor = editor
    #expect(editor.enabledTextCheckingTypes == 0 && !editor.isAutomaticTextCompletionEnabled)
    let undo = try #require(editor.undoManager)
    let original = editor.string
    let literal = "团队 'UTC' -- {{clock}} {hour24}:{minute}"
    undo.beginUndoGrouping()
    editor.insertText(literal, replacementRange: .init(location: 0, length: original.utf16.count))
    undo.endUndoGrouping()
    #expect(editor.string == literal)
    #expect(undo.canUndo)
    let menu = AppDelegate.makeEditMenu()
    let undoItem = try #require(menu.item(withTitle: "Undo"))
    let redoItem = try #require(menu.item(withTitle: "Redo"))
    let undoAction = try #require(undoItem.action)
    let redoAction = try #require(redoItem.action)
    #expect(undoItem.keyEquivalent == "z" && undoItem.keyEquivalentModifierMask == .command)
    #expect(
      redoItem.keyEquivalent == "z" && redoItem.keyEquivalentModifierMask == [.command, .shift])
    #expect(undoItem.target == nil && redoItem.target == nil)
    #expect(undoAction == Selector(("undo:")))
    undo.undo()
    #expect(editor.string == original)
    #expect(redoAction == Selector(("redo:")))
    undo.redo()
    #expect(editor.string == literal)
  }
  #expect(releasedController == nil && releasedWindow == nil)
  // AppKit can retain its last field editor even for the unmodified native implementation.
  #expect(releasedEditor?.window == nil)
}

@Test @MainActor func clockInputsUseOneNativeLiteralEditorWithoutChangingOtherWindows() throws {
  _ = NSApplication.shared
  let preferences = PreferencesController(
    settings: Settings(), interfaces: [], snapshot: Snapshot(), history: [])
  let clocks = ClockMenuController(settings: Settings(), date: Date())
  let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
  let untouched = try #require(other.fieldEditor(true, for: nil) as? NSTextView)
  let checking = untouched.enabledTextCheckingTypes
  let completion = untouched.isAutomaticTextCompletionEnabled
  defer {
    clocks.close()
    preferences.close()
  }
  for controller in [preferences as NSWindowController, clocks] {
    let window = try #require(controller.window)
    let root = try #require(window.contentView)
    let standard = try #require(window.fieldEditor(true, for: nil) as? NSTextView)
    let inputs = editableFields(root)
    #expect(inputs.count == (controller === preferences ? 1 : 4))
    var editor: NSTextView?
    for input in inputs {
      let literal = try #require(window.fieldEditor(true, for: input) as? NSTextView)
      #expect(literal === standard && literal.isFieldEditor)
      #expect(editor == nil || editor === literal)
      editor = literal
      #expect(literal.enabledTextCheckingTypes == 0)
      #expect(!literal.isContinuousSpellCheckingEnabled && !literal.isGrammarCheckingEnabled)
      #expect(!literal.isAutomaticSpellingCorrectionEnabled)
      #expect(
        !literal.isAutomaticQuoteSubstitutionEnabled && !literal.isAutomaticDashSubstitutionEnabled)
      #expect(
        !literal.isAutomaticTextReplacementEnabled && !literal.isAutomaticTextCompletionEnabled)
      #expect(!literal.isAutomaticLinkDetectionEnabled && !literal.isAutomaticDataDetectionEnabled)
      #expect(literal.allowsUndo && !literal.isRichText)
    }
    #expect(window.fieldEditor(true, for: nil) === standard)
    #expect(untouched.enabledTextCheckingTypes == checking)
    #expect(untouched.isAutomaticTextCompletionEnabled == completion)
  }
}
