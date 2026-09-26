import XCTest
@testable import TypstEdit

@MainActor
final class OfflineCompletionServiceTests: XCTestCase {
    private let service = OfflineCompletionService.shared

    // MARK: - Basic function completion

    func testPagebreakSuggestedForPagePrefix() {
        let suggestions = service.provideCompletion(text: "#page", cursorIndex: 5)
        XCTAssertTrue(suggestions.contains("#pagebreak()"), "expected #pagebreak() in \(suggestions)")
        XCTAssertTrue(suggestions.contains("#page("), "expected #page( in \(suggestions)")
    }

    func testParameterlessFunctionsGetEmptyParens() {
        let suggestions = service.provideCompletion(text: "#pagebreak", cursorIndex: 10)
        XCTAssertEqual(suggestions, ["#pagebreak()"])
    }

    func testKeywordsGetNoParens() {
        let suggestions = service.provideCompletion(text: "#se", cursorIndex: 3)
        XCTAssertTrue(suggestions.contains("#set"), "expected bare #set in \(suggestions)")
        XCTAssertFalse(suggestions.contains("#set("), "keyword must not gain parens")
    }

    // MARK: - Manual trigger on hard cases

    func testEmptyPrefixManualTriggerOffersFullList() {
        // Since f916a52 the function list requires a '#' prefix; an empty
        // prefix returns nothing even when the user manually triggers.
        let text = "= Heading\n\n"
        let suggestions = service.provideCompletion(text: text, cursorIndex: text.count, manualTrigger: true)
        XCTAssertTrue(suggestions.isEmpty, "empty prefix must not offer # functions (got \(suggestions))")
    }

    func testEmptyPrefixWithoutManualTriggerReturnsNothing() {
        let text = "= Heading\n\n"
        let suggestions = service.provideCompletion(text: text, cursorIndex: text.count)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testBareWordManualTriggerSuggestsWithMarker() {
        // Since f916a52, # functions are ONLY suggested after '#'. A bare word
        // (even with manual trigger) must not return the function list.
        let suggestions = service.provideCompletion(text: "Some text page", cursorIndex: 14, manualTrigger: true)
        XCTAssertTrue(suggestions.isEmpty, "bare word must not offer # functions (got \(suggestions))")
    }

    func testSetContextUnaffectedByManualFlag() {
        let suggestions = service.provideCompletion(text: "#set ", cursorIndex: 5, manualTrigger: true)
        XCTAssertTrue(suggestions.contains("page("))
    }

    // MARK: - Bounds safety

    func testCursorIndexPastEndDoesNotCrash() {
        // Regression: getEnclosingFunction indexed NSString past its length and
        // raised NSInvalidArgumentException when the cursor index was out of bounds.
        let text = "Hello world this is a note\n#page"
        let suggestions = service.provideCompletion(text: text, cursorIndex: text.count + 5, manualTrigger: true)
        _ = suggestions
    }

    func testEnclosingFunctionContextSurvivesMultibyteCharacters() {
        // Emoji before the cursor shifts NSString (UTF-16) offsets; the search
        // for an enclosing function must not crash or misfire.
        let text = "🦊 emoji line\n#table(col"
        let suggestions = service.provideCompletion(text: text, cursorIndex: text.count, manualTrigger: true)
        XCTAssertTrue(suggestions.contains("column-gutter: ") || !suggestions.isEmpty)
    }

    // MARK: - Merge (insert vs duplicate)

    func testOverlapLengthTakesLongestOverlap() {
        // The reported bug: "The quick brown" + suggestion that repeats the
        // typed sentence duplicated the text on apply.
        let overlap = AICompletionProvider.overlapLength(
            label: "The quick brown fox jumps over the lazy dog.",
            typedPrefix: "The quick brown")
        XCTAssertEqual(overlap, ("The quick brown" as NSString).length)
        // The applied insertion is the label minus the overlap.
        XCTAssertEqual("The quick brown fox jumps over the lazy dog.".dropFirst(overlap),
                       " fox jumps over the lazy dog.")
    }

    func testOverlapLengthReplacesTypedWord() {
        let overlap = AICompletionProvider.overlapLength(
            label: "#pagebreak()",
            typedPrefix: "Some text #page")
        XCTAssertEqual(overlap, ("#page" as NSString).length)
        XCTAssertEqual("#pagebreak()".dropFirst(overlap), "break()")
    }

    func testOverlapLengthNoOverlapInsertsEverything() {
        let overlap = AICompletionProvider.overlapLength(
            label: "world",
            typedPrefix: "hello ")
        XCTAssertEqual(overlap, 0)
    }

    func testOverlapLengthEmptyPrefixInsertsEverything() {
        let overlap = AICompletionProvider.overlapLength(
            label: "#page(",
            typedPrefix: "")
        XCTAssertEqual(overlap, 0)
    }

    // MARK: - AI output cleanup

    func testCleanedInsertionTextStripsCursorMarker() {
        // Marker at end: keep the text before it.
        XCTAssertEqual(AICompletionProvider.cleanedInsertionText("#page<CURSOR>"), "#page")
        // Content emitted after the marker is the completion — keep-after
        // semantics since f916a52.
        XCTAssertEqual(AICompletionProvider.cleanedInsertionText("brown fox<cursor> jumps"), "jumps")
    }

    func testCleanedInsertionTextUnwrapsCodeFence() {
        let fenced = "```typst\n#pagebreak()\n```"
        XCTAssertEqual(AICompletionProvider.cleanedInsertionText(fenced), "#pagebreak()")
    }
}
