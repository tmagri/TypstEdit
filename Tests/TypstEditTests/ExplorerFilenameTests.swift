import XCTest
@testable import TypstEdit

/// Sidebar rows show a filename as wide as the panel allows. These cover the
/// pure width rule behind that: full name while it fits, otherwise the longest
/// head that keeps the extension (and any unsaved marker) visible.
final class ExplorerFilenameTests: XCTestCase {

    /// Roughly the filename area of a narrow side panel at 12pt: enough for a
    /// short name, not for a long one.
    private let narrowWidth: CGFloat = 140
    private let wideWidth: CGFloat = 600

    private func name(_ value: String, extension ext: String = "",
                      mark: String = "", width: CGFloat) -> String {
        ExplorerFilename.displayName(
            for: value, pathExtension: ext, trailingMark: mark,
            availableWidth: width, fontSize: 12
        )
    }

    func testShortNameIsNeverShortenedInAWidePanel() {
        XCTAssertEqual(name("main.typ", extension: "typ", width: wideWidth), "main.typ")
    }

    func testShortNameSurvivesANarrowPanel() {
        XCTAssertEqual(name("main.typ", extension: "typ", width: narrowWidth), "main.typ")
    }

    func testLongNameKeepsItsExtension() {
        let shown = name("DropFlyTimeAdjustmentPicture.tif", extension: "tif", width: narrowWidth)
        XCTAssertTrue(shown.hasSuffix(".tif"), "got \(shown)")
        XCTAssertTrue(shown.contains("…"), "expected an ellipsis, got \(shown)")
    }

    func testWiderPanelShowsMoreOfTheName() {
        let long = "DropFlyTimeAdjustmentPicture"
        let narrow = name("\(long).tif", extension: "tif", width: 120)
        let wide = name("\(long).tif", extension: "tif", width: 320)
        XCTAssertLessThan(narrow.count, wide.count)
        XCTAssertTrue(wide.hasPrefix("DropFlyTimeAd"))
    }

    func testFullNameAppearsOnceThePanelIsWideEnough() {
        let full = "DropFlyTimeAdjustmentPicture.tif"
        XCTAssertEqual(name(full, extension: "tif", width: wideWidth), full)
    }

    func testUnsavedMarkerSurvivesShortening() {
        let shown = name("DropFlyTimeAdjustmentPicture.tif", extension: "tif",
                         mark: "*", width: 120)
        XCTAssertTrue(shown.hasSuffix(".tif*"), "got \(shown)")
    }

    func testFolderWithoutExtensionIsShortenedWithoutADot() {
        let shown = name("DropFlyTimeAdjustmentPicture", width: 120)
        XCTAssertTrue(shown.hasSuffix("…") || shown.contains("…"), "got \(shown)")
        XCTAssertFalse(shown.contains(".."), "no doubled dot expected, got \(shown)")
    }

    func testUnmeasuredWidthLeavesTheNameWhole() {
        XCTAssertEqual(name("DropFlyTimeAdjustmentPicture.tif", extension: "tif", width: 0),
                       "DropFlyTimeAdjustmentPicture.tif")
    }

    func testExtensionThatIsNotASuffixIsTreatedAsPartOfTheName() {
        // A stale extension (name later saved as "archive.tar") must not be
        // appended on top of the whole name: no "archive.tar….gz".
        let shown = name("archive.tar", extension: "gz", width: 40)
        XCTAssertFalse(shown.contains(".tar"), "got \(shown)")
        XCTAssertTrue(shown.hasSuffix("…"), "got \(shown)")
    }
}
