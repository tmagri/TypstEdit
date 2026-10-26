import XCTest
@testable import TypstEdit

final class CalculatorHistoryTests: XCTestCase {
    func testEvaluationsAppendInChronologicalOrder() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("CAS helper not built") }
        let session = await MainActor.run { CalculatorSession() }
        await session.submit("100+1")
        await session.submit("100+2")
        await session.submit("100+3")
        await MainActor.run {
            XCTAssertEqual(session.entries.map(\.input), ["100+1", "100+2", "100+3"])
            XCTAssertEqual(session.entries.map(\.resultPlain), ["101", "102", "103"])
            XCTAssertFalse(session.entries.contains(where: \.isError))
            XCTAssertEqual(session.entries.last?.input, "100+3")
        }
    }

    func testInputErrorsAppendAtTheEndToo() async {
        let session = await MainActor.run { CalculatorSession() }
        // These fail during recall substitution, before calling the helper.
        await session.submit("ans(999)")
        await session.submit("entry(999)")
        await MainActor.run {
            XCTAssertEqual(session.entries.map(\.input), ["ans(999)", "entry(999)"])
            XCTAssertTrue(session.entries.allSatisfy(\.isError))
        }
    }

    func testArrowRecallStillStartsWithNewestEntry() async {
        await MainActor.run {
            let session = CalculatorSession()
            session.entries = [
                CalculatorEntry(input: "first"),
                CalculatorEntry(input: "second"),
                CalculatorEntry(input: "third")
            ]
            XCTAssertEqual(session.moveRecall(-1), "third")
            XCTAssertEqual(session.moveRecall(-1), "second")
            XCTAssertEqual(session.moveRecall(-1), "first")
            XCTAssertEqual(session.moveRecall(1), "second")
            XCTAssertEqual(session.moveRecall(1), "third")
            XCTAssertNil(session.moveRecall(1))
            // Recall navigation must not reverse the display/storage order.
            XCTAssertEqual(session.entries.map(\.input), ["first", "second", "third"])
        }
    }
}
