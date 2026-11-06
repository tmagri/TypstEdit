import XCTest
import Foundation
@testable import TypstEdit

/// The calculator's plotting: the `plot(…)` entry line, the CAS sampling,
/// and the Typst code the chart offers the editor. Parsing and code
/// generation are pure; sampling needs the `typstedit-cas` helper.
final class CalculatorPlotTests: XCTestCase {

    // MARK: - Parsing

    func testNonPlotLinesParseAsNil() throws {
        XCTAssertNil(try TIPlot.parse("solve(x^2-4=0,x)"))
        XCTAssertNil(try TIPlot.parse("2+2"))
        XCTAssertNil(try TIPlot.parse("plotted(3)"))
        XCTAssertNil(try TIPlot.parse(""))
    }

    func testSingleCurveParse() throws {
        let call = try XCTUnwrap(try TIPlot.parse("plot(sin(x), x, -5, 5)"))
        XCTAssertEqual(call.expressions, ["sin(x)"])
        XCTAssertEqual(call.variable, "x")
        XCTAssertEqual(call.xMinText, "-5")
        XCTAssertEqual(call.xMaxText, "5")
    }

    func testMultiCurveParse() throws {
        let call = try XCTUnwrap(try TIPlot.parse("plot(sin(x), cos(x), x^2, x, -10, 10)"))
        XCTAssertEqual(call.expressions, ["sin(x)", "cos(x)", "x^2"])
        XCTAssertEqual(call.variable, "x")
    }

    func testParseIsCaseInsensitiveAndWhitespaceTolerant() throws {
        let call = try XCTUnwrap(try TIPlot.parse("  PLOT ( x+1 , t , 0 , 2 ) "))
        XCTAssertEqual(call.expressions, ["x+1"])
        XCTAssertEqual(call.variable, "t")
    }

    func testArgumentsSplitRespectNesting() throws {
        let call = try XCTUnwrap(try TIPlot.parse("plot(max(x,1)-min(x,0), x, 0, 1)"))
        XCTAssertEqual(call.expressions, ["max(x,1)-min(x,0)"])
        XCTAssertEqual(TIPlot.splitArguments("f(x, y), 2, [1, 2]"),
                       ["f(x, y)", "2", "[1, 2]"])
    }

    func testParseRejectsBadInput() {
        // Too few arguments.
        XCTAssertThrowsError(try TIPlot.parse("plot(sin(x), x)"))
        // Empty expression.
        XCTAssertThrowsError(try TIPlot.parse("plot(, x, 0, 1)"))
        // Equations cannot be drawn.
        XCTAssertThrowsError(try TIPlot.parse("plot(x^2-4=0, x, -3, 3)")) { error in
            XCTAssertTrue(String(describing: error).contains("solve"),
                          "the message should point at solve( for equations")
        }
        // "2x" is not a variable name.
        XCTAssertThrowsError(try TIPlot.parse("plot(x, 2x, 0, 1)"))
        // A plot cannot nest.
        XCTAssertThrowsError(try TIPlot.parse("plot(plot(x, x, 0, 1), x, 0, 1)"))
        // Missing closing parenthesis.
        XCTAssertThrowsError(try TIPlot.parse("plot(sin(x), x, 0, 1"))
    }

    func testTooManyCurvesIsRejected() {
        XCTAssertThrowsError(try TIPlot.parse("plot(1, 2, 3, 4, 5, x, 0, 1)"))
    }

    // MARK: - Bounds

    func testCheckedBoundsRejectsReversedAndNonFinite() {
        XCTAssertThrowsError(try TIPlot.checkedBounds(xMin: 1, xMax: -1))
        XCTAssertThrowsError(try TIPlot.checkedBounds(xMin: 2, xMax: 2))
        XCTAssertThrowsError(try TIPlot.checkedBounds(xMin: .nan, xMax: 1))
        XCTAssertEqual(try TIPlot.checkedBounds(xMin: -1, xMax: 1).xMax, 1)
    }

    // MARK: - Sampling input

    func testSamplingInputUsesOneSeqCall() {
        let input = TIPlot.casInput(expression: "sin(x)", variable: "x",
                                    xMin: -1, xMax: 1)
        // The TI `with` operator substitutes even when the plot variable has
        // a stored value; the parentheses keep `seq` from rejecting it.
        XCTAssertTrue(input.hasPrefix("seq((sin(x) | x = -1 + k*(2)/"),
            "PREFIX | input='\(input)'")
        XCTAssertTrue(input.hasSuffix("),k,0,\(TIPlot.sampleCount - 1))"),
            "SUFFIX | tail='\(String(input.suffix(12)))' pattern=),k,0,\(TIPlot.sampleCount - 1))")
    }

    func testLoopVariableAvoidsNamesUsedByTheExpression() {
        // A stored `k` must not be shadowed when the expression itself uses k.
        XCTAssertEqual(TIPlot.loopVariable(for: "k*x", plotVariable: "x"), "_plot_j")
        XCTAssertEqual(TIPlot.loopVariable(for: "sin(x)", plotVariable: "x"), "k")
        // When the plot variable is k, the loop name still differs.
        XCTAssertEqual(TIPlot.loopVariable(for: "k^2", plotVariable: "k"), "_plot_j")
    }

    func testSampleXsSpanTheRange() {
        let xs = TIPlot.sampleXs(xMin: -2, xMax: 2)
        XCTAssertEqual(xs.count, TIPlot.sampleCount)
        XCTAssertEqual(xs.first ?? 0, -2, accuracy: 1e-12)
        XCTAssertEqual(xs.last ?? 0, 2, accuracy: 1e-12)
    }

    // MARK: - Numbers and trees

    func testNumberParsing() {
        XCTAssertEqual(TIPlot.double("0.479425538604") ?? 0, 0.479425538604, accuracy: 1e-12)
        XCTAssertEqual(TIPlot.double("1e+13") ?? 0, 1e13, accuracy: 1)
        XCTAssertEqual(TIPlot.double("10000000") ?? 0, 1e7, accuracy: 1)
        XCTAssertEqual(TIPlot.double(".5") ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(TIPlot.double(" 2 ") ?? 0, 2, accuracy: 1e-12)
        XCTAssertNil(TIPlot.double("i"))
        XCTAssertNil(TIPlot.double("0.5*i"))
    }

    func testTreeValuesDeclineOnNonNumbers() {
        XCTAssertEqual(TIPlot.numericValue(.number(value: "2", approx: nil)) ?? 0, 2, accuracy: 1e-12)
        // The exact form is a fraction; the approximate form is preferred.
        XCTAssertEqual(TIPlot.numericValue(.number(value: "1/3", approx: "0.333333")) ?? 0,
                       0.333333, accuracy: 1e-6)
        // Complex values, constants and unevaluated calls decline (a gap).
        XCTAssertNil(TIPlot.numericValue(.operation(name: "*", args: [.number(value: "0.5", approx: nil), .constant("i")])))
        XCTAssertNil(TIPlot.numericValue(.constant("infinity")))
        XCTAssertNil(TIPlot.numericValue(.undefined))
        XCTAssertNil(TIPlot.numericValue(.function(name: "gamma", args: [.number(value: "-1", approx: nil)])))
    }

    // MARK: - TI expression → Typst code

    func testTypstCodeElementaryTranslations() {
        XCTAssertEqual(TIPlot.typstCodeExpression("sin(x)", variable: "x"), "calc.sin(x)")
        XCTAssertEqual(TIPlot.typstCodeExpression("x^2", variable: "x"), "calc.pow(x, 2)")
        XCTAssertEqual(TIPlot.typstCodeExpression("2x", variable: "x"), "2 * x")
        XCTAssertEqual(TIPlot.typstCodeExpression("x*sin(2*x)+1", variable: "x"),
                       "x * calc.sin(2 * x) + 1")
        XCTAssertEqual(TIPlot.typstCodeExpression("sqrt(x^2-1)", variable: "x"),
                       "calc.sqrt(calc.pow(x, 2) - 1)")
        // Giac's log is the natural logarithm.
        XCTAssertEqual(TIPlot.typstCodeExpression("log(x)", variable: "x"), "calc.ln(x)")
        XCTAssertEqual(TIPlot.typstCodeExpression("pi*x", variable: "x"), "calc.pi * x")
        XCTAssertEqual(TIPlot.typstCodeExpression("√(x)", variable: "x"), "calc.sqrt(x)")
        XCTAssertEqual(TIPlot.typstCodeExpression("-x^2", variable: "x"), "-calc.pow(x, 2)")
        XCTAssertEqual(TIPlot.typstCodeExpression("x!", variable: "x"), "calc.factorial(x)")
        XCTAssertEqual(TIPlot.typstCodeExpression("(x+1)*(x-1)", variable: "x"),
                       "(x + 1) * (x - 1)")
    }

    func testTypstCodeRegistryFunction() {
        // Registry names draw through the bridge's generic dispatcher.
        // (Skipped quietly if the functions.txt resource is not around.)
        guard !CalcPlugin.registryFunctions.isEmpty else { return }
        XCTAssertEqual(TIPlot.typstCodeExpression("erf(x)", variable: "x"),
                       "calc-call(\"erf\", x)")
        // Wrong arity declines — better the sampled-points form than a
        // document that fails to compile.
        XCTAssertNil(TIPlot.typstCodeExpression("erf(x, 1)", variable: "x"))
    }

    func testTypstCodeDeclinesUnknownNames() {
        // A free name that is neither the variable nor a constant.
        XCTAssertNil(TIPlot.typstCodeExpression("a*x", variable: "x"))
        // Complex numbers have no Typst code form.
        XCTAssertNil(TIPlot.typstCodeExpression("i*x", variable: "x"))
        // Unsupported characters and trailing tokens.
        XCTAssertNil(TIPlot.typstCodeExpression("x@y", variable: "x"))
        XCTAssertNil(TIPlot.typstCodeExpression("x)", variable: "x"))
        XCTAssertNil(TIPlot.typstCodeExpression("", variable: "x"))
    }

    // MARK: - Document code

    private let singleCurve = CalculatorPlotSpec(
        expressions: ["sin(x)"], variable: "x",
        xMin: -10, xMax: 10,
        curves: [[CalculatorPlotPoint(x: -10, y: 0.544),
                  CalculatorPlotPoint(x: 10, y: -0.544)]])

    private let multiCurve = CalculatorPlotSpec(
        expressions: ["sin(x)", "cos(x)"], variable: "x",
        xMin: -10, xMax: 10,
        curves: [[CalculatorPlotPoint(x: -10, y: 0.544)],
                 [CalculatorPlotPoint(x: -10, y: -0.839)]])

    func testCallbackCallSingleCurve() {
        let code = TIPlot.callbackCall(for: singleCurve)
        XCTAssertEqual(code, "#plot(x => calc.sin(x), -10, 10)")
    }

    func testCallbackCallMultiCurveHasLabels() throws {
        let code = try XCTUnwrap(TIPlot.callbackCall(for: multiCurve))
        XCTAssertTrue(code.hasPrefix("#plot(curves: ("))
        XCTAssertTrue(code.contains("(fn: x => calc.sin(x), label: [sin(x)]),"))
        XCTAssertTrue(code.contains("(fn: x => calc.cos(x), label: [cos(x)]),"))
        XCTAssertTrue(code.contains("x-min: -10, x-max: 10"))
    }

    func testDocumentCallPrefersSampledPoints() {
        // `documentCall` is the points form on purpose: it draws the exact
        // chart the calculator showed and cannot crash the document. A
        // callback like `x => calc.sin(x) / x` would divide by zero at the
        // pole when the document resamples it.
        let code = TIPlot.documentCall(for: singleCurve)
        XCTAssertTrue(code.contains("points: (("), code)
        XCTAssertTrue(code.contains("x-min: -10, x-max: 10"))
        // Even a curve that translates cleanly stays as points here.
        let callback = TIPlot.callbackCall(for: singleCurve)
        XCTAssertEqual(callback, "#plot(x => calc.sin(x), -10, 10)",
                       "the callback form stays available for deliberate use")
    }

    func testDocumentCallPointsOnlyForUnknownFunction() {
        // `foo` is neither a calc function nor a registry name: the callback
        // form declines and the call uses the exact sampled points.
        let spec = CalculatorPlotSpec(
            expressions: ["foo(x)"], variable: "x",
            xMin: 0, xMax: 2,
            curves: [[CalculatorPlotPoint(x: 0, y: 1),
                      CalculatorPlotPoint(x: 1, y: 2),
                      CalculatorPlotPoint(x: 2, y: 3)]])
        let code = TIPlot.documentCall(for: spec)
        XCTAssertTrue(code.contains("points: ((0, 1), (1, 2), (2, 3))"),
                      "points come from the sampled data: \(code)")
        XCTAssertFalse(code.contains("foo"))
    }

    func testPointsCallDownsamplesAndSkipsGaps() {
        var curve: [CalculatorPlotPoint] = []
        for i in 0..<TIPlot.sampleCount {
            curve.append(CalculatorPlotPoint(x: Double(i), y: Double(i) * 2))
        }
        curve[10].y = .nan
        let code = TIPlot.pointsCall(curve: curve, xMin: 0, xMax: 159)
        let pairCount = code.components(separatedBy: "), (").count + 1
        XCTAssertLessThanOrEqual(pairCount, 61, "the snippet stays readable: \(code)")
        XCTAssertFalse(code.contains("nan"), "gaps are not exported")
        XCTAssertTrue(code.contains("(159, 318)"), "the last point is kept")
        XCTAssertTrue(code.contains("x-min: 0, x-max: 159"))
    }

    func testMathLabelEscapesMarkup() {
        XCTAssertEqual(TIPlot.mathLabel("a_b*c"), "a\\_b\\*c")
        XCTAssertEqual(TIPlot.mathLabel("x[0]"), "x\\[0\\]")
    }

    func testNonTypstVariableNameFallsBackToPoints() {
        let spec = CalculatorPlotSpec(
            expressions: ["sin(θ)"], variable: "θ",
            xMin: -1, xMax: 1,
            curves: [[CalculatorPlotPoint(x: -1, y: 0)]])
        let code = TIPlot.documentCall(for: spec)
        XCTAssertTrue(code.contains("points: ("), "θ is not a Typst identifier: \(code)")
    }

    // MARK: - Sampling (real CAS helper)

    private func requireHelper() throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
    }

    private let engine = CASEngine()

    func testSampleOfSine() async throws {
        try requireHelper()
        let call = try XCTUnwrap(try TIPlot.parse("plot(sin(x), x, -pi, pi)"))
        let spec = try await TIPlot.sample(call, engine: engine,
                                           angle: .radians, digits: 12, timeout: 30)
        // Bounds written as expressions are resolved by the CAS.
        XCTAssertEqual(spec.xMin, -Double.pi, accuracy: 1e-9)
        XCTAssertEqual(spec.xMax, Double.pi, accuracy: 1e-9)
        XCTAssertEqual(spec.curves.count, 1)
        let curve = spec.curves[0]
        XCTAssertEqual(curve.count, TIPlot.sampleCount)
        // sin(-π) = sin(π) = 0, and the samples top out just under 1 (the
        // peak itself sits between two samples).
        XCTAssertEqual(curve.first?.y ?? 9, 0, accuracy: 1e-9)
        XCTAssertEqual(curve.last?.y ?? 9, 0, accuracy: 1e-9)
        XCTAssertEqual(curve.map(\.y).max() ?? 0, 1, accuracy: 0.01)
        XCTAssertFalse(curve.contains(where: { $0.y.isNaN }))
    }

    func testSampleOfSqrtOverNegativeHalfHasGaps() async throws {
        try requireHelper()
        // sqrt(x) has no real value for x < 0: giac answers complex numbers,
        // which draw as gaps.
        let call = try XCTUnwrap(try TIPlot.parse("plot(sqrt(x), x, -1, 1)"))
        let spec = try await TIPlot.sample(call, engine: engine,
                                           angle: .radians, digits: 12, timeout: 30)
        let curve = spec.curves[0]
        let gaps = curve.filter { $0.y.isNaN }.count
        let values = curve.filter { !$0.y.isNaN }
        XCTAssertGreaterThan(gaps, TIPlot.sampleCount / 3, "the negative half is gaps")
        XCTAssertLessThan(gaps, TIPlot.sampleCount * 2 / 3, "the positive half is real")
        XCTAssertEqual(values.last?.y ?? 9, 1, accuracy: 0.01)
    }

    func testSampleOfPoleKeepsRealValues() async throws {
        try requireHelper()
        // The sample grid never lands exactly on x = 0 here, so the points
        // near the pole keep their large real values; the chart's robust
        // y-scale keeps them from squashing the rest of the curve.
        let call = try XCTUnwrap(try TIPlot.parse("plot(1/x, x, -1, 1)"))
        let spec = try await TIPlot.sample(call, engine: engine,
                                           angle: .radians, digits: 12, timeout: 30)
        let curve = spec.curves[0]
        XCTAssertTrue(curve.contains(where: { abs($0.y) > 100 }),
                      "points near the pole keep their real values")
        XCTAssertTrue(curve.contains(where: { abs($0.y) < 1.1 }),
                      "points away from the pole stay small")
    }

    func testSampleOfConstant() async throws {
        try requireHelper()
        let call = try XCTUnwrap(try TIPlot.parse("plot(2, x, 0, 1)"))
        let spec = try await TIPlot.sample(call, engine: engine,
                                           angle: .radians, digits: 12, timeout: 30)
        XCTAssertTrue(spec.curves[0].allSatisfy { $0.y == 2 })
    }

    func testSampleKeepsStoredVariablesAndPlotVariableK() async throws {
        try requireHelper()
        // A stored value must reach the expression…
        _ = await engine.eval(input: TISyntax.preprocess("5►k"), approx: false,
                              angle: .radians, digits: 12, timeout: 10)
        let call = try XCTUnwrap(try TIPlot.parse("plot(k*x, x, 0, 2)"))
        let spec = try await TIPlot.sample(call, engine: engine,
                                           angle: .radians, digits: 12, timeout: 30)
        XCTAssertEqual(spec.curves[0].last?.y ?? 0, 10, accuracy: 1e-9,
                       "k = 5 at x = 2")
        // …and a curve over a name that is itself stored must still draw the
        // function over the range — the TI way — not a flat line at the
        // stored value.
        let kCall = try XCTUnwrap(try TIPlot.parse("plot(k^2, k, 0, 3)"))
        let kSpec = try await TIPlot.sample(kCall, engine: engine,
                                            angle: .radians, digits: 12, timeout: 30)
        XCTAssertEqual(kSpec.curves[0].first?.y ?? 0, 0, accuracy: 1e-9)
        XCTAssertEqual(kSpec.curves[0].last?.y ?? 0, 9, accuracy: 1e-9,
                       "k runs 0…3; the stored 5 must not flatten the curve")
        // The stored value survives the plot untouched.
        let stillStored = await engine.eval(input: "k", approx: false,
                                            angle: .radians, digits: 12, timeout: 10)
        XCTAssertEqual(stillStored.resultText, "5")
    }

    func testSampleOfUnknownNameFailsWithMessage() async throws {
        try requireHelper()
        // With an unknown name, the sample at x = 0 is genuinely 0 (the CAS
        // multiplies the free name away), so the point probe is what catches
        // the symbolic residue — a flat zero line would be a lie.
        let call = try XCTUnwrap(try TIPlot.parse("plot(nosuchname*x, x, 0, 1)"))
        do {
            _ = try await TIPlot.sample(call, engine: engine,
                                        angle: .radians, digits: 12, timeout: 30)
            XCTFail("an unknown name must fail the sample")
        } catch let error as TIPlotError {
            XCTAssertTrue(error.message.contains("nosuchname*x"),
                          "the message names the curve: \(error.message)")
            XCTAssertTrue(error.message.contains("stored value"),
                          "the message hints at the likely cause: \(error.message)")
        }
    }

    func testFreeSymbolDetection() {
        // A residue keeps the free name visible.
        XCTAssertTrue(TIPlot.containsFreeSymbol(
            .operation(name: "*", args: [.symbol("nosuchname"), .number(value: "0.5", approx: nil)])))
        // Numbers, poles and complex values are honest declines.
        XCTAssertFalse(TIPlot.containsFreeSymbol(.number(value: "2", approx: nil)))
        XCTAssertFalse(TIPlot.containsFreeSymbol(.constant("infinity")))
        XCTAssertFalse(TIPlot.containsFreeSymbol(
            .operation(name: "*", args: [.number(value: "0.7", approx: nil), .constant("i")])))
        XCTAssertFalse(TIPlot.containsFreeSymbol(.undefined))
        // A function name is not a free symbol, but its arguments are.
        XCTAssertFalse(TIPlot.containsFreeSymbol(
            .function(name: "gamma", args: [.number(value: "-1", approx: nil)])))
        XCTAssertTrue(TIPlot.containsFreeSymbol(
            .function(name: "f", args: [.symbol("t")])))
    }

    // MARK: - Session

    func testSessionEvaluatesPlotEntry() async throws {
        try requireHelper()
        let session = await MainActor.run { CalculatorSession() }
        await session.submit("plot(sin(x), x, -1, 1)")
        await session.submit("100+1")
        await MainActor.run {
            XCTAssertEqual(session.entries.count, 2)
            let plot = session.entries[0].plot
            XCTAssertNotNil(plot, "the plot entry carries its sampled chart")
            XCTAssertEqual(plot?.expressions, ["sin(x)"])
            XCTAssertEqual(plot?.curves[0].count, TIPlot.sampleCount)
            XCTAssertFalse(session.entries[0].isError)
            XCTAssertFalse(session.entries[0].resultPlain.isEmpty)
            // The plain evaluation after it is untouched.
            XCTAssertEqual(session.entries[1].resultPlain, "101")
            XCTAssertNil(session.entries[1].plot)
        }
    }

    func testSessionPlotErrorsBecomeErrorEntries() async throws {
        try requireHelper()
        let session = await MainActor.run { CalculatorSession() }
        // Bounds reversed: a plain plot error, never an AI detour.
        await session.submit("plot(x, x, 3, 1)")
        await MainActor.run {
            XCTAssertEqual(session.entries.count, 1)
            XCTAssertTrue(session.entries[0].isError)
            XCTAssertTrue(session.entries[0].errorMessage.contains("x-min"),
                          "\(session.entries[0].errorMessage)")
            XCTAssertNil(session.entries[0].plot)
        }
    }

    /// The AI path's plot interpretation: the model's `plot(…)` expression is
    /// sampled exactly like a typed one, with the prose kept as the AI
    /// answer. This is the sinc case from the bug report.
    func testAIPlotInterpretationDrawsAChart() async throws {
        try requireHelper()
        let interpretation = CalculatorAIFallback.Interpretation(
            expression: "plot(sin(x)/x, x, -10, 10)",
            typstMath: nil,
            answer: "The sinc function $sin(x)/x$ on $[-10, 10]$ has a central peak of height 1 at $x = 0$.")
        let session = await MainActor.run { CalculatorSession() }
        await session.submitPlotInterpretation(interpretation,
                                               input: "Plot a sinc function between -10 and 10",
                                               approx: false)
        await MainActor.run {
            XCTAssertEqual(session.entries.count, 1)
            let entry = session.entries[0]
            XCTAssertFalse(entry.isError, entry.errorMessage)
            let plot = try? XCTUnwrap(entry.plot)
            XCTAssertEqual(plot?.expressions, ["sin(x)/x"])
            XCTAssertEqual(plot?.xMin ?? 0, -10, accuracy: 1e-9)
            XCTAssertEqual(plot?.xMax ?? 0, 10, accuracy: 1e-9)
            // The central peak: sin(x)/x → 1 at x = 0, found near the middle.
            let middle = plot?.curves[0].map(\.y).max() ?? 0
            XCTAssertEqual(middle, 1, accuracy: 0.01)
            // The prose survives for the history and the export.
            XCTAssertTrue(entry.aiAnswer?.contains("sinc") ?? false)
        }
    }

    // MARK: - Persistence and export

    func testPlotEntryRoundTripsThroughTcalcFile() throws {
        var document = CalculatorDocument()
        document.entries = [singleCurveEntry()]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plot-\(UUID().uuidString).tcalc")
        try CalculatorDocument.save(document, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try CalculatorDocument.load(from: url)
        XCTAssertEqual(loaded.entries.first?.plot, singleCurve,
                       "the sampled points are cached with the entry")
    }

    func testOldTcalcFilesWithoutPlotsStillDecode() throws {
        // An entry written before plotting existed has no `plot` key.
        let json = """
        {
          "entries": [
            {
              "id": "C88BFC1E-2BF6-4F53-9A56-B0E28E93B11B",
              "input": "2+2",
              "approx": false,
              "resultTypst": "4",
              "resultPlain": "4",
              "inputTypst": "2 + 2",
              "isError": false,
              "errorMessage": "",
              "timestamp": 750000000.0
            }
          ],
          "kind": "typstedit.calculator.session",
          "version": 1
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).tcalc")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try CalculatorDocument.load(from: url)
        XCTAssertEqual(loaded.entries.first?.resultPlain, "4")
        XCTAssertNil(loaded.entries.first?.plot)
    }

    func testExportTurnsPlotsIntoPointsAndImportsTheBridge() {
        var document = CalculatorDocument()
        document.entries = [singleCurveEntry()]
        let exported = CalculatorExport.typst(sessionName: "Test", document: document)
        XCTAssertTrue(exported.contains("#import \"TypstEditCalcBridge.typ\": plot"))
        XCTAssertTrue(exported.contains("points: (("), exported)
        XCTAssertTrue(exported.contains("x-min: -10, x-max: 10"))
        // The comment keeps the input visible in the exported document.
        XCTAssertTrue(exported.contains("Chart: plot(sin(x), x, -10, 10)"))
    }

    func testExportWithoutPlotsAddsNoBridgeImport() {
        var document = CalculatorDocument()
        document.entries = [CalculatorEntry(input: "2+2", resultTypst: "4",
                                            resultPlain: "4", inputTypst: "2 + 2")]
        let exported = CalculatorExport.typst(sessionName: "Test", document: document)
        XCTAssertFalse(exported.contains("TypstEditCalcBridge"))
    }

    private func singleCurveEntry() -> CalculatorEntry {
        CalculatorEntry(
            input: "plot(sin(x), x, -10, 10)",
            resultPlain: singleCurve.summary,
            plot: singleCurve)
    }
}
