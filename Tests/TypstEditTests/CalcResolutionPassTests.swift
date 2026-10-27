import XCTest
@testable import TypstEdit

/// Resolution of `#calc("…")`, `#calc-table(…)` and `calc-param(…)` in a
/// document source. Parsing is pure; evaluation needs the real CAS helper, so
/// those cases skip when `typstedit-cas` has not been built.
final class CalcResolutionPassTests: XCTestCase {

    private var settings = CalcResolutionSettings(
        angle: .radians, exactMode: .auto, digits: 12, timeout: 30)

    private func emptyState() -> (cache: [String: String], parameters: [CalculatorStoredVariable]) {
        ([:], [])
    }

    // MARK: - No-op paths (no CAS needed)

    func testSourceWithoutCallsIsUnchanged() async {
        let source = "= Title\n\n$E = m c^2$\n"
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            source,
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        XCTAssertEqual(result.outcome.output, source)
        XCTAssertTrue(result.outcome.diagnostics.isEmpty)
        XCTAssertTrue(result.outcome.parameters.isEmpty)
    }

    func testNeedsResolution() {
        XCTAssertTrue(CalcResolutionPass.needsResolution("#calc(\"1\")"))
        XCTAssertTrue(CalcResolutionPass.needsResolution("#calc-table(\"x\", x, 0, 1, 2)"))
        XCTAssertTrue(CalcResolutionPass.needsResolution("#let a = calc-param(1)"))
        XCTAssertFalse(CalcResolutionPass.needsResolution("= Plain document"))
    }

    // MARK: - Live CAS paths

    func testCalcCallResolvesToNumber() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            "Value: #calc(\"2^10\")\n",
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        XCTAssertEqual(result.outcome.output, "Value: 1024\n")
        XCTAssertTrue(result.outcome.diagnostics.isEmpty)
    }

    func testCalcCallWithSquareRootRendersMath() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            "#calc(\"sqrt(2)\")",
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        // sqrt(2) is irrational: forced decimal evaluation gives a number.
        XCTAssertTrue(result.outcome.output.contains("1.414"),
                      "unexpected: \(result.outcome.output)")
    }

    func testParametersAreExtractedAndSynced() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            "#let a = calc-param(2.5)\nValue: #calc(\"a*2\")\n",
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        XCTAssertEqual(result.outcome.parameters, [CalculatorStoredVariable(name: "a", value: "2.5")])
        XCTAssertEqual(result.outcome.output, "#let a = calc-param(2.5)\nValue: 5\n")
        XCTAssertEqual(result.storedParameters, result.outcome.parameters)
    }

    func testCalcTableProducesPointArray() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            "#plot(points: #calc-table(\"x^2\", x, 0, 2, 2), x-min: 0, x-max: 2)",
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        XCTAssertEqual(
            result.outcome.output,
            "#plot(points: ((0, 0), (1, 1), (2, 4)), x-min: 0, x-max: 2)")
        XCTAssertTrue(result.outcome.diagnostics.isEmpty)
    }

    func testCalcTableUsesDocumentParameter() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            "#let a = calc-param(2)\n#calc-table(\"a*x\", x, 0, 2, 2)",
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        XCTAssertTrue(result.outcome.output.contains("((0, 0), (1, 2), (2, 4))"),
                      "unexpected: \(result.outcome.output)")
    }

    func testFailuresBecomeAdvisoryWarnings() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            "#calc(\"2 +\")\n",
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        // The call stays in place and a warning explains why.
        XCTAssertEqual(result.outcome.output, "#calc(\"2 +\")\n")
        XCTAssertFalse(result.outcome.diagnostics.isEmpty)
        XCTAssertEqual(result.outcome.diagnostics.first?.severity, .warning)
        XCTAssertEqual(result.outcome.diagnostics.first?.line, 1)
    }

    func testSecondRunUsesCache() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let first = await CalcResolutionPass.resolve(
            "#calc(\"6*7\")\n",
            fileExtension: "typ",
            settings: settings,
            cache: [:],
            storedParameters: [])
        XCTAssertEqual(first.outcome.output, "42\n")
        XCTAssertFalse(first.cache.isEmpty)

        let second = await CalcResolutionPass.resolve(
            "#calc(\"6*7\")\n",
            fileExtension: "typ",
            settings: settings,
            cache: first.cache,
            storedParameters: first.storedParameters)
        XCTAssertEqual(second.outcome.output, "42\n")
    }

    func testSymbolicResultRendersAsMath() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let state = emptyState()
        let result = await CalcResolutionPass.resolve(
            "#calc(\"solve(x^2=4, x)\")\n",
            fileExtension: "typ",
            settings: settings,
            cache: state.cache,
            storedParameters: state.parameters)
        // Symbolic results become a math span so they typeset as math.
        XCTAssertTrue(result.outcome.output.contains("$"),
                      "unexpected: \(result.outcome.output)")
    }

    func testParametersDeclaredOnAnyLineAreFound() {
        // Regression: `^` without multiline mode only matched line 1, so a
        // parameter declared further down was silently unknown to the CAS.
        let parameters = CalcResolutionPass.extractParameters(from: """
        #set page(width: 10cm)
        = Title
          #let k = calc-param(2)
        text #let notaparam = 3
        #let rate = calc-param(0.05)
        """)
        XCTAssertEqual(parameters, [
            CalculatorStoredVariable(name: "k", value: "2"),
            CalculatorStoredVariable(name: "rate", value: "0.05"),
        ])
    }
}
