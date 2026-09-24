import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct TextViewTests {
    class MockDelegate: TextViewDelegate {
        var shouldReplaceContents: ((_ textView: TextView, _ range: NSRange, _ string: String) -> Bool)?

        func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool {
            shouldReplaceContents?(textView, range, string) ?? true
        }
    }

    let textView: TextView
    let delegate: MockDelegate

    init() {
        textView = TextView(string: "Lorem Ipsum")
        delegate = MockDelegate()
        textView.delegate = delegate
    }

    @Test
    func delegateChangesText() {
        var hasReplaced = false
        delegate.shouldReplaceContents = { textView, _, _ -> Bool in
            if !hasReplaced {
                hasReplaced.toggle()
                textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: " World ")
            }

            return true
        }

        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Hello")

        #expect(textView.string == "Hello World Lorem Ipsum")
        // available in test module
        textView.layoutManager.lineStorage.validateInternalState()
    }

    @Test
    func sharedTextStorage() {
        let storage = NSTextStorage(string: "Hello world")

        let textView1 = TextView(string: "")
        textView1.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView1.layoutSubtreeIfNeeded()
        textView1.setTextStorage(storage)

        let textView2 = TextView(string: "")
        textView2.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView2.layoutSubtreeIfNeeded()
        textView2.setTextStorage(storage)

        // Expect both text views to receive edited events from the storage
        #expect(textView1.layoutManager.lineCount == 1)
        #expect(textView2.layoutManager.lineCount == 1)

        storage.replaceCharacters(in: NSRange(location: 11, length: 0), with: "\nMore Lines\n")

        #expect(textView1.layoutManager.lineCount == 3)
        #expect(textView2.layoutManager.lineCount == 3)
    }

    @Test("Custom UndoManager class receives events")
    func customUndoManagerReceivesEvents() {
        let textView = TextView(string: "")

        textView.replaceCharacters(in: .zero, with: "Hello World")
        textView.undo(nil)

        #expect(textView.string == "")

        textView.redo(nil)

        #expect(textView.string == "Hello World")
    }

    @Test("Undo after suggestion replacement")
    func undoAfterSuggestionReplacement() {
        let textView = TextView(string: "")
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("#", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("l", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "#al")

        let label = "#align(center)[\n  \n]"
        let replacementRange = NSRange(location: 0, length: 3)

        textView.undoManager?.beginUndoGrouping()
        textView.insertText(label, replacementRange: replacementRange)
        textView.undoManager?.endUndoGrouping()
        #expect(textView.string == label)

        textView.undo(nil)
        #expect(textView.string == "#al")

        textView.redo(nil)
        #expect(textView.string == label)
    }

    @Test("Out of bounds mutation range does not fatalError on undo")
    func outOfBoundsMutationDoesNotCrash() {
        let textView = TextView(string: "Short")
        // Deliberately register an invalid/stale out-of-bounds mutation
        textView.undoManager?.beginUndoGrouping()
        textView.insertText("Extra", replacementRange: NSRange(location: 0, length: 50))
        textView.undoManager?.endUndoGrouping()

        // Should not crash with fatalError or NSRangeException
        textView.undo(nil)
    }
}
