import XCTest
@testable import TypstEdit

/// The bounds on what one tool call can put into a conversation: the head is
/// returned inline and the full text is retained so `read_file` can reach the
/// rest, instead of the output being lost or flooding the context.
@MainActor
final class ToolOutputStoreTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolOutputStoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Summarize

    func testShortOutputIsUntouched() {
        let summary = ToolOutputStore.summarize("a\nb\nc\n")
        XCTAssertFalse(summary.truncated)
        XCTAssertEqual(summary.kept, "a\nb\nc\n")
        XCTAssertEqual(summary.totalLines, 3)
        XCTAssertEqual(summary.shownLines, 3)
    }

    func testTrailingNewlineIsNotAnExtraLine() {
        XCTAssertEqual(ToolOutputStore.summarize("a\nb\n").totalLines, 2)
        XCTAssertEqual(ToolOutputStore.summarize("a\nb").totalLines, 2)
    }

    func testTooManyLinesIsTruncated() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let summary = ToolOutputStore.summarize(text, maxLines: 4, maxBytes: 1_000_000)
        XCTAssertTrue(summary.truncated)
        XCTAssertEqual(summary.shownLines, 4)
        XCTAssertEqual(summary.totalLines, 10)
        XCTAssertEqual(summary.kept, "line 1\nline 2\nline 3\nline 4")
    }

    func testTooManyBytesStopsMidList() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        // Each line is 6 bytes plus its newline: "line 1\nline 2" is 13
        // bytes, and a third line would push it to 20, past the cap.
        let summary = ToolOutputStore.summarize(text, maxLines: 100, maxBytes: 14)
        XCTAssertTrue(summary.truncated)
        XCTAssertEqual(summary.shownLines, 2)
        XCTAssertEqual(summary.kept, "line 1\nline 2")
    }

    func testSingleOversizedLineKeepsNothingInline() {
        let text = String(repeating: "x", count: 100)
        let summary = ToolOutputStore.summarize(text, maxLines: 100, maxBytes: 10)
        XCTAssertTrue(summary.truncated)
        XCTAssertEqual(summary.shownLines, 0)
        XCTAssertEqual(summary.kept, "")
    }

    func testEmptyOutputIsUntouched() {
        let summary = ToolOutputStore.summarize("")
        XCTAssertFalse(summary.truncated)
        XCTAssertEqual(summary.kept, "")
    }

    // MARK: - Truncate

    func testOutputWithinLimitsIsReturnedAsIsWithNoFile() {
        let scope = LocalToolExecutor.Scope.project(root: workDir)
        XCTAssertEqual(ToolOutputStore.truncate("short", scope: scope, toolName: "run"), "short")
        XCTAssertNil(ToolOutputStore.directory(for: workDir).flatMap { directory in
            FileManager.default.fileExists(atPath: directory.path) ? directory : nil
        }, "no retained file should be written when nothing was cut")
    }

    func testTruncatedOutputNamesARetainedFileTheModelCanRead() throws {
        let scope = LocalToolExecutor.Scope.project(root: workDir)
        let text = (1...3_000).map { "line \($0)" }.joined(separator: "\n")

        let out = ToolOutputStore.truncate(text, scope: scope, toolName: "python-run")

        XCTAssertTrue(out.hasPrefix("line 1\n"), out)
        XCTAssertTrue(out.contains("showing lines 1-2000 of 3000"), out)
        XCTAssertTrue(out.contains("read_file"), out)
        XCTAssertFalse(out.contains("line 3000"), "the tail must not be inline")

        // The marker names a scope-relative path that resolves inside the
        // project, so the model's own read_file can open it.
        let reference = try XCTUnwrap(Self.reference(in: out))
        XCTAssertFalse(reference.hasPrefix("/"), "expected a scope-relative path, got \(reference)")
        let url = workDir.appendingPathComponent(reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "retained file missing at \(url.path)")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func testRetainedFilesLiveUnderTheHiddenChatFolder() throws {
        let scope = LocalToolExecutor.Scope.project(root: workDir)
        let text = (1...3_000).map { "line \($0)" }.joined(separator: "\n")

        let out = ToolOutputStore.truncate(text, scope: scope, toolName: "run")
        let reference = try XCTUnwrap(Self.reference(in: out))

        XCTAssertTrue(
            reference.hasPrefix(ProjectSettingsManager.dotFolderName + "/"),
            "retained output should live under .typstedit/, got \(reference)"
        )
        XCTAssertTrue(reference.contains("tool-output"), reference)
    }

    func testNoScopeStatesThatNothingCouldBeSaved() {
        let text = (1...3_000).map { "line \($0)" }.joined(separator: "\n")
        let out = ToolOutputStore.truncate(text, scope: .none, toolName: "run")
        XCTAssertTrue(out.contains("nowhere to save"), out)
        XCTAssertFalse(out.contains("read_file"), out)
    }

    func testFileStemIsSafeAndIdentifiesTheTool() {
        XCTAssertEqual(ToolOutputStore.fileStem(toolName: "run"), "tool_run")
        XCTAssertEqual(ToolOutputStore.fileStem(toolName: "github/search-code"), "tool_github-search-code")
        XCTAssertEqual(ToolOutputStore.fileStem(toolName: "???"), "tool_output")
        XCTAssertTrue(ToolOutputStore.fileStem(toolName: String(repeating: "a", count: 200)).count <= 50)
    }

    // MARK: - Pruning

    func testPruneRemovesOnlyStaleFiles() throws {
        let scope = LocalToolExecutor.Scope.project(root: workDir)
        let text = (1...3_000).map { "line \($0)" }.joined(separator: "\n")
        let out = ToolOutputStore.truncate(text, scope: scope, toolName: "run")
        let url = workDir.appendingPathComponent(try XCTUnwrap(Self.reference(in: out)))

        // Fresh: survives a prune.
        ToolOutputStore.pruneStale(scopeRoots: [workDir])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Aged past the retention window: removed.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 86_400)],
            ofItemAtPath: url.path
        )
        ToolOutputStore.pruneStale(scopeRoots: [workDir])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    /// Pulls the scope-relative path out of the truncation marker.
    private static func reference(in output: String) -> String? {
        guard let markerRange = output.range(of: "saved at ") else { return nil }
        let rest = output[markerRange.upperBound...]
        guard let end = rest.firstIndex(of: " ") ?? rest.firstIndex(of: "]") else { return nil }
        let path = String(rest[..<end])
        return path.isEmpty ? nil : path
    }
}
