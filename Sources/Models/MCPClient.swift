import Foundation
import Security

enum MCPError: LocalizedError {
    case notConfigured
    case processLaunchFailed(String)
    case transportNotSupported(MCPTransportType)
    case protocolError(String)
    case toolNotFound(String)
    case serverDisabled
    /// A remote server answered 401/403.
    case authenticationRequired(host: String, status: Int)
    /// A remote server answered with another non-success status.
    case httpStatus(Int, String)
    /// A Streamable HTTP server no longer knows the session id we sent. The
    /// manager reconnects once and retries.
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "MCP server is missing a command or a valid http(s) URL."
        case .processLaunchFailed(let msg): return "Failed to launch MCP server: \(msg)"
        case .transportNotSupported(let transport): return "\(transport.label) transport is not supported."
        case .protocolError(let msg): return "MCP error: \(msg)"
        case .toolNotFound(let name): return "Tool '\(name)' was not found on this server."
        case .serverDisabled: return "This MCP server is disabled."
        case .authenticationRequired(let host, let status):
            // Reached when the 401 path could not complete a sign-in: the
            // server publishes no OAuth settings, or the user dismissed it.
            return "\(host) refused the connection (HTTP \(status)): it needs sign-in, and TypstEdit couldn't complete it. Use Sign in… on that server in Settings → MCP. If the service offers an API token instead, add it there as a header: Authorization: Bearer ${keychain:name}."
        case .httpStatus(let status, let body):
            return body.isEmpty
                ? "The MCP server answered HTTP \(status)."
                : "The MCP server answered HTTP \(status): \(body)"
        case .sessionExpired: return "The MCP server ended the session."
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
/// server's `env` and `headers` values, so `mcp.json` files (which are
/// git-shareable) never need to contain literal secrets.
///
/// A placeholder may be the whole value or sit inside it — a header is
/// usually `Bearer ${keychain:github}`, not the bare token. opencode's
/// `{env:VAR}` spelling (no `$`) is read too, so its configs paste in.
enum MCPEnvironmentResolver {
    private static let placeholder = try! NSRegularExpression(pattern: #"\$?\{(env|keychain):([^}]+)\}"#)

    static func resolve(_ raw: String) -> String {
        resolve(raw, environment: ProcessInfo.processInfo.environment, keychain: MCPKeychain.read(key:))
    }

    /// The substitution itself, with its lookups injectable for tests. A
    /// missing variable or Keychain item resolves to an empty string, the
    /// same as before.
    static func resolve(
        _ raw: String,
        environment: [String: String],
        keychain: (String) -> String?
    ) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let matches = placeholder.matches(in: raw, range: range)
        guard !matches.isEmpty else { return raw }
        var result = ""
        var cursor = raw.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: raw),
                  let kindRange = Range(match.range(at: 1), in: raw),
                  let keyRange = Range(match.range(at: 2), in: raw) else { continue }
            result += raw[cursor..<whole.lowerBound]
            let key = String(raw[keyRange])
            result += raw[kindRange] == "env" ? (environment[key] ?? "") : (keychain(key) ?? "")
            cursor = whole.upperBound
        }
        result += raw[cursor...]
        return result
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

/// One JSON-RPC 2.0 connection to one MCP server, over whichever transport
/// its config names: a local process (stdio), Streamable HTTP, or the legacy
/// HTTP+SSE transport.
///
/// Lifecycle: `start()` connects and performs the `initialize` handshake,
/// `listTools()`/`callTool()` are used once running, and `stop()` closes the
/// connection. `MCPManager` owns one of these per configured server and
/// starts them lazily on first use.
@MainActor
final class MCPClient {
    let config: MCPServerConfig

    private(set) var isRunning = false
    private(set) var tools: [MCPTool] = []
    /// The guidance the server sent in its `initialize` response — usage notes
    /// the author wrote for the model ("call search first, then fetch"). The
    /// handshake used to discard it. Kept so the chat can put it in the system
    /// prompt instead of the model learning the server's quirks by failing.
    private(set) var instructions: String?
    /// The protocol version the handshake settled on.
    private(set) var protocolVersion: String?

    private let urlSession: URLSession
    /// Tokens for this server, in the Keychain.
    let oauthStore: MCPOAuthStore
    private var transport: MCPTransport?
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONObject, Error>] = [:]

    /// A parsed JSON-RPC `result`. `JSONSerialization` output is immutable
    /// Foundation storage, and both the resuming and the awaiting side of a
    /// pending request run on the main actor — the box only tells the
    /// region checker what it cannot see through `[String: Any]`.
    struct JSONObject: @unchecked Sendable {
        let value: [String: Any]
    }
    /// The send behind each pending request, so a Stop can abort an HTTP
    /// request that is still streaming its reply.
    private var inflightSends: [Int: Task<Void, Never>] = [:]

    /// One session for every remote server (see `MCPHTTPSessions`).
    static let sharedURLSession: URLSession = MCPHTTPSessions.shared

    init(
        config: MCPServerConfig,
        urlSession: URLSession = MCPClient.sharedURLSession,
        oauthStore: MCPOAuthStore = MCPOAuthStore()
    ) {
        self.config = config
        self.urlSession = urlSession
        self.oauthStore = oauthStore
    }

    // MARK: - Lifecycle

    /// The protocol revision TypstEdit asks for. Streamable HTTP is defined
    /// from 2025-03-26 on, so it asks for a current one; stdio and legacy SSE
    /// keep asking for 2024-11-05, the revision every server of that kind
    /// speaks. The server answers with the version it will actually use.
    static func requestedProtocolVersion(for transport: MCPTransportType) -> String {
        transport == .http ? "2025-06-18" : "2024-11-05"
    }

    func start() async throws {
        let transport = try makeTransport()
        self.transport = transport
        // Sign in before the handshake when there is no usable token, and
        // refresh a token that is about to lapse: the handshake's first
        // request would otherwise come back 401 and cost a round trip (and a
        // half-open session) to discover what we already knew.
        if let oauth = transport as? MCPOAuthCapable, oauth.requiresSignIn {
            try await signIn(oauth, hint: nil)
        }
        do {
            try await transport.open(
                onMessage: { [weak self] data in self?.handleMessageData(data) },
                onClose: { [weak self] error in self?.transportClosed(error) }
            )
        } catch {
            transport.close()
            self.transport = nil
            throw error
        }
        isRunning = true

        do {
            let requested = Self.requestedProtocolVersion(for: config.transport)
            let result = try await sendRequest(method: "initialize", params: [
                "protocolVersion": requested,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "TypstEdit", "version": "1.0"]
            ])
            let negotiated = (result["protocolVersion"] as? String) ?? requested
            protocolVersion = negotiated
            transport.didNegotiate(protocolVersion: negotiated)
            // Usage guidance the server's author wrote for the model. It was
            // discarded here before, which left the model to discover each
            // server's quirks by failing a call.
            if let text = (result["instructions"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                self.instructions = text
            }
            // Awaited, not fired and forgotten: over HTTP each message is its
            // own request, and `tools/list` must not overtake this one.
            try await sendNotification(method: "notifications/initialized", params: [:])
        } catch {
            stop()
            throw error
        }
    }

    // MARK: - OAuth

    /// The stored credentials for this server, if it was signed in.
    var oauthCredentials: MCPOAuthCredentials? {
        guard config.transport.isRemote else { return nil }
        return oauthStore.load(serverName: config.name)
    }

    /// Whether this server is signed in with usable (or renewable) tokens.
    var isSignedIn: Bool { oauthCredentials != nil }

    /// Runs the interactive sign-in, or refreshes when that is enough.
    ///
    /// A stored token with a refresh token reconnects silently; only a
    /// server with no credentials, or a refresh the server refused, sends
    /// the user to the browser.
    @discardableResult
    func signInInteractively(hint: URL? = nil) async throws -> MCPOAuthCredentials {
        guard let resource = MCPServerConfig.remoteURL(config.url) else { throw MCPError.notConfigured }
        let flow = makeFlow()
        if let stored = oauthStore.load(serverName: config.name) {
            if !stored.isExpiring(), stored.expiresAt != nil { return stored }
            if stored.refreshToken?.isEmpty == false {
                do {
                    let refreshed = try await flow.refresh(stored)
                    oauthStore.save(refreshed, serverName: config.name)
                    return refreshed
                } catch {
                    // A refused refresh (revoked, expired grant) is the one
                    // case that needs a person; fall through to the browser.
                    oauthStore.delete(serverName: config.name)
                    guard case MCPOAuthError.refreshFailed = error else { throw error }
                }
            }
        }
        let endpoint = try await flow.discover(resource: resource, resourceMetadataHint: hint)
        let credentials = try await flow.signIn(
            serverName: config.name,
            resource: resource,
            endpoint: endpoint,
            existingClient: MCPOAuthClientStore().load(serverName: config.name)
        )
        oauthStore.save(credentials, serverName: config.name)
        MCPOAuthClientStore().save(credentials.client, serverName: config.name)
        return credentials
    }

    func signOut() {
        oauthStore.delete(serverName: config.name)
        stop()
    }

    /// The transport's 401 path: refresh or sign in, then the transport
    /// retries its request with the new token.
    private func signIn(_ oauth: MCPOAuthCapable, hint: URL?) async throws {
        let credentials = try await signInInteractively(hint: hint)
        oauth.adopt(credentials)
    }

    private func makeFlow() -> MCPOAuthFlow {
        MCPOAuthFlow()
    }

    private func makeTransport() throws -> MCPTransport {
        switch config.transport {
        case .stdio:
            guard let command = config.command?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
                throw MCPError.notConfigured
            }
            return MCPStdioTransport(command: command, args: config.args, env: config.env)
        case .http, .sse:
            guard let url = MCPServerConfig.remoteURL(config.url) else {
                throw MCPError.notConfigured
            }
            let headers = config.headers.mapValues { MCPEnvironmentResolver.resolve($0) }
            let transport: MCPTransport
            if config.transport == .http {
                transport = MCPStreamableHTTPTransport(endpoint: url, headers: headers, urlSession: urlSession)
            } else {
                transport = MCPLegacySSETransport(streamURL: url, headers: headers, urlSession: urlSession)
            }
            guard let oauth = transport as? MCPOAuthCapable else { return transport }
            oauth.attachOAuth(
                accessToken: { [weak self] in self?.oauthCredentials },
                signIn: { [weak self, weak oauth] hint in
                    guard let self, let oauth else { throw MCPOAuthError.cancelled }
                    try await self.signIn(oauth, hint: hint)
                }
            )
            return transport
        }
    }

    func stop() {
        transport?.close()
        transport = nil
        isRunning = false
        for task in inflightSends.values { task.cancel() }
        inflightSends.removeAll()
        failAllPending(MCPError.serverDisabled)
    }

    private func transportClosed(_ error: Error) {
        guard isRunning else { return }
        isRunning = false
        failAllPending(error)
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

    // MARK: - JSON-RPC

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isRunning, let transport else {
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
        let message = try JSONSerialization.data(withJSONObject: payload)

        // The chat's Stop cancels the task waiting on this reply. Without
        // this handler the continuation would sit until the server answers —
        // even if the tool is running a long job — so the chat looked stuck.
        // Cancel the request by id per MCP's own protocol, then resume
        // ourselves so the tool loop unwinds immediately.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONObject, Error>) in
                pendingRequests[id] = continuation
                inflightSends[id] = Task { [weak self] in
                    do {
                        try await transport.send(message)
                        // An HTTP reply is the POST's body: once the send has
                        // returned, an unanswered request will stay that way.
                        if transport.repliesInline {
                            self?.failRequest(id: id, MCPError.protocolError("The server finished its reply without answering \(method)."))
                        }
                    } catch {
                        self?.failRequest(id: id, error)
                    }
                    self?.inflightSends[id] = nil
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: id)
            }
        }.value
    }

    /// Answers a cancelled request locally and tells the server to stop
    /// working on it. Called on the main actor, where `pendingRequests` lives.
    private func cancelRequest(id: Int) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        inflightSends.removeValue(forKey: id)?.cancel()
        if isRunning {
            postInBackground(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": [
                "requestId": id,
                "reason": "The user stopped this task."
            ]])
        }
        continuation.resume(throwing: CancellationError())
    }

    private func failRequest(id: Int, _ error: Error) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        guard isRunning, let transport else { return }
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        try await transport.send(try JSONSerialization.data(withJSONObject: payload))
    }

    /// Sends a message nobody waits on: a cancellation, or the answer to a
    /// request the server made.
    private func postInBackground(_ payload: [String: Any]) {
        guard let transport, let message = try? JSONSerialization.data(withJSONObject: payload) else { return }
        Task { try? await transport.send(message) }
    }

    /// One inbound message, or a JSON array of them (an HTTP reply may batch).
    private func handleMessageData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return }
        if let batch = json as? [[String: Any]] {
            batch.forEach(handleMessage)
        } else if let message = json as? [String: Any] {
            handleMessage(message)
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        // A message with a method is the server talking first — a request
        // (it has an id) or a notification (no id). It must never be read as
        // a reply: before this check, a server `ping` with id 1 answered our
        // own request 1 with an empty result.
        if let method = json["method"] as? String {
            if let requestID = json["id"] {
                answerServerRequest(id: requestID, method: method)
            }
            return
        }
        guard let id = json["id"] as? Int else { return }
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if let error = json["error"] as? [String: Any] {
            continuation.resume(throwing: MCPError.protocolError(error["message"] as? String ?? "Unknown MCP error"))
        } else if let result = json["result"] as? [String: Any] {
            continuation.resume(returning: JSONObject(value: result))
        } else {
            continuation.resume(returning: JSONObject(value: [:]))
        }
    }

    /// TypstEdit declares no client capabilities, so the only server request
    /// it can honour is `ping`. Anything else gets JSON-RPC's "method not
    /// found" rather than silence, so the server is not left waiting.
    private func answerServerRequest(id: Any, method: String) {
        if method == "ping" {
            postInBackground(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        } else {
            postInBackground(["jsonrpc": "2.0", "id": id, "error": [
                "code": -32601,
                "message": "TypstEdit does not support \(method)."
            ]])
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
