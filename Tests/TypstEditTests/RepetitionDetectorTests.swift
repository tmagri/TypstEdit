import XCTest
@testable import TypstEdit

final class RepetitionDetectorTests: XCTestCase {

    /// Feeds `text` in small streamed-sized pieces; returns the first loop.
    private func stream(_ text: String, pieceSize: Int = 7) -> RepetitionDetector.Loop? {
        var detector = RepetitionDetector()
        var piece = ""
        for character in text {
            piece.append(character)
            if piece.count >= pieceSize {
                if let loop = detector.feed(piece) { return loop }
                piece = ""
            }
        }
        return piece.isEmpty ? nil : detector.feed(piece)
    }

    private let intro = "Here is how to set the page margins in Typst. Use the page function with a margin argument. "

    func testCatchesAParagraphRepeatedOverAndOver() {
        let unit = "I will now update the document to fix the heading levels as requested. "
        let text = intro + String(repeating: unit, count: 30)
        let loop = stream(text)
        XCTAssertNotNil(loop)
        XCTAssertEqual(loop?.unitByteLength, unit.utf8.count)
        XCTAssertGreaterThanOrEqual(loop?.repeats ?? 0, RepetitionDetector.minRepeats)
    }

    func testCatchesALongUnit() {
        let unit = "Long reasoning passage that loops as a whole. "
            + (0..<12).map { "Point \($0) is considered carefully here. " }.joined()
        let loop = stream(intro + String(repeating: unit, count: 6))
        XCTAssertEqual(loop?.unitByteLength, unit.utf8.count)
    }

    func testIgnoresOrdinaryProse() {
        let text = (0..<200).map { "Paragraph \($0) explains step \($0 * 3) of the setup in its own words. " }.joined()
        XCTAssertNil(stream(text))
    }

    func testIgnoresAFewIdenticalTableRows() {
        let row = "| value | value | value |\n"
        let text = intro + String(repeating: row, count: 6) + "That is the table."
        XCTAssertNil(stream(text))
    }

    func testShortUnitNeedsALongerRun() {
        let shortRun = intro + String(repeating: "0, ", count: 250) // 750 bytes
        XCTAssertNil(stream(shortRun))
        let longRun = intro + String(repeating: "0, ", count: 700)
        XCTAssertNotNil(stream(longRun))
    }

    func testHandlesMultibyteText() {
        let unit = "Ich überprüfe die Überschrift – noch einmal. 🔁 "
        let loop = stream(intro + String(repeating: unit, count: 30))
        XCTAssertEqual(loop?.unitByteLength, unit.utf8.count)
        XCTAssertFalse(loop?.unit.contains("\u{FFFD}") ?? true)
    }

    func testKeptPrefixEndsAfterOneCopy() {
        let unit = "Checking the margins again to be sure they are right. "
        let text = intro + String(repeating: unit, count: 30)
        guard let loop = stream(text, pieceSize: text.count) else {
            return XCTFail("no loop found")
        }
        let kept = RepetitionDetector.keptPrefix(of: text, before: loop)
        XCTAssertTrue(kept.hasPrefix(intro))
        XCTAssertLessThan(kept.utf8.count, intro.utf8.count + 2 * unit.utf8.count)
    }

    func testPreviewIsSingleLineAndBounded() {
        XCTAssertEqual(RepetitionDetector.preview("a\n\n  b"), "a b")
        XCTAssertEqual(RepetitionDetector.preview("\n\n"), "(whitespace)")
        XCTAssertTrue(RepetitionDetector.preview(String(repeating: "x", count: 500)).hasSuffix("…"))
    }
}
