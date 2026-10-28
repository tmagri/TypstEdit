import XCTest
@testable import TypstEdit

/// Merge/rebase conflicts, revert/cherry-pick, branches, tags, stash, sync
/// and discard-all, against throwaway repositories.
@MainActor
final class SourceControlWorkflowTests: XCTestCase {

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

    // MARK: Helpers

    /// base commit with one file "one\n", then `manager` for it.
    private func makeBaseRepo() async throws -> (URL, SourceControlManager) {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "keep.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        return (repo, await ws.makeManager(root: repo))
    }

    /// A repository whose `origin` is a bare remote that already has main.
    /// The upstream branch is NOT configured here (tests do that explicitly
    /// when they need pull to work).
    private func makeRepoWithRemote() async throws -> (URL, URL, SourceControlManager) {
        let (repo, manager) = try await makeBaseRepo()
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "origin", "main"], in: repo)
        await manager.refresh()
        return (repo, bare, manager)
    }

    /// Points the current branch at its remote-tracking counterpart.
    private func setUpstream(_ repo: URL) async throws {
        _ = try await ws.git(["branch", "--set-upstream-to=origin/main", "main"], in: repo)
    }

    /// Advances the bare remote through a second clone, so local and remote diverge.
    private func advanceRemote(_ bare: URL, message: String, file: String) async throws {
        let parent = try ws.makeTempDir()
        _ = try await ws.git(["clone", "-q", bare.path, "clone"], in: parent)
        let clone = parent.appendingPathComponent("clone")
        try ws.write("remote\n", to: file, in: clone)
        try await ws.commitAll(message, in: clone)
        _ = try await ws.git(["push", "-q"], in: clone)
    }

    // MARK: Merge conflicts

    func testMergeConflictStateAcceptIncomingAndContinue() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "feature")
        try ws.write("one\nfeature version\n", to: "keep.typ", in: repo)
        try await ws.commitAll("feature change", in: repo)
        await manager.checkout(branch: "main")
        try ws.write("one\nmain version\n", to: "keep.typ", in: repo)
        try await ws.commitAll("main change", in: repo)

        await manager.mergeBranch("feature")
        XCTAssertNotNil(manager.errorMessage, "a conflicted merge reports an error")
        XCTAssertEqual(manager.operationState, .merging)
        XCTAssertEqual(manager.conflictedChanges.count, 1)
        XCTAssertEqual(manager.conflictedChanges[0].path, "keep.typ")
        XCTAssertFalse(manager.commits[0].parents.count == 2, "no merge commit yet")

        let pending = await manager.pendingOperationMessage()
        XCTAssertNotNil(pending)
        XCTAssertTrue(pending?.contains("feature") ?? false, "MERGE_MSG prefill mentions the merged branch: \(pending ?? "")")

        // Continue refuses while conflicts remain.
        let prematureContinue = await manager.continueOperation(message: nil)
        XCTAssertFalse(prematureContinue)
        XCTAssertEqual(manager.errorMessage, "Resolve the remaining conflicts before continuing.")

        let conflict = try ws.change("keep.typ", in: manager)
        XCTAssertTrue(conflict.isConflicted)
        await manager.acceptIncoming(conflict)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\nfeature version\n", "incoming side taken")
        XCTAssertFalse(manager.conflictedChanges.contains { $0.path == "keep.typ" })
        let staged = try ws.change("keep.typ", in: manager)
        XCTAssertTrue(staged.isStaged, "the resolved file is staged")

        // Also check accepting the current side on a fresh conflict later in
        // this test is impossible; covered by the abort test instead.
        let continued = await manager.continueOperation(message: "merged by TypstEdit")
        XCTAssertTrue(continued, manager.errorMessage ?? "")
        XCTAssertEqual(manager.operationState, .none)
        XCTAssertEqual(manager.conflictedChanges.count, 0)
        XCTAssertEqual(manager.commits[0].subject, "merged by TypstEdit")
        XCTAssertEqual(manager.commits[0].parents.count, 2, "the merge commit has both parents")
        XCTAssertTrue(manager.changes.isEmpty)
    }

    func testMergeConflictAbortRestoresState() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "feature")
        try ws.write("one\nfeature version\n", to: "keep.typ", in: repo)
        try await ws.commitAll("feature change", in: repo)
        await manager.checkout(branch: "main")
        try ws.write("one\nmain version\n", to: "keep.typ", in: repo)
        try await ws.commitAll("main change", in: repo)
        await manager.refresh()
        let commitCountBefore = manager.commits.count

        await manager.mergeBranch("feature")
        XCTAssertEqual(manager.operationState, .merging)

        let sidebarExpectation = XCTNSNotificationExpectation(name: .refreshProjectSidebar)
        let treeExpectation = XCTNSNotificationExpectation(name: .gitWorkingTreeDidChange)
        await manager.abortOperation()
        await fulfillment(of: [sidebarExpectation, treeExpectation], timeout: 2)

        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.operationState, .none)
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\nmain version\n", "our side restored")
        XCTAssertEqual(manager.commits.count, commitCountBefore, "no merge commit was created")
        XCTAssertTrue(manager.conflictedChanges.isEmpty)
    }

    func testOperationStateDetectedThroughLinkedWorktree() async throws {
        let repo = try await ws.makeRepo()
        try ws.write("one\n", to: "c.typ", in: repo)
        try await ws.commitAll("base", in: repo)
        _ = try await ws.git(["switch", "-c", "other"], in: repo)
        try ws.write("other\n", to: "c.typ", in: repo)
        try await ws.commitAll("other change", in: repo)
        _ = try await ws.git(["switch", "main"], in: repo)

        let worktreeParent = try ws.makeTempDir()
        let worktree = worktreeParent.appendingPathComponent("wt", isDirectory: true)
        _ = try await ws.git(["worktree", "add", worktree.path, "-b", "side"], in: repo)
        try ws.write("side\n", to: "c.typ", in: worktree)
        try await ws.commitAll("side change", in: worktree)

        // The linked worktree stores its control files in .git/worktrees/<id>,
        // which is exactly what `rev-parse --git-path` resolves.
        let manager = await ws.makeManager(root: worktree)
        XCTAssertEqual(manager.operationState, .none)
        await manager.mergeBranch("other")
        XCTAssertEqual(manager.operationState, .merging)
        XCTAssertFalse(manager.conflictedChanges.isEmpty)
        await manager.abortOperation()
        XCTAssertEqual(manager.operationState, .none)
        XCTAssertEqual(try ws.read("c.typ", in: worktree), "side\n")
    }

    // MARK: Rebase conflicts

    func testRebaseConflictAbort() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "feature")
        try ws.write("feature\n", to: "keep.typ", in: repo)
        try await ws.commitAll("feature change", in: repo)
        await manager.checkout(branch: "main")
        try ws.write("main\n", to: "keep.typ", in: repo)
        try await ws.commitAll("main change", in: repo)
        await manager.checkout(branch: "feature")

        await manager.rebaseCurrentBranch(onto: "main")
        XCTAssertEqual(manager.operationState, .rebasing)
        XCTAssertFalse(manager.conflictedChanges.isEmpty)

        await manager.abortOperation()
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.operationState, .none)
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "feature\n", "the branch is back to its own tip")
        XCTAssertEqual(manager.commits.first(where: \.isHead)?.parents.count, 1)
        XCTAssertTrue(manager.conflictedChanges.isEmpty)
    }

    // MARK: Revert / cherry-pick

    func testRevertCommitCreatesInverseChange() async throws {
        let (repo, manager) = try await makeBaseRepo()
        try ws.write("one\nchanged\n", to: "keep.typ", in: repo)
        try await ws.commitAll("modify keep", in: repo)
        await manager.refresh()
        let badCommit = try XCTUnwrap(manager.commits.first(where: \.isHead))

        await manager.revertCommit(badCommit.id)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.commits[0].subject, "Revert \"modify keep\"")
        XCTAssertEqual(manager.commits[0].parents, [badCommit.id])
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\n")
        XCTAssertTrue(manager.changes.isEmpty)
    }

    func testRevertConflictSetsStateAndAborts() async throws {
        let (repo, manager) = try await makeBaseRepo()
        let baseID = try XCTUnwrap(manager.commits.first(where: \.isHead)?.id)
        try ws.write("one\nchanged on main\n", to: "keep.typ", in: repo)
        try await ws.commitAll("conflicting change", in: repo)

        await manager.revertCommit(baseID)
        XCTAssertEqual(manager.operationState, .reverting)
        XCTAssertFalse(manager.conflictedChanges.isEmpty)

        await manager.abortOperation()
        XCTAssertEqual(manager.operationState, .none)
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\nchanged on main\n")
        XCTAssertEqual(manager.commits.count, 2, "no revert commit was created")
    }

    func testCherryPickAndConflictState() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "feature")
        try ws.write("feature\n", to: "new.typ", in: repo)
        try await ws.commitAll("feature adds file", in: repo)
        await manager.refresh()
        let picked = try XCTUnwrap(manager.commits.first(where: \.isHead))
        await manager.checkout(branch: "main")
        try ws.write("main\n", to: "other.typ", in: repo)
        try await ws.commitAll("main evolves", in: repo)

        await manager.cherryPick(picked.id)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.commits[0].subject, "feature adds file")
        XCTAssertEqual(manager.commits[0].parents.count, 1)
        XCTAssertTrue(ws.exists("new.typ", in: repo))
        let pickedAuthor = try await ws.git(["log", "-1", "--format=%an", picked.id], in: repo)
        let headAuthor = try await ws.git(["log", "-1", "--format=%an", "HEAD"], in: repo)
        XCTAssertEqual(headAuthor, pickedAuthor, "author preserved")

        // A conflicting cherry-pick reports the state and refuses to continue.
        try ws.write("main version\n", to: "conflict.typ", in: repo)
        try await ws.commitAll("main touches conflict", in: repo)
        await manager.checkout(branch: "feature")
        try ws.write("feature version\n", to: "conflict.typ", in: repo)
        try await ws.commitAll("feature touches conflict", in: repo)
        await manager.refresh()
        let conflicting = try XCTUnwrap(manager.commits.first(where: \.isHead))
        await manager.checkout(branch: "main")
        await manager.cherryPick(conflicting.id)
        XCTAssertEqual(manager.operationState, .cherryPicking)
        let refusedContinue = await manager.continueOperation(message: nil)
        XCTAssertFalse(refusedContinue)
        XCTAssertEqual(manager.errorMessage, "Resolve the remaining conflicts before continuing.")
        await manager.abortOperation()
        XCTAssertEqual(manager.operationState, .none)
        XCTAssertEqual(try ws.read("conflict.typ", in: repo), "main version\n")
    }

    // MARK: Branches

    func testBranchRenameAndDelete() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "topic")
        await manager.checkout(branch: "main")

        await manager.renameBranch("main", to: "trunk")
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.branch, "trunk", "renaming the current branch moves HEAD with it")
        XCTAssertEqual(Set(manager.branches.map(\.name)), ["trunk", "topic"])

        await manager.renameBranch("ghost", to: "whatever")
        XCTAssertNotNil(manager.errorMessage)
        manager.errorMessage = nil

        await manager.deleteBranch("topic", force: false)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(Set(manager.branches.map(\.name)), ["trunk"])

        // The current branch cannot be deleted.
        await manager.deleteBranch("trunk", force: false)
        XCTAssertNotNil(manager.errorMessage)
        manager.errorMessage = nil

        // An unmerged branch needs force.
        await manager.createBranch(name: "side")
        try ws.write("side\n", to: "side.typ", in: repo)
        try await ws.commitAll("side work", in: repo)
        await manager.checkout(branch: "trunk")
        await manager.deleteBranch("side", force: false)
        XCTAssertNotNil(manager.errorMessage, "-d refuses unmerged branches")
        manager.errorMessage = nil
        await manager.deleteBranch("side", force: true)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(Set(manager.branches.map(\.name)), ["trunk"])
    }

    func testCheckoutRemoteBranchCreatesTrackingBranchAndSwitchesToExisting() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "feature")
        try ws.write("feature\n", to: "feature.typ", in: repo)
        try await ws.commitAll("feature work", in: repo)
        await manager.checkout(branch: "main")
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        // Both branches exist on the remote; remove the local feature branch.
        _ = try await ws.git(["push", "-q", "origin", "main", "feature"], in: repo)
        _ = try await ws.git(["branch", "-D", "feature"], in: repo)
        // A remote HEAD symref that must not appear as a branch.
        _ = try await ws.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repo)
        await manager.refresh()

        XCTAssertEqual(
            Set(manager.remoteBranches.map(\.name)),
            ["origin/main", "origin/feature"],
            "origin/HEAD is excluded"
        )
        XCTAssertTrue(manager.remoteBranches.allSatisfy(\.isRemote))

        // Creates a local branch that tracks the remote one.
        await manager.checkoutRemoteBranch("origin/feature")
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.branch, "feature")
        XCTAssertEqual(manager.upstreamBranch, "origin/feature")
        let localTip = try await ws.git(["rev-parse", "feature"], in: repo)
        let remoteTip = try await ws.git(["rev-parse", "origin/feature"], in: repo)
        XCTAssertEqual(localTip, remoteTip)

        // Switching away and back reuses the existing local branch.
        await manager.checkout(branch: "main")
        XCTAssertEqual(manager.branch, "main")
        await manager.checkoutRemoteBranch("origin/feature")
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.branch, "feature")
    }

    func testCheckoutDetachedAndCreateBranchAtCommit() async throws {
        let (repo, manager) = try await makeBaseRepo()
        let baseID = try XCTUnwrap(manager.commits.first(where: \.isHead)?.id)
        try ws.write("more\n", to: "advance.typ", in: repo)
        try await ws.commitAll("advance", in: repo)
        await manager.refresh()

        await manager.checkoutDetached(baseID)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertTrue(manager.isDetachedHead)
        XCTAssertTrue(manager.branch.hasPrefix("HEAD ("))
        XCTAssertFalse(ws.exists("advance.typ", in: repo), "switching to an old commit rewrites the worktree")

        await manager.checkout(branch: "main")
        XCTAssertEqual(manager.branch, "main")
        XCTAssertFalse(manager.isDetachedHead)
        XCTAssertTrue(ws.exists("advance.typ", in: repo))

        await manager.createBranch(name: "topic", at: baseID)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.branch, "topic")
        let topicTip = try await ws.git(["rev-parse", "topic"], in: repo)
        XCTAssertEqual(topicTip, "\(baseID)\n")
        XCTAssertFalse(ws.exists("advance.typ", in: repo))
        XCTAssertEqual(manager.commits.count, 2, "history of both branches is loaded")

        // Branching at an invalid commit fails without side effects.
        await manager.createBranch(name: "broken", at: "no-such-commit")
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.branches.contains { $0.name == "broken" })
    }

    // MARK: Tags

    func testCreateAndDeleteTags() async throws {
        let (repo, manager) = try await makeBaseRepo()
        let baseID = try XCTUnwrap(manager.commits.first(where: \.isHead)?.id)
        try ws.write("more\n", to: "advance.typ", in: repo)
        try await ws.commitAll("advance", in: repo)
        await manager.refresh()

        await manager.createTag(name: "v1", message: "release notes\nmulti-line", at: nil)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.tags, ["v1"])
        let tagType = try await ws.git(["cat-file", "-t", "v1"], in: repo)
        XCTAssertEqual(tagType, "tag\n", "annotated tag")

        await manager.createTag(name: "v2", message: nil, at: baseID)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(Set(manager.tags), ["v1", "v2"])
        let tagTarget = try await ws.git(["rev-parse", "v2^{commit}"], in: repo)
        XCTAssertEqual(tagTarget, "\(baseID)\n", "lightweight tag at the base commit")

        await manager.deleteTag("v1")
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.tags, ["v2"])

        await manager.createTag(name: "v2", message: "duplicate", at: nil)
        XCTAssertNotNil(manager.errorMessage, "duplicate tag names are refused")
        manager.errorMessage = nil
        await manager.deleteTag("missing-tag")
        XCTAssertNotNil(manager.errorMessage)
    }

    // MARK: Stash

    func testStashPushApplyPopDropIncludingUntracked() async throws {
        let (repo, manager) = try await makeBaseRepo()

        try ws.write("one\nedited\n", to: "keep.typ", in: repo)
        try ws.write("new file\n", to: "fresh.typ", in: repo)
        await manager.refresh()

        await manager.stash(message: "wip stuff", includeUntracked: true)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertTrue(manager.changes.isEmpty, "stash removed tracked and untracked changes")
        XCTAssertEqual(manager.stashes.count, 1)
        XCTAssertEqual(manager.stashes[0].id, "stash@{0}")
        XCTAssertEqual(manager.stashes[0].index, 0)
        XCTAssertNotNil(manager.stashes[0].date)
        XCTAssertTrue(manager.stashes[0].message.contains("wip stuff"), manager.stashes[0].message)
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\n", "stash restored the file")
        XCTAssertFalse(ws.exists("fresh.typ", in: repo), "untracked files are stashed away too")

        // Apply: changes return, the stash stays.
        await manager.applyStash(manager.stashes[0])
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\nedited\n")
        XCTAssertTrue(ws.exists("fresh.typ", in: repo))
        XCTAssertEqual(manager.stashes.count, 1)

        // Clean up, then pop: the stash is dropped on success.
        await manager.discardAllChanges()
        XCTAssertTrue(manager.changes.isEmpty)
        XCTAssertEqual(manager.stashes.count, 1, "dropping changes does not touch the stash")
        await manager.popStash(manager.stashes[0])
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\nedited\n")
        XCTAssertTrue(ws.exists("fresh.typ", in: repo))
        XCTAssertTrue(manager.stashes.isEmpty, "pop drops the stash")

        // Without untracked, only tracked changes are stashed.
        try ws.write("one\nedited again\n", to: "keep.typ", in: repo)
        try ws.write("other\n", to: "other.typ", in: repo)
        await manager.refresh()
        await manager.stash(message: nil, includeUntracked: false)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\n")
        XCTAssertTrue(ws.exists("other.typ", in: repo), "untracked files stay in the worktree")
        XCTAssertEqual(manager.stashes.count, 1)

        // Drop: the stash disappears, the worktree is untouched.
        await manager.dropStash(manager.stashes[0])
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertTrue(manager.stashes.isEmpty)
        XCTAssertTrue(ws.exists("other.typ", in: repo))
    }

    // MARK: Stash and merge during an in-progress operation

    /// The mid-operation states used below: a conflicted merge (MERGE_HEAD)
    /// and a conflicted rebase (rebase-merge), plus one stash to try to
    /// apply/pop.
    private func makeConflictedMergeWithStash() async throws -> (URL, SourceControlManager) {
        let (repo, manager) = try await makeBaseRepo()
        // One stash to attempt to apply/pop mid-merge.
        try ws.write("stashed\n", to: "stashed.typ", in: repo)
        await manager.stash(message: "before the storm", includeUntracked: true)
        XCTAssertEqual(manager.stashes.count, 1)

        // Diverge and start a conflicted merge.
        await manager.createBranch(name: "feature")
        try ws.write("one\nfeature version\n", to: "keep.typ", in: repo)
        try await ws.commitAll("feature change", in: repo)
        await manager.checkout(branch: "main")
        try ws.write("one\nmain version\n", to: "keep.typ", in: repo)
        try await ws.commitAll("main change", in: repo)
        await manager.mergeBranch("feature")
        XCTAssertEqual(manager.operationState, .merging)
        XCTAssertNotNil(manager.errorMessage, "the conflicted merge itself reports the conflict")
        return (repo, manager)
    }

    func testStashPushApplyPopRefusedDuringMerge() async throws {
        let (repo, manager) = try await makeConflictedMergeWithStash()
        try ws.write("mid-merge edit\n", to: "other.typ", in: repo)
        await manager.refresh()

        await manager.stash(message: "mid merge", includeUntracked: true)
        XCTAssertEqual(manager.errorMessage, "An operation is in progress; finish or abort it first.")
        XCTAssertEqual(manager.stashes.count, 1, "no extra stash was created")
        XCTAssertTrue(ws.exists("other.typ", in: repo), "mid-merge edit stays in the worktree")

        await manager.applyStash(manager.stashes[0])
        XCTAssertEqual(manager.errorMessage, "An operation is in progress; finish or abort it first.")
        XCTAssertEqual(manager.stashes.count, 1)

        await manager.popStash(manager.stashes[0])
        XCTAssertEqual(manager.errorMessage, "An operation is in progress; finish or abort it first.")
        XCTAssertEqual(manager.stashes.count, 1, "pop is refused, so the stash survives")

        // Dropping stays allowed: it does not touch the working tree.
        await manager.dropStash(manager.stashes[0])
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertTrue(manager.stashes.isEmpty)

        // After the abort, stashing works again.
        await manager.abortOperation()
        XCTAssertEqual(manager.operationState, .none)
        await manager.stash(message: nil, includeUntracked: true)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.stashes.count, 1)
        XCTAssertFalse(ws.exists("other.typ", in: repo), "the mid-merge edit was stashed away")
    }

    func testStashPushRefusedDuringRebase() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "feature")
        try ws.write("feature\n", to: "keep.typ", in: repo)
        try await ws.commitAll("feature change", in: repo)
        await manager.checkout(branch: "main")
        try ws.write("main\n", to: "keep.typ", in: repo)
        try await ws.commitAll("main change", in: repo)
        await manager.checkout(branch: "feature")

        await manager.rebaseCurrentBranch(onto: "main")
        XCTAssertEqual(manager.operationState, .rebasing)
        try ws.write("mid-rebase resolution\n", to: "resolved.typ", in: repo)
        await manager.refresh()

        await manager.stash(message: "mid rebase", includeUntracked: true)
        XCTAssertEqual(manager.errorMessage, "An operation is in progress; finish or abort it first.")
        XCTAssertTrue(ws.exists("resolved.typ", in: repo), "the staged resolution was not stolen")
        XCTAssertEqual(manager.operationState, .rebasing, "the rebase is untouched")
    }

    func testMergeAndRebaseRefusedDuringRebase() async throws {
        let (repo, manager) = try await makeBaseRepo()
        await manager.createBranch(name: "feature")
        try ws.write("feature\n", to: "keep.typ", in: repo)
        try await ws.commitAll("feature change", in: repo)
        await manager.checkout(branch: "main")
        try ws.write("main\n", to: "keep.typ", in: repo)
        try await ws.commitAll("main change", in: repo)
        await manager.checkout(branch: "feature")

        await manager.rebaseCurrentBranch(onto: "main")
        XCTAssertEqual(manager.operationState, .rebasing)

        await manager.mergeBranch("main")
        XCTAssertEqual(manager.errorMessage, "An operation is in progress; finish or abort it first.")
        XCTAssertEqual(manager.operationState, .rebasing, "no merge state was created on top")
        XCTAssertEqual(manager.commits.first(where: \.isHead)?.parents.count, 1, "no merge commit")

        await manager.rebaseCurrentBranch(onto: "main")
        XCTAssertEqual(manager.errorMessage, "An operation is in progress; finish or abort it first.")
        XCTAssertEqual(manager.operationState, .rebasing)
    }

    func testFastForwardSyncHelperCoversAllDivergenceStates() {
        // Only ahead or only behind: a fast-forward pull still works.
        XCTAssertTrue(GitOutputParser.canFastForwardSync(ahead: 0, behind: 0))
        XCTAssertTrue(GitOutputParser.canFastForwardSync(ahead: 0, behind: 3))
        XCTAssertTrue(GitOutputParser.canFastForwardSync(ahead: 2, behind: 0))
        // Diverged: never fast-forwardable.
        XCTAssertFalse(GitOutputParser.canFastForwardSync(ahead: 1, behind: 1))
        XCTAssertFalse(GitOutputParser.canFastForwardSync(ahead: 7, behind: 2))
        XCTAssertFalse(GitOutputParser.canFastForwardSync(ahead: 2, behind: 7))
    }

    // MARK: Sync and pull modes

    func testSyncSetsUpstreamAndPushes() async throws {
        let (repo, bare, manager) = try await makeRepoWithRemote()
        try ws.write("local\n", to: "local.typ", in: repo)
        try await ws.commitAll("local work", in: repo)
        await manager.refresh()

        XCTAssertNil(manager.upstreamBranch)
        await manager.sync(mode: .fastForwardOnly)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.upstreamBranch, "origin/main", "the push sets the upstream")
        XCTAssertEqual(manager.ahead, 0)
        XCTAssertEqual(manager.unpushedCount, 0)
        let localTip = try await ws.git(["rev-parse", "origin/main"], in: repo)
        let remoteTip = try await ws.git(["rev-parse", "main"], in: repo)
        XCTAssertEqual(localTip, remoteTip)
        let bareTip = try await ws.git(["rev-parse", "main"], in: bare)
        XCTAssertEqual(bareTip, remoteTip)
    }

    func testSyncSkipsPushAfterFailedFastForwardPull() async throws {
        let (repo, bare, manager) = try await makeRepoWithRemote()
        try await setUpstream(repo)
        try await advanceRemote(bare, message: "remote work", file: "remote.typ")
        await manager.fetch()
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        try ws.write("local\n", to: "local.typ", in: repo)
        try await ws.commitAll("local work", in: repo)
        await manager.refresh()
        XCTAssertEqual(manager.ahead, 1)
        XCTAssertEqual(manager.behind, 1)

        await manager.sync(mode: .fastForwardOnly)
        XCTAssertNotNil(manager.errorMessage, "the diverged fast-forward pull fails")
        XCTAssertEqual(manager.ahead, 1)
        XCTAssertEqual(manager.behind, 1, "the push was skipped")
        let remoteMain = try await ws.git(["rev-parse", "main"], in: bare)
        let trackingMain = try await ws.git(["rev-parse", "origin/main"], in: repo)
        XCTAssertEqual(remoteMain, trackingMain, "the remote was not advanced")
    }

    func testPullMergeAndRebaseModes() async throws {
        let (repo, bare, manager) = try await makeRepoWithRemote()
        try await setUpstream(repo)

        // Diverge, then a merge pull: creates a merge commit.
        try await advanceRemote(bare, message: "remote change", file: "remote.typ")
        await manager.fetch()
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        try ws.write("local\n", to: "local.typ", in: repo)
        try await ws.commitAll("local change", in: repo)
        await manager.refresh()
        XCTAssertEqual(manager.ahead, 1)
        XCTAssertEqual(manager.behind, 1)

        await manager.pull(mode: .merge)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.behind, 0)
        XCTAssertEqual(manager.commits[0].parents.count, 2, "pull --no-rebase creates a merge commit")
        XCTAssertTrue(ws.exists("remote.typ", in: repo))

        // Diverge again, then a rebase pull: linear history.
        try await advanceRemote(bare, message: "remote change 2", file: "remote2.typ")
        await manager.fetch()
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        try ws.write("local2\n", to: "local2.typ", in: repo)
        try await ws.commitAll("local change 2", in: repo)
        await manager.refresh()

        await manager.pull(mode: .rebase)
        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(manager.behind, 0)
        XCTAssertEqual(manager.commits[0].subject, "local change 2")
        XCTAssertEqual(manager.commits[0].parents.count, 1, "pull --rebase keeps history linear")
        XCTAssertTrue(ws.exists("remote2.typ", in: repo))
    }

    // MARK: Discard all

    func testDiscardAllChangesKeepsStagedAndTrashesUntracked() async throws {
        let (repo, manager) = try await makeBaseRepo()
        try ws.write("c\n", to: "c.typ", in: repo)
        try await ws.commitAll("add c", in: repo)
        await manager.refresh()

        try ws.write("one\nunstaged edit\n", to: "keep.typ", in: repo)   // unstaged, tracked
        try ws.write("c\nstaged edit\n", to: "c.typ", in: repo)
        await manager.refresh()
        await manager.stage(try ws.change("c.typ", in: manager))          // staged
        try ws.write("untracked\n", to: "untracked.typ", in: repo)        // untracked
        await manager.refresh()
        XCTAssertEqual(manager.changes.count, 3)

        // Notifications carry the repository root as the object.
        final class PostedRootBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: URL?
            func set(_ url: URL?) {
                lock.lock(); defer { lock.unlock() }
                value = url
            }
            func get() -> URL? {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }
        let box = PostedRootBox()
        let treeChanged = expectation(description: "gitWorkingTreeDidChange")
        let observer = NotificationCenter.default.addObserver(
            forName: .gitWorkingTreeDidChange, object: nil, queue: nil
        ) { note in
            box.set(note.object as? URL)
            treeChanged.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await manager.discardAllChanges()
        await fulfillment(of: [treeChanged], timeout: 2)

        XCTAssertNil(manager.errorMessage, manager.errorMessage ?? "")
        XCTAssertEqual(try ws.read("keep.typ", in: repo), "one\n", "unstaged tracked edits restored from the index")
        XCTAssertFalse(ws.exists("untracked.typ", in: repo), "untracked files went to the Trash")
        XCTAssertEqual(try ws.read("c.typ", in: repo), "c\nstaged edit\n", "staged changes are kept")
        let staged = try ws.change("c.typ", in: manager)
        XCTAssertTrue(staged.isStaged)
        XCTAssertEqual(staged.indexStatus, "M")
        XCTAssertEqual(box.get()?.path, repo.path, "notification object is the repository root")
    }
}
