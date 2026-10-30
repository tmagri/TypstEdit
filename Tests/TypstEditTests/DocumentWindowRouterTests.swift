import XCTest
@testable import TypstEdit

/// Where an opened file goes when several document windows are open.
final class DocumentWindowRouterTests: XCTestCase {
    private typealias Slot = DocumentWindowRouter.Slot

    private func file(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testAlreadyOpenFileFocusesItsWindow() {
        let slots = [
            Slot(fileURL: file("/docs/a.typ"), isIdle: false, isKey: true, isMain: true),
            Slot(fileURL: file("/docs/b.typ"), isIdle: false, isKey: false, isMain: false),
        ]
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/b.typ"), in: slots), .focus(1))
        // Same file through a non-standard path.
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/../docs/./a.typ"), in: slots), .focus(0))
    }

    func testFocusWinsOverIdleWindow() {
        let slots = [
            Slot(fileURL: nil, isIdle: true, isKey: true, isMain: true),
            Slot(fileURL: file("/docs/b.typ"), isIdle: false, isKey: false, isMain: false),
        ]
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/b.typ"), in: slots), .focus(1))
    }

    func testIdleKeyWindowIsPreferredOverIdleMainWindow() {
        let slots = [
            Slot(fileURL: nil, isIdle: true, isKey: false, isMain: true),
            Slot(fileURL: nil, isIdle: true, isKey: true, isMain: false),
        ]
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/c.typ"), in: slots), .load(1))
    }

    func testIdleMainWindowIsUsedWhenKeyWindowIsBusy() {
        let slots = [
            Slot(fileURL: nil, isIdle: true, isKey: false, isMain: true),
            Slot(fileURL: file("/docs/b.typ"), isIdle: false, isKey: true, isMain: false),
        ]
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/c.typ"), in: slots), .load(0))
    }

    func testBusyWindowsGetANewWindow() {
        let slots = [
            Slot(fileURL: file("/docs/a.typ"), isIdle: false, isKey: true, isMain: true),
        ]
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/c.typ"), in: slots), .newWindow)
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/c.typ"), in: []), .newWindow)
    }

    func testClaimedIdleWindowIsNotReusedInTheSameBatch() {
        let slots = [Slot(fileURL: nil, isIdle: true, isKey: false, isMain: true)]
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/a.typ"), in: slots), .load(0))
        XCTAssertEqual(DocumentWindowRouter.destination(for: file("/docs/b.typ"), in: slots, claimed: [0]), .newWindow)
    }
}

/// The controller state behind the close, quit and file-switch prompts.
@MainActor
final class DocumentLifecycleTests: XCTestCase {

    func testDiscardUnsavedChangesStopsFurtherPrompts() {
        let controller = EditorController()
        controller.syncSavedContent("saved")
        controller.sourceCode = "edited"
        controller.checkUnsavedChanges(currentContent: controller.sourceCode)
        XCTAssertTrue(controller.hasUnsavedChanges)

        controller.discardUnsavedChanges()
        XCTAssertFalse(controller.hasUnsavedChanges)
        // The same text no longer counts as an edit.
        controller.checkUnsavedChanges(currentContent: controller.sourceCode)
        XCTAssertFalse(controller.hasUnsavedChanges)
        XCTAssertTrue(AppDelegate.isIdle(controller))
    }

    func testCloseDocumentLeavesAnIdleController() {
        let controller = EditorController()
        controller.syncSavedContent("text")
        controller.sourceCode = "changed"
        // No file yet, so no auto-recovery copy is written for the test.
        controller.checkUnsavedChanges(currentContent: controller.sourceCode)
        controller.currentFileURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).typ")
        controller.isFileDeletedOnDisk = true
        XCTAssertTrue(controller.hasUnsavedChanges)

        controller.closeDocument()

        XCTAssertNil(controller.currentFileURL)
        XCTAssertFalse(controller.hasUnsavedChanges)
        XCTAssertFalse(controller.isFileDeletedOnDisk)
        XCTAssertEqual(controller.sourceCode, "")
        XCTAssertTrue(AppDelegate.isIdle(controller))
    }

    func testNoteDiskStateFlagsAMissingFile() throws {
        let controller = EditorController()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString).typ")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        controller.noteDiskState(for: url)
        XCTAssertFalse(controller.isFileDeletedOnDisk)

        try FileManager.default.removeItem(at: url)
        controller.noteDiskState(for: url)
        XCTAssertTrue(controller.isFileDeletedOnDisk)
    }
}
