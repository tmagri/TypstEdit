import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct AddCursorTests {
    let textView: TextView

    init() {
        textView = TextView(string: "aaaa\nbbbb\ncccc\ndddd\neeee")
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 500, height: 500))
    }

    private var ranges: [NSRange] {
        textView.selectionManager.textSelections.map(\.range)
    }

    @Test
    func addsCursorBelowKeepingColumn() {
        textView.selectionManager.setSelectedRange(NSRange(location: 12, length: 0)) // "cc|cc"
        textView.selectionManager.addCursorVertically(up: false)
        textView.selectionManager.addCursorVertically(up: false)
        #expect(ranges == [NSRange(location: 12, length: 0), NSRange(location: 17, length: 0), NSRange(location: 22, length: 0)])
    }

    @Test
    func oppositeDirectionRemovesFarthestCursor() {
        textView.selectionManager.setSelectedRange(NSRange(location: 12, length: 0))
        textView.selectionManager.addCursorVertically(up: false)
        textView.selectionManager.addCursorVertically(up: false)
        textView.selectionManager.addCursorVertically(up: true)
        #expect(ranges == [NSRange(location: 12, length: 0), NSRange(location: 17, length: 0)])
        textView.selectionManager.addCursorVertically(up: true)
        #expect(ranges == [NSRange(location: 12, length: 0)])
        // Back to one cursor: going up now adds above.
        textView.selectionManager.addCursorVertically(up: true)
        #expect(ranges == [NSRange(location: 7, length: 0), NSRange(location: 12, length: 0)])
        textView.selectionManager.addCursorVertically(up: false)
        #expect(ranges == [NSRange(location: 12, length: 0)])
    }

    @Test
    func stopsAtFirstLine() {
        textView.selectionManager.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(textView.selectionManager.addCursorVertically(up: true) == nil)
        #expect(ranges == [NSRange(location: 2, length: 0)])
    }

    @Test
    func collapseKeepsPrimaryCursor() {
        textView.selectionManager.setSelectedRange(NSRange(location: 12, length: 0))
        textView.selectionManager.addCursorVertically(up: true)
        textView.selectionManager.addCursorVertically(up: true)
        #expect(textView.selectionManager.collapseToPrimarySelection())
        #expect(ranges == [NSRange(location: 12, length: 0)])
    }

    @Test
    func cursorsMovedOntoSamePositionMerge() {
        textView.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 6, length: 0)])
        textView.selectionManager.moveSelections(direction: .up, destination: .document)
        #expect(ranges == [NSRange(location: 0, length: 0)])
    }
}
