import XCTest
import CodeEditSourceEditor
@testable import TypstEdit

/// The completion services now address text by **UTF-16 offset**, matching the
/// `NSRange` the editor hands them. These tests pin the boundary cases that a
/// unit change would silently break: cursor at EOF, past EOF, and after
/// characters that occupy more than one UTF-16 unit.
@MainActor
final class CompletionOffsetTests: XCTestCase {
    private let service = OfflineCompletionService.shared

    // MARK: - Word prefix

    func testWordPrefixAtEndOfDocument() {
        let text = "Some prose\n#page"
        let suggestions = service.provideCompletion(text: text, cursorIndex: text.utf16.count)
        XCTAssertTrue(suggestions.contains("#pagebreak()"), "\(suggestions)")
    }

    func testWordPrefixIncludesHashMarker() {
        // The '#' belongs to the function name; a prefix of "page" alone would
        // not satisfy the `hasPrefix("#")` filter in `provideCompletion`.
        let suggestions = service.provideCompletion(text: "#page", cursorIndex: 5)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.hasPrefix("#") }, "\(suggestions)")
    }

    func testCursorIndexPastEndDoesNotCrashOrThrow() {
        // Regression: the old implementation indexed NSString past its length.
        let text = "Hello world\n#page"
        _ = service.provideCompletion(text: text, cursorIndex: text.utf16.count + 5)
        _ = service.provideCompletion(text: text, cursorIndex: Int.max)
        _ = service.provideCompletion(text: text, cursorIndex: -3)
    }

    func testCursorInNonASCIIProseUsesUTF16Offset() {
        // "héllo 👋 " is 8 Characters but 10 UTF-16 units. Passing a UTF-16
        // cursor must land at the same place as the NSString does, so the
        // prefix is still found.
        let text = "héllo 👋 #page"
        let cursor = text.utf16.count
        let suggestions = service.provideCompletion(text: text, cursorIndex: cursor)
        XCTAssertTrue(suggestions.contains("#pagebreak()"), "\(suggestions)")
    }

    // MARK: - Context lookups remain bounded

    // MARK: - Line/column → offset

    /// A cursor given as (line, column) must resolve to the same place the
    /// text view means. This compares the shipping implementation against an
    /// independent walk of the same text, for every (line, column) pair across
    /// awkward documents. It specifically pins three cases that broke a naive
    /// `getLineStart` rewrite: a blank line in the middle, the last line, and a
    /// line past the end of the document.
    func testLineColumnToOffsetMatchesCharacterWalk() {
        let samples = [
            "abc\ndef\nghi",
            "one\ntwo\nthree\nfour",
            "",
            "a",
            "a\n",
            "\n\n\n",
            "x\ny\r\nz",
            "line1\nline2\n",
            "a\n\n\n\nb\nc",
            "👋 émoji\nsecond\nthird",
        ]

        func referenceOffset(_ text: String, line: Int, column: Int) -> Int {
            let nsText = text as NSString
            var index = 0
            var currentLine = 1
            while index < nsText.length && currentLine < line {
                let unit = nsText.character(at: index)
                index += 1
                if unit == 0x0A {
                    currentLine += 1
                } else if unit == 0x0D {
                    if index < nsText.length && nsText.character(at: index) == 0x0A { index += 1 }
                    currentLine += 1
                }
            }
            var added = 0
            let target = max(0, column - 1)
            while added < target && index < nsText.length {
                let unit = nsText.character(at: index)
                if unit == 0x0A || unit == 0x0D { break }
                index += 1
                added += 1
            }
            return index
        }

        let provider = AICompletionProvider()
        for text in samples {
            let lineCount = max(1, (text as NSString).components(separatedBy: "\n").count)
            for line in 1...(lineCount + 2) {
                for column in 1...8 {
                    let expected = referenceOffset(text, line: line, column: column)
                    let actual = provider.cursorUTF16Offset(
                        from: CursorPosition.Position(line: line, column: column),
                        in: text
                    )
                    XCTAssertEqual(
                        actual, expected,
                        "line \(line) column \(column) of \(text.debugDescription)"
                    )
                }
            }
        }
    }

    func testCompletionIsFastOnLargeDocument() {
        // Guards against reintroducing an O(document) Character walk on the
        // keystroke path. The ceiling is deliberately loose: it only needs to
        // catch a return to the ~50-100 ms behaviour, not measure precisely.
        let paragraph = "This is a paragraph of ordinary prose text in a note.\n\n"
        let text = String(repeating: paragraph, count: 25_000) + "#page"
        let start = Date()
        _ = service.provideCompletion(text: text, cursorIndex: text.utf16.count)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.25, "completion on a ~1.4 MB document took \(elapsed)s")
    }
}
