import AppKit

/// Configuration identifiers and literal labels reuse their window's native field editor,
/// leaving other windows and global text preferences untouched.
@MainActor enum LiteralFieldEditor {
  static func prepare(in window: NSWindow) -> NSTextView? {
    // nil asks for the default editor; controllers delegate only for literal-field clients.
    guard let editor = window.fieldEditor(true, for: nil) as? NSTextView else { return nil }
    editor.isFieldEditor = true
    editor.isRichText = false
    editor.importsGraphics = false
    editor.allowsUndo = true
    editor.isContinuousSpellCheckingEnabled = false
    editor.isGrammarCheckingEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticTextCompletionEnabled = false
    editor.isAutomaticLinkDetectionEnabled = false
    editor.isAutomaticDataDetectionEnabled = false
    editor.enabledTextCheckingTypes = 0
    if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
    return editor
  }
}
