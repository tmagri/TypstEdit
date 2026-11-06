import XCTest
import AppKit
@testable import TypstEdit
import CodeEditTextView

/// Regression tests for "⌘C does nothing in the Settings text fields".
///
/// Root cause: the Edit menu's Cut/Copy/Paste/Delete/Select All items were
/// replaced with buttons that only posted a `.menuCommand` notification. Only a
/// document window's `ContentView` observes that notification, so in any other
/// window (Settings, a diff window, a standalone alert) ⌘C posted an event
/// nobody handled and the pasteboard was never written. The fix routes the
/// command to the focused native text view first, and only falls back to the
/// `.menuCommand` route that drives the document editor.
@MainActor
final class FieldEditorCopyReproTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// A window with an `NSTextField` whose field editor holds focus, the same
    /// state a Settings text box is in while the user types in it.
    private func makeFocusedFieldEditor(
        text: String = "settings value"
    ) throws -> (window: NSWindow, fieldEditor: NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        let field = NSTextField(frame: NSRect(x: 20, y: 50, width: 300, height: 24))
        container.addSubview(field)
        window.contentView = container

        XCTAssertTrue(window.makeFirstResponder(field), "the field must take focus")
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView,
                                        "a focused NSTextField is edited by an NSTextView")
        fieldEditor.string = text
        return (window, fieldEditor)
    }

    /// The reported bug: select text in a Settings box, press ⌘C, paste
    /// somewhere else — the clipboard stayed empty.
    func testCopyFromFocusedFieldEditorFillsThePasteboard() throws {
        let (window, fieldEditor) = try makeFocusedFieldEditor(text: "recoverable token")
        defer { window.close() }

        fieldEditor.setSelectedRange(NSRange(location: 0, length: 11))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("", forType: .string)

        let handled = NativeEditingCommand.forward("copy", to: fieldEditor)

        XCTAssertTrue(handled, "copy must be handled by the focused field editor")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "recoverable",
                       "⌘C in a settings text field must copy the selection")
    }

    /// The same routing has to cover the rest of the Edit menu, not just Copy.
    func testCutDeleteAndSelectAllReachTheFieldEditor() throws {
        let (window, fieldEditor) = try makeFocusedFieldEditor(text: "abcdef")
        defer { window.close() }

        fieldEditor.setSelectedRange(NSRange(location: 0, length: 3))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NativeEditingCommand.forward("cut", to: fieldEditor))
        XCTAssertEqual(fieldEditor.string, "def", "⌘X must remove the selection")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "abc",
                       "⌘X must put the selection on the clipboard")

        fieldEditor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(NativeEditingCommand.forward("selectAll", to: fieldEditor))
        XCTAssertEqual(fieldEditor.selectedRange(), NSRange(location: 0, length: 3),
                       "⌘A must select the whole field")

        XCTAssertTrue(NativeEditingCommand.forward("delete", to: fieldEditor))
        XCTAssertEqual(fieldEditor.string, "", "the Delete menu item must delete the selection")
    }

    /// Undo/redo in a field editor live on the field's own undo stack. The
    /// document editor's undo calls `UndoManager.undo()`, which a field editor
    /// does not implement (`undo:` is a window/field-editor action), so the
    /// routed selector has to be the AppKit action.
    func testUndoAndRedoReachTheFieldEditor() throws {
        let (window, fieldEditor) = try makeFocusedFieldEditor(text: "hello")
        defer { window.close() }

        // A field editor only registers undo steps for edits it sees through
        // its own input handling, so make the edit through `insertText`.
        fieldEditor.setSelectedRange(NSRange(location: 5, length: 0))
        fieldEditor.insertText(" world", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(fieldEditor.string, "hello world")

        XCTAssertTrue(NativeEditingCommand.forward("undo", to: fieldEditor))
        XCTAssertFalse(fieldEditor.string.contains(" world"),
                       "⌘Z in a settings field must undo that field's edit")

        XCTAssertTrue(NativeEditingCommand.forward("redo", to: fieldEditor))
        XCTAssertEqual(fieldEditor.string, "hello world",
                       "⇧⌘Z in a settings field must redo that field's edit")
    }

    /// Paste as Plain Text and Paste and Convert to Typst are app-specific, but
    /// a plain field can still paste. Both must insert the clipboard text.
    func testPasteCommandsInsertIntoAFieldEditor() throws {
        let (window, fieldEditor) = try makeFocusedFieldEditor(text: "")
        defer { window.close() }

        for command in ["paste", "pasteAsPlainText", "pasteForceTypst"] {
            fieldEditor.string = ""
            fieldEditor.setSelectedRange(NSRange(location: 0, length: 0))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("clipboard \(command)", forType: .string)

            XCTAssertTrue(NativeEditingCommand.forward(command, to: fieldEditor), command)
            XCTAssertEqual(fieldEditor.string, "clipboard \(command)",
                           "\(command) must paste into a focused settings field")
        }
    }

    /// The document editor must keep its conversion-aware commands. Its
    /// `TextView` is an `NSView`, not an `NSTextView`; treating it as a field
    /// editor would bypass the Markdown→Typst paste conversion and the
    /// "Copy as Markdown" behaviour.
    func testDocumentEditorIsNotTreatedAsAFieldEditor() throws {
        let editorTextView = CodeEditTextView.TextView(string: "= Heading\n\nbody")
        XCTAssertFalse(NativeEditingCommand.isTextResponder(editorTextView),
                       "the code editor must use the app's .menuCommand route")
        XCTAssertNil(NativeEditingCommand.selector(for: "copyAsMarkdown"))
        XCTAssertFalse(NativeEditingCommand.isTextResponder(nil))
        XCTAssertFalse(NativeEditingCommand.isTextResponder(NSView()))
    }

    /// Commands with no meaning for a plain field do not run an AppKit action,
    /// and they must not reach the document window either: while the user is in
    /// a settings field, the edit commands belong to that field.
    func testAppSpecificCommandsAreNotForwarded() throws {
        let (window, fieldEditor) = try makeFocusedFieldEditor()
        defer { window.close() }

        XCTAssertFalse(NativeEditingCommand.forward("copyAsMarkdown", to: fieldEditor))
        XCTAssertNil(NativeEditingCommand.selector(for: "copyAsMarkdown"))
        XCTAssertNil(NativeEditingCommand.selector(for: "promoteHeading"))

        // A focused field consumes the shortcut instead of editing a document
        // window the user is not looking at.
        var fallbackCommands: [String] = []
        NativeEditingCommand.route("copyAsMarkdown", to: fieldEditor) { fallbackCommands.append($0) }
        XCTAssertTrue(fallbackCommands.isEmpty)

        // With no field focused, the document window still gets the command.
        NativeEditingCommand.route("copyAsMarkdown", to: nil) { fallbackCommands.append($0) }
        XCTAssertEqual(fallbackCommands, ["copyAsMarkdown"])
    }

    /// The reported route through the menu: with a field editor focused, the
    /// command must never also reach a document window, otherwise it would edit
    /// the document the user is not looking at. The `.menuCommand` broadcast is
    /// what `ContentView` observes, so its absence is the regression guard.
    func testRoutedCommandDoesNotReachTheDocumentWindowWhenAFieldIsFocused() throws {
        let (window, fieldEditor) = try makeFocusedFieldEditor(text: "visible text")
        defer { window.close() }
        fieldEditor.setSelectedRange(NSRange(location: 0, length: 7))
        NSPasteboard.general.clearContents()

        var fallbackCommands: [String] = []
        NativeEditingCommand.route("copy", to: fieldEditor) { fallbackCommands.append($0) }

        XCTAssertTrue(fallbackCommands.isEmpty, "a focused field must consume the command")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "visible")
    }
}
