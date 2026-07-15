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
