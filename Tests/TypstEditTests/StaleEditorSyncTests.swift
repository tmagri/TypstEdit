import XCTest
@testable import TypstEdit
import CodeEditSourceEditor
import CodeEditTextView
import AppKit

/// SwiftUI can keep two `SourceEditor`s alive for one controller, and the one prepared last is
/// not always the one on screen. The editor the user types in must own the model: a stale
/// editor writing its old text or caret back made the caret jump back while typing.
@MainActor
final class StaleEditorSyncTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func makeEditor(for controller: EditorController, text: String) -> TextViewController {
        let tvc = TextViewController(
            string: "",
            language: controller.highlightLanguage,
            configuration: controller.editorConfiguration,
            cursorPositions: [],
            coordinators: [controller.sourceEditorBridge]
        )
        tvc.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = tvc.view
        windows.append(window)
        tvc.setText(text)
        return tvc
    }

    func testFocusedEditorBecomesActiveAndStaleEditorCannotOverwriteModel() {
        let controller = EditorController()
        let original = "Hello world"
        controller.sourceCode = original

        let live = makeEditor(for: controller, text: original)
        live.view.window?.orderFront(nil)
        live.view.window?.makeFirstResponder(live.textView)
        controller.sourceEditorBridge.prepareCoordinator(controller: live)
        // A second editor is prepared last, so the bridge points at it, but it is not focused.
        let stale = makeEditor(for: controller, text: original)
        controller.sourceEditorBridge.prepareCoordinator(controller: stale)
        XCTAssertTrue(controller.textViewController === stale)

        // The user types in the live editor: it becomes the active one.
        live.textView.selectionManager.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        live.textView.insertText("!")
        XCTAssertTrue(controller.textViewController === live)
        XCTAssertEqual(controller.sourceCode, "Hello world!")

        // The stale editor still holds the old text. Its writes must not reach the model.
        controller.sourceCodeBinding.wrappedValue = stale.textView.string
        XCTAssertEqual(controller.sourceCode, "Hello world!")

        // Nor may its caret replace the live editor's caret.
        var state = controller.editorState
        state.cursorPositions = [CursorPosition(range: NSRange(location: 2, length: 0))]
        controller.editorStateBinding.wrappedValue = state
        XCTAssertNotEqual(controller.editorState.cursorPositions?.first?.range, NSRange(location: 2, length: 0))
    }

    func testUnfocusedStaleEditorChangeDoesNotWriteModel() {
        let controller = EditorController()
        controller.sourceCode = "abc"
        let live = makeEditor(for: controller, text: "abc")
        live.view.window?.orderFront(nil)
        live.view.window?.makeFirstResponder(live.textView)
        // Created last, so it is prepared last and the bridge points at it.
        let stale = makeEditor(for: controller, text: "abc")

        live.textView.selectionManager.setSelectedRange(NSRange(location: 3, length: 0))
        live.textView.insertText("d")
        XCTAssertTrue(controller.textViewController === live)
        XCTAssertEqual(controller.sourceCode, "abcd")

        // A change in an editor that is neither active nor focused is ignored.
        stale.textView.replaceCharacters(in: NSRange(location: 0, length: 3), with: "old text")
        XCTAssertEqual(controller.sourceCode, "abcd")
        XCTAssertTrue(controller.textViewController === live)
    }
}
