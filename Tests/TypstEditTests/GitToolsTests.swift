import XCTest
@testable import TypstEdit

/// Git tools for AI Chat. Every test runs against a temporary repository:
/// the user's real repository and git configuration are never touched, and
/// credential prompts cannot appear (the shared fixture points askpass at
/// /usr/bin/false).
@MainActor
final class GitToolsTests: XCTestCase {
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

    // MARK: Helpers

    private func execute(
        _ tool: String,
        _ arguments: [String: Any] = [:],
        in root: URL,
        approve: Bool = true,
        networkRunner: NetworkGitRunner? = nil,
        approvals: ((PendingApprovalKind) -> Void)? = nil,
        permissions: GitToolPermissions = GitToolPermissions(
            enabled: true, fetchEnabled: true, pullEnabled: true, pushEnabled: true
        )
    ) async throws -> String {
        try await GitTools.execute(
            toolName: tool,
            arguments: arguments,
            scope: .project(root: root),
            permissions: { permissions },
            runner: ws.runner,
            networkRunner: networkRunner
        ) { kind in
            approvals?(kind)
            return approve
        }
    }

    private func repoWithCommit() async throws -> URL {
        let repo = try await ws.makeRepo()
        try ws.write("# Hello\n", to: "main.typ", in: repo)
        try await ws.commitAll("initial", in: repo)
        return repo
    }

    // MARK: Opt-in descriptors

    func testDescriptorsAreAbsentUntilGitToolsAreEnabled() {
        let disabled = GitToolPermissions(fetchEnabled: true, pullEnabled: true, pushEnabled: true)
        XCTAssertTrue(GitTools.descriptors(permissions: disabled).isEmpty)
        let local = GitTools.descriptors(permissions: GitToolPermissions(enabled: true)).map(\.name)
        XCTAssertEqual(local.sorted(), ["git_commit", "git_diff", "git_log", "git_stage", "git_status"])
        let all = GitTools.descriptors(permissions: GitToolPermissions(
            enabled: true, fetchEnabled: true, pullEnabled: true, pushEnabled: true
        )).map(\.name)
        XCTAssertTrue(all.contains("git_push"))
        XCTAssertTrue(all.contains("git_pull"))
        XCTAssertTrue(all.contains("git_fetch"))
        XCTAssertFalse(local.contains("git_push"))
        XCTAssertFalse(local.contains("git_pull"))
        XCTAssertFalse(local.contains("git_fetch"))
    }

    func testSubagentWhitelistCannotReachMutatingGitTools() {
        let all = Set(GitTools.descriptors(permissions: GitToolPermissions(
            enabled: true, fetchEnabled: true, pullEnabled: true, pushEnabled: true
        )).map(\.name))
        let readOnly = all.intersection(GitTools.readOnlyToolNames)
        XCTAssertEqual(readOnly, Set(["git_status", "git_diff", "git_log"]))
        XCTAssertFalse(AIChatManager.subagentReadOnlyToolNames.contains("git_commit"))
        XCTAssertFalse(AIChatManager.subagentReadOnlyToolNames.contains("git_push"))
    }

    // MARK: Read-only tools

    func testStatusReportsBranchAndChangeGroups() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)
        try ws.write("new\n", to: "notes.txt", in: repo)
        try ws.write("staged\n", to: "staged.typ", in: repo)

        let output = try await execute("git_status", in: repo)
        XCTAssertTrue(output.contains("Branch: main"), output)
        XCTAssertTrue(output.contains("Not staged (1)"), output)
        XCTAssertTrue(output.contains("  M  main.typ"), output)
        XCTAssertTrue(output.contains("Untracked (2)"), output)
        XCTAssertTrue(output.contains("notes.txt"), output)
    }

    func testStatusIsCleanAfterCommit() async throws {
        let repo = try await repoWithCommit()
        let output = try await execute("git_status", in: repo)
        XCTAssertTrue(output.contains("Working tree clean."), output)
    }

    func testDiffShowsUnstagedAndStagedSides() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)
        let unstaged = try await execute("git_diff", in: repo)
        XCTAssertTrue(unstaged.contains("-# Hello"), unstaged)
        XCTAssertTrue(unstaged.contains("+# Changed"), unstaged)

        _ = try await ws.git(["add", "main.typ"], in: repo)
        let unstagedAfterStaging = try await execute("git_diff", in: repo)
        XCTAssertEqual(unstagedAfterStaging, "No unstaged changes.")
        let staged = try await execute("git_diff", ["staged": true], in: repo)
        XCTAssertTrue(staged.contains("+# Changed"), staged)
    }

    func testDiffOfNamedUntrackedFileShowsAddition() async throws {
        let repo = try await repoWithCommit()
        try ws.write("brand new\n", to: "new.typ", in: repo)
        let output = try await execute("git_diff", ["path": "new.typ"], in: repo)
        XCTAssertTrue(output.contains("+brand new"), output)
    }

    func testDiffWithoutPathMentionsUntrackedFiles() async throws {
        let repo = try await repoWithCommit()
        try ws.write("x\n", to: "untracked.typ", in: repo)
        let output = try await execute("git_diff", in: repo)
        XCTAssertTrue(output.contains("Untracked files are not in this diff"), output)
        XCTAssertTrue(output.contains("untracked.typ"), output)
    }

    func testLogListsRecentCommits() async throws {
        let repo = try await repoWithCommit()
        try ws.write("second\n", to: "main.typ", in: repo)
        try await ws.commitAll("second commit", in: repo)
        let output = try await execute("git_log", ["count": 5], in: repo)
        XCTAssertTrue(output.contains("second commit"), output)
        XCTAssertTrue(output.contains("initial"), output)
        XCTAssertTrue(output.contains("Test User"), output)
    }

    func testLogOnUnbornRepositorySaysNoCommits() async throws {
        let repo = try await ws.makeRepo()
        let output = try await execute("git_log", in: repo)
        XCTAssertEqual(output, "No commits yet.")
    }

    func testStageTreatsPathspecMagicAsLiteralText() async throws {
        let repo = try await repoWithCommit()
        // Two files: one whose name looks like a glob pathspec, one normal.
        try ws.write("magic\n", to: ":(glob)*.typ", in: repo)
        try ws.write("normal\n", to: "other.typ", in: repo)

        _ = try await execute("git_stage", ["paths": [":(glob)*.typ"]], in: repo)
        let staged = try await ws.git(["diff", "--cached", "--name-only"], in: repo)
        XCTAssertTrue(staged.contains(":(glob)*.typ"), staged)
        XCTAssertFalse(staged.contains("other.typ"), "a literal name must never expand into other files")
    }

    // MARK: Scope and path safety

    func testRefusesProjectThatIsNotTheRepositoryRoot() async throws {
        let repo = try await repoWithCommit()
        let subfolder = repo.appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        do {
            _ = try await execute("git_status", in: subfolder)
            XCTFail("expected the subfolder to be refused")
        } catch let error as GitToolError {
            guard case .projectInsideLargerRepository = error else { throw error }
            XCTAssertTrue(error.localizedDescription.contains(repo.lastPathComponent))
        }
    }

    func testRefusesFolderWithoutRepository() async throws {
        let plain = try ws.makeTempDir()
        do {
            _ = try await execute("git_status", in: plain)
            XCTFail("expected a not-a-repository error")
        } catch let error as GitToolError {
            XCTAssertEqual(error, .notARepository)
        }
    }

    func testRefusesNoScope() async throws {
        do {
            _ = try await GitTools.execute(toolName: "git_status", arguments: [:], scope: .none,
                                           permissions: { GitToolPermissions(enabled: true) },
                                           runner: ws.runner) { _ in true }
            XCTFail("expected a no-scope error")
        } catch let error as GitToolError {
            XCTAssertEqual(error, .noScope)
        }
    }

    func testPathValidationRejectsEscapesAndOptionLikeNames() async throws {
        let repo = try await repoWithCommit()
        for bad in [["../outside.typ"], ["/etc/passwd"], ["-rf"], ["a/../../b"], [""], ["."], ["./main.typ"], ["a//b"]] {
            XCTAssertThrowsError(try GitTools.validatedPaths(bad, repository: repo), "\(bad) must be rejected")
        }
        XCTAssertEqual(try GitTools.validatedPaths(["chapters/main.typ", "main.typ"], repository: repo),
                       ["chapters/main.typ", "main.typ"])
    }

    func testStageRejectsZeroAndTooManyPaths() async throws {
        let repo = try await repoWithCommit()
        XCTAssertThrowsError(try GitTools.validatedPaths([], repository: repo))
        let many = (0...100).map { "file\($0).typ" }
        XCTAssertThrowsError(try GitTools.validatedPaths(many, repository: repo))
        XCTAssertThrowsError(try GitTools.validatedPaths([42], repository: repo))
    }

    // MARK: Staging (approval required)

    func testStageNeedsApprovalAndDoesNothingWhenDenied() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)

        var seen: PendingApprovalKind?
        do {
            _ = try await execute("git_stage", ["paths": ["main.typ"]], in: repo, approve: false,
                                  approvals: { seen = $0 })
            XCTFail("expected approval denial")
        } catch let error as LocalToolError {
            guard case .approvalDenied = error else { throw error }
        }
        guard case .gitStage(let paths, let stage)? = seen else {
            return XCTFail("expected a gitStage approval request")
        }
        XCTAssertEqual(paths, ["main.typ"])
        XCTAssertTrue(stage)
        // Denial leaves the index untouched.
        let status = try await ws.git(["status", "--porcelain"], in: repo)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "M main.typ")
    }

    func testStageAndUnstageChangeOnlyTheIndex() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)
        let before = try ws.read("main.typ", in: repo)

        let staged = try await execute("git_stage", ["paths": ["main.typ"]], in: repo)
        XCTAssertTrue(staged.hasPrefix("Staged 1 path"), staged)
        XCTAssertEqual(try ws.read("main.typ", in: repo), before, "staging must not rewrite files")
        let stagedNames = try await ws.git(["diff", "--cached", "--name-only"], in: repo)
        XCTAssertTrue(stagedNames.contains("main.typ"))

        _ = try await execute("git_stage", ["paths": ["main.typ"], "stage": false], in: repo)
        let namesAfterUnstage = try await ws.git(["diff", "--cached", "--name-only"], in: repo)
        XCTAssertFalse(namesAfterUnstage.contains("main.typ"))
        XCTAssertEqual(try ws.read("main.typ", in: repo), before)
    }

    func testCommitNeedsApprovalAndDoesNothingWhenDenied() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)
        _ = try await execute("git_stage", ["paths": ["main.typ"]], in: repo)
        let headBefore = try await ws.git(["rev-parse", "HEAD"], in: repo)

        var seen: PendingApprovalKind?
        do {
            _ = try await execute("git_commit", ["message": "denied"], in: repo, approve: false,
                                  approvals: { seen = $0 })
            XCTFail("expected approval denial")
        } catch let error as LocalToolError {
            guard case .approvalDenied = error else { throw error }
        }
        guard case .gitCommit(let message, let files, _, let stageAll)? = seen else {
            return XCTFail("expected a gitCommit approval request")
        }
        XCTAssertEqual(message, "denied")
        XCTAssertEqual(files, ["main.typ"])
        XCTAssertFalse(stageAll)
        let headAfterDenial = try await ws.git(["rev-parse", "HEAD"], in: repo)
        XCTAssertEqual(headAfterDenial, headBefore)
    }

    func testCommitCreatesCommitWithMessageAndDoesNotPush() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)
        _ = try await execute("git_stage", ["paths": ["main.typ"]], in: repo)

        let output = try await execute("git_commit", ["message": "feat: update heading"], in: repo)
        XCTAssertTrue(output.hasPrefix("Committed "), output)
        XCTAssertTrue(output.contains("feat: update heading"))
        let subject = try await ws.git(["log", "-1", "--format=%s"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(subject, "feat: update heading")
        let statusAfterCommit = try await ws.git(["status", "--porcelain"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(statusAfterCommit, "")
    }

    func testCommitRefusesEmptyMessageAndNothingStaged() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)

        do {
            _ = try await execute("git_commit", ["message": "   "], in: repo)
            XCTFail("expected an empty-message error")
        } catch let error as GitToolError {
            guard case .invalidArguments(let message) = error else { throw error }
            XCTAssertTrue(message.contains("empty"))
        }
        do {
            _ = try await execute("git_commit", ["message": "nothing staged"], in: repo)
            XCTFail("expected a nothing-staged error")
        } catch let error as GitToolError {
            guard case .invalidArguments(let message) = error else { throw error }
            XCTAssertTrue(message.contains("Nothing is staged"))
        }
        let count = try await ws.git(["rev-list", "--count", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(count, "1")
    }

    func testCommitStageAllIncludesUntrackedFiles() async throws {
        let repo = try await repoWithCommit()
        try ws.write("# Changed\n", to: "main.typ", in: repo)
        try ws.write("new\n", to: "new.typ", in: repo)

        var seen: PendingApprovalKind?
        _ = try await execute("git_commit", ["message": "feat: both", "stage_all": true], in: repo,
                              approvals: { seen = $0 })
        guard case .gitCommit(_, let files, _, let stageAll)? = seen else {
            return XCTFail("expected a gitCommit approval request")
        }
        XCTAssertTrue(stageAll)
        XCTAssertEqual(files.sorted(), ["main.typ", "new.typ"])
        let names = try await ws.git(["show", "--name-only", "--format=", "HEAD"], in: repo)
        XCTAssertTrue(names.contains("main.typ") && names.contains("new.typ"), names)
    }

    // MARK: Independent permissions

    func testDisabledNetworkCallsAreBlockedBeforeApproval() async throws {
        let repo = try await repoWithCommit()
        let local = GitToolPermissions(enabled: true)
        var approvals = 0
        for tool in ["git_fetch", "git_pull", "git_push"] {
            do {
                _ = try await execute(tool, in: repo, approvals: { _ in approvals += 1 }, permissions: local)
                XCTFail("Disabled \(tool) must not execute")
            } catch let error as GitToolError {
                XCTAssertEqual(error, .permissionDenied(tool))
            }
        }
        XCTAssertEqual(approvals, 0)
    }

    func testPullPermissionDoesNotAuthorizePush() async throws {
        let repo = try await repoWithCommit()
        let pullOnly = GitToolPermissions(enabled: true, pullEnabled: true)
        do {
            _ = try await execute("git_push", in: repo, permissions: pullOnly)
            XCTFail("Pull must not grant Push")
        } catch let error as GitToolError {
            XCTAssertEqual(error, .permissionDenied("git_push"))
        }
    }

    func testLocalCommitWithMessageNeverPublishesToConfiguredRemote() async throws {
        let repo = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: repo)
        let remoteBefore = try await ws.git(["rev-parse", "main"], in: bare)
        try ws.write("Local only\n", to: "main.typ", in: repo)

        let local = GitToolPermissions(enabled: true)
        _ = try await execute("git_commit", ["message": "Review before publishing", "stage_all": true],
                              in: repo, permissions: local)
        let subject = try await ws.git(["log", "-1", "--format=%s"], in: repo)
        XCTAssertEqual(subject.trimmingCharacters(in: .newlines), "Review before publishing")
        let remoteAfter = try await ws.git(["rev-parse", "main"], in: bare)
        let localAfter = try await ws.git(["rev-parse", "HEAD"], in: repo)
        XCTAssertEqual(remoteBefore, remoteAfter, "Creating a commit must not change the remote")
        XCTAssertNotEqual(localAfter, remoteAfter)
    }

    func testCommitRejectsMissingMessageBeforeApproval() async throws {
        let repo = try await repoWithCommit()
        var approvals = 0
        do {
            _ = try await execute("git_commit", ["stage_all": true], in: repo,
                                  approvals: { _ in approvals += 1 })
            XCTFail("A commit requires a message")
        } catch let error as GitToolError {
            XCTAssertEqual(error, .invalidArguments("message is required."))
        }
        XCTAssertEqual(approvals, 0)
    }

    func testRevokingPermissionWhileApprovingPreventsMutation() async throws {
        let repo = try await repoWithCommit()
        try ws.write("Not staged\n", to: "main.typ", in: repo)
        var permissions = GitToolPermissions(enabled: true)
        do {
            _ = try await GitTools.execute(toolName: "git_stage", arguments: ["paths": ["main.typ"]],
                                           scope: .project(root: repo), permissions: { permissions },
                                           runner: ws.runner) { _ in
                permissions.enabled = false
                return true
            }
            XCTFail("Permission revoked while reviewing must block the action")
        } catch let error as LocalToolError {
            guard case .approvalDenied = error else { throw error }
        }
        let index = try await ws.git(["diff", "--cached", "--name-only"], in: repo)
        XCTAssertTrue(index.isEmpty)
    }

    func testPushApprovalCanBeDeniedOrPermissionRevokedWithoutPublishing() async throws {
        let repo = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: repo)
        let remoteBefore = try await ws.git(["rev-parse", "main"], in: bare)
        try ws.write("Unpublished\n", to: "main.typ", in: repo)
        try await ws.commitAll("Wait for review", in: repo)
        let network = NetworkGitRunner(runner: ws.runner, timeout: 30)

        for approve in [false, true] {
            var permissions = GitToolPermissions(enabled: true, pushEnabled: true)
            do {
                _ = try await GitTools.execute(toolName: "git_push", arguments: [:],
                                               scope: .project(root: repo), permissions: { permissions },
                                               runner: ws.runner, networkRunner: network) { kind in
                    guard case .gitNetwork(operation: .push, branch: "main", upstream: "origin/main") = kind else {
                        XCTFail("Push must show the branch and upstream for review")
                        return false
                    }
                    if approve { permissions.pushEnabled = false }
                    return approve
                }
                XCTFail("An unapproved push must not publish")
            } catch let error as LocalToolError {
                guard case .approvalDenied = error else { throw error }
            }
            let remoteAfter = try await ws.git(["rev-parse", "main"], in: bare)
            XCTAssertEqual(remoteBefore, remoteAfter)
        }
    }

    // MARK: Network tools

    func testPushRefusesCommitsChangedDuringApproval() async throws {
        let repo = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: repo)
        let remoteBefore = try await ws.git(["rev-parse", "main"], in: bare)
        let network = NetworkGitRunner(runner: ws.runner, timeout: 30)
        do {
            _ = try await GitTools.execute(toolName: "git_push", arguments: [:], scope: .project(root: repo),
                                           permissions: { GitToolPermissions(enabled: true, pushEnabled: true) },
                                           runner: ws.runner, networkRunner: network) { _ in
                do {
                    try self.ws.write("Changed during review\n", to: "main.typ", in: repo)
                    try await self.ws.commitAll("Not reviewed", in: repo)
                    return true
                } catch {
                    XCTFail("Fixture failed: \(error)")
                    return false
                }
            }
            XCTFail("Push must refuse commits not included in the review")
        } catch let error as GitToolError {
            guard case .invalidArguments(let message) = error else { throw error }
            XCTAssertTrue(message.contains("changed during review"), message)
        }
        let remoteAfter = try await ws.git(["rev-parse", "main"], in: bare)
        XCTAssertEqual(remoteBefore, remoteAfter)
    }

    func testPushRefusesDestinationChangedDuringApproval() async throws {
        let repo = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        let otherBare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: repo)
        let remoteBefore = try await ws.git(["rev-parse", "main"], in: bare)
        let network = NetworkGitRunner(runner: ws.runner, timeout: 30)
        do {
            _ = try await GitTools.execute(toolName: "git_push", arguments: [:], scope: .project(root: repo),
                                           permissions: { GitToolPermissions(enabled: true, pushEnabled: true) },
                                           runner: ws.runner, networkRunner: network) { _ in
                do {
                    _ = try await self.ws.git(["remote", "set-url", "--push", "origin", otherBare.path], in: repo)
                    return true
                } catch {
                    XCTFail("Fixture failed: \(error)")
                    return false
                }
            }
            XCTFail("Push must refuse a destination not included in the review")
        } catch let error as GitToolError {
            guard case .invalidArguments(let message) = error else { throw error }
            XCTAssertTrue(message.contains("changed during review"), message)
        }
        let remoteAfter = try await ws.git(["rev-parse", "main"], in: bare)
        let otherRefs = try await ws.git(["for-each-ref", "--format=%(refname)"], in: otherBare)
        XCTAssertEqual(remoteBefore, remoteAfter)
        XCTAssertTrue(otherRefs.isEmpty)
    }

    func testPushOnlyPublishesReviewedBranchIgnoringPushDefaults() async throws {
        let repo = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        let otherBare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: repo)
        _ = try await ws.git(["branch", "feature"], in: repo)
        _ = try await ws.git(["push", "-q", "origin", "feature"], in: repo)
        let featureBefore = try await ws.git(["rev-parse", "feature"], in: bare)
        try ws.write("Approved main commit\n", to: "main.typ", in: repo)
        try await ws.commitAll("Only publish main", in: repo)
        _ = try await ws.git(["branch", "-f", "feature", "HEAD"], in: repo)
        _ = try await ws.git(["tag", "-a", "private-tag", "-m", "Do not publish"], in: repo)
        _ = try await ws.git(["config", "push.default", "matching"], in: repo)
        _ = try await ws.git(["config", "push.followTags", "true"], in: repo)
        _ = try await ws.git(["remote", "add", "alternate", otherBare.path], in: repo)
        _ = try await ws.git(["config", "branch.main.pushRemote", "alternate"], in: repo)

        _ = try await execute("git_push", in: repo,
                              networkRunner: NetworkGitRunner(runner: ws.runner, timeout: 30))
        let localHead = try await ws.git(["rev-parse", "HEAD"], in: repo)
        let remoteMain = try await ws.git(["rev-parse", "main"], in: bare)
        let remoteFeature = try await ws.git(["rev-parse", "feature"], in: bare)
        let tags = try await ws.git(["tag", "--list"], in: bare)
        let otherRefs = try await ws.git(["for-each-ref", "--format=%(refname)"], in: otherBare)
        XCTAssertEqual(localHead, remoteMain)
        XCTAssertEqual(featureBefore, remoteFeature, "Push must not publish other branches")
        XCTAssertTrue(tags.isEmpty, "Push must not publish unreviewed tags")
        XCTAssertTrue(otherRefs.isEmpty, "Push must use the approved upstream, not pushRemote")
    }

    func testNetworkToolsRefuseWithoutUpstream() async throws {
        let repo = try await repoWithCommit()
        for tool in ["git_push", "git_pull"] {
            do {
                _ = try await execute(tool, in: repo)
                XCTFail("\(tool) must refuse without an upstream")
            } catch let error as GitToolError {
                guard case .invalidArguments(let message) = error else { throw error }
                XCTAssertTrue(message.contains("upstream"), message)
            }
        }
    }

    func testFetchPushAndPullAgainstLocalRemote() async throws {
        let work = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: work)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: work)

        let network = NetworkGitRunner(runner: ws.runner, timeout: 30)

        // Push a new commit through the tool.
        try ws.write("# Pushed\n", to: "main.typ", in: work)
        _ = try await execute("git_stage", ["paths": ["main.typ"]], in: work)
        _ = try await execute("git_commit", ["message": "feat: pushed"], in: work)
        let pushOutput = try await execute("git_push", in: work, networkRunner: network)
        XCTAssertTrue(pushOutput.contains("Pushed main to origin/main"), pushOutput)
        let pushedSubject = try await ws.git(["log", "-1", "--format=%s", "main"], in: bare)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(pushedSubject, "feat: pushed")

        // A second clone pushes an older-then-newer commit; the work tree pulls it.
        let other = try ws.makeTempDir()
        _ = try await ws.git(["clone", "-q", bare.path, other.path], in: other)
        try ws.write("# From other\n", to: "other.typ", in: other)
        _ = try await ws.git(["add", "-A"], in: other)
        _ = try await ws.git(["commit", "-q", "-m", "feat: from other"], in: other)
        _ = try await ws.git(["push", "-q", "origin", "main"], in: other)

        let fetchOutput = try await execute("git_fetch", in: work, networkRunner: network)
        XCTAssertTrue(fetchOutput.contains("Fetched"), fetchOutput)
        let pullOutput = try await execute("git_pull", in: work, networkRunner: network)
        XCTAssertFalse(pullOutput.isEmpty)
        XCTAssertTrue(ws.exists("other.typ", in: work), "pull must update the working tree")
    }

    func testDivergedPullFailsWithoutMerging() async throws {
        let work = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: work)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: work)

        let other = try ws.makeTempDir()
        _ = try await ws.git(["clone", "-q", bare.path, other.path], in: other)
        try ws.write("other\n", to: "other.typ", in: other)
        _ = try await ws.git(["add", "-A"], in: other)
        _ = try await ws.git(["commit", "-q", "-m", "remote change"], in: other)
        _ = try await ws.git(["push", "-q", "origin", "main"], in: other)

        try ws.write("local\n", to: "main.typ", in: work)
        _ = try await ws.git(["add", "-A"], in: work)
        _ = try await ws.git(["commit", "-q", "-m", "local change"], in: work)

        let network = NetworkGitRunner(runner: ws.runner, timeout: 30)
        do {
            _ = try await execute("git_pull", in: work, networkRunner: network)
            XCTFail("expected a fast-forward refusal")
        } catch is GitError {
            // A clean failure; no merge commit is created.
        }
        let countAfterDivergedPull = try await ws.git(["rev-list", "--count", "HEAD"], in: work)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(countAfterDivergedPull, "2")
    }

    func testNetworkApprovalShowsOperationBranchAndRemote() async throws {
        let repo = try await repoWithCommit()
        let bare = try await ws.makeRepo(bare: true)
        _ = try await ws.git(["remote", "add", "origin", bare.path], in: repo)
        _ = try await ws.git(["push", "-q", "-u", "origin", "main"], in: repo)
        let network = NetworkGitRunner(runner: ws.runner, timeout: 30)

        var seen: PendingApprovalKind?
        do {
            _ = try await execute("git_fetch", in: repo, approve: false, networkRunner: network,
                                  approvals: { seen = $0 })
            XCTFail("expected approval denial")
        } catch let error as LocalToolError {
            guard case .approvalDenied = error else { throw error }
        }
        guard case .gitNetwork(let operation, let branch, let upstream)? = seen else {
            return XCTFail("expected a gitNetwork approval request")
        }
        XCTAssertEqual(operation, .fetch)
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(upstream, "origin/main")
    }

    // MARK: Refusals during an operation

    func testCommitRefusedDuringMergeConflict() async throws {
        let repo = try await repoWithCommit()
        _ = try await ws.git(["checkout", "-q", "-b", "feature"], in: repo)
        try ws.write("feature\n", to: "main.typ", in: repo)
        try await ws.commitAll("feature change", in: repo)
        _ = try await ws.git(["checkout", "-q", "main"], in: repo)
        try ws.write("main\n", to: "main.typ", in: repo)
        try await ws.commitAll("main change", in: repo)
        _ = try? await ws.git(["merge", "--no-edit", "feature"], in: repo)

        do {
            _ = try await execute("git_commit", ["message": "resolve"], in: repo)
            XCTFail("expected a refusal while merging")
        } catch let error as GitToolError {
            guard case .invalidArguments(let message) = error else { throw error }
            XCTAssertTrue(message.contains("progress") || message.contains("conflict"), message)
        }
    }
}
