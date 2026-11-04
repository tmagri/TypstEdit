import XCTest
import Combine
@testable import TypstEdit

/// Typing must not invalidate SwiftUI views, but programmatic edits must, so that `SourceEditor` pushes them
/// down to the text view. Every change is still reported through `sourceCodeDidChange`.
@MainActor
final class EditorControllerPublishingTests: XCTestCase {
    func testTextViewChangesDoNotSendObjectWillChange() {
        let controller = EditorController()
        var willChangeCount = 0
        let cancellable = controller.objectWillChange.sink { willChangeCount += 1 }

        controller.sourceCodeBinding.wrappedValue = "typed"
        var state = controller.editorState
        state.cursorPositions = [.init(range: NSRange(location: 5, length: 0))]
        controller.editorStateBinding.wrappedValue = state

        XCTAssertEqual(controller.sourceCode, "typed")
        XCTAssertEqual(controller.editorState.cursorPositions?.first?.range, NSRange(location: 5, length: 0))
        XCTAssertEqual(willChangeCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testProgrammaticChangesSendObjectWillChange() {
        let controller = EditorController()
        var willChangeCount = 0
        let cancellable = controller.objectWillChange.sink { willChangeCount += 1 }

        controller.sourceCode = "loaded"
        controller.editorState.findPanelVisible = true

        XCTAssertEqual(willChangeCount, 2)
        withExtendedLifetime(cancellable) {}
    }

    func testSourceCodeDidChangeIsCoalescedAndSendsLatestValue() {
        let controller = EditorController()
        var received: [String] = []
        let delivered = expectation(description: "change delivered")
        let cancellable = controller.sourceCodeDidChange.sink { value in
            received.append(value)
            delivered.fulfill()
        }

        controller.sourceCodeBinding.wrappedValue = "a"
        controller.sourceCodeBinding.wrappedValue = "ab"
        controller.sourceCode = "abc"

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(received, ["abc"])
        withExtendedLifetime(cancellable) {}
    }

    func testUnchangedTextIsNotReported() {
        let controller = EditorController()
        controller.sourceCode = "same"
        let settled = expectation(description: "initial change delivered")
        var cancellable = controller.sourceCodeDidChange.sink { _ in settled.fulfill() }
        wait(for: [settled], timeout: 2)

        var count = 0
        cancellable = controller.sourceCodeDidChange.sink { _ in count += 1 }
        controller.sourceCodeBinding.wrappedValue = "same"
        let drained = expectation(description: "run loop turn")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(count, 0)
        withExtendedLifetime(cancellable) {}
    }
}
