import XCTest
@testable import TypstEdit

/// `isMathMode` drives whether an inserted symbol becomes Typst code (`$x$`)
/// or a Unicode character. It used to count dollars from the start of the
/// document for every call. It now takes a bounded backward fast-exit first,
/// so these tests pin both the answers and the surrounding cases.
final class MathModeTests: XCTestCase {

    func testEmptyDocument() {
        XCTAssertFalse(FormatDetector.isMathMode(in: "", at: 0))
    }

    func testPlainProseIsNotMath() {
        let text = "This is ordinary prose with no math at all."
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: text.utf16.count))
    }

    func testInsideInlineMath() {
        let text = "before $x + y$ after"
        // Cursor between the dollars.
        let inside = (text as NSString).range(of: "x + y").location
        XCTAssertTrue(FormatDetector.isMathMode(in: text, at: inside))
    }

    func testAfterClosingDollarIsNotMath() {
        let text = "before $x + y$ after"
        let after = (text as NSString).range(of: "after").location
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: after))
    }

    func testBeforeOpeningDollarIsNotMath() {
        let text = "before $x + y$ after"
        let before = (text as NSString).range(of: "before").location
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: before))
    }

    func testEscapedDollarDoesNotToggle() {
        // `\$` is a literal dollar, not math delimiters.
        let text: String = #"price is \$5 and \$10 here"#
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: text.utf16.count))
    }

    func testTwoMathBlocksIsNotMathBetweenThem() {
        let text = "$a$ plain $b$"
        let middle = (text as NSString).range(of: "plain").location
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: middle))
        // Inside the second block the parity is odd again.
        let second = (text as NSString).range(of: "b").location
        XCTAssertTrue(FormatDetector.isMathMode(in: text, at: second))
    }

    func testLargeProseDocumentResolvesQuickly() {
        // Guards against reintroducing the substring-per-character scan, which
        // measured ~50 ms on a document this size. The ceiling is deliberately
        // loose: it only needs to catch a regression to that behaviour.
        let prose = String(repeating: "a sentence of ordinary prose. ", count: 40_000)
        let text = prose + "end"
        let start = Date()
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: text.utf16.count))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2,
                          "isMathMode on a ~1.2 MB document should not scan with allocations")
    }

    func testUnclosedMathBlockFarFromStartIsDetected() {
        // A correct answer must not depend on how close the opening `$` is to
        // the cursor: an unclosed block can run for thousands of characters.
        let body = String(repeating: "x + ", count: 3000)   // ~12k units
        let text = "$" + body
        XCTAssertTrue(FormatDetector.isMathMode(in: text, at: text.utf16.count),
                      "an unclosed math block is math however long it is")
    }

    func testCursorPastEndIsClamped() {
        let text = "$x$"
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: 999))
        XCTAssertFalse(FormatDetector.isMathMode(in: text, at: -5))
    }

    func testResultMatchesFullCountImplementation() {
        // Cross-check the fast path against a straightforward reference count
        // over a document with dollars scattered through it.
        let text = "a $b$ c $d$ e $f$ g \\$ h $i$ j $k$ l"
        let ns = text as NSString
        for offset in 0...ns.length {
            var count = 0
            var i = 0
            while i < offset {
                let c = ns.character(at: i)
                if c == 0x5C { i += 2; continue }
                if c == 0x24 { count += 1 }
                i += 1
            }
            let expected = count % 2 != 0
            XCTAssertEqual(FormatDetector.isMathMode(in: text, at: offset), expected,
                           "offset \(offset)")
        }
    }
}
