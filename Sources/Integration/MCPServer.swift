import Foundation

/// Writes protocol messages to the real stdout. In headless mode fd 1 is
/// redirected to stderr (see `TypstEditCLI.reserveStdout`) so stray `print()`
/// calls in shared code can never corrupt the JSON-RPC stream.
final class ProtocolOutput: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(fileDescriptor: Int32) {
        handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
    }

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        handle.write(Data(text.utf8))
    }

    func writeLine(_ text: String) { write(text + "\n") }
}

/// Model Context Protocol server exposing TypstEdit's compiler to AI agents
/// (Claude, Codex, Cursor, opencode, …). Start it with `TypstEdit mcp`; the
/// agent talks newline-delimited JSON-RPC 2.0 over stdin/stdout.
@MainActor
final class TypstEditMCPServer {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let output: ProtocolOutput
    private let service = AgentCompileService.shared

    init(output: ProtocolOutput) {
        self.output = output
    }

    /// Reads requests from stdin on a background thread until EOF, then exits.
    nonisolated func start() -> Never {
        let thread = Thread { [self] in
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                Task { @MainActor in await self.handle(trimmed) }
            }
            // stdin closed: the client went away. Let in-flight replies drain briefly.
            Thread.sleep(forTimeInterval: 0.2)
            exit(0)
        }
        thread.start()
        dispatchMain()
    }

    // MARK: - JSON-RPC

    func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            send(error: -32700, message: "Parse error", id: NSNull())
            return
        }
        // Batches (2025-03-26) are handled element by element.
        if let batch = json as? [[String: Any]] {
            for message in batch { await handle(message: message) }
            return
        }
        guard let message = json as? [String: Any] else {
            send(error: -32600, message: "Invalid request", id: NSNull())
            return
        }
        await handle(message: message)
    }

    private func handle(message: [String: Any]) async {
        guard let method = message["method"] as? String else { return } // a response to us; ignore
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) never get a reply.
        guard let id else { return }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            send(result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "typstedit", "title": "TypstEdit", "version": TypstEditCLI.appVersion],
                "instructions": Self.instructions
            ], id: id)
        case "ping":
            send(result: [:], id: id)
        case "tools/list":
            send(result: ["tools": Self.toolDefinitions], id: id)
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            send(result: await callTool(name, arguments), id: id)
        case "resources/list":
            send(result: ["resources": []], id: id)
        case "resources/templates/list":
            send(result: ["resourceTemplates": []], id: id)
        case "prompts/list":
            send(result: ["prompts": []], id: id)
        default:
            send(error: -32601, message: "Method not found: \(method)", id: id)
        }
    }

    private func send(result: [String: Any], id: Any) {
        sendJSON(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(error code: Int, message: String, id: Any) {
        sendJSON(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return }
        output.writeLine(text)
    }

    // MARK: - Tools

    private func callTool(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "typst_compile":
            return await compileTool(arguments, checkOnly: false)
        case "typst_check":
            return await compileTool(arguments, checkOnly: true)
        case "typst_render_preview":
            return await previewTool(arguments)
        case "typstedit_open":
            return openTool(arguments)
        case "typstedit_info":
            let info = await TypstEditCLI.infoDictionary()
            return Self.toolResult(text: TypstEditCLI.describe(info: info), structured: info)
        default:
            return Self.toolResult(text: "Unknown tool '\(name)'. Call tools/list for the available tools.", isError: true)
        }
    }

    private func request(from arguments: [String: Any]) -> AgentCompileRequest {
        var request = AgentCompileRequest()
        request.inputPath = arguments["path"] as? String
        request.source = arguments["source"] as? String
        request.sourceKind = arguments["source_format"] as? String ?? "typ"
        request.outputPath = arguments["output"] as? String
        request.format = (arguments["format"] as? String).flatMap { AgentOutputFormat(rawValue: $0.lowercased()) }
        request.root = arguments["root"] as? String
        request.pages = (arguments["pages"] as? String) ?? (arguments["pages"] as? Int).map(String.init)
        request.ppi = arguments["ppi"] as? Int
        request.fontPaths = arguments["font_paths"] as? [String] ?? []
        if let inputs = arguments["inputs"] as? [String: Any] {
            request.inputs = inputs.mapValues { "\($0)" }
        }
        // Agents may send relative paths; without a cwd of their own, the home folder is the only sane base.
        if request.inputPath.map({ !$0.hasPrefix("/") && !$0.hasPrefix("~") }) == true {
            request.workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        }
        return request
    }

    private func compileTool(_ arguments: [String: Any], checkOnly: Bool) async -> [String: Any] {
        if let problem = Self.validateInput(arguments) {
            return Self.toolResult(text: problem, isError: true)
        }
        var request = request(from: arguments)
        request.checkOnly = checkOnly
        let result = await service.compile(request)
        return Self.toolResult(text: result.summary, structured: Self.dictionary(from: result), isError: !result.success)
    }

    /// Renders pages to PNG and returns them inline so multimodal agents can *see* the document.
    private func previewTool(_ arguments: [String: Any]) async -> [String: Any] {
        if let problem = Self.validateInput(arguments) {
            return Self.toolResult(text: problem, isError: true)
        }
        var request = request(from: arguments)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-preview-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        request.format = .png
        request.outputPath = scratch.appendingPathComponent("page-{p}.png").path
        request.pages = (arguments["pages"] as? String) ?? (arguments["page"] as? Int).map(String.init) ?? "1"
        request.ppi = min(max(arguments["ppi"] as? Int ?? 110, 36), 300)

        var result = await service.compile(request)
        let maxPages = 4
        var content: [[String: Any]] = []
        for path in result.outputs.prefix(maxPages) {
            if let data = FileManager.default.contents(atPath: path) {
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
            }
        }
        if result.outputs.count > maxPages {
            result.notes.append("Only the first \(maxPages) of \(result.outputs.count) pages are shown; use `pages` to pick others.")
        }
        result.outputs = [] // scratch files are deleted; don't advertise their paths
        content.insert(["type": "text", "text": result.summary], at: 0)
        return ["content": content, "isError": !result.success]
    }

    private func openTool(_ arguments: [String: Any]) -> [String: Any] {
        guard let path = arguments["path"] as? String, !path.isEmpty else {
            return Self.toolResult(text: "`path` is required.", isError: true)
        }
        let url = AgentCompileService.resolve(path, relativeTo: FileManager.default.homeDirectoryForCurrentUser)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self.toolResult(text: "File not found: \(url.path)", isError: true)
        }
        let (ok, message) = TypstEditCLI.openInApp([url])
        return Self.toolResult(text: ok ? "Opened \(url.path) in TypstEdit." : message, isError: !ok)
    }

    // MARK: - Helpers

    private static func validateInput(_ arguments: [String: Any]) -> String? {
        let path = (arguments["path"] as? String)?.isEmpty == false
        let source = arguments["source"] is String
        if path && source { return "Pass either `path` or `source`, not both." }
        if !path && !source { return "Pass `path` (a .typ/.md/.note file) or `source` (inline Typst code)." }
        return nil
    }

    private static func toolResult(text: String, structured: [String: Any]? = nil, isError: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if let structured { result["structuredContent"] = structured }
        return result
    }

    private static func dictionary(from result: AgentCompileResult) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(result) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static let instructions = """
    TypstEdit is a native macOS editor for Typst. Use these tools to compile Typst (.typ), \
    Markdown (.md) and TypstEdit Note (.note) documents with the same compiler and pipeline \
    as the app. Use typst_check after editing a document to get errors with file, line and \
    column; typst_compile to write PDF/PNG/SVG; typst_render_preview to look at pages as \
    images; typstedit_open to show a file to the user in the editor. Paths should be absolute.
    """

    private static let inputProperties: [String: Any] = [
        "path": ["type": "string", "description": "Absolute path to a .typ, .md or .note file. Use this OR `source`."],
        "source": ["type": "string", "description": "Inline document text to compile instead of a file."],
        "source_format": ["type": "string", "enum": ["typ", "md", "note"], "description": "Syntax of `source` (default: typ)."],
        "root": ["type": "string", "description": "Project root for absolute paths and imports. Defaults to the file's folder. With `source`, relative paths resolve inside this folder."],
        "inputs": ["type": "object", "additionalProperties": ["type": "string"], "description": "Values for `sys.inputs`."],
        "font_paths": ["type": "array", "items": ["type": "string"], "description": "Extra font folders."]
    ]

    static var toolDefinitions: [[String: Any]] {
        let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]
        return [
            [
                "name": "typst_check",
                "title": "Check Typst document",
                "description": "Compiles a document without keeping output and returns errors and warnings (file, line, column, message, hints). Use after every edit.",
                "inputSchema": ["type": "object", "properties": inputProperties],
                "annotations": readOnly
            ],
            [
                "name": "typst_compile",
                "title": "Compile Typst document",
                "description": "Compiles a document to PDF (default), PNG or SVG with TypstEdit's compiler. Returns the written file paths and diagnostics. PNG/SVG write one file per page (name-1.png, name-2.png…).",
                "inputSchema": ["type": "object", "properties": inputProperties.merging([
                    "output": ["type": "string", "description": "Output file or folder. Defaults to the input's folder and name with the format's extension."],
                    "format": ["type": "string", "enum": AgentOutputFormat.allCases.map(\.rawValue), "description": "Output format (default: from `output` extension, else pdf)."],
                    "pages": ["type": "string", "description": "Pages to export, e.g. \"1\" or \"2,4-6\"."],
                    "ppi": ["type": "integer", "description": "Pixels per inch for PNG (default 144)."]
                ]) { $1 }],
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]
            ],
            [
                "name": "typst_render_preview",
                "title": "Render page preview",
                "description": "Renders pages of a document as PNG images and returns them inline, so you can visually verify layout. Up to 4 pages per call.",
                "inputSchema": ["type": "object", "properties": inputProperties.merging([
                    "page": ["type": "integer", "description": "Page to render (default 1)."],
                    "pages": ["type": "string", "description": "Page selection instead of `page`, e.g. \"1-3\"."],
                    "ppi": ["type": "integer", "description": "Resolution, 36–300 (default 110)."]
                ]) { $1 }],
                "annotations": readOnly
            ],
            [
                "name": "typstedit_open",
                "title": "Open in TypstEdit",
                "description": "Opens a file in the TypstEdit app so the user can see it with live preview.",
                "inputSchema": ["type": "object", "properties": ["path": ["type": "string", "description": "Absolute path of the file to open."]], "required": ["path"]],
                "annotations": ["readOnlyHint": true, "openWorldHint": false]
            ],
            [
                "name": "typstedit_info",
                "title": "TypstEdit info",
                "description": "Returns the TypstEdit version, the active Typst compiler path and version, and supported formats.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": readOnly
            ]
        ]
    }
}
