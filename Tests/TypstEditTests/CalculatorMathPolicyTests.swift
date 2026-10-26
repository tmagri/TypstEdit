import XCTest
@testable import TypstEdit

/// The chat math tool must never become a general Giac execution surface.
final class CalculatorMathPolicyTests: XCTestCase {

    func testPermittedMathPasses() throws {
        let inputs = [
            "2+2",
            "solve(x^2-4=0,x)",
            "d(x^3,x)",
            "∫(x^2,x,0,1)",
            "det([[1,2][3,4]])",
            "[1,2;3,4]",
            "Σ(k,k,1,5)",
            "sin(pi/2)+ln(e)",
            "limit(sin(x)/x,x,0)",
            "x_1 + y2",
            "sqrt(2) < 3",
        ]
        for input in inputs {
            XCTAssertNoThrow(try CalculatorMathPolicy.prepare(input), input)
        }
    }

    func testPermittedMathKeepsTIForms() throws {
        XCTAssertEqual(try CalculatorMathPolicy.prepare("d(x^2,x)"), "diff(x^2,x)")
        XCTAssertEqual(try CalculatorMathPolicy.prepare("∫(x^2,x,0,1)"), "integrate(x^2,x,0,1)")
    }

    func testProgrammingFileAndShellCommandsAreRefused() {
        let blocked = [
            "eval(x)",
            "system(\"ls\")",
            "read(\"/etc/passwd\")",
            "write(1,2)",
            "cat(\"file\")",
            "map(sin,[1,2])",
            "apply(f,x)",
            "xcas_mode(0)",
            "digits(50)",
            "purge(a)",
            "1;2",
            "#include <stdio.h>",
        ]
        for input in blocked {
            XCTAssertThrowsError(try CalculatorMathPolicy.prepare(input), input) { error in
                XCTAssertTrue(error is CalculatorMathPolicy.Rejection, input)
            }
        }
    }

    func testStatefulAndQuotedSyntaxIsRefused() {
        let blocked = [
            "5→a",
            "\"text\"",
            "f:=x^2",
            "1+1 // trailing comment",
            "'quoted'",
        ]
        for input in blocked {
            XCTAssertThrowsError(try CalculatorMathPolicy.prepare(input), input)
        }
        // A plain `=` is an equation, not an assignment, and stays usable.
        XCTAssertNoThrow(try CalculatorMathPolicy.prepare("x=5"))
    }

    func testStatementSeparatorsAreRefusedOutsideMatrices() {
        XCTAssertNoThrow(try CalculatorMathPolicy.prepare("[1,2;3,4]"))
        XCTAssertThrowsError(try CalculatorMathPolicy.prepare("x=1;y=2"))
        XCTAssertThrowsError(try CalculatorMathPolicy.prepare("solve(x^2=4,x);2"))
    }

    func testMultiLetterVariablesAreRefused() {
        // A model retrying with a descriptive name must not smuggle a command.
        XCTAssertThrowsError(try CalculatorMathPolicy.prepare("totalCost*2"))
        // Single letters and numeric suffixes stay usable.
        XCTAssertNoThrow(try CalculatorMathPolicy.prepare("a*2+b"))
    }

    func testLimits() {
        XCTAssertThrowsError(try CalculatorMathPolicy.prepare(
            String(repeating: "1+", count: 3_000) + "1"))
        XCTAssertThrowsError(try CalculatorMathPolicy.prepare(
            String(repeating: "(", count: 70) + "1" + String(repeating: ")", count: 70)))
        XCTAssertThrowsError(try CalculatorMathPolicy.prepare("solve(x^2=4,x"))
        XCTAssertThrowsError(try CalculatorMathPolicy.prepare(""))
    }
}
