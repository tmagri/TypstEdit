import XCTest
@testable import TypstEdit

/// Typst math → calculator entry line conversion, used by "Send to Calculator".
///
/// The point of these tests is fidelity: Typst math looks like Giac input but
/// several constructs mean something *different*, and a silent misreading is
/// worse than a refusal. Each case below is a construct where passing the text
/// through unchanged is known to be wrong.
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
        XCTAssertEqual(try TypstMathToTI.convert(raw: "$x^2 + 3 x$"), "x^2 + 3*x")
    }

    func testEmptyEquationThrows() {
        XCTAssertThrowsError(try TypstMathToTI.convert(raw: "$$"))
        XCTAssertThrowsError(try TypstMathToTI.convert(raw: "   "))
    }

    /// Alignment points are Typst layout, not mathematics.
    func testAlignmentPointsAreDropped() throws {
        XCTAssertEqual(try convert("x &= 2"), "x = 2")
        XCTAssertEqual(try convert("a & b"), "a*b")
    }

    // MARK: - Arithmetic and powers

    func testFractionsAndPowersPassThrough() throws {
        XCTAssertEqual(try convert("(a + b) / 2"), "(a + b)/2")
        XCTAssertEqual(try convert("x^(2 n)"), "x^(2*n)")
        XCTAssertEqual(try convert("x_1 + x_2"), "x_1 + x_2")
        XCTAssertEqual(try convert("3!"), "3!")
    }

    func testGroupingBracesBecomeParentheses() throws {
        XCTAssertEqual(try convert("{a + b} / 2"), "(a + b)/2")
    }

    func testMultiplicationWords() throws {
        XCTAssertEqual(try convert("2 times x"), "2*x")
        XCTAssertEqual(try convert("a dot b"), "a*b")
        XCTAssertEqual(try convert("a · b"), "a*b")
        XCTAssertEqual(try convert("a div b"), "a/b")
    }

    /// Typst juxtaposition is multiplication, but Giac reads `2 x` and `x y`
    /// as syntax errors.
    func testJuxtapositionBecomesExplicitMultiplication() throws {
        XCTAssertEqual(try convert("2 x"), "2*x")
        XCTAssertEqual(try convert("x y"), "x*y")
        XCTAssertEqual(try convert("2 x y"), "2*x*y")
        XCTAssertEqual(try convert("pi r^2"), "pi*r^2")
        XCTAssertEqual(try convert("alpha + beta"), "alpha + beta")
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
        XCTAssertEqual(try convert("sec(x)"), "1/cos(x)")
        XCTAssertEqual(try convert("csc(x)"), "1/sin(x)")
        XCTAssertEqual(try convert("cot(x)"), "1/tan(x)")
    }

    func testFunctionNamesAreWordBounded() throws {
        // `arcsinh` must not be rewritten as `asin` + `h`.
        XCTAssertEqual(try convert("arcsinh(x)"), "asinh(x)")
    }

    /// Typst renders `sin x` (no parentheses) as a function application.
    func testFunctionWithoutParentheses() throws {
        XCTAssertEqual(try convert("sin x"), "sin(x)")
        XCTAssertEqual(try convert("sin 2x"), "sin(2*x)")
        XCTAssertEqual(try convert("floor x"), "floor(x)")
        // Two functions side by side stay separate products.
        XCTAssertEqual(try convert("sin x cos x"), "sin(x)*cos(x)")
    }

    /// Typst's `sin^2 x` attaches the power to the function, not the argument.
    func testFunctionPowerAndInverse() throws {
        XCTAssertEqual(try convert("sin^2 x"), "(sin(x))^2")
        XCTAssertEqual(try convert("sin^(-1)(x)"), "asin(x)")
        XCTAssertEqual(try convert("sin^(-2) x"), "(sin(x))^(-2)")
    }

    /// `frac(a, b)` is Giac's integer-part function, not a fraction.
    func testFracCallBecomesDivision() throws {
        XCTAssertEqual(try convert("frac(a, b)"), "a/b")
        XCTAssertEqual(try convert("frac(1, 3)"), "1/3")
    }

    /// A compound numerator or denominator must stay grouped, or
    /// `frac(a + b, c)` would become a + b/c.
    func testFracCallGroupsCompoundArguments() throws {
        XCTAssertEqual(try convert("frac(a + b, c)"), "(a + b)/c")
        XCTAssertEqual(
            try convert("frac(x^2 + 1, 2x - 3)"),
            "(x^2 + 1)/(2*x - 3)")
        XCTAssertEqual(
            try convert("binom(n, k) = frac(n!, k!(n-k)!)"),
            "comb(n, k) = n!/(k!*(n - k)!)")
    }

    /// Typst's `root(index, radicand)`; Giac's `root` has the opposite order.
    func testRootCall() throws {
        XCTAssertEqual(try convert("root(3, x)"), "x^(1/3)")
        XCTAssertEqual(try convert("root(8)"), "sqrt(8)")
    }

    /// Typst's `log` is base 10; Giac's is the natural log.
    func testLogarithms() throws {
        XCTAssertEqual(try convert("log(x)"), "log10(x)")
        XCTAssertEqual(try convert("log 100"), "log10(100)")
        XCTAssertEqual(try convert("log_2(x)"), "logb(x, 2)")
        XCTAssertEqual(try convert("ln(x)"), "ln(x)")
    }

    func testVectorsAndNorms() throws {
        XCTAssertEqual(try convert("vec(1, 2, 3)"), "[1,2,3]")
        XCTAssertEqual(try convert("||x||"), "norm(x)")
        XCTAssertEqual(try convert("|x|"), "abs(x)")
        XCTAssertEqual(try convert("|x - 1|"), "abs(x - 1)")
    }

    func testWrapperCallsAreUnwrapped() throws {
        XCTAssertEqual(try convert("upright(d) x"), "d*x")
        XCTAssertEqual(try convert("display(sum_(k=1)^n k)"), "sum(k, k, 1, n)")
        XCTAssertEqual(try convert("lr((a+b))"), "(a + b)")
        XCTAssertEqual(try convert("attach(x, t: 1)"), "x^1")
    }

    // MARK: - Operators and constants

    func testComparisonAndInfinity() throws {
        XCTAssertEqual(try convert("x <= 2"), "x <= 2")
        XCTAssertEqual(try convert("x ≥ 2"), "x >= 2")
        XCTAssertEqual(try convert("x ≠ 2"), "x != 2")
        XCTAssertEqual(try convert("lim_(x -> oo) x"), "limit(x, x, infinity)")
        XCTAssertEqual(try convert("oo"), "infinity")
    }

    /// `degree` is a symbol in Typst; Giac needs radians.
    func testDegreesBecomeRadians() throws {
        XCTAssertEqual(try convert("90 degree"), "90*pi/180")
        XCTAssertEqual(try convert("sin 30 degree"), "sin(30*pi/180)")
    }

    func testPercentIsAQuotient() throws {
        XCTAssertEqual(try convert("50%"), "50/100")
    }

    func testScientificNotationIsOneNumber() throws {
        XCTAssertEqual(try convert("1.5e-7"), "1.5e-7")
        XCTAssertEqual(try convert("2E+12"), "2e+12")
    }

    // MARK: - Calculus

    func testDefiniteIntegral() throws {
        XCTAssertEqual(
            try convert("integral_0^1 x^2 dif x"),
            "integrate(x^2, x, 0, 1)")
        XCTAssertEqual(
            try convert("integral_(0)^(pi) sin(x) dif x"),
            "integrate(sin(x), x, 0, pi)")
        XCTAssertEqual(
            try convert("integral x^2 dif x"),
            "integrate(x^2, x)")
        XCTAssertEqual(
            try convert("integral.double_0^1 x dif x"),
            "integrate(x, x, 0, 1, 2)")
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
            "limit(sin(x)/x, x, 0)")
        // One-sided limits are Giac's fourth argument.
        XCTAssertEqual(
            try convert("lim_(x -> 0^+) 1/x"),
            "limit(1/x, x, 0, 1)")
    }

    func testDerivativeFraction() throws {
        XCTAssertEqual(try convert("(dif x^2)/(dif x)"), "diff(x^2, x)")
        XCTAssertEqual(try convert("(dif^(2) f)/(dif x^(2))"), "diff(f, x, 2)")
        XCTAssertEqual(try convert("f'(x)"), "diff(f, x)")
        // The same quotient written with the fraction element.
        XCTAssertEqual(try convert("frac(dif y, dif x)"), "diff(y, x)")
    }

    /// An integrand may contain additions; the differential marks its end.
    func testIntegrandExtendsToTheDifferential() throws {
        XCTAssertEqual(
            try convert("integral_0^1 x^2 + x dif x"),
            "integrate(x^2 + x, x, 0, 1)")
    }

    // MARK: - Matrices and cases

    func testMatrix() throws {
        XCTAssertEqual(try convert("mat(a, b; c, d)"), "[[a,b],[c,d]]")
        // Named arguments are layout, not cells.
        XCTAssertEqual(try convert("mat(delim: \"[\", 1, 2; 3, 4)"), "[[1,2],[3,4]]")
    }

    /// `cases` with `if`/`otherwise` is a piecewise function; without them it
    /// is a column of values.
    func testCases() throws {
        XCTAssertEqual(
            try convert("cases(x & \"if\" x > 0, -x & \"otherwise\")"),
            "piecewise(x > 0, x, true, -x)")
        XCTAssertEqual(try convert("cases(x, -x)"), "[x,-x]")
    }

    // MARK: - Failure modes

    /// Wrong-but-plausible output is worse than a refusal, so anything the
    /// converter cannot express raises with a reason.
    func testUnsupportedConstructsThrow() {
        XCTAssertThrowsError(try convert("hat(x)"))
        XCTAssertThrowsError(try convert("overline(x)"))
        XCTAssertThrowsError(try convert("accent(x, hat)"))
        XCTAssertThrowsError(try convert("x in RR"))
        XCTAssertThrowsError(try convert("\"quoted\""))
        XCTAssertThrowsError(try convert("dif x"))
        // Conditional probability has no entry-line form.
        XCTAssertThrowsError(try convert("P(A | B)"))
        XCTAssertThrowsError(try convert("plus.minus"))
        // Interpolated Typst code is not mathematics.
        XCTAssertThrowsError(try convert("#calc(\"1+1\")"))
        // A multi-line derivation cannot fit one entry line.
        XCTAssertThrowsError(try convert("x = 2 \\\\ y = 3"))
    }

    func testUnbalancedBracketsThrow() {
        XCTAssertThrowsError(try convert("(x + 1"))
        XCTAssertThrowsError(try convert("mat(1, 2"))
    }

    func testIncompleteCallsThrow() {
        XCTAssertThrowsError(try convert("frac(1)"))
        XCTAssertThrowsError(try convert("root()"))
        XCTAssertThrowsError(try convert("sum k^2"))
        XCTAssertThrowsError(try convert("lim_(x) x"))
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
                .number(value: "1", approx: nil),
                .symbol("x"),
            ]))
        XCTAssertEqual(rendered, "J_1(x)")
        // The renderer's notation converts back to the engine's spelling.
        XCTAssertEqual(try convert(rendered), "BesselJ(1, x)")
    }

    func testCASRenderedSumRoundTrips() throws {
        let rendered = CASTypstRenderer.typst(
            .function(name: "sum", args: [
                .symbol("k"),
                .symbol("k"),
                .number(value: "1", approx: nil),
                .symbol("n"),
            ]))
        XCTAssertEqual(rendered, "sum_(k = 1)^(n) k")
        XCTAssertEqual(try convert(rendered), "sum(k, k, 1, n)")
    }
}
