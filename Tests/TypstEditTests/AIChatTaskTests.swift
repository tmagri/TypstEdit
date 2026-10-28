import XCTest
@testable import TypstEdit

/// Pure formatting helpers used by the chat's live task rows: the running
/// tool's label and its elapsed time. The task lifecycle itself is driven by
/// the network-dependent agent loop and isn't covered here.
final class AIChatTaskTests: XCTestCase {

    func testElapsedLabelUsesMinutesAndPaddedSeconds() {
        XCTAssertEqual(AIChatManager.elapsedLabel(0), "0:00")
        XCTAssertEqual(AIChatManager.elapsedLabel(7), "0:07")
        XCTAssertEqual(AIChatManager.elapsedLabel(62), "1:02")
        XCTAssertEqual(AIChatManager.elapsedLabel(600), "10:00")
    }

    func testElapsedLabelTreatsNegativeIntervalsAsZero() {
        XCTAssertEqual(AIChatManager.elapsedLabel(-5), "0:00")
    }

    func testToolDisplayNameSplitsTheNamespace() {
        XCTAssertEqual(AIChatManager.toolDisplayName("project__read_file"), "project → read_file")
        XCTAssertEqual(AIChatManager.toolDisplayName("solo"), "solo")
    }
}
