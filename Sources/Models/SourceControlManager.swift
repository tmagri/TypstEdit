import Foundation
import Combine

extension Notification.Name {
    /// Posted (object: repository root URL, standardized) after any git operation that may have
    /// rewritten files in the working tree. Editor windows reload clean buffers inside that root.
    static let gitWorkingTreeDidChange = Notification.Name("TypstEdit.gitWorkingTreeDidChange")
}

// MARK: - Public model types

/// Which side of the index a change is shown on in the Source Control UI.
enum GitChangeGroup: String, Sendable {
    case staged
    case unstaged
}

/// One path reported by `git status`. A path that has both staged and
/// unstaged modifications is represented once, with both flags set.
///
/// `indexStatus` / `worktreeStatus` use porcelain-v1 style single letters:
/// `" "` unmodified, `M` modified, `A` added, `D` deleted, `R` renamed,
/// `C` copied, `T` type change, `U` unmerged, `?` untracked.
struct GitChange: Identifiable, Hashable, Sendable {
    /// Path relative to the repository root (the new path for renames).
    var id: String
    var path: String
    /// Original path for renames/copies (relative to the repository root).
    var originalPath: String?
    var indexStatus: String
    var worktreeStatus: String
    var isStaged: Bool
    var isUnstaged: Bool
    var isUntracked: Bool
    var isConflicted: Bool

    init(
        path: String,
        originalPath: String? = nil,
        indexStatus: String,
        worktreeStatus: String,
        isStaged: Bool,
        isUnstaged: Bool,
        isUntracked: Bool = false,
        isConflicted: Bool = false
    ) {
        self.id = path
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.isStaged = isStaged
        self.isUnstaged = isUnstaged
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
    }

    /// The status letter to display for a given group.
    func statusLetter(for group: GitChangeGroup) -> String {
        if isConflicted { return "U" }
        if isUntracked { return "?" }
        switch group {
        case .staged: return indexStatus.trimmingCharacters(in: .whitespaces)
        case .unstaged: return worktreeStatus.trimmingCharacters(in: .whitespaces)
        }
    }
}

struct GitCommit: Identifiable, Sendable {
    /// Full commit hash.
    var id: String
    var shortHash: String
    /// Full parent hashes (empty for root commits, 2+ for merges).
    var parents: [String]
    var subject: String
    var author: String
    var date: Date
    /// Decorations as printed by `%D`, e.g. `HEAD -> main, origin/main, tag: v1`.
    var refs: String
    /// Reachable from HEAD and not from any remote-tracking ref (with no
    /// remote configured, every HEAD-reachable commit counts as unpushed).
    var isUnpushed: Bool = false
    /// True for the commit HEAD points at.
    var isHead: Bool = false
}

struct GitBranch: Identifiable, Sendable {
    var id: String
    var name: String
    var isCurrent: Bool
    var isRemote: Bool = false
    /// For a local branch: its upstream (e.g. "origin/main"); for a remote
    /// branch: the local branch that tracks it, if any.
    var upstream: String?

    init(name: String, isCurrent: Bool, isRemote: Bool = false, upstream: String? = nil) {
        self.id = name
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.upstream = upstream
    }
}

enum GitPullMode: String, Sendable, CaseIterable {
    case fastForwardOnly
    case merge
    case rebase
}

/// An interrupted merge/rebase/cherry-pick/revert, detected from the git
/// control files (MERGE_HEAD, rebase-merge/rebase-apply, CHERRY_PICK_HEAD,
/// REVERT_HEAD).
enum GitOperationState: Equatable, Sendable {
    case none
    case merging
    case rebasing
    case cherryPicking
    case reverting
}

struct GitStash: Identifiable, Sendable, Hashable {
    /// Reflog selector, e.g. "stash@{0}".
    var id: String
    var index: Int
    var message: String
    var date: Date?
}

// MARK: - Errors

enum GitError: LocalizedError, Sendable, Equatable {
    case gitNotFound(String)
    case notARepository
    case commandFailed(arguments: [String], exitCode: Int32, message: String)
    case invalidInput(String)
    case launchFailed(String)
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .gitNotFound(let path):
            return "Git was not found at \(path). Install the Xcode Command Line Tools (xcode-select --install)."
        case .notARepository:
            return "The project folder is not inside a Git repository."
        case .commandFailed(let arguments, let exitCode, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            let verb = arguments.first(where: { !$0.hasPrefix("-") }) ?? "command"
            return "git \(verb) failed (exit code \(exitCode))."
        case .invalidInput(let message):
            return message
        case .launchFailed(let message):
            return "Could not run Git: \(message)"
        case .timedOut(let seconds):
            return "The network operation did not finish within \(seconds) \(seconds == 1 ? "second" : "seconds") and was cancelled."
        }
    }
}

// MARK: - Process runner

struct GitCommandResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs `/usr/bin/git` directly (no shell) on a background thread. stdout and
/// stderr are drained concurrently so a chatty command can never deadlock on
/// a full pipe buffer. Cancelling the calling task terminates the process.
struct GitRunner: Sendable {
    var executableURL: URL
    /// Extra environment variables, applied after the sanitized process
    /// environment (used by tests to isolate from the user's git config).
    var environmentOverrides: [String: String]

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environmentOverrides: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.environmentOverrides = environmentOverrides
    }

    /// Global options prepended to every invocation. `--literal-pathspecs` is
    /// deliberately NOT here: it breaks `git stash push -u` (Apple Git fails
    /// to remove the stashed untracked files). It is passed per command
    /// instead, exactly where user-controlled paths appear after `--`.
    static let globalArguments: [String] = [
        "--no-pager",
        "-c", "core.quotepath=false",
        "-c", "color.ui=false",
        "-c", "log.showSignature=false",
    ]

    /// Prepended to commands that pass user-controlled paths after `--`, so
    /// magic-looking names (e.g. ":(glob)*.typ") stay literal.
    static let literalPathArguments = ["--literal-pathspecs"]

    /// Inherited variables that would redirect git to a different repository
    /// or index than the one we are pointing it at.
    private static let strippedVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE",
        "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
        "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS",
        "GIT_ICASE_PATHSPECS", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "PAGER",
    ]

    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Self.strippedVariables { env.removeValue(forKey: key) }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env["LC_ALL"] = "C"
        for (key, value) in environmentOverrides { env[key] = value }
        return env
    }

    /// Runs git with `arguments` in `directory`.
    /// - Parameter acceptedExitCodes: exit codes that are not treated as failures.
    func run(
        _ arguments: [String],
        in directory: URL,
        input: Data? = nil,
        acceptedExitCodes: Set<Int32> = [0]
    ) async throws -> GitCommandResult {
        let result = try await runRaw(arguments, in: directory, input: input)
        guard acceptedExitCodes.contains(result.exitCode) else {
            var message = result.stderrString
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = result.stdoutString
            }
            throw GitError.commandFailed(arguments: arguments, exitCode: result.exitCode, message: message)
        }
        return result
    }

    /// Runs git and returns the result whatever the exit code.
    func runRaw(_ arguments: [String], in directory: URL, input: Data? = nil) async throws -> GitCommandResult {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitError.gitNotFound(executableURL.path)
        }
        let control = ProcessControl()
        let fullArguments = Self.globalArguments + arguments
        let env = environment()
        let executable = executableURL
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitCommandResult, Error>) in
                Self.launch(
                    executable: executable,
                    arguments: fullArguments,
                    directory: directory,
                    environment: env,
                    input: input,
                    control: control
                ) { continuation.resume(with: $0) }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// Starts the process without blocking any thread: stdout/stderr are
    /// drained by readability handlers and completion fires once the process
    /// has exited *and* both pipes reached EOF.
    private static func launch(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        input: Data?,
        control: ProcessControl,
        completion: @escaping @Sendable (Result<GitCommandResult, Error>) -> Void
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe? = input == nil ? nil : Pipe()
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        let state = RunState(completion: completion, control: control)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                state.finish(.stdout)
            } else {
                state.append(chunk, to: .stdout)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                state.finish(.stderr)
            } else {
                state.append(chunk, to: .stderr)
            }
        }
        process.terminationHandler = { finished in
            let code: Int32 = finished.terminationReason == .uncaughtSignal
                ? 128 + finished.terminationStatus
                : finished.terminationStatus
            state.exited(code)
        }

        do {
            try control.launch(process)
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            state.fail(error)
            return
        }
        // Process closes the parent's copies of the child's pipe ends itself,
        // so EOF arrives once git (and any children) exit.
        if let stdinPipe, let input {
            let writer = stdinPipe.fileHandleForWriting
            // A dedicated thread so a large input can never block the
            // cooperative pool or a GCD worker.
            let thread = Thread {
                // Ignore EPIPE if git exits before reading everything.
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
            thread.start()
        }
    }
}

/// Collects output of one git invocation and completes exactly once.
private final class RunState: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutDone = false
    private var stderrDone = false
    private var exitCode: Int32?
    private var completed = false
    private let completion: @Sendable (Result<GitCommandResult, Error>) -> Void
    private let control: ProcessControl

    init(completion: @escaping @Sendable (Result<GitCommandResult, Error>) -> Void, control: ProcessControl) {
        self.completion = completion
        self.control = control
    }

    func append(_ data: Data, to stream: Stream) {
        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .stdout: stdout.append(data)
        case .stderr: stderr.append(data)
        }
    }

    func finish(_ stream: Stream) {
        lock.lock()
        switch stream {
        case .stdout: stdoutDone = true
        case .stderr: stderrDone = true
        }
        let result = takeResultIfReady()
        lock.unlock()
        if let result { completion(result) }
    }

    func exited(_ code: Int32) {
        lock.lock()
        exitCode = code
        let result = takeResultIfReady()
        lock.unlock()
        if let result { completion(result) }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(.failure(error))
    }

    /// Must be called with the lock held.
    private func takeResultIfReady() -> Result<GitCommandResult, Error>? {
        guard !completed, stdoutDone, stderrDone, let exitCode else { return nil }
        completed = true
        if control.isCancelled { return .failure(CancellationError()) }
        return .success(GitCommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
    }
}

/// Thread-safe holder for the running process so a task cancellation handler
/// can terminate it.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(error.localizedDescription)
        }
        self.process = process
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard let process, process.isRunning else { return }
        // SIGTERM first, then SIGKILL after a grace period, so a process
        // that ignores or misses the terminate signal can never leave the
        // manager stuck in the busy state.
        process.terminate()
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 3)
            self?.forceKillIfStillRunning()
        }
    }

    /// Sends SIGKILL when the process is still alive 3 s after the SIGTERM.
    private func forceKillIfStillRunning() {
        lock.lock(); defer { lock.unlock() }
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

// MARK: - Pure parsers

/// Branch/HEAD information from `git status --porcelain=v2 --branch`.
struct GitStatusSnapshot: Sendable, Equatable {
    /// Current commit hash, or nil when HEAD is unborn (`(initial)`).
    var headOID: String?
    /// Branch name, or nil when HEAD is detached.
    var headBranch: String?
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var changes: [GitChange] = []

    var isUnborn: Bool { headOID == nil }
    var isDetached: Bool { headBranch == nil }
}

enum GitOutputParser {
    /// Splits NUL-terminated output into UTF-8 records, dropping empties.
    static func nulRecords(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Converts porcelain-v2 `.` (unmodified) into porcelain-v1 `" "`.
    private static func v1(_ c: Character) -> String {
        c == "." ? " " : String(c)
    }

    /// Parses `git status --porcelain=v2 -z --branch --untracked-files=all`.
    static func parseStatusV2(_ data: Data) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        let records = nulRecords(data)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                parseHeader(record, into: &snapshot)
            case "1":
                // 1 XY sub mH mI mW hH hI <path>
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                if let change = ordinaryChange(xy: parts[1], path: String(parts[8]), originalPath: nil) {
                    snapshot.changes.append(change)
                }
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore <path>\0<origPath>
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = index < records.count ? records[index] : nil
                index += 1
                guard parts.count == 10 else { continue }
                if let change = ordinaryChange(xy: parts[1], path: String(parts[9]), originalPath: original) {
                    snapshot.changes.append(change)
                }
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                let xy = Array(parts[1])
                snapshot.changes.append(GitChange(
                    path: String(parts[10]),
                    indexStatus: xy.count > 0 ? v1(xy[0]) : "U",
                    worktreeStatus: xy.count > 1 ? v1(xy[1]) : "U",
                    isStaged: false,
                    isUnstaged: true,
                    isUntracked: false,
                    isConflicted: true
                ))
            case "?":
                let path = String(record.dropFirst(2))
                guard !path.isEmpty else { continue }
                snapshot.changes.append(GitChange(
                    path: path,
                    indexStatus: "?",
                    worktreeStatus: "?",
                    isStaged: false,
                    isUnstaged: true,
                    isUntracked: true
                ))
            default:
                // "!" ignored entries and anything unknown.
                continue
            }
        }
        return snapshot
    }

    private static func ordinaryChange(xy: Substring, path: String, originalPath: String?) -> GitChange? {
        let chars = Array(xy)
        guard chars.count == 2, !path.isEmpty else { return nil }
        let x = v1(chars[0])
        let y = v1(chars[1])
        return GitChange(
            path: path,
            originalPath: originalPath,
            indexStatus: x,
            worktreeStatus: y,
            isStaged: x != " ",
            isUnstaged: y != " "
        )
    }

    private static func parseHeader(_ record: String, into snapshot: inout GitStatusSnapshot) {
        let parts = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid":
            snapshot.headOID = value == "(initial)" ? nil : value
        case "branch.head":
            snapshot.headBranch = value == "(detached)" ? nil : value
        case "branch.upstream":
            snapshot.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { snapshot.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { snapshot.behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    static let logFieldSeparator: Character = "\u{1F}"
    /// `git log` format: hash, parents, author, unix time, decorations, subject.
    static let logFormat = "%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s"

    /// Parses `git log -z --format=<logFormat>`.
    static func parseLog(_ data: Data) -> [GitCommit] {
        nulRecords(data).compactMap { record in
            // Subject is last so any odd characters in it cannot shift fields.
            let fields = record.split(separator: logFieldSeparator, maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6 else { return nil }
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { return nil }
            let parents = fields[1].split(separator: " ").map(String.init)
            let timestamp = TimeInterval(fields[3].trimmingCharacters(in: .whitespaces)) ?? 0
            return GitCommit(
                id: hash,
                shortHash: String(hash.prefix(7)),
                parents: parents,
                subject: String(fields[5]),
                author: String(fields[2]),
                date: Date(timeIntervalSince1970: timestamp),
                refs: String(fields[4])
            )
        }
    }

    /// Format for `git for-each-ref refs/heads`: HEAD marker, ref name, upstream.
    static let branchFormat = "%(HEAD)%00%(refname)%00%(upstream:short)"

    /// Parses `git for-each-ref --format=<branchFormat> refs/heads`. When HEAD
    /// is unborn its branch has no ref yet, so it is appended as current.
    /// Records without the optional upstream field (older fixtures) still parse.
    static func parseBranches(_ data: Data, currentBranch: String?) -> [GitBranch] {
        var branches: [GitBranch] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            var name = String(parts[1])
            if name.hasPrefix("refs/heads/") { name.removeFirst("refs/heads/".count) }
            guard !name.isEmpty else { continue }
            var upstream = parts.count > 2 ? String(parts[2]) : ""
            if upstream.isEmpty { upstream = "" }
            branches.append(GitBranch(name: name, isCurrent: parts[0] == "*" || name == currentBranch, upstream: upstream.isEmpty ? nil : upstream))
        }
        if let currentBranch, !branches.contains(where: { $0.name == currentBranch }) {
            branches.append(GitBranch(name: currentBranch, isCurrent: true))
        }
        return branches
    }

    /// Format for `git for-each-ref refs/remotes`: just the ref name.
    static let remoteBranchFormat = "%(refname)"

    /// Parses `git for-each-ref --format=<remoteBranchFormat> refs/remotes`.
    /// `refs/remotes/<remote>/HEAD` entries are excluded.
    static func parseRemoteBranches(_ data: Data) -> [GitBranch] {
        var branches: [GitBranch] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard !line.isEmpty else { continue }
            var name = String(line)
            if name.hasPrefix("refs/remotes/") { name.removeFirst("refs/remotes/".count) }
            guard !name.isEmpty, !name.hasSuffix("/HEAD") else { continue }
            branches.append(GitBranch(name: name, isCurrent: false, isRemote: true))
        }
        return branches
    }

    /// Format for `git stash list`: reflog selector, commit time, subject.
    static let stashListFormat = "%gd%x1f%ct%x1f%s"

    /// Parses `git stash list --format=<stashListFormat>`.
    static func parseStashes(_ data: Data) -> [GitStash] {
        var stashes: [GitStash] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let id = String(fields[0])
            guard id.hasPrefix("stash@{") else { continue }
            let indexDigits = id.dropFirst("stash@{".count).dropLast("}".count)
            let index = Int(indexDigits) ?? stashes.count
            let date = Double(fields[1].trimmingCharacters(in: .whitespaces))
                .map { Date(timeIntervalSince1970: $0) }
            stashes.append(GitStash(id: id, index: index, message: String(fields[2]), date: date))
        }
        return stashes
    }

    /// Parses newline-separated commit ids (`git rev-list` output).
    static func parseCommitIDs(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// True when git's stderr says the directory has no repository / work tree.
    static func isNoRepositoryMessage(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("not a git repository")
            || lower.contains("must be run in a work tree")
    }

    /// A fast-forward-only pull/sync can only succeed while the branch is
    /// not diverged — ahead *and* behind its upstream at the same time.
    static func canFastForwardSync(ahead: Int, behind: Int) -> Bool {
        !(ahead > 0 && behind > 0)
    }
}

// MARK: - Manager

/// Main-actor façade for the Source Control panel. All git work happens in
/// background processes; results are applied only if the project root has not
/// changed meanwhile (tracked through `generation`).
@MainActor
final class SourceControlManager: ObservableObject {
    @Published private(set) var repositoryRoot: URL?
    @Published private(set) var branch: String = ""
    @Published private(set) var changes: [GitChange] = []
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var branches: [GitBranch] = []
    @Published private(set) var ahead: Int = 0
    @Published private(set) var behind: Int = 0
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var hasRemote: Bool = false
    @Published private(set) var remoteBranches: [GitBranch] = []
    @Published private(set) var tags: [String] = []
    @Published private(set) var stashes: [GitStash] = []
    @Published private(set) var operationState: GitOperationState = .none
    /// Upstream of the current branch, e.g. "origin/main".
    @Published private(set) var upstreamBranch: String?
    @Published private(set) var isDetachedHead: Bool = false
    /// False while HEAD is unborn.
    @Published private(set) var hasCommits: Bool = false
    /// User-facing label while busy, e.g. "Pushing…".
    @Published private(set) var currentOperation: String?
    @Published var errorMessage: String?

    private(set) var projectRoot: URL?

    /// Number of commits loaded into `commits`.
    var historyLimit = 50
    /// Diffs larger than this are truncated before being returned.
    var maxDiffBytes = 2_000_000
    /// Network operations (fetch/pull/push/sync) time out after this many
    /// seconds; the git process is then killed.
    var networkTimeout: TimeInterval = 300
    /// Whether network operations may show a credential dialog. Tests and
    /// CI set this to false and point GIT_ASKPASS at /usr/bin/false.
    var isAskpassEnabled: Bool = true
    /// Upper bound on how far back unpushed commits are counted in `load`;
    /// only relevant for repositories with enormous unpushed history.
    var unpushedScanLimit = 100_000

    let runner: GitRunner
    /// Incremented whenever the project root changes; stale results are dropped.
    private var generation = 0
    /// Incremented per refresh; only the newest refresh may publish.
    private var refreshSequence = 0
    private var activeOperation: UUID?
    private var activeTask: Task<Void, Error>?
    private var askpassScriptURL: URL?
    var upstream: String?
    var remotes: [String] = []
    var isUnborn = false
    var isDetached = false

    init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    deinit {
        // Remove the askpass script (its own unique directory).
        if let script = askpassScriptURL {
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
        }
    }

    var stagedChanges: [GitChange] { changes.filter(\.isStaged) }
    var unstagedChanges: [GitChange] { changes.filter(\.isUnstaged) }
    /// Commits reachable from HEAD that no remote-tracking ref contains.
    var unpushedCount: Int { commits.filter(\.isUnpushed).count }
    /// Conflicted entries of the current status.
    var conflictedChanges: [GitChange] { changes.filter(\.isConflicted) }
    /// True when the branch has commits both ahead of and behind its
    /// upstream: a fast-forward-only pull/sync cannot succeed then.
    var hasDiverged: Bool { !GitOutputParser.canFastForwardSync(ahead: ahead, behind: behind) }

    // MARK: Root handling

    func setProjectRoot(_ url: URL?) async {
        let normalized = url?.standardizedFileURL
        if normalized == projectRoot, repositoryRoot != nil || normalized == nil {
            await refresh(reportErrors: false)
            return
        }
        generation += 1
        projectRoot = normalized
        activeOperation = nil
        isBusy = false
        currentOperation = nil
        errorMessage = nil
        clearSnapshot()
        guard normalized != nil else { return }
        await refresh(reportErrors: false)
    }

    func refresh() async {
        await refresh(reportErrors: true)
    }

    private func clearSnapshot() {
        repositoryRoot = nil
        branch = ""
        changes = []
        commits = []
        branches = []
        ahead = 0
        behind = 0
        hasRemote = false
        upstream = nil
        remotes = []
        isUnborn = false
        isDetached = false
        remoteBranches = []
        tags = []
        stashes = []
        operationState = .none
        upstreamBranch = nil
        isDetachedHead = false
        hasCommits = false
    }

    private struct Snapshot: Sendable {
        var root: URL
        var status: GitStatusSnapshot
        var branchDisplay: String
        var commits: [GitCommit]
        var branches: [GitBranch]
        var remotes: [String]
        var remoteBranches: [GitBranch]
        var tags: [String]
        var stashes: [GitStash]
        var unpushedIDs: Set<String>
        var operationState: GitOperationState
    }

    private enum LoadResult: Sendable {
        case noRepository
        case repository(Snapshot)
    }

    /// Reloads all state. `reportErrors == false` keeps failures silent (used
    /// after mutations, which report their own errors, and on root changes).
    private func refresh(reportErrors: Bool) async {
        guard let projectRoot else {
            clearSnapshot()
            return
        }
        let gen = generation
        refreshSequence += 1
        let sequence = refreshSequence
        let historyLimit = historyLimit
        let unpushedLimit = unpushedScanLimit
        do {
            let result = try await Self.load(
                projectRoot: projectRoot, runner: runner,
                historyLimit: historyLimit, unpushedScanLimit: unpushedLimit
            )
            guard gen == generation, sequence == refreshSequence else { return }
            switch result {
            case .noRepository:
                clearSnapshot()
            case .repository(let snapshot):
                apply(snapshot)
            }
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation, sequence == refreshSequence else { return }
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    /// Publishes a snapshot in one synchronous main-actor turn so SwiftUI
    /// never renders a mix of old and new state.
    private func apply(_ snapshot: Snapshot) {
        if repositoryRoot != snapshot.root { repositoryRoot = snapshot.root }
        branch = snapshot.branchDisplay
        changes = snapshot.status.changes
        commits = snapshot.commits
        branches = snapshot.branches
        ahead = snapshot.status.ahead
        behind = snapshot.status.behind
        hasRemote = !snapshot.remotes.isEmpty
        upstream = snapshot.status.upstream
        remotes = snapshot.remotes
        isUnborn = snapshot.status.isUnborn
        isDetached = snapshot.status.isDetached
        // Phase 2 state.
        upstreamBranch = snapshot.status.upstream
        isDetachedHead = snapshot.status.isDetached
        hasCommits = !snapshot.status.isUnborn
        operationState = snapshot.operationState
        tags = snapshot.tags
        stashes = snapshot.stashes
        // Remote branches: mark the one the current branch tracks as current,
        // and point each at the local branch that tracks it.
        let trackedRemote = snapshot.status.upstream
        var trackingLocal: [String: String] = [:]
        for branch in snapshot.branches {
            if let upstreamName = branch.upstream { trackingLocal[upstreamName] = branch.name }
        }
        remoteBranches = snapshot.remoteBranches.map { branch in
            var copy = branch
            copy.isCurrent = trackedRemote == branch.name
            copy.upstream = trackingLocal[branch.name]
            return copy
        }
    }

    private nonisolated static func load(
        projectRoot: URL,
        runner: GitRunner,
        historyLimit: Int,
        unpushedScanLimit: Int
    ) async throws -> LoadResult {
        guard FileManager.default.fileExists(atPath: projectRoot.path) else { return .noRepository }
        let topLevel = try await runner.runRaw(["rev-parse", "--show-toplevel"], in: projectRoot)
        if topLevel.exitCode != 0 {
            if GitOutputParser.isNoRepositoryMessage(topLevel.stderrString) { return .noRepository }
            throw GitError.commandFailed(arguments: ["rev-parse"], exitCode: topLevel.exitCode, message: topLevel.stderrString)
        }
        var rootPath = topLevel.stdoutString
        if rootPath.hasSuffix("\n") { rootPath.removeLast() }
        guard !rootPath.isEmpty else { return .noRepository }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        let statusResult = try await runner.run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--renames"],
            in: root
        )
        let status = GitOutputParser.parseStatusV2(statusResult.stdout)

        async let logTask = runner.run(
            ["log", "--topo-order", "-z", "--no-color", "--decorate=short",
             "--format=\(GitOutputParser.logFormat)", "-n", String(max(1, historyLimit)),
             "--exclude=refs/stash", "--all"],
            in: root,
            acceptedExitCodes: [0, 128]
        )
        async let branchTask = runner.run(
            ["for-each-ref", "--format=\(GitOutputParser.branchFormat)", "refs/heads"],
            in: root
        )
        async let remoteTask = runner.run(["remote"], in: root)
        async let remoteBranchTask = runner.run(
            ["for-each-ref", "--format=\(GitOutputParser.remoteBranchFormat)", "refs/remotes"],
            in: root
        )
        async let tagTask = runner.run(
            ["for-each-ref", "--sort=-creatordate", "--format=%(refname:short)", "refs/tags"],
            in: root
        )
        async let stashTask = runner.run(
            ["stash", "list", "--format=\(GitOutputParser.stashListFormat)"],
            in: root
        )

        let logResult = try await logTask
        let branchResult = try await branchTask
        let remoteResult = try await remoteTask
        let remoteBranchResult = try await remoteBranchTask
        let tagResult = try await tagTask
        let stashResult = try await stashTask

        // An unborn repository with no refs at all may exit non-zero on some
        // git versions; treat it as empty history.
        let branches = GitOutputParser.parseBranches(branchResult.stdout, currentBranch: status.headBranch)
        let remotes = remoteResult.stdoutString.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let remoteBranches = GitOutputParser.parseRemoteBranches(remoteBranchResult.stdout)
        let tags = tagResult.stdoutString.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let stashes = GitOutputParser.parseStashes(stashResult.stdout)

        // Unpushed commits: reachable from HEAD and not from any
        // remote-tracking ref. With no remotes, every HEAD-reachable commit
        // counts as unpushed. (Capped: see unpushedScanLimit.)
        var unpushedIDs: Set<String> = []
        if let headOID = status.headOID {
            let arguments = remotes.isEmpty
                ? ["rev-list", "--max-count=\(unpushedScanLimit)", headOID]
                : ["rev-list", "--max-count=\(unpushedScanLimit)", headOID, "--not", "--remotes"]
            if let result = try? await runner.run(arguments, in: root), result.exitCode == 0 {
                unpushedIDs = Set(GitOutputParser.parseCommitIDs(result.stdout))
            }
        }
        let state = await Self.operationState(root: root, runner: runner)

        var commits = logResult.exitCode == 0 ? GitOutputParser.parseLog(logResult.stdout) : []
        commits = commits.map { commit in
            var copy = commit
            copy.isUnpushed = unpushedIDs.contains(copy.id)
            copy.isHead = commit.id == status.headOID
            return copy
        }

        let display: String
        if let name = status.headBranch {
            display = name
        } else if let oid = status.headOID {
            display = "HEAD (\(oid.prefix(7)))"
        } else {
            display = "HEAD"
        }
        return .repository(Snapshot(
            root: root, status: status, branchDisplay: display,
            commits: commits, branches: branches, remotes: remotes,
            remoteBranches: remoteBranches, tags: tags, stashes: stashes,
            unpushedIDs: unpushedIDs, operationState: state
        ))
    }

    // MARK: Operation plumbing

    /// Cancels the operation in progress (kills the running git process).
    func cancelCurrentOperation() {
        activeTask?.cancel()
    }

    /// A git runner for network operations: credential prompts via askpass,
    /// per-command timeout, and process kill on cancel/timeout.
    func makeNetworkGit() -> NetworkGitRunner {
        var overrides = runner.environmentOverrides
        var askpassScript: URL?
        if isAskpassEnabled {
            if askpassScriptURL == nil {
                askpassScriptURL = GitAskpass.installAskpassScript()
            }
            if let script = askpassScriptURL {
                for (key, value) in GitAskpass.environment(for: script) {
                    overrides[key] = value
                }
            }
            askpassScript = askpassScriptURL
        }
        let networkRunner = GitRunner(
            executableURL: runner.executableURL,
            environmentOverrides: overrides
        )
        return NetworkGitRunner(
            runner: networkRunner,
            timeout: networkTimeout,
            askpassActivityURL: askpassScript.map { GitAskpass.activityFileURL(forScript: $0) }
        )
    }

    /// Runs a mutating operation guarded by `isBusy`, reports errors, refreshes
    /// silently afterwards and, when `touchesWorkingTree`, posts
    /// `.refreshProjectSidebar` and `.gitWorkingTreeDidChange` (object: the
    /// repository root) on the main actor — including on failure, since a
    /// failed merge still writes conflict markers.
    @discardableResult
    internal func perform(
        label: String? = nil,
        requiresRepository: Bool = true,
        touchesWorkingTree: Bool,
        _ body: @escaping @Sendable (URL, GitRunner) async throws -> Void
    ) async -> Bool {
        guard !isBusy else { return false }
        let target: URL
        if requiresRepository {
            guard let repositoryRoot else {
                errorMessage = GitError.notARepository.localizedDescription
                return false
            }
            target = repositoryRoot
        } else {
            guard let projectRoot else {
                errorMessage = "No project folder is open."
                return false
            }
            target = projectRoot
        }
        let gen = generation
        let token = UUID()
        activeOperation = token
        isBusy = true
        currentOperation = label
        errorMessage = nil

        // Unstructured task so cancelCurrentOperation() can stop the git
        // process; cancellation of the caller propagates the same way.
        let task = Task { try await body(target, runner) }
        activeTask = task
        var succeeded = true
        do {
            try await withTaskCancellationHandler {
                _ = try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            succeeded = false
        } catch {
            succeeded = false
            if gen == generation { errorMessage = error.localizedDescription }
        }

        if touchesWorkingTree {
            NotificationCenter.default.post(name: .refreshProjectSidebar, object: nil)
            NotificationCenter.default.post(name: .gitWorkingTreeDidChange, object: target.standardizedFileURL)
        }
        if gen == generation {
            await refresh(reportErrors: false)
        }
        if activeOperation == token {
            activeOperation = nil
            isBusy = false
            currentOperation = nil
            activeTask = nil
        }
        return succeeded && gen == generation
    }

    /// True when `revision` (a valid commit) is reachable from HEAD's history
    /// but not from any remote-tracking ref. With no remotes, every commit
    /// reachable from `revision` counts as unpushed.
    nonisolated static func isUnpushed(_ revision: String, root: URL, runner: GitRunner) async throws -> Bool {
        let remotes = try await runner.run(["remote"], in: root)
            .stdoutString.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let arguments = remotes.isEmpty
            ? ["rev-list", "--max-count=1", revision]
            : ["rev-list", "--max-count=1", revision, "--not", "--remotes"]
        let result = try await runner.run(arguments, in: root)
        return !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Resolves `name` to a path inside the repository's git directory using
    /// `rev-parse --git-path`, so linked worktrees resolve correctly. Returns
    /// nil when the command fails.
    nonisolated static func gitPath(_ name: String, root: URL, runner: GitRunner) async throws -> String? {
        let result = try await runner.runRaw(["rev-parse", "--git-path", name], in: root)
        guard result.exitCode == 0 else { return nil }
        let raw = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: raw, relativeTo: root)
        return url.standardizedFileURL.path
    }

    /// Detects a merge/rebase/cherry-pick/revert in progress by looking for
    /// the git control files (worktree-safe via `rev-parse --git-path`).
    nonisolated static func operationState(root: URL, runner: GitRunner) async -> GitOperationState {
        // Rebase wins over everything (its replay can itself be conflicted,
        // in which case MERGE_HEAD exists too).
        let candidates: [(String, GitOperationState)] = [
            ("rebase-merge", .rebasing),
            ("rebase-apply", .rebasing),
            ("CHERRY_PICK_HEAD", .cherryPicking),
            ("REVERT_HEAD", .reverting),
            ("MERGE_HEAD", .merging),
        ]
        for (name, state) in candidates {
            guard let path = try? await gitPath(name, root: root, runner: runner),
                  FileManager.default.fileExists(atPath: path) else {
                continue
            }
            return state
        }
        return .none
    }

    /// Whether HEAD currently points at an existing commit (checked live,
    /// not from the cached snapshot).
    nonisolated static func headExists(root: URL, runner: GitRunner) async throws -> Bool {
        let result = try await runner.runRaw(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)
        return result.exitCode == 0
    }

    private static func paths(for change: GitChange) -> [String] {
        var paths = [change.path]
        if let original = change.originalPath, original != change.path { paths.append(original) }
        return paths
    }

    // MARK: Repository

    func initializeRepository() async {
        guard repositoryRoot == nil else { return }
        await perform(requiresRepository: false, touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(["init", "-q"], in: root)
        }
    }

    // MARK: Ignoring

    /// Adds a repository-relative path to the root `.gitignore` and, when Git
    /// already tracks it, stops tracking it — the files stay on disk, and the
    /// next commit records that they are no longer versioned. Directories get
    /// a trailing slash so the whole subtree is ignored, and every rule is
    /// anchored to the repository root.
    func addToGitIgnore(path: String, isDirectory: Bool) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Invalid path."
            return
        }
        guard trimmed != ".gitignore" else {
            errorMessage = "Ignoring .gitignore itself would hide the rules from Git."
            return
        }
        // Untracking mid-merge/rebase would drop entries the operation still
        // needs, so finish or abort it first — same rule as stash/merge.
        guard operationState == .none else {
            errorMessage = "Finish or abort the \(operationState.displayName.lowercased()) before changing what Git tracks."
            return
        }
        let pattern = Self.gitIgnorePattern(for: trimmed, isDirectory: isDirectory)
        await perform(label: "Adding to .gitignore…", touchesWorkingTree: true) { root, runner in
            let ignoreURL = root.appendingPathComponent(".gitignore")
            let existing: String
            if FileManager.default.fileExists(atPath: ignoreURL.path) {
                guard let text = try? String(contentsOf: ignoreURL, encoding: .utf8) else {
                    throw GitError.invalidInput("The .gitignore file is not UTF-8 text; add the rule by hand.")
                }
                existing = text
            } else {
                existing = ""
            }
            let updated = Self.appendingGitIgnorePattern(pattern, to: existing)
            if updated != existing {
                try updated.write(to: ignoreURL, atomically: true, encoding: .utf8)
            }

            // Only untrack what Git actually tracks. Untracked paths need the
            // rule alone, which the refresh then applies.
            let tracked = try await runner.runRaw(
                GitRunner.literalPathArguments + ["ls-files", "-z", "--", trimmed],
                in: root
            ).stdoutString
                .split(separator: "\0", omittingEmptySubsequences: true)
                .map(String.init)
            guard !tracked.isEmpty else { return }
            // `update-index --force-remove` drops the paths from the index
            // without touching the working tree and without `git rm`'s
            // refusal to untrack locally modified files.
            _ = try await runner.run(
                GitRunner.literalPathArguments + ["update-index", "--force-remove", "--"] + tracked,
                in: root
            )
        }
    }

    /// Escapes one repository-relative path as an anchored `.gitignore` rule.
    /// `#` and `!` are only special as the first character; `*`, `?`, `[` and
    /// `\` are special anywhere (backslash first, so it isn't escaped twice).
    nonisolated static func gitIgnorePattern(for path: String, isDirectory: Bool) -> String {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        var escaped = ""
        for character in relative {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "*", "?", "[":
                escaped += "\\\(character)"
            case "#", "!" where escaped.isEmpty:
                escaped += "\\\(character)"
            default:
                escaped.append(character)
            }
        }
        return "/" + escaped + (isDirectory ? "/" : "")
    }

    /// Appends `pattern` on its own line unless an identical rule is already
    /// present, leaving the rest of the file untouched and ending with a
    /// newline. Existing lines are compared with surrounding whitespace
    /// trimmed, since Git ignores it too.
    nonisolated static func appendingGitIgnorePattern(_ pattern: String, to existing: String) -> String {
        let lines = existing
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(pattern) else { return existing }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        return updated + pattern + "\n"
    }

    // MARK: Staging

    func stage(_ change: GitChange) async {
        await perform(touchesWorkingTree: false) { root, runner in
            // `-A` also stages deletions. Only the current path is passed:
            // for a staged rename the original path is already gone from the
            // index and worktree, and naming it would fail the pathspec.
            _ = try await runner.run(
                GitRunner.literalPathArguments + ["add", "-A", "--", change.path],
                in: root
            )
        }
    }

    func unstage(_ change: GitChange) async {
        let paths = Self.paths(for: change)
        await perform(touchesWorkingTree: false) { root, runner in
            try await Self.unstage(paths: paths, root: root, runner: runner)
        }
    }

    func stageAll() async {
        await perform(touchesWorkingTree: false) { root, runner in
            _ = try await runner.run(["add", "-A"], in: root)
        }
    }

    func unstageAll() async {
        await perform(touchesWorkingTree: false) { root, runner in
            if try await Self.headExists(root: root, runner: runner) {
                _ = try await runner.run(["reset", "-q"], in: root)
            } else {
                // No commit to reset to: empty the index (files stay on disk).
                _ = try await runner.run(["read-tree", "--empty"], in: root)
            }
        }
    }

    private nonisolated static func unstage(paths: [String], root: URL, runner: GitRunner) async throws {
        if try await headExists(root: root, runner: runner) {
            // Restores both sides of a rename (removes the new path from the
            // index and re-adds the original from HEAD) and staged deletions.
            _ = try await runner.run(
                GitRunner.literalPathArguments + ["reset", "-q", "HEAD", "--"] + paths,
                in: root
            )
        } else {
            _ = try await runner.run(
                GitRunner.literalPathArguments
                    + ["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--"] + paths,
                in: root
            )
        }
    }

    // MARK: Commit

    /// Commits the staged changes. Amend is allowed with nothing staged
    /// (message-only) but refused for a pushed HEAD and when there are no
    /// commits yet. Author identity and date are preserved.
    func commit(message: String, amend: Bool) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a commit message."
            return false
        }
        guard !isBusy else { return false }
        if !amend,
           !changes.contains(where: \.isStaged),
           !changes.contains(where: \.isConflicted) {
            errorMessage = "There are no staged changes to commit."
            return false
        }
        let data = Data(message.utf8)
        return await perform(touchesWorkingTree: false) { root, runner in
            if amend {
                guard try await Self.headExists(root: root, runner: runner) else {
                    throw GitError.invalidInput("There are no commits to amend.")
                }
                guard try await Self.isUnpushed("HEAD", root: root, runner: runner) else {
                    throw GitError.invalidInput("The latest commit has already been pushed and cannot be amended.")
                }
            }
            // Message via stdin: no argument parsing issues, any content allowed.
            var arguments = ["commit", "-q"]
            if amend { arguments.append("--amend") }
            arguments.append(contentsOf: ["--file=-", "--cleanup=strip"])
            _ = try await runner.run(arguments, in: root, input: data)
        }
    }

    func commit(message: String) async -> Bool {
        await commit(message: message, amend: false)
    }

    /// The full message of HEAD, for prefilling the amend box.
    func headCommitMessage() async -> String? {
        guard let root = repositoryRoot else { return nil }
        guard let result = try? await runner.run(["cat-file", "commit", "HEAD^{commit}"], in: root),
              result.exitCode == 0,
              let parsed = RawCommit.parse(result.stdout) else {
            return nil
        }
        return parsed.messageText
    }

    /// The full message of any commit, byte-exact.
    func fullMessage(of commitID: String) async throws -> String {
        guard let root = repositoryRoot else { throw GitError.notARepository }
        let trimmedID = commitID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw GitError.invalidInput("Invalid commit.") }
        let resolved = try await runner.run(
            ["rev-parse", "--verify", "\(trimmedID)^{commit}"],
            in: root
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = try await runner.run(["cat-file", "commit", resolved], in: root).stdout
        guard let parsed = RawCommit.parse(raw) else {
            throw GitError.invalidInput("Could not read the commit message.")
        }
        return parsed.messageText
    }

    /// Undoes the latest commit with a soft reset: its changes stay staged.
    /// Refuses a pushed HEAD, an unborn HEAD and an in-progress operation.
    /// For a root commit the branch ref is deleted and the index is kept.
    /// Returns the undone commit's message.
    @discardableResult
    func undoLastCommit() async -> String? {
        guard !isBusy else { return nil }
        final class MessageBox: @unchecked Sendable { var message: String? }
        let box = MessageBox()
        let ok = await perform(label: "Undoing commit…", touchesWorkingTree: false) { root, runner in
            guard try await Self.headExists(root: root, runner: runner) else {
                throw GitError.invalidInput("There are no commits to undo.")
            }
            guard await Self.operationState(root: root, runner: runner) == .none else {
                throw GitError.invalidInput("An operation is in progress; finish or abort it first.")
            }
            guard try await Self.isUnpushed("HEAD", root: root, runner: runner) else {
                throw GitError.invalidInput("The latest commit has already been pushed and cannot be undone.")
            }
            let parentLine = try await runner.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: root)
                .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let parents = parentLine.split(separator: " ").dropFirst().map(String.init)
            let raw = try await runner.run(["cat-file", "commit", "HEAD"], in: root).stdout
            guard let parsed = RawCommit.parse(raw) else {
                throw GitError.invalidInput("Could not read the commit.")
            }
            box.message = parsed.messageText
            if parents.isEmpty {
                // Root commit: delete the branch ref; index and files untouched.
                let symref = try await runner.runRaw(["symbolic-ref", "--quiet", "HEAD"], in: root)
                guard symref.exitCode == 0 else {
                    throw GitError.invalidInput("The root commit cannot be undone while HEAD is detached.")
                }
                let branchRef = symref.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branchRef.isEmpty else {
                    throw GitError.invalidInput("Could not determine the current branch.")
                }
                _ = try await runner.run(["update-ref", "-d", branchRef], in: root)
            } else {
                _ = try await runner.run(["reset", "--quiet", "--soft", "HEAD~1"], in: root)
            }
        }
        guard ok else { return nil }
        return box.message
    }

    /// Rewrites an unpushed, HEAD-reachable commit's message via plumbing.
    /// The index and working tree are never touched; the branch ref is
    /// updated with a compare-and-swap.
    func rewordCommit(_ commitID: String, message: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a commit message."
            return false
        }
        return await perform(label: "Rewording…", touchesWorkingTree: false) { root, runner in
            try await Self.reword(commitID: commitID, message: trimmed, root: root, runner: runner)
        }
    }

    // MARK: Remote

    func fetch() async {
        guard hasRemote else {
            errorMessage = "This repository has no remote."
            return
        }
        let network = makeNetworkGit()
        await perform(label: "Fetching…", touchesWorkingTree: false) { root, _ in
            _ = try await network.run(["fetch", "--all", "--prune", "--quiet"], in: root)
        }
    }

    func pull() async {
        await pull(mode: .fastForwardOnly)
    }

    func pull(mode: GitPullMode) async {
        guard hasRemote else {
            errorMessage = "This repository has no remote."
            return
        }
        guard upstream != nil else {
            errorMessage = "The current branch has no upstream branch. Push it first."
            return
        }
        let arguments: [String]
        switch mode {
        case .fastForwardOnly: arguments = ["pull", "--no-rebase", "--ff-only", "--quiet"]
        case .merge: arguments = ["pull", "--no-rebase", "--quiet"]
        case .rebase: arguments = ["pull", "--rebase", "--quiet"]
        }
        let network = makeNetworkGit()
        await perform(label: "Pulling…", touchesWorkingTree: true) { root, _ in
            _ = try await network.run(arguments, in: root)
        }
    }

    func push() async {
        guard hasRemote else {
            errorMessage = "This repository has no remote."
            return
        }
        let network = makeNetworkGit()
        if upstream != nil {
            await perform(label: "Pushing…", touchesWorkingTree: false) { root, _ in
                _ = try await network.run(["push", "--quiet"], in: root)
            }
            return
        }
        guard !isDetached, !isUnborn, !branch.isEmpty else {
            errorMessage = isUnborn ? "Create a commit before pushing." : "Check out a branch before pushing."
            return
        }
        let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
        let branchName = branch
        await perform(label: "Pushing…", touchesWorkingTree: false) { root, _ in
            _ = try await network.run(
                ["push", "--quiet", "--set-upstream", remote, "refs/heads/\(branchName):refs/heads/\(branchName)"],
                in: root
            )
        }
    }

    // MARK: Branches

    func checkout(branch name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            errorMessage = "Invalid branch name."
            return
        }
        guard trimmed != branch else { return }
        await perform(touchesWorkingTree: true) { root, runner in
            // Must be an existing local branch; never fall back to treating
            // the name as a path (`checkout -- <path>` would discard edits).
            let check = try await runner.runRaw(["show-ref", "--verify", "--quiet", "refs/heads/\(trimmed)"], in: root)
            guard check.exitCode == 0 else {
                throw GitError.invalidInput("Branch '\(trimmed)' does not exist.")
            }
            _ = try await runner.run(["switch", "--quiet", "--no-guess", trimmed], in: root)
        }
    }

    // MARK: Discard

    /// Reverts unstaged edits of a tracked file to its staged (index) version.
    /// Untracked files are moved to the Trash (never deleted outright).
    /// Refuses conflicted and intent-to-add files.
    func discard(_ change: GitChange) async {
        guard change.isUnstaged else { return }
        if change.isUntracked {
            let path = change.path
            await perform(label: "Discarding…", touchesWorkingTree: true) { root, _ in
                let url = root.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw GitError.invalidInput("'\(path)' no longer exists.")
                }
                var resultingItem: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItem)
            }
            return
        }
        if change.isConflicted {
            errorMessage = "Resolve the merge conflict in '\(change.path)' before discarding."
            return
        }
        if change.worktreeStatus == "A" {
            errorMessage = "'\(change.path)' is only marked as intent-to-add; it cannot be discarded."
            return
        }
        let path = change.path
        await perform(label: "Discarding…", touchesWorkingTree: true) { root, runner in
            _ = try await runner.run(
                GitRunner.literalPathArguments + ["checkout", "--quiet", "--", path],
                in: root
            )
        }
    }

    /// Discards unstaged edits of tracked files (restoring them from the
    /// index) and moves untracked files to the Trash. Staged changes are kept.
    func discardAllChanges() async {
        guard operationState == .none, !changes.contains(where: \.isConflicted) else {
            errorMessage = "Resolve conflicts before discarding changes."
            return
        }
        let untracked = changes.filter(\.isUntracked).map(\.path)
        let hasUnstagedTracked = changes.contains { $0.isUnstaged && !$0.isUntracked && !$0.isConflicted }
        guard hasUnstagedTracked || !untracked.isEmpty else { return }
        await perform(label: "Discarding changes…", touchesWorkingTree: true) { root, runner in
            if hasUnstagedTracked {
                // Restores the working tree from the index; staged changes survive.
                _ = try await runner.run(
                    GitRunner.literalPathArguments + ["checkout", "--quiet", "--", "."],
                    in: root
                )
            }
            for path in untracked {
                let url = root.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                var resultingItem: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItem)
            }
        }
    }

    // MARK: Diff

    /// Unified diff for one change. Staged diffs compare HEAD (or the empty
    /// tree before the first commit) with the index; unstaged diffs compare
    /// the index with the working tree, or /dev/null for untracked files.
    func diff(for change: GitChange, group: GitChangeGroup) async throws -> String {
        guard let root = repositoryRoot else { throw GitError.notARepository }
        let runner = runner
        let limit = maxDiffBytes
        let paths = Self.paths(for: change)
        // Literal pathspecs so magic-looking file names stay literal.
        let base = GitRunner.literalPathArguments
            + ["diff", "--no-color", "--no-ext-diff", "--find-renames", "--no-relative"]

        let output: Data
        switch group {
        case .staged:
            if try await Self.headExists(root: root, runner: runner) {
                output = try await runner.run(base + ["--cached", "--"] + paths, in: root).stdout
            } else {
                let empty = try await runner.run(["hash-object", "-t", "tree", "--stdin"], in: root, input: Data())
                let emptyTree = empty.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                output = try await runner.run(base + ["--cached", emptyTree, "--"] + paths, in: root).stdout
            }
        case .unstaged:
            if change.isUntracked {
                // --no-index exits 1 when files differ.
                output = try await runner.run(
                    GitRunner.literalPathArguments
                        + ["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", change.path],
                    in: root,
                    acceptedExitCodes: [0, 1]
                ).stdout
            } else {
                output = try await runner.run(base + ["--"] + [change.path], in: root).stdout
            }
        }
        if output.count > limit {
            let text = String(decoding: output.prefix(limit), as: UTF8.self)
            return text + "\n… diff truncated (\(output.count) bytes total)\n"
        }
        return String(decoding: output, as: UTF8.self)
    }
}
