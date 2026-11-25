import XCTest
@testable import TypstEdit

/// A notification's handler closure can run off the main actor, so a plain
/// `var` captured by it to record what fired isn't safe to mutate without
/// this: a small lock-protected box, used only to shuttle a value back out
/// of `XCTNSNotificationExpectation.handler` in the tests below.
private final class Captured<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Behavior of the built-in chat tools: paged reads, exact-match edits with the
/// read-before-edit invariant, case-insensitive grep, and the Python sandbox.
@MainActor
final class LocalToolExecutorTests: XCTestCase {

    private var workDir: URL!
    private var executor: LocalToolExecutor!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalToolExecutorTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        executor = LocalToolExecutor()
        executor.scope = .project(root: workDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Helpers

    private func write(_ name: String, _ text: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func read(_ path: String) throws -> String { try String(contentsOf: workDir.appendingPathComponent(path), encoding: .utf8) }

    @discardableResult
    private func run(_ tool: String, _ args: [String: Any], approve: Bool = true) async throws -> String {
        try await executor.execute(toolName: tool, arguments: args) { _ in approve }
    }

    private func assertThrows(_ expected: (LocalToolError) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected a LocalToolError", file: file, line: line)
        } catch let error as LocalToolError {
            XCTAssertTrue(expected(error), "unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - Reading

    func testSmallFileComesBackWholeWithoutPagingNoise() async throws {
        try write("small.typ", "= Title\n\nBody")
        let out = try await run("read_file", ["path": "small.typ"])
        XCTAssertEqual(out, "= Title\n\nBody")
    }

    func testLargeFileIsWindowedWithOffsetHeader() async throws {
        let lines = (1...900).map { "line \($0)" }.joined(separator: "\n")
        try write("big.typ", lines)

        let first = try await run("read_file", ["path": "big.typ"])
        XCTAssertTrue(first.hasPrefix("[lines 1-400 of 900 in 'big.typ']"), first.prefix(80).description)
        XCTAssertTrue(first.contains("call again with offset: 401"))
        XCTAssertTrue(first.contains("line 400"))
        XCTAssertFalse(first.contains("line 401"))

        let second = try await run("read_file", ["path": "big.typ", "offset": 401, "limit": 10])
        XCTAssertTrue(second.hasPrefix("[lines 401-410 of 900"), second.prefix(80).description)
        XCTAssertTrue(second.contains("line 410"))
    }

    func testOutlineModeMapsALongDocument() async throws {
        var lines = (1...900).map { "body \($0)" }
        lines[0] = "= Final design"
        lines[299] = "== Colours"
        lines[599] = "= Appendix"
        lines[700] = "#include \"steps.typ\""
        try write("Mugs.typ", lines.joined(separator: "\n"))

        let out = try await run("read_file", ["path": "Mugs.typ", "outline": true])
        XCTAssertTrue(out.hasPrefix("[outline of 'Mugs.typ' — 900 lines, 3 headings]"), out)
        XCTAssertTrue(out.contains("1-599: = Final design"), out)
        XCTAssertTrue(out.contains("300-599: == Colours"), out)
        XCTAssertTrue(out.contains("600-900: = Appendix"), out)
        XCTAssertTrue(out.contains("701: #include \"steps.typ\""), out)
        XCTAssertFalse(out.contains("body 5"))
    }

    func testOutlineDoesNotSatisfyReadBeforeEdit() async throws {
        try write("doc.typ", "= Title\nalpha\n")
        _ = try await run("read_file", ["path": "doc.typ", "outline": true])
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "gamma"])
        }
    }

    func testMoveLinesRequiresAReadThenMovesAndKeepsCRLF() async throws {
        try write("doc.typ", "= Design\r\nA\r\n= Transform\r\nT\r\n= Appendix\r\n")
        let args: [String: Any] = ["path": "doc.typ", "start_line": 3, "end_line": 4, "before_line": 6, "start_text": "= Transform"]
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("move_lines", args)
        }
        _ = try await run("read_file", ["path": "doc.typ"])
        let out = try await run("move_lines", args)
        XCTAssertTrue(out.contains("Moved lines 3-4 (2 lines)"), out)
        XCTAssertTrue(out.contains("now start at line 4"), out)
        XCTAssertEqual(try read("doc.typ"), "= Design\r\nA\r\n= Appendix\r\n= Transform\r\nT\r\n")
    }

    func testMoveLinesDeniedLeavesFileAlone() async throws {
        try write("doc.typ", "a\nb\nc\n")
        _ = try await run("read_file", ["path": "doc.typ"])
        await assertThrows({ if case .approvalDenied = $0 { return true }; return false }) {
            try await self.run("move_lines", ["path": "doc.typ", "start_line": 1, "end_line": 1, "before_line": 4, "start_text": "a"], approve: false)
        }
        XCTAssertEqual(try read("doc.typ"), "a\nb\nc\n")
    }

    func testOffsetPastEndExplainsInsteadOfCrashing() async throws {
        try write("short.typ", "a\nb")
        let out = try await run("read_file", ["path": "short.typ", "offset": 99])
        XCTAssertTrue(out.contains("only has 2 lines"), out)
    }

    func testFileOverRewriteLimitIsStillReadableAndEditable() async throws {
        // ~600 KB: above write_file's 300 KB diff cap, below the scan cap.
        let filler = String(repeating: "x", count: 90)
        let lines = (1...6_000).map { "\($0): \(filler)" }
        try write("huge.typ", lines.joined(separator: "\n"))

        let window = try await run("read_file", ["path": "huge.typ", "limit": 5])
        XCTAssertTrue(window.hasPrefix("[lines 1-5 of 6000 in 'huge.typ']"), window.prefix(60).description)

        _ = try await run("read_file", ["path": "huge.typ", "offset": 3_000, "limit": 1])
        let edited = try await run("edit_file", [
            "path": "huge.typ", "old_string": "3000: \(filler)", "new_string": "3000: CHANGED"
        ])
        XCTAssertTrue(edited.contains("1 place"), edited)
        XCTAssertTrue(try read("huge.typ").contains("3000: CHANGED"))

        // Whole-file rewrite of a file that big is refused with a hint.
        await assertThrows({ if case .fileTooLarge = $0 { return true }; return false }) {
            try await self.run("write_file", ["path": "huge.typ", "content": "gone"])
        }

        // move_lines is allowed up to maxScannableBytes (10 MB), so a 600 KB file moves successfully.
        let moved = try await run("move_lines", [
            "path": "huge.typ", "start_line": 1, "end_line": 2, "before_line": 5, "start_text": "1: \(filler)"
        ])
        XCTAssertTrue(moved.contains("Moved lines 1-2"), moved)
    }

    func testMoveLinesRequestsFileMoveLinesApproval() async throws {
        try write("doc.typ", "line 1\nline 2\nline 3\nline 4\n")
        _ = try await run("read_file", ["path": "doc.typ"])
        var seenApproval: PendingApprovalKind?
        _ = try await executor.execute(toolName: "move_lines", arguments: [
            "path": "doc.typ", "start_line": 1, "end_line": 2, "before_line": 5, "start_text": "line 1"
        ]) { kind in
            seenApproval = kind
            return true
        }
        guard case .fileMoveLines(let path, let start, let end, let before, let snippet)? = seenApproval else {
            return XCTFail("Expected .fileMoveLines approval, got \(String(describing: seenApproval))")
        }
        XCTAssertEqual(path, "doc.typ")
        XCTAssertEqual(start, 1)
        XCTAssertEqual(end, 2)
        XCTAssertEqual(before, 5)
        XCTAssertEqual(snippet, "line 1\nline 2")
    }

    func testGetOutlineReturnsStructureAndSatisfiesMoveLines() async throws {
        let content = "= Heading 1\nbody 1\n= Heading 2\nbody 2\n= Heading 3\nbody 3\n"
        try write("notes.typ", content)

        // get_outline for entire file
        let fullOutline = try await run("get_outline", ["path": "notes.typ"])
        XCTAssertTrue(fullOutline.contains("1-2: = Heading 1"))
        XCTAssertTrue(fullOutline.contains("3-4: = Heading 2"))
        XCTAssertTrue(fullOutline.contains("= Heading 3"))

        // get_outline with range
        let rangedOutline = try await run("get_outline", ["path": "notes.typ", "start_line": 3, "end_line": 4])
        XCTAssertTrue(rangedOutline.contains("3-4: = Heading 2"))
        XCTAssertFalse(rangedOutline.contains("= Heading 3"))

        // get_outline satisfies read requirement for move_lines without extra read_file
        let moveOut = try await run("move_lines", [
            "path": "notes.typ", "start_line": 5, "end_line": 6, "before_line": 1, "start_text": "= Heading 3"
        ])
        XCTAssertTrue(moveOut.contains("Moved lines 5-6"))
        XCTAssertTrue(try read("notes.typ").hasPrefix("= Heading 3"))
    }

    func testSkimOutlineReturnsCompressedPreviewsAndSatisfiesMoveLines() async throws {
        let content = """
        = Background
        This document provides deep technical background on quantum error correcting surface codes and fault tolerance.
        = Implementation
        We implement rotated surface codes with syndrome measurement cycles executed in real time.
        = Evaluation
        Simulations show a threshold of one percent under depolarizing circuit noise models.
        """
        try write("paper.typ", content)

        let skimmed = try await run("skim_outline", ["path": "paper.typ"])
        XCTAssertTrue(skimmed.contains("[skim of 'paper.typ'"))
        XCTAssertTrue(skimmed.contains("= Background"))
        XCTAssertTrue(skimmed.contains("Preview:"))
        XCTAssertTrue(skimmed.contains("= Implementation"))

        // Range filtering
        let ranged = try await run("skim_outline", ["path": "paper.typ", "start_line": 3, "end_line": 4])
        XCTAssertTrue(ranged.contains("= Implementation"))
        XCTAssertFalse(ranged.contains("= Evaluation"))

        // skim_outline satisfies move_lines read requirement
        let moveOut = try await run("move_lines", [
            "path": "paper.typ", "start_line": 5, "end_line": 6, "before_line": 1, "start_text": "= Evaluation"
        ])
        XCTAssertTrue(moveOut.contains("Moved lines 5-6"))
        XCTAssertTrue(try read("paper.typ").hasPrefix("= Evaluation"))
    }

    // MARK: - Section addressing

    private let sectionedDoc = "= Intro\nintro text\n= Methods\nmethods text\n== Data\ndata text\n= Results\nresults text\n"

    func testReadFileBySection() async throws {
        try write("doc.typ", sectionedDoc)
        let out = try await run("read_file", ["path": "doc.typ", "section": "Methods"])
        XCTAssertTrue(out.hasPrefix("[section = Methods — lines 3-6]"), out)
        XCTAssertTrue(out.contains("data text"))
        XCTAssertFalse(out.contains("results text"))
        XCTAssertFalse(out.contains("intro text"))
    }

    func testReadFileBySectionReportsUnknownName() async throws {
        try write("doc.typ", sectionedDoc)
        await assertThrows({ error in
            if case .invalidArguments(let message) = error { return message.contains("Closest headings") }
            return false
        }) {
            try await self.run("read_file", ["path": "doc.typ", "section": "Methods overview"])
        }
    }

    func testGetOutlineBySection() async throws {
        try write("doc.typ", sectionedDoc)
        let out = try await run("get_outline", ["path": "doc.typ", "section": "Methods"])
        XCTAssertTrue(out.contains("5-6: == Data"), out)
        XCTAssertFalse(out.contains("= Results"), out)
    }

    func testMoveLinesBySectionNames() async throws {
        try write("doc.typ", sectionedDoc)
        _ = try await run("get_outline", ["path": "doc.typ"])
        let out = try await run("move_lines", ["path": "doc.typ", "section": "Intro", "after_section": "Results"])
        XCTAssertTrue(out.contains("Moved section = Intro"), out)
        XCTAssertEqual(try read("doc.typ"), "= Methods\nmethods text\n== Data\ndata text\n= Results\nresults text\n= Intro\nintro text\n")

        // Names stay valid after the earlier move shifted every line.
        _ = try await run("move_lines", ["path": "doc.typ", "section": "Results", "before_section": "Methods"])
        XCTAssertEqual(try read("doc.typ"), "= Results\nresults text\n= Methods\nmethods text\n== Data\ndata text\n= Intro\nintro text\n")
    }

    func testMoveLinesToEndByWord() async throws {
        try write("doc.typ", sectionedDoc)
        _ = try await run("read_file", ["path": "doc.typ"])
        _ = try await run("move_lines", ["path": "doc.typ", "section": "Data", "before_line": "end"])
        XCTAssertEqual(try read("doc.typ"), "= Intro\nintro text\n= Methods\nmethods text\n= Results\nresults text\n== Data\ndata text\n")
    }

    func testMoveLinesWithoutBlockExplainsBothForms() async throws {
        try write("doc.typ", sectionedDoc)
        _ = try await run("read_file", ["path": "doc.typ"])
        await assertThrows({ error in
            if case .invalidArguments(let message) = error { return message.contains("section") && message.contains("start_line") }
            return false
        }) {
            try await self.run("move_lines", ["path": "doc.typ", "before_line": 1])
        }
    }

    // MARK: - find_section / check_references

    /// Embeds by counting a few topic words, so meaning-only matches are
    /// deterministic and no test reaches a real embedding model.
    private struct TopicEmbeddingProvider: EmbeddingProvider {
        var dimensions: Int { 3 }
        func getEmbedding(for text: String) async throws -> [Float] {
            let lower = text.lowercased()
            return [["wash", "fade", "dishwasher"], ["price", "cost", "bulk"], ["mug", "coffee"]].map { words in
                Float(words.filter { lower.contains($0) }.count) + 0.01
            }
        }
    }

    private struct UnavailableEmbeddingProvider: EmbeddingProvider {
        var dimensions: Int { 3 }
        func getEmbedding(for text: String) async throws -> [Float] { throw EmbeddingError.modelUnavailable }
    }

    func testFindSectionUsesMeaningWhenKeywordsMiss() async throws {
        executor.embeddingProviderOverride = TopicEmbeddingProvider()
        try write("shop.typ", """
        = Coffee mugs
        Our mug range.
        = Dishwasher testing
        Results after fifty wash cycles; prints fade slightly.
        = Bulk pricing
        Price breaks for large orders.
        """)
        let out = try await run("find_section", ["query": "does it survive the wash", "path": "shop.typ"])
        XCTAssertTrue(out.contains("ranked by meaning"), out)
        XCTAssertTrue(out.contains("1. shop.typ:3-4: = Dishwasher testing"), out)
    }

    func testFindSectionRanksAndEnablesMoveLines() async throws {
        executor.embeddingProviderOverride = UnavailableEmbeddingProvider()
        try write("report.typ", """
        = Introduction
        Coffee mug printing overview.
        = Error analysis
        We compute error bars from repeated measurements.
        = Colour management
        Profiles keep printed colours consistent.
        """)
        let out = try await run("find_section", ["query": "error bars", "path": "report.typ"])
        XCTAssertTrue(out.contains("ranked by keywords (no embedding model reachable)"), out)
        XCTAssertTrue(out.contains("1. report.typ:3-4: = Error analysis"), out)
        XCTAssertTrue(out.contains("section: \"= Error analysis\""), out)

        // A find_section result counts as having seen the file's layout.
        _ = try await run("move_lines", ["path": "report.typ", "section": "= Error analysis", "before_section": "Introduction"])
        XCTAssertTrue(try read("report.typ").hasPrefix("= Error analysis"))
    }

    func testFindSectionSearchesWholeProject() async throws {
        executor.embeddingProviderOverride = UnavailableEmbeddingProvider()
        try write("a.typ", "= Apples\nRed fruit.\n")
        try write("notes/b.md", "# Bananas\nYellow fruit, rich in potassium.\n")
        let out = try await run("find_section", ["query": "potassium bananas"])
        XCTAssertTrue(out.contains("notes/b.md:1-"), out)
        XCTAssertTrue(out.contains("in 2 files"), out)
    }

    func testCheckReferencesFollowsIncludesAndBibliography() async throws {
        try write("main.typ", """
        = Intro <intro>
        See @intro, @methods and @smith2020, but not @smiht2020.
        #include "chapters/methods.typ"
        #bibliography("refs.bib")
        """)
        try write("chapters/methods.typ", "= Methods <methods>\nDetails.")
        try write("refs.bib", "@article{smith2020, title={T}}\n@book{unused1, title={U}}\n")
        try write("stray.typ", "= Stray <stray>") // not included by main.typ

        let out = try await run("check_references", ["path": "main.typ"])
        XCTAssertTrue(out.contains("2 .typ files"), out)
        XCTAssertTrue(out.contains("Undefined references (1)"), out)
        XCTAssertTrue(out.contains("@smiht2020 at main.typ:2 — did you mean @smith2020?"), out)
        XCTAssertTrue(out.contains("unused1"), out)
        XCTAssertFalse(out.contains("stray"), out)

        let projectWide = try await run("check_references", [:])
        XCTAssertTrue(projectWide.contains("3 .typ files"), projectWide)
        XCTAssertTrue(projectWide.contains("<stray> at stray.typ:1"), projectWide)
    }

    func testCheckReferencesReportsMissingBibliography() async throws {
        try write("main.typ", "As @knuth said.\n#bibliography(\"missing.bib\")")
        let out = try await run("check_references", [:])
        XCTAssertTrue(out.contains("Missing bibliography files (1)"), out)
        XCTAssertTrue(out.contains("missing.bib (named at main.typ:2)"), out)
        XCTAssertTrue(out.contains("Some may be citations"), out)
    }

    // MARK: - Writing tools

    func testEditFileReportsLostFacts() async throws {
        try write("notes.md", "We tested 1,240 mugs and none of the samples passed the scratch test.\n")
        _ = try await run("read_file", ["path": "notes.md"])
        let out = try await run("edit_file", [
            "path": "notes.md",
            "old_string": "We tested 1,240 mugs and none of the samples passed the scratch test.",
            "new_string": "We tested many mugs and the samples passed the scratch test."
        ])
        XCTAssertTrue(out.contains("⚠️ Fact check"), out)
        XCTAssertTrue(out.contains("number 1,240"), out)
        XCTAssertTrue(out.contains("\"none\" gone"), out)
    }

    func testEditFileConfirmsKeptFactsAndSkipsCode() async throws {
        try write("notes.md", "The press runs at 200 degrees for 180 seconds.\n")
        _ = try await run("read_file", ["path": "notes.md"])
        let prose = try await run("edit_file", [
            "path": "notes.md",
            "old_string": "The press runs at 200 degrees for 180 seconds.",
            "new_string": "The press heats to 200 degrees and runs for 180 seconds."
        ])
        XCTAssertTrue(prose.contains("✓ Fact check"), prose)

        try write("code.typ", "#set page(margin: 2cm)\n")
        _ = try await run("read_file", ["path": "code.typ"])
        let code = try await run("edit_file", ["path": "code.typ", "old_string": "2cm", "new_string": "3cm"])
        XCTAssertFalse(code.contains("Fact check"), code)
    }

    func testCheckWritingToolBySection() async throws {
        try write("guide.md", "# Setup\nYou should simply leverage the robust installer.\n\n# Usage\nRun the tool.\n")
        let out = try await run("check_writing", ["path": "guide.md", "section": "Setup"])
        XCTAssertTrue(out.hasPrefix("[writing check of # Setup in 'guide.md'"), out)
        XCTAssertTrue(out.contains("Weak modal"), out)
        XCTAssertTrue(out.contains("Hype or filler word (3)"), out)
        XCTAssertFalse(out.contains("Run the tool"), out)
    }

    func testFindRepetitionToolFindsCopiedSection() async throws {
        executor.embeddingProviderOverride = UnavailableEmbeddingProvider()
        let paragraph = "Sublimation printing transfers dye from coated paper onto a polymer coated ceramic mug under heat and pressure."
        try write("a.typ", "= Intro\n\(paragraph)\n")
        try write("b.typ", "= Appendix\n\(paragraph)\n")
        let out = try await run("find_repetition", [:])
        XCTAssertTrue(out.contains("Copied passages (1)"), out)
        XCTAssertTrue(out.contains("a.typ:2-2 in = Intro ≈ b.typ:2-2 in = Appendix"), out)
        XCTAssertTrue(out.contains("Same-meaning check skipped: no embedding model reachable"), out)
    }

    func testFindRepetitionToolFindsSameMeaning() async throws {
        executor.embeddingProviderOverride = TopicEmbeddingProvider()
        try write("shop.typ", """
        = Care
        Put the mug in the dishwasher on a gentle wash and the print will not fade for years.

        Our coffee range comes in four sizes and two glazes for every kind of kitchen.

        = Notes
        A gentle dishwasher wash keeps the colours from fading over many cycles of use.
        """)
        let out = try await run("find_repetition", ["path": "shop.typ", "min_similarity": 0.9])
        XCTAssertTrue(out.contains("Same meaning, different words (1)"), out)
        XCTAssertTrue(out.contains("shop.typ:2-2 in = Care ~ shop.typ:7-7 in = Notes"), out)
    }

    private let mergeDoc = """
    = Report
    == Results <results>
    Supplier A averaged a colour error of 2.1. Supplier B averaged 3.8 and looked too warm.

    == Findings <findings>
    Supplier A averaged a colour error of 2.1 in the trial. Supplier B mugs faded after 30 dishwasher cycles.

    == Summary
    See @findings.

    """

    func testMergeSectionsPlanThenApply() async throws {
        try write("r.typ", mergeDoc)
        let plan = try await run("merge_sections", ["path": "r.typ", "keep": "Results", "remove": "Findings"])
        XCTAssertTrue(plan.contains("Dropped — already said with the same facts (1)"), plan)
        XCTAssertTrue(plan.contains("Added word for word (1)"), plan)
        XCTAssertTrue(plan.contains("will point to <results>"), plan)
        XCTAssertEqual(try read("r.typ"), mergeDoc, "the plan must not write")

        let out = try await run("merge_sections", ["path": "r.typ", "keep": "Results", "remove": "Findings", "apply": true])
        XCTAssertTrue(out.contains("extractive"), out)
        XCTAssertTrue(out.contains("Pointed 1 reference"), out)
        XCTAssertTrue(out.contains("✓ Fact check"), out)
        XCTAssertEqual(try read("r.typ"), """
        = Report
        == Results <results>
        Supplier A averaged a colour error of 2.1. Supplier B averaged 3.8 and looked too warm.

        Supplier B mugs faded after 30 dishwasher cycles.

        == Summary
        See @results.

        """)
    }

    func testMergeSectionsRefusesConflictsUntilResolved() async throws {
        let conflicting = mergeDoc.replacingOccurrences(of: "2.1 in the trial", with: "2.4 in the trial")
        try write("r.typ", conflicting)
        _ = try await run("merge_sections", ["path": "r.typ", "keep": "Results", "remove": "Findings"])
        await assertThrows({ error in
            if case .invalidArguments(let message) = error { return message.contains("disagree in 1 place") }
            return false
        }) {
            try await self.run("merge_sections", ["path": "r.typ", "keep": "Results", "remove": "Findings", "apply": true])
        }
        XCTAssertEqual(try read("r.typ"), conflicting)

        // The model resolves it with its own text; the fact check sees the
        // dropped 2.4 and says so.
        let out = try await run("merge_sections", [
            "path": "r.typ", "keep": "Results", "remove": "Findings",
            "merged_text": "Supplier A averaged a colour error of 2.1. Supplier B averaged 3.8, looked too warm, and faded after 30 dishwasher cycles."
        ])
        XCTAssertTrue(out.contains("⚠️ Fact check"), out)
        XCTAssertTrue(out.contains("number 2.4"), out)
        XCTAssertFalse(try read("r.typ").contains("== Findings"))
    }

    // MARK: - Read-before-edit invariant

    func testEditRequiresPriorRead() async throws {
        try write("doc.typ", "alpha\nbeta\n")
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "gamma"])
        }
        XCTAssertEqual(try read("doc.typ"), "alpha\nbeta\n")
    }

    func testOverwritingExistingFileRequiresPriorRead() async throws {
        try write("doc.typ", "alpha")
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("write_file", ["path": "doc.typ", "content": "beta"])
        }
    }

    func testCreatingNewFileNeedsNoPriorRead() async throws {
        let out = try await run("write_file", ["path": "nested/new.typ", "content": "hello"])
        XCTAssertTrue(out.contains("Wrote"))
        XCTAssertEqual(try read("nested/new.typ"), "hello")
    }

    // MARK: - Editing

    func testAmbiguousEditIsRejected() async throws {
        try write("doc.typ", "same\nmiddle\nsame\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        await assertThrows({ if case .editAmbiguous(_, let count) = $0 { return count == 2 }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "same", "new_string": "other"])
        }
        XCTAssertEqual(try read("doc.typ"), "same\nmiddle\nsame\n")
    }

    func testReplaceAllEditsEveryOccurrence() async throws {
        try write("doc.typ", "same\nmiddle\nsame\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        _ = try await run("edit_file", [
            "path": "doc.typ", "old_string": "same", "new_string": "other", "replace_all": true
        ])
        XCTAssertEqual(try read("doc.typ"), "other\nmiddle\nother\n")
    }

    func testUniqueEditAppliesAndIsApprovedWithSnippet() async throws {
        try write("doc.typ", "one\ntwo\nthree\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        var seen: PendingApprovalKind?
        let out = try await executor.execute(toolName: "edit_file", arguments: [
            "path": "doc.typ", "old_string": "two", "new_string": "TWO!"
        ]) { kind in
            seen = kind
            return true
        }

        XCTAssertEqual(try read("doc.typ"), "one\nTWO!\nthree\n")
        XCTAssertTrue(out.contains("1 place"))
        guard case .fileEdit(let path, let old, let new, let occurrences)? = seen else {
            return XCTFail("expected a .fileEdit approval, got \(String(describing: seen))")
        }
        XCTAssertEqual(path, "doc.typ")
        XCTAssertEqual(old, "two")
        XCTAssertEqual(new, "TWO!")
        XCTAssertEqual(occurrences, 1)
    }

    func testDeniedEditLeavesFileUntouched() async throws {
        try write("doc.typ", "one\ntwo\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        await assertThrows({ if case .approvalDenied = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "two", "new_string": "2"], approve: false)
        }
        XCTAssertEqual(try read("doc.typ"), "one\ntwo\n")
    }

    func testEditPreservesCRLFLineEndings() async throws {
        let url = workDir.appendingPathComponent("crlf.typ")
        try Data("one\r\ntwo\r\nthree\r\n".utf8).write(to: url)

        _ = try await run("read_file", ["path": "crlf.typ"])
        _ = try await run("edit_file", ["path": "crlf.typ", "old_string": "one\ntwo", "new_string": "one\n2"])

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "one\r\n2\r\nthree\r\n")
    }

    func testEditMissingTextNamesTheToolAndHints() async throws {
        try write("doc.typ", "alpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        await assertThrows({ if case .editNoMatch = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "nope", "new_string": "x"])
        }
    }

    func testEditMissingTextPointsAtTheClosestLines() async throws {
        try write("doc.typ", "# Intro\nThis is the opening paragraph.\n# Results\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        var thrown: LocalToolError?
        do {
            _ = try await run("edit_file", [
                "path": "doc.typ",
                "old_string": "This is the opening paragraf.",
                "new_string": "This is the opening paragraph!"
            ])
        } catch let error as LocalToolError {
            thrown = error
        }

        guard case .editNoMatch(_, _, let hints)? = thrown else {
            return XCTFail("expected .editNoMatch, got \(String(describing: thrown))")
        }
        XCTAssertTrue(
            hints.contains { $0.hasPrefix("2: ") && $0.contains("opening paragraph") },
            "expected a hint pointing at line 2, got \(hints)"
        )
        XCTAssertEqual(try read("doc.typ"), "# Intro\nThis is the opening paragraph.\n# Results\n")
    }

    func testEditAlreadyAppliedSaysSo() async throws {
        try write("doc.typ", "one\nnew text\nthree\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        var thrown: LocalToolError?
        do {
            _ = try await run("edit_file", [
                "path": "doc.typ", "old_string": "one\nold text", "new_string": "new text"
            ])
        } catch let error as LocalToolError {
            thrown = error
        }

        guard case .editNoMatch(_, _, let hints)? = thrown else {
            return XCTFail("expected .editNoMatch, got \(String(describing: thrown))")
        }
        XCTAssertTrue(
            hints.contains { $0.contains("already be in the file") },
            "expected an already-applied hint, got \(hints)"
        )
    }

    /// The case this tier exists for: the model typed a sentence it saw
    /// rendered — curly quotes and an em dash — where the source has ASCII.
    func testEditMatchesTypographicVariants() async throws {
        try write("doc.typ", "The editor said \"no\" - clearly.\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        let out = try await run("edit_file", [
            "path": "doc.typ",
            "old_string": "The editor said \u{201C}no\u{201D} \u{2014} clearly.",
            "new_string": "The editor said \"yes\" - clearly."
        ])
        XCTAssertTrue(out.contains("Matched on whole lines"), out)
        XCTAssertEqual(try read("doc.typ"), "The editor said \"yes\" - clearly.\n")
    }

    func testEditLooseMatchIgnoresTrailingWhitespace() async throws {
        try write("doc.typ", "alpha   \nbeta\t\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        _ = try await run("edit_file", ["path": "doc.typ", "old_string": "alpha\nbeta", "new_string": "alpha\nBETA"])
        XCTAssertEqual(try read("doc.typ"), "alpha   \nBETA\n")
    }

    /// A loose match splices with the *file's* endings, so a CRLF file stays
    /// CRLF even though the model wrote bare "\n".
    func testEditLooseMatchPreservesCRLF() async throws {
        let url = workDir.appendingPathComponent("crlf.typ")
        try Data("one \u{201C}quoted\u{201D}\r\ntwo\r\n".utf8).write(to: url)

        _ = try await run("read_file", ["path": "crlf.typ"])
        _ = try await run("edit_file", [
            "path": "crlf.typ", "old_string": "one \"quoted\"\ntwo", "new_string": "one \"quoted\"\nTWO"
        ])

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "one \u{201C}quoted\u{201D}\r\nTWO\r\n")
    }

    func testEditLooseMatchStillRejectsAmbiguity() async throws {
        try write("doc.typ", "same   \nmiddle\nsame   \n")
        _ = try await run("read_file", ["path": "doc.typ"])

        await assertThrows({ if case .editAmbiguous(_, let count) = $0 { return count == 2 }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "same", "new_string": "other"])
        }
        XCTAssertEqual(try read("doc.typ"), "same   \nmiddle\nsame   \n")
    }

    func testEditLooseMatchHonoursReplaceAll() async throws {
        // An em dash in the file where the model typed a hyphen forces the
        // loose tier, so replace_all is exercised there rather than exactly.
        try write("doc.typ", "same\u{2014}one   \nmiddle\nsame\u{2014}one   \n")
        _ = try await run("read_file", ["path": "doc.typ"])

        _ = try await run("edit_file", [
            "path": "doc.typ", "old_string": "same-one", "new_string": "other", "replace_all": true
        ])
        XCTAssertEqual(try read("doc.typ"), "other\nmiddle\nother\n")
    }

    /// The exact tier still wins when it can: replacing one word must not
    /// rewrite the rest of the line, including whitespace the model omitted.
    func testExactMatchLeavesSurroundingWhitespaceAlone() async throws {
        try write("doc.typ", "same   \nmiddle\nsame   \n")
        _ = try await run("read_file", ["path": "doc.typ"])

        let out = try await run("edit_file", [
            "path": "doc.typ", "old_string": "same", "new_string": "other", "replace_all": true
        ])
        XCTAssertFalse(out.contains("Matched on whole lines"), out)
        XCTAssertEqual(try read("doc.typ"), "other   \nmiddle\nother   \n")
    }

    func testFileChangedSinceReadIsDetected() async throws {
        let url = try write("doc.typ", "alpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        // Simulate the user saving an edit behind the chat's back.
        try "alpha changed\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        await assertThrows({ if case .fileChangedSinceRead = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "x"])
        }
    }

    func testNewMessageResetsReadTracking() async throws {
        try write("doc.typ", "alpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])

        executor.beginRequest()
        await assertThrows({ if case .fileNotReadYet = $0 { return true }; return false }) {
            try await self.run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "x"])
        }
    }

    // MARK: - Grep

    func testGrepIsCaseInsensitiveByDefault() async throws {
        try write("a.typ", "The Mug is White\nother\n")
        try write("sub/b.md", "another mug line\n")

        let out = try await run("grep_project", ["pattern": "mug"])
        XCTAssertTrue(out.contains("a.typ:1:"), out)
        XCTAssertTrue(out.contains("sub/b.md:1:"), out)
    }

    func testGrepCaseSensitiveOptInExcludesDifferentCase() async throws {
        try write("a.typ", "The Mug is White\nmug here\n")
        let out = try await run("grep_project", ["pattern": "mug", "case_sensitive": true])
        XCTAssertFalse(out.contains("The Mug"), out)
        XCTAssertTrue(out.contains("mug here"), out)
    }

    func testGrepLiteralTreatsRegexCharactersLiterally() async throws {
        try write("a.typ", "cost: $12.50 (net)\nplain line\n")
        let out = try await run("grep_project", ["pattern": "$12.50 (net)", "literal": true])
        XCTAssertTrue(out.contains("cost: $12.50 (net)"), out)
    }

    func testGrepGlobFiltersFiles() async throws {
        try write("a.typ", "target\n")
        try write("b.md", "target\n")
        let out = try await run("grep_project", ["pattern": "target", "glob": "*.typ"])
        XCTAssertTrue(out.contains("a.typ"), out)
        XCTAssertFalse(out.contains("b.md"), out)
    }

    func testGrepSkipsExcludedDirectories() async throws {
        try write("visible.typ", "needle\n")
        try write("backups/old.typ", "needle\n")
        let out = try await run("grep_project", ["pattern": "needle"])
        XCTAssertTrue(out.contains("visible.typ"), out)
        XCTAssertFalse(out.contains("backups"), out)
    }

    func testGrepInvalidRegexReportsIt() async throws {
        await assertThrows({ if case .invalidArguments = $0 { return true }; return false }) {
            try await self.run("grep_project", ["pattern": "("])
        }
    }

    // MARK: - Markdown → Typst conversion

    func testConvertMarkdownToTypstUsesTheSharedConverter() async throws {
        let out = try await run("convert_markdown_to_typst", ["markdown": "**bold** and *italic*"])
        XCTAssertEqual(out, AICompletionService.shared.sanitizeMarkdownToTypst("**bold** and *italic*"))
        XCTAssertTrue(out.contains("bold"))
    }

    func testConvertMarkdownToTypstRequiresNonEmptyInput() async throws {
        let out = try await run("convert_markdown_to_typst", ["markdown": ""])
        XCTAssertTrue(out.contains("markdown is required"), out)
    }

    // MARK: - Typst check

    private func requireTypst() throws -> String {
        guard let path = TypstUpdater.shared.resolveActiveTypstPath() else {
            throw XCTSkip("No typst binary available on this machine.")
        }
        return path
    }

    func testRunTypstCheckRequiresSourceOrPath() async throws {
        let out = try await run("run_typst_check", [:])
        XCTAssertTrue(out.contains("Provide either"), out)
    }

    func testRunTypstCheckOnGoodSourceCompiles() async throws {
        _ = try requireTypst()
        let out = try await run("run_typst_check", ["source": "= Hello\n\nWorld"])
        XCTAssertTrue(out.contains("Compiled successfully"), out)
    }

    func testRunTypstCheckOnBadSourceReportsTheCompilerError() async throws {
        _ = try requireTypst()
        let out = try await run("run_typst_check", ["source": "#undefinedFunctionCall()"])
        XCTAssertTrue(out.contains("Compile failed"), out)
    }

    func testRunTypstCheckWithPathCompilesTheRealFileInPlace() async throws {
        _ = try requireTypst()
        try write("doc.typ", "= Title\n\nBody text")
        let out = try await run("run_typst_check", ["path": "doc.typ"])
        XCTAssertTrue(out.contains("Compiled successfully"), out)
    }

    func testRunTypstCheckWithMissingPathReportsNotFound() async throws {
        _ = try requireTypst()
        let out = try await run("run_typst_check", ["path": "nope.typ"])
        XCTAssertTrue(out.contains("File not found"), out)
    }

    // MARK: - Export & delivery

    func testToolDescriptorsExposeDeliveryTools() {
        let names = Set(executor.toolDescriptors().map(\.name))
        for expected in ["export_document", "export_markdown", "create_folder", "copy_files"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected) in \(names.sorted())")
        }
    }

    func testCreateFolderCreatesNestedFolderWithApproval() async throws {
        var seen: PendingApprovalKind?
        let out = try await executor.execute(toolName: "create_folder", arguments: [
            "path": "deploy/evidence"
        ]) { kind in
            seen = kind
            return true
        }

        XCTAssertTrue(out.contains("Created folder"), out)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("deploy/evidence").path
        ))
        guard case .createFolder(let path)? = seen else {
            return XCTFail("expected a .createFolder approval, got \(String(describing: seen))")
        }
        XCTAssertEqual(path, "deploy/evidence")
    }

    func testDeniedCreateFolderLeavesNothingBehind() async throws {
        await assertThrows({ if case .approvalDenied = $0 { return true }; return false }) {
            try await self.run("create_folder", ["path": "deploy"], approve: false)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("deploy").path))
    }

    func testListFilesShowsEmptyFolders() async throws {
        _ = try await run("create_folder", ["path": "deploy/evidence"])
        let out = try await run("list_files", [:])
        XCTAssertTrue(out.contains("deploy/"), out)
        XCTAssertTrue(out.contains("deploy/evidence/"), out)
    }

    func testExportMarkdownWritesConvertedCopy() async throws {
        try write("Mugs.typ", "= Mugs\n\nSome **bold** text.\n")
        var seen: PendingApprovalKind?
        let out = try await executor.execute(toolName: "export_markdown", arguments: [
            "path": "Mugs.typ", "output": "deploy/Mugs.md"
        ]) { kind in
            seen = kind
            return true
        }

        let markdown = try read("deploy/Mugs.md")
        XCTAssertTrue(out.contains("Exported"), out)
        XCTAssertTrue(markdown.contains("# Mugs"), markdown)
        XCTAssertTrue(markdown.contains("**bold**"), markdown)
        XCTAssertFalse(markdown.contains("= Mugs"), markdown)
        guard case .fileWrite(let path, _, let newContent, let isNewFile)? = seen else {
            return XCTFail("expected a .fileWrite approval, got \(String(describing: seen))")
        }
        XCTAssertEqual(path, "deploy/Mugs.md")
        XCTAssertTrue(isNewFile)
        XCTAssertEqual(newContent, markdown)
    }

    func testExportMarkdownOfMarkdownSourceCopiesItThrough() async throws {
        try write("notes.md", "# Notes\n\nPlain **markdown**.\n")
        _ = try await run("export_markdown", ["path": "notes.md", "output": "deploy/notes.md"])
        XCTAssertEqual(try read("deploy/notes.md"), "# Notes\n\nPlain **markdown**.\n")
    }

    func testExportMarkdownOfMarkdownSourceToItselfIsANoOp() async throws {
        try write("notes.md", "# Notes\n")
        let out = try await run("export_markdown", ["path": "notes.md", "output": "notes.md"])
        XCTAssertTrue(out.contains("already Markdown"), out)
        XCTAssertEqual(try read("notes.md"), "# Notes\n")
    }

    func testCopyFilesGathersRelatedFilesAndCreatesFolder() async throws {
        try write("Mugs.typ", "= Mugs\n")
        try write("evidence/photo.txt", "image placeholder")
        try write("evidence/receipt.txt", "receipt")

        var seen: PendingApprovalKind?
        let out = try await executor.execute(toolName: "copy_files", arguments: [
            "sources": ["Mugs.typ", "evidence/photo.txt", "evidence/receipt.txt"],
            "destination": "deploy/evidence"
        ]) { kind in
            seen = kind
            return true
        }

        XCTAssertTrue(out.contains("Copied 3 items"), out)
        XCTAssertEqual(try read("deploy/evidence/Mugs.typ"), "= Mugs\n")
        XCTAssertEqual(try read("deploy/evidence/photo.txt"), "image placeholder")
        XCTAssertEqual(try read("deploy/evidence/receipt.txt"), "receipt")
        guard case .fileCopy(let sources, let destination, let overwrite)? = seen else {
            return XCTFail("expected a .fileCopy approval, got \(String(describing: seen))")
        }
        XCTAssertEqual(sources, ["Mugs.typ", "evidence/photo.txt", "evidence/receipt.txt"])
        XCTAssertEqual(destination, "deploy/evidence")
        XCTAssertFalse(overwrite)
    }

    func testCopyFilesRefusesExistingDestinationWithoutOverwrite() async throws {
        try write("new.txt", "new")
        try write("deploy/new.txt", "old")

        await assertThrows({ if case .invalidArguments = $0 { return true }; return false }) {
            try await self.run("copy_files", ["sources": ["new.txt"], "destination": "deploy"])
        }
        XCTAssertEqual(try read("deploy/new.txt"), "old")
    }

    func testCopyFilesOverwritesWhenAsked() async throws {
        try write("new.txt", "new")
        try write("deploy/new.txt", "old")

        _ = try await run("copy_files", [
            "sources": ["new.txt"], "destination": "deploy", "overwrite": true
        ])
        XCTAssertEqual(try read("deploy/new.txt"), "new")
    }

    func testCopyFilesRejectsEscapingTheScope() async throws {
        let outside = workDir.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        await assertThrows({ if case .pathEscapesScope = $0 { return true }; return false }) {
            try await self.run("copy_files", [
                "sources": ["../\(outside.lastPathComponent)"],
                "destination": "deploy"
            ])
        }
    }

    func testExportDocumentRejectsMismatchedOutputExtension() async throws {
        try write("Mugs.typ", "= Mugs\n")
        await assertThrows({ if case .invalidArguments = $0 { return true }; return false }) {
            try await self.run("export_document", [
                "path": "Mugs.typ", "format": "pdf", "output": "deploy/Mugs.md"
            ])
        }
    }

    func testExportDocumentCompilesPDFIntoDeliveryFolder() async throws {
        _ = try requireTypst()
        try write("Mugs.typ", "= Mugs\n\nFinal copy.\n")

        var seen: PendingApprovalKind?
        let out = try await executor.execute(toolName: "export_document", arguments: [
            "path": "Mugs.typ", "format": "pdf", "output": "deploy/Mugs"
        ]) { kind in
            seen = kind
            return true
        }

        let pdf = workDir.appendingPathComponent("deploy/Mugs.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path), out)
        XCTAssertTrue(out.contains("Exported"), out)
        guard case .documentExport(let path, let format, let destination, let existingFile)? = seen else {
            return XCTFail("expected a .documentExport approval, got \(String(describing: seen))")
        }
        XCTAssertEqual(path, "Mugs.typ")
        XCTAssertEqual(format, "pdf")
        XCTAssertEqual(destination, "deploy/Mugs.pdf")
        XCTAssertFalse(existingFile)
    }

    /// The full "make a deploy folder with the PDF, a Markdown copy and
    /// related evidence" job from the sample prompt — proving the agent can
    /// do it with built-in tools, no Python and no manual steps.
    func testDeployPackageWorkflowBuildsPDFMarkdownAndEvidence() async throws {
        _ = try requireTypst()
        try write("Mugs.typ", "= Mugs\n\nFinal approved copy.\n")
        try write("evidence/order-confirmation.txt", "Order 1234")
        try write("evidence/shipping-label.txt", "Label data")

        _ = try await run("create_folder", ["path": "deploy"])
        _ = try await run("export_document", [
            "path": "Mugs.typ", "format": "pdf", "output": "deploy/Mugs.pdf"
        ])
        _ = try await run("export_markdown", [
            "path": "Mugs.typ", "output": "deploy/Mugs.md"
        ])
        _ = try await run("copy_files", [
            "sources": ["evidence/order-confirmation.txt", "evidence/shipping-label.txt"],
            "destination": "deploy/evidence"
        ])

        let listing = try await run("list_files", [:])
        for expected in ["deploy/", "deploy/Mugs.pdf", "deploy/Mugs.md", "deploy/evidence/"] {
            XCTAssertTrue(listing.contains(expected), "missing \(expected) in:\n\(listing)")
        }
        XCTAssertTrue(listing.contains("deploy/evidence/order-confirmation.txt"), listing)
        XCTAssertTrue(listing.contains("deploy/evidence/shipping-label.txt"), listing)
        XCTAssertTrue(try read("deploy/Mugs.md").contains("# Mugs"))
    }

    // MARK: - Automatic post-edit validation

    func testEditFileAppendsPassingValidationNote() async throws {
        _ = try requireTypst()
        try write("doc.typ", "= Title\n\nalpha\n")
        _ = try await run("read_file", ["path": "doc.typ"])
        let out = try await run("edit_file", ["path": "doc.typ", "old_string": "alpha", "new_string": "beta"])
        XCTAssertTrue(out.contains("Typst check: compiles cleanly"), out)
    }

    func testWriteFileAppendsFailingValidationNoteWithoutThrowing() async throws {
        _ = try requireTypst()
        let out = try await run("write_file", ["path": "broken.typ", "content": "#undefinedFunctionCall()"])
        XCTAssertTrue(out.contains("Wrote"), out)
        XCTAssertTrue(out.contains("⚠️ Typst check"), out)
        XCTAssertTrue(out.contains("Compile failed"), out)
        // Advisory only — the file is still written even though it doesn't compile.
        XCTAssertEqual(try read("broken.typ"), "#undefinedFunctionCall()")
    }

    func testValidationNoteIsSkippedWhenDisabled() async throws {
        _ = try requireTypst()
        executor.autoValidateTypstEdits = false
        let out = try await run("write_file", ["path": "untouched.typ", "content": "#undefinedFunctionCall()"])
        XCTAssertFalse(out.contains("Typst check"), out)
    }

    func testValidationNoteIsSkippedForNonTypFiles() async throws {
        _ = try requireTypst()
        let out = try await run("write_file", ["path": "notes.md", "content": "# Just markdown"])
        XCTAssertFalse(out.contains("Typst check"), out)
    }

    // MARK: - Open-editor change notification
    //
    // `write_file`/`edit_file` post `.aiChatModifiedFile` so any window with
    // the touched file open can reload it or warn before clobbering unsaved
    // edits (see `ContentView`'s handler) — these confirm the notification
    // actually fires, with the right URL, only on a real disk write.

    func testWriteFileOfNewContentPostsAiChatModifiedFile() async throws {
        try write("notice.typ", "old")
        _ = try await run("read_file", ["path": "notice.typ"])
        let expectedURL = workDir.appendingPathComponent("notice.typ")

        let observed = Captured<URL?>(nil)
        let expectation = XCTNSNotificationExpectation(name: .aiChatModifiedFile, object: nil, notificationCenter: .default)
        expectation.handler = { notification in
            observed.value = notification.object as? URL
            return true
        }
        _ = try await run("write_file", ["path": "notice.typ", "content": "new"])
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(observed.value?.standardizedFileURL.path, expectedURL.standardizedFileURL.path)
    }

    func testWriteFileNoOpDoesNotPostAiChatModifiedFile() async throws {
        try write("same.typ", "unchanged")
        _ = try await run("read_file", ["path": "same.typ"])

        let expectation = XCTNSNotificationExpectation(name: .aiChatModifiedFile, object: nil, notificationCenter: .default)
        expectation.isInverted = true
        _ = try await run("write_file", ["path": "same.typ", "content": "unchanged"])
        await fulfillment(of: [expectation], timeout: 0.3)
    }

    func testEditFilePostsAiChatModifiedFileWithTheRightURL() async throws {
        try write("edit-notice.typ", "alpha\nbeta\n")
        _ = try await run("read_file", ["path": "edit-notice.typ"])
        let expectedURL = workDir.appendingPathComponent("edit-notice.typ")

        let observed = Captured<URL?>(nil)
        let expectation = XCTNSNotificationExpectation(name: .aiChatModifiedFile, object: nil, notificationCenter: .default)
        expectation.handler = { notification in
            observed.value = notification.object as? URL
            return true
        }
        _ = try await run("edit_file", ["path": "edit-notice.typ", "old_string": "alpha", "new_string": "gamma"])
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(observed.value?.standardizedFileURL.path, expectedURL.standardizedFileURL.path)
    }

    func testDeniedWriteDoesNotPostAiChatModifiedFile() async throws {
        let expectation = XCTNSNotificationExpectation(name: .aiChatModifiedFile, object: nil, notificationCenter: .default)
        expectation.isInverted = true
        _ = try? await run("write_file", ["path": "denied.typ", "content": "x"], approve: false)
        await fulfillment(of: [expectation], timeout: 0.3)
    }

    // MARK: - Prompt shaping / plan round-trip

    func testBuildPromptExcludesCompactedAndToolCalls() {
        // The new engine folds the transcript inside the agent (it owns the
        // session), so the pure shaping rule is exercised through a real
        // manager's prompt instead of a static helper.
        let chat = AIChatManager()
        chat.replaceTranscript([
            ChatMessage(role: .user, text: "old question", isCompacted: true),
            ChatMessage(role: .assistant, text: "old answer", isCompacted: true),
            ChatMessage(role: .assistant, text: "[Summary of earlier conversation]\n\nThey wanted X.", isSummary: true),
            ChatMessage(role: .user, text: "new question"),
            ChatMessage(role: .toolCall, toolName: "project__read_file", toolStatus: .succeeded, toolOutput: "file body"),
            ChatMessage(role: .assistant, text: "new answer"),
            ChatMessage(role: .user, text: "follow up"),
        ])
        let prompt = chat.buildPrompt()

        XCTAssertFalse(prompt.contains("old question"))
        XCTAssertFalse(prompt.contains("old answer"))
        XCTAssertTrue(prompt.contains("They wanted X."), "the summary stands in for the folded turns")
        XCTAssertTrue(prompt.contains("[USER] new question"))
        XCTAssertTrue(prompt.contains("new answer"))
        XCTAssertTrue(prompt.hasSuffix("[USER] follow up"), "the newest user turn closes the prompt")
    }

    func testBuildPromptKeepsTheSummaryRow() {
        let chat = AIChatManager()
        chat.replaceTranscript([
            ChatMessage(role: .assistant, text: "[Summary of earlier conversation]\n\nThey wanted X.", isSummary: true),
            ChatMessage(role: .user, text: "follow up"),
        ])
        let prompt = chat.buildPrompt()
        XCTAssertTrue(prompt.contains("They wanted X."), "the summary is the only record of the summarized turns")
        XCTAssertTrue(prompt.hasSuffix("[USER] follow up"))
    }

    func testPlanIsRebuiltFromTranscript() {
        let args = #"{"items":[{"content":"Read the file","status":"completed"},{"content":"Rewrite section 2","status":"in_progress"}]}"#
        let messages = [
            ChatMessage(role: .user, text: "do it"),
            ChatMessage(role: .toolCall, toolName: "agent__update_plan", toolArgumentsJSON: args, toolStatus: .succeeded)
        ]
        let plan = AgentHarnessTools.plan(from: messages)
        XCTAssertEqual(plan.map(\.content), ["Read the file", "Rewrite section 2"])
        XCTAssertEqual(plan.map(\.status), [.completed, .inProgress])
    }

    // MARK: - Python sandbox

    func testSandboxedPythonCanWriteScratchButNotTheProject() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("python3 or sandbox-exec unavailable")
        }
        executor.pythonToolEnabled = true
        executor.pythonSandboxEnabled = true

        let projectPath = workDir.path
        let code = """
        import os
        open(os.path.join(os.environ["TMPDIR"], "ok.txt"), "w").write("ok")
        print("SCRATCH_OK")
        try:
            open("\(projectPath)/bad.txt", "w").write("bad")
            print("PROJECT_WRITE_ALLOWED")
        except Exception:
            print("PROJECT_WRITE_DENIED")
        """
        let out = try await run("run", ["code": code])
        XCTAssertTrue(out.contains("SCRATCH_OK"), out)
        XCTAssertTrue(out.contains("PROJECT_WRITE_DENIED"), out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("bad.txt").path))
    }

    /// Stop must abort a running script, not leave it to burn CPU until the
    /// 20-second timeout while the chat looks stuck.
    func testCancellingPythonTerminatesTheScript() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("python3 unavailable")
        }
        executor.pythonToolEnabled = true
        executor.pythonSandboxEnabled = false

        let marker = workDir.appendingPathComponent("finished.txt")
        let code = """
        import time
        time.sleep(30)
        open(r"\(marker.path)", "w").write("done")
        """

        let started = Date()
        let task = Task {
            try await self.executor.execute(toolName: "run", arguments: ["code": code]) { _ in true }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected the cancelled run to throw CancellationError")
        } catch is CancellationError {
            // Expected: the tool reports a stopped task, not success/timeout.
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "Stop should terminate Python at once, not wait for its timeout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the script must not get to finish its work after Stop")
    }

    // MARK: - Sudo / elevated runs

    func testElevationDetectorCatchesSudoAndOsascriptButNotOrdinaryCode() {
        XCTAssertTrue(LocalToolExecutor.codeWantsElevation("subprocess.run(['sudo', 'id'])"))
        XCTAssertTrue(LocalToolExecutor.codeWantsElevation("os.system('sudo -A rm /tmp/x')"))
        XCTAssertTrue(LocalToolExecutor.codeWantsElevation("os.system('/usr/bin/sudo apt install frotz')"))
        XCTAssertTrue(LocalToolExecutor.codeWantsElevation("subprocess.run(['osascript', '-e', 'do shell script \"id\" with administrator privileges'])"))
        XCTAssertTrue(LocalToolExecutor.codeWantsElevation("os.system('SUDO_ASKPASS=/x sudo whoami')"))
        // "pseudo" contains no word-boundary `sudo` (s-e-u-d-o), so a plain
        // script mentioning it must not trip the gate.
        XCTAssertFalse(LocalToolExecutor.codeWantsElevation("print('pseudo filesystem')"))
        XCTAssertFalse(LocalToolExecutor.codeWantsElevation("import subprocess\nprint(subprocess.run(['id']))"))
    }

    /// With the sudo opt-in off, an elevated script is refused *before*
    /// approval — the user never sees an approval card to mis-click.
    func testElevatedScriptIsRefusedWhileSudoIsOff() async {
        executor.pythonToolEnabled = true
        executor.pythonSudoEnabled = false
        executor.pythonSandboxEnabled = false

        var askedForApproval = false
        do {
            _ = try await executor.execute(toolName: "run", arguments: ["code": "os.system('sudo id')"]) { _ in
                askedForApproval = true
                return true
            }
            XCTFail("expected a refusal, not a run")
        } catch let error as LocalToolError {
            if case .elevationDisabled = error {} else {
                XCTFail("expected elevationDisabled, got: \(error)")
            }
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("sudo"), message)
            XCTAssertTrue(message.contains("Settings"), message)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertFalse(askedForApproval, "the gate fires before the approval card")
    }

    /// Sudo opted in but the sandbox on: sandbox-exec cannot run setuid
    /// binaries, so the run is refused with an explanation rather than a
    /// confusing Seatbelt error.
    func testElevatedScriptIsRefusedWhileSandboxed() async {
        executor.pythonToolEnabled = true
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = true

        do {
            _ = try await executor.execute(toolName: "run", arguments: ["code": "os.system('sudo id')"]) { _ in true }
            XCTFail("expected a refusal, not a run")
        } catch let error as LocalToolError {
            if case .elevationBlockedBySandbox = error {} else {
                XCTFail("expected elevationBlockedBySandbox, got: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// The elevated approval never auto-approves — YOLO mode included —
    /// while an ordinary script keeps today's behavior.
    func testElevatedApprovalIsNeverAutoApproved() {
        let elevated = PendingApprovalKind.runPython(code: "os.system('sudo id')", wantsElevation: true)
        let ordinary = PendingApprovalKind.runPython(code: "print('hello')", wantsElevation: false)
        XCTAssertFalse(elevated.canAutoApprove(yoloMode: true), "sudo must always meet a human")
        XCTAssertFalse(elevated.canAutoApprove(yoloMode: false))
        XCTAssertTrue(ordinary.canAutoApprove(yoloMode: true))
        XCTAssertFalse(ordinary.canAutoApprove(yoloMode: false))
    }

    /// The helper must be private (0700, only this user) and executable, and
    /// must actually be an askpass script — and nothing may linger afterwards.
    func testAskpassHelperIsPrivateAndExecutable() throws {
        let dir = try LocalToolExecutor.writeAskpassHelper()
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("askpass")
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700, "the helper must be owner-only")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))

        let contents = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(contents.contains("osascript"), contents)
        XCTAssertTrue(contents.contains("with hidden answer"), contents)
        XCTAssertTrue(contents.contains("default button \"Cancel\""), "Cancel must be the default so a stray Return dismisses the dialog")

        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual(dirAttributes[.posixPermissions] as? Int, 0o700)
    }

    /// The full plumbing, without touching sudo: a script the detector flags
    /// (a dormant `if False:` branch mentioning sudo) gets SUDO_ASKPASS
    /// pointing at a fresh helper, which is what lets an approved `sudo -A`
    /// find the dialog. The branch never runs, so no dialog can appear — and
    /// an unflagged script gets no helper at all, which is the second layer of
    /// the gate: even detector-evading `sudo -A` has nothing to ask with.
    func testElevatedOptInHandsAskpassHelperToTheScript() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("python3 unavailable")
        }
        executor.pythonToolEnabled = true
        executor.pythonSudoEnabled = true
        executor.pythonSandboxEnabled = false

        let flagged = """
        import os
        if False:
            os.system("sudo id")
        print(os.environ.get("SUDO_ASKPASS", "NONE"))
        """
        let flaggedOut = try await run("run", ["code": flagged])
        XCTAssertTrue(flaggedOut.contains("typstedit-askpass-"), flaggedOut)
        XCTAssertFalse(flaggedOut.contains("NONE"), flaggedOut)

        let plainOut = try await run("run", ["code": #"import os; print(os.environ.get("SUDO_ASKPASS", "NONE"))"#])
        XCTAssertTrue(plainOut.contains("NONE"), "an ordinary script must not receive the askpass helper: \(plainOut)")
    }
}
