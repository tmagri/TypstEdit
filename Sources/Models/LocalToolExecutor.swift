import Foundation

enum LocalToolError: LocalizedError {
    case pathEscapesScope(String)
    case noScope
    case fileNotFound(String)
    case fileTooLarge(String)
    case approvalDenied
    case pythonNotFound
    case invalidArguments(String)
    case fileNotReadYet(String, tool: String)
    case fileChangedSinceRead(String)
    case editNoMatch(String, tool: String)
    case editAmbiguous(String, count: Int)
    case sandboxUnavailable

    var errorDescription: String? {
        switch self {
        case .pathEscapesScope(let path): return "'\(path)' resolves outside the current project/notebook — refusing to touch it."
        case .noScope: return "No project or notebook is open, so there's nothing to read/write."
        case .fileNotFound(let path): return "File not found: \(path)"
        case .fileTooLarge(let path): return "'\(path)' is too large for that operation. Use edit_file for a targeted change, or read_file with offset/limit to inspect part of it."
        case .approvalDenied: return "You declined this action."
        case .pythonNotFound: return "No python3 executable was found on this Mac (checked /usr/bin, Homebrew paths)."
        case .invalidArguments(let msg): return msg
        case .fileNotReadYet(let path, let tool):
            return "'\(path)' hasn't been read in this request yet. Call read_file on it first, then retry \(tool)."
        case .fileChangedSinceRead(let path):
            return "'\(path)' changed on disk since it was last read. Read it again before editing, so you're not working from stale content."
        case .editNoMatch(let path, let tool):
            return "old_string was not found in '\(path)'. \(tool) needs an exact match, including indentation and punctuation — re-read the region and copy it verbatim."
        case .editAmbiguous(let path, let count):
            return "old_string matches \(count) places in '\(path)'. Include more surrounding context so it identifies exactly one spot, or pass replace_all: true if you really mean every occurrence."
        case .sandboxUnavailable:
            return "The Python sandbox (sandbox-exec) isn't available on this system, and sandboxing is enabled for this tool. Turn it off in Settings → AI Chat if you really want unsandboxed execution."
        }
    }
}

/// Built-in tools AI Chat always has access to (no MCP server required),
/// scoped to either the whole open project or just the current notebook —
/// never beyond it. This is the actual "harness" piece: file read/write,
/// project search, a Typst compile check, and (opt-in, approval-gated every
/// single call) a Python execution tool.
///
/// Every path-taking tool resolves through `resolvePath`, which is the sole
/// security boundary preventing the model from reading or writing anything
/// outside the active scope.
@MainActor
final class LocalToolExecutor {
    enum Scope: Equatable {
        case project(root: URL)
        case notebook(root: URL)
        case none

        var root: URL? {
            switch self {
            case .project(let r), .notebook(let r): return r
            case .none: return nil
            }
        }

        var label: String {
            switch self {
            case .project(let r): return "Project: \(r.lastPathComponent)"
            case .notebook(let r): return "Notebook: \(r.lastPathComponent)"
            case .none: return "Standalone — no file tools available"
            }
        }

        var noun: String {
            switch self {
            case .project: return "project"
            case .notebook: return "notebook"
            case .none: return "project"
            }
        }
    }

    /// The "server name" half of a tool's qualifiedName (see
    /// `MCPTool.qualifiedName`) for file/search tools scoped to the project
    /// or notebook, so the chat's dispatcher can route `project__read_file`
    /// here and `<mcp-server>__<tool>` to `MCPManager`.
    static let namespace = "project"
    /// Separate namespace for the Python tool so it can be toggled
    /// independently of (and described differently from) the file tools.
    static let pythonNamespace = "python"

    var scope: Scope = .none
    var pythonToolEnabled: Bool = false
    /// Whether `search_project` (the same RAG index AI Prompt uses) is
    /// offered to the model at all. Independent of the read/write file
    /// tools, since a user may want the AI to work only from files it reads
    /// explicitly rather than from semantic search matches.
    var ragToolEnabled: Bool = true

    /// Caps how much of a file a whole-file *rewrite* will read/diff in one
    /// call, to keep the approval UI responsive. Targeted `edit_file` changes
    /// use `maxScannableBytes` instead.
    private let maxReadableBytes = 300_000
    /// Upper bound for `read_file`/`edit_file`. Much larger than the rewrite
    /// cap because paging already limits what reaches the model, and edits are
    /// the whole point of being able to touch a document this size.
    private let maxScannableBytes = 10_000_000

    /// `read_file` returns at most this many lines when the model doesn't
    /// specify its own `limit`, and a file exceeds it — the single biggest
    /// cause of a chat blowing past the model's context window was one
    /// `read_file` call dumping an entire multi-thousand-line document into
    /// the prompt. Small files (the common case) are still returned whole,
    /// with no paging noise.
    private let defaultReadLineLimit = 400
    /// Hard ceiling on a model-requested `limit`, so a single call still
    /// can't request the whole file back in one shot.
    private let maxReadLineLimit = 2000
    /// Upper bound on `grep_project` matches per call, and the cap on how many
    /// files it will scan — enough for a normal project, bounded enough that a
    /// pathological pattern can't hang the UI.
    private static let maxGrepResults = 500
    private static let maxGrepFileCount = 5000
    private static let maxGrepFileBytes = 1_000_000

    /// One active skill's attachment folder, so `read_skill_file` can hand
    /// the model supplementary reference material (specs, templates,
    /// examples) that lives alongside `SKILL.md` without eagerly loading it
    /// into every prompt. Populated by the caller (`AIChatManager`) from
    /// whichever skills are currently enabled for the conversation.
    struct SkillAttachmentInfo {
        let skillID: String
        let folder: URL
        let files: [String]
    }
    var activeSkillAttachments: [SkillAttachmentInfo] = []

    /// Whether the Python tool runs under `sandbox-exec` (no network, no
    /// writes outside a scratch folder) — on by default, mirroring the
    /// Settings toggle. Off means "runs with your full user permissions",
    /// exactly as the old behavior.
    var pythonSandboxEnabled: Bool = true

    /// Whether `edit_file`/`write_file` automatically compile the `.typ`
    /// file they just changed and report the result alongside their own
    /// output. On by default — catching a mismatched delimiter or bad
    /// reference immediately, in the same tool call, is far more reliable
    /// than hoping the model remembers to check on its own afterwards.
    var autoValidateTypstEdits: Bool = true

    /// Files the model has read during the *current* request, keyed by
    /// standardized absolute path, valued by the file's modification date at
    /// read time. Enforces the read-before-edit invariant (`edit_file` and
    /// overwrites via `write_file`) and catches stale-content edits. Reset on
    /// every new user turn by `beginRequest()` — a fresh turn means a fresh
    /// context, and the model must look at the file again.
    private var readFiles: [String: Date] = [:]

    /// Called by the chat manager at the start of each user turn.
    func beginRequest() {
        readFiles.removeAll()
    }

    // MARK: - Tool Descriptors

    func toolDescriptors() -> [MCPTool] {
        var tools: [MCPTool] = []

        if scope.root != nil {
            tools.append(MCPTool(
                serverName: Self.namespace,
                name: "list_files",
                description: "List files under the current \(scope.noun). Optionally filter by extension.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "extensions": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional file extensions to include, e.g. [\"typ\", \"md\"]"
                        ]
                    ]
                ]
            ))
            tools.append(MCPTool(
                serverName: Self.namespace,
                name: "read_file",
                description: "Read a text file's contents, by path relative to the \(scope.noun) root. Files over \(defaultReadLineLimit) lines are returned in a window instead of all at once — the result tells you the total line count and, if truncated, which `offset` to pass next to keep reading. Prefer requesting a smaller `limit` for a quick look before pulling in the rest of a large file. A file must be read in the current request before you can edit or overwrite it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Path relative to the \(scope.noun) root"],
                        "offset": ["type": "integer", "description": "1-based line number to start reading from. Omit to start at the top of the file."],
                        "limit": ["type": "integer", "description": "Maximum number of lines to return (default \(defaultReadLineLimit), capped at \(maxReadLineLimit))."]
                    ],
                    "required": ["path"]
                ]
            ))
            tools.append(MCPTool(
                serverName: Self.namespace,
                name: "grep_project",
                description: "Search file contents for a literal string or regular expression and return matching lines with their file and line number. Case-insensitive by default. Use this for exact lookups (a symbol, a phrase, a tag) — prefer it over search_project for anything you can spell exactly, and over reading a whole file to find one line. Skips binary files, hidden folders, and build/backup directories.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pattern": ["type": "string", "description": "Text to find. Treated as a regular expression unless literal is true."],
                        "literal": ["type": "boolean", "description": "Match the pattern as plain text instead of a regex. Default false."],
                        "case_sensitive": ["type": "boolean", "description": "Default false — matching ignores case, which is usually what you want for prose and identifiers."],
                        "glob": ["type": "string", "description": "Optional filename filter, e.g. \"*.typ\" or \"chapters/**/*.typ\"."],
                        "max_results": ["type": "integer", "description": "Maximum matching lines to return (default 100, capped at \(Self.maxGrepResults))."]
                    ],
                    "required": ["pattern"]
                ]
            ))
            tools.append(MCPTool(
                serverName: Self.namespace,
                name: "edit_file",
                description: "Change part of an existing file by replacing an exact string. Much cheaper and safer than write_file for a localized change — the file must have been read in this request, and old_string must match exactly once (include enough surrounding lines to be unique) unless replace_all is true. The user reviews a diff and approves before anything is written.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Path relative to the \(scope.noun) root"],
                        "old_string": ["type": "string", "description": "The exact existing text to replace, copied verbatim from read_file (including indentation)"],
                        "new_string": ["type": "string", "description": "Replacement text. Use an empty string to delete the matched text."],
                        "replace_all": ["type": "boolean", "description": "Replace every occurrence instead of requiring exactly one. Default false."]
                    ],
                    "required": ["path", "old_string", "new_string"]
                ]
            ))
            if ragToolEnabled {
                tools.append(MCPTool(
                    serverName: Self.namespace,
                    name: "search_project",
                    description: "Semantic search across the project's indexed files (RAG) for relevant snippets.",
                    inputSchema: [
                        "type": "object",
                        "properties": ["query": ["type": "string"]],
                        "required": ["query"]
                    ]
                ))
            }
            tools.append(MCPTool(
                serverName: Self.namespace,
                name: "write_file",
                description: "Create or overwrite a text file, by path relative to the \(scope.noun) root. The user always reviews a diff and must approve before anything is written.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"]
                    ],
                    "required": ["path", "content"]
                ]
            ))
        }

        if !activeSkillAttachments.isEmpty {
            let listing = activeSkillAttachments.map { info in
                "\(info.skillID): \(info.files.joined(separator: ", "))"
            }.joined(separator: " | ")
            tools.append(MCPTool(
                serverName: Self.namespace,
                name: "read_skill_file",
                description: "Read a supplementary file attached to one of your currently enabled skills — reference material, templates, or examples that aren't preloaded into this prompt. Available right now: \(listing)",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "skill": ["type": "string", "description": "Skill id exactly as given, e.g. \"global:formal-resume-style\""],
                        "path": ["type": "string", "description": "Attachment filename as listed for that skill"]
                    ],
                    "required": ["skill", "path"]
                ]
            ))
        }

        tools.append(MCPTool(
            serverName: Self.namespace,
            name: "run_typst_check",
            description: "Checks Typst source for compiler errors — delimiter mismatches, bad syntax, unresolved references — without touching the open document. Pass `source` to check an isolated snippet (e.g. before deciding it's safe to write), or `path` to compile an existing file in place at its real location, so its own relative imports resolve. (edit_file/write_file already run this automatically on the `.typ` file they just changed and report the result alongside their own output — call this directly if you want to double-check something else, like a chunk you haven't written yet.)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "A standalone Typst snippet to compile in isolation."],
                    "path": ["type": "string", "description": "Path to an existing file in the \(scope.noun), relative to its root, to compile at its real location instead."]
                ]
            ]
        ))
        tools.append(MCPTool(
            serverName: Self.namespace,
            name: "convert_markdown_to_typst",
            description: "Converts Markdown into native Typst markup using TypstEdit's own converter — the exact same pass used when you paste Markdown into the editor. If you're unsure of Typst's own syntax for something (bold, headings, lists, links, tables, math), write it in plain Markdown and run it through here rather than hand-writing Typst delimiters from memory, then pass the result to edit_file/write_file.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "markdown": ["type": "string", "description": "Markdown text to convert, e.g. \"**bold**\", \"# Heading\", \"- a list\", \"$x^2$\"."],
                    "hybrid": ["type": "boolean", "description": "Set true only when converting content for a .note file, which mixes Markdown prose with live Typst code regions. Default false."]
                ],
                "required": ["markdown"]
            ]
        ))

        if pythonToolEnabled {
            let sandboxNote = pythonSandboxEnabled
                ? "Runs under macOS sandbox-exec: no network access, and writes are limited to a per-run scratch folder whose path is returned in the result ($TMPDIR points at it). Reading project files is allowed."
                : "Runs with your macOS user's permissions, working directory set to the current \(scope.noun) root, with no sandboxing or network isolation."
            tools.append(MCPTool(
                serverName: Self.pythonNamespace,
                name: "run",
                description: "Run a short Python 3 script and return its stdout/stderr. \(sandboxNote) The exact code is always shown to you for approval — every call — before anything runs.",
                inputSchema: [
                    "type": "object",
                    "properties": ["code": ["type": "string"]],
                    "required": ["code"]
                ]
            ))
        }

        return tools
    }

    // MARK: - Execution

    func execute(
        toolName: String,
        arguments: [String: Any],
        requestApproval: @escaping (PendingApprovalKind) async -> Bool
    ) async throws -> String {
        switch toolName {
        case "list_files": return try listFiles(arguments)
        case "read_file": return try readFile(arguments)
        case "read_skill_file": return try readSkillFile(arguments)
        case "grep_project": return try await grepProject(arguments)
        case "edit_file": return try await editFile(arguments, requestApproval: requestApproval)
        case "search_project": return await searchProject(arguments)
        case "write_file": return try await writeFile(arguments, requestApproval: requestApproval)
        case "run_typst_check": return await runTypstCheck(arguments)
        case "convert_markdown_to_typst": return convertMarkdownToTypst(arguments)
        case "run": return try await runPython(arguments, requestApproval: requestApproval)
        default: throw LocalToolError.invalidArguments("Unknown built-in tool '\(toolName)'")
        }
    }

    // MARK: - Path Resolution (Security Boundary)

    /// Resolves a model-provided relative path against the current scope
    /// root and verifies the result cannot escape it — blocks `../` style
    /// traversal, absolute-path smuggling, and symlink escapes. Every tool
    /// that touches the filesystem must go through this.
    private func resolvePath(_ relativePath: String) throws -> URL {
        guard let root = scope.root else { throw LocalToolError.noScope }
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LocalToolError.invalidArguments("path is required") }

        // `root.appendingPathComponent` rather than
        // `URL(fileURLWithPath:relativeTo:)`: the latter treats `root` as a
        // *file* when its URL has no trailing slash, which silently resolved
        // `foo.typ` to root's parent. `../` traversal is still caught below.
        let candidate = root.appendingPathComponent(cleaned).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()

        guard resolvedCandidate.path == resolvedRoot.path || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw LocalToolError.pathEscapesScope(relativePath)
        }
        return candidate
    }

    // MARK: - Tool Implementations

    private func listFiles(_ arguments: [String: Any]) throws -> String {
        guard let root = scope.root else { throw LocalToolError.noScope }
        let extensions = (arguments["extensions"] as? [String])?.map { $0.lowercased() }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "(no files found)"
        }

        let excludedDirs = Self.excludedDirectories
        var results: [String] = []
        let rootPath = root.standardizedFileURL.path

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if excludedDirs.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if let extensions, !extensions.isEmpty, !extensions.contains(url.pathExtension.lowercased()) {
                continue
            }
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
            results.append(relative)
            if results.count >= 500 { break }
        }
        return results.isEmpty ? "(no matching files)" : results.sorted().joined(separator: "\n")
    }

    private func readFile(_ arguments: [String: Any]) throws -> String {
        guard let path = arguments["path"] as? String else {
            throw LocalToolError.invalidArguments("path is required")
        }
        let url = try resolvePath(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalToolError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxScannableBytes else {
            throw LocalToolError.fileTooLarge(path)
        }
        let fullText = TextFileEncoding.decode(data).text
        readFiles[url.standardizedFileURL.path] = Self.modificationDate(of: url)
        return Self.windowed(fullText, label: path, arguments: arguments, defaultLimit: defaultReadLineLimit, maxLimit: maxReadLineLimit)
    }

    /// Slices `text` into the line range the model asked for (`offset`/
    /// `limit` in `arguments`), or returns it whole when it's short enough
    /// that paging would just be noise. Shared by `read_file` and
    /// `read_skill_file` so both page the same way.
    private static func windowed(_ text: String, label: String, arguments: [String: Any], defaultLimit: Int, maxLimit: Int) -> String {
        let hasExplicitWindow = arguments["offset"] != nil || arguments["limit"] != nil
        let lines = text.components(separatedBy: "\n")
        let totalLines = lines.count

        if !hasExplicitWindow && totalLines <= defaultLimit {
            return text
        }

        let requestedOffset = Self.intValue(arguments["offset"]) ?? 1
        let offset = max(1, requestedOffset)
        let limit = min(Self.intValue(arguments["limit"]) ?? defaultLimit, maxLimit)

        guard offset <= max(totalLines, 1) else {
            return "'\(label)' only has \(totalLines) line\(totalLines == 1 ? "" : "s"); offset \(offset) is past the end."
        }

        let startIndex = offset - 1
        let endIndex = min(totalLines, startIndex + limit)
        let slice = lines[startIndex..<endIndex].joined(separator: "\n")

        var header = "[lines \(offset)-\(endIndex) of \(totalLines) in '\(label)']\n"
        if endIndex < totalLines {
            header += "(truncated — call again with offset: \(endIndex + 1) to continue reading)\n"
        }
        return header + slice
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func readSkillFile(_ arguments: [String: Any]) throws -> String {
        guard let skillID = arguments["skill"] as? String, let path = arguments["path"] as? String else {
            throw LocalToolError.invalidArguments("skill and path are required")
        }
        guard let info = activeSkillAttachments.first(where: { $0.skillID == skillID }) else {
            throw LocalToolError.invalidArguments("'\(skillID)' isn't one of the currently enabled skills with attachments.")
        }
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, info.files.contains(cleaned) else {
            throw LocalToolError.fileNotFound(path)
        }

        // Belt-and-suspenders against traversal even though `cleaned` must
        // already match a filename we ourselves listed from the folder.
        let candidate = info.folder.appendingPathComponent(cleaned).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let resolvedFolder = info.folder.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedCandidate.path.hasPrefix(resolvedFolder.path + "/") else {
            throw LocalToolError.pathEscapesScope(path)
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw LocalToolError.fileNotFound(path)
        }

        let data = try Data(contentsOf: candidate)
        guard data.count <= maxScannableBytes else {
            throw LocalToolError.fileTooLarge(path)
        }
        let fullText = TextFileEncoding.decode(data).text
        return Self.windowed(fullText, label: "\(skillID)/\(cleaned)", arguments: arguments, defaultLimit: defaultReadLineLimit, maxLimit: maxReadLineLimit)
    }

    private func searchProject(_ arguments: [String: Any]) async -> String {
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "query is required"
        }
        let chunks = await RAGManager.shared.search(query: query, topK: 5)
        if !chunks.isEmpty {
            return chunks.map { "--- \($0.fileURL.lastPathComponent) ---\n\($0.text)" }.joined(separator: "\n\n")
        }
        // Semantic search can miss exact terms entirely (or there's no index
        // yet). Fall back to a case-insensitive literal scan so an exact
        // phrase still finds something instead of a bare "no results".
        let fallback = (try? await grepProject([
            "pattern": query,
            "literal": true,
            "max_results": 30
        ], noteIfEmpty: true)) ?? "(search unavailable)"
        return "No semantic matches. Literal (case-insensitive) results:\n\n\(fallback)"
    }

    // MARK: - Grep

    /// Searches file contents across the scope. Runs the actual scan off the
    /// main actor: a project-sized walk on the UI thread would beachball the
    /// app for the duration of the search.
    private func grepProject(_ arguments: [String: Any], noteIfEmpty: Bool = false) async throws -> String {
        guard let root = scope.root else { throw LocalToolError.noScope }
        guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
            throw LocalToolError.invalidArguments("pattern is required")
        }
        let literal = (arguments["literal"] as? Bool) ?? false
        let caseSensitive = (arguments["case_sensitive"] as? Bool) ?? false
        let glob = arguments["glob"] as? String
        let requestedMax = Self.intValue(arguments["max_results"]) ?? 100
        let maxResults = min(max(requestedMax, 1), Self.maxGrepResults)

        let regex: NSRegularExpression
        do {
            let source = literal ? NSRegularExpression.escapedPattern(for: pattern) : pattern
            regex = try NSRegularExpression(
                pattern: source,
                options: caseSensitive ? [] : [.caseInsensitive]
            )
        } catch {
            throw LocalToolError.invalidArguments("Invalid regular expression: \(error.localizedDescription)")
        }

        let globRegex = glob.flatMap { Self.globToRegex($0) }
        let rootPath = root.standardizedFileURL.path
        let excluded = Self.excludedDirectories
        let fileCap = Self.maxGrepFileCount
        let byteCap = Self.maxGrepFileBytes

        let result = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root, rootPath: rootPath, regex: regex, globRegex: globRegex,
                      excluded: excluded, fileCap: fileCap, byteCap: byteCap, maxResults: maxResults)
        }.value

        if result.lines.isEmpty {
            return noteIfEmpty ? "(no literal matches for \"\(pattern)\")" : "No matches for \"\(pattern)\"\(glob.map { " in \($0)" } ?? "")."
        }

        var output = result.lines.joined(separator: "\n")
        if result.capped {
            output += "\n… (stopped after \(result.files) files and \(result.hits) match\(result.hits == 1 ? "" : "es"); showing \(result.lines.count) line\(result.lines.count == 1 ? "" : "s"). Narrow the pattern or pass a glob to see more.)"
        }
        return output
    }

    /// Synchronous, nonisolated scan used by `grepProject` off the main
    /// actor. `NSEnumerator` can't be iterated from an async context, so the
    /// whole walk lives in one synchronous function that the detached task
    /// simply calls.
    private nonisolated static func scan(
        root: URL,
        rootPath: String,
        regex: NSRegularExpression,
        globRegex: NSRegularExpression?,
        excluded: Set<String>,
        fileCap: Int,
        byteCap: Int,
        maxResults: Int
    ) -> (lines: [String], hits: Int, files: Int, capped: Bool) {
        var lines: [String] = []
        var hits = 0
        var filesScanned = 0
        var capped = false

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], 0, 0, false) }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if excluded.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if filesScanned >= fileCap { capped = true; break }

            let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
            if let globRegex {
                let range = NSRange(location: 0, length: (relative as NSString).length)
                if globRegex.firstMatch(in: relative, options: [], range: range) == nil { continue }
            }

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > byteCap { continue }
            guard let data = try? Data(contentsOf: url), !data.contains(0) else { continue }
            filesScanned += 1

            guard let text = String(data: data, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let nsLine = line as NSString
                let matches = regex.numberOfMatches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
                guard matches > 0 else { continue }
                hits += matches
                let preview = line.count > 300 ? String(line.prefix(300)) + "…" : line
                lines.append("\(relative):\(index + 1): \(preview)")
                if lines.count >= maxResults { capped = true; break }
            }
            if lines.count >= maxResults { break }
        }
        return (lines, hits, filesScanned, capped)
    }

    private static let excludedDirectories: Set<String> = ["backups", "temp", "vectorcaches", ProjectSettingsManager.dotFolderName]

    /// Minimal glob support for `grep_project`'s `glob` argument:
    /// `**` matches across folders, `*` within a segment, `?` one character.
    private static func globToRegex(_ glob: String) -> NSRegularExpression? {
        var pattern = glob.trimmingCharacters(in: .whitespaces)
        if pattern.hasPrefix("/") {
            pattern = String(pattern.dropFirst())
        }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: "@@DOUBLE@@")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
            .replacingOccurrences(of: "@@DOUBLE@@", with: ".*")
        return try? NSRegularExpression(pattern: "^" + escaped + "$", options: [.caseInsensitive])
    }

    private func writeFile(_ arguments: [String: Any], requestApproval: @escaping (PendingApprovalKind) async -> Bool) async throws -> String {
        guard let path = arguments["path"] as? String, let content = arguments["content"] as? String else {
            throw LocalToolError.invalidArguments("path and content are required")
        }
        let url = try resolvePath(path)
        let exists = FileManager.default.fileExists(atPath: url.path)

        let oldContent: String
        if exists {
            try requireFreshRead(of: url, path: path, tool: "write_file")
            let data = try Data(contentsOf: url)
            guard data.count <= maxReadableBytes else { throw LocalToolError.fileTooLarge(path) }
            oldContent = TextFileEncoding.decode(data).text
        } else {
            oldContent = ""
        }

        if exists && oldContent == content {
            return "No changes — '\(path)' already matches the requested content."
        }

        let approved = await requestApproval(.fileWrite(relativePath: path, oldContent: oldContent, newContent: content, isNewFile: !exists))
        guard approved else { throw LocalToolError.approvalDenied }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        readFiles[url.standardizedFileURL.path] = Self.modificationDate(of: url)
        return "Wrote \(content.utf8.count) bytes to '\(path)'." + (await validationNote(for: url, path: path))
    }

    /// Advisory Typst compile check appended after `edit_file`/`write_file`
    /// touches a `.typ` file — never a hard failure. A file that's only ever
    /// `#include`d into another document (a chapter, a shared component)
    /// often can't compile standalone on its own symbols, so a failure here
    /// is a hint to double-check, not proof something's actually broken.
    private func validationNote(for url: URL, path: String) async -> String {
        guard autoValidateTypstEdits, url.pathExtension.lowercased() == "typ" else { return "" }
        guard let typstPath = TypstUpdater.shared.resolveActiveTypstPath() else { return "" }

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-autocheck-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let result = await Self.compile(typstPath: typstPath, inputURL: url, outputURL: outputURL, rootPath: scope.root?.path)

        if result.hasPrefix("Compiled successfully") {
            return "\n\n✓ Typst check: compiles cleanly."
        }
        return "\n\n⚠️ Typst check (standalone — ignore if '\(path)' is only ever #include'd into another file that supplies missing context):\n\(result)"
    }

    /// Requires that `url` was read earlier in this request (and, since this
    /// is a partial change, that it hasn't been touched on disk since).
    private func requireFreshRead(of url: URL, path: String, tool: String) throws {
        let key = url.standardizedFileURL.path
        guard let readAt = readFiles[key] else {
            throw LocalToolError.fileNotReadYet(path, tool: tool)
        }
        if let current = Self.modificationDate(of: url), current != readAt {
            throw LocalToolError.fileChangedSinceRead(path)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func editFile(_ arguments: [String: Any], requestApproval: @escaping (PendingApprovalKind) async -> Bool) async throws -> String {
        guard let path = arguments["path"] as? String,
              let oldString = arguments["old_string"] as? String,
              let newString = arguments["new_string"] as? String else {
            throw LocalToolError.invalidArguments("path, old_string, and new_string are required")
        }
        guard !oldString.isEmpty else {
            throw LocalToolError.invalidArguments("old_string can't be empty — use write_file to create or replace a whole file.")
        }
        let replaceAll = (arguments["replace_all"] as? Bool) ?? false
        let url = try resolvePath(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalToolError.fileNotFound(path)
        }
        try requireFreshRead(of: url, path: path, tool: "edit_file")

        let data = try Data(contentsOf: url)
        guard data.count <= maxScannableBytes else { throw LocalToolError.fileTooLarge(path) }
        let decoded = TextFileEncoding.decode(data)
        let usesCRLF = decoded.text.contains("\r\n")

        // Match against LF-normalized text so a model that thinks in `\n`
        // can still edit a CRLF file, then restore the file's own endings.
        let normalized = decoded.text.replacingOccurrences(of: "\r\n", with: "\n")
        let oldNormalized = oldString.replacingOccurrences(of: "\r\n", with: "\n")
        let newNormalized = newString.replacingOccurrences(of: "\r\n", with: "\n")

        let occurrences = Self.occurrenceCount(of: oldNormalized, in: normalized)
        guard occurrences > 0 else {
            throw LocalToolError.editNoMatch(path, tool: "edit_file")
        }
        guard occurrences == 1 || replaceAll else {
            throw LocalToolError.editAmbiguous(path, count: occurrences)
        }

        let updatedNormalized: String
        if replaceAll {
            updatedNormalized = normalized.replacingOccurrences(of: oldNormalized, with: newNormalized)
        } else if let range = normalized.range(of: oldNormalized) {
            updatedNormalized = normalized.replacingCharacters(in: range, with: newNormalized)
        } else {
            throw LocalToolError.editNoMatch(path, tool: "edit_file")
        }

        let approved = await requestApproval(.fileEdit(
            relativePath: path,
            oldSnippet: oldNormalized,
            newSnippet: newNormalized,
            occurrences: occurrences
        ))
        guard approved else { throw LocalToolError.approvalDenied }

        let finalText = usesCRLF ? updatedNormalized.replacingOccurrences(of: "\n", with: "\r\n") : updatedNormalized
        try Self.write(text: finalText, to: url, originalData: data, encoding: decoded.encoding)
        readFiles[url.standardizedFileURL.path] = Self.modificationDate(of: url)

        let what = occurrences == 1 ? "1 place" : "\(occurrences) places"
        let summary = "Edited '\(path)': replaced \(what) with \(newNormalized.count) character\(newNormalized.count == 1 ? "" : "s") of new text."
        return summary + (await validationNote(for: url, path: path))
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// Writes text back using the encoding the file was read with, keeping a
    /// UTF-8 BOM if the original had one.
    private static func write(text: String, to url: URL, originalData: Data, encoding: String.Encoding) throws {
        guard var data = text.data(using: encoding) else {
            throw LocalToolError.invalidArguments("Could not re-encode '\(url.lastPathComponent)' as \(encoding) — re-read it and try a narrower edit.")
        }
        if originalData.starts(with: [0xEF, 0xBB, 0xBF]), encoding == .utf8, !data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
        }
        try data.write(to: url, options: .atomic)
    }

    private func runTypstCheck(_ arguments: [String: Any]) async -> String {
        let path = arguments["path"] as? String
        let source = arguments["source"] as? String
        guard (path?.isEmpty == false) || (source?.isEmpty == false) else {
            return "Provide either 'source' (a standalone snippet) or 'path' (an existing file in the \(scope.noun))."
        }
        guard let typstPath = TypstUpdater.shared.resolveActiveTypstPath() else {
            return "Could not locate the Typst compiler."
        }

        // `path`: compile an existing file at its real location, so its own
        // relative imports/includes resolve — the accurate signal after an
        // actual edit, rather than a detached copy.
        if let path, !path.isEmpty {
            guard scope.root != nil else {
                return "No project or notebook is open, so there's no real file to check."
            }
            let url: URL
            do {
                url = try resolvePath(path)
            } catch {
                return error.localizedDescription
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return "File not found: \(path)"
            }
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-check-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: outputURL) }
            return await Self.compile(typstPath: typstPath, inputURL: url, outputURL: outputURL, rootPath: scope.root?.path)
        }

        // `source`: compile an isolated snippet that doesn't exist on disk
        // yet — for checking a chunk of Typst before deciding it's safe to
        // write anywhere.
        guard let source, !source.isEmpty else {
            return "Provide either 'source' (a standalone snippet) or 'path' (an existing file in the \(scope.noun))."
        }

        // Typst requires the input file to live inside `--root` — the system
        // temp directory isn't under the project root, so passing both used
        // to fail every isolated-snippet check with "source file must be
        // contained in project root". When there's a scope, the scratch file
        // goes under its already-hidden `.typstedit/` folder instead, which
        // also lets the snippet use root-relative imports to other project
        // files if it needs to.
        let workDir: URL
        if let root = scope.root {
            workDir = ProjectSettingsManager.dotFolderURL(for: root).appendingPathComponent("tmp-check-\(UUID().uuidString)", isDirectory: true)
        } else {
            workDir = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-check-\(UUID().uuidString)", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceURL = workDir.appendingPathComponent("check.typ")
        let outputURL = workDir.appendingPathComponent("check.pdf")
        do {
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            return "Failed to write a temporary source file: \(error.localizedDescription)"
        }

        return await Self.compile(typstPath: typstPath, inputURL: sourceURL, outputURL: outputURL, rootPath: scope.root?.path)
    }

    /// Runs `typst compile` and reports success/failure as a short string the
    /// model can act on directly. Shared by the ad-hoc snippet/real-file
    /// checks above and the automatic post-edit validation (`validationNote`).
    private static func compile(typstPath: String, inputURL: URL, outputURL: URL, rootPath: String?) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        var args = ["compile", inputURL.path, outputURL.path]
        if let rootPath {
            args += ["--root", rootPath]
        }
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return "Failed to launch Typst: \(error.localizedDescription)"
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if finishedProcess.terminationStatus == 0 {
                    continuation.resume(returning: "Compiled successfully with no errors.")
                } else {
                    continuation.resume(returning: "Compile failed:\n\(errText.isEmpty ? "(no error output)" : errText)")
                }
            }
        }
    }

    /// Runs Markdown text through TypstEdit's own Markdown→Typst converter —
    /// the same pipeline used when pasting Markdown into the editor, and when
    /// sanitizing AI Prompt output — so the model can write in Markdown (which
    /// it's typically far more reliable at) instead of hand-writing Typst
    /// delimiters it might get wrong.
    private func convertMarkdownToTypst(_ arguments: [String: Any]) -> String {
        guard let markdown = arguments["markdown"] as? String, !markdown.isEmpty else {
            return "markdown is required"
        }
        let hybrid = (arguments["hybrid"] as? Bool) ?? false
        return AICompletionService.shared.sanitizeMarkdownToTypst(markdown, isHybrid: hybrid)
    }

    private func runPython(_ arguments: [String: Any], requestApproval: @escaping (PendingApprovalKind) async -> Bool) async throws -> String {
        guard let code = arguments["code"] as? String, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidArguments("code is required")
        }

        let approved = await requestApproval(.runPython(code: code))
        guard approved else { throw LocalToolError.approvalDenied }

        guard let pythonPath = Self.resolvePython() else { throw LocalToolError.pythonNotFound }

        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-py-\(UUID().uuidString).py")
        try code.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        // Per-run scratch folder: the only place a sandboxed script can write.
        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-py-scratch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let process = Process()
        if pythonSandboxEnabled {
            guard let sandboxExec = Self.sandboxExecPath else { throw LocalToolError.sandboxUnavailable }
            process.executableURL = URL(fileURLWithPath: sandboxExec)
            // The writable path must be fully canonical: `resolvingSymlinksInPath`
            // leaves `/var` alone on macOS, but sandbox rules are matched
            // against the real `/private/var` path.
            process.arguments = ["-p", Self.sandboxProfile(writable: [Self.canonicalPath(scratchDir)]), pythonPath, scriptURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [scriptURL.path]
        }
        process.currentDirectoryURL = scope.root ?? FileManager.default.temporaryDirectory

        // Resolve to the real path: /var is a symlink to /private/var on
        // macOS, and sandbox subpath rules match the resolved path.
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = scratchDir.resolvingSymlinksInPath().path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw LocalToolError.invalidArguments("Failed to launch Python: \(error.localizedDescription)")
        }

        // Hard timeout so a hanging/runaway script can never block the chat forever.
        let timedOut = await Self.waitWithTimeout(process: process, seconds: 20)

        let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if timedOut {
            return "Python script timed out after 20 seconds and was terminated.\nPartial stdout:\n\(outText)"
        }

        var result = outText
        if !errText.isEmpty {
            result += (result.isEmpty ? "" : "\n") + "stderr:\n\(errText)"
        }
        if pythonSandboxEnabled {
            result += (result.isEmpty ? "" : "\n") + "Sandboxed run: network denied; writable scratch folder was \(scratchDir.path)."
        }
        return result.isEmpty ? "(no output)" : result
    }

    private static var sandboxExecPath: String? {
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
    private static func sandboxProfile(writable: [String]) -> String {
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
        """
    }

    private static func resolvePython() -> String? {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func waitWithTimeout(process: Process, seconds: Double) async -> Bool {
        let exited = Task<Void, Never> {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        }

        let timedOut = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await exited.value
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return true
            }
            let result = await group.next() ?? true
            group.cancelAll()
            return result
        }

        if timedOut {
            if process.isRunning { process.terminate() }
            _ = await exited.value
        }
        return timedOut
    }
}
