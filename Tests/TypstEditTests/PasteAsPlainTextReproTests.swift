import XCTest
import AppKit
@testable import TypstEdit

/// Regression tests for "Paste as Plain Text does nothing".
///
/// Root cause: `forwardActionIfNotFirstResponder` treated "our editor isn't
/// wired up yet" (`textViewController == nil` — the state right after creating
/// or opening a file, before the SwiftUI coordinator finishes attaching the
/// live text view) exactly like "some other native responder has focus", and
/// in both cases unconditionally forwarded the action via `NSApp.sendAction`
/// and returned `true`. Since nothing in the responder chain actually
/// implements the custom `"pasteAsPlainText:"` selector, the forward was a
/// pure no-op — and because it returned `true`, the caller's own
/// `pasteViaModel` fallback (meant for exactly this situation) was never
/// reached. The fix makes `forwardActionIfNotFirstResponder` return `false`
/// (don't forward, don't bail) whenever there's no live `textViewController`
/// to compare against, so the caller's model-based fallback actually runs.
@MainActor
final class PasteAsPlainTextReproTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // `NSApp`/`NSApplication.shared` must exist before `EditorController`
        // touches `NSApp.keyWindow` — in a plain `swift test` process nothing
        // else bootstraps it.
        _ = NSApplication.shared
    }

    func testPasteAsPlainTextWithNoLiveTextViewInsertsClipboardText() {
        let controller = EditorController()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("hello world plain text", forType: .string)

        controller.pasteAsPlainText()

        XCTAssertTrue(
            controller.sourceCode.contains("hello world plain text"),
            "Paste as Plain Text silently did nothing; sourceCode was: \(controller.sourceCode)"
        )
    }

    func testPasteSelectionWithNoLiveTextViewInsertsClipboardText() {
        // The regular Cmd+V path shares the same `forwardActionIfNotFirstResponder`
        // guard, so it was equally vulnerable to the same silent-no-op bug.
        let controller = EditorController()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("regular paste text", forType: .string)

        controller.pasteSelection()

        XCTAssertTrue(
            controller.sourceCode.contains("regular paste text"),
            "Paste silently did nothing; sourceCode was: \(controller.sourceCode)"
        )
    }
}
