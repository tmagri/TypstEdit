import Foundation

/// Git tools for AI Chat. Opt-in only: the descriptors are absent unless the
/// user turns Git tools on. Fetch, Pull and Push each need their own opt-in;
/// enabling local commits never enables a network action.
///
/// Safety rules:
/// - Git tools work only when the active chat scope folder *is* the repository
///   root. A project opened inside a larger repository therefore gets no Git
///   tools, so the assistant can never change a repository the user did not
///   open.
/// - Every path argument is relative, checked for `..`, absolute paths and
///   leading `-`, and contained in the scope root.
/// - Read-only tools need no approval. Every other tool shows the exact plan
///   (paths, message, branch, upstream) and needs an approval per call.
/// - Nothing here force-pushes, hard-resets, rebases, discards your working
///   tree, rewrites history, or changes branches. The source-control panel
///   remains the place for those actions.
/// - Git runs with the app's sanitized environment, so an AI-supplied value
///   can never redirect it to another repository or index.
@MainActor
enum GitTools {
    static let namespace = "git"

    /// Tools a read-only agent (delegate_task) may use.
    static let readOnlyToolNames: Set<String> = ["git_status", "git_diff", "git_log"]

    /// Installed once per app run, on first network action.
    private static var askpassScriptURL: URL?

    // MARK: - Descriptors

    static func descriptors(permissions: GitToolPermissions) -> [MCPTool] {
        guard permissions.enabled else { return [] }
        var tools: [MCPTool] = [
            MCPTool(
                serverName: namespace,
                name: "git_status",
                description: "Show the Git state of the open project: branch, upstream, ahead/behind counts, staged and unstaged files, untracked files, merge conflicts, and any merge/rebase in progress. Read-only.",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
            MCPTool(
                serverName: namespace,
                name: "git_diff",
                description: "Show a unified diff of saved file changes. Without a path, shows all unstaged tracked changes. Use staged:true for the changes that would be committed. Read-only; untracked files are shown when you name them.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Optional path relative to the project root. Omit to diff the whole working tree."],
                        "staged": ["type": "boolean", "description": "Compare HEAD with the index (staged changes) instead of the index with the working tree. Default false."],
                    ],
                ]
            ),
            MCPTool(
                serverName: namespace,
                name: "git_log",
                description: "Show recent commits (hash, author, date, subject) for the branch. Read-only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "count": ["type": "integer", "description": "How many commits to show, 1–30. Default 10."],
                        "path": ["type": "string", "description": "Optional path relative to the project root, to show only commits that touched it."],
                    ],
                ]
            ),
            MCPTool(
                serverName: namespace,
                name: "git_stage",
                description: "Stage or unstage files. The user sees the exact file list and must approve. Staging never changes file contents.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "paths": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Paths relative to the project root (1–100).",
                        ],
                        "stage": ["type": "boolean", "description": "true stages the paths; false unstages them. Default true."],
                    ],
                    "required": ["paths"],
                ]
            ),
            MCPTool(
                serverName: namespace,
                name: "git_commit",
                description: "Commit staged changes with a message. The user sees the message and the staged file list and must approve. Does not push. Use git_stage first unless stage_all is true.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "message": ["type": "string", "minLength": 1, "description": "Required, non-empty commit message. Explain why, not only what."],
                        "stage_all": ["type": "boolean", "description": "Stage every change (including untracked files) before committing. Default false."],
                    ],
                    "required": ["message"],
                ]
            ),
        ]
        let networkTools = [
            MCPTool(
                serverName: namespace,
                name: "git_fetch",
                description: "Fetch from the remote and update remote-tracking branches. Never changes your files or local branches. The user must approve.",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
            MCPTool(
                serverName: namespace,
                name: "git_pull",
                description: "Pull the current branch with fast-forward only. Fails instead of creating a merge commit; the user must approve. Requires an upstream branch.",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
            MCPTool(
                serverName: namespace,
                name: "git_push",
                description: "Push the current branch to its existing upstream. Requires the separate Push permission and explicit user approval every time, even in YOLO mode. Never force-pushes, never sets a new upstream.",
                inputSchema: ["type": "object", "properties": [String: Any]()]
            ),
        ]
        tools += networkTools.filter { permissions.allows($0.name) }
        return tools
    }

    // MARK: - Execution

    static func execute(
        toolName: String,
        arguments: [String: Any],
        scope: LocalToolExecutor.Scope,
        permissions: @escaping () -> GitToolPermissions = { GitToolPermissions() },
        runner: GitRunner = GitRunner(),
        networkRunner: NetworkGitRunner? = nil,
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        // Check at execution time too, not only when descriptors are sent.
        // This blocks stale tool calls after a user revokes a permission.
        guard permissions().allows(toolName) else {
            throw GitToolError.permissionDenied(toolName)
        }
        guard let root = scope.root else {
            throw GitToolError.noScope
        }
        let repository = try await repositoryRoot(for: root, runner: runner)
        let approval: (PendingApprovalKind) async -> Bool = { kind in
            guard !Task.isCancelled, permissions().allows(toolName) else { return false }
            let approved = await requestApproval(kind)
            // Settings can change while the approval card is open.
            return approved && !Task.isCancelled && permissions().allows(toolName)
        }

        switch toolName {
        case "git_status":
            return try await status(repository: repository, runner: runner)
        case "git_diff":
            return try await diff(repository: repository, arguments: arguments, runner: runner)
        case "git_log":
            return try await log(repository: repository, arguments: arguments, runner: runner)
        case "git_stage":
            return try await stage(repository: repository, arguments: arguments, runner: runner,
                                   requestApproval: approval)
        case "git_commit":
            return try await commit(repository: repository, arguments: arguments, runner: runner,
                                    requestApproval: approval)
        case "git_fetch":
            return try await fetch(repository: repository, runner: runner, networkRunner: networkRunner,
                                   requestApproval: approval)
        case "git_pull":
            return try await pull(repository: repository, runner: runner, networkRunner: networkRunner,
                                  requestApproval: approval)
        case "git_push":
            return try await push(repository: repository, runner: runner, networkRunner: networkRunner,
                                  requestApproval: approval)
        default:
            throw GitToolError.unknownTool(toolName)
        }
    }

    // MARK: - Repository and scope

    /// Resolves the repository and requires it to be the chat scope folder
    /// itself, so Git tools never act on a parent repository.
    static func repositoryRoot(for scopeRoot: URL, runner: GitRunner) async throws -> URL {
        let root = scopeRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitToolError.noScope
        }
        let result = try await runner.runRaw(["rev-parse", "--show-toplevel"], in: root)
        guard result.exitCode == 0 else {
            throw GitToolError.notARepository
        }
        let top = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty else { throw GitToolError.notARepository }
        let repository = URL(fileURLWithPath: top, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard repository.path == root.path else {
            throw GitToolError.projectInsideLargerRepository(
                project: root.lastPathComponent, repository: repository.lastPathComponent
            )
        }
        return repository
    }

    /// Relative paths only, no `..`, no absolute paths, no leading `-`.
    /// Contained in the repository root after normalization.
    static func validatedPaths(_ raw: Any?, repository: URL) throws -> [String] {
        guard let values = raw as? [Any], !values.isEmpty else {
            throw GitToolError.invalidArguments("paths must be a non-empty array of relative paths.")
        }
        guard values.count <= 100 else {
            throw GitToolError.invalidArguments("Pass 100 paths at most per call.")
        }
        var result: [String] = []
        for value in values {
            guard let rawPath = value as? String else {
                throw GitToolError.invalidArguments("paths must contain only strings.")
            }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.hasPrefix("-"), !path.hasPrefix("/"), !path.contains("\0") else {
                throw GitToolError.invalidArguments("'\(rawPath)' is not a relative path inside the project.")
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(".."), !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." }) else {
                throw GitToolError.invalidArguments("'\(rawPath)' is not a relative path inside the project.")
            }
            let resolved = repository.appendingPathComponent(path).standardizedFileURL
            guard resolved.path.hasPrefix(repository.path + "/") else {
                throw GitToolError.invalidArguments("'\(rawPath)' is outside the project.")
            }
            result.append(path)
        }
        return result
    }

    // MARK: - Read-only tools

    private static func snapshot(repository: URL, runner: GitRunner) async throws -> GitStatusSnapshot {
        let result = try await runner.run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--renames"],
            in: repository
        )
        return GitOutputParser.parseStatusV2(result.stdout)
    }

    private static func status(repository: URL, runner: GitRunner) async throws -> String {
        let status = try await snapshot(repository: repository, runner: runner)
        let operation = await SourceControlManager.operationState(root: repository, runner: runner)

        var lines: [String] = []
        var head: [String] = []
        head.append("Branch: \(status.headBranch ?? "detached HEAD (no branch)")")
        if status.isUnborn { head.append("No commits yet") }
        if let upstream = status.upstream {
            head.append("Upstream: \(upstream) (ahead \(status.ahead), behind \(status.behind))")
        }
        if let operation = operationLabel(operation) {
            head.append("\(operation) in progress — finish or abort it in the Source Control panel.")
        }
        lines.append(head.joined(separator: " · "))

        func list(_ title: String, _ changes: [GitChange], _ group: GitChangeGroup) {
            guard !changes.isEmpty else { return }
            lines.append("")
            lines.append("\(title) (\(changes.count)):")
            for change in changes {
                let letter = change.isConflicted ? "U" : change.statusLetter(for: group)
                var line = "  \(letter)  \(change.path)"
                if let original = change.originalPath, original != change.path { line += " ← \(original)" }
                lines.append(line)
            }
        }
        list("Conflicts", status.changes.filter(\.isConflicted), .unstaged)
        list("Staged", status.changes.filter { $0.isStaged && !$0.isConflicted }, .staged)
        list("Not staged", status.changes.filter { $0.isUnstaged && !$0.isConflicted }.filter { !$0.isUntracked }, .unstaged)
        list("Untracked", status.changes.filter(\.isUntracked), .unstaged)
        if status.changes.isEmpty && operation == .none {
            lines.append("Working tree clean.")
        }
        return lines.joined(separator: "\n")
    }

    private static func diff(repository: URL, arguments: [String: Any], runner: GitRunner) async throws -> String {
        let staged = arguments["staged"] as? Bool ?? false
        var path: String?
        if let rawPath = arguments["path"] as? String {
            path = try validatedPaths([rawPath], repository: repository).first
        }

        let base = ["diff", "--no-color", "--no-ext-diff", "--find-renames", "--no-relative"]
        let output: String
        if let path {
            let status = try await snapshot(repository: repository, runner: runner)
            let isUntracked = status.changes.contains { $0.isUntracked && $0.path == path }
            if isUntracked && !staged {
                let result = try await runner.run(
                    GitRunner.literalPathArguments + base + ["--no-index", "--", "/dev/null", path],
                    in: repository,
                    acceptedExitCodes: [0, 1]
                )
                output = result.stdoutString
            } else {
                let result = try await runner.run(
                    GitRunner.literalPathArguments + base + (staged ? ["--cached"] : []) + ["--"] + [path],
                    in: repository
                )
                output = result.stdoutString
            }
        } else {
            let result = try await runner.run(base + (staged ? ["--cached"] : []), in: repository)
            var text = result.stdoutString
            if !staged {
                let status = try await snapshot(repository: repository, runner: runner)
                let untracked = status.changes.filter(\.isUntracked).map(\.path)
                if !untracked.isEmpty {
                    text += "\n\nUntracked files are not in this diff. Name one with the path argument to see it: "
                        + untracked.prefix(10).joined(separator: ", ")
                }
            }
            output = text
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return staged ? "No staged changes." : "No unstaged changes."
        }
        return truncate(output)
    }

    private static func log(repository: URL, arguments: [String: Any], runner: GitRunner) async throws -> String {
        var count = (arguments["count"] as? Int) ?? 10
        if let number = arguments["count"] as? Double { count = Int(number) }
        count = min(30, max(1, count))

        var args = GitRunner.literalPathArguments
            + ["log", "--no-color", "--date=short", "-n", String(count),
               "--format=%h%x09%ad%x09%an%x09%s"]
        if let rawPath = arguments["path"] as? String {
            let path = try validatedPaths([rawPath], repository: repository)[0]
            args += ["--", path]
        }
        let result = try await runner.run(args, in: repository, acceptedExitCodes: [0, 128])
        guard result.exitCode == 0 else { return "No commits yet." }
        let lines = result.stdoutString.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return "No commits yet." }
        return lines.map { line -> String in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return String(line) }
            return "\(parts[0])  \(parts[1])  \(parts[2])\n    \(parts[3])"
        }.joined(separator: "\n")
    }

    // MARK: - Local mutations (approval required)

    private static func stage(
        repository: URL,
        arguments: [String: Any],
        runner: GitRunner,
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        let paths = try validatedPaths(arguments["paths"], repository: repository)
        let shouldStage = arguments["stage"] as? Bool ?? true
        guard await requestApproval(.gitStage(paths: paths, stage: shouldStage)) else {
            throw LocalToolError.approvalDenied
        }
        let status = try await snapshot(repository: repository, runner: runner)
        let literal = GitRunner.literalPathArguments
        if shouldStage {
            _ = try await runner.run(literal + ["add", "-A", "--"] + paths, in: repository)
        } else if status.isUnborn {
            _ = try await runner.run(literal + ["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--"] + paths,
                                     in: repository)
        } else {
            _ = try await runner.run(literal + ["reset", "-q", "HEAD", "--"] + paths, in: repository)
        }
        notifyChanged(repository: repository, workingTree: false)
        let verb = shouldStage ? "Staged" : "Unstaged"
        return "\(verb) \(paths.count) path\(paths.count == 1 ? "" : "s"): \(paths.joined(separator: ", "))"
    }

    private static func commit(
        repository: URL,
        arguments: [String: Any],
        runner: GitRunner,
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        guard let rawMessage = arguments["message"] as? String else {
            throw GitToolError.invalidArguments("message is required.")
        }
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw GitToolError.invalidArguments("The commit message is empty.")
        }
        guard message.count <= 10_000 else {
            throw GitToolError.invalidArguments("The commit message is too long.")
        }
        let stageAll = arguments["stage_all"] as? Bool ?? false

        var status = try await snapshot(repository: repository, runner: runner)
        let operation = await SourceControlManager.operationState(root: repository, runner: runner)
        guard operation == .none else {
            throw GitToolError.invalidArguments("A \(operationLabel(operation) ?? "Git operation") is in progress. Finish or abort it in the Source Control panel first.")
        }
        guard !status.changes.contains(where: \.isConflicted) else {
            throw GitToolError.invalidArguments("Resolve the merge conflicts in the Source Control panel first.")
        }
        var toStage: [String] = []
        if stageAll {
            toStage = status.changes.map(\.path).sorted()
            guard !toStage.isEmpty else { throw GitToolError.invalidArguments("There is nothing to commit.") }
        } else {
            guard status.changes.contains(where: \.isStaged) else {
                throw GitToolError.invalidArguments("Nothing is staged. Call git_stage first, or pass stage_all: true.")
            }
        }
        let branch = status.headBranch ?? "detached HEAD"
        let approved = await requestApproval(.gitCommit(
            message: message, files: stageAll ? toStage : status.changes.filter(\.isStaged).map(\.path).sorted(),
            branch: branch, stageAll: stageAll
        ))
        guard approved else { throw LocalToolError.approvalDenied }

        if stageAll {
            _ = try await runner.run(["add", "-A"], in: repository)
            status = try await snapshot(repository: repository, runner: runner)
        }
        let result = try await runner.run(
            ["commit", "-q", "--file=-", "--cleanup=strip"],
            in: repository,
            input: Data(message.utf8)
        )
        notifyChanged(repository: repository, workingTree: false)
        let hashResult = try await runner.run(["rev-parse", "--short", "HEAD"], in: repository)
        let hash = hashResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Committed \(hash) on \(branch): \(message)\n\(summary)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Network actions (separate opt-in + approval)

    private static func fetch(
        repository: URL,
        runner: GitRunner,
        networkRunner: NetworkGitRunner?,
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        let status = try await snapshot(repository: repository, runner: runner)
        guard await requestApproval(.gitNetwork(operation: .fetch, branch: status.headBranch ?? "detached HEAD", upstream: status.upstream)) else {
            throw LocalToolError.approvalDenied
        }
        let network = networkRunner ?? defaultNetworkRunner(base: runner)
        _ = try await network.run(["fetch", "--all", "--prune", "--quiet"], in: repository)
        notifyChanged(repository: repository, workingTree: false)
        return "Fetched from the remote. Local branches and files are unchanged."
    }

    private static func pull(
        repository: URL,
        runner: GitRunner,
        networkRunner: NetworkGitRunner?,
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        let status = try await snapshot(repository: repository, runner: runner)
        guard let upstream = status.upstream else {
            throw GitToolError.invalidArguments("The current branch has no upstream. Publish it in the Source Control panel first.")
        }
        guard await requestApproval(.gitNetwork(operation: .pull, branch: status.headBranch ?? "detached HEAD", upstream: upstream)) else {
            throw LocalToolError.approvalDenied
        }
        let network = networkRunner ?? defaultNetworkRunner(base: runner)
        let result = try await network.run(["pull", "--no-rebase", "--ff-only", "--quiet"], in: repository)
        notifyChanged(repository: repository, workingTree: true)
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "Pulled \(upstream) (fast-forward only)." : truncate(output)
    }

    private static func push(
        repository: URL,
        runner: GitRunner,
        networkRunner: NetworkGitRunner?,
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        let target = try await pushTarget(repository: repository, runner: runner)
        guard await requestApproval(.gitNetwork(operation: .push, branch: target.branch, upstream: target.upstream)) else {
            throw LocalToolError.approvalDenied
        }
        guard try await pushTarget(repository: repository, runner: runner) == target else {
            throw GitToolError.invalidArguments("The branch, commits, or push destination changed during review. Request Push again to review the new target.")
        }
        let network = networkRunner ?? defaultNetworkRunner(base: runner)
        // Pin the approved commit and upstream. Explicit arguments override
        // matching/default push settings and prevent extra tags/submodules
        // from being published alongside the reviewed branch.
        _ = try await network.run([
            "push", "--quiet", "--no-force", "--no-follow-tags", "--recurse-submodules=no",
            "--", target.remote, "\(target.headOID):\(target.remoteRef)"
        ], in: repository)
        notifyChanged(repository: repository, workingTree: false)
        return "Pushed \(target.branch) to \(target.upstream)."
    }

    private struct PushTarget: Equatable {
        let branch: String
        let headOID: String
        let upstream: String
        let remote: String
        let remoteRef: String
        let pushURLs: String
    }

    private static func pushTarget(repository: URL, runner: GitRunner) async throws -> PushTarget {
        let status = try await snapshot(repository: repository, runner: runner)
        guard let branch = status.headBranch else {
            throw GitToolError.invalidArguments("HEAD is detached. Check out a branch in the Source Control panel first.")
        }
        guard let upstream = status.upstream else {
            throw GitToolError.invalidArguments("The branch has no upstream. Publish it in the Source Control panel first.")
        }
        guard let headOID = status.headOID else {
            throw GitToolError.invalidArguments("Create a local commit before pushing.")
        }
        let info = try await runner.run([
            "for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)", "refs/heads/\(branch)"
        ], in: repository)
        let fields = info.stdoutString.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 2 else {
            throw GitToolError.invalidArguments("The branch has no valid remote upstream.")
        }
        let remote = String(fields[0])
        let remoteRef = String(fields[1]).trimmingCharacters(in: .newlines)
        guard !remote.isEmpty, remote != ".", remoteRef.hasPrefix("refs/heads/") else {
            throw GitToolError.invalidArguments("AI Push requires an upstream branch on a configured remote.")
        }
        let urls = try await runner.run(["remote", "get-url", "--push", "--all", "--", remote], in: repository)
        return PushTarget(branch: branch, headOID: headOID, upstream: upstream,
                          remote: remote, remoteRef: remoteRef, pushURLs: urls.stdoutString)
    }

    /// Builds the network runner with the same credential dialogs and timeout
    /// as the Source Control panel.
    static func defaultNetworkRunner(base: GitRunner) -> NetworkGitRunner {
        if askpassScriptURL == nil {
            askpassScriptURL = GitAskpass.installAskpassScript()
        }
        var runner = base
        var activityURL: URL?
        if let script = askpassScriptURL {
            runner.environmentOverrides.merge(GitAskpass.environment(for: script)) { _, new in new }
            activityURL = GitAskpass.activityFileURL(forScript: script)
        }
        return NetworkGitRunner(runner: runner, timeout: 300, askpassActivityURL: activityURL)
    }

    // MARK: - Helpers

    /// Keeps the explorer and the source-control panel in step, and tells
    /// open editor windows to reload a file a pull or checkout rewrote.
    private static func notifyChanged(repository: URL, workingTree: Bool) {
        NotificationCenter.default.post(name: .refreshProjectSidebar, object: nil)
        if workingTree {
            NotificationCenter.default.post(name: .gitWorkingTreeDidChange, object: repository)
        }
    }

    private static func operationLabel(_ state: GitOperationState) -> String? {
        switch state {
        case .none: return nil
        case .merging: return "Merge"
        case .rebasing: return "Rebase"
        case .cherryPicking: return "Cherry-pick"
        case .reverting: return "Revert"
        }
    }

    private static func truncate(_ text: String, limit: Int = 60_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n… output truncated at \(limit) characters."
    }
}

enum GitToolError: LocalizedError, Equatable {
    case permissionDenied(String)
    case noScope
    case notARepository
    case projectInsideLargerRepository(project: String, repository: String)
    case invalidArguments(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let name):
            return "\(name) is not allowed. Enable its permission in Settings → AI Chat → Git Tools."
        case .noScope:
            return "Git tools need an open project or notebook folder."
        case .notARepository:
            return "This project folder is not a Git repository. Git tools are off until you initialize one."
        case .projectInsideLargerRepository(let project, let repository):
            return "The folder '\(project)' is inside the repository '\(repository)', not its root. Open '\(repository)' as the project to let AI Chat use Git."
        case .invalidArguments(let message):
            return message
        case .unknownTool(let name):
            return "Unknown Git tool '\(name)'."
        }
    }
}
