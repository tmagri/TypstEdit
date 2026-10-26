import XCTest
@testable import TypstEdit

/// Expected-output tests for the CAS tree → Typst math renderer. Every case
/// mirrors one shape the TI-89 home screen produces.
final class CASTypstRendererTests: XCTestCase {

    private func render(_ e: CASExpression) -> String {
        CASTypstRenderer.typst(e)
    }

    private func op(_ name: String, _ args: CASExpression...) -> CASExpression {
        .operation(name: name, args: args)
    }

    private func fn(_ name: String, _ args: CASExpression...) -> CASExpression {
        .function(name: name, args: args)
    }

    func testNumbers() {
        XCTAssertEqual(render(.number(value: "7", approx: nil)), "7")
        XCTAssertEqual(render(.number(value: "1/2", approx: "0.5")), "1/2")
        // Typst reads `-3/4` with the minus outside the fraction — the same
        // value, and how the TI-89 displays it.
        XCTAssertEqual(render(.number(value: "-3/4", approx: "-0.75")), "-3/4")
    }

    func testScientificNotation() {
        XCTAssertEqual(render(.number(value: "1.5e-7", approx: nil)), "1.5 times 10^(-7)")
        XCTAssertEqual(render(.number(value: "2E+12", approx: nil)), "2 times 10^(12)")
    }

    func testComplexNumber() {
        XCTAssertEqual(render(.number(value: "1+i", approx: nil)), "1+i")
    }

    func testSymbolsAndConstants() {
        XCTAssertEqual(render(.symbol("x")), "x")
        XCTAssertEqual(render(.constant("pi")), "pi")
        XCTAssertEqual(render(.constant("infinity")), "oo")
    }

    func testFractions() {
        let frac = op("/", .symbol("x"), .number(value: "2", approx: nil))
        XCTAssertEqual(render(frac), "x/2")
        let compound = op("/", op("+", .symbol("a"), .symbol("b")), .number(value: "2", approx: nil))
        XCTAssertEqual(render(compound), "(a + b)/2")
    }

    func testPowers() {
        XCTAssertEqual(render(op("^", .symbol("x"), .number(value: "2", approx: nil))), "x^2")
        XCTAssertEqual(render(op("^", op("+", .symbol("a"), .symbol("b")), .number(value: "2", approx: nil))),
                       "(a + b)^2")
        XCTAssertEqual(render(op("^", .symbol("x"), op("-", .number(value: "1", approx: nil)))),
                       "x^(-1)")
    }

    func testMultiplicationIsJuxtaposition() {
        XCTAssertEqual(render(op("*", .number(value: "2", approx: nil), .symbol("x"))), "2 x")
    }

    func testEquationAndSolutionSet() {
        let equation = op("=", op("^", .symbol("x"), .number(value: "2", approx: nil)),
                          .number(value: "4", approx: nil))
        XCTAssertEqual(render(equation), "x^2 = 4")
        let set = CASExpression.list([
            op("=", .symbol("x"), op("-", .number(value: "2", approx: nil))),
            op("=", .symbol("x"), .number(value: "2", approx: nil)),
        ])
        XCTAssertEqual(render(set), "{x = -2, x = 2}")
    }

    func testIntegral() {
        XCTAssertEqual(render(fn("integrate", .symbol("x"), .symbol("x"))),
                       "integral x dif x")
        // giac prints the ∫ head as the glyph itself.
        XCTAssertEqual(render(fn("∫", op("+", .symbol("x"), .number(value: "1", approx: nil)), .symbol("x"),
                                 .number(value: "0", approx: nil), .number(value: "1", approx: nil))),
                       "integral_0^1 (x + 1) dif x")
        XCTAssertEqual(render(fn("integrate",
                                 .op("+", .symbol("x"), .number(value: "1", approx: nil)),
                                 .symbol("x"),
                                 .number(value: "0", approx: nil),
                                 .number(value: "1", approx: nil))),
                       "integral_0^1 (x + 1) dif x")
    }

    func testDerivative() {
        XCTAssertEqual(render(fn("derivative", .symbol("f"), .symbol("x"))),
                       "(dif f)/(dif x)")
        XCTAssertEqual(render(fn("derivative", .symbol("f"), .symbol("x"), .number(value: "2", approx: nil))),
                       "(dif^(2) f)/(dif^(2) x)")
    }

    func testLimit() {
        XCTAssertEqual(render(fn("limit",
                                 .op("/", .fn("sin", .symbol("x")), .symbol("x")),
                                 .symbol("x"),
                                 .number(value: "0", approx: nil))),
                       "lim_(x -> 0) (sin(x)/x)")
        // One-sided limit from the right.
        XCTAssertEqual(render(fn("limit", .op("/", .number(value: "1", approx: nil), .symbol("x")),
                                 .symbol("x"), .number(value: "0", approx: nil),
                                 .number(value: "1", approx: nil))),
                       "lim_(x -> 0^+) (1/x)")
    }

    func testSum() {
        XCTAssertEqual(render(fn("sum", .symbol("k"), .symbol("k"),
                                 .number(value: "1", approx: nil), .symbol("n"))),
                       "sum_(k = 1)^(n) k")
    }

    func testSqrtAndExp() {
        XCTAssertEqual(render(fn("sqrt", .number(value: "2", approx: nil))), "sqrt(2)")
        XCTAssertEqual(render(fn("exp", .symbol("x"))), "e^(x)")
    }

    func testInverseTrigIsTILike() {
        XCTAssertEqual(render(fn("asin", .symbol("x"))), "sin^(-1)(x)")
    }

    func testVectorsAndMatrices() {
        let vector = CASExpression.vector([.symbol("a"), .symbol("b")])
        XCTAssertEqual(render(vector), "vec(a, b)")
        let matrix = CASExpression.vector([
            .vector([.number(value: "1", approx: nil), .number(value: "2", approx: nil)]),
            .vector([.number(value: "3", approx: nil), .number(value: "4", approx: nil)]),
        ])
        XCTAssertEqual(render(matrix), "mat(1, 2; 3, 4)")
    }

    func testSequence() {
        XCTAssertEqual(render(.sequence([.symbol("a"), .symbol("b"), .symbol("c")])), "a, b, c")
    }

    func testStore() {
        XCTAssertEqual(render(op(":=", .symbol("a"), .number(value: "5", approx: nil))),
                       "a \"≔\" 5")
    }
}

private extension CASExpression {
    static func op(_ name: String, _ args: CASExpression...) -> CASExpression {
        .operation(name: name, args: args)
    }

    static func fn(_ name: String, _ args: CASExpression...) -> CASExpression {
        .function(name: name, args: args)
    }
}
