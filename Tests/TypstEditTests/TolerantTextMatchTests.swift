import XCTest
@testable import TypstEdit

/// Matching rules behind `edit_file`'s tolerant tier: folding typographic
/// variants, ignoring trailing whitespace, and keeping a file's own line
/// endings when a loose match is spliced back in.
final class TolerantTextMatchTests: XCTestCase {

    // MARK: - Normalisation

    func testNormalizeFoldsTypographicQuotesAndDashes() {
        XCTAssertEqual(
            TolerantTextMatch.normalizeForMatch("\u{201C}quoted\u{201D} \u{2018}single\u{2019}"),
            "\"quoted\" 'single'"
        )
        XCTAssertEqual(
            TolerantTextMatch.normalizeForMatch("a\u{2013}b\u{2014}c\u{2212}d\u{2010}e"),
            "a-b-c-d-e"
        )
    }

    func testNormalizeFoldsNonBreakingAndThinSpaces() {
        XCTAssertEqual(TolerantTextMatch.normalizeForMatch("a\u{00A0}b\u{2009}c\u{202F}d"), "a b c d")
    }

    func testNormalizeLeavesFullWidthSpaceAlone() {
        // Meaningful in CJK text, so it must not be folded into ASCII space.
        XCTAssertEqual(TolerantTextMatch.normalizeForMatch("中\u{3000}文"), "中\u{3000}文")
    }

    func testNormalizedLineDropsTrailingWhitespace() {
        XCTAssertEqual(TolerantTextMatch.normalizedLine("alpha   \t"), "alpha")
        XCTAssertEqual(TolerantTextMatch.normalizedLine("alpha \r"), "alpha")
        XCTAssertEqual(TolerantTextMatch.normalizedLine("  alpha"), "  alpha")
    }

    // MARK: - Exact tier

    func testFindExactReturnsEveryOccurrence() {
        let text = "one two one two one"
        let ranges = TolerantTextMatch.findExact("one", in: text)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["one", "one", "one"])
    }

    func testFindExactIgnoresOverlaps() {
        XCTAssertEqual(TolerantTextMatch.findExact("aa", in: "aaaa").count, 2)
    }

    func testFindExactEmptyNeedleFindsNothing() {
        XCTAssertTrue(TolerantTextMatch.findExact("", in: "anything").isEmpty)
    }

    // MARK: - Loose tier

    func testLineMatchIgnoresTypographicVariants() {
        // The model quoted a sentence out of rendered text: curly quotes and
        // an em dash where the source has ASCII.
        let source = "The editor said \"no\" - clearly.\nSecond line.\n"
        let needle = "The editor said \u{201C}no\u{201D} \u{2014} clearly."
        let ranges = TolerantTextMatch.findLineBased(needle, in: source)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(source[ranges[0]]), "The editor said \"no\" - clearly.")
    }

    func testLineMatchIgnoresTrailingWhitespace() {
        let source = "alpha   \nbeta\t\n"
        XCTAssertEqual(TolerantTextMatch.findLineBased("alpha\nbeta", in: source).count, 1)
    }

    func testLineMatchRequiresEveryLine() {
        let source = "alpha\nbeta\n"
        XCTAssertTrue(TolerantTextMatch.findLineBased("alpha\ngamma", in: source).isEmpty)
    }

    func testLineMatchStopsAtContentWhenNeedleHasNoTrailingNewline() {
        let source = "alpha\nbeta\ngamma\n"
        let ranges = TolerantTextMatch.findLineBased("alpha\nbeta", in: source)
        XCTAssertEqual(ranges.count, 1)
        // Range ends at the content, so the newline after "beta" survives.
        XCTAssertEqual(String(source[ranges[0]]), "alpha\nbeta")
    }

    func testLineMatchIncludesTheNewlineWhenNeedleHasOne() {
        let source = "alpha\nbeta\ngamma\n"
        let ranges = TolerantTextMatch.findLineBased("alpha\nbeta\n", in: source)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(source[ranges[0]]), "alpha\nbeta\n")
    }

    func testLineMatchDoesNotMatchTheFinalLineWithoutItsNewline() {
        let source = "alpha\nbeta"
        XCTAssertTrue(TolerantTextMatch.findLineBased("alpha\nbeta\n", in: source).isEmpty)
        XCTAssertEqual(TolerantTextMatch.findLineBased("alpha\nbeta", in: source).count, 1)
    }

    func testLineMatchIsAmbiguousWhenLinesRepeat() {
        let source = "note\nbody\nnote\nbody\n"
        XCTAssertEqual(TolerantTextMatch.findLineBased("note\nbody", in: source).count, 2)
    }

    func testLineMatchIgnoresAllBlankNeedle() {
        // An empty old_string is refused before this, but a whitespace-only
        // one must not match at every position.
        XCTAssertTrue(TolerantTextMatch.findLineBased("  \n\t", in: "a\nb\n").isEmpty)
    }

    // MARK: - Line ending reconciliation

    func testReconcileReusesRegionEndings() {
        let region = "alpha\r\nbeta\r\n"
        let replacement = "alpha\nbeta"
        XCTAssertEqual(
            TolerantTextMatch.reconcileEndings(region: region, replacement: replacement, fallback: "\n"),
            "alpha\r\nbeta"
        )
    }

    func testReconcileFallsBackForNewLines() {
        let region = "alpha\r\nbeta\r\n"
        let replacement = "alpha\ninserted\nbeta"
        XCTAssertEqual(
            TolerantTextMatch.reconcileEndings(region: region, replacement: replacement, fallback: "\r\n"),
            "alpha\r\ninserted\r\nbeta"
        )
    }

    func testReconcileKeepsMixedEndingsOfUntouchedLines() {
        // The region mixes styles; each surviving line must keep its own.
        let region = "alpha\r\nbeta\ngamma\r\n"
        let replacement = "alpha\nbeta\ngamma"
        XCTAssertEqual(
            TolerantTextMatch.reconcileEndings(region: region, replacement: replacement, fallback: "\n"),
            "alpha\r\nbeta\ngamma"
        )
    }

    func testReconcileSingleLineReplacementIsUntouched() {
        XCTAssertEqual(
            TolerantTextMatch.reconcileEndings(region: "x", replacement: "y", fallback: "\r\n"),
            "y"
        )
    }

    func testLineEndingDetectsDominantStyle() {
        XCTAssertEqual(TolerantTextMatch.lineEnding(in: "a\r\nb\r\nc\n", fallback: "\n"), "\r\n")
        XCTAssertEqual(TolerantTextMatch.lineEnding(in: "a\nb\nc\r\n", fallback: "\r\n"), "\n")
        XCTAssertEqual(TolerantTextMatch.lineEnding(in: "a\r\nb\n", fallback: "\n"), "\n")
        XCTAssertEqual(TolerantTextMatch.lineEnding(in: "no endings", fallback: "\r\n"), "\r\n")
    }

    // MARK: - Failure hints

    func testClosestLinesPointAtTheRegionTheModelMeant() {
        let source = """
        # Introduction
        This is the opening paragraph.
        # Results
        Numbers go here.
        """
        let hints = TolerantTextMatch.closestLines(to: "This is the opening paragraf.", in: source)
        XCTAssertEqual(hints.count, 1)
        XCTAssertTrue(hints[0].hasPrefix("2: "), "expected the second line, got \(hints)")
        XCTAssertTrue(hints[0].contains("opening paragraph"))
    }

    func testClosestLinesIsEmptyWhenNothingResemblesTheNeedle() {
        XCTAssertTrue(TolerantTextMatch.closestLines(to: "zzzzzzzz", in: "alpha\nbeta\n").isEmpty)
    }

    func testAlreadyPresentDetectsAResentReplacement() {
        let source = "one\nreplaced text\nthree\n"
        XCTAssertTrue(
            TolerantTextMatch.alreadyPresent(replacementFirstLines: "replaced text", in: source)
        )
        XCTAssertFalse(
            TolerantTextMatch.alreadyPresent(replacementFirstLines: "never written", in: source)
        )
    }
}
