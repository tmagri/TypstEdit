import Foundation

enum LocalToolError: LocalizedError {
    case pathEscapesScope(String)
    case noScope
    case fileNotFound(String)
    case fileTooLarge(String)
    case approvalDenied
    case pythonNotFound
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .pathEscapesScope(let path): return "'\(path)' resolves outside the current project/notebook — refusing to touch it."
        case .noScope: return "No project or notebook is open, so there's nothing to read/write."
        case .fileNotFound(let path): return "File not found: \(path)"
        case .fileTooLarge(let path): return "'\(path)' is too large for the AI to read directly."
        case .approvalDenied: return "You declined this action."
        case .pythonNotFound: return "No python3 executable was found on this Mac (checked /usr/bin, Homebrew paths)."
        case .invalidArguments(let msg): return msg
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

    /// Caps how much of a file this tool set will read/diff in one call, to
    /// keep both the model's context window and the approval UI responsive.
    private let maxReadableBytes = 300_000

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
                description: "Read a text file's contents, by path relative to the \(scope.noun) root.",
                inputSchema: [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Path relative to the \(scope.noun) root"]],
                    "required": ["path"]
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

        tools.append(MCPTool(
            serverName: Self.namespace,
            name: "run_typst_check",
            description: "Compile the given Typst source in an isolated temp directory and report any compiler errors — does not touch the open document.",
            inputSchema: [
                "type": "object",
                "properties": ["source": ["type": "string"]],
                "required": ["source"]
            ]
        ))

        if pythonToolEnabled {
            tools.append(MCPTool(
                serverName: Self.pythonNamespace,
                name: "run",
                description: "Run a short Python 3 script and return its stdout/stderr. Executes with your macOS user's permissions, working directory set to the current \(scope.noun) root, with no additional sandboxing or network isolation. The exact code is always shown to you for approval — every call — before anything runs.",
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
        case "search_project": return await searchProject(arguments)
        case "write_file": return try await writeFile(arguments, requestApproval: requestApproval)
        case "run_typst_check": return await runTypstCheck(arguments)
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

        let candidate = URL(fileURLWithPath: cleaned, relativeTo: root).standardizedFileURL
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

        let excludedDirs: Set<String> = ["backups", "temp", "vectorcaches", ProjectSettingsManager.dotFolderName]
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
        guard data.count <= maxReadableBytes else {
            throw LocalToolError.fileTooLarge(path)
        }
        return TextFileEncoding.decode(data).text
    }

    private func searchProject(_ arguments: [String: Any]) async -> String {
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "query is required"
        }
        let chunks = await RAGManager.shared.search(query: query, topK: 5)
        guard !chunks.isEmpty else { return "No relevant results found." }
        return chunks.map { "--- \($0.fileURL.lastPathComponent) ---\n\($0.text)" }.joined(separator: "\n\n")
    }

    private func writeFile(_ arguments: [String: Any], requestApproval: @escaping (PendingApprovalKind) async -> Bool) async throws -> String {
        guard let path = arguments["path"] as? String, let content = arguments["content"] as? String else {
            throw LocalToolError.invalidArguments("path and content are required")
        }
        let url = try resolvePath(path)
        let exists = FileManager.default.fileExists(atPath: url.path)

        let oldContent: String
        if exists {
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
        return "Wrote \(content.utf8.count) bytes to '\(path)'."
    }

    private func runTypstCheck(_ arguments: [String: Any]) async -> String {
        guard let source = arguments["source"] as? String, !source.isEmpty else {
            return "source is required"
        }
        guard let typstPath = TypstUpdater.shared.resolveActiveTypstPath() else {
            return "Could not locate the Typst compiler."
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceURL = workDir.appendingPathComponent("check.typ")
        let outputURL = workDir.appendingPathComponent("check.pdf")
        do {
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            return "Failed to write a temporary source file: \(error.localizedDescription)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        var args = ["compile", sourceURL.path, outputURL.path]
        if let root = scope.root {
            args += ["--root", root.path]
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = scope.root ?? FileManager.default.temporaryDirectory

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
        return result.isEmpty ? "(no output)" : result
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
