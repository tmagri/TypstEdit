import XCTest
@testable import TypstEdit

/// The pure rules behind "Add to .gitignore" in the Git view: how a
/// repository-relative path becomes a rule, and how the rule is appended to
/// an existing `.gitignore` without duplicating or reformatting it.
final class GitIgnoreTests: XCTestCase {

    func testPatternIsAnchoredToTheRepositoryRoot() {
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "build/output.pdf", isDirectory: false),
            "/build/output.pdf"
        )
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "node_modules", isDirectory: true),
            "/node_modules/"
        )
    }

    func testPatternStripsLeadingSlashes() {
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "/tmp/logs", isDirectory: true),
            "/tmp/logs/"
        )
    }

    func testGlobCharactersAreEscaped() {
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "notes/[draft]*.md", isDirectory: false),
            "/notes/\\[draft]\\*.md"
        )
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "why?.txt", isDirectory: false),
            "/why\\?.txt"
        )
    }

    func testLeadingCommentAndNegationAreEscaped() {
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "#scratch", isDirectory: false),
            "/\\#scratch"
        )
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "!important", isDirectory: false),
            "/\\!important"
        )
    }

    func testBackslashIsEscapedOnce() {
        XCTAssertEqual(
            SourceControlManager.gitIgnorePattern(for: "a\\b", isDirectory: false),
            "/a\\\\b"
        )
    }

    func testAppendingAddsOneLineAndKeepsExistingContent() {
        XCTAssertEqual(
            SourceControlManager.appendingGitIgnorePattern("/build/", to: ""),
            "/build/\n"
        )
        XCTAssertEqual(
            SourceControlManager.appendingGitIgnorePattern("/build/", to: ".DS_Store"),
            ".DS_Store\n/build/\n"
        )
        XCTAssertEqual(
            SourceControlManager.appendingGitIgnorePattern("/build/", to: ".DS_Store\n"),
            ".DS_Store\n/build/\n"
        )
    }

    func testDuplicateRuleIsNotRepeated() {
        let existing = ".DS_Store\n/build/\n"
        XCTAssertEqual(
            SourceControlManager.appendingGitIgnorePattern("/build/", to: existing),
            existing
        )
    }
}

/// End-to-end checks against throwaway repositories: the rule is written to
/// the root `.gitignore` and already-tracked paths are untracked from the
/// index while staying on disk.
@MainActor
final class GitIgnoreWorkspaceTests: XCTestCase {

    private let ws = GitTestWorkspace()

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git not available")
        let probe = try? await ws.runner.runRaw(["--version"], in: FileManager.default.temporaryDirectory)
        try XCTSkipUnless(probe?.exitCode == 0, "git not usable (Command Line Tools missing?)")
    }

    override func tearDown() async throws {
        ws.cleanup()
        try await super.tearDown()
    }

    func testIgnoringTrackedFileWritesRuleAndUntracksIt() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("log\n", to: "logs/app.log", in: repo)
        try ws.write("keep\n", to: "keep.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        let manager = await ws.makeManager(root: repo)

        await manager.addToGitIgnore(path: "logs/app.log", isDirectory: false)
        XCTAssertNil(manager.errorMessage)

        XCTAssertEqual(try ws.read(".gitignore", in: repo), "/logs/app.log\n")
        XCTAssertTrue(ws.exists("logs/app.log", in: repo), "the file stays on disk")
        let tracked = try await ws.git(["ls-files", "--", "logs/app.log"], in: repo)
        XCTAssertTrue(tracked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // The untracking is staged, so it is visible as a deletion until the
        // next commit records that the path is no longer versioned.
        let change = try ws.change("logs/app.log", in: manager)
        XCTAssertEqual(change.indexStatus, "D")
    }

    func testIgnoringUntrackedFileHidesItFromChanges() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("keep\n", to: "keep.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        try ws.write("scratch\n", to: "scratch/notes.txt", in: repo)
        let manager = await ws.makeManager(root: repo)
        XCTAssertNotNil(manager.changes.first { $0.path == "scratch/notes.txt" })

        await manager.addToGitIgnore(path: "scratch/notes.txt", isDirectory: false)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try ws.read(".gitignore", in: repo), "/scratch/notes.txt\n")
        XCTAssertNil(manager.changes.first { $0.path == "scratch/notes.txt" }, "the ignored path disappears from Changes")
        XCTAssertTrue(ws.exists("scratch/notes.txt", in: repo))
    }

    func testIgnoringAFolderUntracksEverythingUnderIt() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("a\n", to: "build/a.txt", in: repo)
        try ws.write("b\n", to: "build/sub/b.txt", in: repo)
        try ws.write("keep\n", to: "keep.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        let manager = await ws.makeManager(root: repo)

        await manager.addToGitIgnore(path: "build", isDirectory: true)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try ws.read(".gitignore", in: repo), "/build/\n")
        let tracked = try await ws.git(["ls-files", "--", "build"], in: repo)
        XCTAssertTrue(tracked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(ws.exists("build/sub/b.txt", in: repo))
    }

    func testIgnoringIsIdempotent() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("keep\n", to: "keep.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        try ws.write("scratch\n", to: "scratch.txt", in: repo)
        let manager = await ws.makeManager(root: repo)

        await manager.addToGitIgnore(path: "scratch.txt", isDirectory: false)
        await manager.addToGitIgnore(path: "scratch.txt", isDirectory: false)

        XCTAssertEqual(try ws.read(".gitignore", in: repo), "/scratch.txt\n")
    }

    func testPathsStartingWithADashAreIgnoredSafely() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("keep\n", to: "keep.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        try ws.write("dash\n", to: "-dash.typ", in: repo)
        let manager = await ws.makeManager(root: repo)

        await manager.addToGitIgnore(path: "-dash.typ", isDirectory: false)

        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try ws.read(".gitignore", in: repo), "/-dash.typ\n")
        XCTAssertNil(manager.changes.first { $0.path == "-dash.typ" })
    }

    func testIgnoringGitignoreItselfIsRefused() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("keep\n", to: "keep.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        let manager = await ws.makeManager(root: repo)

        await manager.addToGitIgnore(path: ".gitignore", isDirectory: false)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(ws.exists(".gitignore", in: repo))
    }
}
