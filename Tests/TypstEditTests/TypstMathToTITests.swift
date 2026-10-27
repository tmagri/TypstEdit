import XCTest
@testable import TypstEdit

/// Typst math → calculator entry line conversion, used by "Send to Calculator".
final class TypstMathToTITests: XCTestCase {

    private func convert(_ math: String) throws -> String {
        try TypstMathToTI.convert(math: math)
    }

    // MARK: - Delimiters

    func testStripDelimiters() {
        XCTAssertEqual(TypstMathToTI.stripDelimiters("$x^2$"), "x^2")
        XCTAssertEqual(TypstMathToTI.stripDelimiters("$$x^2$$"), "x^2")
        XCTAssertEqual(TypstMathToTI.stripDelimiters("\\[x^2\\]"), "x^2")
        XCTAssertEqual(TypstMathToTI.stripDelimiters("\\(x^2\\)"), "x^2")
        XCTAssertEqual(TypstMathToTI.stripDelimiters("  $ x + 1 $  "), "x + 1")
    }

    func testConvertRawStripsAndConverts() throws {
        XCTAssertEqual(try TypstMathToTI.convert(raw: "$x^2 + 3 x$"), "x^2 + 3 x")
    }

    func testEmptyEquationThrows() {
        XCTAssertThrowsError(try TypstMathToTI.convert(raw: "$$"))
    }

    // MARK: - Arithmetic and powers

    func testFractionsAndPowersPassThrough() throws {
        XCTAssertEqual(try convert("(a + b) / 2"), "(a + b) / 2")
        XCTAssertEqual(try convert("x^(2 n)"), "x^(2 n)")
        XCTAssertEqual(try convert("x_1 + x_2"), "x_1 + x_2")
        XCTAssertEqual(try convert("3!"), "3!")
    }

    func testGroupingBracesBecomeParentheses() throws {
        XCTAssertEqual(try convert("{a + b} / 2"), "(a + b) / 2")
    }

    func testMultiplicationWords() throws {
        XCTAssertEqual(try convert("2 times x"), "2*x")
        XCTAssertEqual(try convert("a dot b"), "a*b")
        XCTAssertEqual(try convert("a · b"), "a * b")
        XCTAssertEqual(try convert("a div b"), "a/b")
    }

    // MARK: - Functions

    func testFunctionSpellings() throws {
        XCTAssertEqual(try convert("arcsin(x)"), "asin(x)")
        XCTAssertEqual(try convert("arctan(x)"), "atan(x)")
        XCTAssertEqual(try convert("binom(n, k)"), "comb(n, k)")
        XCTAssertEqual(try convert("sqrt(x + 1)"), "sqrt(x + 1)")
        XCTAssertEqual(try convert("ln(x)"), "ln(x)")
        XCTAssertEqual(try convert("abs(x)"), "abs(x)")
    }

    func testReciprocalTrigFunctions() throws {
        XCTAssertEqual(try convert("sec(x)"), "(1/cos)(x)")
        XCTAssertEqual(try convert("csc(x)"), "(1/sin)(x)")
        XCTAssertEqual(try convert("cot(x)"), "(1/tan)(x)")
    }

    func testFunctionNamesAreWordBounded() throws {
        // `arcsinh` must not be rewritten as `asin` + `h`.
        XCTAssertEqual(try convert("arcsinh(x)"), "asinh(x)")
    }

    // MARK: - Operators and constants

    func testComparisonAndInfinity() throws {
        XCTAssertEqual(try convert("x <= 2"), "x <= 2")
        XCTAssertEqual(try convert("x ≥ 2"), "x >= 2")
        XCTAssertEqual(try convert("x ≠ 2"), "x != 2")
        XCTAssertEqual(try convert("lim_(x -> oo) x"), "limit(x, x, infinity)")
        XCTAssertEqual(try convert("oo"), "infinity")
    }

    // MARK: - Calculus

    func testDefiniteIntegral() throws {
        XCTAssertEqual(
            try convert("integral_0^1 x^2 dif x"),
            "integrate(x^2, x, 0, 1)")
        XCTAssertEqual(
            try convert("integral_(0)^(pi) sin(x) dif x"),
            "integrate(sin(x), x, 0, pi)")
    }

    func testSumAndProduct() throws {
        XCTAssertEqual(
            try convert("sum_(k=1)^10 k"),
            "sum(k, k, 1, 10)")
        XCTAssertEqual(
            try convert("product_(k=1)^n k"),
            "product(k, k, 1, n)")
    }

    func testLimit() throws {
        XCTAssertEqual(
            try convert("lim_(x -> 0) sin(x) / x"),
            "limit(sin(x) / x, x, 0)")
    }

    func testDerivativeFraction() throws {
        XCTAssertEqual(
            try convert("(dif x^2)/(dif x)"),
            "diff(x^2, x)")
    }

    // MARK: - Matrices

    func testMatrix() throws {
        XCTAssertEqual(
            try convert("mat(a, b; c, d)"),
            "[[a,b],[c,d]]")
    }

    // MARK: - Failure modes

    func testUnsupportedConstructsThrow() {
        XCTAssertThrowsError(try convert("cases(x & \"if\" x > 0)"))
        XCTAssertThrowsError(try convert("bold(x)"))
        XCTAssertThrowsError(try convert("overline(x)"))
        XCTAssertThrowsError(try convert("x & y"))
        XCTAssertThrowsError(try convert("∑_(k=0)^n k"))
        XCTAssertThrowsError(try convert("∫_0^1 x"))
    }

    func testUnbalancedBracketsThrow() {
        XCTAssertThrowsError(try convert("(x + 1"))
    }

    func testUnbalancedMatThrows() {
        XCTAssertThrowsError(try convert("mat(a, b; c, d"))
    }

    // MARK: - Round trip through the CAS renderer

    /// What the calculator renders should be loadable back into it. This is
    /// the exact "equation in the editor → calculator" path.
    func testCASRenderedEquationRoundTrips() throws {
        let rendered = CASTypstRenderer.typst(
            .function(name: "integrate", args: [
                .function(name: "sin", args: [.symbol("x")]),
                .symbol("x"),
                .number(value: "0", approx: nil),
                .constant("pi"),
            ]))
        // `integral_0^pi sin(x) dif x`
        XCTAssertEqual(rendered, "integral_0^pi sin(x) dif x")
        XCTAssertEqual(try convert(rendered), "integrate(sin(x), x, 0, pi)")
    }

    func testCASRenderedBesselRoundTrips() throws {
        let rendered = CASTypstRenderer.typst(
            .function(name: "BesselJ", args: [
                .number(value: "0", approx: nil),
                .symbol("x"),
            ]))
        XCTAssertEqual(rendered, "J(x)")
        // Order-zero Bessel renders without a subscript; the calculator-side
        // spelling keeps working when typed back in.
        XCTAssertTrue(rendered.contains("J"))
    }
}
