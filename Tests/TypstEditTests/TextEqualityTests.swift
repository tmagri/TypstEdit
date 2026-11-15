import XCTest
@testable import TypstEdit

/// The editor compares the whole document against a saved copy on every
/// keystroke. These tests pin the fast paths that keep that O(1) for the typing
/// case, and — more importantly — pin that they are still *correct* for the
/// cases where content really is equal or really does differ.
final class TextEqualityTests: XCTestCase {

    // MARK: - equal

    func testEqualIdentical() {
        XCTAssertTrue(TextEquality.equal("hello", "hello"))
        XCTAssertTrue(TextEquality.equal("", ""))
    }

    func testEqualDifferentLength() {
        // The typing case: one character appended. Must be false, and must be
        // decided by the length gate rather than by comparing contents.
        XCTAssertFalse(TextEquality.equal("hello", "hello!"))
        XCTAssertFalse(TextEquality.equal("hello!", "hello"))
    }

    func testEqualSameLengthDifferentContent() {
        // Same length defeats the length gate, so the byte compare must run.
        XCTAssertFalse(TextEquality.equal("hello", "hellp"))
        // Differs only in the last character of a long string: the case a
        // comparison would still have to walk all the way to.
        let long = String(repeating: "a", count: 100_000)
        XCTAssertFalse(TextEquality.equal(long + "b", long + "c"))
        XCTAssertTrue(TextEquality.equal(long + "b", long + "b"))
    }

    func testEqualLargeIdentical() {
        let text = String(repeating: "lorem ipsum dolor sit amet ", count: 20_000)
        XCTAssertTrue(TextEquality.equal(text, text))
        // Distinct copies of the same content: no pointer shortcut available.
        let copy = String(decoding: Array(text.utf8), as: UTF8.self)
        XCTAssertTrue(TextEquality.equal(text, copy))
    }

    func testEqualNonASCII() {
        // Multi-byte content must round-trip correctly through the UTF-8 byte
        // compare (an emoji is one Character but two UTF-16 units and four UTF-8
        // bytes, so length checks must be in matching units).
        XCTAssertTrue(TextEquality.equal("héllo 👋 wörld", "héllo 👋 wörld"))
        XCTAssertFalse(TextEquality.equal("héllo 👋 wörld", "héllo 👋 worlD"))
        // Same grapheme count, different UTF-16 length.
        XCTAssertFalse(TextEquality.equal("👋", "👋🏽"))
    }

    // MARK: - trimmedRange

    func testTrimmedRangeStripsSurroundingWhitespace() {
        let s = "\n\n  hello  \n\n"
        let range = TextEquality.trimmedRange(of: s)
        XCTAssertEqual((s as NSString).substring(with: range), "hello")
    }

    func testTrimmedRangeAllWhitespace() {
        let s = "  \n\t\n "
        XCTAssertEqual(TextEquality.trimmedRange(of: s).length, 0)
    }

    func testTrimmedRangeNoWhitespace() {
        let s = "hello"
        XCTAssertEqual(TextEquality.trimmedRange(of: s), NSRange(location: 0, length: 5))
    }

    // MARK: - equalIgnoringSurroundingWhitespace

    func testEqualIgnoringWhitespaceTrailingNewline() {
        // The reason this helper exists: SourceEditor normalises a trailing
        // newline on load, which must not make a freshly opened file look dirty.
        XCTAssertTrue(TextEquality.equalIgnoringSurroundingWhitespace("hello\n\n", "hello"))
        XCTAssertTrue(TextEquality.equalIgnoringSurroundingWhitespace("  hello  ", "hello"))
    }

    func testEqualIgnoringWhitespaceRealDifference() {
        XCTAssertFalse(TextEquality.equalIgnoringSurroundingWhitespace("hello\n", "hellp\n"))
        XCTAssertFalse(TextEquality.equalIgnoringSurroundingWhitespace("hello", "hello world"))
    }

    func testEqualIgnoringWhitespaceInteriorWhitespaceMatters() {
        // Only *surrounding* whitespace is ignored; interior changes are real edits.
        XCTAssertFalse(TextEquality.equalIgnoringSurroundingWhitespace("a b", "a  b"))
    }

    func testEqualIgnoringWhitespaceLargeDocumentTyping() {
        // Mirrors the real check: a 1.6 MB document, one character typed.
        let base = String(repeating: "paragraph of prose text.\n\n", count: 60_000)
        let typed = base + "x"
        XCTAssertFalse(TextEquality.equalIgnoringSurroundingWhitespace(typed, base))
        XCTAssertTrue(TextEquality.equalIgnoringSurroundingWhitespace(base, base))
    }

    // MARK: - offset helpers

    func testIndexAtUTF16OffsetMatchesCharacterLookup() {
        let s = "abc\ndef\nghi"
        for offset in 0...s.utf16.count {
            guard let idx = TextEquality.index(utf16Offset: offset, in: s) else {
                return XCTFail("offset \(offset) should resolve")
            }
            XCTAssertEqual(TextEquality.utf16Offset(of: idx, in: s), offset)
        }
    }

    func testIndexAtUTF16OffsetRejectsOutOfRange() {
        XCTAssertNil(TextEquality.index(utf16Offset: -1, in: "abc"))
        XCTAssertNil(TextEquality.index(utf16Offset: 4, in: "abc"))
    }

    func testLengthCountsUTF16UnitsNotGraphemes() {
        // The editor's ranges are UTF-16, so the length gate must match. An
        // emoji is 1 Character but 2 UTF-16 units.
        XCTAssertEqual(TextEquality.length("👋"), 2)
        XCTAssertEqual(TextEquality.length("abc"), 3)
    }
}
