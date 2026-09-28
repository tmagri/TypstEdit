import XCTest
@testable import TypstEdit

final class TabularImportTests: XCTestCase {

    @MainActor
    private func makeController() -> EditorController {
        EditorController()
    }

    // MARK: - TSV (tab-separated)

    @MainActor
    func testTSVWithHeader() {
        let controller = makeController()
        let input = "Name\tAge\tCity\nAlice\t30\tNYC\nBob\t25\tLA"
        let result = controller.importTabularData(from: input)

        XCTAssertEqual(result, .success(rows: 2, cols: 3))
        XCTAssertTrue(controller.useTableHeader)
        XCTAssertEqual(controller.tableHeaderCells, ["Name", "Age", "City"])
        XCTAssertEqual(controller.currentTableCells, ["Alice", "30", "NYC", "Bob", "25", "LA"])
        XCTAssertEqual(controller.tableEditInitialRows, 2)
        XCTAssertEqual(controller.tableEditInitialCols, 3)
    }

    // MARK: - CSV (comma-separated)

    @MainActor
    func testCSVWithHeader() {
        let controller = makeController()
        let input = "Name,Age\nAlice,30\nBob,25"
        let result = controller.importTabularData(from: input)

        XCTAssertEqual(result, .success(rows: 2, cols: 2))
        XCTAssertEqual(controller.tableHeaderCells, ["Name", "Age"])
        XCTAssertEqual(controller.currentTableCells, ["Alice", "30", "Bob", "25"])
        XCTAssertEqual(controller.tableEditInitialRows, 2)
        XCTAssertEqual(controller.tableEditInitialCols, 2)
    }

    // MARK: - Single row (header only)

    @MainActor
    func testSingleRowIsHeaderOnly() {
        let controller = makeController()
        let input = "Name\tAge"
        let result = controller.importTabularData(from: input)

        XCTAssertEqual(result, .success(rows: 0, cols: 2))
        XCTAssertEqual(controller.tableHeaderCells, ["Name", "Age"])
        XCTAssertEqual(controller.currentTableCells, [])
        XCTAssertEqual(controller.tableEditInitialRows, 0)
        XCTAssertEqual(controller.tableEditInitialCols, 2)
    }

    // MARK: - Ragged rows get padded to the widest column count

    @MainActor
    func testRaggedRowsArePadded() {
        let controller = makeController()
        let input = "A\tB\tC\n1\t2\n4\t5\t6"
        let result = controller.importTabularData(from: input)

        XCTAssertEqual(result, .success(rows: 2, cols: 3))
        XCTAssertEqual(controller.tableHeaderCells, ["A", "B", "C"])
        XCTAssertEqual(controller.currentTableCells, ["1", "2", "", "4", "5", "6"])
        XCTAssertEqual(controller.tableEditInitialCols, 3)
    }

    // MARK: - Non-tabular input

    @MainActor
    func testEmptyInput() {
        let controller = makeController()
        XCTAssertEqual(controller.importTabularData(from: ""), .emptyClipboard)
        XCTAssertEqual(controller.importTabularData(from: "   \n\t  "), .emptyClipboard)
    }

    @MainActor
    func testSingleWordIsNotATable() {
        let controller = makeController()
        XCTAssertEqual(controller.importTabularData(from: "hello"), .notATable)
    }

    @MainActor
    func testSingleLineSentenceIsNotATable() {
        // A lone line with a comma is not multi-line, so it is rejected.
        let controller = makeController()
        XCTAssertEqual(controller.importTabularData(from: "Hello, how are you"), .notATable)
    }

    @MainActor
    func testMultiLineProseIsNotATable() {
        // No delimiter present, so it is not tabular.
        let controller = makeController()
        XCTAssertEqual(controller.importTabularData(from: "Hello\nworld"), .notATable)
    }

    // MARK: - ensureTypstContent (cell bracketing)

    @MainActor
    func testPlainTextGetsBracketed() {
        let controller = makeController()
        XCTAssertEqual(controller.ensureTypstContent("Alice"), "[Alice]")
    }

    @MainActor
    func testAlreadyBracketedIsUnchanged() {
        let controller = makeController()
        XCTAssertEqual(controller.ensureTypstContent("[Alice]"), "[Alice]")
    }

    @MainActor
    func testNumberIsUnchanged() {
        let controller = makeController()
        XCTAssertEqual(controller.ensureTypstContent("30"), "30")
    }

    @MainActor
    func testHashExpressionIsUnchanged() {
        let controller = makeController()
        XCTAssertEqual(controller.ensureTypstContent("#text(red)[foo]"), "#text(red)[foo]")
    }

    @MainActor
    func testParentheticalTextStillGetsBracketed() {
        // Regression: a "(" in the middle of plain text is a literal character,
        // not a Typst expression, so the cell must still be wrapped in brackets.
        let controller = makeController()
        let cell = "DPK - Working Days (Off Peak Block Out) [Sun,Mon,Tue,Wed,Thu,Fri,Sat: 24 Hours]"
        XCTAssertEqual(
            controller.ensureTypstContent(cell),
            "[DPK - Working Days (Off Peak Block Out) [Sun,Mon,Tue,Wed,Thu,Fri,Sat: 24 Hours]]"
        )
    }
}
