import XCTest
@testable import TypstEdit

/// End-to-end tests against the real `typstedit-cas` helper. Skipped when the
/// helper hasn't been built (run Tools/cas/build_cas.sh to build it), so CI
/// and quick local test runs stay green without the ~30 minute CAS build.
final class CASEngineTests: XCTestCase {

    private func eval(_ input: String,
                      approx: Bool = false,
                      angle: CASAngleMode = .radians) async -> CASEvalResult {
        await CASEngine.shared.eval(
            input: TISyntax.preprocess(input),
            approx: approx,
            angle: angle,
            digits: 12,
            timeout: 30)
    }

    func testHelperExistsOrSkip() throws {
        guard CASEngine.isAvailable else {
            throw XCTSkip("typstedit-cas not built — run Tools/cas/build_cas.sh")
        }
    }

    func testSolveQuadratic() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("helper not built") }
        let result = await eval("solve(x^2-4=0,x)")
        XCTAssertTrue(result.ok, "eval failed: \(result.errorMessage)")
        XCTAssertTrue(result.resultText.contains("-2"))
        XCTAssertTrue(result.resultText.contains("2"))
        // TI mode returns an or-node; its Typst rendering must be a relation.
        XCTAssertTrue(result.resultTypst.contains("-2"))
        XCTAssertTrue(result.resultTypst.contains("2"))
    }

    func testDefiniteIntegralExact() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("helper not built") }
        let result = await eval("∫(x^2,x,0,1)")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.resultText, "1/3")
        // The evaluated result is 1/3; the integral form is the input tree.
        XCTAssertEqual(result.resultTypst, "1/3")
        XCTAssertEqual(result.inputTypst, "integral_0^1 (x^2) dif x")
    }

    func testStoreAndReuse() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("helper not built") }
        _ = await eval("5→a")
        let result = await eval("a*2")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.resultText, "10")
        // Clean up so other tests see a fresh engine.
        await CASEngine.shared.reset()
    }

    func testComplexApproxSolveIsCleanUTF8() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("helper not built") }
        let result = await eval("cSolve(x^2+1=0,x)", approx: true)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.resultText.contains("i"))
        // giac's TI mode prints the approximate imaginary unit as byte 0xA1;
        // the helper must sanitize it.
        XCTAssertFalse(result.resultText.contains("\u{A1}"))
    }

    func testMatrixInputAndArithmetic() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("helper not built") }
        let cases: [(String, String)] = [
            ("[[1,2][3,4]]", "mat(1, 2; 3, 4)"),
            ("[1,2;3,4]", "mat(1, 2; 3, 4)"),
            ("[[1,2];[3,4]]", "mat(1, 2; 3, 4)"),
            ("2*[[1,2][3,4]]", "mat(2, 4; 6, 8)"),
            ("[[1,2][3,4]]+[[1,0][0,1]]", "mat(2, 2; 3, 5)"),
            ("[[1,2][3,4]]*[[2,0][0,2]]", "mat(2, 4; 6, 8)"),
            ("det([[1,2][3,4]])", "-2"),
            ("transpose([[1,2][3,4]])", "mat(1, 3; 2, 4)"),
            ("[[1,2][3,4]]^(-1)", "mat(-2, 1; 3/2, -1/2)"),
            ("rref([[1,2][3,4]])", "mat(1, 0; 0, 1)"),
            ("[[1,2]]", "mat(1, 2)"),
            ("[[1][2]]", "mat(1; 2)"),
            ("[[1]]", "mat(1)")
        ]
        for (input, expected) in cases {
            let result = await eval(input)
            XCTAssertTrue(result.ok, "\(input): \(result.errorMessage)")
            XCTAssertEqual(result.resultTypst, expected, input)
        }
    }

    func testStoredMatrixCanBeReused() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("helper not built") }
        let store = await eval("[[1,2][3,4]]→matrix_test")
        XCTAssertTrue(store.ok, store.errorMessage)
        XCTAssertEqual(store.resultTypst, "mat(1, 2; 3, 4)")
        let result = await eval("matrix_test*2")
        XCTAssertTrue(result.ok, result.errorMessage)
        XCTAssertEqual(result.resultTypst, "mat(2, 4; 6, 8)")
        _ = await eval("delVar(matrix_test)")
    }

    func testErrorPath() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("helper not built") }
        // giac's parser auto-closes truncation, so exercise the error path
        // with an empty request instead.
        let result = await eval("")
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.errorMessage.isEmpty)
    }
}
