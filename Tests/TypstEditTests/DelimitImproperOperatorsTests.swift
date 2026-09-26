import XCTest
@testable import TypstEdit

final class DelimitImproperOperatorsTests: XCTestCase {

    private func delimit(_ source: String) -> (output: String, warnings: [TypstError]) {
        TypstCompiler.delimitImproperOperators(source)
    }

    // MARK: - Legitimate Typst must be preserved

    func testPreservesValidReference() {
        let out = delimit("See @fig1 for details.").output
        XCTAssertEqual(out, "See @fig1 for details.")
    }

    func testPreservesHashKeywordsAndCalls() {
        let inputs = [
            "#let x = 1",
            "#set page(width: 10pt)",
            "#emph[hi]",
            "#raw(\"code\")",
            "#\"string\"",
            "#(1 + 2)",
            "#{ let y = 2 }",
            "#123"
        ]
        for input in inputs {
            XCTAssertEqual(delimit(input).output, input, "Should preserve valid Typst: \(input)")
        }
    }

    func testPreservesMathAndLabels() {
        let inputs = [
            "Energy is $E = mc^2$ here.",
            "Figure <fig1> shows it.",
            "Tag <p>text</p> here."
        ]
        for input in inputs {
            XCTAssertEqual(delimit(input).output, input, "Should preserve: \(input)")
        }
    }

    func testDoesNotEscapeOperatorsInsideLinkTargetString() {
        // `@` inside a Typst string is a literal character. Escaping it produces
        // `\@` — an invalid string escape that breaks the compile — plus a
        // bogus "needs delimiting" warning. The label's `\@` (content-mode
        // escaping, typed by the user) must also pass through untouched.
        let source = "#link(\"mailto:jane.doe@example.com\")[jane.doe\\@example.com]"
        let (output, warnings) = delimit(source)
        XCTAssertEqual(output, source, "string contents must pass through untouched")
        XCTAssertTrue(warnings.isEmpty, "no warning expected, got: \(warnings.map(\.message))")
    }

    func testMasksEveryStringOnACodeLine() {
        let source = "#text(font: \"Liberation Serif\", fill: \"l@r<>\")[a]"
        let (output, warnings) = delimit(source)
        XCTAssertEqual(output, source)
        XCTAssertTrue(warnings.isEmpty, "no warning expected, got: \(warnings.map(\.message))")
    }

    func testStillEscapesAtInProseBeforeCodeOnSameLine() {
        // The `#` must precede the first quote for string masking to apply;
        // operators in the prose part of the same line still get escaped.
        let source = "Mail jane@example.com or visit #link(\"https://example.com\")[the site]"
        let (output, warnings) = delimit(source)
        XCTAssertTrue(output.contains("jane\\@example.com"), "prose @ still escaped: \(output)")
        XCTAssertFalse(output.contains("https://example.com\\@"), "string target untouched")
        XCTAssertEqual(warnings.count, 1)
    }

    func testProseQuotesKeepEscapingWithoutHash() {
        // No code expression on the line: quoted prose keeps the old behavior.
        let source = "Email \"the team\" at jane@example.com today"
        let (output, warnings) = delimit(source)
        XCTAssertTrue(output.contains("jane\\@example.com"), "prose @ still escaped: \(output)")
        XCTAssertEqual(warnings.count, 1)
    }

    func testPreservesOperatorsInsideCodeSpans() {
        let out = delimit("Call `user@x.com` and `#foo` now.").output
        XCTAssertEqual(out, "Call `user@x.com` and `#foo` now.")
    }

    func testPreservesOperatorsInsideFencedCodeBlock() {
        let source = """
        Before
        ```typst
        #let x = @ref
        $5 < 3$
        ```
        After
        """
        XCTAssertEqual(delimit(source).output, source)
    }

    // MARK: - Improper operators get delimited + warned

    func testEscapesBareAtSign() {
        let result = delimit("Price @ the store")
        XCTAssertTrue(result.output.contains("\\@"))
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0].severity, .warning)
        XCTAssertEqual(result.warnings[0].line, 1)
    }

    func testEscapesEmailAtSign() {
        let result = delimit("Contact user@email.com")
        XCTAssertTrue(result.output.contains("user\\@email.com"))
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testEscapesStrayHash() {
        let result = delimit("Hashtag # here")
        XCTAssertTrue(result.output.contains("\\#"))
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testEscapesStrayDollar() {
        let result = delimit("Cost is $5 today")
        XCTAssertTrue(result.output.contains("\\$5"))
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testEscapesComparisonAngles() {
        let result = delimit("If 5 < 3 then 3 > 5")
        XCTAssertTrue(result.output.contains("\\"), "Expected an escape")
        XCTAssertEqual(result.warnings.count, 1, "One warning per line")
    }

    // MARK: - Line numbers + grouping

    func testWarningLineNumbersAreOneBasedAndAccurate() {
        let source = "line one\nline two # bad\nline three @ bad"
        let result = delimit(source)
        let lines = result.warnings.map(\.line).sorted()
        XCTAssertEqual(lines, [2, 3])
    }

    func testDoesNotEscapeAlreadyEscapedOperators() {
        let out = delimit("Already \\@ and \\# done").output
        XCTAssertEqual(out, "Already \\@ and \\# done")
    }

    func testNoWarningsForCleanText() {
        let result = delimit("Just a normal sentence with no operators.")
        XCTAssertTrue(result.warnings.isEmpty)
    }
}
