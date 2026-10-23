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
}
