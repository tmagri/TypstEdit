import XCTest
@testable import TypstEdit

/// Round-trip tests for the `.tcalc` session file and the `.typ` export.
final class CalculatorDocumentTests: XCTestCase {

    private func sampleDocument() -> CalculatorDocument {
        CalculatorDocument(
            angle: .degrees,
            exactMode: .approx,
            displayDigits: 9,
            variables: [CalculatorStoredVariable(name: "a", value: "5")],
            entries: [
                CalculatorEntry(
                    input: "solve(x^2-4=0,x)",
                    approx: false,
                    resultTypst: "{x = -2, x = 2}",
                    resultPlain: "[x=-2,x=2]",
                    inputTypst: "solve(x^2 - 4 = 0, x)"),
                CalculatorEntry(
                    input: "5→a",
                    approx: false,
                    resultTypst: "5",
                    resultPlain: "5",
                    inputTypst: "5 \"≔\" a"),
                CalculatorEntry(
                    input: "1/0",
                    isError: true,
                    errorMessage: "Division by zero"),
            ])
    }

    func testRoundTrip() throws {
        let original = sampleDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calc-test-\(UUID().uuidString).tcalc")
        defer { try? FileManager.default.removeItem(at: url) }

        try CalculatorDocument.save(original, to: url)
        let loaded = try CalculatorDocument.load(from: url)

        XCTAssertEqual(loaded.kind, CalculatorDocument.documentKind)
        XCTAssertEqual(loaded, original)
    }

    func testLoadToleratesMissingKind() throws {
        let original = sampleDocument()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.sortedKeys]
        var untagged = original
        untagged.kind = ""
        untagged.version = 0
        let data = try encoder.encode(untagged)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calc-test-\(UUID().uuidString).tcalc")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try CalculatorDocument.load(from: url)
        XCTAssertEqual(loaded.entries.count, 3)
        XCTAssertEqual(loaded.angle, .degrees)
    }

    func testExportContainsEquations() {
        let exported = CalculatorExport.typst(
            sessionName: "My Calc",
            document: sampleDocument())

        XCTAssertTrue(exported.contains("= My Calc"))
        // Input = result lines for successful entries.
        XCTAssertTrue(exported.contains("$ solve(x^2 - 4 = 0, x) = {x = -2, x = 2} $"))
        // Error entries are skipped.
        XCTAssertFalse(exported.contains("Division by zero"))
        // Stored variables are listed.
        XCTAssertTrue(exported.contains("Stored variables"))
        XCTAssertTrue(exported.contains("a"))
    }

    func testInsertionFormats() {
        let entry = CalculatorEntry(
            input: "x^2",
            resultTypst: "x^2",
            resultPlain: "x^2",
            inputTypst: "x^2")

        XCTAssertEqual(CalculatorSession.inlineEquation(entry.resultTypst), "$x^2$")
        XCTAssertEqual(CalculatorSession.blockEquation(entry.resultTypst), "$ x^2 $")
        XCTAssertEqual(CalculatorSession.inputEqualsResult(entry), "$ x^2 = x^2 $")
    }
}
