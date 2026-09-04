import XCTest
@testable import TypstEdit
import CodeEditSourceEditor
import CodeEditTextView
import AppKit

final class InterestNoteReproTests: XCTestCase {
    @MainActor
    func testReproInterestNoteDeletion() throws {
        let noteURL = URL(fileURLWithPath: "Interest.note")
        guard let data = try? Data(contentsOf: noteURL),
              let fileContent = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read Interest.note from disk")
            return
        }

        let controller = EditorController()
        controller.currentFileURL = noteURL
        controller.sourceCode = fileContent

        // Create TextViewController using the same setup as SourceEditor
        let tvc = TextViewController(
            string: "",
            language: controller.highlightLanguage,
            configuration: controller.editorConfiguration,
            cursorPositions: [],
            coordinators: [controller.sourceEditorBridge]
        )
        tvc.loadView()
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = tvc.view
        tvc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        tvc.view.layoutSubtreeIfNeeded()

        controller.sourceEditorBridge.prepareCoordinator(controller: tvc)
        tvc.setText(fileContent)
        tvc.view.layoutSubtreeIfNeeded()
        tvc.textView.layoutManager.layoutLines()

        print("[REPRO] Initial string length: \(tvc.textView.string.count)")
        print("[REPRO] Initial line count: \(tvc.textView.layoutManager.lineCount)")
        print("[REPRO] Initial subviews count: \(tvc.textView.subviews.count)")

        let deletePrefix = """
        = Interest

        Variables:
        B is Balance 
        p is Principle
        i is Interest Rate
        t is Time (repayments as a continuous function)
        k is Pay Rate Increase
        r is Base Repayment Amount
        $B=p(1+i)^{t}+∑_{k=1}^
        """

        let deleteRange = (fileContent as NSString).range(of: deletePrefix)
        XCTAssertNotEqual(deleteRange.location, NSNotFound, "deletePrefix must exist in fileContent")

        // Select the range in the editor
        tvc.textView.selectionManager.setSelectedRange(deleteRange)

        // Perform deletion
        tvc.textView.deleteBackward(nil)

        // Process runloop
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        print("[REPRO] After deletion:")
        print("[REPRO] textView.string.count: \(tvc.textView.string.count)")
        print("[REPRO] lineCount: \(tvc.textView.layoutManager.lineCount)")
        print("[REPRO] textView.visibleRect: \(tvc.textView.visibleRect)")
        print("[REPRO] textView.frame: \(tvc.textView.frame)")
        print("[REPRO] gutterView.frame: \(tvc.gutterView.frame)")
        print("[REPRO] textView subviews count: \(tvc.textView.subviews.count)")

        print("[REPRO] lineStorage.length: \(tvc.textView.layoutManager.lineStorage.length)")
        print("[REPRO] lineStorage.height: \(tvc.textView.layoutManager.lineStorage.height)")
        print("[REPRO] lineStorage.count: \(tvc.textView.layoutManager.lineStorage.count)")
        print("[REPRO] lineStorage.first: \(String(describing: tvc.textView.layoutManager.lineStorage.first))")
        print("[REPRO] lineStorage.getLine(atOffset: 0): \(String(describing: tvc.textView.layoutManager.lineStorage.getLine(atOffset: 0)))")
        print("[REPRO] lineStorage.getLine(atPosition: 0.0): \(String(describing: tvc.textView.layoutManager.lineStorage.getLine(atPosition: 0.0)))")
        print("[REPRO] lineStorage.getLine(atPosition: 1.0): \(String(describing: tvc.textView.layoutManager.lineStorage.getLine(atPosition: 1.0)))")
        print("[REPRO] lineStorage.getLine(atIndex: 0): \(String(describing: tvc.textView.layoutManager.lineStorage.getLine(atIndex: 0)))")
        print("[REPRO] lineStorage.getLine(atIndex: 1): \(String(describing: tvc.textView.layoutManager.lineStorage.getLine(atIndex: 1)))")

        for (idx, line) in tvc.textView.layoutManager.lineStorage.enumerated().prefix(5) {
            print("[REPRO] iteration idx \(idx): yPos=\(line.yPos), range=\(line.range), height=\(line.height)")
        }

        let visibleLines = Array(tvc.textView.layoutManager.linesStartingAt(tvc.textView.visibleRect.minY, until: tvc.textView.visibleRect.maxY))
        print("[REPRO] visibleLines count from layoutManager: \(visibleLines.count)")

        XCTAssertFalse(visibleLines.isEmpty, "Visible lines should not be empty")
        XCTAssertGreaterThan(tvc.textView.subviews.count, 0, "TextView should have line fragment subviews")
    }
}
