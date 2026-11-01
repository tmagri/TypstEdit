import Foundation

/// A read-only tool call, parsed into a form that carries no main-actor state.
///
/// This is what makes concurrent tool calls possible. `LocalToolExecutor` is
/// `@MainActor`, so running several of its methods in a task group would just
/// serialize them on the actor — no faster than a loop, and the closure
/// capture is a data race besides. Parsing a call into a `Sendable` plan on
/// the main actor, then running the file I/O off it, is the part that actually
/// overlaps.
///
/// Only operations that read are representable here. Anything that writes, or
/// that can raise an approval prompt, stays on the sequential main-actor path:
/// a parallel write batch would make the transcript order and the approval
/// order non-deterministic for no benefit.
enum ReadOnlyToolPlan: Sendable {
    /// `read_file`. `url` is already resolved and checked against the scope.
    case readFile(
        url: URL,
        label: String,
        offset: Int?,
        limit: Int?,
        outline: Bool,
        maxBytes: Int,
        defaultLineLimit: Int,
        maxLineLimit: Int
    )
    /// `grep_project`. The pattern is carried as a string and recompiled in
    /// the runner, because `NSRegularExpression` is a non-`Sendable` class;
    /// it is validated at parse time so an invalid pattern still fails fast.
    case grep(
        root: URL,
        pattern: String,
        literal: Bool,
        caseSensitive: Bool,
        glob: String?,
        maxResults: Int,
        noteIfEmpty: Bool
    )
    /// `read_skill_file`. The folder and the permitted file list come from the
    /// enabled skills, resolved before the plan is built.
    case readSkillFile(
        folder: URL,
        skillID: String,
        fileName: String,
        offset: Int?,
        limit: Int?,
        maxBytes: Int,
        defaultLineLimit: Int,
        maxLineLimit: Int
    )
}

/// What one read-only call produced, plus any state the main actor has to
/// record afterwards.
///
/// The side effect is returned rather than applied in place because the work
/// runs off the main actor: `readFiles` (the read-before-edit ledger) is
/// main-actor state, so the runner reports what it read and the caller writes
/// it back once the batch finishes.
struct ReadOnlyToolOutcome: Sendable {
    var output: String
    /// Standardized path of a file whose read should satisfy read-before-edit,
    /// with its modification date at read time. `nil` for calls that don't
    /// count — an outline, a grep, a failure.
    var readFilePath: String?
    var readFileDate: Date?

    init(output: String, readFilePath: String? = nil, readFileDate: Date? = nil) {
        self.output = output
        self.readFilePath = readFilePath
        self.readFileDate = readFileDate
    }
}

/// What one concurrent read-only call produced. A `Sendable` result type
/// rather than `Result<_, Error>` because an existential `Error` cannot cross
/// a task-group boundary, and the transcript still needs to tell a failure
/// from a success.
enum ReadOnlyToolResult: Sendable {
    case success(ReadOnlyToolOutcome)
    case failure(String)
}

/// Which tool calls in one round may run together.
///
/// The rule is deliberately narrow: a tool is eligible only if it cannot
/// modify anything and never raises an approval prompt. `web_fetch` is
/// excluded despite being a read — it asks for approval on every call, and a
/// prompt is a blocking interaction, not work that benefits from overlapping.
/// `run_typst_check` is excluded because it writes a temporary file and
/// compiling several documents at once is exactly the load that makes a slow
/// machine feel stuck. `search_project` is excluded because it needs the
/// main-actor RAG index.
enum ParallelToolCalls {

    /// Tool names (without the `server__` prefix) that may overlap.
    static let safeToolNames: Set<String> = [
        "read_file",
        "grep_project",
        "read_skill_file"
    ]

    /// The namespace whose tools are eligible. An MCP server's tools are never
    /// batched: the server may hold a lock, share one connection, or simply
    /// not support concurrent requests.
    static let eligibleNamespace = "project"

    /// Whether one call may run alongside others in the same round.
    static func isSafe(_ qualifiedName: String) -> Bool {
        guard qualifiedName.hasPrefix(eligibleNamespace + "__") else { return false }
        return safeToolNames.contains(ToolCallRepeatGuard.baseName(qualifiedName))
    }

    /// Most calls run at once. A model occasionally asks for a dozen reads in
    /// one reply; letting all of them open files at the same time trades one
    /// bottleneck for another on a spinning disk or a network volume.
    static let maxConcurrent = 4

    /// One unit of work: either a single call, or several safe calls that can
    /// overlap.
    struct Group: Equatable {
        /// Indices into the round's call list, in the order the model wrote
        /// them. Always contiguous.
        var indices: [Int]

        var isParallel: Bool { indices.count > 1 }
    }

    /// Splits a round into groups. A run of consecutive safe calls becomes one
    /// group; every other call is its own group, so the model's order is
    /// preserved around anything that changes state.
    static func groups(for calls: [String]) -> [Group] {
        var groups: [Group] = []
        var run: [Int] = []

        func flush() {
            guard !run.isEmpty else { return }
            groups.append(Group(indices: run))
            run = []
        }

        for (index, name) in calls.enumerated() {
            if isSafe(name) {
                run.append(index)
            } else {
                flush()
                groups.append(Group(indices: [index]))
            }
        }
        flush()
        return groups
    }
}
