import XCTest
@testable import TypstEdit

final class CalculatorAIFallbackTests: XCTestCase {
    // MARK: - Question-like entries route to AI

    func testNaturalLanguageQuestionsRouteToAI() {
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage("How many r's in strawberry"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage("what is the capital of France"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage("convert 3.5 miles to km"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage("who wrote Hamlet?"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage("is 97 a prime number?"))
    }

    /// The phrasings from the field report that Giac swallows as string
    /// echoes — none has a starter word (the third has one, mangled case),
    /// so they exercise the "?" rule and the letter-word rule.
    func testCircleAreaPhrasingsRouteToAI() {
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "Area of a circle, if diameter is 1 cm."))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "Area of a circle, if diameter is 1 cm?"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "WHat is the Area of a circle, if diameter is 1 cm?"))
    }

    /// Word problems embed units and equations (`g = 9.8 m/s^2`) but are
    /// still questions: the CAS must not keep them just because they contain
    /// math notation.
    func testWordProblemsWithEmbeddedMathRouteToAI() {
        let ball = """
        A boy throws a ball vertically upward with a velocity of 6 m/s. \
        Ignoring air resistance and using g = 9.8 m/s^2, how many seconds does it take \
        for the ball to return to the boy's hand? Give just the numerical value in seconds.
        """
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(ball))

        let ballNoQuestionMark = """
        A boy throws a ball vertically upward with a velocity of 6 m/s. \
        Ignoring air resistance and using g = 9.8 m/s^2, give just the numerical value \
        of the time the ball takes to return to the boy's hand.
        """
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(ballNoQuestionMark))

        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "If I caught 10 pokemon, how many can I carry at a time."))
    }

    /// Prose requests for a symbolic answer are still questions — Giac
    /// answers them `undef` rather than erroring, so they must route too.
    func testDerivativePhrasingsRouteToAI() {
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage("the derivative of x^2"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "the derivative of x^2 with respect to x"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "integral of x^2 from 0 to 1"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "taylor series expansion of sin(x) at x = 0"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "taylor series expansion of sin(x) at x = a"))
        XCTAssertTrue(CalculatorAIFallback.looksLikeNaturalLanguage(
            "the derivative of x^2 + 2x + 4 with respect to x"))
    }

    // MARK: - Math-shaped input must never be routed, even on CAS failure,
    // so typos in formulas still show the CAS error.

    func testMathSyntaxStaysWithTheCAS() {
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("sovle(x^2-4=0,x)"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("sin(pi/2"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("x^2"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("2*x+1"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("5+"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("Define f(x)=x^2"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("[[1,2];[3,4]]"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("a-b/c"))
        // Operator-heavy input with spaces is still a formula, not prose.
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("solve x^2 - 4 = 0 for x"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("2 * 3 + 4"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("1 + 2 + 3 + 4 + 5"))
    }

    func testShortOrSymbolicInputStaysWithTheCAS() {
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage(""))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("x"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("5"))
        XCTAssertFalse(CalculatorAIFallback.looksLikeNaturalLanguage("xy z1 2")) // too few letter words
    }

    // MARK: - String echoes: Giac "succeeds" on prose by echoing it back as
    // a quoted string, which must count as a failure for routing.

    func testStringEchoViaResultTreeIsDetected() {
        let echoed = CASEvalResult(
            inputTree: nil,
            resultTree: .string("Area of a circle, if diameter is 1 cm."),
            resultText: "\"Area of a circle, if diameter is 1 cm.\"",
            resultTypst: "", inputTypst: "", errorMessage: "", ok: true)
        XCTAssertTrue(CalculatorAIFallback.isStringEcho(
            echoed, input: "Area of a circle, if diameter is 1 cm."))
    }

    func testStringEchoViaQuotedTextIsDetected() {
        let quoted = CASEvalResult(
            inputTree: nil, resultTree: nil,
            resultText: "\"WHat is the Area of a circle, if diameter is 1 cm?\"",
            resultTypst: "", inputTypst: "", errorMessage: "", ok: true)
        XCTAssertTrue(CalculatorAIFallback.isStringEcho(
            quoted, input: "WHat is the Area of a circle, if diameter is 1 cm?"))
    }

    func testRealResultsAreNotStringEchoes() {
        let math = CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "4",
            resultTypst: "4", inputTypst: "2+2", errorMessage: "", ok: true)
        XCTAssertFalse(CalculatorAIFallback.isStringEcho(math, input: "2+2"))

        let failure = CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "",
            resultTypst: "", inputTypst: "", errorMessage: "bad syntax", ok: false)
        XCTAssertFalse(CalculatorAIFallback.isStringEcho(failure, input: "5+"))
    }

    // MARK: - `undef` results: Giac answers `undef` (not an error) for text
    // it cannot make sense of, so that counts as unusable for routing too.

    func testUndefinedResultsAreDetected() {
        let viaTree = CASEvalResult(
            inputTree: nil, resultTree: .undefined, resultText: "undef",
            resultTypst: "undef", inputTypst: "", errorMessage: "", ok: true)
        XCTAssertTrue(CalculatorAIFallback.isUndefined(viaTree))
        XCTAssertTrue(CalculatorAIFallback.isUnhelpfulResult(
            viaTree, input: "the derivative of x^2"))

        let viaText = CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "undef",
            resultTypst: "undef", inputTypst: "", errorMessage: "", ok: true)
        XCTAssertTrue(CalculatorAIFallback.isUndefined(viaText))
    }

    /// Giac also mangles prose into an equation with `undef` on one side
    /// ("… at x = 0" → `undef = 0`), which must count as undefined too.
    func testMangledUndefinedExpressionsAreDetected() {
        let asZero = CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "undef = 0",
            resultTypst: "undef = 0", inputTypst: "", errorMessage: "", ok: true)
        XCTAssertTrue(CalculatorAIFallback.isUndefined(asZero))
        XCTAssertTrue(CalculatorAIFallback.isUnhelpfulResult(
            asZero, input: "taylor series expansion of sin(x) at x = 0"))

        let asSymbol = CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "undef = a",
            resultTypst: "undef = a", inputTypst: "", errorMessage: "", ok: true)
        XCTAssertTrue(CalculatorAIFallback.isUndefined(asSymbol))

        // The same shape in the expression tree.
        let tree = CASExpression.operation(name: "=", args: [.undefined, .symbol("a")])
        XCTAssertTrue(CalculatorAIFallback.containsUndefined(tree))
        let clean = CASExpression.operation(name: "=", args: [.symbol("x"), .number(value: "2", approx: nil)])
        XCTAssertFalse(CalculatorAIFallback.containsUndefined(clean))
    }

    func testRealSymbolicResultsAreNotUndefined() {
        let derivative = CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "2*x",
            resultTypst: "2 x", inputTypst: "d(x^2,x)", errorMessage: "", ok: true)
        XCTAssertFalse(CalculatorAIFallback.isUndefined(derivative))
        XCTAssertFalse(CalculatorAIFallback.isUnhelpfulResult(derivative, input: "d(x^2,x)"))

        let number = CASEvalResult(
            inputTree: nil, resultTree: nil, resultText: "60/49",
            resultTypst: "60/49", inputTypst: "", errorMessage: "", ok: true)
        XCTAssertFalse(CalculatorAIFallback.isUnhelpfulResult(number, input: "2*6/9.8"))
    }

    // MARK: - EXPR/ANSWER reply parsing (small local models misbehave, so
    // the parser must tolerate variations).

    func testParseComputableInterpretation() {
        let parsed = CalculatorAIFallback.parseInterpretation(
            "EXPR: pi*(1/2)^2\nANSWER: The area is about 0.785 square centimeters.")
        XCTAssertEqual(parsed.expression, "pi*(1/2)^2")
        XCTAssertEqual(parsed.answer, "The area is about 0.785 square centimeters.")
    }

    func testParseKnowledgeInterpretation() {
        let parsed = CalculatorAIFallback.parseInterpretation(
            "EXPR: none\nANSWER: Hamlet was written by William Shakespeare.")
        XCTAssertNil(parsed.expression)
        XCTAssertEqual(parsed.answer, "Hamlet was written by William Shakespeare.")
    }

    func testParseMarkdownWrappedLabels() {
        let parsed = CalculatorAIFallback.parseInterpretation(
            "**EXPR:** `pi*(1/2)^2`\n**ANSWER:** about 0.785")
        XCTAssertEqual(parsed.expression, "pi*(1/2)^2")
        XCTAssertEqual(parsed.answer, "about 0.785")
    }

    func testParseLongLabelSpelling() {
        let parsed = CalculatorAIFallback.parseInterpretation(
            "Expression: pi*(1/2)^2\nAnswer: about 0.785")
        XCTAssertEqual(parsed.expression, "pi*(1/2)^2")
        XCTAssertEqual(parsed.answer, "about 0.785")
    }

    func testParseFormatlessReplyBecomesTheAnswer() {
        let parsed = CalculatorAIFallback.parseInterpretation(
            "It was written by Shakespeare around 1600.")
        XCTAssertNil(parsed.expression)
        XCTAssertEqual(parsed.answer, "It was written by Shakespeare around 1600.")
    }

    func testParseExpressionOnlyReplyGetsANote() {
        let parsed = CalculatorAIFallback.parseInterpretation("EXPR: pi*(1/2)^2")
        XCTAssertEqual(parsed.expression, "pi*(1/2)^2")
        XCTAssertTrue(parsed.answer.contains("pi*(1/2)^2"))
    }

    func testParseTypstMathInterpretation() {
        let input = """
        EXPR: none
        TYPST: x^2 = pi^2/3 + 4 sum_(n=1)^oo (-1)^n/n^2 cos(n x)
        ANSWER: The Fourier series on $(-pi, pi)$ is $x^2 = pi^2/3 + 4 sum_(n=1)^oo (-1)^n/n^2 cos(n x)$.
        """
        let parsed = CalculatorAIFallback.parseInterpretation(input)
        XCTAssertNil(parsed.expression)
        XCTAssertEqual(parsed.typstMath, "x^2 = pi^2/3 + 4 sum_(n=1)^oo (-1)^n/n^2 cos(n x)")
        XCTAssertTrue(parsed.answer.contains("$"))
    }

    func testExtractPrimaryEquationFromProse() {
        let rawAnswer = "The Fourier series of f(x)=x² on (-π,π) with period 2π is x² = π²/3 + 4∑ₙ₌₁^∞ (-1)ⁿ/n² · cos(nx), since the function is even (all bₙ=0), a₀=2π²/3, and aₙ=4(-1)ⁿ/n²."
        let parsed = CalculatorAIFallback.parseInterpretation(rawAnswer)
        XCTAssertNotNil(parsed.typstMath)
        XCTAssertTrue(parsed.typstMath?.contains("x^2") == true)
        XCTAssertTrue(parsed.typstMath?.contains("sum") == true)
    }

    func testNormalizeToTypstMathConvertsLatexAndUnicode() {
        let unicodeSample = "x² = π²/3 + 4∑ₙ₌₁^∞ (-1)ⁿ/n² · cos(nx)"
        let normalizedUnicode = CalculatorAIFallback.normalizeToTypstMath(unicodeSample)
        XCTAssertTrue(normalizedUnicode.contains("x^2"))
        XCTAssertTrue(normalizedUnicode.contains("pi"))
        XCTAssertTrue(normalizedUnicode.contains("sum"))
        XCTAssertTrue(normalizedUnicode.contains("dot"))

        let latexSample = "x^2 = \\frac{\\pi^2}{3} + 4 \\sum_{n=1}^{\\infty} \\frac{(-1)^n}{n^2} \\cos(nx)"
        let normalizedLatex = CalculatorAIFallback.normalizeToTypstMath(latexSample)
        XCTAssertTrue(normalizedLatex.contains("x^2"))
        XCTAssertTrue(normalizedLatex.contains("pi"))
        XCTAssertTrue(normalizedLatex.contains("sum"))
    }

    func testNormalizeAnswerMathReplacesLatexDelimiters() {
        let answer = "The Fourier series of \\(f(x)=x^{2}\\) is \\(x^{2} = \\frac{\\pi^{2}}{3}\\)."
        let normalized = CalculatorAIFallback.normalizeAnswerMath(answer)
        XCTAssertFalse(normalized.contains("\\("))
        XCTAssertFalse(normalized.contains("\\)"))
        XCTAssertTrue(normalized.contains("$"))
    }

    // MARK: - Expression cleanup (markdown, typographic math, sentence dots)

    func testInterpretationExpressionCleanup() {
        XCTAssertEqual(CalculatorAIFallback.interpretationExpression("pi*(1/2)^2"), "pi*(1/2)^2")
        XCTAssertEqual(CalculatorAIFallback.interpretationExpression("`pi*(1/2)^2`."), "pi*(1/2)^2")
        XCTAssertEqual(CalculatorAIFallback.interpretationExpression("$pi*(1/2)^2$"), "pi*(1/2)^2")
        XCTAssertEqual(CalculatorAIFallback.interpretationExpression("π×(1÷2)²"), "pi*(1/2)^2")
        XCTAssertEqual(CalculatorAIFallback.interpretationExpression("sqrt(2)."), "sqrt(2)")
        XCTAssertNil(CalculatorAIFallback.interpretationExpression("none"))
        XCTAssertNil(CalculatorAIFallback.interpretationExpression("None"))
        XCTAssertNil(CalculatorAIFallback.interpretationExpression("  "))
    }

    // MARK: - Persistence: the optional `aiAnswer` field must not break
    // existing .tcalc files, and AI entries must round-trip.

    func testEntryAIGroundTruthRoundTrip() throws {
        let entry = CalculatorEntry(
            input: "How many r's in strawberry",
            resultPlain: "Three.",
            aiAnswer: "Three.")
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([CalculatorEntry].self, from: data)
        XCTAssertEqual(decoded.first?.aiAnswer, "Three.")
        XCTAssertEqual(decoded.first?.resultPlain, "Three.")
    }

    func testLegacyEntriesWithoutAIAnswerStillDecode() throws {
        // A pre-fallback .tcalc entry: no `aiAnswer` key at all.
        let legacyJSON = """
        [{"id":"11111111-1111-1111-1111-111111111111",
          "input":"2+2",
          "approx":false,
          "resultTypst":"4",
          "resultPlain":"4",
          "inputTypst":"2+2",
          "isError":false,
          "errorMessage":"",
          "timestamp":5.0}]
        """
        let decoded = try JSONDecoder().decode([CalculatorEntry].self,
                                               from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.first?.resultPlain, "4")
        XCTAssertNil(decoded.first?.aiAnswer)
    }

    // MARK: - Export: AI answers are prose plus (when computable) one exact
    // result — never the whole thing wrapped in math delimiters.

    func testExportRendersAIAnswersAsText() {
        let document = CalculatorDocument(entries: [
            CalculatorEntry(input: "2+2", resultTypst: "4", resultPlain: "4", inputTypst: "2+2"),
            CalculatorEntry(input: "How many r's in strawberry",
                            resultPlain: "Three.", aiAnswer: "Three."),
        ])
        let exported = CalculatorExport.typst(sessionName: "Test", document: document)
        XCTAssertTrue(exported.contains("$ 2+2 = 4 $"))
        XCTAssertTrue(exported.contains("*How many r's in strawberry*"))
        XCTAssertTrue(exported.contains("Three."))
        XCTAssertFalse(exported.contains("$ Three. $"))
    }

    func testExportIncludesComputedResultForAIEntries() {
        let document = CalculatorDocument(entries: [
            CalculatorEntry(input: "Area of a circle, if diameter is 1 cm?",
                            resultTypst: "\\frac{\\pi}{4}",
                            resultPlain: "pi/4",
                            aiAnswer: "The area is pi/4, about 0.785 square centimeters."),
        ])
        let exported = CalculatorExport.typst(sessionName: "Test", document: document)
        XCTAssertTrue(exported.contains("*Area of a circle, if diameter is 1 cm?*"))
        XCTAssertTrue(exported.contains("$ \\frac{\\pi}{4} $"))
        XCTAssertTrue(exported.contains("The area is pi/4"))
    }
}
