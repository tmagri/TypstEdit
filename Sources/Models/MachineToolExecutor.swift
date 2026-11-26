import Foundation

/// Executes TypstEdit's machine-level tools: the read-only `file__*` set
/// (find/read/search/hash/hex, over `FileToolbox`) and the `shell__run`
/// command runner (sandbox-exec profile, elevation refusal, `sudo -A` askpass
/// helper under Bypass Permissions, SIGTERM→SIGKILL timeouts, and a
/// `background` detach that survives the call). Ported from Clippy's
/// `ClippyToolExecutor`, trimmed to the two namespaces TypstEdit lacks —
/// project, python, web and screen tools live in `LocalToolExecutor`.
///
/// Tools are namespaced (`file__find`, `shell__run`) and qualified for the
/// providers as `namespace__name`, the same convention the gospel harness
/// uses.
@MainActor
final class MachineToolExecutor: ObservableObject {
    static let shellNamespace = "shell"
    static let fileNamespace = "file"

    // MARK: Feature flags (Settings → AI Chat → Tools)

    /// Whether the shell tool exists at all. Off by default.
    var shellToolEnabled: Bool { AISettingsManager.shared.shellToolEnabled }
    /// Whether commands run under `sandbox-exec` (no network, writes limited
    /// to a per-run scratch folder).
    var shellSandboxEnabled: Bool { AISettingsManager.shared.shellSandboxEnabled }

    /// Whether the read-only `file__*` tools exist. On by default: they are
    /// strictly narrower than `python__run` (which is also on by default) —
    /// every one of them only reads, and none can spawn a process, so they
    /// turn hand-coded shell/python one-liners into one auditable call. They
    /// can read files anywhere the user's account can, which is the point,
    /// and it is no wider than what the sandboxed Python tool already reads.
    var fileToolEnabled: Bool { AISettingsManager.shared.fileToolEnabled }

    /// Whether the `file__*` walks may descend into a network volume. Off by
    /// default; see `AISettingsManager.fileToolNetworkVolumesEnabled`.
    var fileToolNetworkVolumesEnabled: Bool { AISettingsManager.shared.fileToolNetworkVolumesEnabled }

    /// YOLO auto-approval. The executor asks the agent's gate through
    /// `willAutoApprove`, set from the agent's `yoloMode`.
    var willAutoApprove: (PendingApprovalKind) -> Bool = { _ in false }

    /// Whether a card can actually be put in front of the user. False for a
    /// background (subscription) run, where an approval would wait forever.
    /// The agent sets it from `isBackgroundRun`.
    var canShowApprovalCard: Bool = true

    /// The user's saved permission rules. A matching deny rule refuses the
    /// call here, before `willAutoApprove` or a card — so it holds under
    /// YOLO too. Allow rules are the agent's business (they feed
    /// `willAutoApprove`, where the safety monitor can still veto them).
    var permissionRules: () -> [PermissionRule] = { AISettingsManager.shared.permissionRules }

    /// Bypass Permissions for the chat this executor belongs to ("super
    /// YOLO"). Set from the agent's `effectiveBypassPermissions`. It is not
    /// an approval switch — approvals are the agent's gate — it is what turns
    /// the *sandbox* and the *sudo* refusals off, so "anything will run"
    /// really is true rather than "anything will be approved and then blocked
    /// by sandbox-exec".
    var bypassPermissions: () -> Bool = { false }

    /// Whether the chat is bypassing permissions right now. Read once per
    /// call, so flipping the switch takes effect on the next one.
    var isBypassingPermissions: Bool { bypassPermissions() }

    /// Where shell commands run (the reference folder). Commands run with
    /// this as the working directory when it exists, so a relative path
    /// reaches the user's notes without being spelled out.
    var workingDirectory: URL {
        let folder = referenceFolder
        if FileManager.default.fileExists(atPath: folder) {
            return URL(fileURLWithPath: folder, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    var referenceFolder: String {
        referenceManager().folderPath
    }

    /// The reference folder this executor serves, when the conversation it
    /// belongs to has picked one of its own. Empty = follow the app setting.
    /// Set once by the agent that owns the executor, so a tool call reads the
    /// same folder the chat header shows. It is only the *default*: the
    /// `file__*` tools read any folder the model names.
    var conversationReferenceFolder: () -> String = { "" }

    /// The folder resolver for this conversation. One constructor for every
    /// call site, so a per-conversation pick cannot reach some tools and miss
    /// others.
    func referenceManager() -> ReferenceFolderManager {
        ReferenceFolderManager(
            settings: { AISettingsManager.shared.reference },
            conversationFolderPath: conversationReferenceFolder
        )
    }

    // MARK: - Tool list

    func tools() -> [MCPTool] {
        var tools: [MCPTool] = []

        // File tools — the read-only "grep+" set (find/read/search/hash/hex).
        // All read-only: safe for the concurrent batch, the subagent, and
        // Plan mode.
        if fileToolEnabled {
            tools.append(MCPTool(
                serverName: Self.fileNamespace,
                name: "find",
                description: "Find files anywhere on this Mac by property: name glob (*.wram.gz, bank??.asm), extension, size range, and/or modification date. Returns one line per hit with size and modified date, newest first by default. Reads only — it never lists what it cannot read. Use it for \"where is …\", \"what changed since …\", \"files bigger than …\" instead of guessing paths or hand-writing find/ls pipelines. A walk that stops at its limit says so.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "root": ["type": "string", "description": "Folder to search under. Absolute path or ~ path — any folder on this Mac. Default: TypstEdit's reference folder."],
                        "name_glob": ["type": "string", "description": "Glob pattern for the file name, e.g. \"*.rom\", \"Makefile\", \"bank??.asm\". Case-insensitive."],
                        "extension": ["type": "string", "description": "Only files with this extension, e.g. \"swift\" or \".asm\"."],
                        "min_size_bytes": ["type": "integer", "description": "Only files at least this many bytes."],
                        "max_size_bytes": ["type": "integer", "description": "Only files at most this many bytes."],
                        "modified_after": ["type": "string", "description": "Only files modified after this date, e.g. \"2026-11-24\" or a full ISO 8601 timestamp."],
                        "modified_before": ["type": "string", "description": "Only files modified before this date."],
                        "sort_by": ["type": "string", "enum": ["modified", "name", "size"], "description": "modified = newest first (default), name = alphabetical, size = largest first."],
                        "max_results": ["type": "integer", "description": "Most hits to return. Default 100."],
                    ],
                    "required": [],
                ]
            ))
            tools.append(MCPTool(
                serverName: Self.fileNamespace,
                name: "read",
                description: "Read a text file at any absolute or ~ path on this Mac, paged by line; pass start_line/end_line to page through a big file. outline: true lists headings and code declarations with the line range of each block, skim: true adds one line from inside each block, and symbol: \"name\" reads exactly one declaration's block. A binary file answers with a short description (size, format) rather than an error — get its bytes with file__hex. Use this instead of sed -n/head/tail pipelines. Reading the user's private data (mail, keychains, other apps' containers) is never appropriate — it is their machine, not yours.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute or ~ file path."],
                        "start_line": ["type": "integer", "description": "First line, 1-based. Default 1."],
                        "end_line": ["type": "integer", "description": "Last line. Defaults to start_line + 2000."],
                        "outline": ["type": "boolean", "description": "Return a map of headings and code declarations with their line ranges."],
                        "skim": ["type": "boolean", "description": "An outline that also quotes one line from inside each block."],
                        "symbol": ["type": "string", "description": "Read exactly one declaration's block by name."],
                        "full": ["type": "boolean", "description": "With outline or skim: list every nested member too, not just the top two levels."],
                    ],
                    "required": ["path"],
                ]
            ))
            tools.append(MCPTool(
                serverName: Self.fileNamespace,
                name: "search",
                description: "Search text in files at any path on this Mac: regex or literal, case control, mode (match/count/filenames/matches_only/frequency), context lines, invert, and a glob filter for which files to search. Give path a file to search one file, a folder to search under it, or any folder on this Mac. Use this instead of grep -rn/-c/-l/-o/-v pipelines anywhere on disk.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pattern": ["type": "string", "description": "The text or regular expression to search for."],
                        "path": ["type": "string", "description": "File or folder to search: a file to search, or a folder to search under — any folder on this Mac. Default: TypstEdit's reference folder."],
                        "regex": ["type": "boolean", "description": "Treat pattern as a regular expression. Default false."],
                        "match_case": ["type": "boolean", "description": "Case-sensitive search. Default false."],
                        "mode": ["type": "string", "enum": ["match", "count", "filenames", "matches_only", "frequency"],
                                 "description": "How matches are reported. Default \"match\"."],
                        "context_lines": ["type": "integer", "description": "Lines of context around each hit."],
                        "invert": ["type": "boolean", "description": "Return lines that do NOT match."],
                        "glob": ["type": "string", "description": "Only search files whose name matches this glob, e.g. \"*.asm\"."],
                        "max_results": ["type": "integer", "description": "Most matches to return. Default 200."],
                    ],
                    "required": ["pattern"],
                ]
            ))
            tools.append(MCPTool(
                serverName: Self.fileNamespace,
                name: "hash",
                description: "Hash one file: returns crc32, md5, sha1 and sha256 in one call, plus the size. Use it to verify a file against an expected checksum (a ROM patch, a downloaded artifact, a case artifact) instead of a python zlib/shasum one-liner. crc32 is the value zlib.crc32 computes — the usual \"correct\" CRC for ROM/data work.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute or ~ file path."],
                    ],
                    "required": ["path"],
                ]
            ))
            tools.append(MCPTool(
                serverName: Self.fileNamespace,
                name: "hex",
                description: "Inspect the bytes of a binary file — the tool that replaces hexdump/xxd/struct/strings one-liners. mode: \"dump\" returns an xxd-style hex+ASCII dump from an offset (use file__hash's size or a read result to pick one); \"find\" searches for a byte pattern given as hex (\"A4 03\") or as an integer value with width_bytes and endian (\"little\", \"big\" or \"both\" for the two spellings side by side) and returns every offset with hex context — this finds a 16-bit little-endian pointer like $A403 everywhere it appears; \"read\" unpacks integers at an offset (width 1/2/4/8 bytes, signed or unsigned, either endianness); \"strings\" lists printable runs. When endian is \"both\" and the two byte orders differ, find reports both.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "enum": ["dump", "find", "read", "strings"],
                                 "description": "What to do. Default \"dump\"."],
                        "path": ["type": "string", "description": "Absolute or ~ file path."],
                        "offset": ["type": "integer", "description": "Start byte for dump/read. Supports hex like \"0x1F30\" or decimal."],
                        "length": ["type": "integer", "description": "Bytes for a dump. Default 256."],
                        "hex": ["type": "string", "description": "find: hex byte pattern, e.g. \"A4 03\" or \"A403\"."],
                        "value": ["type": "integer", "description": "find: integer to search for, in the width and endianness given. Accepts hex like 42035 or 0xA403."],
                        "width_bytes": ["type": "integer", "description": "find/read: value width in bytes — 1, 2, 4 or 8. find infers from the value when omitted; read requires it."],
                        "endian": ["type": "string", "enum": ["little", "big", "both"], "description": "find: byte order to search for. Default \"both\" — every spelling of the value gets a chance."],
                        "count": ["type": "integer", "description": "read: how many integers to unpack. Default 1."],
                        "signed": ["type": "integer", "description": "read: whether the integers are signed. 1 = signed, 0 = unsigned (default)."],
                        "min_length": ["type": "integer", "description": "strings: shortest printable run. Default 4."],
                    ],
                    "required": ["path", "mode"],
                ]
            ))
        }

        // Shell — the generic command runner. Kept apart from Python: a
        // command line is what the user would have typed in a terminal, and
        // it is what the approval card shows verbatim.
        if shellToolEnabled {
            let bypassing = isBypassingPermissions
            let sandboxNote = bypassing
                ? "Runs with your macOS user's full permissions: no sandbox, network reachable, no approval card, and sudo is allowed (`sudo -A`, which pops a macOS password dialog)."
                : shellSandboxEnabled
                    ? "Runs under macOS sandbox-exec: no network access, and writes are limited to a per-run scratch folder whose path is returned in the result ($TMPDIR points at it). Reading the reference folder is allowed."
                    : "Runs with your macOS user's permissions, working directory set to the reference folder, with no sandboxing or network isolation."
            let agentNote = Self.sshAgentSocket() != nil
                ? " A live SSH agent is available (SSH_AUTH_SOCK is set), so `ssh`/`scp`/`rsync` over ssh can use keys without a passphrase prompt — use `-o BatchMode=yes` so a host that would prompt fails fast instead of hanging."
                : " There is no SSH agent and no stdin, so `ssh` can only use a key with no passphrase: use `-o BatchMode=yes` and expect a passphrase-protected key to fail."
            let approvalNote = bypassing
                ? ""
                : " The exact command is always shown to you for approval before anything runs."
            tools.append(MCPTool(
                serverName: Self.shellNamespace,
                name: "run",
                description: "Run one shell command (`/bin/zsh -lc`) and return its stdout/stderr and exit status. \(sandboxNote)\(agentNote)\(approvalNote) Prefer this over python__run for ordinary commands (ls, grep, git, wc, jq, du); use python__run for real computation. There is no TTY and stdin is empty, so pass non-interactive flags (`git --no-pager`, `rm -f`, `-y`): a command that prompts gets EOF and fails instead of waiting. The call is killed at `timeoutSeconds` (default 120, max 3600); for anything that may outlive that — a large copy, `rsync`, a build, a `ddrescue` pass — set `background: true` and poll the log path it returns instead.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "The full command line, run as `/bin/zsh -lc`. Use one command; `&&` chains work but are harder to review."],
                        "timeoutSeconds": ["type": "number", "description": "How long this call may run before it is killed: 5 to 3600 seconds, default 120. Raise it for a slow command you want the output of; use `background` instead if it may run longer than that or must survive this call."],
                        "background": ["type": "boolean", "description": "Detach the command and return a log path instead of waiting. Use for a copy, an rsync, a compile or any job that should keep running after the call returns. The same approval card is shown."],
                    ],
                    "required": ["command"],
                ]
            ))
        }

        return tools
    }

    // MARK: - Execution

    /// Parses a read-only call into a `Sendable` plan, or returns `nil` when
    /// the call is not one the concurrent batch may run.
    ///
    /// Resolving paths and reading settings happen here, on the main actor,
    /// because both are main-actor state. What the plan carries is plain data,
    /// so `ReadOnlyToolRunner` can do the file I/O off the actor.
    ///
    /// `toolName` is the **qualified** name (`file__read`). It was
    /// documented as the bare one and the cases have always matched the
    /// qualified form, so callers that stripped the namespace first matched no
    /// case at all and every such call fell back to the sequential path —
    /// silently, because `nil` here means "not batchable" rather than "error".
    /// The parameter is named for what it is now.
    ///
    /// Throwing is deliberate: an argument mistake must reach the model with
    /// the same message the sequential path produces, not be silently dropped
    /// from the batch.
    func readOnlyPlan(toolName: String, arguments: [String: Any]) throws -> ReadOnlyToolPlan? {
        let manager = referenceManager()

        switch toolName {
        case "\(Self.fileNamespace)__find":
            // The toggle gates the batch path too: a plan built while the
            // setting is off must not reach the runner.
            guard fileToolEnabled else { return nil }
            let base = manager.folderPath
            let root = (arguments["root"] as? String)
                .flatMap { FileToolbox.resolvePath($0, relativeTo: base) }
                ?? base
            var after: Date?
            if let raw = arguments["modified_after"] as? String, !raw.isEmpty {
                guard let parsed = FileToolbox.parseDate(raw) else {
                    throw LocalToolError.invalidArguments(
                        "modified_after must be a date like \"2026-11-24\" or a full ISO 8601 timestamp — got \"\(raw)\"."
                    )
                }
                after = parsed
            }
            var before: Date?
            if let raw = arguments["modified_before"] as? String, !raw.isEmpty {
                guard let parsed = FileToolbox.parseDate(raw) else {
                    throw LocalToolError.invalidArguments(
                        "modified_before must be a date like \"2026-11-24\" or a full ISO 8601 timestamp — got \"\(raw)\"."
                    )
                }
                before = parsed
            }
            return .fileFind(
                root: root,
                nameGlob: arguments["name_glob"] as? String,
                extension_: arguments["extension"] as? String,
                minSizeBytes: arguments["min_size_bytes"] as? Int,
                maxSizeBytes: arguments["max_size_bytes"] as? Int,
                modifiedAfter: after,
                modifiedBefore: before,
                sortBy: arguments["sort_by"] as? String,
                maxResults: arguments["max_results"] as? Int ?? 100,
                allowNetworkVolumes: fileToolNetworkVolumesEnabled
            )

        case "\(Self.fileNamespace)__read":
            guard fileToolEnabled else { return nil }
            guard let requested = arguments["path"] as? String, !requested.isEmpty,
                  let resolved = FileToolbox.resolvePath(
                    requested, relativeTo: manager.folderPath
                  ) else {
                throw LocalToolError.invalidArguments("path is required")
            }
            return .fileRead(
                url: URL(fileURLWithPath: resolved),
                label: requested,
                options: FileReadOptions(arguments: arguments)
            )

        case "\(Self.fileNamespace)__search":
            guard fileToolEnabled else { return nil }
            guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
                throw LocalToolError.invalidArguments("pattern is required")
            }
            _ = try FileToolbox.compileRegex(
                pattern: pattern,
                regex: arguments["regex"] as? Bool ?? false,
                caseSensitive: arguments["match_case"] as? Bool ?? false
            )
            return .fileSearch(
                root: (arguments["path"] as? String)
                    .flatMap { FileToolbox.resolvePath($0, relativeTo: manager.folderPath) }
                    ?? manager.folderPath,
                pattern: pattern,
                regex: arguments["regex"] as? Bool ?? false,
                caseSensitive: arguments["match_case"] as? Bool ?? false,
                mode: (arguments["mode"] as? String).flatMap(FileToolbox.SearchMode.init(rawValue:)) ?? .match,
                contextLines: min(arguments["context_lines"] as? Int ?? 0, 10),
                invert: arguments["invert"] as? Bool ?? false,
                glob: arguments["glob"] as? String,
                limit: (arguments["max_results"] as? Int).map { max(1, min($0, FileToolbox.searchMatchLimit)) }
                    ?? FileToolbox.searchMatchLimit,
                allowNetworkVolumes: fileToolNetworkVolumesEnabled
            )

        case "\(Self.fileNamespace)__hash":
            guard fileToolEnabled else { return nil }
            guard let requested = arguments["path"] as? String, !requested.isEmpty,
                  let resolved = FileToolbox.resolvePath(
                    requested, relativeTo: manager.folderPath
                  ) else {
                throw LocalToolError.invalidArguments("path is required")
            }
            return .fileHash(path: URL(fileURLWithPath: resolved), label: requested)

        case "\(Self.fileNamespace)__hex":
            guard fileToolEnabled else { return nil }
            return .fileHex(spec: try FileToolbox.parseHexSpec(
                arguments: arguments, relativeTo: manager.folderPath
            ))

        default:
            return nil
        }
    }

    /// Runs one tool call.
    ///
    /// `onFileChange` is kept for interface compatibility with the agent's
    /// file-write tools: nothing this executor runs changes a file (the
    /// `file__*` tools only read, and a shell run reports what it did through
    /// its own output), so it is never called here.
    func execute(
        qualifiedName: String,
        argumentsJSON: String,
        onFileChange: ((ProjectFileChange) -> Void)? = nil,
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]

        // Every executor tool funnels its approval through this wrapper, so
        // the YOLO gate applies no matter which private helper asks. The
        // agent has the same check (it owns agent-level kinds like mail and
        // notes), but enforcing it here too means a future call site that
        // passes a raw card closure cannot silently defeat YOLO.
        //
        // Saved deny rules come first: they refuse the call outright, with
        // no card, under YOLO or not.
        let gatedApproval: (PendingApprovalKind) async throws -> Bool = { [willAutoApprove, permissionRules] kind in
            if case .deny(let rule) = PermissionRules.decision(for: kind, rules: permissionRules()) {
                throw LocalToolError.blockedByRule(rule)
            }
            if willAutoApprove(kind) { return true }
            return await requestApproval(kind)
        }

        switch qualifiedName {
        case "\(Self.fileNamespace)__find":
            guard fileToolEnabled else { throw LocalToolError.invalidArguments("The file tools are turned off — enable them in Settings → AI Chat → Tools.") }
            return try await fileFind(arguments)
        case "\(Self.fileNamespace)__read":
            guard fileToolEnabled else { throw LocalToolError.invalidArguments("The file tools are turned off — enable them in Settings → AI Chat → Tools.") }
            return try fileRead(arguments)
        case "\(Self.fileNamespace)__search":
            guard fileToolEnabled else { throw LocalToolError.invalidArguments("The file tools are turned off — enable them in Settings → AI Chat → Tools.") }
            return try await fileSearch(arguments)
        case "\(Self.fileNamespace)__hash":
            guard fileToolEnabled else { throw LocalToolError.invalidArguments("The file tools are turned off — enable them in Settings → AI Chat → Tools.") }
            return try await fileHash(arguments)
        case "\(Self.fileNamespace)__hex":
            guard fileToolEnabled else { throw LocalToolError.invalidArguments("The file tools are turned off — enable them in Settings → AI Chat → Tools.") }
            return try fileHex(arguments)
        case "\(Self.shellNamespace)__run":
            return try await runShell(arguments, requestApproval: gatedApproval)
        default:
            throw LocalToolError.invalidArguments("Unknown tool '\(qualifiedName)'")
        }
    }

    // MARK: - File tools (read-only "grep+")

    private func fileFind(_ arguments: [String: Any]) async throws -> String {
        let manager = referenceManager()
        let base = manager.folderPath
        // A relative root means "relative to this chat's folder", never the
        // process's working directory (`/` for a GUI app). See
        // `FileToolbox.resolvePath(_:relativeTo:)`.
        let root = (arguments["root"] as? String)
            .flatMap { FileToolbox.resolvePath($0, relativeTo: base) }
            ?? base
        let networkAllowed = fileToolNetworkVolumesEnabled

        // Optional date filters: parse only when the model supplied one, and
        // fail with a named message when it does not parse.
        var after: Date?
        if let raw = arguments["modified_after"] as? String, !raw.isEmpty {
            guard let parsed = FileToolbox.parseDate(raw) else {
                throw LocalToolError.invalidArguments(
                    "modified_after must be a date like \"2026-11-24\" or a full ISO 8601 timestamp — got \"\(raw)\"."
                )
            }
            after = parsed
        }
        var before: Date?
        if let raw = arguments["modified_before"] as? String, !raw.isEmpty {
            guard let parsed = FileToolbox.parseDate(raw) else {
                throw LocalToolError.invalidArguments(
                    "modified_before must be a date like \"2026-11-24\" or a full ISO 8601 timestamp — got \"\(raw)\"."
                )
            }
            before = parsed
        }

        // Everything the walk needs is plain data by this point: a
        // `[String: Any]` argument dictionary is not `Sendable`, so it must
        // not be captured by the off-actor closure.
        let nameGlob = arguments["name_glob"] as? String
        let extension_ = arguments["extension"] as? String
        let minSize = arguments["min_size_bytes"] as? Int
        let maxSize = arguments["max_size_bytes"] as? Int
        let sortBy = arguments["sort_by"] as? String
        let maxResults = arguments["max_results"] as? Int ?? 100
        let modifiedAfter = after
        let modifiedBefore = before

        // The walk runs off the main actor with a deadline: a blocking
        // directory read on a dying volume cannot be interrupted, so racing
        // it against a timer is the only thing that keeps the turn alive.
        let outcome = await FileSystemBounds.runWithDeadline(
            seconds: FileToolbox.walkTimeoutSeconds
        ) { @Sendable in
            try FileToolbox.find(
                root: root,
                nameGlob: nameGlob,
                extension_: extension_,
                minSizeBytes: minSize,
                maxSizeBytes: maxSize,
                modifiedAfter: modifiedAfter,
                modifiedBefore: modifiedBefore,
                sortBy: sortBy,
                maxResults: maxResults,
                allowNetworkVolumes: networkAllowed
            )
        }
        switch outcome {
        case .timedOut:
            throw LocalToolError.invalidArguments(
                FileSystemBounds.timeoutMessage(
                    tool: "file__find", path: root, seconds: FileToolbox.walkTimeoutSeconds
                )
            )
        case .failed(let message):
            throw LocalToolError.invalidArguments(message)
        case .finished(let result):
            return FileToolbox.renderFind(result)
        }
    }

    private func fileRead(_ arguments: [String: Any]) throws -> String {
        let base = referenceManager().folderPath
        guard let requested = arguments["path"] as? String,
              let resolved = FileToolbox.resolvePath(requested, relativeTo: base) else {
            throw LocalToolError.invalidArguments("path is required")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            throw LocalToolError.invalidArguments(
                "File not found: \(requested). Call file__find to locate it instead of guessing."
            )
        }
        if isDirectory.boolValue {
            throw LocalToolError.invalidArguments(
                "\(requested) is a folder, not a file. Call file__find to see what is inside it, or file__search to search under it."
            )
        }
        return try ReferenceFolderManager.readTextFile(
            at: resolved, label: requested, options: FileReadOptions(arguments: arguments)
        )
    }

    private func fileSearch(_ arguments: [String: Any]) async throws -> String {
        guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
            throw LocalToolError.invalidArguments("pattern is required")
        }
        let manager = referenceManager()
        let base = manager.folderPath
        let root = (arguments["path"] as? String)
            .flatMap { FileToolbox.resolvePath($0, relativeTo: base) }
            ?? base
        let networkAllowed = fileToolNetworkVolumesEnabled
        let spec = FileToolbox.SearchSpec(
            root: root,
            pattern: pattern,
            regex: arguments["regex"] as? Bool ?? false,
            caseSensitive: arguments["match_case"] as? Bool ?? false,
            mode: (arguments["mode"] as? String).flatMap(FileToolbox.SearchMode.init(rawValue:)) ?? .match,
            contextLines: min(arguments["context_lines"] as? Int ?? 0, 10),
            invert: arguments["invert"] as? Bool ?? false,
            glob: arguments["glob"] as? String,
            limit: (arguments["max_results"] as? Int).map { max(1, min($0, FileToolbox.searchMatchLimit)) }
                ?? FileToolbox.searchMatchLimit
        )
        // The pattern is compiled here, on the caller's side, so an invalid
        // regex still fails with the message the model can act on rather
        // than being swallowed by the walk's error-tolerant worker.
        _ = try FileToolbox.compileRegex(
            pattern: spec.pattern, regex: spec.regex, caseSensitive: spec.caseSensitive
        )
        let outcome = await FileSystemBounds.runWithDeadline(
            seconds: FileToolbox.walkTimeoutSeconds
        ) { @Sendable in
            try FileToolbox.search(spec, allowNetworkVolumes: networkAllowed)
        }
        switch outcome {
        case .timedOut:
            throw LocalToolError.invalidArguments(
                FileSystemBounds.timeoutMessage(
                    tool: "file__search", path: root, seconds: FileToolbox.walkTimeoutSeconds
                )
            )
        case .failed(let message):
            throw LocalToolError.invalidArguments(message)
        case .finished(let text):
            return text
        }
    }

    private func fileHash(_ arguments: [String: Any]) async throws -> String {
        let base = referenceManager().folderPath
        guard let requested = arguments["path"] as? String,
              let resolved = FileToolbox.resolvePath(requested, relativeTo: base) else {
            throw LocalToolError.invalidArguments("path is required")
        }
        // A hash of a file on a dead share blocks just as a walk does, so it
        // gets the same treatment.
        let outcome = await FileSystemBounds.runWithDeadline(
            seconds: FileToolbox.walkTimeoutSeconds
        ) { @Sendable in
            try FileToolbox.hashFile(at: resolved)
        }
        switch outcome {
        case .timedOut:
            throw LocalToolError.invalidArguments(
                FileSystemBounds.timeoutMessage(
                    tool: "file__hash", path: resolved, seconds: FileToolbox.walkTimeoutSeconds
                )
            )
        case .failed(let message):
            throw LocalToolError.invalidArguments(message)
        case .finished(let result):
            return FileToolbox.renderHash(result, label: requested)
        }
    }

    private func fileHex(_ arguments: [String: Any]) throws -> String {
        let spec = try FileToolbox.parseHexSpec(
            arguments: arguments, relativeTo: referenceManager().folderPath
        )
        return try FileToolbox.runHex(spec)
    }

    // MARK: - Shell

    /// Runs one command line through `/bin/zsh -lc` and returns its output.
    ///
    /// The login shell (`-l`) is what makes the tool usable at all from a
    /// GUI-launched app: TypstEdit inherits a minimal environment, so without
    /// it `brew`, `git` and anything else on the Homebrew PATH would be
    /// missing. Under the sandbox the user's profile scripts still run, with
    /// writes denied — a profile that writes prints a warning into stderr,
    /// which is harmless and cheaper than a tool that cannot find `git`.
    ///
    /// Elevated commands are refused outright rather than gated: sudo has no
    /// TTY here, and a shell that can ask for a root password is a much
    /// larger surface than a reviewed script that does. `python__run` with
    /// its sudo opt-in is the deliberate path for that.
    ///
    /// Bypass Permissions is the one exception: it is the mode where the
    /// answer to "can it run this?" is yes, so a `sudo` command is handed the
    /// same askpass helper `python__run` uses (macOS still shows its own
    /// password dialog — the password never touches the transcript), and the
    /// sandbox is dropped so the command reaches the network and the disk.
    ///
    /// `timeoutSeconds` is the caller's choice because not every command is a
    /// one-shot query. The default stays short — a wedged `grep` should not
    /// hold a turn for minutes — but a copy, an `rsync`, a compile or a
    /// `ddrescue` pass is legitimately long, and killing one mid-file is worse
    /// than waiting. The ceiling exists so no single call can hang a chat
    /// indefinitely; anything past it belongs in `background`, which detaches
    /// the job and reports progress instead of streaming it.
    private func runShell(
        _ arguments: [String: Any],
        requestApproval: @escaping (PendingApprovalKind) async throws -> Bool
    ) async throws -> String {
        guard shellToolEnabled else {
            throw LocalToolError.invalidArguments("The shell tool isn't enabled — turn it on in Settings → AI Chat → Tools.")
        }
        guard let command = arguments["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidArguments("command is required")
        }
        let bypassing = isBypassingPermissions
        let wantsElevation = Self.codeWantsElevation(command)
        if wantsElevation, !bypassing { throw LocalToolError.shellElevationRefused }

        let background = arguments["background"] as? Bool ?? false
        let timeoutSeconds = Self.shellTimeout(arguments["timeoutSeconds"])

        let kind = PendingApprovalKind.runShell(command: command)
        let approved = try await requestApproval(kind)
        guard approved else { throw LocalToolError.approvalDenied }

        guard let shell = Self.resolveShell() else { throw LocalToolError.shellNotFound }

        // Per-run scratch folder: the only place a sandboxed command can
        // write. It is also $TMPDIR, so a command that writes a temp file
        // works without being told where to put it.
        //
        // A backgrounded job keeps its folder: the `defer` below would delete
        // it moments after the job started, taking the copy's destination with
        // it. It lives beside the log instead, so a person can clean it up in
        // the same place they read the log.
        let scratchDir: URL
        if background {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            scratchDir = Self.shellLogDirectory()
                .appendingPathComponent("scratch-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        } else {
            scratchDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("typstedit-sh-\(UUID().uuidString)", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer {
            if !background { try? FileManager.default.removeItem(at: scratchDir) }
        }

        var environment = Self.commandEnvironment(scratchDir: scratchDir)
        // Same rule as the Python runner: an askpass inherited from the
        // launch environment is dropped, and only a bypassing run that asks
        // for elevation gets one.
        environment.removeValue(forKey: "SUDO_ASKPASS")
        var askpassDir: URL?
        if wantsElevation, bypassing {
            let dir = try Self.writeAskpassHelper()
            askpassDir = dir
            environment["SUDO_ASKPASS"] = dir.appendingPathComponent("askpass").path
        }
        defer {
            if let askpassDir {
                try? FileManager.default.removeItem(at: askpassDir)
            }
        }

        let sandboxed = shellSandboxEnabled && !bypassing
        if background {
            // A backgrounded command is detached from this call entirely: the
            // tool returns a handle, and the model polls it with a normal
            // short call. That is the only shape that survives a copy outliving
            // the chat's patience — the shell tool's own timeout cannot reach a
            // process that is no longer its child.
            return try await Self.launchInBackground(
                command: command,
                shell: shell,
                directory: workingDirectory,
                environment: environment,
                sandboxed: sandboxed,
                scratchDir: scratchDir
            )
        }
        let outcome = try await Self.runProcess(
            executablePath: shell,
            arguments: ["-lc", command],
            directory: workingDirectory,
            environment: environment,
            sandboxProfile: sandboxed
                ? Self.sandboxProfile(writable: [Self.canonicalPath(scratchDir)])
                : nil,
            timeoutSeconds: timeoutSeconds
        )

        if Task.isCancelled { throw CancellationError() }

        if outcome.timedOut {
            let partial = String(outcome.stdout.prefix(2_000))
            return """
            Command timed out after \(Int(timeoutSeconds)) seconds and was terminated.
            Partial stdout:
            \(partial)

            If this was expected to take longer (a copy, a build, an rsync), re-run it with a larger `timeoutSeconds`, or run it with `background: true` and poll its log file instead.
            """
        }

        var result = outcome.stdout
        if !outcome.stderr.isEmpty {
            result += (result.isEmpty ? "" : "\n") + "stderr:\n\(outcome.stderr)"
        }
        // The exit status is the whole point of a shell call: `grep` finding
        // nothing and `grep` failing to open the file both print nothing, and
        // only the status tells them apart.
        if outcome.status != 0 {
            result += (result.isEmpty ? "" : "\n") + "exit status \(outcome.status)"
        } else if result.isEmpty {
            result = "(no output, exit status 0)"
        }
        if sandboxed {
            result += "\nSandboxed run: network denied; writable scratch folder was \(scratchDir.path)."
        } else if bypassing {
            result += "\nBypass Permissions run: no sandbox, so the network and the whole disk were reachable."
        }
        let cap = 16_000
        return ToolOutputStore.clip(result, to: cap, label: "shell")
    }

    /// How long this call may run before it is killed.
    ///
    /// Three bands rather than a free number, because the argument comes from
    /// a model: too small and a normal `git status` on a cold cache dies too
    /// early, too large and one wedged command holds a chat for an hour. The
    /// model can name a value in between; anything outside the band is clamped
    /// to it and the clamp is reported in the tool description, not silently
    /// applied to the run.
    nonisolated static let defaultShellTimeout: Double = 120
    nonisolated static let minimumShellTimeout: Double = 5
    nonisolated static let maximumShellTimeout: Double = 3_600

    nonisolated static func shellTimeout(_ raw: Any?) -> Double {
        guard let seconds = (raw as? NSNumber)?.doubleValue ?? (raw as? Double),
              seconds.isFinite, seconds > 0
        else { return defaultShellTimeout }
        return min(max(seconds, minimumShellTimeout), maximumShellTimeout)
    }

    /// Where a backgrounded command's output goes, and how it is found again.
    ///
    /// `~/Library/Logs/TypstEdit/Shell` rather than a temp folder: the whole
    /// point of a detached job is that it outlives the call that started it,
    /// so its log must outlive it too — a copy that runs for six hours needs
    /// its log to still be there afterwards, and a person should be able to
    /// find it in Console.app without knowing TypstEdit's internals.
    nonisolated static func shellLogDirectory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/TypstEdit/Shell", isDirectory: true)
    }

    /// Starts a command with `nohup` under a shell that is already gone by the
    /// time this returns, and answers with the log and pid file paths.
    ///
    /// `nohup` plus a subshell is what makes it survive: the process is
    /// reparented to launchd, so neither the tool's timeout nor TypstEdit
    /// quitting can reach it. stdin is `/dev/null`, so nothing waits on a
    /// terminal that does not exist. A `.pid` file is written next to the log
    /// so a later call can tell "still running" from "finished" without
    /// guessing from the log's last line.
    ///
    /// **The job must be backgrounded inside the wrapper, and the launcher
    /// awaited rather than blocked on.** Two defects made a backgrounded
    /// build freeze the whole app until it finished:
    ///
    /// 1. The wrapper ended in `exec`, so `nohup`'s shell *became* the job
    ///    and `waitUntilExit()` lasted the job's whole run (measured: 3.03 s
    ///    for a 3 s `sleep`, which is why the chat sat on that row's spinner
    ///    until the build ended). `( exec … ) &` makes the launcher's shell
    ///    exit at once (measured: 0.026 s for the same 3 s job) while `exec`
    ///    inside the subshell keeps `$!` pointing at the command itself, so
    ///    the pid file still names the process a person would `kill`.
    /// 2. `waitUntilExit()` is a blocking call. This type is `@MainActor`,
    ///    so it ran on the main thread and the run loop got no turn at all:
    ///    the window stopped redrawing and read as "locked". The wait is now
    ///    `await waitWithTimeout(...)`, which suspends instead of blocking
    ///    and is bounded, because a launcher that hangs (a slow login profile)
    ///    must never take the UI with it.
    @MainActor
    static func launchInBackground(
        command: String,
        shell: String,
        directory: URL,
        environment: [String: String],
        sandboxed: Bool,
        scratchDir: URL
    ) async throws -> String {
        let logDirectory = shellLogDirectory()
        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let slug = command
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "job"
        let safeSlug = slug.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let jobName = "\(stamp)-\(safeSlug.isEmpty ? "job" : safeSlug)-\(UUID().uuidString.prefix(8))"
        let logURL = logDirectory.appendingPathComponent(jobName + ".log")
        let pidURL = logDirectory.appendingPathComponent(jobName + ".pid")

        // The sandbox still applies to a detached job: a backgrounded `curl`
        // must not be the way around a denied network. `sandbox-exec` wraps the
        // job exactly as it wraps a foreground run.
        let inner: String
        if sandboxed, let sandboxExec = sandboxExecPath {
            let profile = sandboxProfile(writable: [canonicalPath(scratchDir)])
            inner = "\(sandboxExec) -p \(shellQuote(profile)) \(shell) -lc \(shellQuote(command))"
        } else {
            inner = "\(shell) -lc \(shellQuote(command))"
        }

        // `echo $!` after backgrounding the subshell is the pid a person needs
        // to `kill` — `exec` inside the subshell keeps that pid on the command
        // rather than on a shell that merely waits for it. The trailing `&`
        // is what lets the launcher exit immediately.
        let wrapper = """
        ( exec \(inner) ) &
        echo $! > \(shellQuote(pidURL.path))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [shell, "-lc", wrapper]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let logHandle = FileHandle(forWritingAtPath: logURL.path)
            ?? {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                return FileHandle(forWritingAtPath: logURL.path)
            }()
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        try process.run()
        // Only the launcher is awaited, and it exits as soon as it has forked
        // the job: `waitWithTimeout` suspends instead of blocking the main
        // thread, and its bound means a hung login profile cannot freeze the
        // app. A detached job is not a child of this call any more, so the
        // timeout reaching the launcher does not reach the job.
        let launcherHung = await waitWithTimeout(process: process, seconds: backgroundLaunchTimeout)
        try? logHandle?.close()

        var lines: [String] = []
        if launcherHung {
            // The launcher never came back, which means the job may or may not
            // be running. Saying "started" here would be a lie the model acts
            // on, so it is reported as unknown and the log is named anyway.
            lines.append(
                "The launcher did not return within \(Int(backgroundLaunchTimeout)) seconds, so it was stopped. The job may or may not be running — check the log and the pid file below before assuming either."
            )
        } else {
            lines.append("Started in the background, detached from this chat. It keeps running if this call ends, the chat is closed or TypstEdit quits.")
        }
        lines.append(contentsOf: [
            "Log: \(logURL.path)",
            "PID file: \(pidURL.path)",
            "",
            "Poll it with:",
            "  tail -5 \(shellQuote(logURL.path))",
            "  test -s \(shellQuote(pidURL.path)) && ps -p $(cat \(shellQuote(pidURL.path))) > /dev/null && echo RUNNING || echo FINISHED",
        ])
        if sandboxed {
            lines.append("")
            lines.append("Sandboxed job: network denied; its writable folder is \(scratchDir.path) and it is kept after the job finishes.")
        }
        return lines.joined(separator: "\n")
    }

    /// How long the *launcher* of a background job may take before it is
    /// stopped, not how long the job may run.
    ///
    /// The launcher only has to fork and write a pid file (measured: 26 ms),
    /// so 15 s is generous by three orders of magnitude. It exists because a
    /// blocking wait here froze the app for the job's whole run; once the wait
    /// was no longer blocking, the remaining hazard was a login profile that
    /// hangs on its own, which must fail a tool call rather than wedge a turn.
    nonisolated static let backgroundLaunchTimeout: Double = 15

    /// Single-quotes a string for `/bin/zsh`. Embedded single quotes are the
    /// only character that needs the `'\''` dance; everything else is literal
    /// inside single quotes, which is why this is used for whole command lines.
    nonisolated static func shellQuote(_ text: String) -> String {
        // A raw string, so the replacement is exactly the four characters
        // `'\''` that zsh needs: close quote, escaped quote, reopen quote.
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The environment a shell command runs in.
    ///
    /// `PAGER`/`GIT_PAGER` are pinned to `cat` because a pager needs a TTY it
    /// does not have, and `TERM=dumb` keeps tools from emitting escape codes
    /// into a transcript. stdin is `/dev/null` (set by `runProcess`), so
    /// anything that prompts gets EOF instead of blocking. The Homebrew
    /// prefixes are appended for the case where a GUI-launched app's login
    /// shell could not add them itself.
    ///
    /// The SSH agent socket is forwarded when one is live (see
    /// `sshAgentSocket()`), because it is the only way an unattended `ssh`
    /// can use a key: there is no TTY to ask for the passphrase, and `ssh`
    /// has no askpass program unless the elevation path writes one.
    nonisolated static func commandEnvironment(
        scratchDir: URL,
        environment inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited
        environment["TMPDIR"] = scratchDir.resolvingSymlinksInPath().path
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["TERM"] = "dumb"
        environment["SHELL"] = "/bin/zsh"
        if let socket = sshAgentSocket(environment: inherited) {
            environment["SSH_AUTH_SOCK"] = socket
        }
        // A GUI app's PATH misses the Homebrew prefixes when the login shell
        // could not add them; appending them is harmless when it did.
        let prefixes = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let existing = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let present = Set(existing.split(separator: ":").map(String.init))
        let missing = prefixes.filter { !present.contains($0) }
        if !missing.isEmpty {
            environment["PATH"] = (missing + [existing]).joined(separator: ":")
        }
        return environment
    }

    nonisolated static func resolveShell() -> String? {
        for path in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// The live `ssh-agent` socket, if this Mac has one.
    ///
    /// A GUI-launched app almost never inherits `SSH_AUTH_SOCK`: the socket is
    /// exported by whatever started the agent (`ssh-agent` in a login shell,
    /// or macOS's launchd job), and a Dock launch sees launchd's own
    /// environment instead. Without it `ssh` cannot use any key that has a
    /// passphrase, and there is no TTY to ask for one — so this is the
    /// difference between "the agent can drive a remote host" and "the agent
    /// can only ask you to". Order: an inherited variable that still points at
    /// a real socket wins, then launchd, then the locations Apple's and
    /// Homebrew's agent setups actually use.
    ///
    /// Only a real socket is returned. A stale path (an agent that died with
    /// a previous login) is worse than none: `ssh` fails with "Error
    /// connecting to agent" instead of falling back to a key on disk.
    ///
    /// Both fallbacks are globs because neither name is stable:
    /// launchd's socket lives in a randomly-named `com.apple.launchd.*`
    /// folder, and Homebrew's agent names its socket `s.<random>.agent.<random>`
    /// rather than `sock`.
    nonisolated static func sshAgentSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchctlGetenv: (String) -> String? = launchctlValue
    ) -> String? {
        var candidates: [String] = []
        if let inherited = environment["SSH_AUTH_SOCK"], !inherited.isEmpty {
            candidates.append(inherited)
        }
        if let fromLaunchd = launchctlGetenv("SSH_AUTH_SOCK"), !fromLaunchd.isEmpty {
            candidates.append(fromLaunchd)
        }
        candidates.append(contentsOf: sshAgentSocketCandidates())
        return candidates.first(where: isSocket)
    }

    /// Where an agent socket is known to live when the environment has lost
    /// track of it. Newest first: a Homebrew agent started minutes ago is a
    /// better bet than one from a login a week ago.
    nonisolated static func sshAgentSocketCandidates() -> [String] {
        var found: [String] = []
        for pattern in [
            NSHomeDirectory() + "/.ssh/agent/*",
            "/private/var/run/com.apple.launchd.*/Listeners",
            "/private/tmp/com.apple.launchd.*/Listeners",
            "/tmp/ssh-*/agent.*",
        ] {
            found.append(contentsOf: expandGlob(pattern))
        }
        // An explicit path is worth a look even when nothing globbed: some
        // setups point at a fixed name.
        found.append("/private/var/run/ssh-agent.socket")
        return found
    }

    /// One `glob(3)` expansion, returning only the paths that matched.
    ///
    /// `glob(3)` rather than `FileManager` because the agent's own names are
    /// not stable (a random launchd folder, a random `s.*.agent.*` socket
    /// name), so the only way to find one is to ask the file system to match a
    /// pattern. `GLOB_NOSORT` keeps a freshly created socket first.
    nonisolated static func expandGlob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, GLOB_NOSORT, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            guard let path = result.gl_pathv[index] else { return nil }
            return String(cString: path)
        }
    }

    /// True for a path that exists and is a unix-domain socket.
    nonisolated static func isSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// One `launchctl getenv` read. Cheap (a few milliseconds), and it answers
    /// the one question the process environment cannot: what the *user's*
    /// session exported, which is where macOS puts a per-user agent socket.
    nonisolated static func launchctlValue(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", name]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    // MARK: - Process helpers

    nonisolated static var sandboxExecPath: String? {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") ? "/usr/bin/sandbox-exec" : nil
    }

    /// `realpath(3)`-based canonicalization. Foundation's
    /// `resolvingSymlinksInPath()` does not rewrite `/var` to `/private/var`
    /// on macOS; sandbox profile paths must be the real ones.
    private static func canonicalPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { pointer -> String in
            guard let pointer, let resolved = realpath(pointer, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Deny-by-default profile that still allows normal reads and process
    /// setup, but blocks all networking and every write outside `writable`
    /// (plus `/dev`, which stdout/stderr need).
    static func sandboxProfile(writable: [String], lockElevation: Bool = false) -> String {
        let writeRules = writable
            .map { $0.replacingOccurrences(of: "\"", with: "\\\"") }
            .map { "(subpath \"\($0)\")" }
            .joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* \(writeRules) (subpath "/dev"))
        """ + (lockElevation ? "\n" + elevationLockRules : "")
    }

    /// Rules that close the routes to root for a run nobody reviewed. Any
    /// `sandbox-exec` profile already stops setuid programs (`sudo`, `su`,
    /// `security_authtrampoline`) from running, however the script spells or
    /// hides the call. On top of that:
    /// - the authorization service is unreachable, so nothing can pop an
    ///   administrator dialog (`with administrator privileges`, or
    ///   `AuthorizationExecuteWithPrivileges` through ctypes);
    /// - `osascript` and LaunchServices (`open`) are denied, so the script
    ///   cannot ask Terminal to run `sudo` in a real terminal outside the
    ///   sandbox.
    static let elevationLockRules = """
        (deny mach-lookup (global-name "com.apple.authd"))
        (deny lsopen)
        (deny process-exec (literal "/usr/bin/osascript"))
        """

    /// Heuristic detection of elevated-privilege use in a command: a
    /// word-boundary `sudo` and osascript's `administrator privileges`. Not a
    /// security boundary — the approval card, the password dialog and (when
    /// on) the sandbox are the real boundaries — it only decides whether the
    /// sudo gate applies, so a false positive merely refuses a harmless
    /// command with an error that says how the user can allow it, and the
    /// model can rewrite the command.
    nonisolated static func codeWantsElevation(_ code: String) -> Bool {
        let range = NSRange(code.startIndex..., in: code)
        return elevationSignal.firstMatch(in: code, options: [], range: range) != nil
    }
    /// `\b` between `SUDO` and `_ASKPASS` never matches (underscore continues
    /// the word), so `SUDO_ASKPASS` alone is not an elevation signal; a bare
    /// `sudo` command is.
    private nonisolated static let elevationSignal = try! NSRegularExpression(
        pattern: #"\bsudo\b|administrator\s+privileges"#,
        options: .caseInsensitive
    )

    /// The askpass helper handed to `sudo -A` through `SUDO_ASKPASS`.
    ///
    /// Plain `sudo` without a TTY always fails ("a terminal is required…"),
    /// which is what keeps elevation impossible while this feature is off.
    /// With Bypass Permissions on, `sudo -A` runs this helper, and osascript
    /// shows the standard macOS dialog with a secure (hidden) text field; the
    /// password travels over sudo's own pipe and never appears in the
    /// command's output or the chat transcript. Cancel — deliberately the
    /// default button, so a stray Return dismisses it — makes osascript exit
    /// non-zero and sudo fail like a declined approval.
    static func askpassScript() -> String {
        #"""
        #!/bin/sh
        # TypstEdit AI Chat askpass helper (SUDO_ASKPASS for `sudo -A`).
        exec /usr/bin/osascript \
          -e 'display dialog ("TypstEdit wants to run a command with sudo." & return & return & "Only enter your password if you understand why the approved command needs it. This gives the command full administrator (root) access.") default answer "" with hidden answer with title "TypstEdit — sudo request" with icon caution buttons {"Cancel", "Allow"} default button "Cancel"' \
          -e 'text returned of result'
        """#
    }

    /// Writes the askpass helper into a fresh private temp folder — folder
    /// and script both 0700 — and returns the folder. The caller deletes it
    /// when the run finishes, so no reusable helper lingers on disk.
    static func writeAskpassHelper() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let script = dir.appendingPathComponent("askpass")
        try askpassScript().write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script.path
        )
        return dir
    }

    /// What one process run produced. Plain data, so it can cross back from
    /// the off-actor wait.
    nonisolated struct ProcessOutcome: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
        var timedOut: Bool
    }

    /// Runs a process with no stdin, captures both pipes, and enforces a
    /// timeout with SIGTERM→SIGKILL.
    ///
    /// The heart of a shell tool is that nothing can prompt: `ssh-keygen -f`,
    /// `rm -i`, `git commit` (no message) would all block forever waiting on
    /// input nobody can type. stdin is `/dev/null`, so they get EOF and fail
    /// instead — a fast, explained failure the model can act on.
    nonisolated static func runProcess(
        executablePath: String,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        sandboxProfile: String?,
        timeoutSeconds: Double
    ) async throws -> ProcessOutcome {
        let process = Process()
        if let sandboxProfile {
            guard let sandboxExec = sandboxExecPath else { throw LocalToolError.sandboxUnavailable }
            process.executableURL = URL(fileURLWithPath: sandboxExec)
            process.arguments = ["-p", sandboxProfile, executablePath] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
        }
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw LocalToolError.invalidArguments("Failed to launch \(executablePath): \(error.localizedDescription)")
        }

        let timedOut = await waitWithTimeout(process: process, seconds: timeoutSeconds)

        // Drained after the process is gone (or killed), so neither read can
        // block on a writer that is still alive.
        let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return ProcessOutcome(
            stdout: outText,
            stderr: errText,
            status: timedOut ? -1 : process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func waitWithTimeout(process: Process, seconds: Double) async -> Bool {
        let exited = Task<Void, Never> {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        }

        // A task group does not cancel its children by itself, so without the
        // handler below a Stop would wait out the whole timeout while the
        // command kept running. Terminating the process makes the `exited`
        // child resume at once; `group.cancelAll()` then cancels the sleep.
        // The force kill covers a command that ignores SIGTERM.
        let timedOut = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    await exited.value
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    return true
                }
                let result = await group.next() ?? true
                // A real timeout must terminate the process *inside* the
                // group: the scope waits for the `exited` child, which only
                // resumes once the process is gone.
                if result {
                    terminate(process)
                }
                group.cancelAll()
                return result
            }
        } onCancel: {
            terminate(process)
        }

        // Covers both the real timeout and a cancellation that raced the
        // process exit; `terminate` is a no-op if it already stopped.
        if timedOut {
            _ = await exited.value
        }
        return timedOut
    }

    /// SIGTERM, then SIGKILL after a grace period, so a runaway command that
    /// ignores or misses the terminate signal still stops promptly.
    private nonisolated static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 2)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }
}
