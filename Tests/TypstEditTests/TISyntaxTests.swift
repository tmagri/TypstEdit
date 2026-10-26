import XCTest
@testable import TypstEdit

/// Tests for the TI-89 → giac input preprocessing and recall substitution.
final class TISyntaxTests: XCTestCase {

    func testStoreArrow() {
        XCTAssertEqual(TISyntax.preprocess("5->a"), "5►a")
        XCTAssertEqual(TISyntax.preprocess("5→a"), "5►a")
    }

    func testDerivativeAlias() {
        XCTAssertEqual(TISyntax.preprocess("d(x^2,x)"), "diff(x^2,x)")
        // A variable named d followed by a parenthesised product is left alone
        // unless it starts the call.
        XCTAssertEqual(TISyntax.preprocess("d*(x)"), "d*(x)")
        XCTAssertEqual(TISyntax.preprocess("ab*d(x,x)"), "ab*diff(x,x)")
    }

    func testSigmaAndPiTemplates() {
        XCTAssertEqual(TISyntax.preprocess("Σ(k^2,k,1,n)"), "sum(k^2,k,1,n)")
        XCTAssertEqual(TISyntax.preprocess("Π(k,k,1,4)"), "product(k,k,1,4)")
    }

    func testUnicodeOperators() {
        XCTAssertEqual(TISyntax.preprocess("x≥1"), "x>=1")
        XCTAssertEqual(TISyntax.preprocess("x≤1"), "x<=1")
        XCTAssertEqual(TISyntax.preprocess("x≠1"), "x!=1")
        XCTAssertEqual(TISyntax.preprocess("limit(1/x,x,∞)"), "limit(1/x,x,infinity)")
    }

    func testCasedCommands() {
        XCTAssertEqual(TISyntax.preprocess("cSolve(x^2+1=0,x)"), "csolve(x^2+1=0,x)")
        XCTAssertEqual(TISyntax.preprocess("nSolve(cos(x)=x,x)"), "fsolve(cos(x)=x,x)")
        XCTAssertEqual(TISyntax.preprocess("propFrac(x^2/(x+1),x)"), "propfrac(x^2/(x+1),x)")
        XCTAssertEqual(TISyntax.preprocess("delVar(a)"), "purge(a)")
        // giac already spells this one with a capital Z.
        XCTAssertEqual(TISyntax.preprocess("cZeros(x^2-1,x)"), "cZeros(x^2-1,x)")
    }

    func testDefineStatement() {
        XCTAssertEqual(TISyntax.preprocess("define f(x)=x^2"), "f(x):=x^2")
        XCTAssertEqual(TISyntax.preprocess("Define g(a,b)=a*b"), "g(a,b):=a*b")
    }

    func testAnsSubstitution() {
        let history = [
            CalculatorEntry(input: "solve(x^2-4=0,x)", resultPlain: "[x=-2,x=2]"),
            CalculatorEntry(input: "expand((x+1)(x+2))", resultPlain: "x^2+3*x+2"),
        ]
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "ans*2", history: history),
                       "x^2+3*x+2*2")
        // TI-89 numbering: ans(1) is the most recent result, ans(2) the one before.
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "ans(1)^2", history: history),
                       "x^2+3*x+2^2")
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "ans(2)^2", history: history),
                       "[x=-2,x=2]^2")
    }

    func testEntrySubstitution() {
        let history = [
            CalculatorEntry(input: "solve(x^2-4=0,x)", resultPlain: "[x=-2,x=2]"),
            CalculatorEntry(input: "factor(ans)", resultPlain: "[x-2,x+2]"),
        ]
        // entry(1) = most recent input, entry(2) = the one before it.
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "entry(1)", history: history),
                       "factor(ans)")
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "entry(2)", history: history),
                       "solve(x^2-4=0,x)")
    }

    func testRecallErrors() {
        XCTAssertThrowsError(try TISyntax.substituteRecalls(in: "ans", history: []))
        XCTAssertThrowsError(try TISyntax.substituteRecalls(
            in: "ans(5)",
            history: [CalculatorEntry(input: "1", resultPlain: "1")]))
    }

    func testAnsInsideFunctionIsNotReplacedTwice() {
        // ans(n) must be replaced as a numbered recall, not stripped by the
        // bare-ans rule afterwards.
        let history = [
            CalculatorEntry(input: "1+1", resultPlain: "2"),
            CalculatorEntry(input: "3+3", resultPlain: "6"),
        ]
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "ans(1)+ans(2)", history: history),
                       "6+2")
    }
}
