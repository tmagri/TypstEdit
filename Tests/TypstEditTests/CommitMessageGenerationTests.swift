import XCTest
@testable import TypstEdit

/// AI commit messages: gathering the diff context (against real temporary
/// repositories), building the prompt, and cleaning the model's reply into a
/// safe commit message. The model call itself needs a provider, so only the
/// surrounding pieces are tested here.
@MainActor
final class CommitMessageGenerationTests: XCTestCase {

    private var ws: GitTestWorkspace!

    override func setUp() async throws {
        try await super.setUp()
        ws = GitTestWorkspace()
    }

    override func tearDown() async throws {
        ws.cleanup()
        ws = nil
        try await super.tearDown()
    }

    // MARK: Cleaning the reply

    func testCleanSubjectOnly() {
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage("Add export button"), "Add export button")
    }

    func testStripFencesAndPrefixAndQuotes() {
        let raw = """
        ```
        Commit message: Add export button

        - The toolbar had no way to export
        ```
        """
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage(raw),
                       "Add export button\n\n- The toolbar had no way to export")
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage(#"“Add export button”"#), "Add export button")
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage("Subject: Fix crash on open"), "Fix crash on open")
    }

    func testFillerLineIsDropped() {
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage("Here is a commit message:\n\nAdd export button"), "Add export button")
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage("Here's the message:\nAdd export button"), "Add export button")
    }

    func testHardWrappedSubjectIsJoinedUntilABodyLine() {
        let raw = """
        Add support for exporting documents to PDF and
        PNG with custom page sizes

        - The export sheet only offered fixed sizes
        """
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage(raw),
                       "Add support for exporting documents to PDF and PNG with custom page sizes\n\n- The export sheet only offered fixed sizes")
        // A body that starts with "- " is never glued onto the subject.
        let withBody = """
        Add export button
        - right side of the toolbar
        """
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage(withBody), "Add export button\n\n- right side of the toolbar")
    }

    func testBlankLinesCollapse() {
        XCTAssertEqual(SourceControlManager.cleanedCommitMessage("Add export button\n\n\n\n- Why\n\n\n- Why two"),
                       "Add export button\n\n- Why\n\n- Why two")
    }

    func testNothingUsableReturnsNil() {
        XCTAssertNil(SourceControlManager.cleanedCommitMessage("```"))
        XCTAssertNil(SourceControlManager.cleanedCommitMessage("  \n\n  "))
        XCTAssertNil(SourceControlManager.cleanedCommitMessage(""))
    }

    // MARK: The prompt

    func testPromptNamesTheScopeAndCarriesStatusAndDiff() {
        let context = (status: "M main.typ\n", diff: "--- a/main.typ\n+++ b/main.typ\n", scope: "staged changes")
        let (system, user) = SourceControlManager.commitMessagePrompt(context: context)
        XCTAssertTrue(system.contains("imperative mood"))
        XCTAssertTrue(system.contains("72"))
        XCTAssertTrue(user.contains("staged changes"))
        XCTAssertTrue(user.contains("M main.typ"))
        XCTAssertTrue(user.contains("--- a/main.typ"))
    }

    func testPromptWithoutDiffDescribesNewFiles() {
        let context = (status: "A new.typ\n", diff: "", scope: "all changes (nothing is staged)")
        let (_, user) = SourceControlManager.commitMessagePrompt(context: context)
        XCTAssertTrue(user.contains("no commit yet"), user)
        XCTAssertTrue(user.contains("A new.typ"))
        XCTAssertFalse(user.contains("\ndiff:\n"), user)
    }

    // MARK: Gathering the context (real repositories)

    func testCleanRepositoryHasNoContext() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("# Hello\n", to: "main.typ", in: repo)
        try await ws.commitAll("initial", in: repo)
        let context = try await SourceControlManager.commitContext(root: repo, runner: ws.runner, charLimit: 1_000)
        XCTAssertNil(context)
    }

    func testStagedChangeWinsOverUnstaged() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("# Hello\n", to: "main.typ", in: repo)
        try await ws.commitAll("initial", in: repo)
        try ws.write("# Hello\n# New section\n", to: "main.typ", in: repo)
        _ = try await ws.git(["add", "main.typ"], in: repo)
        try ws.write("# Hello\n# New section\n# More\n", to: "main.typ", in: repo)

        let raw = try await SourceControlManager.commitContext(root: repo, runner: ws.runner, charLimit: 10_000)
        let context = try XCTUnwrap(raw)
        XCTAssertEqual(context.scope, "staged changes")
        XCTAssertTrue(context.status.contains("M main.typ"))
        XCTAssertTrue(context.diff.contains("New section"))
        XCTAssertFalse(context.diff.contains("# More"))
    }

    func testUnstagedChangeFallsBackToEverything() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("# Hello\n", to: "main.typ", in: repo)
        try await ws.commitAll("initial", in: repo)
        try ws.write("# Hello\n# New section\n", to: "main.typ", in: repo)

        let raw = try await SourceControlManager.commitContext(root: repo, runner: ws.runner, charLimit: 10_000)
        let context = try XCTUnwrap(raw)
        XCTAssertEqual(context.scope, "all changes (nothing is staged)")
        XCTAssertTrue(context.diff.contains("New section"))
        // Untracked files are named in the status even though a diff can't show them.
        try ws.write("draft\n", to: "notes.txt", in: repo)
        let withUntracked = try await SourceControlManager.commitContext(root: repo, runner: ws.runner, charLimit: 10_000)
        XCTAssertTrue(try XCTUnwrap(withUntracked).status.contains("notes.txt"))
    }

    func testUnbornRepositoryUsesTheStagedDiff() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("# New document\n", to: "main.typ", in: repo)
        _ = try await ws.git(["add", "-A"], in: repo)

        let raw = try await SourceControlManager.commitContext(root: repo, runner: ws.runner, charLimit: 10_000)
        let context = try XCTUnwrap(raw)
        XCTAssertEqual(context.scope, "staged changes")
        XCTAssertTrue(context.diff.contains("New document"))
    }

    func testLargeDiffIsCapped() async throws {
        let repo = try await ws.makeRepo()
        let big = (1...4_000).map { "line \($0)" }.joined(separator: "\n")
        try ws.write(big, to: "main.typ", in: repo)
        _ = try await ws.git(["add", "-A"], in: repo)

        let raw = try await SourceControlManager.commitContext(root: repo, runner: ws.runner, charLimit: 500)
        let context = try XCTUnwrap(raw)
        XCTAssertLessThanOrEqual(context.diff.count, 600)
        XCTAssertTrue(context.diff.contains("diff truncated"), context.diff.suffix(200).description)
        XCTAssertTrue(context.status.contains("main.typ"))
    }
}
