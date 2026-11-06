import XCTest
@testable import TypstEdit

/// Where an opened project folder goes. A folder is open in one window only.
final class ProjectWindowRouterTests: XCTestCase {
    private typealias Slot = ProjectWindowRouter.Slot

    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    func testAlreadyOpenProjectFocusesItsWindow() {
        let slots = [
            Slot(projectRoot: folder("/work/a"), isIdle: false, isKey: true, isMain: true),
            Slot(projectRoot: folder("/work/b"), isIdle: false, isKey: false, isMain: false),
        ]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/b"), in: slots), .focus(1))
        // Same folder through a non-standard path, with or without a slash.
        XCTAssertEqual(ProjectWindowRouter.destination(for: URL(fileURLWithPath: "/work/x/../a"), in: slots), .focus(0))
    }

    func testFocusWinsOverEverythingElse() {
        let slots = [
            Slot(projectRoot: nil, isIdle: true, isKey: true, isMain: true, isPreferred: true),
            Slot(projectRoot: folder("/work/b"), isIdle: false, isKey: false, isMain: false),
        ]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/b"), in: slots), .focus(1))
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/b"), in: slots, forceNewWindow: true), .focus(1))
    }

    func testSubfolderIsADifferentProject() {
        let slots = [Slot(projectRoot: folder("/work/a"), isIdle: false, isKey: true, isMain: true)]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/a/sub"), in: slots), .newWindow)
        XCTAssertFalse(ProjectWindowRouter.isSameFolder(folder("/work/a"), folder("/work/a/sub")))
    }

    func testBusyWindowsGetANewWindow() {
        let slots = [
            Slot(projectRoot: folder("/work/a"), isIdle: false, isKey: true, isMain: true),
            Slot(projectRoot: nil, isIdle: false, isKey: false, isMain: false), // standalone file
        ]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/c"), in: slots), .newWindow)
    }

    func testIdleKeyWindowThenIdleMainWindow() {
        let keyIdle = [
            Slot(projectRoot: nil, isIdle: true, isKey: false, isMain: true),
            Slot(projectRoot: nil, isIdle: true, isKey: true, isMain: false),
        ]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/c"), in: keyIdle), .load(1))

        let mainIdle = [
            Slot(projectRoot: nil, isIdle: true, isKey: false, isMain: true),
            Slot(projectRoot: folder("/work/a"), isIdle: false, isKey: true, isMain: false),
        ]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/c"), in: mainIdle), .load(0))
    }

    func testPreferredWindowIsReplacedWhenTheFolderIsNotOpen() {
        let slots = [
            Slot(projectRoot: nil, isIdle: true, isKey: true, isMain: true),
            Slot(projectRoot: folder("/work/a"), isIdle: false, isKey: false, isMain: false, isPreferred: true),
        ]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/c"), in: slots), .load(1))
    }

    func testForceNewWindowSkipsIdleWindows() {
        let slots = [Slot(projectRoot: nil, isIdle: true, isKey: true, isMain: true)]
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/c"), in: slots, forceNewWindow: true), .newWindow)
    }

    func testNoWindowsOpensANewWindow() {
        XCTAssertEqual(ProjectWindowRouter.destination(for: folder("/work/c"), in: []), .newWindow)
    }
}

/// Each window's project state is its own.
@MainActor
final class ProjectContextIsolationTests: XCTestCase {

    func testEveryEditorHasItsOwnContext() {
        let first = EditorController()
        let second = EditorController()
        XCTAssertFalse(first.projectContext === second.projectContext)
        XCTAssertFalse(first.projectContext.rag === second.projectContext.rag)
        XCTAssertFalse(first.projectContext.chat === second.projectContext.chat)
        XCTAssertFalse(first.projectContext.mcp === second.projectContext.mcp)
        XCTAssertFalse(first.projectContext.skills === second.projectContext.skills)
        XCTAssertNotEqual(first.projectContext.instanceID, second.projectContext.instanceID)
    }

    func testProjectRootStaysInItsOwnWindow() throws {
        let rootA = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-a-\(UUID().uuidString)", isDirectory: true)
        let rootB = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let first = EditorController()
        let second = EditorController()
        first.projectRootURL = rootA
        second.projectRootURL = rootB

        XCTAssertEqual(first.projectContext.skills.projectRoot, rootA)
        XCTAssertEqual(second.projectContext.skills.projectRoot, rootB)
        XCTAssertEqual(first.projectContext.mcp.projectRoot, rootA)
        XCTAssertEqual(second.projectContext.mcp.projectRoot, rootB)

        // Closing one window's project leaves the other alone.
        first.projectRootURL = nil
        XCTAssertNil(first.projectContext.skills.projectRoot)
        XCTAssertEqual(second.projectContext.skills.projectRoot, rootB)
    }

    func testChatSessionsUseTheirWindowContext() {
        let controller = EditorController()
        let chat = controller.projectContext.chat
        XCTAssertTrue(chat.context === controller.projectContext)
        XCTAssertTrue(chat.activeManager.context === controller.projectContext)
        chat.startNewSession()
        XCTAssertTrue(chat.activeManager.context === controller.projectContext)
    }

    func testDetachedContextNeverTakesAProject() {
        ProjectContext.detached.setProjectRoot(URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(ProjectContext.detached.projectRoot)
    }

    func testShadowFileNamesAreNamespacedPerWindow() {
        XCTAssertEqual(TypstCompiler.shadowStem(for: "main.typ", namespace: nil), "main.typ.preview")
        XCTAssertEqual(TypstCompiler.shadowStem(for: "main.typ", namespace: "ab12"), "main.typ.ab12.preview")
        XCTAssertNotEqual(
            TypstCompiler.shadowStem(for: "main.typ", namespace: "aaaa"),
            TypstCompiler.shadowStem(for: "main.typ", namespace: "bbbb")
        )
    }

    func testScratchCleanupOnlyRemovesThatWindowsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["main.typ.aaaa.preview.typ", "main.typ.aaaa.preview.pdf", "main.typ.bbbb.preview.typ", "TypstEditCalc.wasm"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        TypstCompiler.cleanUpScratchFiles(in: dir, namespace: "aaaa")

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["TypstEditCalc.wasm", "main.typ.bbbb.preview.typ"])
    }

    private final class Counter {
        var count = 0
    }

    func testCompilerNotificationsCarryTheirSender() async throws {
        let mine = TypstCompiler()
        let other = TypstCompiler()
        let mineCount = Counter()
        let otherCount = Counter()
        let tokens = [
            NotificationCenter.default.addObserver(forName: .typstErrorsUpdated, object: mine, queue: nil) { _ in mineCount.count += 1 },
            NotificationCenter.default.addObserver(forName: .typstErrorsUpdated, object: other, queue: nil) { _ in otherCount.count += 1 },
        ]
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }

        other.setDiagnosticDocumentForTesting(fileName: "other.typ")
        other.feedWatchOutputForTesting("""
        compiling ...
        [10:00:00] compiled with errors
        error: unknown variable: v
          ┌─ other.typ:1:1
          │
        1 │ broken text
          │ ^

        """ + "\n")
        // The publish is debounced.
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertGreaterThan(otherCount.count, 0)
        XCTAssertEqual(mineCount.count, 0, "another window's compiler must not reach this window")
    }

    func testSidebarRefreshOverlap() {
        let root = URL(fileURLWithPath: "/work/a")
        XCTAssertTrue(SidebarView.overlaps(root, URL(fileURLWithPath: "/work/a/ch1.typ")))
        XCTAssertTrue(SidebarView.overlaps(URL(fileURLWithPath: "/work"), root))
        XCTAssertFalse(SidebarView.overlaps(root, URL(fileURLWithPath: "/work/ab")))
        XCTAssertFalse(SidebarView.overlaps(root, URL(fileURLWithPath: "/work/b")))
    }
}

/// Notes belong to the Notes window, and a chat history folder has one
/// writer at a time.
@MainActor
final class NotesAndChatOwnershipTests: XCTestCase {
    private typealias Slot = ProjectWindowRouter.Slot

    func testFileInsideAnOpenProjectFocusesThatWindow() {
        let slots = [
            Slot(projectRoot: URL(fileURLWithPath: "/notes"), isIdle: false, isKey: false, isMain: true),
            Slot(projectRoot: nil, isIdle: true, isKey: true, isMain: false),
        ]
        // Open Recent records a note's notebook folder as its "project".
        XCTAssertEqual(
            ProjectWindowRouter.destination(
                for: URL(fileURLWithPath: "/notes/Physics"),
                file: URL(fileURLWithPath: "/notes/Physics/a.note"),
                in: slots),
            .focus(0))
    }

    func testNotebookOpenedAsProjectIsNotTakenOverByTheNotesWindow() {
        let slots = [
            Slot(projectRoot: URL(fileURLWithPath: "/notes"), isIdle: false, isKey: false, isMain: true),
            Slot(projectRoot: nil, isIdle: true, isKey: true, isMain: false),
        ]
        XCTAssertEqual(
            ProjectWindowRouter.destination(
                for: URL(fileURLWithPath: "/notes/Physics"),
                file: URL(fileURLWithPath: "/notes/Physics/a.note"),
                in: slots,
                ignoringOwner: URL(fileURLWithPath: "/notes")),
            .load(1))
    }

    func testNotebookAlreadyOpenAsProjectIsFocused() {
        let slots = [
            Slot(projectRoot: URL(fileURLWithPath: "/notes"), isIdle: false, isKey: true, isMain: true),
            Slot(projectRoot: URL(fileURLWithPath: "/notes/Physics"), isIdle: false, isKey: false, isMain: false),
        ]
        XCTAssertEqual(
            ProjectWindowRouter.destination(
                for: URL(fileURLWithPath: "/notes/Physics"),
                file: URL(fileURLWithPath: "/notes/Physics/a.note"),
                in: slots,
                ignoringOwner: URL(fileURLWithPath: "/notes")),
            .focus(1))
    }

    func testDeepestOwningProjectWins() {
        let slots = [
            Slot(projectRoot: URL(fileURLWithPath: "/work"), isIdle: false, isKey: false, isMain: true),
            Slot(projectRoot: URL(fileURLWithPath: "/work/book"), isIdle: false, isKey: false, isMain: false),
        ]
        XCTAssertEqual(
            ProjectWindowRouter.destination(
                for: URL(fileURLWithPath: "/work/book/ch1"),
                file: URL(fileURLWithPath: "/work/book/ch1/a.typ"),
                in: slots),
            .focus(1))
    }

    func testContainsIsStrict() {
        XCTAssertTrue(ProjectWindowRouter.contains(URL(fileURLWithPath: "/notes"), URL(fileURLWithPath: "/notes/a/b.note")))
        XCTAssertFalse(ProjectWindowRouter.contains(URL(fileURLWithPath: "/notes"), URL(fileURLWithPath: "/notes")))
        XCTAssertFalse(ProjectWindowRouter.contains(URL(fileURLWithPath: "/notes"), URL(fileURLWithPath: "/notesextra/a.note")))
    }

    func testNotesAreRecognised() {
        let root = NotebookManager.shared.rootDirectory
        XCTAssertTrue(AppDelegate.isNote(root.appendingPathComponent("Physics/a.note")))
        XCTAssertFalse(AppDelegate.isNote(root))
        XCTAssertFalse(AppDelegate.isNote(URL(fileURLWithPath: "/tmp/a.note")))
    }

    func testSecondWindowOnTheSameChatFolderDoesNotSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = AIChatSessionStore()
        let second = AIChatSessionStore()
        first.updateContext(projectRoot: root, currentFileURL: nil)
        second.updateContext(projectRoot: root, currentFileURL: nil)

        XCTAssertTrue(first.ownsStorage)
        XCTAssertNil(first.storageNotice)
        XCTAssertFalse(second.ownsStorage)
        XCTAssertNotNil(second.storageNotice)

        // When the owner closes, the next window to open the scope may save.
        first.close()
        let third = AIChatSessionStore()
        third.updateContext(projectRoot: root, currentFileURL: nil)
        XCTAssertTrue(third.ownsStorage)
        third.close()
        second.close()
    }

    func testScopeWithoutStorageClaimsNothing() {
        let store = AIChatSessionStore()
        store.updateContext(projectRoot: nil, currentFileURL: URL(fileURLWithPath: "/tmp/loose.typ"))
        XCTAssertFalse(store.ownsStorage)
        XCTAssertNil(store.storageNotice)
    }
}
