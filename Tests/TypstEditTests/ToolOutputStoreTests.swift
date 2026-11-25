import XCTest
@testable import TypstEdit

/// The bounds on what one tool call can put into a conversation: the head is
/// returned inline and the full text is retained so `read_file` can reach the
/// rest, instead of the output being lost or flooding the context.
///
/// The store files to `~/Library/Logs/TypstEdit/Outputs` — beside the shell
/// jobs' logs, where Console.app can find them — and prunes opportunistically
/// on write. The tests redirect that folder through `directoryOverride` so
/// they never touch the user's real logs.
@MainActor
final class ToolOutputStoreTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolOutputStoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        ToolOutputStore.directoryOverride = workDir
    }

    override func tearDown() async throws {
        ToolOutputStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Clip

    func testShortOutputIsUntouched() {
        XCTAssertEqual(ToolOutputStore.clip("a\nb\nc\n", to: 1_000, label: "run"), "a\nb\nc\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("anything").path), "a short output must not be filed")
    }

    func testEmptyOutputIsUntouched() {
        XCTAssertEqual(ToolOutputStore.clip("", to: 1_000, label: "run"), "")
    }

    func testACutOutputKeepsItsHeadAndNamesTheSavedFile() throws {
        let text = (1...3_000).map { "line \($0)" }.joined(separator: "\n")
        let out = ToolOutputStore.clip(text, to: 200, label: "python-run")

        XCTAssertTrue(out.hasPrefix("line 1\n"), out)
        XCTAssertTrue(out.contains("showing the first 200 of \(text.count) characters"), out)
        XCTAssertTrue(out.contains("read_file"), out)
        XCTAssertTrue(out.contains("Do not re-run"), "the marker must never invite a re-run")
        XCTAssertFalse(out.contains("line 3000"), "the tail must not be inline")

        // The marker names a real file holding the whole text.
        let saved = try XCTUnwrap(Self.savedPath(in: out))
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), text)
        XCTAssertTrue(saved.hasPrefix(workDir.path))
    }

    func testASavedOutputsNameCarriesTheToolLabel() throws {
        let text = String(repeating: "x", count: 500)
        let out = ToolOutputStore.clip(text, to: 100, label: "python-run")
        let saved = try XCTUnwrap(Self.savedPath(in: out))
        XCTAssertTrue(URL(fileURLWithPath: saved).lastPathComponent.contains("python-run"))
    }

    func testAWriteThatCouldNotHappenSaysTheDataIsGone() throws {
        // A folder that cannot be created (a file in the way) makes the save
        // fail; the marker must not name a path that 404s.
        ToolOutputStore.directoryOverride = nil
        let blocked = workDir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocked)
        ToolOutputStore.directoryOverride = blocked

        let out = ToolOutputStore.clip(String(repeating: "y", count: 200), to: 50, label: "run")
        XCTAssertTrue(out.contains("could not be saved"), out)
        XCTAssertTrue(out.contains("not recoverable"), out)
        XCTAssertFalse(out.contains("read_file"), out)
    }

    func testPruneOldDeletesOnlyFilesPastRetention() throws {
        let old = workDir.appendingPathComponent("old.txt")
        let fresh = workDir.appendingPathComponent("fresh.txt")
        try Data("old".utf8).write(to: old)
        try Data("fresh".utf8).write(to: fresh)
        let stale = Date().addingTimeInterval(-(ToolOutputStore.retention + 60))
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: old.path)

        ToolOutputStore.pruneOld(in: workDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testSafeComponentRedactsHostileNames() {
        XCTAssertEqual(ToolOutputStore.safeComponent("a/b c..d"), "a-b-c-d")
        XCTAssertEqual(ToolOutputStore.safeComponent(""), "output")
        XCTAssertFalse(ToolOutputStore.safeComponent("../../etc/passwd").contains(".."))
    }

    // MARK: - Helpers

    /// The absolute path the marker points at: `saved to <path>.`
    private static func savedPath(in marker: String) -> String? {
        guard let range = marker.range(of: "saved to ") else { return nil }
        let rest = marker[range.upperBound...]
        guard let end = rest.range(of: ". Read it with") else { return nil }
        return String(rest[..<end.lowerBound])
    }
}
