import XCTest
@testable import TypstEdit

/// Regression coverage for the "save .note → app freezes" bug.
///
/// Two coupled defects:
///
/// 1. **The freeze.** `TypstCompiler.compileClean` ran `typst` with a `Pipe`
///    on stderr and called `waitUntilExit()` before reading the pipe. A
///    broken note emitted ~3.4 MB of diagnostics; typst blocked writing to the
///    full ~64 KB pipe buffer and never exited; the app (main actor) waited
///    forever. `BlockingProcess.run` drains concurrently with the wait.
/// 2. **The flood.** `delimitImproperOperators` escaped `>` inside a live
///    Typst code region (`if parts.len() >= 3 {` → `\>=`), which is invalid in
///    code mode and cascaded into ~4,000 errors — the diagnostic volume that
///    triggered (1). The delimiting pass now masks the same regions the
///    hybrid sanitizer extracts, so the two passes can never disagree about
///    what is live Typst code.
@MainActor
final class SaveFreezeReproTests: XCTestCase {

    private func delimit(_ source: String) -> (output: String, warnings: [TypstError]) {
        TypstCompiler.delimitImproperOperators(source)
    }

    // The exact shape from the user's Genesis.note that triggered the flood:
    // a multi-line `#show` rule whose body compares with `>=`.
    private static let showRuleWithComparison = """
    #show ref: it => {
    let target = str(it.target)
    if target.starts-with("gen-") {
    let parts = target.split("-")
    if parts.len() >= 3 {
        link(it.target, [Gen ] + parts.at(1) + sub(parts.at(2)))
    } else if parts.len() == 2 {
        link(it.target, [Gen ] + parts.at(1))
    } else {
        it
    }

    = Genesis <gen>
    """

    // MARK: - The escaping corruption

    func testDelimitDoesNotEscapeOperatorsInsideLiveTypstRegion() {
        let (output, warnings) = delimit(Self.showRuleWithComparison)
        XCTAssertFalse(output.contains("\\>="), "comparison operators inside a live Typst region must never be escaped, got: \(output)")
        XCTAssertTrue(output.contains("parts.len() >= 3"), "the code line must survive verbatim: \(output)")
        // The `= Genesis <gen>` heading is markup OUTSIDE the region: its `<`
        // opens a valid label and must not be escaped either.
        XCTAssertTrue(output.contains("= Genesis <gen>"), "the labelled heading must survive verbatim: \(output)")
        XCTAssertTrue(warnings.isEmpty, "no advisory warnings expected for valid Typst, got: \(warnings.map(\.message))")
    }

    func testDelimitStillEscapesStrayOperatorsInProse() {
        let (output, warnings) = delimit("Compare: 5 < 3 and 3 > 5 in prose.")
        XCTAssertTrue(output.contains("3 \\> 5"), "prose comparisons must still be escaped: \(output)")
        XCTAssertEqual(warnings.count, 0, "silent escape for prose angles: \(warnings.map(\.message))")
    }

    // MARK: - The sanitizer and the delimiter must agree

    func testSanitizerKeepsComparisonInsideShowRule() {
        let sanitized = AICompletionService.shared.sanitizeMarkdownToTypst(
            Self.showRuleWithComparison, isHybrid: true)
        XCTAssertTrue(sanitized.contains("parts.len() >= 3"),
                      "the live Typst line must reach the output unescaped: \(sanitized)")
        XCTAssertFalse(sanitized.contains("\\>="), "no backslash may appear before >=: \(sanitized)")
    }

    func testEndToEndNoteWithShowRuleCompilesCleanly() async {
        // What `compileClean` (the Save → export-PDF path) produces for this
        // note: preamble + sanitized body. It must be free of the `\>=`
        // corruption, so typst reports at most the user's own brace error —
        // not thousands of cascading ones.
        let note = Self.showRuleWithComparison + "\nProse paragraph citing @gen.\n"
        let sanitized = AICompletionService.shared.sanitizeMarkdownToTypst(note, isHybrid: true)
        let source = TypstCompiler.notePreamble + sanitized
        XCTAssertFalse(source.contains("\\>="), "the compile pipeline must not corrupt comparisons: \(source)")
    }

    // MARK: - Region scanning is shared, not duplicated

    func testRegionSpansMatchExtraction() {
        let source = """
        Text before.
        #let f(x) = {
          if x >= 3 { [big] } else { [small] }
        }
        More prose with 1 < 2.

        #f(5)
        Tail.
        """
        let spans = AICompletionService.typstRegionLineSpans(in: source)
        XCTAssertEqual(spans.count, 2, "definition (multiline) and call site: \(spans)")

        let (text, regions) = AICompletionService.extractTypstRegions(source, marker: Unicode.Scalar(0xE003)!)
        XCTAssertEqual(regions.count, spans.count)
        XCTAssertEqual(regions[0].components(separatedBy: "\n").count,
                       spans[0].end - spans[0].start + 1,
                       "extracted region length must match the span")
        XCTAssertTrue(regions[0].contains("if x >= 3"),
                      "the comparison inside the region must survive extraction: \(regions[0])")
        // Prose after the region keeps its stray `<` …
        XCTAssertTrue(text.contains("More prose with 1 < 2.") || regions.joined().contains("More prose with 1 < 2."))
    }
}
