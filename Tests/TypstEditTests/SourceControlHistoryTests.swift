import XCTest
@testable import TypstEdit

/// Amend, undo, reword and unpushed flags, against throwaway repositories.
@MainActor
final class SourceControlHistoryTests: XCTestCase {

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

    // MARK: Amend

    func testAmendMessageOnlyPreservesTreeAndAuthor() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "original by ada"], in: repo)
        let manager = await ws.makeManager(root: repo)

        let originalMessage = try await manager.headCommitMessage()
        XCTAssertEqual(originalMessage, "original by ada\n")

        let before = try await ws.git(["show", "-s", "--format=%an%x1f%ae%x1f%ad%x1f%T", "HEAD"], in: repo)
        let amended = await manager.commit(message: "better message", amend: true)
        XCTAssertTrue(amended, manager.errorMessage ?? "")

        XCTAssertEqual(manager.commits.count, 1)
        XCTAssertEqual(manager.commits[0].subject, "better message")
        let amendedMessage = try await manager.headCommitMessage()
        XCTAssertEqual(amendedMessage, "better message\n")
        let after = try await ws.git(["show", "-s", "--format=%an%x1f%ae%x1f%ad%x1f%T", "HEAD"], in: repo)
        XCTAssertEqual(before, after, "author identity/date and tree must be preserved")
        XCTAssertEqual(try ws.read("a.typ", in: repo), "one\n", "message-only amend must not touch files")
        XCTAssertTrue(manager.changes.isEmpty)
    }

    func testAmendWithStagedChangesFoldsThemIn() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "first"], in: repo)
        let manager = await ws.makeManager(root: repo)

        try ws.write("one\ntwo\n", to: "a.typ", in: repo)
        await manager.refresh()
        await manager.stage(try ws.change("a.typ", in: manager))
        let amended = await manager.commit(message: "first, with more", amend: true)
        XCTAssertTrue(amended, manager.errorMessage ?? "")

        XCTAssertEqual(manager.commits.count, 1)
        XCTAssertEqual(manager.commits[0].subject, "first, with more")
        XCTAssertEqual(manager.commits[0].parents, [], "amending the root commit has no parents")
        XCTAssertTrue(manager.changes.isEmpty)
        XCTAssertEqual(try ws.read("a.typ", in: repo), "one\ntwo\n")
        let headContent = try await ws.git(["show", "HEAD:a.typ"], in: repo)
        XCTAssertEqual(headContent, "one\ntwo\n", "staged change folded into the amended commit")
    }

    func testAmendRefusesPushedHeadAndUnbornRepository() async throws {
        // Unborn.
        let fresh = try await ws.makeRepo()
        let emptyManager = await ws.makeManager(root: fresh)
        let unbornAmend = await emptyManager.commit(message: "x", amend: true)
        XCTAssertFalse(unbornAmend)
        XCTAssertNotNil(emptyManager.errorMessage)
        let unbornMessage = await emptyManager.headCommitMessage()
        XCTAssertNil(unbornMessage)

        // Pushed.
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        try await ws.commitAll("first", in: repo)
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "origin", "main"], in: repo)
        let manager = await ws.makeManager(root: repo)
        XCTAssertFalse(manager.commits[0].isUnpushed, "pushed commit must not count as unpushed")
        let pushedAmend = await manager.commit(message: "rewritten", amend: true)
        XCTAssertFalse(pushedAmend)
        XCTAssertEqual(manager.errorMessage, "The latest commit has already been pushed and cannot be amended.")
    }

    // MARK: Messages

    func testHeadCommitMessageAndFullMessage() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        _ = try await ws.git(["add", "-A"], in: repo)
        _ = try await ws.git(["commit", "-q", "-m", "subject line\n\nbody line 1\nbody line 2"], in: repo)
        _ = try ws.write("two\n", to: "b.typ", in: repo)
        try await ws.commitAll("second", in: repo)
        let manager = await ws.makeManager(root: repo)

        XCTAssertEqual(manager.commits[0].subject, "second")
        XCTAssertEqual(manager.commits[1].subject, "subject line")
        let headMessage = try await manager.headCommitMessage()
        XCTAssertEqual(headMessage, "second\n")

        // The full message of any commit, byte-exact.
        let firstCommitID = manager.commits[1].id
        let full = try await manager.fullMessage(of: firstCommitID)
        XCTAssertEqual(full, "subject line\n\nbody line 1\nbody line 2\n")
        // Short hashes work too.
        let byShort = try await manager.fullMessage(of: String(firstCommitID.prefix(7)))
        XCTAssertEqual(byShort, "subject line\n\nbody line 1\nbody line 2\n")
        let secondMessage = try await manager.fullMessage(of: manager.commits[0].id)
        XCTAssertEqual(secondMessage, "second\n")

        do {
            _ = try await manager.fullMessage(of: "no-such-commit")
            XCTFail("expected an error")
        } catch {
            // expected
        }
    }

    // MARK: Undo

    func testUndoLastCommitKeepsChangesStaged() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        try await ws.commitAll("first", in: repo)
        try ws.write("two\n", to: "b.typ", in: repo)
        try await ws.commitAll("second: add b", in: repo)
        let manager = await ws.makeManager(root: repo)
        XCTAssertEqual(manager.commits.count, 2)

        let message = await manager.undoLastCommit()
        XCTAssertEqual(message, "second: add b\n")
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.commits.count, 1)
        XCTAssertEqual(manager.commits[0].subject, "first")
        XCTAssertEqual(try ws.read("b.typ", in: repo), "two\n", "soft reset keeps the file")
        let change = try ws.change("b.typ", in: manager)
        XCTAssertTrue(change.isStaged, "the undone changes come back staged")
        XCTAssertEqual(change.indexStatus, "A")
        XCTAssertFalse(change.isUnstaged)
    }

    func testUndoRootCommitDeletesBranchRefAndKeepsIndex() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        try await ws.commitAll("the only commit", in: repo)
        let manager = await ws.makeManager(root: repo)
        XCTAssertTrue(manager.hasCommits)

        let message = await manager.undoLastCommit()
        XCTAssertEqual(message, "the only commit\n")
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.hasCommits, "deleting the branch ref makes HEAD unborn again")
        XCTAssertEqual(manager.branch, "main")
        XCTAssertTrue(manager.commits.isEmpty)
        XCTAssertEqual(try ws.read("a.typ", in: repo), "one\n", "files are untouched")
        let change = try ws.change("a.typ", in: manager)
        XCTAssertTrue(change.isStaged, "the index is kept")
        XCTAssertEqual(change.indexStatus, "A")
    }

    func testUndoRefusesPushedHead() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        try await ws.commitAll("first", in: repo)
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "origin", "main"], in: repo)
        let manager = await ws.makeManager(root: repo)

        let message = await manager.undoLastCommit()
        XCTAssertNil(message)
        XCTAssertEqual(manager.errorMessage, "The latest commit has already been pushed and cannot be undone.")
        XCTAssertEqual(manager.commits.count, 1, "nothing was undone")
    }

    // MARK: Reword

    func testRewordHeadCommit() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "base"], in: repo)
        try ws.write("two\n", to: "b.typ", in: repo)
        try await ws.commitAll("head commit", in: repo)
        let manager = await ws.makeManager(root: repo)
        let oldHead = try XCTUnwrap(manager.commits.first(where: \.isHead))
        let authorBefore = try await ws.git(["show", "-s", "--format=%an%x1f%ad", oldHead.id], in: repo)

        let ok = await manager.rewordCommit(oldHead.id, message: "reworded head")
        XCTAssertTrue(ok, manager.errorMessage ?? "")

        XCTAssertEqual(manager.commits.count, 2)
        XCTAssertEqual(manager.commits[0].subject, "reworded head")
        XCTAssertEqual(manager.commits[1].subject, "base")
        let newHead = try XCTUnwrap(manager.commits.first(where: \.isHead))
        XCTAssertNotEqual(newHead.id, oldHead.id)
        XCTAssertEqual(newHead.parents, oldHead.parents, "parent is preserved")
        let authorAfter = try await ws.git(["show", "-s", "--format=%an%x1f%ad", newHead.id], in: repo)
        XCTAssertEqual(authorBefore, authorAfter, "author identity and date are preserved")
        let tree = try await ws.git(["show", "-s", "--format=%T", newHead.id], in: repo)
        let oldTree = try await ws.git(["show", "-s", "--format=%T", oldHead.id], in: repo)
        XCTAssertEqual(tree, oldTree)
        let rewordedMessage = try await manager.fullMessage(of: newHead.id)
        XCTAssertEqual(rewordedMessage, "reworded head\n")
    }

    func testRewordOlderCommitPreservesDescendantsIncludingMerge() async throws {
        let repo = try await ws.makeRepo()
        // base <- target <- (side, main), main merges side, then one more commit.
        try ws.write("base\n", to: "base.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "base"], in: repo)
        try ws.write("target\n", to: "t.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "target body\n\ndetails about target"], in: repo)
        let targetID = (try await ws.git(["rev-parse", "HEAD"], in: repo))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await ws.git(["switch", "-c", "side"], in: repo)
        try ws.write("side\n", to: "s.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "side work"], in: repo)

        _ = try await ws.git(["switch", "main"], in: repo)
        try ws.write("m1\n", to: "m.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "main work"], in: repo)
        _ = try await ws.git(["merge", "--no-edit", "-m", "merge side", "side"], in: repo)
        // The merged branch would keep the old chain reachable; delete it so
        // the graph after the reword contains exactly the new chain.
        _ = try await ws.git(["branch", "-d", "side"], in: repo)
        try ws.write("h\n", to: "h.typ", in: repo)
        _ = try await ws.gitAsAda(["add", "-A"], in: repo)
        _ = try await ws.gitAsAda(["commit", "-q", "-m", "head commit"], in: repo)

        let manager = await ws.makeManager(root: repo)
        let subjects = manager.commits.map(\.subject)
        XCTAssertTrue(subjects.contains("merge side"))
        XCTAssertEqual(manager.commits.count, 6)

        // Uncommitted changes must survive the reword untouched.
        try ws.write("dirty\n", to: "dirty.typ", in: repo)
        await manager.refresh()

        // Snapshot everything that must be preserved, per original commit.
        var original: [String: (subject: String, raw: String, tree: String)] = [:]
        for commit in manager.commits where commit.subject != "target body" {
            let tree = try await ws.git(["show", "-s", "--format=%T", commit.id], in: repo)
            let raw = try await ws.git(["cat-file", "commit", commit.id], in: repo)
            original[commit.subject] = (commit.subject, raw, tree)
        }
        let targetRaw = try await ws.git(["cat-file", "commit", targetID], in: repo)
        let targetTree = (try await ws.git(["show", "-s", "--format=%T", targetID], in: repo))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ok = await manager.rewordCommit(targetID, message: "target, reworded")
        XCTAssertTrue(ok, manager.errorMessage ?? "")

        // The new graph, by subject.
        var bySubject: [String: GitCommit] = [:]
        for commit in manager.commits { bySubject[commit.subject] = commit }
        XCTAssertEqual(manager.commits.count, 6)
        XCTAssertEqual(bySubject["target, reworded"]?.subject, "target, reworded")
        XCTAssertNil(bySubject["target body"], "old subject gone")
        for name in ["side work", "main work", "merge side", "head commit", "base"] {
            XCTAssertNotNil(bySubject[name], "\(name) kept its subject")
        }

        // Merge commit parents both remapped.
        let newTargetID = try XCTUnwrap(bySubject["target, reworded"]?.id)
        let merge = try XCTUnwrap(bySubject["merge side"])
        XCTAssertEqual(merge.parents.count, 2)
        let mainWork = try XCTUnwrap(bySubject["main work"])
        let sideWork = try XCTUnwrap(bySubject["side work"])
        XCTAssertEqual(merge.parents, [mainWork.id, sideWork.id], "merge parents are the rewritten commits")
        let head = try XCTUnwrap(bySubject["head commit"])
        XCTAssertEqual(head.parents, [merge.id])
        XCTAssertEqual(mainWork.parents, [newTargetID])
        XCTAssertEqual(sideWork.parents, [newTargetID])

        // Byte-exact preservation for every descendant: message, author,
        // committer, encoding, and tree identical to the original.
        for (subject, info) in original {
            let newCommit = try XCTUnwrap(bySubject[subject], "missing \(subject)")
            let newRaw = try await ws.git(["cat-file", "commit", newCommit.id], in: repo)
            XCTAssertEqual(
                RawCommit.parse(Data(newRaw.utf8))?.message,
                RawCommit.parse(Data(info.raw.utf8))?.message,
                "\(subject): message bytes must be preserved"
            )
            XCTAssertEqual(
                RawCommit.parse(Data(newRaw.utf8))?.otherHeaders,
                RawCommit.parse(Data(info.raw.utf8))?.otherHeaders,
                "\(subject): author/committer/encoding headers must be preserved"
            )
            let newTree = try await ws.git(["show", "-s", "--format=%T", newCommit.id], in: repo)
            XCTAssertEqual(newTree, info.tree, "\(subject): tree must be identical")
        }

        // The reworded commit: new message, everything else preserved.
        let newTarget = try XCTUnwrap(bySubject["target, reworded"])
        let newTargetRaw = try await ws.git(["cat-file", "commit", newTarget.id], in: repo)
        let oldParsed = try XCTUnwrap(RawCommit.parse(Data(targetRaw.utf8)))
        let newParsed = try XCTUnwrap(RawCommit.parse(Data(newTargetRaw.utf8)))
        XCTAssertEqual(newParsed.message, Data("target, reworded\n".utf8))
        XCTAssertEqual(newParsed.otherHeaders, oldParsed.otherHeaders)
        XCTAssertEqual(newParsed.tree, oldParsed.tree)
        XCTAssertEqual(newParsed.tree, targetTree)

        // The working tree and index were never touched.
        XCTAssertEqual(try ws.read("dirty.typ", in: repo), "dirty\n")
        let dirty = try ws.change("dirty.typ", in: manager)
        XCTAssertTrue(dirty.isUntracked)

        // Reflog message per the contract.
        let reflog = try await ws.git(["reflog", "show", "--format=%gs", "-n", "1", "main"], in: repo)
        XCTAssertEqual(reflog.trimmingCharacters(in: .whitespacesAndNewlines), "TypstEdit: reword")
    }

    func testRewordDetachedHead() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        try await ws.commitAll("first", in: repo)
        try ws.write("two\n", to: "b.typ", in: repo)
        try await ws.commitAll("second", in: repo)
        let manager = await ws.makeManager(root: repo)

        await manager.checkoutDetached(manager.commits[0].id)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.isDetachedHead)

        let ok = await manager.rewordCommit("HEAD", message: "detached reword")
        XCTAssertTrue(ok, manager.errorMessage ?? "")
        XCTAssertTrue(manager.isDetachedHead, "still detached after reword")
        // With a detached HEAD, log --all may order the branch tip first, so
        // look the HEAD commit up by its flag.
        let newHead = try XCTUnwrap(manager.commits.first(where: \.isHead))
        XCTAssertEqual(newHead.subject, "detached reword")
        XCTAssertEqual(newHead.parents.count, 1)
        // The branch itself must not have moved.
        let mainSubject = try await ws.git(["log", "-1", "--format=%s", "main"], in: repo)
        XCTAssertEqual(mainSubject.trimmingCharacters(in: .whitespacesAndNewlines), "second")
    }

    func testRewordRefusesPushedUnreachableAndInProgress() async throws {
        // Pushed.
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        try await ws.commitAll("first", in: repo)
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "origin", "main"], in: repo)
        let manager = await ws.makeManager(root: repo)
        let headID = try XCTUnwrap(manager.commits.first(where: \.isHead)?.id)
        let pushedReword = await manager.rewordCommit(headID, message: "nope")
        XCTAssertFalse(pushedReword)
        XCTAssertEqual(manager.errorMessage, "The commit has already been pushed and cannot be rewritten.")

        // Not reachable from HEAD.
        _ = try await ws.git(["switch", "-c", "island"], in: repo)
        try ws.write("island\n", to: "i.typ", in: repo)
        try await ws.commitAll("island commit", in: repo)
        let islandID = (try await ws.git(["rev-parse", "HEAD"], in: repo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await ws.git(["switch", "main"], in: repo)
        await manager.refresh()
        let unreachableReword = await manager.rewordCommit(islandID, message: "nope")
        XCTAssertFalse(unreachableReword)
        XCTAssertEqual(manager.errorMessage, "The commit is not reachable from the current branch.")

        // Operation in progress (merge conflict).
        try ws.write("one\nmain\n", to: "a.typ", in: repo)
        try await ws.commitAll("main change", in: repo)
        let mainChangeID = (try await ws.git(["rev-parse", "HEAD"], in: repo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await ws.git(["switch", "island"], in: repo)
        try ws.write("one\nisland\n", to: "a.typ", in: repo)
        try await ws.commitAll("island change", in: repo)
        _ = try await ws.git(["switch", "main"], in: repo)
        await manager.refresh()
        await manager.mergeBranch("island")
        XCTAssertEqual(manager.operationState, .merging)
        manager.errorMessage = nil
        let inProgressReword = await manager.rewordCommit(mainChangeID, message: "nope")
        XCTAssertFalse(inProgressReword)
        XCTAssertEqual(manager.errorMessage, "An operation is in progress; finish or abort it first.")
        await manager.abortOperation()
        XCTAssertEqual(manager.operationState, .none)
    }

    // MARK: Unpushed flags

    func testUnpushedFlagsAndCount() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "a.typ", in: repo)
        try await ws.commitAll("first", in: repo)
        try ws.write("two\n", to: "b.typ", in: repo)
        try await ws.commitAll("second", in: repo)
        let manager = await ws.makeManager(root: repo)

        // No remote: every HEAD-reachable commit is unpushed.
        XCTAssertTrue(manager.commits.allSatisfy(\.isUnpushed))
        XCTAssertEqual(manager.unpushedCount, 2)
        XCTAssertEqual(manager.commits.filter(\.isHead).count, 1)
        XCTAssertEqual(manager.commits.first(where: \.isHead)?.subject, "second")

        // After pushing: none unpushed.
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        await manager.refresh()
        await manager.push()
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertFalse(manager.commits.contains(where: \.isUnpushed))
        XCTAssertEqual(manager.unpushedCount, 0)

        // A new local commit is unpushed again.
        try ws.write("three\n", to: "c.typ", in: repo)
        try await ws.commitAll("third", in: repo)
        await manager.refresh()
        XCTAssertEqual(manager.unpushedCount, 1)
        XCTAssertTrue(manager.commits[0].isUnpushed)
        XCTAssertFalse(manager.commits[1].isUnpushed)
        XCTAssertEqual(manager.ahead, 1)
    }
}
