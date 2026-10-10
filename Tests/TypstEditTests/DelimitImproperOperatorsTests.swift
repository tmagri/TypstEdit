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
        XCTAssertTrue(warnings.isEmpty, "prose @ is escaped silently: \(warnings.map(\.message))")
    }

    func testProseQuotesKeepEscapingWithoutHash() {
        // No code expression on the line: quoted prose keeps the old behavior.
        let source = "Email \"the team\" at jane@example.com today"
        let (output, warnings) = delimit(source)
        XCTAssertTrue(output.contains("jane\\@example.com"), "prose @ still escaped: \(output)")
        XCTAssertTrue(warnings.isEmpty, "prose @ is escaped silently: \(warnings.map(\.message))")
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

    // MARK: - Improper operators get delimited (silently) + warned

    func testEscapesBareAtSignSilently() {
        // A bare `@` is escaped so it renders literally, but prose punctuation is
        // not worth an advisory warning.
        let result = delimit("Price @ the store")
        XCTAssertTrue(result.output.contains("\\@"))
        XCTAssertTrue(result.warnings.isEmpty, "got: \(result.warnings.map(\.message))")
    }

    func testEscapesEmailAtSignSilently() {
        let result = delimit("Contact user@email.com")
        XCTAssertTrue(result.output.contains("user\\@email.com"))
        XCTAssertTrue(result.warnings.isEmpty, "got: \(result.warnings.map(\.message))")
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

    // MARK: - Register-style `$` tokens (assembly / technical notes)

    func testEscapesRegisterTokenPairWithoutWarning() {
        // `$DC10–$DC4F` is two register/address tokens, not one math region. Both
        // must be escaped so they render literally, and neither should warn.
        let source = "at $DC10–$DC4F here"
        let (output, warnings) = delimit(source)
        XCTAssertEqual(output, "at \\$DC10–\\$DC4F here")
        XCTAssertTrue(warnings.isEmpty, "got: \(warnings.map(\.message))")
    }

    func testEscapesSlashSeparatedRegisterListWithoutWarning() {
        let source = "labels ($3DF8/$3E50/$3E54) untouched"
        let (output, warnings) = delimit(source)
        XCTAssertEqual(output, "labels (\\$3DF8/\\$3E50/\\$3E54) untouched")
        XCTAssertTrue(warnings.isEmpty, "got: \(warnings.map(\.message))")
    }

    func testStillWarnsForSingleDigitAmount() {
        // `$5` is a currency amount, not a register token: it is escaped and the
        // warning is kept so the user knows the dollar was auto-delimited.
        let result = delimit("It costs $5 total")
        XCTAssertTrue(result.output.contains("\\$5"))
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testEscapesComparisonAnglesSilently() {
        // `<`/`>` as comparison operators are ordinary prose: escape them so they
        // render literally, but do not warn.
        let result = delimit("If 5 < 3 then 3 > 5")
        XCTAssertTrue(result.output.contains("\\"), "Expected an escape")
        XCTAssertTrue(result.warnings.isEmpty, "got: \(result.warnings.map(\.message))")
    }

    // MARK: - Line numbers + grouping

    func testWarningLineNumbersAreOneBasedAndAccurate() {
        let source = "line one\nline two # bad\nline three # bad"
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
