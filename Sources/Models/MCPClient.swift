import Foundation
import Security

enum MCPError: LocalizedError {
    case notConfigured
    case processLaunchFailed(String)
    case transportNotSupported(MCPTransportType)
    case protocolError(String)
    case toolNotFound(String)
    case serverDisabled

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "MCP server is missing a command or URL."
        case .processLaunchFailed(let msg): return "Failed to launch MCP server: \(msg)"
        case .transportNotSupported(let transport): return "\(transport.label) transport is not supported yet."
        case .protocolError(let msg): return "MCP error: \(msg)"
        case .toolNotFound(let name): return "Tool '\(name)' was not found on this server."
        case .serverDisabled: return "This MCP server is disabled."
        }
    }
}

/// One MCP tool as advertised by `tools/list`, carrying what every provider's
/// function-calling API needs: a name, a human description, and a JSON
/// Schema describing its arguments.
struct MCPTool: Identifiable {
    let serverName: String
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var id: String { "\(serverName)::\(name)" }
    /// Flat name used when talking to model providers, since most
    /// function-calling APIs want a single identifier with no namespacing.
    var qualifiedName: String { "\(serverName)__\(name)" }
}

/// Resolves `${env:VAR}` and `${keychain:key}` placeholders in a configured
/// server's `env` values, so project-scoped `mcp.json` files (which are
/// git-shareable) never need to contain literal secrets.
enum MCPEnvironmentResolver {
    static func resolve(_ raw: String) -> String {
        if raw.hasPrefix("${env:"), raw.hasSuffix("}") {
            let key = String(raw.dropFirst("${env:".count).dropLast())
            return ProcessInfo.processInfo.environment[key] ?? ""
        }
        if raw.hasPrefix("${keychain:"), raw.hasSuffix("}") {
            let key = String(raw.dropFirst("${keychain:".count).dropLast())
            return MCPKeychain.read(key: key) ?? ""
        }
        return raw
    }

    /// True for values a user likely typed a real secret into directly,
    /// rather than a placeholder — used by the Settings UI to nudge towards
    /// Keychain storage for project-scoped servers.
    static func looksLikeLiteralSecret(_ raw: String) -> Bool {
        guard !raw.hasPrefix("${") else { return false }
        let lower = raw.lowercased()
        return raw.count > 12 && (lower.contains("key") || lower.contains("token") || lower.contains("secret") || raw.range(of: "^[A-Za-z0-9_\\-]{20,}$", options: .regularExpression) != nil)
    }
}

/// Minimal Keychain wrapper so project-scoped MCP server definitions can
/// reference `${keychain:name}` instead of embedding a literal secret in a
/// file that might get committed to git.
enum MCPKeychain {
    private static let service = "com.tmagri.TypstEdit.MCP"

    static func read(key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A single JSON-RPC-over-stdio connection to one MCP server process.
///
/// Lifecycle: `start()` spawns the process and performs the `initialize`
/// handshake, `listTools()`/`callTool()` are used once running, and `stop()`
/// terminates the process. `MCPManager` owns one of these per configured
/// server and starts them lazily on first use.
@MainActor
final class MCPClient {
    let config: MCPServerConfig

    private(set) var isRunning = false
    private(set) var tools: [MCPTool] = []

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard config.transport == .stdio else {
            throw MCPError.transportNotSupported(config.transport)
        }
        guard let command = config.command?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
            throw MCPError.notConfigured
        }

        let process = Process()
        // Always shell out through `env` so bare commands (npx, uvx, a
        // binary on PATH, …) resolve the same way they would in a terminal,
        // regardless of whether `command` is absolute or not.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + config.args
        process.environment = Self.resolvedEnvironment(overrides: config.env)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.handleIncoming(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.failAllPending(MCPError.protocolError("Server process exited unexpectedly."))
            }
        }

        do {
            try process.run()
        } catch {
            throw MCPError.processLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.isRunning = true

        do {
            _ = try await sendRequest(method: "initialize", params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "TypstEdit", "version": "1.0"]
            ])
            sendNotification(method: "notifications/initialized", params: [:])
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        stdoutHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        failAllPending(MCPError.serverDisabled)
    }

    /// Augments the inherited environment with common install locations so
    /// GUI-launched processes (which don't source `~/.zshrc`) can still find
    /// `npx`, `uvx`, Homebrew binaries, etc. — the same PATH problem
    /// `TypstSettingsView.resolveCommandPath` already works around for git/cargo.
    private static func resolvedEnvironment(overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            NSString(string: "~/.nvm/versions/node/current/bin").expandingTildeInPath,
            NSString(string: "~/.cargo/bin").expandingTildeInPath,
            NSString(string: "~/.local/bin").expandingTildeInPath
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let combined = (extraPaths + existingPath.split(separator: ":").map(String.init))
        var seen = Set<String>()
        let dedupedPath = combined.filter { seen.insert($0).inserted }.joined(separator: ":")
        env["PATH"] = dedupedPath

        for (key, rawValue) in overrides {
            env[key] = MCPEnvironmentResolver.resolve(rawValue)
        }
        return env
    }

    // MARK: - Tools

    @discardableResult
    func listTools() async throws -> [MCPTool] {
        let response = try await sendRequest(method: "tools/list", params: [:])
        guard let toolsArray = response["tools"] as? [[String: Any]] else {
            self.tools = []
            return []
        }
        let serverName = config.name
        let parsed: [MCPTool] = toolsArray.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let description = entry["description"] as? String ?? ""
            let schema = entry["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
            return MCPTool(serverName: serverName, name: name, description: description, inputSchema: schema)
        }
        self.tools = parsed
        return parsed
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let response = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])

        if let isError = response["isError"] as? Bool, isError {
            throw MCPError.protocolError(Self.extractText(from: response) ?? "Tool reported an error.")
        }
        return Self.extractText(from: response) ?? "(no output)"
    }

    private static func extractText(from result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { block -> String? in
            guard let type = block["type"] as? String else { return nil }
            if type == "text" { return block["text"] as? String }
            return "[\(type) content omitted]"
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: - JSON-RPC Transport
    //
    // MCP's stdio transport is newline-delimited JSON-RPC 2.0: every message
    // is exactly one line, UTF-8, no embedded newlines (unlike LSP, there is
    // no Content-Length framing).

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isRunning, let stdinHandle else {
            throw MCPError.protocolError("Server is not running.")
        }
        let id = nextRequestID
        nextRequestID += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        // The chat's Stop cancels the task waiting on this reply. Without
        // this handler the continuation would sit until the server answers —
        // even if the tool is running a long job — so the chat looked stuck.
        // Cancel the request by id per MCP's own protocol, then resume
        // ourselves so the tool loop unwinds immediately.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[id] = continuation
                do {
                    try write(payload, to: stdinHandle)
                } catch {
                    pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: id)
            }
        }
    }

    /// Answers a cancelled request locally and tells the server to stop
    /// working on it. Called on the main actor, where `pendingRequests` lives.
    private func cancelRequest(id: Int) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        if isRunning {
            sendNotification(method: "notifications/cancelled", params: [
                "requestId": id,
                "reason": "The user stopped this task."
            ])
        }
        continuation.resume(throwing: CancellationError())
    }

    private func sendNotification(method: String, params: [String: Any]) {
        guard isRunning, let stdinHandle else { return }
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        try? write(payload, to: stdinHandle)
    }

    private func write(_ payload: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        handle.write(data)
    }

    private func handleIncoming(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
        guard let id = json["id"] as? Int else { return } // server notification — nothing to correlate
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if let error = json["error"] as? [String: Any] {
            continuation.resume(throwing: MCPError.protocolError(error["message"] as? String ?? "Unknown MCP error"))
        } else if let result = json["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(returning: [:])
        }
    }

    private func failAllPending(_ error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }
}
