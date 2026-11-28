import Foundation

/// One read-only tool call, parsed into a form that carries no main-actor
/// state. Ported from TypstEdit's `ReadOnlyToolPlan`.
///
/// This is what makes concurrent tool calls possible. `AIChatManager`,
/// `ClippyToolExecutor` and `SkillsManager` are all `@MainActor`, so running
/// several of their methods in a task group would just serialize them on the
/// actor — no faster than a loop, and the closure capture is a data race
/// besides. Parsing a call into a `Sendable` plan on the main actor, then
/// running the file I/O off it, is the part that actually overlaps.
///
/// Only operations that read are representable here. Anything that writes, or
/// that can raise an approval prompt, stays on the sequential main-actor path:
/// a parallel write batch would make the transcript order and the approval
/// order non-deterministic for no benefit.
enum ReadOnlyToolPlan: Sendable {
    /// `reference__list_files`. All the state it needs is the folder path.
    case listReferenceFiles(folder: String)
    /// `reference__read_file`. `url` is already resolved and checked against
    /// the folder, so the runner never re-does the containment check.
    case readReferenceFile(url: URL, label: String, options: FileReadOptions)
    /// `reference__grep`. The pattern travels as a string and is matched in the
    /// runner; it is validated at parse time so an invalid pattern still fails
    /// fast, on the main actor, with the message the sequential path uses.
    case grepReference(folder: String, pattern: String, matchCase: Bool, limit: Int,
                       regex: Bool, mode: FileToolbox.SearchMode, contextLines: Int,
                       invert: Bool, scopePath: String?)
    /// `file__find`. All arguments are plain data; the walk runs off-actor.
    case fileFind(root: String, nameGlob: String?, extension_: String?,
                  minSizeBytes: Int?, maxSizeBytes: Int?,
                  modifiedAfter: Date?, modifiedBefore: Date?,
                  sortBy: String?, maxResults: Int?, allowNetworkVolumes: Bool)
    /// `file__read`. The URL is already resolved (tilde expanded, absolute).
    case fileRead(url: URL, label: String, options: FileReadOptions)
    /// `file__search`. Same search core as the reference grep.
    case fileSearch(root: String, pattern: String, regex: Bool, caseSensitive: Bool,
                    mode: FileToolbox.SearchMode, contextLines: Int, invert: Bool,
                    glob: String?, limit: Int, allowNetworkVolumes: Bool)
    /// `file__hash`.
    case fileHash(path: URL, label: String)
    /// `file__hex`. The arguments are parsed into a `Sendable` spec on the
    /// main actor (JSON values are `Any`, which cannot cross the boundary),
    /// so the runner does exactly what the sequential path does.
    case fileHex(spec: FileToolbox.HexSpec)
    /// `skill__read_file`. The URL is resolved and containment-checked against
    /// the skill folder before the plan is built.
    case readSkillFile(url: URL, label: String, maxChars: Int)
    // MARK: TypstEdit's project/notebook read tools (LocalToolExecutor)
    //
    // Carried as Sendable plans for the same reason the file tools are: the
    // scope root and limits are read on the main actor when the plan is
    // parsed, then the I/O runs off it.

    /// `project__read_file`: paged read with an optional section anchor, or
    /// an outline-only render.
    case projectReadFile(url: URL, label: String, offset: Int?, limit: Int?, outline: Bool,
                         maxBytes: Int, defaultLineLimit: Int, maxLineLimit: Int, section: String?)
    /// `project__get_outline`: headings and line ranges for a page of a file.
    case projectOutline(url: URL, label: String, startLine: Int?, endLine: Int?,
                        maxBytes: Int, section: String?)
    /// `project__grep_project`: regex scan over the project tree, capped.
    case projectGrep(root: URL, scopeRootPath: String, pattern: String, literal: Bool, caseSensitive: Bool,
                     glob: String?, maxResults: Int, noteIfEmpty: Bool)
    /// `project__read_skill_file`: one attachment of an enabled skill.
    case projectSkillFile(folder: URL, skillID: String, fileName: String, offset: Int?, limit: Int?,
                          maxBytes: Int, defaultLineLimit: Int, maxLineLimit: Int)
    /// An MCP tool call on a server the user allowed to overlap, for a tool the
    /// server itself annotated read-only.
    ///
    /// The arguments travel as the JSON text the model wrote, not as
    /// `[String: Any]`: `Any` is not `Sendable`, and re-parsing inside the
    /// runner would lose the exact bytes the server expects.
    case mcpTool(serverName: String, toolName: String, argumentsJSON: String)
}

/// Runs a round's eligible read-only calls concurrently and returns the output
/// per call index.
///
/// A named type rather than a bare closure signature at each call site: the
/// explicit `@MainActor` + `async` closure parameter does not survive inference
/// when written inline in an argument list.
typealias ParallelReadRunner = @MainActor (_ calls: [ParallelReadCall]) async -> [Int: String]

/// One eligible call in a concurrent read batch.
///
/// A struct rather than a labelled tuple because a labelled tuple cannot appear
/// in a closure's parameter type without tripping the type checker.
struct ParallelReadCall {
    /// The call's position in the round, so results can be put back in the
    /// order the model wrote them.
    let index: Int
    let qualifiedName: String
    let argumentsJSON: String
}

/// What one project read produced, beyond its text: the file it read and
/// when, so the caller can write the read-before-edit ledger on the main
/// actor once the batch lands (see `LocalToolExecutor.applyReadOnlyOutcome`).
/// An outline-only read is recorded in its own ledger, because `move_lines`
/// may act on what an outline showed but a full read still owes the model
/// the text.
struct ReadOnlyToolOutcome: Sendable, Equatable {
    let output: String
    /// The file the read touched, when it was a file read (a grep has none).
    let readFilePath: String?
    let readFileDate: Date?
    var isOutlineOnly: Bool = false

    init(output: String, readFilePath: String? = nil, readFileDate: Date? = nil, isOutlineOnly: Bool = false) {
        self.output = output
        self.readFilePath = readFilePath
        self.readFileDate = readFileDate
        self.isOutlineOnly = isOutlineOnly
    }
}

/// What one concurrent read-only call produced.
///
/// An enum rather than `Result<_, Error>` because an existential `Error` cannot
/// cross a task-group boundary, and the transcript still needs to tell a
/// failure from a success.
enum ReadOnlyToolResult: Sendable {
    case success(String)
    case failure(String)
}

/// Which tool calls in one round may run together.
///
/// Two different rules live here, because the questions are different:
///
/// - **TypstEdit's own tools** are known. `safeToolNames` is an allowlist of the
///   ones that only read, and membership means the call may overlap.
/// - **MCP tools** are not known. Whether a server can take two requests at
///   once is its property, not the client's, so an MCP call is batched only
///   when the user allowed that server to overlap *and* the server annotated
///   the specific tool read-only. See `MCPManager.mayRunConcurrently`.
enum ParallelToolCalls {

    /// Qualified names of TypstEdit's own tools that may overlap.
    ///
    /// Every name here has a `ReadOnlyToolPlan` case that the off-actor
    /// runner can execute — `safeToolNames` ⊆ plan-parsable names, because a
    /// safe name whose parse returns `nil` would silently fall back to the
    /// sequential path (see the notes on `readOnlyPlan`). The `file__*` set
    /// is all read-only — that is the design constraint for everything in
    /// `FileToolbox` — and the project reads are parsed into plans by
    /// `LocalToolExecutor` with the scope root and limits read up front.
    /// Git reads and the calculator stay sequential: they have no plan
    /// cases, and a plan-less "safe" name is exactly the silent fallback
    /// this list must not create.
    static let safeToolNames: Set<String> = [
        "project__read_file",
        "project__get_outline",
        "project__grep_project",
        "project__read_skill_file",
        "file__find",
        "file__read",
        "file__search",
        "file__hash",
        "file__hex",
    ]

    /// Whether one call may run alongside others in the same round, for the
    /// tools TypstEdit ships itself.
    ///
    /// MCP tools are never in this set: `isSafe` cannot answer for them
    /// without the manager, so the agent asks `MCPManager` separately.
    static func isSafe(_ qualifiedName: String) -> Bool {
        safeToolNames.contains(qualifiedName)
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

    /// Splits a round into groups by *position*. A run of consecutive eligible
    /// calls becomes one group; every other call is its own group, so the
    /// model's order is preserved around anything that changes state.
    ///
    /// This is what stops a write in the middle of a round from being reordered
    /// past a read that was meant to observe it.
    ///
    /// `isEligible` answers per index rather than per name because eligibility
    /// is not only a question about the tool: a call whose arguments were cut
    /// off, or one the repeat guard already refuses, runs on the sequential
    /// path and therefore splits the run it sits in. The live loop in
    /// `AICompletionService` decides that set and passes it here, so the rule
    /// this function implements is the rule the round actually uses.
    static func groups(count: Int, isEligible: (Int) -> Bool) -> [Group] {
        guard count > 0 else { return [] }
        var groups: [Group] = []
        var run: [Int] = []

        func flush() {
            guard !run.isEmpty else { return }
            groups.append(Group(indices: run))
            run = []
        }

        for index in 0..<count {
            if isEligible(index) {
                run.append(index)
            } else {
                flush()
                groups.append(Group(indices: [index]))
            }
        }
        flush()
        return groups
    }

    /// The name-only form, kept for the tests and for callers that reason
    /// about a round before its arguments are parsed.
    static func groups(for calls: [String]) -> [Group] {
        groups(count: calls.count, isEligible: { isSafe(calls[$0]) })
    }

    /// The groups of a round that may actually run concurrently, in order.
    ///
    /// A group of one is not a batch: it stays on the sequential path, so the
    /// round behaves exactly as it did before batching existed. Only groups of
    /// two or more come back, and they must be run **one after another** — a
    /// writer between two runs of reads separates them, and a caller that
    /// flattened this list into one batch would reintroduce the reorder
    /// `groups` exists to prevent.
    ///
    /// This is the function the tool loop uses. It used to collect every
    /// eligible call in the round regardless of where it sat, which let
    /// `[read A, edit B, read B]` overlap the second read with the first — both
    /// issued before the edit — so the read could observe a file the model had
    /// not changed yet. `groups` has always split on a write; nothing called it
    /// on the live path.
    static func parallelGroups(count: Int, isEligible: (Int) -> Bool) -> [Group] {
        groups(count: count, isEligible: isEligible).filter(\.isParallel)
    }
}

/// Runs a parsed read-only plan with no main-actor involvement.
///
/// Every caller is main-actor code, so the concrete work is `nonisolated`:
/// that is the hop which actually moves the file I/O off the actor. The reads
/// delegate to the same implementations the sequential path uses, so a batched
/// call and a lone one cannot answer the same query differently.
enum ReadOnlyToolRunner {

    nonisolated static func run(_ plan: ReadOnlyToolPlan) async throws -> String {
        switch plan {
        case .listReferenceFiles(let folder):
            return ReferenceFolderManager.renderListFiles(
                ReferenceFolderManager.listing(in: folder)
            )

        case .readReferenceFile(let url, let label, let options):
            return try ReferenceFolderManager.readTextFile(
                at: url.path, label: label, options: options
            )

        case .grepReference(let folder, let pattern, let matchCase, let limit,
                           let regex, let mode, let contextLines, let invert, let scopePath):
            return try ReferenceFolderManager.grep(
                in: folder, pattern: pattern, matchCase: matchCase, limit: limit,
                regex: regex, mode: mode, contextLines: contextLines,
                invert: invert, scopePath: scopePath
            )

        case .fileFind(let root, let nameGlob, let extension_, let minSizeBytes, let maxSizeBytes,
                       let modifiedAfter, let modifiedBefore, let sortBy, let maxResults,
                       let allowNetworkVolumes):
            // Bounded even here: the batch is off-actor, but a wedged share
            // would still hold the whole group until it answered.
            let outcome = await FileSystemBounds.runWithDeadline(
                seconds: FileToolbox.walkTimeoutSeconds
            ) { @Sendable in
                try FileToolbox.find(
                    root: root,
                    nameGlob: nameGlob,
                    extension_: extension_,
                    minSizeBytes: minSizeBytes,
                    maxSizeBytes: maxSizeBytes,
                    modifiedAfter: modifiedAfter,
                    modifiedBefore: modifiedBefore,
                    sortBy: sortBy,
                    maxResults: maxResults,
                    allowNetworkVolumes: allowNetworkVolumes
                )
            }
            switch outcome {
            case .timedOut:
                throw LocalToolError.invalidArguments(FileSystemBounds.timeoutMessage(
                    tool: "file__find", path: root, seconds: FileToolbox.walkTimeoutSeconds
                ))
            case .failed(let message):
                throw LocalToolError.invalidArguments(message)
            case .finished(let result):
                return FileToolbox.renderFind(result)
            }

        case .fileRead(let url, let label, let options):
            return try ReferenceFolderManager.readTextFile(
                at: url.path, label: label, options: options
            )

        case .fileSearch(let root, let pattern, let regex, let caseSensitive, let mode,
                         let contextLines, let invert, let glob, let limit,
                         let allowNetworkVolumes):
            let spec = FileToolbox.SearchSpec(
                root: root, pattern: pattern, regex: regex, caseSensitive: caseSensitive,
                mode: mode, contextLines: contextLines, invert: invert, glob: glob, limit: limit
            )
            let outcome = await FileSystemBounds.runWithDeadline(
                seconds: FileToolbox.walkTimeoutSeconds
            ) { @Sendable in
                try FileToolbox.search(spec, allowNetworkVolumes: allowNetworkVolumes)
            }
            switch outcome {
            case .timedOut:
                throw LocalToolError.invalidArguments(FileSystemBounds.timeoutMessage(
                    tool: "file__search", path: root, seconds: FileToolbox.walkTimeoutSeconds
                ))
            case .failed(let message):
                throw LocalToolError.invalidArguments(message)
            case .finished(let text):
                return text
            }

        case .fileHash(let path, let label):
            return FileToolbox.renderHash(try FileToolbox.hashFile(at: path.path), label: label)

        case .fileHex(let spec):
            return try FileToolbox.runHex(spec)

        case .readSkillFile(let url, let label, let maxChars):
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw ReferenceFolderError.notFound(label)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ReferenceFolderError.notReadable(label)
            }
            return text.count > maxChars
                ? String(text.prefix(maxChars)) + "\n[... file truncated ...]"
                : text

        case .projectReadFile, .projectOutline, .projectGrep, .projectSkillFile:
            // TypstEdit's project reads keep their own off-actor executor
            // (it holds the section anchoring, windowing and grep scan the
            // sequential path uses, so a batched read answers exactly what a
            // lone one would). It returns the outcome form because the
            // read-before-edit ledger needs the file path and modification
            // date; the batch caller applies the ledger and unwraps.
            return try LocalToolExecutor.runProjectReadOnly(plan).output

        case .mcpTool(let serverName, let toolName, let argumentsJSON):
            // Dispatched through the runner the active agent installed, which
            // owns the connection (TypstEdit keeps one MCPManager per window).
            // The await is the whole point: the reply is the round trip that
            // overlapping avoids paying twice.
            let arguments = (try? JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8)
            )) as? [String: Any] ?? [:]
            guard let call = Self.mcpCall else {
                throw LocalToolError.invalidArguments("No active chat owns the MCP connection, so this server tool cannot run in a batch. Run it as a single call instead.")
            }
            return try await call(
                serverName, toolName, arguments
            )
        }
    }

    /// The MCP round trip a `.mcpTool` plan uses, installed by the active
    /// agent (it knows which window's `MCPManager` owns the server). `nil`
    /// means no agent is running — the batch refuses the call rather than
    /// guessing at a manager.
    nonisolated(unsafe) static var mcpCall: (
        (_ serverName: String, _ toolName: String, _ arguments: [String: Any]) async throws -> String
    )? = nil

    /// Runs a batch with at most `ParallelToolCalls.maxConcurrent` in flight,
    /// keyed by the caller's index so the results can be reassembled in the
    /// order the model wrote the calls.
    ///
    /// A group does not cancel its children by itself, so a Stop would wait out
    /// every remaining read. `withTaskCancellationHandler` and the
    /// `Task.isCancelled` check stop admitting new work instead.
    nonisolated static func runBatch(
        _ plans: [(index: Int, plan: ReadOnlyToolPlan)]
    ) async -> [Int: ReadOnlyToolResult] {
        guard !plans.isEmpty else { return [:] }

        var results: [Int: ReadOnlyToolResult] = [:]
        let limit = max(1, ParallelToolCalls.maxConcurrent)

        await withTaskGroup(of: (Int, ReadOnlyToolResult).self) { group in
            var next = 0

            func add(_ entry: (index: Int, plan: ReadOnlyToolPlan)) {
                group.addTask {
                    do {
                        return (entry.index, .success(try await run(entry.plan)))
                    } catch {
                        return (entry.index, .failure(error.localizedDescription))
                    }
                }
            }

            while next < plans.count, next < limit {
                add(plans[next])
                next += 1
            }
            while let finished = await group.next() {
                results[finished.0] = finished.1
                // Cancelled: stop admitting work, but still drain what is
                // running so the group's scope can close.
                if Task.isCancelled { continue }
                if next < plans.count {
                    add(plans[next])
                    next += 1
                }
            }
        }
        return results
    }
}
