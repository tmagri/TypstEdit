import XCTest
@testable import TypstEdit

final class UnitConversionTests: XCTestCase {
    func testParsesCommonConversionsWithoutCapturingOrdinaryMath() throws {
        let length = try XCTUnwrap(UnitConversion.parse("5 kg to lb"))
        XCTAssertEqual(length.casInput, "convert(5*_kg,_lb)")
        XCTAssertEqual(length.value, "5 kg")
        XCTAssertEqual(length.target, "lb")

        let volume = try XCTUnwrap(UnitConversion.parse("212 mm x 174 mm x 90 mm in cubic metres"))
        XCTAssertEqual(volume.casInput, "convert(212*_mm*174*_mm*90*_mm,_m^3)")
        XCTAssertNil(UnitConversion.parse("solve(x^2-4=0,x)"))
        XCTAssertNil(UnitConversion.parse("10 ms"))
    }

    func testFormatsCASUnitResult() {
        let result = CASEvalResult(
            inputTree: nil,
            resultTree: .function(name: "_", args: [.vector([
                .number(value: "0.00331992", approx: nil),
                .operation(name: "^", args: [.symbol("_m"), .number(value: "3", approx: nil)]),
            ])]),
            resultText: "0.00331992_(m^3)",
            resultTypst: "",
            inputTypst: "",
            errorMessage: "",
            ok: true)
        XCTAssertEqual(UnitConversion.formatted(result), "0.00331992 m³")
    }
}

@MainActor
final class UnitConversionIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(CASEngine.isAvailable, "CAS helper not found")
    }

    func testCalculatorPanelEvaluatesUnitConversion() async {
        let session = CalculatorSession()
        await session.submit("212 mm x 174 mm x 90 mm in cubic metres")
        XCTAssertEqual(session.entries.last?.isError, false, session.entries.last?.errorMessage ?? "")
        XCTAssertEqual(session.entries.last?.resultPlain, "0.00331992 m³")
        XCTAssertEqual(session.entries.last?.resultTypst, "0.00331992 \"m³\"")
    }

    func testCalculatorToolEvaluatesUnitConversion() async throws {
        let output = try await CalculatorTool.evaluate(["expression": "5 kg to lb"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertTrue((json["result"] as? String)?.hasSuffix(" lb") == true)
        XCTAssertTrue((json["typst"] as? String)?.hasSuffix(" \"lb\"") == true)
    }

    func testCalculatorToolKeepsTheInputLimitForUnitRequests() async {
        do {
            _ = try await CalculatorTool.evaluate([
                "expression": String(repeating: "1 ", count: 2_100) + "kg to lb"
            ])
            XCTFail("Expected an overlong request to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("4096-byte limit"))
        }
    }
}
