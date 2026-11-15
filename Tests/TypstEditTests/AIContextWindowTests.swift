import XCTest
@testable import TypstEdit

/// `completionWindow` was ported from grapheme-cluster indexing to UTF-16
/// offsets to stop it walking the whole document. These tests pin that the port
/// did not change *what the model is shown*: windows are compared against an
/// independent Character-based reference implementation at every cursor offset,
/// for all three scopes.
@MainActor
final class AIContextWindowTests: XCTestCase {

    /// Straightforward Character-indexed reference implementation of the
    /// algorithm the UTF-16 version replaced. Intentionally independent of
    /// production code so a shared bug cannot hide.
    private func reference(
        _ text: String,
        at cursorIndex: Int,
        scope: AISettingsManager.CompletionContextScope
    ) -> (prefix: String, suffix: String) {
        let safeIndex = min(max(0, cursorIndex), text.count)
        let cursorIdx = text.index(text.startIndex, offsetBy: safeIndex)

        switch scope {
        case .currentLine:
            var lineStart = cursorIdx
            while lineStart > text.startIndex {
                let prev = text.index(before: lineStart)
                if text[prev] == "\n" || text[prev] == "\r" { break }
                lineStart = prev
            }
            var lineEnd = cursorIdx
            while lineEnd < text.endIndex {
                if text[lineEnd] == "\n" || text[lineEnd] == "\r" { break }
                lineEnd = text.index(after: lineEnd)
            }
            var linePrefix = String(text[lineStart..<cursorIdx])
            var lineSuffix = String(text[cursorIdx..<lineEnd])
            if linePrefix.count > 300 { linePrefix = String(linePrefix.suffix(300)) }
            if lineSuffix.count > 150 { lineSuffix = String(lineSuffix.prefix(150)) }
            return (linePrefix, lineSuffix)

        case .surroundingLines:
            var windowStart = cursorIdx
            var linesBefore = 0
            while windowStart > text.startIndex && linesBefore < 5 {
                let prev = text.index(before: windowStart)
                if text[prev] == "\n" { linesBefore += 1 }
                windowStart = prev
            }
            if linesBefore == 5, windowStart < cursorIdx, text[windowStart] == "\n" {
                windowStart = text.index(after: windowStart)
            }
            var windowEnd = cursorIdx
            var linesAfter = 0
            while windowEnd < text.endIndex && linesAfter < 5 {
                if text[windowEnd] == "\n" { linesAfter += 1 }
                windowEnd = text.index(after: windowEnd)
            }
            return (String(text[windowStart..<cursorIdx]), String(text[cursorIdx..<windowEnd]))

        case .fullDocument:
            return (String(text[..<cursorIdx]), String(text[cursorIdx...]))
        }
    }

    private var samples: [String] {
        [
            "",
            "abc",
            "abc\ndef",
            "line one\nline two\nline three",
            "a\r\nb\r\nc",
            "\n\n\n\n\n\n\nx\n\n\n\n\n\n\n",
            "= Heading\n\nSome prose *bold* here.\n\n#let x = 1\n",
            String(repeating: "word ", count: 200),
            "trailing newlines\n\n\n",
            "\n\nleading newlines",
            "one very long line without breaks: " + String(repeating: "abc ", count: 120),
            "mixed\n\n\nblank\n\nlines\n\n",
        ]
    }

    func testWindowsMatchCharacterBasedImplementation() {
        var checked = 0
        for text in samples {
            // Only pure-ASCII samples can be compared across the two unit
            // systems: UTF-16 offset and Character offset coincide there.
            guard text.utf16.count == text.count else { continue }
            for offset in 0...text.utf16.count {
                for scope in AISettingsManager.CompletionContextScope.allCases {
                    let expected = reference(text, at: offset, scope: scope)
                    let actual = AIContextManager.shared.completionWindow(
                        text: text, cursorIndex: offset, scope: scope)
                    XCTAssertEqual(actual.prefix, expected.prefix,
                                   "prefix mismatch: scope=\(scope) offset=\(offset) text=\(text.debugDescription)")
                    XCTAssertEqual(actual.suffix, expected.suffix,
                                   "suffix mismatch: scope=\(scope) offset=\(offset) text=\(text.debugDescription)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "expected a broad cross-check")
    }

    func testCurrentLineStopsAtLineBoundary() {
        let text = "first line\nsecond line here\nthird"
        let cursor = (text as NSString).range(of: "second").location
        let actual = AIContextManager.shared.completionWindow(
            text: text, cursorIndex: cursor, scope: .currentLine)
        XCTAssertFalse(actual.prefix.contains("\n"))
        XCTAssertFalse(actual.suffix.contains("\n"))
        XCTAssertTrue(actual.prefix.hasPrefix("second") || actual.prefix.isEmpty || actual.prefix.allSatisfy { $0 != "\n" })
    }

    func testCurrentLineTruncatesLongParagraph() {
        let text = String(repeating: "x", count: 500) + "|"
        let cursor = text.utf16.count - 1
        let actual = AIContextManager.shared.completionWindow(
            text: text, cursorIndex: cursor, scope: .currentLine)
        XCTAssertEqual(actual.prefix.utf16.count, 300, "prefix is capped at 300 characters")
    }

    func testTruncationNeverSplitsASurrogatePair() {
        // Place an emoji so the 300-unit cut lands between its two UTF-16 halves.
        // A lone surrogate would be silently replaced with U+FFFD in the prompt.
        for padding in 296...304 {
            let text = String(repeating: "x", count: padding) + "👋" + String(repeating: "y", count: 10) + "|"
            let cursor = text.utf16.count - 1
            let window = AIContextManager.shared.completionWindow(
                text: text, cursorIndex: cursor, scope: .currentLine)
            XCTAssertFalse(window.prefix.unicodeScalars.contains("\u{FFFD}"), "padding \(padding)")
            XCTAssertEqual(window.prefix, String(window.prefix.unicodeScalars.map(Character.init)),
                           "prefix must be valid Unicode (padding \(padding))")
            XCTAssertLessThanOrEqual(window.prefix.utf16.count, 302, "padding \(padding)")
        }
        for padding in 146...154 {
            let text = "|" + String(repeating: "x", count: padding) + "👋" + String(repeating: "y", count: 10)
            let window = AIContextManager.shared.completionWindow(
                text: text, cursorIndex: 1, scope: .currentLine)
            XCTAssertFalse(window.suffix.unicodeScalars.contains("\u{FFFD}"), "padding \(padding)")
            XCTAssertLessThanOrEqual(window.suffix.utf16.count, 152, "padding \(padding)")
        }
    }

    func testCursorPastEndIsClamped() {
        let text = "abc\ndef"
        let clamped = AIContextManager.shared.completionWindow(
            text: text, cursorIndex: 999, scope: .fullDocument)
        XCTAssertEqual(clamped.prefix, text)
        XCTAssertEqual(clamped.suffix, "")

        let negative = AIContextManager.shared.completionWindow(
            text: text, cursorIndex: -5, scope: .fullDocument)
        XCTAssertEqual(negative.prefix, "")
        XCTAssertEqual(negative.suffix, text)
    }
}
