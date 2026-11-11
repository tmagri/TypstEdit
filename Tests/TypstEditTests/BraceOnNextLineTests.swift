import XCTest
@testable import TypstEdit

/// Regression for Revelation.note: a construct opener whose block brace sits
/// on the NEXT line (`#show heading.where(level: 1): it =>` ⏎ `{`).
///
/// Typst terminates a statement at a newline — only an unclosed bracket
/// continues one — so a trailing `=>` (or `=`) is a hard
/// "error: expected expression" pointing just past the arrow, even though
/// the author's intent is unambiguous. The `.note` auto-fix pass joins such
/// an opener with its brace line so the note compiles exactly as written.
final class BraceOnNextLineTests: XCTestCase {

    /// The exact shape from Revelation.note lines 48–53.
    private static let construct = """
    // Every major (level-1) chapter heading starts on a fresh page.
    #show heading.where(level: 1): it =>
    {
      pagebreak(weak: true)
      it
    }

    = Chapter
    Prose after the rule.
    """

    // MARK: - The join

    func testAutoFixJoinsArrowWithBraceOnNextLine() {
        let output = TypstCompiler.autoFixBrokenNoteSyntax(Self.construct)
        XCTAssertTrue(
            output.contains("it => {"),
            "the opener line and its brace must be joined: \(output)"
        )
        XCTAssertFalse(
            output.contains("it =>\n"),
            "no trailing arrow may remain: \(output)"
        )
        XCTAssertTrue(output.contains("  pagebreak(weak: true)"), "body lines must survive verbatim: \(output)")
        XCTAssertTrue(output.contains("\n}"), "the closing brace line must survive: \(output)")
    }

    func testAutoFixJoinsLetBindingWithBraceOnNextLine() {
        let output = TypstCompiler.autoFixBrokenNoteSyntax(
            "#let make = (n) =>\n{\n  n * 2\n}\n\n= T\n"
        )
        XCTAssertTrue(output.contains("#let make = (n) => {"), "got: \(output)")
        XCTAssertFalse(output.contains("=\n{"), "no trailing assignment may remain: \(output)")
    }

    /// A `{`-line with trailing content joins whole: `it =>` + `{ x }`
    /// becomes `it => { x }`.
    func testAutoFixJoinsBraceLineWithTrailingContent() {
        let output = TypstCompiler.autoFixBrokenNoteSyntax("#let f = (x) =>\n{ x * 2 }\n")
        XCTAssertEqual(output, "#let f = (x) => { x * 2 }\n")
    }

    /// A `===` run is a Markdown setext underline, not an assignment opener —
    /// and a prose line ending in `:` must never merge with what follows.
    func testAutoFixDoesNotJoinSetextUnderlineOrProseColon() {
        let input = "Title\n===\n{not code}\n\nAnd a list:\n- a\n"
        XCTAssertEqual(TypstCompiler.autoFixBrokenNoteSyntax(input), input)
    }

    /// The common one-line style must pass through byte-identical.
    func testAutoFixLeavesSameLineBraceAlone() {
        let input = "#show heading.where(level: 1): it => {\n  it\n}\n"
        XCTAssertEqual(TypstCompiler.autoFixBrokenNoteSyntax(input), input)
    }

    /// Inside a fenced code block nothing is live Typst — never rewrite.
    func testAutoFixLeavesFencedBraceAlone() {
        let input = "```typst\n#let f = (x) =>\n{\n  x\n}\n```\n"
        XCTAssertEqual(TypstCompiler.autoFixBrokenNoteSyntax(input), input)
    }

    /// A comparison `x ==` (or `<=`, `>=`) must not read as an assignment
    /// opener: only a bare trailing `=` after a value joins.
    func testAutoFixDoesNotJoinComparisonOperators() {
        let input = "#let done = (a ==\n{b})\n"
        XCTAssertEqual(TypstCompiler.autoFixBrokenNoteSyntax(input), input)
    }

    /// Mirror of the CESE-side rules test (`NoteTypstRegions.isBlockOpenerLine`)
    /// — keep both helpers in sync.
    func testBlockOpenerLineRules() {
        XCTAssertTrue(TypstCompiler.isBlockOpenerLine("#show heading.where(level: 1): it =>"))
        XCTAssertTrue(TypstCompiler.isBlockOpenerLine("#let x ="))
        XCTAssertTrue(TypstCompiler.isBlockOpenerLine("#let f = (n) ="))
        XCTAssertFalse(TypstCompiler.isBlockOpenerLine("==="))
        XCTAssertFalse(TypstCompiler.isBlockOpenerLine("#let done = (a =="))
        XCTAssertFalse(TypstCompiler.isBlockOpenerLine("plain prose"))
    }

    // MARK: - Region scanners stay in sync with the join

    /// The region scanner must cover the brace body too: the lenient fallback
    /// fixer protects region lines from repair, and highlighting must match
    /// what actually compiles (the join). The construct spans lines 1–5 —
    /// opener, `{`, body, `}`.
    func testRegionSpansCoverBraceOnNextLineConstruct() {
        let spans = AICompletionService.typstRegionLineSpans(in: Self.construct)
        XCTAssertEqual(spans.count, 1, "only the construct is a region: \(spans)")
        XCTAssertEqual(spans[0].start, 1, "the region starts at the opener line: \(spans)")
        XCTAssertEqual(spans[0].end, 5, "the region ends at the `}` line: \(spans)")
    }

    // MARK: - The real pipeline

    @MainActor
    func testCompileCleanSucceedsOnBraceOnNextLineNote() async {
        let compiler = TypstCompiler()
        let result = await compiler.compileClean(
            content: Self.construct,
            fileExtension: "note",
            originalFileURL: nil,
            projectRoot: nil
        )
        XCTAssertTrue(result.success, "the note must compile as written: \(result.error ?? "")")
        XCTAssertNotNil(result.pdfURL)
    }

    /// When the arrow has nothing to join (nothing follows), the construct is
    /// genuinely unfixable — and the live-preview pipeline must SAY so: the
    /// diagnostic may not be silently swallowed, because the lenient fallback
    /// fixer protects live Typst regions from repair. This is the "error
    /// doesn't show what the cause is" report: with a trailing `=>` Typst
    /// reports "expected expression" right after the arrow, and that message
    /// (with the source line) is exactly what the Issues panel must show.
    @MainActor
    func testPreviewPublishesUnfixableArrowError() async throws {
        let compiler = TypstCompiler()
        defer { compiler.cleanUp() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brace-on-next-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("broken.note")
        let source = "#show heading.where(level: 1): it =>\n\nProse after the rule.\n"
        try source.write(to: file, atomically: true, encoding: .utf8)

        await compiler.updateContent(source: source, fileURL: file)

        // Poll with Task.sleep so main-actor work (diagnostic parsing,
        // publishing) keeps running while the watch cycle settles.
        let deadline = Date().addingTimeInterval(20)
        while compiler.errors.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(
            compiler.errors.isEmpty,
            "an unfixable trailing arrow must surface a diagnostic, got none"
        )
        XCTAssertTrue(
            compiler.errors.contains { $0.message.contains("expected expression") },
            "the diagnostic must carry typst's message, got: \(compiler.errors.map(\.message))"
        )
        XCTAssertTrue(
            compiler.errors.contains { $0.line == 1 },
            "the diagnostic must map to the user's line 1, got: \(compiler.errors.map { "\($0.message) @ \($0.line.map(String.init) ?? "?")" })"
        )
    }
}
