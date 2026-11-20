import XCTest
@testable import TypstEdit

/// "Undo file changes": snapshots taken as the executor writes, and the
/// revert that puts files back. Each test works in its own temp folder.
final class FileRevertTests: XCTestCase {
    private var root: URL!
    private var store: FileSnapshotStore!
    private let sessionID = UUID()

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FileRevert-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        store = FileSnapshotStore(root: root.appendingPathComponent("snapshots"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func path(_ name: String) -> String {
        root.appendingPathComponent("files/\(name)").path
    }

    private func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: path(name)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Simulates what the executor + manager do for one write: change the
    /// file, keep its old bytes, and return the tool row that records it.
    private func change(_ name: String, to content: String, at date: Date = Date()) throws -> ChatMessage {
        let before = FileManager.default.contents(atPath: path(name))
        try Data(content.utf8).write(to: URL(fileURLWithPath: path(name)))
        var row = ChatMessage(role: .toolCall, toolName: "write_file", toolStatus: .succeeded)
        row.timestamp = date
        if let before {
            try store.save(before: before, sessionID: sessionID, toolCallID: row.id)
        }
        row.fileChanges = [FileChangeRecord(
            relativePath: name, absolutePath: path(name),
            existedBefore: before != nil, afterHash: FileRevert.sha256(Data(content.utf8))
        )]
        return row
    }

    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }

    /// Two turns: the first creates a.md, the second edits it and b.md.
    private func twoTurns() throws -> (messages: [ChatMessage], turn1: UUID, turn2: UUID) {
        try Data("b original".utf8).write(to: URL(fileURLWithPath: path("b.md")))
        let first = user("make a"), second = user("edit both")
        let messages = [
            first, try change("a.md", to: "a v1"), ChatMessage(role: .assistant, text: "done"),
            second, try change("a.md", to: "a v2"), try change("b.md", to: "b v2"),
        ]
        return (messages, first.id, second.id)
    }

    func testUndoingTheLastTurnRestoresEachFileToBeforeIt() throws {
        let (messages, _, turn2) = try twoTurns()
        let plan = FileRevert.plan(messages: messages, from: turn2)
        XCTAssertEqual(plan.entries.map(\.relativePath), ["a.md", "b.md"])
        XCTAssertTrue(FileRevert.changedSince(plan).isEmpty)

        let outcome = FileRevert.apply(plan, store: store, sessionID: sessionID)
        XCTAssertEqual(outcome.restored, ["a.md", "b.md"])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(read("a.md"), "a v1", "back to after turn 1, not before it")
        XCTAssertEqual(read("b.md"), "b original")
        XCTAssertEqual(outcome.revertedToolCallIDs.count, 2)
    }

    /// From an earlier turn, every later change goes too, and a file a tool
    /// created is removed rather than emptied.
    func testUndoingFromTheFirstTurnRemovesCreatedFiles() throws {
        let (messages, turn1, _) = try twoTurns()
        let plan = FileRevert.plan(messages: messages, from: turn1)
        XCTAssertEqual(plan.entries.first?.toolCallIDs.count, 2, "both changes to a.md")
        _ = FileRevert.apply(plan, store: store, sessionID: sessionID)
        XCTAssertNil(read("a.md"))
        XCTAssertEqual(read("b.md"), "b original")
    }

    func testOutsideEditsAreFlaggedBeforeUndo() throws {
        let (messages, _, turn2) = try twoTurns()
        try Data("user typed this".utf8).write(to: URL(fileURLWithPath: path("b.md")))
        let changed = FileRevert.changedSince(FileRevert.plan(messages: messages, from: turn2))
        XCTAssertEqual(changed.map(\.relativePath), ["b.md"])
    }

    /// A lost snapshot is reported; the file is left alone and its row is
    /// not marked undone, while the other files are still restored.
    func testMissingSnapshotFailsThatFileOnly() throws {
        let (messages, _, turn2) = try twoTurns()
        let plan = FileRevert.plan(messages: messages, from: turn2)
        store.removeAll(sessionID: sessionID)
        let outcome = FileRevert.apply(plan, store: store, sessionID: sessionID)
        XCTAssertEqual(outcome.failed.map(\.path), ["a.md", "b.md"])
        XCTAssertEqual(read("b.md"), "b v2", "untouched without its snapshot")
        XCTAssertTrue(outcome.revertedToolCallIDs.isEmpty)
    }

    /// A batch patch records every file it touched, and undoing puts each
    /// one back separately.
    func testABatchPatchIsOneRowWithManyFiles() throws {
        try Data("one".utf8).write(to: URL(fileURLWithPath: path("a.md")))
        let turn = user("patch both")
        var row = ChatMessage(role: .toolCall, toolName: "apply_patch", toolStatus: .succeeded)
        row.fileChanges = [
            FileChangeRecord(relativePath: "a.md", absolutePath: path("a.md"),
                             existedBefore: true, afterHash: FileRevert.sha256(Data("one new".utf8))),
            FileChangeRecord(relativePath: "b.md", absolutePath: path("b.md"),
                             existedBefore: false, afterHash: FileRevert.sha256(Data("created".utf8))),
        ]
        try store.save(before: Data("one".utf8), sessionID: sessionID, toolCallID: row.id)
        try Data("one new".utf8).write(to: URL(fileURLWithPath: path("a.md")))
        try Data("created".utf8).write(to: URL(fileURLWithPath: path("b.md")))
        let messages = [turn, row]

        let plan = FileRevert.plan(messages: messages, from: turn.id)
        XCTAssertEqual(plan.entries.map(\.relativePath), ["a.md", "b.md"])
        let outcome = FileRevert.apply(plan, store: store, sessionID: sessionID)
        XCTAssertEqual(outcome.restored, ["a.md", "b.md"])
        XCTAssertEqual(read("a.md"), "one")
        XCTAssertNil(read("b.md"), "a created file is removed")
    }

    /// A removal recorded with an empty after-hash is unchanged while the
    /// file stays gone, and flagged once something recreated it.
    func testADeletionStaysUndoableUntilTheFileComesBack() throws {
        let turn = user("delete it")
        var row = ChatMessage(role: .toolCall, toolName: "apply_patch", toolStatus: .succeeded)
        row.fileChanges = [FileChangeRecord(relativePath: "gone.md", absolutePath: path("gone.md"),
                                            existedBefore: true, afterHash: "")]
        try store.save(before: Data("was here".utf8), sessionID: sessionID, toolCallID: row.id)
        let messages = [turn, row]

        XCTAssertTrue(FileRevert.changedSince(FileRevert.plan(messages: messages, from: turn.id)).isEmpty,
                      "still deleted, so undo is offered without a warning")
        try Data("something else".utf8).write(to: URL(fileURLWithPath: path("gone.md")))
        XCTAssertEqual(FileRevert.changedSince(FileRevert.plan(messages: messages, from: turn.id)).count, 1,
                       "recreated, so the warning applies")
    }

    func testUndoButtonsOnlyOnTurnsThatChangedFiles() throws {
        let (messages, turn1, turn2) = try twoTurns()
        let third = user("just a question")
        let counts = FileRevert.undoableTurns(in: messages + [third, ChatMessage(role: .assistant, text: "ok")])
        XCTAssertEqual(counts[turn1], 2, "a.md and b.md from turn 1 on")
        XCTAssertEqual(counts[turn2], 2)
        XCTAssertNil(counts[third.id], "a turn without changes gets no button")
    }

    func testRevertedAndExpiredChangesAreNotOfferedAgain() throws {
        var (messages, _, turn2) = try twoTurns()
        for index in messages.indices where messages[index].fileChanges != nil {
            messages[index].fileChanges = messages[index].fileChanges?.map { record in
                var updated = record
                updated.isReverted = true
                return updated
            }
        }
        XCTAssertTrue(FileRevert.undoableTurns(in: messages).isEmpty)
        XCTAssertTrue(FileRevert.plan(messages: messages, from: turn2).isEmpty)

        let ask = user("x")
        let old = try change("c.md", to: "c", at: Date().addingTimeInterval(-FileRevert.retention - 60))
        XCTAssertTrue(FileRevert.plan(messages: [ask, old], from: ask.id).isEmpty)
        XCTAssertTrue(FileRevert.undoableTurns(in: [ask, old]).isEmpty)
    }

    /// Transcripts saved before undo existed still decode.
    func testOldTranscriptRowsDecodeWithoutFileChanges() throws {
        let json = #"{"id":"\#(UUID().uuidString)","role":"toolCall","text":"","timestamp":0,"isSubagent":false,"isCompacted":false,"isSummary":false}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.fileChanges)
    }

    func testPruneDropsOnlyOldSnapshots() throws {
        let keep = UUID(), drop = UUID()
        try store.save(before: Data("k".utf8), sessionID: sessionID, toolCallID: keep)
        try store.save(before: Data("d".utf8), sessionID: sessionID, toolCallID: drop)
        let dropURL = store.root.appendingPathComponent("\(sessionID.uuidString)/\(drop.uuidString).snapshot")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: dropURL.path)
        store.prune(olderThan: FileRevert.retention)
        XCTAssertNotNil(store.before(sessionID: sessionID, toolCallID: keep))
        XCTAssertNil(store.before(sessionID: sessionID, toolCallID: drop))
    }
}

/// The executor records what it changed — with the bytes from just before
/// the write — so the manager can snapshot them for undo.
@MainActor
final class ExecutorFileChangeTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TypstEditChangeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func executor() -> LocalToolExecutor {
        let executor = LocalToolExecutor()
        executor.scope = .project(root: folder)
        return executor
    }

    func testWriteRecordsCreationAndEditRecordsPriorBytes() async throws {
        let executor = executor()
        _ = try await executor.execute(
            toolName: "write_file",
            arguments: ["path": "n.md", "content": "one two"]
        ) { _ in true }
        let created = executor.drainRecordedFileChanges()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].relativePath, "n.md")
        XCTAssertNil(created[0].before, "a new file has nothing to restore")
        XCTAssertEqual(created[0].after.map { String(decoding: $0, as: UTF8.self) }, "one two")

        _ = try await executor.execute(
            toolName: "edit_file",
            arguments: ["path": "n.md", "old_string": "two", "new_string": "three"]
        ) { _ in true }
        let edited = executor.drainRecordedFileChanges()
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited[0].before.map { String(decoding: $0, as: UTF8.self) }, "one two")
        XCTAssertEqual(edited[0].after.map { String(decoding: $0, as: UTF8.self) }, "one three")
    }

    func testDeclinedWriteRecordsNothing() async throws {
        let executor = executor()
        _ = try? await executor.execute(
            toolName: "write_file",
            arguments: ["path": "no.md", "content": "x"]
        ) { _ in false }
        XCTAssertTrue(executor.drainRecordedFileChanges().isEmpty)
    }
}
