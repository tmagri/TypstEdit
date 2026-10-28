import XCTest
@testable import TypstEdit

// MARK: - Pure parser tests

final class SourceControlParserTests: XCTestCase {

    private func nul(_ records: [String]) -> Data {
        Data(records.map { $0 + "\0" }.joined().utf8)
    }

    func testStatusV2ParsesHeadersAndAllEntryKinds() {
        let zeros = String(repeating: "0", count: 40)
        let hash = String(repeating: "a", count: 40)
        let data = nul([
            "# branch.oid \(hash)",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +3 -1",
            "1 M. N... 100644 100644 100644 \(hash) \(hash) dir/with space.typ",
            "1 .D N... 100644 100644 000000 \(hash) \(hash) gone.typ",
            "1 MM N... 100644 100644 100644 \(hash) \(hash) both.typ",
            "1 A. N... 000000 100644 100644 \(zeros) \(hash) -dash.typ",
            "2 R. N... 100644 100644 100644 \(hash) \(hash) R100 new name.typ",
            "old name.typ",
            "u UU N... 100644 100644 100644 100644 \(hash) \(hash) \(hash) conflict.typ",
            "? line\nbreak.typ",
            "? :(glob)*.typ",
            "! ignored.log",
        ])
        let status = GitOutputParser.parseStatusV2(data)
        XCTAssertEqual(status.headOID, hash)
        XCTAssertEqual(status.headBranch, "feature/x")
        XCTAssertEqual(status.upstream, "origin/feature/x")
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 1)
        XCTAssertFalse(status.isUnborn)

        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })
        XCTAssertEqual(status.changes.count, 8, "ignored entries are skipped")

        let spaced = try! XCTUnwrap(byPath["dir/with space.typ"])
        XCTAssertEqual(spaced.indexStatus, "M")
        XCTAssertEqual(spaced.worktreeStatus, " ")
        XCTAssertTrue(spaced.isStaged)
        XCTAssertFalse(spaced.isUnstaged)

        let gone = try! XCTUnwrap(byPath["gone.typ"])
        XCTAssertEqual(gone.worktreeStatus, "D")
        XCTAssertTrue(gone.isUnstaged)
        XCTAssertFalse(gone.isStaged)

        let both = try! XCTUnwrap(byPath["both.typ"])
        XCTAssertTrue(both.isStaged && both.isUnstaged)

        XCTAssertEqual(byPath["-dash.typ"]?.indexStatus, "A")

        let renamed = try! XCTUnwrap(byPath["new name.typ"])
        XCTAssertEqual(renamed.id, "new name.typ")
        XCTAssertEqual(renamed.originalPath, "old name.typ")
        XCTAssertEqual(renamed.indexStatus, "R")
        XCTAssertNil(byPath["old name.typ"], "orig path must not become its own entry")

        let conflict = try! XCTUnwrap(byPath["conflict.typ"])
        XCTAssertTrue(conflict.isConflicted)
        XCTAssertFalse(conflict.isStaged)
        XCTAssertEqual(conflict.statusLetter(for: .unstaged), "U")

        let newline = try! XCTUnwrap(byPath["line\nbreak.typ"])
        XCTAssertTrue(newline.isUntracked)
        XCTAssertEqual(newline.statusLetter(for: .unstaged), "?")
        XCTAssertNotNil(byPath[":(glob)*.typ"])
    }

    func testStatusV2UnbornAndDetached() {
        let unborn = GitOutputParser.parseStatusV2(nul(["# branch.oid (initial)", "# branch.head main"]))
        XCTAssertTrue(unborn.isUnborn)
        XCTAssertEqual(unborn.headBranch, "main")
        XCTAssertTrue(unborn.changes.isEmpty)

        let detached = GitOutputParser.parseStatusV2(nul(["# branch.oid abc", "# branch.head (detached)"]))
        XCTAssertTrue(detached.isDetached)
        XCTAssertNil(detached.headBranch)
    }

    func testStatusV2ToleratesGarbage() {
        let status = GitOutputParser.parseStatusV2(nul(["1 M.", "2 R. short", "zzz", ""]))
        XCTAssertTrue(status.changes.isEmpty)
    }

    func testParseLogWithParentsDecorationsAndOddSubject() {
        let sep = "\u{1F}"
        let h1 = String(repeating: "1", count: 40)
        let h2 = String(repeating: "2", count: 40)
        let h3 = String(repeating: "3", count: 40)
        let data = nul([
            [h1, "\(h2) \(h3)", "Ada Lovelace", "1700000000", "HEAD -> main, origin/main, tag: v1", "Merge \(sep) branch"].joined(separator: sep),
            [h2, "", "Bob", "1600000000", "", "root commit"].joined(separator: sep),
        ])
        let commits = GitOutputParser.parseLog(data)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].id, h1)
        XCTAssertEqual(commits[0].shortHash, "1111111")
        XCTAssertEqual(commits[0].parents, [h2, h3])
        XCTAssertEqual(commits[0].author, "Ada Lovelace")
        XCTAssertEqual(commits[0].refs, "HEAD -> main, origin/main, tag: v1")
        XCTAssertEqual(commits[0].subject, "Merge \(sep) branch", "subject is last field and kept intact")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(commits[1].parents, [])
        XCTAssertEqual(commits[1].refs, "")
    }

    func testParseBranchesAddsUnbornCurrentBranch() {
        let data = Data(" \0refs/heads/a\n*\0refs/heads/feature/b\n".utf8)
        let branches = GitOutputParser.parseBranches(data, currentBranch: "feature/b")
        XCTAssertEqual(branches.map(\.name), ["a", "feature/b"])
        XCTAssertEqual(branches.filter(\.isCurrent).map(\.name), ["feature/b"])

        let unborn = GitOutputParser.parseBranches(Data(), currentBranch: "main")
        XCTAssertEqual(unborn.map(\.name), ["main"])
        XCTAssertTrue(unborn[0].isCurrent)
    }

    func testNoRepositoryMessageDetection() {
        XCTAssertTrue(GitOutputParser.isNoRepositoryMessage("fatal: not a git repository (or any of the parent directories): .git"))
        XCTAssertFalse(GitOutputParser.isNoRepositoryMessage("fatal: detected dubious ownership in repository"))
    }
}

// MARK: - Integration tests against throwaway repositories

/// Every repository here lives in a fresh temporary directory; the user's
/// real repository and git configuration are never touched.
@MainActor
final class SourceControlTests: XCTestCase {

    private var tempDirs: [URL] = []

    private static let isolatedEnvironment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test User",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test User",
        "GIT_COMMITTER_EMAIL": "test@example.com",
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "init.defaultBranch",
        "GIT_CONFIG_VALUE_0": "main",
        "GIT_CONFIG_KEY_1": "commit.gpgsign",
        "GIT_CONFIG_VALUE_1": "false",
        // Belt and braces: no credential prompt of any kind can appear in
        // tests (git and ssh askpass both point at /bin/false, which exits 1).
        "GIT_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS_REQUIRE": "never",
    ]

    private let runner = GitRunner(environmentOverrides: SourceControlTests.isolatedEnvironment)

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git not available")
        let probe = try? await runner.runRaw(["--version"], in: FileManager.default.temporaryDirectory)
        try XCTSkipUnless(probe?.exitCode == 0, "git not usable (Command Line Tools missing?)")
    }

    override func tearDown() async throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: Fixture helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir.resolvingSymlinksInPath()
    }

    private func makeRepo(bare: Bool = false) async throws -> URL {
        let dir = try makeTempDir()
        _ = try await runner.run(bare ? ["init", "-q", "--bare"] : ["init", "-q"], in: dir)
        return dir
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) async throws -> String {
        try await runner.run(args, in: dir).stdoutString
    }

    private func write(_ text: String, to name: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeManager(root: URL) async -> SourceControlManager {
        let manager = SourceControlManager(runner: runner)
        // Never show a credential dialog from a test.
        manager.isAskpassEnabled = false
        await manager.setProjectRoot(root)
        return manager
    }

    private func change(_ path: String, in manager: SourceControlManager, file: StaticString = #filePath, line: UInt = #line) throws -> GitChange {
        try XCTUnwrap(manager.changes.first { $0.path == path }, "missing change for \(path); have \(manager.changes.map(\.path))", file: file, line: line)
    }

    private func samePath(_ a: URL?, _ b: URL) -> Bool {
        a?.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Repository detection

    func testNonRepositoryIsNotAnError() async throws {
        let dir = try makeTempDir()
        let manager = await makeManager(root: dir)
        XCTAssertNil(manager.repositoryRoot)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.changes.isEmpty)
        await manager.refresh()
        XCTAssertNil(manager.errorMessage, "explicit refresh of a non-repo is still not an error")

        await manager.initializeRepository()
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(samePath(manager.repositoryRoot, dir))
        XCTAssertEqual(manager.branch, "main")
        XCTAssertEqual(manager.branches.map(\.name), ["main"])
    }

    func testSubfolderDetectsParentRepositoryAndRootSwitching() async throws {
        let repo = try await makeRepo()
        try write("x", to: "chapters/one.typ", in: repo)
        let sub = repo.appendingPathComponent("chapters", isDirectory: true)
        let manager = await makeManager(root: sub)
        XCTAssertTrue(samePath(manager.repositoryRoot, repo))
        XCTAssertEqual(manager.changes.map(\.path), ["chapters/one.typ"], "paths are relative to the repo root")

        let other = try makeTempDir()
        await manager.setProjectRoot(other)
        XCTAssertNil(manager.repositoryRoot)
        XCTAssertTrue(manager.changes.isEmpty)
        XCTAssertEqual(manager.branch, "")

        await manager.setProjectRoot(nil)
        XCTAssertNil(manager.projectRoot)
        XCTAssertNil(manager.repositoryRoot)
    }

    func testRootSwitchDuringRefreshDoesNotLeakOldState() async throws {
        let repoA = try await makeRepo()
        try write("a", to: "a.typ", in: repoA)
        let plain = try makeTempDir()
        let manager = SourceControlManager(runner: runner)
        async let first: Void = manager.setProjectRoot(repoA)
        async let second: Void = manager.setProjectRoot(plain)
        _ = await (first, second)
        // Whichever ran last wins; the published state must match it.
        if samePath(manager.projectRoot, plain) {
            XCTAssertNil(manager.repositoryRoot)
            XCTAssertTrue(manager.changes.isEmpty)
        } else {
            XCTAssertTrue(samePath(manager.repositoryRoot, repoA))
        }
    }

    // MARK: Unborn HEAD

    func testUnbornStageUnstageDiffAndCommitWithTrickyNames() async throws {
        let repo = try await makeRepo()
        let names = ["-dash.typ", ":(glob)*.typ", "sp ace.typ", "line\nbreak.typ", "*.typ"]
        for name in names { try write("content of \(name)\n", to: name, in: repo) }

        let manager = await makeManager(root: repo)
        XCTAssertEqual(manager.branch, "main")
        XCTAssertTrue(manager.commits.isEmpty)
        XCTAssertEqual(Set(manager.changes.map(\.path)), Set(names))
        XCTAssertTrue(manager.changes.allSatisfy { $0.isUntracked && $0.isUnstaged })

        // Untracked diff.
        let untrackedDiff = try await manager.diff(for: try change("sp ace.typ", in: manager), group: .unstaged)
        XCTAssertTrue(untrackedDiff.contains("+content of sp ace.typ"), untrackedDiff)

        // Staging one magic-looking name must not stage the others.
        await manager.stage(try change("*.typ", in: manager))
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(try change("*.typ", in: manager).isStaged)
        XCTAssertTrue(try change("-dash.typ", in: manager).isUntracked, "'*.typ' must be literal")

        for name in names { await manager.stage(try change(name, in: manager)) }
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.changes.allSatisfy { $0.isStaged && $0.indexStatus == "A" && !$0.isUnstaged })

        // Staged diff against the empty tree before the first commit.
        let stagedDiff = try await manager.diff(for: try change("-dash.typ", in: manager), group: .staged)
        XCTAssertTrue(stagedDiff.contains("new file mode"), stagedDiff)
        XCTAssertTrue(stagedDiff.contains("+content of -dash.typ"), stagedDiff)
        XCTAssertFalse(stagedDiff.contains("sp ace"), "diff is limited to the one path")

        // Unstage without a HEAD.
        await manager.unstage(try change(":(glob)*.typ", in: manager))
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(try change(":(glob)*.typ", in: manager).isUntracked)
        XCTAssertTrue(try change("*.typ", in: manager).isStaged, "unstaging a magic name leaves others staged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(":(glob)*.typ").path))

        await manager.unstageAll()
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.changes.allSatisfy(\.isUntracked))

        await manager.stageAll()
        let committed = await manager.commit(message: "-initial commit\n\nbody")
        XCTAssertTrue(committed, manager.errorMessage ?? "")
        XCTAssertTrue(manager.changes.isEmpty)
        XCTAssertEqual(manager.commits.count, 1)
        XCTAssertEqual(manager.commits.first?.subject, "-initial commit")
        XCTAssertTrue(manager.commits.first?.refs.contains("main") ?? false)
        XCTAssertEqual(manager.commits.first?.parents, [])
    }

    func testCommitRejectsEmptyMessageAndNothingStaged() async throws {
        let repo = try await makeRepo()
        try write("x", to: "a.typ", in: repo)
        let manager = await makeManager(root: repo)
        let empty = await manager.commit(message: "   ")
        XCTAssertFalse(empty)
        XCTAssertNotNil(manager.errorMessage)
        manager.errorMessage = nil
        let nothing = await manager.commit(message: "msg")
        XCTAssertFalse(nothing)
        XCTAssertNotNil(manager.errorMessage)
    }

    func testCreateBranchOnUnbornHead() async throws {
        let repo = try await makeRepo()
        let manager = await makeManager(root: repo)
        await manager.createBranch(name: "draft")
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.branch, "draft")
        XCTAssertEqual(manager.branches.map(\.name), ["draft"])
    }

    // MARK: Born HEAD

    private func makeCommittedRepo() async throws -> (URL, SourceControlManager) {
        let repo = try await makeRepo()
        try write("one\n", to: "keep.typ", in: repo)
        try write("old\n", to: "old name.typ", in: repo)
        try write("bye\n", to: "-gone.typ", in: repo)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-q", "-m", "base"], in: repo)
        return (repo, await makeManager(root: repo))
    }

    func testStagedRenameUnstageRestoresBothPaths() async throws {
        let (repo, manager) = try await makeCommittedRepo()
        try await git(["mv", "old name.typ", "new name.typ"], in: repo)
        await manager.refresh()
        let renamed = try change("new name.typ", in: manager)
        XCTAssertEqual(renamed.indexStatus, "R")
        XCTAssertEqual(renamed.originalPath, "old name.typ")

        let diff = try await manager.diff(for: renamed, group: .staged)
        XCTAssertTrue(diff.contains("rename from old name.typ"), diff)
        XCTAssertTrue(diff.contains("rename to new name.typ"), diff)

        await manager.unstage(renamed)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(try change("new name.typ", in: manager).isUntracked)
        let original = try change("old name.typ", in: manager)
        XCTAssertEqual(original.indexStatus, " ", "original path is back in the index")
        XCTAssertEqual(original.worktreeStatus, "D")

        // Stage both halves again: git re-detects the rename.
        await manager.stage(original)
        await manager.stage(try change("new name.typ", in: manager))
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.changes.count, 1)
        XCTAssertEqual(manager.changes.first?.indexStatus, "R")
    }

    func testDeletedFileStageUnstageAndDiff() async throws {
        let (repo, manager) = try await makeCommittedRepo()
        try FileManager.default.removeItem(at: repo.appendingPathComponent("-gone.typ"))
        await manager.refresh()
        let deleted = try change("-gone.typ", in: manager)
        XCTAssertEqual(deleted.worktreeStatus, "D")
        let unstagedDiff = try await manager.diff(for: deleted, group: .unstaged)
        XCTAssertTrue(unstagedDiff.contains("deleted file mode"), unstagedDiff)

        await manager.stage(deleted)
        XCTAssertNil(manager.errorMessage)
        let staged = try change("-gone.typ", in: manager)
        XCTAssertEqual(staged.indexStatus, "D")
        XCTAssertTrue(staged.isStaged)
        let stagedDiff = try await manager.diff(for: staged, group: .staged)
        XCTAssertTrue(stagedDiff.contains("-bye"), stagedDiff)

        await manager.unstage(staged)
        XCTAssertNil(manager.errorMessage)
        let back = try change("-gone.typ", in: manager)
        XCTAssertFalse(back.isStaged)
        XCTAssertEqual(back.worktreeStatus, "D")
    }

    func testPartiallyStagedFileAndDiffGroups() async throws {
        let (repo, manager) = try await makeCommittedRepo()
        try write("one\nstaged\n", to: "keep.typ", in: repo)
        await manager.refresh()
        await manager.stage(try change("keep.typ", in: manager))
        try write("one\nstaged\nunstaged\n", to: "keep.typ", in: repo)
        await manager.refresh()
        let both = try change("keep.typ", in: manager)
        XCTAssertTrue(both.isStaged && both.isUnstaged)
        let staged = try await manager.diff(for: both, group: .staged)
        let unstaged = try await manager.diff(for: both, group: .unstaged)
        XCTAssertTrue(staged.contains("+staged") && !staged.contains("+unstaged"), staged)
        XCTAssertTrue(unstaged.contains("+unstaged") && !unstaged.contains("+staged"), unstaged)

        await manager.unstage(both)
        let after = try change("keep.typ", in: manager)
        XCTAssertFalse(after.isStaged)
        let content = try String(contentsOf: repo.appendingPathComponent("keep.typ"), encoding: .utf8)
        XCTAssertEqual(content, "one\nstaged\nunstaged\n", "unstage never touches the working tree")
    }

    func testDiscardRestoresTrackedAndTrashesUntracked() async throws {
        let (repo, manager) = try await makeCommittedRepo()
        try write("changed\n", to: "keep.typ", in: repo)
        try write("new\n", to: "fresh.typ", in: repo)
        await manager.refresh()

        let sidebarExpectation = XCTNSNotificationExpectation(name: .refreshProjectSidebar)
        let treeExpectation = XCTNSNotificationExpectation(name: .gitWorkingTreeDidChange)
        await manager.discard(try change("keep.typ", in: manager))
        await fulfillment(of: [sidebarExpectation, treeExpectation], timeout: 2)
        XCTAssertNil(manager.errorMessage)
        let content = try String(contentsOf: repo.appendingPathComponent("keep.typ"), encoding: .utf8)
        XCTAssertEqual(content, "one\n")

        // Untracked files are moved to the Trash: removed from the repo
        // directory, never deleted outright.
        await manager.discard(try change("fresh.typ", in: manager))
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("fresh.typ").path))
        XCTAssertTrue(manager.changes.isEmpty)
    }

    func testBranchesCheckoutAndHistoryTopology() async throws {
        let (repo, manager) = try await makeCommittedRepo()
        await manager.createBranch(name: "feature")
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.branch, "feature")

        try write("feature\n", to: "feature.typ", in: repo)
        await manager.stageAll()
        let ok = await manager.commit(message: "feature work")
        XCTAssertTrue(ok)

        await manager.checkout(branch: "main")
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.branch, "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.typ").path))
        XCTAssertEqual(Set(manager.branches.map(\.name)), ["main", "feature"])
        XCTAssertEqual(manager.branches.first(where: \.isCurrent)?.name, "main")

        // --all history includes the other branch, with parent links.
        XCTAssertEqual(manager.commits.count, 2)
        let tip = try XCTUnwrap(manager.commits.first { $0.subject == "feature work" })
        let base = try XCTUnwrap(manager.commits.first { $0.subject == "base" })
        XCTAssertEqual(tip.parents, [base.id])
        XCTAssertTrue(tip.refs.contains("feature"))

        await manager.checkout(branch: "does-not-exist")
        XCTAssertNotNil(manager.errorMessage)
        manager.errorMessage = nil
        await manager.createBranch(name: "bad..name")
        XCTAssertNotNil(manager.errorMessage)
        manager.errorMessage = nil
        await manager.createBranch(name: "-x")
        XCTAssertNotNil(manager.errorMessage)
    }

    func testPushPullFetchWithLocalBareRemote() async throws {
        let (repo, manager) = try await makeCommittedRepo()
        XCTAssertFalse(manager.hasRemote)
        let remote = try await makeRepo(bare: true)
        try await git(["remote", "add", "origin", remote.path], in: repo)
        await manager.refresh()
        XCTAssertTrue(manager.hasRemote)

        await manager.push()
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.ahead, 0)
        XCTAssertEqual(manager.behind, 0)

        // A second clone advances the remote; we fetch and fast-forward.
        let cloneParent = try makeTempDir()
        try await git(["clone", "-q", remote.path, "clone"], in: cloneParent)
        let clone = cloneParent.appendingPathComponent("clone")
        try write("remote\n", to: "remote.typ", in: clone)
        try await git(["add", "-A"], in: clone)
        try await git(["commit", "-q", "-m", "remote change"], in: clone)
        try await git(["push", "-q"], in: clone)

        await manager.fetch()
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.behind, 1)
        await manager.pull()
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.behind, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("remote.typ").path))
    }

    func testRunnerCancellationTerminatesProcess() async throws {
        // `yes` ignores its arguments' meaning and streams forever, standing
        // in for a hung git command (e.g. a stalled network fetch).
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/yes"))
        let endless = GitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/yes"))
        let dir = try makeTempDir()
        let task = Task { try await endless.runRaw(["x"], in: dir) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testRunnerDrainsLargeOutputWithoutDeadlock() async throws {
        let repo = try await makeRepo()
        // ~1 MB file: diff output well beyond the pipe buffer size.
        let big = String(repeating: "lorem ipsum dolor sit amet\n", count: 40_000)
        try write(big, to: "big.typ", in: repo)
        let manager = await makeManager(root: repo)
        let diff = try await manager.diff(for: try change("big.typ", in: manager), group: .unstaged)
        XCTAssertGreaterThan(diff.utf8.count, big.utf8.count)
    }
}
