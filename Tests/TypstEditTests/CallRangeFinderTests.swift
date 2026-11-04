import XCTest
@testable import TypstEdit

final class CallRangeFinderTests: XCTestCase {
    func testTableRangeContainsCursor() {
        let text = "Intro\n#table(columns: 2, [a], [b])\nAfter"
        let start = (text as NSString).range(of: "#table").location
        let end = NSMaxRange((text as NSString).range(of: "[b])"))
        let expected = NSRange(location: start, length: end - start)

        XCTAssertEqual(TableDetector.findTableRange(in: text, at: start), expected)
        XCTAssertEqual(TableDetector.findTableRange(in: text, at: start + 3), expected)
        XCTAssertEqual(TableDetector.findTableRange(in: text, at: end), expected)
        XCTAssertNil(TableDetector.findTableRange(in: text, at: 2))
        XCTAssertNil(TableDetector.findTableRange(in: text, at: end + 2))
    }

    func testUnclosedCallIsIgnored() {
        let text = "#table(columns: 2, [a]\n\n#outline(depth: 2)"
        XCTAssertNil(TableDetector.findTableRange(in: text, at: 5))
        let outline = (text as NSString).range(of: "#outline(depth: 2)")
        XCTAssertEqual(OutlineDetector.findOutlineRange(in: text, at: outline.location + 3), outline)
    }

    func testNestedParenthesesAndNonASCII() {
        let text = "Ünïcødé 👋 #bibliography((\"a.bib\", \"b.bib\"), title: [Réf])"
        let range = (text as NSString).range(of: "#bibliography((\"a.bib\", \"b.bib\"), title: [Réf])")
        XCTAssertEqual(BibliographyDetector.findBibliographyRange(in: text, at: range.location + 20), range)
    }

    func testTypstImagePrefersInnermostStart() {
        let text = "#box(#image(\"a.png\", width: 50%))"
        let image = (text as NSString).range(of: "#image(\"a.png\", width: 50%)")
        XCTAssertEqual(ImageDetector.findImageRange(in: text, at: image.location + 8), image)
    }

    func testMarkdownImageNearCursor() {
        let padding = String(repeating: "x", count: 5000)
        let text = padding + " ![alt](pic.png) " + padding
        let image = (text as NSString).range(of: "![alt](pic.png)")
        XCTAssertEqual(ImageDetector.findImageRange(in: text, at: image.location + 3), image)
    }
}
