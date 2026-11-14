import XCTest
@testable import CodeEditTextView

final class TextSelectionManagerTests: XCTestCase {
    var textStorage: NSTextStorage!
    var layoutManager: TextLayoutManager!

    func selectionManager(_ text: String = "Loren Ipsum 💯") -> TextSelectionManager {
        textStorage = NSTextStorage(string: text)
        layoutManager = TextLayoutManager(
            textStorage: textStorage,
            lineHeightMultiplier: 1.0,
            wrapLines: false,
            textView: NSView(),
            delegate: nil
        )
        return TextSelectionManager(
            layoutManager: layoutManager,
            textStorage: textStorage,
            textView: nil,
            delegate: nil
        )
    }

    func test_updateSelectionLeft() {
        let selectionManager = selectionManager()
        let locations = [2, 0, 14, 14]
        let expectedRanges = [(1, 1), (0, 0), (12, 2), (13, 1)]
        let decomposeCharacters = [false, false, false, true]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .backward,
                destination: .character,
                decomposeCharacters: decomposeCharacters[idx]
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionRight() {
        let selectionManager = selectionManager()
        let locations = [2, 0, 14, 13, 12]
        let expectedRanges = [(2, 1), (0, 1), (14, 0), (12, 2), (12, 1)]
        let decomposeCharacters = [false, false, false, false, true]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .forward,
                destination: .character,
                decomposeCharacters: decomposeCharacters[idx]
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionLeftWord() {
        let selectionManager = selectionManager()
        let locations = [2, 0, 12]
        let expectedRanges = [(0, 2), (0, 0), (6, 6)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .backward,
                destination: .word,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionRightWord() {
        // "Loren Ipsum 💯"
        let selectionManager = selectionManager()
        let locations = [2, 0, 6]
        let expectedRanges = [(2, 3), (0, 5), (6, 5)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .forward,
                destination: .word,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionLeftLine() {
        // "Loren Ipsum 💯"
        let selectionManager = selectionManager()
        let locations = [2, 0, 14, 12]
        let expectedRanges = [(0, 2), (0, 0), (0, 14), (0, 12)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .backward,
                destination: .line,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionRightLine() {
        let selectionManager = selectionManager("Loren Ipsum 💯\nHello World")
        let locations = [2, 0, 14, 12, 17]
        let expectedRanges = [(2, 12), (0, 14), (14, 0), (12, 2), (17, 9)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .forward,
                destination: .line,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionUpDocument() {
        let selectionManager = selectionManager("Loren Ipsum 💯\nHello World\n1\n2\n3\n")
        let locations = [0, 27, 30, 33]
        let expectedRanges = [(0, 0), (0, 27), (0, 30), (0, 33)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .up,
                destination: .document,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_updateSelectionDownDocument() {
        let selectionManager = selectionManager("Loren Ipsum 💯\nHello World\n1\n2\n3\n")
        let locations = [0, 2, 27, 30, 33]
        let expectedRanges = [(0, 33), (2, 31), (27, 6), (30, 3), (33, 0)]

        for idx in locations.indices {
            let range = selectionManager.rangeOfSelection(
                from: locations[idx],
                direction: .down,
                destination: .document,
                decomposeCharacters: false
            )

            XCTAssert(
                range.location == expectedRanges[idx].0,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
            XCTAssert(
                range.length == expectedRanges[idx].1,
                "Invalid Location. Testing location \(locations[idx]). Expected \(expectedRanges[idx]). Got \(range)"
            )
        }
    }

    func test_selectionEndOfDocumentHasXPos() {
        let selectionManager = selectionManager("1\n2\n3\n")
        selectionManager.setSelectedRange(NSRange(location: 6, length: 0)) // Beyond text.length, end of doc
        XCTAssertNotNil(selectionManager.textSelections.first?.suggestedXPos)
    }

    // MARK: - Out-of-bounds offsets

    /// A stale caret (left behind after the document shrank) must never make Foundation raise
    /// `NSRangeException`. These used to abort the app inside `enumerateSubstrings(in:options:)`.
    func test_outOfBoundsOffsetsNeverThrowAndStayInBounds() {
        let text = "abc\ndef\nghi"
        let documentLength = (text as NSString).length
        let destinations: [TextSelectionManager.Destination] = [
            .character, .word, .line, .visualLine, .document, .page
        ]
        let directions: [TextSelectionManager.Direction] = [.forward, .backward, .up, .down]

        // Past EOF, far past EOF, and the boundary case one past the last character.
        for offset in [documentLength - 1, documentLength, documentLength + 1, documentLength + 5000] {
            let selectionManager = selectionManager(text)
            for destination in destinations {
                for direction in directions {
                    let range = selectionManager.rangeOfSelection(
                        from: offset,
                        direction: direction,
                        destination: destination
                    )
                    XCTAssertGreaterThanOrEqual(
                        range.location, 0,
                        "Negative location for \(direction)/\(destination) at \(offset)"
                    )
                    XCTAssertGreaterThanOrEqual(
                        range.length, 0,
                        "Negative length for \(direction)/\(destination) at \(offset)"
                    )
                    XCTAssertLessThanOrEqual(
                        range.max, documentLength,
                        "Range \(range) exceeds document for \(direction)/\(destination) at \(offset)"
                    )
                }
            }
        }
    }

    func test_wordSelectionPastEofDoesNotThrow() {
        let selectionManager = selectionManager("abc\ndef\nghi")
        // Forward and backward both build an enumeration range from `offset`.
        XCTAssertNoThrow(
            _ = selectionManager.rangeOfSelection(from: 5000, direction: .forward, destination: .word)
        )
        XCTAssertNoThrow(
            _ = selectionManager.rangeOfSelection(from: 5000, direction: .backward, destination: .word)
        )
    }

    func test_lineSelectionBackwardUsesLineLocationNotIndex() {
        // Second line starts at offset 12 in "first line\nsecond line".
        let selectionManager = selectionManager("first line\nsecond line")
        let range = selectionManager.rangeOfSelection(
            from: 17, // inside the second line
            direction: .backward,
            destination: .line
        )
        XCTAssertEqual(range.location, 11, "Backwards line selection should stop at the second line's location")
        XCTAssertEqual(range.length, 6, "Backwards line selection should cover the text before the caret")
    }
}
