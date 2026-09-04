import Testing
import AppKit
@testable import CodeEditTextView

extension TextLineStorage {
    /// Validate that the internal tree is intact and correct.
    ///
    /// Ensures that:
    /// - All lines can be queried by their index starting from `0`.
    /// - All lines can be found by iterating `y` positions.
    func validateInternalState() {
        func validateLines(_ lines: [TextLineStorage<Data>.TextLinePosition]) {
            var _lastLine: TextLineStorage<Data>.TextLinePosition?
            for line in lines {
                guard let lastLine = _lastLine else {
                    #expect(line.index == 0)
                    _lastLine = line
                    return
                }

                #expect(line.index == lastLine.index + 1)
                #expect(line.yPos >= lastLine.yPos + lastLine.height)
                #expect(line.range.location == lastLine.range.max + 1)
                _lastLine = line
            }
        }

        let linesUsingIndex = (0..<count).compactMap({ getLine(atIndex: $0) })
        validateLines(linesUsingIndex)

        let linesUsingYValue = Array(linesStartingAt(0, until: height))
        validateLines(linesUsingYValue)
    }
}

@Suite
@MainActor
struct TextLayoutManagerTests {
    let textView: TextView
    let textStorage: NSTextStorage
    let layoutManager: TextLayoutManager

    init() throws {
        textView = TextView(string: "A\nB\nC\nD")
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.updateFrameIfNeeded()
        textStorage = textView.textStorage
        layoutManager = try #require(textView.layoutManager)
    }

    @Test(
        arguments: [
            ("\nE", NSRange(location: 6, length: 0), 5),
            ("0\n", NSRange(location: 0, length: 0), 5), // at beginning
            ("A\nBC\nD", NSRange(location: 3, length: 0), 6), // in middle
            ("A\r\nB\nC\rD", NSRange(location: 0, length: 0), 7) // Insert mixed line breaks
        ]
    )
    func insertText(_ testItem: (String, NSRange, Int)) throws { // swiftlint:disable:this large_tuple
        let (insertText, insertRange, lineCount) = testItem

        textStorage.replaceCharacters(in: insertRange, with: insertText)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    @Test(
        arguments: [
            (NSRange(location: 5, length: 2), 3), // At end
            (NSRange(location: 0, length: 2), 3), // At beginning
            (NSRange(location: 2, length: 3), 3) // In middle
        ]
    )
    func deleteText(_ testItem: (NSRange, Int)) throws {
        let (deleteRange, lineCount) = testItem

        textStorage.deleteCharacters(in: deleteRange)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    @Test(
        arguments: [
            ("\nD\nE\nF", NSRange(location: 5, length: 2), 6), // At end
            ("A\nY\nZ", NSRange(location: 0, length: 1), 6), // At beginning
            ("1\n2\n", NSRange(location: 2, length: 4), 4), // In middle
            ("A\nB\nC\nD\nE\nF\nG", NSRange(location: 0, length: 7), 7), // Entire string
            ("A\r\nB\nC\r", NSRange(location: 0, length: 6), 4) // Mixed line breaks
        ]
    )
    func replaceText(_ testItem: (String, NSRange, Int)) throws { // swiftlint:disable:this large_tuple
        let (replaceText, replaceRange, lineCount) = testItem

        textStorage.replaceCharacters(in: replaceRange, with: replaceText)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    /// This ensures that getting line rect info does not invalidate layout. The issue was previously caused by a
    /// call to ``TextLayoutManager/preparePositionForDisplay``.
    @Test
    func getRectsDoesNotRemoveLayoutInfo() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        let lineFragmentIDs = Set(
            layoutManager.lineStorage
                .linesInRange(NSRange(location: 0, length: 7))
                .flatMap(\.data.lineFragments)
                .map(\.data.id)
        )

        _ = layoutManager.rectsFor(range: NSRange(start: 0, end: 7))

        #expect(
            layoutManager.lineStorage.linesInRange(NSRange(location: 0, length: 7)).allSatisfy({ position in
                !position.data.lineFragments.isEmpty
            })
        )
        let afterLineFragmentIDs = Set(
            layoutManager.lineStorage
                .linesInRange(NSRange(location: 0, length: 7))
                .flatMap(\.data.lineFragments)
                .map(\.data.id)
        )
        #expect(lineFragmentIDs == afterLineFragmentIDs, "Line fragments were invalidated by `rectsFor(range:)` call.")
        layoutManager.lineStorage.validateInternalState()
    }

    /// It's easy to iterate through lines by taking the last line's range, and adding one to the end of the range.
    /// However, that will always skip lines that are empty, but represent a line. This test ensures that when we
    /// iterate over a range, we'll always find those empty lines.
    ///
    /// Related implementation: ``TextLayoutManager/Iterator``
    @Test
    func yPositionIteratorDoesNotSkipEmptyLines() {
        // Layout manager keeps 1-length lines at the 2nd and 4th lines.
        textStorage.mutableString.setString("A\n\nB\n\nC")
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        var lineIndexes: [Int] = []
        for line in layoutManager.linesStartingAt(0.0, until: 1000.0) {
            lineIndexes.append(line.index)
        }

        var lastLineIndex: Int?
        for lineIndex in lineIndexes {
            if let lastIndex = lastLineIndex {
                #expect(lineIndex - 1 == lastIndex, "Skipped an index when iterating.")
            } else {
                #expect(lineIndex == 0, "First index was not 0")
            }
            lastLineIndex = lineIndex
        }
    }

    /// See comment for `yPositionIteratorDoesNotSkipEmptyLines`.
    @Test
    func rangeIteratorDoesNotSkipEmptyLines() {
        // Layout manager keeps 1-length lines at the 2nd and 4th lines.
        textStorage.mutableString.setString("A\n\nB\n\nC")
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        var lineIndexes: [Int] = []
        for line in layoutManager.linesInRange(textView.documentRange) {
            lineIndexes.append(line.index)
        }

        var lastLineIndex: Int?
        for lineIndex in lineIndexes {
            if let lastIndex = lastLineIndex {
                #expect(lineIndex - 1 == lastIndex, "Skipped an index when iterating.")
            } else {
                #expect(lineIndex == 0, "First index was not 0")
            }
            lastLineIndex = lineIndex
        }
    }

    @Test
    func afterLayoutDoesntNeedLayout() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(layoutManager.needsLayout == false)
    }

    /// Invalidating a range shouldn't cause a layout on any other lines next layout pass.
    /// Note that this is correct behavior, and edits that add or remove lines will trigger another heuristic.
    /// See `editsWithNewlinesForceLayoutGoingDownScreen`
    @Test
    func invalidatingRangeLaysOutLines() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        let lineIds = Set(layoutManager.linesInRange(NSRange(start: 2, end: 4)).map { $0.data.id })
        layoutManager.invalidateLayoutForRange(NSRange(start: 2, end: 4))

        #expect(layoutManager.needsLayout == false) // No forced layout
        #expect(
            layoutManager
                .linesInRange(NSRange(start: 2, end: 4))
                .allSatisfy({ $0.data.needsLayout(maxWidth: .infinity) })
        )

        let invalidatedLineIds = layoutManager.layoutLines()

        #expect(
            invalidatedLineIds.isSuperset(of: lineIds),
            "Invalidated lines != lines that were laid out in next pass."
        )
    }

    /// ~~Inserting a new line should cause layout going down the rest of the screen, because the following lines
    /// should have moved their position to accomodate the new line.~~
    /// This is slightly changed now. The layout manager checks if a line actually needs to be typeset again and only
    /// invalidates it if it does. Otherwise it moves lines. This test now just checks that the invalidated lines
    /// equal the expected invalidated lines.
    @Test
    func editsWithNewlinesForceLayoutGoingDownScreen() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        textStorage.replaceCharacters(in: NSRange(start: 4, end: 4), with: "Z\n")

        let expectedLineIds = Array(
            layoutManager.lineStorage.linesInRange(NSRange(location: 4, length: 4))
        ).map { $0.data.id }

        #expect(layoutManager.needsLayout == false) // No forced layout for entire view

        let invalidatedLineIds = layoutManager.layoutLines()
        #expect(Set(expectedLineIds) == invalidatedLineIds)
    }

    @Test
    func rectForOffsetReturnsValueAfterEndOfDoc() throws {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        for idx in 0..<10 {
            // This should return something even after the end of the document.
            #expect(layoutManager.rectForOffset(idx) != nil, "Failed to find rect for offset: \(idx)")
        }
    }

    @Test
    func textOffsetForPointReturnsValuesEverywhere() throws {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        // textOffsetAtPoint is valid *everywhere*. It should always return something.
        for xPos in 0..<1000 {
            for yPos in 0..<1000 {
                #expect(layoutManager.textOffsetAtPoint(CGPoint(x: xPos, y: yPos)) != nil)
            }
        }
    }

    @Test
    func editingEndOfDocumentInvalidatesLastLine() throws {
        // Setup a slightly longer final line
        textStorage.replaceCharacters(in: NSRange(location: 7, length: 0), with: "EFGH")
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        textStorage.replaceCharacters(in: NSRange(location: 10, length: 1), with: "")
        let invalidatedLineIds = layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        let expectedLineIds = Array(
            layoutManager.lineStorage.linesInRange(NSRange(location: 6, length: 0))
        ).map { $0.data.id }

        #expect(invalidatedLineIds.isSuperset(of: Set(expectedLineIds)))
    }

    @Test
    func testDeleteMultiLineFromBeginning() throws {
        let tv = TextView(string: "First line\nSecond line\nThird line\nFourth line\nFifth line")
        tv.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        tv.updateFrameIfNeeded()
        let lm = try #require(tv.layoutManager)
        lm.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        
        #expect(lm.lineCount == 5)
        #expect(tv.subviews.count > 0)
        
        // Select from very beginning (index 0) through second line exactly (multi-line selection including index 0)
        let selectionRange = NSRange(location: 0, length: 23)
        tv.selectionManager.setSelectedRange(selectionRange)
        tv.deleteBackward(nil)
        
        lm.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        
        #expect(tv.textStorage.string == "Third line\nFourth line\nFifth line")
        #expect(lm.lineCount == 3)
        #expect(lm.visibleLineIds.count == 3)
        
        let visibleSubviews = tv.subviews.filter { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
        #expect(visibleSubviews.count == 3, "Surviving lines should have visible subviews positioned properly")
        #expect(lm.lineStorage.length == tv.textStorage.length)
        lm.lineStorage.validateInternalState()
    }

    @Test
    func testDeleteMultiLineFromBeginningInScrollViewWithScrollOffset() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let tv = TextView(string: "First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line\nSeventh line\nEighth line")
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        scrollView.documentView = tv
        tv.updateFrameIfNeeded()
        let lm = try #require(tv.layoutManager)
        lm.layoutLines()

        // Simulate user having scrolled down during selection
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 50))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lm.layoutLines()

        // Select from 0 through second line
        let selectionRange = NSRange(location: 0, length: 23)
        tv.selectionManager.setSelectedRange(selectionRange)
        tv.deleteBackward(nil)

        let visibleSubviews = tv.subviews.filter { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
        #expect(!visibleSubviews.isEmpty, "Surviving lines must NOT be hidden or blank after deleting from beginning while scrolled")
        #expect(tv.visibleRect.minY == 0, "Visible rect should have scrolled to the beginning where the cursor is")
    }

    @Test
    func testMultiStorageDelegatePrioritizesTextLayoutManager() throws {
        var callOrder: [String] = []

        class TrackingDelegate: NSObject, NSTextStorageDelegate {
            let name: String
            let onCall: (String) -> Void
            init(name: String, onCall: @escaping (String) -> Void) {
                self.name = name
                self.onCall = onCall
            }
            func textStorage(
                _ textStorage: NSTextStorage,
                didProcessEditing editedMask: NSTextStorageEditActions,
                range editedRange: NSRange,
                changeInLength delta: Int
            ) {
                onCall(name)
            }
        }

        let multi = MultiStorageDelegate()
        let tracker = TrackingDelegate(name: "Highlighter") { callOrder.append($0) }
        multi.addDelegate(tracker)

        let tv = TextView(string: "Hello")
        let lm = try #require(tv.layoutManager)
        multi.addDelegate(lm)

        let storage = NSTextStorage(string: "Hello")
        storage.delegate = multi
        storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "World")

        #expect(!callOrder.isEmpty)
    }

    @Test
    func testDeleteFromBeginningWhenDocumentFitsInViewportLaysOutLinesImmediately() throws {
        // Document smaller than scrollview so frame height does NOT change on edit
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let tv = TextView(string: "= Title\n*Bold sentence here*\n$x + y = z$\nFinal line")
        scrollView.documentView = tv
        tv.updateFrameIfNeeded()
        let lm = try #require(tv.layoutManager)
        lm.layoutLines()

        #expect(!tv.subviews.filter({ !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }).isEmpty)

        // Select from 0 into between "*Bold" and "sentence":
        // "= Title\n*Bold " (length: 8 + 6 = 14)
        let selectionRange = NSRange(location: 0, length: 14)
        tv.selectionManager.setSelectedRange(selectionRange)
        tv.deleteBackward(nil)

        #expect(tv.textStorage.string == "sentence here*\n$x + y = z$\nFinal line")

        // Crucial check: line fragment views MUST exist and be visible immediately, even without frame change or window resize
        let visibleSubviews = tv.subviews.filter { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
        #expect(visibleSubviews.count == 3, "All 3 surviving lines must have visible line fragment views immediately")
    }

    @Test
    func testSetTextStorageImmediatelyLaysOutLinesAndPopulatesSubviews() throws {
        let tv = TextView(string: "Initial text")
        tv.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        let lm = try #require(tv.layoutManager)
        lm.layoutLines()

        // Replace entire text storage via setText
        tv.setText("New line 1\nNew line 2\nNew line 3")

        let visibleSubviews = tv.subviews.filter { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
        #expect(visibleSubviews.count == 3, "setText must immediately lay out line views and never leave subviews empty/blank")
    }

    /// Regression test for the blank-editor bug caused by `layoutLines` being called while the scroll
    /// position is still below the (newly-shrunk) document height.
    ///
    /// Before the fix, `linesStartingAt(800, until: 820)` returned zero lines for a ~100px document,
    /// causing `enqueueViews(notInSet:)` to hide every fragment view — producing a blank editor.
    /// The guard at the top of `layoutLines` should return early without touching fragment views.
    @Test
    func testLayoutLinesWithStaleVisibleRectBeyondDocHeightDoesNotBlank() throws {
        // Small content — document height will be much less than 800px.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let tv = TextView(string: "Line one\nLine two\nLine three")
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        scrollView.documentView = tv
        tv.updateFrameIfNeeded()
        let lm = try #require(tv.layoutManager)
        lm.layoutLines()

        // Force-layout to populate fragment views.
        let initialVisible = tv.subviews.filter { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
        #expect(!initialVisible.isEmpty, "Fragment views should exist before the test")

        // Simulate calling layoutLines with a rect that is entirely BELOW the document.
        // This mimics the race: scroll position is stale at y=800, document is only ~60px tall.
        let staleRect = NSRect(x: 0, y: 800, width: 400, height: 200)
        lm.layoutLines(in: staleRect)

        // The guard must prevent enqueueViews from hiding all fragment views.
        let afterStale = tv.subviews.filter { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }
        #expect(
            afterStale.count == initialVisible.count,
            "layoutLines with a stale out-of-bounds rect must NOT hide existing fragment views"
        )
    }
}

