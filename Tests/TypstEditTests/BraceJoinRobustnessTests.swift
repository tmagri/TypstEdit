import XCTest
@testable import TypstEdit

/// Hardening for the `.note` brace-on-next-line join (`autoFixBrokenNoteSyntax`
/// step 1b) and the `pendingFallbackRewrite` change in the live preview.
///
/// The join rewrites user text before every `.note` compile — preview, export
/// and `compileClean` — so it must be conservative: it may only touch real
/// construct openers, it must never change the line count (diagnostics and
/// operator warnings are reported by line), and it must never move a brace
/// into a comment.
final class BraceJoinRobustnessTests: XCTestCase {

    private func fix(_ source: String) -> String {
        TypstCompiler.autoFixBrokenNoteSyntax(source)
    }

    private func lineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }

    /// Sources that exercise every join shape plus the near misses.
    private static let corpus: [String] = [
        "#show heading.where(level: 1): it =>\n{\n  pagebreak(weak: true)\n  it\n}\n\n= Chapter\n",
        "#let make = (n) =>\n{\n  n * 2\n}\n",
        "#let f = (x) =>\n{ x * 2 }\nAfter.\n",
        "#let total =\n{\n  1 + 2\n}\n",
        "#let f = (x) =>\n{ (y) =>\n{\n  x + y\n}\n}\n",
        "#let f(x) = {\n  let y =\n  {\n    x\n  }\n  y\n}\n",
        "#show: it =>\r\n{\r\n  it\r\n}\r\n",
        "\t#show: it =>\n\t{\n\t\tit\n\t}\n",
        "// usage: it =>\n{\n  not joined\n}\n",
        "#let x = 1 // note =>\n{a}\n",
        "#let f = (x) =>\n\n{\n  x\n}\n",
        "```typst\n#let f = (x) =>\n{\n  x\n}\n```\n",
        "Title\n===\n{not code}\n",
        "#let ok = (a <=\n{b})\n#let ok2 = (a !=\n{b})\n#let ok3 = (a ==\n{b})\n",
        "#let x =",
        "{",
        "#let x =\n{",
        "",
        "Plain prose with no code at all.\n\nSecond paragraph.\n",
    ]

    // MARK: - Invariants

    /// Line numbers are how compile errors, operator warnings and the line map
    /// find their way back to the user — the join must never add or drop one.
    func testJoinNeverChangesLineCount() {
        for source in Self.corpus {
            // Step 1 may append a closing fence for an unclosed one; nothing
            // else may change the count.
            let unclosedFence = source.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count % 2 == 1
            let expected = lineCount(source) + (unclosedFence ? 1 : 0)
            XCTAssertEqual(lineCount(fix(source)), expected, "line count changed for: \(source.debugDescription)")
        }
    }

    func testJoinIsIdempotent() {
        for source in Self.corpus {
            let once = fix(source)
            XCTAssertEqual(fix(once), once, "second pass changed: \(source.debugDescription)")
        }
    }

    /// Joining only moves a `{` and whitespace: every other character survives
    /// in order.
    func testJoinPreservesNonWhitespaceContent() {
        func significant(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        for source in Self.corpus where !source.contains("```") {
            XCTAssertEqual(significant(fix(source)), significant(source), "content changed for: \(source.debugDescription)")
        }
    }

    // MARK: - Shapes

    func testBraceOnlyLineBecomesEmpty() {
        XCTAssertEqual(fix("#show: it =>\n{\n  it\n}\n"), "#show: it => {\n\n  it\n}\n")
    }

    func testChainedOpenersJoinAllTheWayDown() {
        let output = fix("#let f = (x) =>\n{ (y) =>\n{\n  x + y\n}\n}\n")
        XCTAssertEqual(output, "#let f = (x) => {\n(y) => {\n\n  x + y\n}\n}\n")
        XCTAssertFalse(output.contains("=>\n"), "no arrow may be left dangling: \(output)")
    }

    func testOpenerIndentationIsPreserved() {
        let output = fix("#let f(x) = {\n  let y =\n  {\n    x\n  }\n  y\n}\n")
        XCTAssertEqual(output, "#let f(x) = {\n  let y = {\n\n    x\n  }\n  y\n}\n")
    }

    func testTabIndentationIsPreserved() {
        XCTAssertEqual(fix("\t#show: it =>\n\t{ it }\n"), "\t#show: it => {\n\tit }\n")
    }

    func testCRLFSourceJoinsAndKeepsLineEndings() {
        let output = fix("#show: it =>\r\n{\r\n  it\r\n}\r\n")
        XCTAssertEqual(output, "#show: it => {\r\n\r\n  it\r\n}\r\n")
    }

    // MARK: - Must not join

    /// Joining onto a commented line would comment the brace out and leave
    /// the body unbalanced.
    func testLineCommentOpenerNeverJoins() {
        for source in [
            "// usage: it =>\n{\n  x\n}\n",
            "#let x = 1 // note =>\n{a}\n",
            "  // let y =\n  {\n",
        ] {
            XCTAssertEqual(fix(source), source, "commented opener joined: \(source.debugDescription)")
        }
    }

    func testURLAndStringSlashesAreNotComments() {
        XCTAssertFalse(TypstCompiler.hasLineComment("#link(\"https://x.com\")[a] ="))
        XCTAssertFalse(TypstCompiler.hasLineComment("#let s = \"a // b\" ="))
        XCTAssertFalse(TypstCompiler.hasLineComment("#let s = \"esc \\\" // still string\" ="))
        XCTAssertTrue(TypstCompiler.hasLineComment("#let x = 1 // c"))
        XCTAssertTrue(TypstCompiler.hasLineComment("// c"))
        XCTAssertTrue(TypstCompiler.isBlockOpenerLine("#let u = \"https://x\" ="))
    }

    func testBlankLineBetweenOpenerAndBraceIsLeftAlone() {
        let source = "#let f = (x) =>\n\n{\n  x\n}\n"
        XCTAssertEqual(fix(source), source)
    }

    func testCompoundAndComparisonOperatorsNeverJoin() {
        for op in ["<=", ">=", "!=", "==", "+=", "-=", "*=", "/="] {
            let source = "#let ok = (a \(op)\n{b})\n"
            XCTAssertEqual(fix(source), source, "joined after \(op)")
            XCTAssertFalse(TypstCompiler.isBlockOpenerLine("#let ok = (a \(op)"), op)
        }
    }

    func testArrowWithoutValueHeadNeverJoins() {
        XCTAssertFalse(TypstCompiler.isBlockOpenerLine("=>"))
        XCTAssertFalse(TypstCompiler.isBlockOpenerLine("  => "))
        XCTAssertFalse(TypstCompiler.isBlockOpenerLine("="))
        XCTAssertFalse(TypstCompiler.isBlockOpenerLine(""))
    }

    func testIndentedAndTaggedFencesAreRespected() {
        let source = "  ```js\n  const f = (x) =>\n  {\n  }\n  ```\nAfter\n"
        XCTAssertEqual(fix(source), source)
    }

    func testEdgeOfDocumentDoesNotCrash() {
        XCTAssertEqual(fix("#let x ="), "#let x =")
        XCTAssertEqual(fix("{"), "{")
        XCTAssertEqual(fix("#let x =\n{"), "#let x = {\n")
    }

    // MARK: - Region scanner parity

    /// The fallback fixer and the highlighter use the region spans; they must
    /// agree with the join about which lines belong to a construct.
    func testRegionSpansDoNotExtendPastCommentedOpener() {
        let spans = AICompletionService.typstRegionLineSpans(in: "#let x = 1 // =>\n{\n  a\n}\n")
        XCTAssertEqual(spans.count, 1, "\(spans)")
        XCTAssertEqual(spans.first?.end, 0, "a commented arrow must not pull the `{` line in: \(spans)")
    }

    func testRegionSpansFollowAChainedOpener() {
        let spans = AICompletionService.typstRegionLineSpans(in: "#let f = (x) =>\n{ (y) =>\n{\n  x + y\n}\n}\n\nProse.\n")
        XCTAssertEqual(spans.count, 1, "\(spans)")
        XCTAssertEqual(spans.first?.start, 0)
        XCTAssertEqual(spans.first?.end, 5, "the region must end at the outer `}`: \(spans)")
    }

    // MARK: - Real compiles

    /// Every join shape must produce a document Typst accepts.
    @MainActor
    func testEveryJoinShapeCompiles() async throws {
        let compiler = TypstCompiler()
        defer { compiler.cleanUp() }
        let notes: [String: String] = [
            "show rule": "#show heading.where(level: 1): it =>\n{\n  pagebreak(weak: true)\n  it\n}\n\n= Chapter\nProse.\n",
            "closure": "#let make = (n) =>\n{\n  n * 2\n}\n\n#make(3)\n",
            "brace-line content": "#let f = (x) =>\n{ x * 2 }\n\nValue: #f(4)\n",
            "assignment block": "#let total =\n{\n  1 + 2\n}\n\nTotal: #total\n",
            "chain": "#let add = (x) =>\n{ (y) =>\n{\n  x + y\n}\n}\n\nSum: #add(1)(2)\n",
            "nested let": "#let f(x) = {\n  let y =\n  {\n    x * 2\n  }\n  y\n}\n\nNested: #f(5)\n",
            "crlf": "#show strong: it =>\r\n{\r\n  text(red, it)\r\n}\r\n\r\nSome *bold* text.\r\n",
            "tabs": "\t#show emph: it =>\n\t{\n\t\tunderline(it)\n\t}\n\nSome _emph_ text.\n",
            "commented opener": "// usage: it =>\n{\n  plain text\n}\n\nAfter.\n",
            "markdown around": "# Heading\n\n- item one\n- item two\n\n#let f = (x) =>\n{\n  x + 1\n}\n\n**Bold** and $x^2$ math: #f(1)\n",
            "fenced": "```typst\n#let f = (x) =>\n{\n  x\n}\n```\n\nDone.\n",
        ]
        for (name, note) in notes.sorted(by: { $0.key < $1.key }) {
            let result = await compiler.compileClean(content: note, fileExtension: "note", originalFileURL: nil, projectRoot: nil)
            if result.error?.contains("executable not found") == true { throw XCTSkip("typst binary not available") }
            XCTAssertTrue(result.success, "[\(name)] must compile: \(result.error ?? "")")
        }
    }

    // MARK: - Live preview line mapping

    @MainActor
    private func preview(_ source: String, until done: @escaping (TypstCompiler) -> Bool) async throws -> TypstCompiler {
        let compiler = TypstCompiler()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brace-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            await MainActor.run { compiler.cleanUp() }
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("doc.note")
        try source.write(to: file, atomically: true, encoding: .utf8)
        await compiler.updateContent(source: source, fileURL: file)
        let deadline = Date().addingTimeInterval(20)
        while !done(compiler), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return compiler
    }

    /// A real error after a joined construct must land on the line the user
    /// wrote, and — since live Typst regions are protected from the fallback
    /// fixer, so no rewrite happens — it must be published at all.
    @MainActor
    func testErrorAfterJoinedConstructMapsToUserLine() async throws {
        let source = [
            "#show heading.where(level: 1): it =>",  // 1
            "{",                                      // 2
            "  it",                                   // 3
            "}",                                      // 4
            "",                                       // 5
            "= Chapter",                              // 6
            "",                                       // 7
            "#let broken = undefined-thing-here",     // 8
            "",                                       // 9
            "Prose.",                                 // 10
        ].joined(separator: "\n")
        let compiler = try await preview(source) { c in
            c.errors.contains { $0.severity == .error }
        }
        let errors = compiler.errors.filter { $0.severity == .error }
        XCTAssertFalse(errors.isEmpty, "the unknown variable must be reported")
        XCTAssertTrue(
            errors.contains { $0.message.contains("unknown variable") && $0.line == 8 },
            "the error must map to user line 8, got: \(errors.map { "\($0.message) @ \($0.line.map(String.init) ?? "?")" })"
        )
    }

    /// Operator-delimiting warnings are computed on the joined text; they must
    /// still name the user's line.
    @MainActor
    func testOperatorWarningAfterJoinedConstructKeepsUserLine() async throws {
        let source = [
            "#let make = (n) =>",   // 1
            "{",                    // 2
            "  n * 2",              // 3
            "}",                    // 4
            "",                     // 5
            "line two # bad",       // 6
        ].joined(separator: "\n")
        let compiler = try await preview(source) { c in
            c.errors.contains { $0.severity == .warning && $0.line != nil }
        }
        let warningLines = compiler.errors.filter { $0.severity == .warning }.compactMap(\.line)
        XCTAssertTrue(warningLines.contains(6), "the delimiting warning must name line 6, got: \(warningLines)")
        XCTAssertFalse(warningLines.contains(5), "an off-by-one line means the join dropped a line: \(warningLines)")
    }

    /// The happy path: a joined construct compiles in the live preview with no
    /// errors left on the Issues panel.
    @MainActor
    func testJoinedConstructPreviewsWithoutErrors() async throws {
        let source = "#show heading.where(level: 1): it =>\n{\n  pagebreak(weak: true)\n  it\n}\n\n= Chapter\nProse.\n"
        let compiler = try await preview(source) { c in
            c.compilationStatus == "Watching..." && !c.isCompiling
        }
        // Give a pending fallback/watch cycle a moment to publish anything.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(compiler.compilationStatus, "Watching...", "the preview must compile")
        XCTAssertTrue(
            compiler.errors.filter { $0.severity == .error }.isEmpty,
            "got: \(compiler.errors.map(\.message))"
        )
    }
}
