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
        // Cursor on an empty line — explicit invocation must still offer the
        // function list, not return nothing.
        let text = "= Heading\n\n"
        let suggestions = service.provideCompletion(text: text, cursorIndex: text.count, manualTrigger: true)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.contains("#pagebreak()"))
    }

    func testEmptyPrefixWithoutManualTriggerReturnsNothing() {
        let text = "= Heading\n\n"
        let suggestions = service.provideCompletion(text: text, cursorIndex: text.count)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testBareWordManualTriggerSuggestsWithMarker() {
        // Typing `page` (no #) and invoking manually should offer #functions
        // that will merge onto the typed word.
        let suggestions = service.provideCompletion(text: "Some text page", cursorIndex: 14, manualTrigger: true)
        XCTAssertTrue(suggestions.contains("#pagebreak"), "expected #pagebreak in \(suggestions)")
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

    func testMergeInsertionTakesLongestOverlap() {
        // The reported bug: "The quick brown" + suggestion that repeats the
        // typed sentence duplicated the text on apply.
        let (replaceCount, insertion) = AICompletionProvider.mergeInsertion(
            label: "The quick brown fox jumps over the lazy dog.",
            typedPrefix: "The quick brown")
        XCTAssertEqual(insertion, " fox jumps over the lazy dog.")
        XCTAssertEqual(replaceCount, ("The quick brown" as NSString).length)
    }

    func testMergeInsertionReplacesTypedWord() {
        let (replaceCount, insertion) = AICompletionProvider.mergeInsertion(
            label: "#pagebreak()",
            typedPrefix: "Some text #page")
        XCTAssertEqual(insertion, "break()")
        XCTAssertEqual(replaceCount, ("#page" as NSString).length)
    }

    func testMergeInsertionNoOverlapInsertsEverything() {
        let (replaceCount, insertion) = AICompletionProvider.mergeInsertion(
            label: "world",
            typedPrefix: "hello ")
        XCTAssertEqual(insertion, "world")
        XCTAssertEqual(replaceCount, 0)
    }

    func testMergeInsertionEmptyPrefixInsertsEverything() {
        let (replaceCount, insertion) = AICompletionProvider.mergeInsertion(
            label: "#page(",
            typedPrefix: "")
        XCTAssertEqual(insertion, "#page(")
        XCTAssertEqual(replaceCount, 0)
    }

    // MARK: - AI output cleanup

    func testCleanedInsertionTextStripsCursorMarker() {
        XCTAssertEqual(AICompletionProvider.cleanedInsertionText("#page<CURSOR>"), "#page")
        XCTAssertEqual(AICompletionProvider.cleanedInsertionText("brown fox<cursor> jumps"), "brown fox")
    }

    func testCleanedInsertionTextUnwrapsCodeFence() {
        let fenced = "```typst\n#pagebreak()\n```"
        XCTAssertEqual(AICompletionProvider.cleanedInsertionText(fenced), "#pagebreak()")
    }
}
