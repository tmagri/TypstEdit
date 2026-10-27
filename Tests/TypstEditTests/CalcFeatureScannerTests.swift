import XCTest
@testable import TypstEdit

/// Detection of TypstEdit calculator features in a document, and the
/// portability policy that decides whether to warn.
final class CalcFeatureScannerTests: XCTestCase {

    // MARK: - Detection

    func testPlainDocumentHasNoFeatures() {
        let summary = CalcFeatureScanner.scan("= Title\n\nJust prose and $x^2$ math.\n")
        XCTAssertFalse(summary.usesAny)
        XCTAssertTrue(summary.featureNames.isEmpty)
        XCTAssertNil(summary.firstLine)
    }

    func testCalcCall() {
        let summary = CalcFeatureScanner.scan("Value: #calc(\"2^10\")\n")
        XCTAssertTrue(summary.usesCalcCall)
        XCTAssertTrue(summary.needsResolution)
        XCTAssertEqual(summary.lines, [1])
    }

    func testCalcTable() {
        let summary = CalcFeatureScanner.scan("#plot(points: #calc-table(\"sin(x)\", x, 0, 6.28, 40))")
        XCTAssertTrue(summary.usesCalcTable)
        XCTAssertTrue(summary.bridgeNames.contains("plot"))
        XCTAssertTrue(summary.needsResolution)
    }

    func testCalcParam() {
        let summary = CalcFeatureScanner.scan("#let a = calc-param(2.5)")
        XCTAssertTrue(summary.usesCalcParam)
        XCTAssertTrue(summary.needsResolution)
    }

    func testPlotOnlyNeedsBridgeButNoResolution() {
        let summary = CalcFeatureScanner.scan("#plot(x => BesselJ(0, x), 0, 10)")
        XCTAssertTrue(summary.bridgeNames.contains("plot"))
        XCTAssertTrue(summary.bridgeNames.contains("BesselJ"))
        XCTAssertFalse(summary.needsResolution, "plot/Bessel need the bridge but no CAS round-trip")
    }

    func testBridgeNamesAreDetected() {
        for name in ["BesselJ", "BesselY", "BesselI", "BesselK", "calc-gamma", "plot", "calc-call", "calc-fn"] {
            let summary = CalcFeatureScanner.scan("\(name)(1, 2)")
            XCTAssertTrue(summary.bridgeNames.contains(name), "\(name) should be detected")
            XCTAssertTrue(summary.usesAny)
        }
    }

    func testGenericCallIsDetected() {
        let summary = CalcFeatureScanner.scan("#calc-call(\"zeta\", 2)")
        XCTAssertTrue(summary.usesAny)
        XCTAssertTrue(summary.bridgeNames.contains("calc-call"))
    }

    func testLowercaseGiacSpellingsAreNotBridgeNames() {
        // `besselJ(x, p)` is Giac's spelling and only valid inside #calc("…").
        let summary = CalcFeatureScanner.scan("besselJ(2, 1)")
        XCTAssertFalse(summary.bridgeNames.contains("besselJ"))
    }

    func testSimilarNamesAreNotMatched() {
        let summary = CalcFeatureScanner.scan("my-plot(1) and replot(2) and calc-paramx(3)")
        XCTAssertFalse(summary.bridgeNames.contains("plot"))
        XCTAssertFalse(summary.usesCalcParam)
    }

    func testLineNumbersAreCollectedOnceAndSorted() {
        let source = """
        = Doc
        #calc("1+1")
        prose
        #calc("2+2")
        #plot(x => x, 0, 1)
        """
        let summary = CalcFeatureScanner.scan(source)
        XCTAssertEqual(summary.lines, [2, 4, 5])
        XCTAssertEqual(summary.firstLine, 2)
    }

    func testFeatureNamesAreStable() {
        let summary = CalcFeatureScanner.scan("#calc(\"1\") #let a = calc-param(1) #plot(x => BesselJ(0, x), 0, 1)")
        // Bridge names are sorted; the resolved-at-compile-time ones come first.
        XCTAssertEqual(summary.featureNames, ["#calc", "calc-param", "BesselJ", "plot"])
    }

    // MARK: - Portability policy

    func testTypstFilesAreWarned() {
        let summary = CalcFeatureScanner.scan("#plot(x => BesselJ(0, x), 0, 1)")
        let warning = CalcPortabilityPolicy.warning(summary: summary, fileExtension: "typ")
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.severity, .warning)
        XCTAssertEqual(warning?.line, 1)
        XCTAssertTrue(warning?.message.contains("not portable") ?? false)
        XCTAssertFalse(warning?.hints.isEmpty ?? true)
    }

    func testNoteFilesAreExempt() {
        let summary = CalcFeatureScanner.scan("#plot(x => BesselJ(0, x), 0, 1)")
        XCTAssertNil(CalcPortabilityPolicy.warning(summary: summary, fileExtension: "note"))
        XCTAssertFalse(CalcPortabilityPolicy.shouldWarn(fileExtension: "note"))
    }

    func testNoWarningWithoutFeatures() {
        let summary = CalcFeatureScanner.scan("= Plain")
        XCTAssertNil(CalcPortabilityPolicy.warning(summary: summary, fileExtension: "typ"))
    }

    // MARK: - Strings are CAS input, not Typst calls

    func testNamesInsideCalcStringsAreNotBridgeUsage() {
        let summary = CalcFeatureScanner.scan("#calc(\"BesselJ(0, 6) + plot(1)\")")
        XCTAssertTrue(summary.usesCalcCall)
        XCTAssertTrue(summary.bridgeNames.isEmpty, "\(summary.bridgeNames)")
        XCTAssertFalse(summary.needsBridge, "#calc alone resolves to a literal")
    }

    func testCalcParamNeedsTheBridge() {
        XCTAssertTrue(CalcFeatureScanner.scan("#let a = calc-param(1)").needsBridge)
    }

    func testMaskingKeepsOffsetsAndLines() {
        let source = "a \"x\\\"y\nz\" b"
        let masked = CalcFeatureScanner.maskingStringContents(source)
        XCTAssertEqual(masked.utf16.count, source.utf16.count)
        XCTAssertEqual(masked.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(masked.hasPrefix("a \""))
        XCTAssertTrue(masked.hasSuffix("\" b"))
    }
}
