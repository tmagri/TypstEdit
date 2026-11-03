import XCTest
@testable import TypstEdit

/// Fixtures are verbatim `typst` 0.12 CLI output.
final class TypstDiagnosticParserTests: XCTestCase {

    // `C# source` — the `#` starts code, so Typst expects an expression.
    private let hashError = """
    error: expected expression
       ┌─ temp/Mugs.typ.preview.typ:55:20
       │
    55 │ === Result of the C# validation
       │                     ^


    """

    private let hintError = """
    error: unknown variable: a-b
      ┌─ temp/h.typ:2:1
      │
    2 │ #a-b
      │  ^^^
      │
      = hint: if you meant to use subtraction, try adding spaces around the minus sign: `a - b`

    """

    private let importedFileError = """
    error: cannot add integer and string
      ┌─ lib.typ:2:2
      │
    2 │   x + "a"
      │   ^^^^^^^

    help: error occurred in this call of function `boom`
      ┌─ temp/main.typ:3:1
      │
    3 │ #boom(1)
      │  ^^^^^^^

    """

    func testParsesLocationSnippetAndCaret() {
        let diagnostics = TypstDiagnosticParser.parse(hashError)
        XCTAssertEqual(diagnostics.count, 1)
        let d = diagnostics[0]
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.message, "expected expression")
        XCTAssertEqual(d.location, .init(path: "temp/Mugs.typ.preview.typ", line: 55, column: 20))
        XCTAssertEqual(d.snippet, "=== Result of the C# validation")
        XCTAssertEqual(d.caretColumn, 20)
        XCTAssertEqual(d.caretLength, 1)
    }

    func testParsesHints() {
        let d = TypstDiagnosticParser.parse(hintError)[0]
        XCTAssertEqual(d.snippet, "#a-b")
        XCTAssertEqual(d.caretColumn, 1)
        XCTAssertEqual(d.caretLength, 3)
        XCTAssertEqual(d.hints, ["if you meant to use subtraction, try adding spaces around the minus sign: `a - b`"])
    }

    func testHelpBlockAttachesAsTraceFrame() {
        let diagnostics = TypstDiagnosticParser.parse(importedFileError)
        XCTAssertEqual(diagnostics.count, 1, "help: must not start a new diagnostic")
        let d = diagnostics[0]
        XCTAssertEqual(d.location?.path, "lib.typ")
        XCTAssertEqual(d.snippet, "  x + \"a\"", "the trace frame's code must not replace the primary snippet")
        XCTAssertEqual(d.trace.count, 1)
        XCTAssertEqual(d.trace[0].message, "error occurred in this call of function `boom`")
        XCTAssertEqual(d.trace[0].location, .init(path: "temp/main.typ", line: 3, column: 1))
    }

    func testDiagnosticWithoutLocationIsKept() {
        let diagnostics = TypstDiagnosticParser.parse("error: source file must be contained in project root\n")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertNil(diagnostics[0].location)
        XCTAssertEqual(diagnostics[0].message, "source file must be contained in project root")
    }

    func testWarningAndErrorInOneBatch() {
        let output = """
        warning: unknown font family: nosuchfont
          ┌─ temp/w.typ:1:16
          │
        1 │ #set text(font: "NoSuchFont")
          │                 ^^^^^^^^^^^^

        """ + hintError
        let diagnostics = TypstDiagnosticParser.parse(output)
        XCTAssertEqual(diagnostics.map(\.severity), [.warning, .error])
        XCTAssertEqual(diagnostics[0].caretColumn, 16)
        XCTAssertEqual(diagnostics[0].caretLength, 12)
    }

    /// The live preview feeds lines one at a time; a block must be reported as
    /// ended on its blank line (the old code waited for the *next* compile).
    func testIncrementalEventsReportBlockEnd() {
        var parser = TypstDiagnosticParser()
        var events: [TypstDiagnosticParser.Event] = []
        for line in hashError.components(separatedBy: "\n") {
            events.append(parser.consume(line))
        }
        XCTAssertTrue(events.contains(.located(index: 0)))
        XCTAssertEqual(events.filter { $0 == .blockEnded }.count, 1, "extra blank lines must not end empty blocks")
        XCTAssertFalse(parser.isInsideBlock)
    }

    func testBlankLinesOutsideBlocksAreIgnored() {
        var parser = TypstDiagnosticParser()
        XCTAssertEqual(parser.consume(""), .none)
        XCTAssertEqual(parser.consume("watching temp/x.typ"), .none)
        XCTAssertTrue(parser.diagnostics.isEmpty)
    }

    // MARK: - Explanations and quick fixes

    func testExplainsHashFollowedBySpace() {
        let raw = TypstDiagnosticParser.parse(hashError)[0]
        var error = TypstError(line: 55, message: raw.message)
        error.snippet = raw.snippet
        error.column = raw.caretColumn
        let explanation = TypstErrorExplainer.explanation(for: error)
        XCTAssertNotNil(explanation)
        XCTAssertTrue(explanation?.contains(##"`\#`"##) ?? false)
    }

    func testExplainsMissingProjectRoot() {
        let error = TypstError(line: nil, message: "source file must be contained in project root")
        XCTAssertTrue(TypstErrorExplainer.explanation(for: error)?.contains("Store Temp Files Inside Project") ?? false)
        XCTAssertEqual(error.locationLabel, "General")
    }

    func testQuickFixEscapesBareHashOnly() {
        let error = TypstError(line: 1, message: "expected expression")
        let fixes = TypstSuggestionEngine.shared.suggestFixes(for: error, in: "#text[unmodified C# source]")
        let escape = fixes.first { $0.title.contains("Escape #") }
        XCTAssertEqual(escape?.replacement, ##"#text[unmodified C\# source]"##)
    }

    func testQuickFixShowsUnknownVariableAsText() {
        let error = TypstError(line: 1, message: "unknown variable: foo")
        let fixes = TypstSuggestionEngine.shared.suggestFixes(for: error, in: "price #foo today")
        XCTAssertTrue(fixes.contains { $0.replacement == ##"price \#foo today"## })
    }

    func testReportTextIncludesCaretHintsAndTrace() {
        var error = TypstError(line: 3, message: "cannot add integer and string")
        error.file = "lib.typ"
        error.fileLine = 2
        error.snippet = "  x + \"a\""
        error.column = 2
        error.length = 7
        error.hints = ["a hint"]
        error.trace = [.init(message: "error occurred in this call of function `boom`", line: 3)]
        let text = error.reportText(documentName: "main.typ")
        XCTAssertTrue(text.contains("in lib.typ, line 2"))
        XCTAssertTrue(text.contains("      ^^^^^^^"))
        XCTAssertTrue(text.contains("hint: a hint"))
        XCTAssertTrue(text.contains("(line 3)"))
        XCTAssertEqual(error.locationLabel, "lib.typ:2")
    }

    // MARK: - Typst 0.13+ `while calling` frames

    /// Verbatim `typst` 0.15.1 output. Before 0.13 the call chain was printed
    /// as `help: error occurred in this call of function …`; since 0.13 it is a
    /// separate `while calling `name` at file:line:col` paragraph printed after
    /// the primary block's blank line, so it must attach across that blank line.
    private let whileCallingError = """
    error: cannot add integer and string
      ┌─ nested.typ:1:16
      │
    1 │ #let inner(x) = x + "s"
      │                 ^^^^^^^

      while calling `inner` at nested.typ:2:17
        inner(y)
      while calling `middle` at nested.typ:3:16
        middle(z)
      while calling `outer` at nested.typ:4:1
        outer(1)

    """

    func testParsesWhileCallingFrames() {
        let diagnostics = TypstDiagnosticParser.parse(whileCallingError)
        XCTAssertEqual(diagnostics.count, 1, "`while calling` must not start a new diagnostic")
        let d = diagnostics[0]
        XCTAssertEqual(d.message, "cannot add integer and string")
        XCTAssertEqual(d.location, .init(path: "nested.typ", line: 1, column: 16))
        XCTAssertEqual(d.snippet, "#let inner(x) = x + \"s\"", "a frame's code line must not replace the primary snippet")
        XCTAssertEqual(d.trace.count, 3)
        XCTAssertEqual(d.trace.map(\.message), [
            "while calling `inner`", "while calling `middle`", "while calling `outer`",
        ])
        XCTAssertEqual(d.trace[0].location, .init(path: "nested.typ", line: 2, column: 17))
        XCTAssertEqual(d.trace[0].snippet, "inner(y)")
        XCTAssertEqual(d.trace[2].location, .init(path: "nested.typ", line: 4, column: 1))
        XCTAssertEqual(d.trace[2].snippet, "outer(1)")
    }

    func testWhileCallingFrameEmitsUpdateAfterBlockEnded() {
        var parser = TypstDiagnosticParser()
        var events: [TypstDiagnosticParser.Event] = []
        for line in whileCallingError.components(separatedBy: "\n") {
            events.append(parser.consume(line))
        }
        XCTAssertTrue(events.contains(.located(index: 0)))
        // Two blocks end: the diagnostic's own block (before the frames) and the
        // trailing frame paragraph.
        XCTAssertEqual(events.filter { $0 == .blockEnded }.count, 2)
        // The frames arrive after the blank line, so the batch must be told to
        // republish — otherwise the call chain never reaches the error panel.
        XCTAssertEqual(events.filter { $0 == .updated(index: 0) }.count, 3)
    }

    func testFrameInAnotherFileKeepsItsOwnPath() {
        let output = """
        error: cannot add integer and string
          ┌─ lib/helper.typ:1:15
          │
        1 │ #let boom(x) = x + "a"
          │                ^^^^^^^

          while calling `nested` at m.typ:3:1
            nested(2)

        """
        let d = TypstDiagnosticParser.parse(output)[0]
        XCTAssertEqual(d.location?.path, "lib/helper.typ")
        XCTAssertEqual(d.trace.count, 1)
        XCTAssertEqual(d.trace[0].location, .init(path: "m.typ", line: 3, column: 1))
    }

    func testStdinPathIsParsed() {
        let output = """
        error: expected expression
          ┌─ <stdin>:1:12
          │
        1 │ #let a = 1 +

        """
        XCTAssertEqual(TypstDiagnosticParser.parse(output)[0].location, .init(path: "<stdin>", line: 1, column: 12))
    }

    // MARK: - ANSI

    func testStripsANSIColorSequences() {
        // `--color always` wraps the header and gutter in SGR codes. Without
        // stripping, `startsBlock` misses the diagnostic and it is dropped.
        let colored = "\u{1B}[0m\u{1B}[1m\u{1B}[38;5;9merror\u{1B}[0m\u{1B}[1m: unknown variable: a-b\u{1B}[0m"
        XCTAssertTrue(TypstDiagnosticParser.startsBlock(colored))
        let d = TypstDiagnosticParser.parse(colored)[0]
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.message, "unknown variable: a-b")
    }

    // MARK: - Diagnostic codes

    func testCodesAreStableAcrossOperandOrder() {
        // Typst says "cannot add integer and string" or "cannot add string and
        // integer" depending on operand order; both must map to one slug.
        XCTAssertEqual(TypstDiagnosticCode.slug(for: "cannot add integer and string"), "incompatible-operands")
        XCTAssertEqual(TypstDiagnosticCode.slug(for: "cannot add string and integer"), "incompatible-operands")
    }

    func testCodesForCommonDiagnostics() {
        XCTAssertEqual(TypstDiagnosticCode.slug(for: "unknown variable: foo"), "unknown-variable")
        XCTAssertEqual(TypstDiagnosticCode.slug(for: "unknown font family: nopefont"), "unknown-font")
        XCTAssertEqual(TypstDiagnosticCode.slug(for: "file not found (searched at /x/y.png)"), "file-not-found")
        XCTAssertEqual(TypstDiagnosticCode.slug(for: "unclosed delimiter"), "unclosed-delimiter")
        XCTAssertEqual(TypstDiagnosticCode.slug(for: "dictionary does not contain key \"b\""), "missing-key")
        XCTAssertNil(TypstDiagnosticCode.slug(for: "something Typst has never said"))
    }

    func testDocsURLOnlyWhenKnown() {
        XCTAssertEqual(
            TypstDiagnosticCode.docsURL(for: "unknown variable: foo"),
            "https://typst.app/docs/reference/scripting/#bindings")
        XCTAssertNil(TypstDiagnosticCode.docsURL(for: "expected comma"))
    }

    // MARK: - Fallback fixer scoping

    func testErrorLinesIgnoreImportedFilesWhenScoped() {
        let output = """
        error: cannot add integer and string
          ┌─ lib/helper.typ:7:15
          │
        7 │ #let boom(x) = x + "a"

        error: expected expression
          ┌─ temp/doc.typ.preview.typ:3:12
          │
        3 │ #let b = 2 +

        """
        // Unscoped (legacy): both errors, which would let the lenient fixer
        // rewrite line 7 of the shadow file because lib/helper.typ used line 7.
        XCTAssertEqual(TypstCompiler.parseRawErrorLines(from: output), [7, 3])
        // Scoped to the compiled file: only its own error line.
        XCTAssertEqual(
            TypstCompiler.parseRawErrorLines(from: output, onlyInFile: "doc.typ.preview.typ"),
            [3])
    }
}
