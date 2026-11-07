import XCTest
@testable import TypstEdit

/// PDF preview zoom is per window (`EditorController`), and "Fit" is a real
/// mode: `0` means autoScales, not a no-op on top of a manual scale.
@MainActor
final class PreviewZoomTests: XCTestCase {

    func testEachControllerHasItsOwnZoom() {
        let first = EditorController()
        let second = EditorController()

        first.pdfZoomIn()
        first.pdfZoomIn()

        XCTAssertGreaterThan(first.pdfZoomFactor, 0)
        XCTAssertEqual(second.pdfZoomFactor, 0, "Zooming one window must not change another")
    }

    func testFitClearsManualZoom() {
        let controller = EditorController()
        controller.pdfZoomIn()
        XCTAssertGreaterThan(controller.pdfZoomFactor, 0)

        controller.fitPDFToWindow()
        XCTAssertEqual(controller.pdfZoomFactor, 0, "Fit is requested as 0 (autoScales)")
    }

    func testZoomInFromFitStartsFromTheOnScreenScale() {
        let controller = EditorController()
        // A fitted page that fills ~60% of its natural size.
        controller.pdfEffectiveScale = 0.6

        controller.pdfZoomIn()

        XCTAssertEqual(controller.pdfZoomFactor, 0.6 * 1.2, accuracy: 0.0001,
                       "First step from Fit must scale what is on screen, not jump to 120%")
    }

    func testZoomInAndOutAreInverses() {
        let controller = EditorController()
        controller.pdfZoomIn()
        let zoomed = controller.pdfZoomFactor
        controller.pdfZoomOut()
        XCTAssertEqual(controller.pdfZoomFactor, zoomed / 1.2, accuracy: 0.0001)
    }

    func testZoomIsClamped() {
        let controller = EditorController()
        for _ in 0..<50 { controller.pdfZoomIn() }
        XCTAssertLessThanOrEqual(controller.pdfZoomFactor, 5.0)

        for _ in 0..<100 { controller.pdfZoomOut() }
        XCTAssertGreaterThanOrEqual(controller.pdfZoomFactor, 0.1)
    }

    func testFitButtonRelabelIsImmediate() {
        let controller = EditorController()
        controller.adjustPDFZoom(by: 2.0)
        XCTAssertGreaterThan(controller.pdfZoomFactor, 0)
        controller.fitPDFToWindow()
        XCTAssertEqual(controller.pdfZoomFactor, 0)
    }
}
