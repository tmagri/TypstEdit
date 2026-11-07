import XCTest
@preconcurrency import PDFKit
import AppKit
@testable import TypstEdit

/// Exercises the real PDFKit wiring behind the preview zoom controls.
/// The coordinator is what applies "Fit" to the `PDFView`, so this catches
/// the original bug: Fit only reset a SwiftUI value and never re-enabled
/// `autoScales`, leaving the preview at the manually scaled size.
@MainActor
final class PreviewViewCoordinatorTests: XCTestCase {

    private var window: NSWindow!
    private var views: [PDFView] = []

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    override func tearDown() async throws {
        views.forEach { $0.removeFromSuperview() }
        views.removeAll()
        window = nil
        try await super.tearDown()
    }

    /// Builds a laid-out PDFView showing a one-page PDF.
    private func makePDFView(coordinator: PreviewView.Coordinator) throws -> PDFView {
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        window.contentView = pdfView
        window.makeKeyAndOrderFront(nil)
        pdfView.layoutSubtreeIfNeeded()

        let document = try makePDF(pageSize: NSSize(width: 595, height: 842))
        pdfView.document = document
        pdfView.layoutSubtreeIfNeeded()
        views.append(pdfView)

        coordinator.startObservingScale(pdfView)
        coordinator.lastRequestedZoom = 0
        coordinator.enterFitMode(on: pdfView)
        return pdfView
    }

    private func makePDF(pageSize: NSSize) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("Could not create a PDF context")
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount > 0 else {
            throw XCTSkip("Could not build a PDFDocument")
        }
        return document
    }

    func testFitReEnablesAutoScalesAfterManualZoom() throws {
        let coordinator = PreviewView.Coordinator()
        let pdfView = try makePDFView(coordinator: coordinator)

        coordinator.applyZoomRequest(2.0, to: pdfView)
        XCTAssertFalse(pdfView.autoScales, "A manual zoom must own the scale")
        XCTAssertEqual(pdfView.scaleFactor, 2.0, accuracy: 0.001)

        coordinator.applyZoomRequest(0, to: pdfView)
        XCTAssertTrue(pdfView.autoScales, "Fit must hand scaling back to autoScales")
        XCTAssertNotEqual(pdfView.scaleFactor, 2.0, accuracy: 0.001,
                          "Fit must actually resize the page, not leave the manual zoom")
        XCTAssertEqual(pdfView.scaleFactor, pdfView.scaleFactorForSizeToFit, accuracy: 0.01)
    }

    func testFitKeepsWorkingWhenAlreadyFitted() throws {
        let coordinator = PreviewView.Coordinator()
        let pdfView = try makePDFView(coordinator: coordinator)
        XCTAssertTrue(pdfView.autoScales)

        // Clicking Fit twice must not break anything.
        coordinator.applyZoomRequest(0, to: pdfView)
        coordinator.applyZoomRequest(0, to: pdfView)
        XCTAssertTrue(pdfView.autoScales)
    }

    func testTwoViewsKeepIndependentScales() throws {
        let firstCoordinator = PreviewView.Coordinator()
        let secondCoordinator = PreviewView.Coordinator()
        let firstView = try makePDFView(coordinator: firstCoordinator)

        // A second view in its own window.
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        let secondView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        secondView.autoScales = true
        secondWindow.contentView = secondView
        secondView.layoutSubtreeIfNeeded()
        secondView.document = try makePDF(pageSize: NSSize(width: 595, height: 842))
        secondView.layoutSubtreeIfNeeded()
        views.append(secondView)
        secondCoordinator.startObservingScale(secondView)
        secondCoordinator.enterFitMode(on: secondView)

        let secondFitScale = secondView.scaleFactor

        firstCoordinator.applyZoomRequest(2.0, to: firstView)

        XCTAssertEqual(firstView.scaleFactor, 2.0, accuracy: 0.001)
        XCTAssertEqual(secondView.scaleFactor, secondFitScale, accuracy: 0.001,
                       "Scaling one preview must not change another window's preview")
        XCTAssertTrue(secondView.autoScales)

        addTeardownBlock { secondWindow.contentView = nil }
    }

    func testZoomRequestEchoDoesNotFightLiveGesture() throws {
        let coordinator = PreviewView.Coordinator()
        let pdfView = try makePDFView(coordinator: coordinator)

        // Simulate the pinch path: PDFKit already changed the scale.
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.5
        coordinator.lastRequestedZoom = 0

        coordinator.applyZoomRequest(1.5, to: pdfView)

        XCTAssertEqual(pdfView.scaleFactor, 1.5, accuracy: 0.001)
        XCTAssertFalse(pdfView.autoScales, "The user's zoom must survive the state echo")
    }
}
