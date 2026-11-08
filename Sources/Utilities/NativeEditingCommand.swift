import AppKit

/// Routes the Edit menu's text commands to AppKit when a *native* text view
/// (a field editor) has keyboard focus.
///
/// TypstEdit replaces AppKit's standard Cut/Copy/Paste/Delete/Select All items
/// so those actions can run the editor's Markdown→Typst conversion. The
/// replacement items post `.menuCommand`, and only a document window's
/// `ContentView` observes that notification. That worked for the document
/// editor but silently broke every other text field in the app: ⌘C inside the
/// Settings window (or any window that is not a document window) posted a
/// notification nobody handled, so nothing was copied.
///
/// When a field editor is focused, the native action is the correct one to
/// run. It also preserves behaviour the app would otherwise have to
/// reimplement: `SecureField` refuses to copy its contents, field-editor undo
/// stays on the field's own undo stack, and append-only fields keep their own
/// editing rules.
///
/// The document editor's `TextView` is an `NSView`, not an `NSTextView`, so it
/// keeps using the app's conversion-aware commands.
@MainActor
enum NativeEditingCommand {
    /// The AppKit action that implements `command` in a native text view.
    /// `nil` means the command is app-specific (e.g. "Copy and Convert as
    /// Markdown") and has no meaning for a plain text field.
    static func selector(for command: String) -> Selector? {
        switch command {
        case "cut":              return #selector(NSText.cut(_:))
        case "copy":             return #selector(NSText.copy(_:))
        case "paste":            return #selector(NSText.paste(_:))
        case "pasteAsPlainText": return #selector(NSTextView.pasteAsPlainText(_:))
        // A plain text field has no Markdown→Typst conversion; fall back to a
        // normal paste so the shortcut still inserts the clipboard text.
        case "pasteForceTypst":  return #selector(NSText.paste(_:))
        case "delete":           return #selector(NSText.delete(_:))
        case "selectAll":        return #selector(NSText.selectAll(_:))
        // Field editors expose undo/redo through AppKit's action methods, not
        // through `UndoManager`'s bare `undo()`.
        case "undo":             return Selector(("undo:"))
        case "redo":             return Selector(("redo:"))
        default:                 return nil
        }
    }

    /// True when `responder` is a native text view, i.e. the command belongs to
    /// a focused field editor rather than the document editor.
    static func isTextResponder(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    /// Runs `command` in `responder` when it is a native text view.
    /// - Returns: `false` when `responder` is not a field editor (or the
    ///   command is app-specific), so the caller can keep the `.menuCommand`
    ///   route to the document window.
    @discardableResult
    static func forward(_ command: String, to responder: NSResponder?) -> Bool {
        guard isTextResponder(responder),
              let selector = selector(for: command) else { return false }
        return responder?.tryToPerform(selector, with: nil) ?? false
    }

    /// True when `command` means something to a terminal and `responder` is one.
    /// The Python pane's shell is an `NSView`, not an `NSTextView`, so without
    /// this ⌘C/⌘V/⌘A in the pane posted a notification the document window
    /// answered by acting on the *editor* — copying text the user could not
    /// see, or pasting the clipboard into a Python file instead of the shell.
    static func forward(_ command: String, to terminal: PythonTerminal) -> Bool {
        let action: Selector?
        switch command {
        case "cut":
            // A terminal has nothing to cut; swallow it so the document
            // editor does not delete a selection the user cannot see.
            return true
        case "copy":             action = #selector(NSText.copy(_:))
        case "paste":            action = #selector(NSText.paste(_:))
        case "pasteAsPlainText": action = #selector(NSText.paste(_:))
        case "delete":
            // The Edit menu binds the Delete key, so AppKit asks the menu
            // before the terminal's own key handling. Forward the key as the
            // byte a terminal expects, or Backspace would do nothing.
            terminal.send([0x7f])
            return true
        case "selectAll":        action = #selector(NSText.selectAll(_:))
        default:                 action = nil
        }
        guard let action else { return false }
        return terminal.tryToPerform(action, with: nil)
    }

    /// The responder that currently has keyboard focus, following the same
    /// precedence AppKit uses for menu actions: the key window, then the main
    /// window. When neither is reported (a window that is still ordering in, a
    /// window restored without key status, a headless test process) fall back to
    /// the frontmost *visible* window whose field editor has focus.
    private static var activeResponder: NSResponder? {
        if let responder = NSApp.keyWindow?.firstResponder { return responder }
        if let responder = NSApp.mainWindow?.firstResponder { return responder }
        for window in NSApp.orderedWindows where window.isVisible {
            if let responder = window.firstResponder, responder is NSTextView { return responder }
        }
        return nil
    }

    /// The Edit menu's entry point: give a focused native text view the command,
    /// otherwise hand it to the app's `.menuCommand` publisher for the document
    /// window. `fallback` is only called when no field editor is focused, which
    /// is what stops a document window from copying text the user cannot see.
    static func route(_ command: String, fallback: (String) -> Void) {
        route(command, to: activeResponder, terminal: PythonTerminal.focused, fallback: fallback)
    }

    /// `route` against an explicit responder. The Edit menu always uses the
    /// focused one above; this overload keeps the decision testable without a
    /// real key window.
    static func route(
        _ command: String,
        to responder: NSResponder?,
        terminal: PythonTerminal? = nil,
        fallback: (String) -> Void
    ) {
        if isTextResponder(responder) {
            forward(command, to: responder)
            return
        }
        if let terminal, forward(command, to: terminal) {
            return
        }
        fallback(command)
    }
}
