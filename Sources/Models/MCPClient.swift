import Foundation
import Security

enum MCPError: LocalizedError {
    case notConfigured
    case processLaunchFailed(String)
    case protocolError(String)
    case toolNotFound(String)
    case serverDisabled
    /// A remote server answered 401/403.
    case authenticationRequired(host: String, status: Int)
    /// A remote server refused the Authorization header set in the server's
    /// own config. Browser sign-in can't replace a fixed token, so it isn't tried.
    case headerTokenRejected(host: String)
    /// A remote server over plain http on a non-local host, without `allowInsecure`.
    case insecureConnectionNotAllowed(host: String)
    /// A remote server answered with another non-success status.
    case httpStatus(Int, String)
    /// A Streamable HTTP server no longer knows the session id we sent. The
    /// manager reconnects once and retries.
    case sessionExpired
    /// The server accepted the connection but never answered the handshake.
    ///
    /// Without this the request sat on its continuation until the user hit
    /// Stop, so a server that starts but is not an MCP server looked like a
    /// chat that had hung. `detail` is whatever the process wrote to its own
    /// error stream, which is usually the whole explanation.
    case timedOut(method: String, seconds: Int, detail: String)
    /// The server needs a browser sign-in and this start was not allowed to
    /// open one. Raised while a reply is being prepared, where waiting for a
    /// person would hold the whole chat.
    case signInRequired(server: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "MCP server is missing a command or a valid http(s) URL."
        case .processLaunchFailed(let msg): return "Failed to launch MCP server: \(msg)"
        case .protocolError(let msg): return "MCP error: \(msg)"
        case .toolNotFound(let name): return "Tool '\(name)' was not found on this server."
        case .serverDisabled: return "This MCP server is disabled."
        case .authenticationRequired(let host, let status):
            // Reached when the 401 path could not complete a sign-in: the
            // server publishes no OAuth settings, or the user dismissed it.
            return "\(host) refused the connection (HTTP \(status)): it needs sign-in, and TypstEdit couldn't complete it. Use Sign in… on that server in Settings → MCP. If the service offers an API token instead, add it there as a header: Authorization: Bearer ${keychain:name}."
        case .insecureConnectionNotAllowed(let host):
            return "\(host) is reached over plain http, which isn't encrypted, so TypstEdit won't connect to it. If this is an internal server without a certificate, edit it in Settings → MCP and turn on \"Allow insecure connection\"."
        case .headerTokenRejected(let host):
            return "\(host) refused the Authorization header set for this server: the token is probably expired or wrong. Get a new token from the service and update it in the Keychain. Sign in… isn't used while the server has its own Authorization header."
        case .httpStatus(let status, let body):
            return body.isEmpty
                ? "The MCP server answered HTTP \(status)."
                : "The MCP server answered HTTP \(status): \(body)"
        case .sessionExpired: return "The MCP server ended the session."
        case .signInRequired(let server):
            return "\(server) needs you to sign in again, so its tools were left out of this reply. Use Sign in… on that server in Settings → MCP; TypstEdit does not open a browser in the middle of a reply."
        case .timedOut(let method, let seconds, let detail):
            // Say which method went unanswered, how long it waited, and quote
            // the server's own complaint when it made one. A bare "timed out"
            // sends the user looking at the wrong program.
            var message = "The MCP server did not answer \(method) within \(seconds) seconds."
            if !detail.isEmpty {
                message += " It wrote: \(detail)"
            } else {
                // The common cause, and one a config cannot show: many tools
                // ship a launcher that is not the server, and the server only
                // starts behind a subcommand (`typstedit mcp`, `server start`).
                // A launcher like that opens its own window and waits for a
                // person, which looks exactly like a hang from here.
                message += " The command started but said nothing, which usually means it is not the server itself: check whether it needs a subcommand in its arguments."
            }
            return message
        }
    }
}

// `MCPTool` lives in AISupport.swift — one definition shared by the harness,
// the local tools, skills and MCP servers.

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
        resolve(
            raw,
            environment: ProcessInfo.processInfo.environment,
            keychain: MCPSecrets.placeholderValue(for:)
        )
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

/// The macOS Keychain, for `${keychain:name}` placeholders a person set up by
/// hand.
///
/// TypstEdit's own credentials are **not** stored here any more: they live in
/// `MCPSecrets`, because an ad-hoc-signed build changes its code hash on every
/// rebuild and macOS then asks for the item again (see that type for the whole
/// story). This type is only the fallback a `mcp.json` placeholder still
/// resolves through, and `MCPSecrets` reads it at most once per key per launch.
///
/// Writes stay here for that same hand-set-up case; nothing in TypstEdit calls
/// them on its own any more.
enum MCPKeychain {
    private static let service = "com.tmagri.TypstEdit.MCP"

    /// The three answers a read can give. "No such item" and "the user said
    /// no" are different, and the import reports them differently: one is
    /// nothing to do, the other is a question that may be asked again.
    enum Probe: Equatable {
        case found(String)
        case missing
        case refused
    }

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

    /// Turns a plain `read` closure into a `Probe`, for the import path.
    ///
    /// `nil` is ambiguous — a missing item and a dismissed dialog both look
    /// like it — so existence is checked separately, with attributes only.
    /// That check returns no secret material, so it asks nothing, which is
    /// what makes "not there" distinguishable from "there, but refused".
    static func probe(
        key: String,
        read: (String) -> String?,
        exists: (String) -> Bool
    ) -> Probe {
        if let value = read(key) { return .found(value) }
        return exists(key) ? .refused : .missing
    }

    /// Whether an item for `key` exists, without reading its secret.
    static func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
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
    /// Whether the server said, in its `initialize` reply, that it will
    /// announce tool changes (`capabilities.tools.listChanged`).
    ///
    /// A server that leaves the flag out may still change its tools, but it
    /// has promised not to say so, so TypstEdit neither holds a stream open for
    /// the announcement nor expects one.
    private(set) var serverAnnouncesToolChanges = false
    /// Called when the server announced that its tool list changed.
    ///
    /// `MCPManager` uses this to re-read the catalogue, so the model's next
    /// turn declares a tool the server just added instead of calling one it
    /// just removed. Fired on the main actor, synchronously from the inbound
    /// message; the handler is responsible for not blocking on the network.
    var onToolsChanged: (@MainActor () -> Void)?

    /// Whether this client may open the browser to sign in. A silent token
    /// refresh is always allowed; only the consent page is gated. Off for the
    /// starts a chat turn makes (see `MCPManager.availableTools`).
    var allowsInteractiveSignIn = true

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
    /// The reply deadline behind each pending request, for the methods
    /// `timeoutSeconds(for:)` bounds. Cancelled when the reply arrives, so an
    /// answered request never fires a late timeout.
    private var inflightTimeouts: [Int: Task<Void, Never>] = [:]

    /// One session for every remote server (see `MCPHTTPSessions`).
    static let sharedURLSession: URLSession = MCPHTTPSessions.shared

    init(
        config: MCPServerConfig,
        urlSession: URLSession = MCPClient.sharedURLSession,
        oauthStore: MCPOAuthStore = MCPOAuthStore()
    ) {
        self.config = config
        // A server that opted out of transport security gets the session that skips
        // certificate checks. Only the default session is swapped, so a test's own session
        // is never replaced.
        self.urlSession = (config.allowInsecure && urlSession === MCPClient.sharedURLSession)
            ? MCPHTTPSessions.insecure
            : urlSession
        self.oauthStore = oauthStore
    }

    // MARK: - Lifecycle

    /// The protocol revision TypstEdit asks for. Streamable HTTP is defined from
    /// 2025-03-26 on, so it asks for a current one; stdio and legacy SSE keep
    /// asking for 2024-11-05, the revision every server of that kind speaks.
    /// The server answers with the version it will actually use.
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
            // Whether the server will tell us when its tools change. Read
            // from its capabilities rather than assumed: a server that did
            // not promise is not required to send the notification, and for
            // a remote server expecting one would mean holding a stream open
            // for a message that may never come.
            if let capabilities = result["capabilities"] as? [String: Any],
               let tools = capabilities["tools"] as? [String: Any],
               let listChanged = tools["listChanged"] as? Bool {
                serverAnnouncesToolChanges = listChanged
            }
            transport.didLearnServerCapabilities(toolsListChanged: serverAnnouncesToolChanges)
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
        if let refusal = MCPServerConfig.insecureRefusal(for: resource, allowInsecure: config.allowInsecure) {
            throw refusal
        }
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
        // Past this point only a person can help: the browser opens and the
        // flow waits up to five minutes for the consent page. That is right
        // when the user pressed Sign in…, and wrong while a chat reply is
        // being prepared, where it held the model's request behind each
        // signed-out server in turn.
        guard allowsInteractiveSignIn else { throw MCPError.signInRequired(server: config.name) }
        let endpoint = try await flow.discover(resource: resource, resourceMetadataHint: hint)
        // A hand-registered client's secret is usually a ${keychain:…}
        // placeholder; resolve it the same way headers are.
        var preset = config.oauth
        let resolvedSecret = config.oauth?.clientSecret.map { MCPEnvironmentResolver.resolve($0) }
        preset?.clientSecret = resolvedSecret
        let credentials = try await flow.signIn(
            serverName: config.name,
            resource: resource,
            endpoint: endpoint,
            existingClient: MCPOAuthClientStore().load(serverName: config.name),
            preset: preset
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
        guard config.allowInsecure else { return MCPOAuthFlow() }
        // Discovery, registration and token requests must skip certificate checks too, or
        // a self-signed server could serve tools but never complete a sign-in.
        let flow = MCPOAuthFlow(http: MCPURLSessionHTTP(session: urlSession))
        flow.allowInsecure = true
        return flow
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
            if let refusal = MCPServerConfig.insecureRefusal(for: url, allowInsecure: config.allowInsecure) {
                throw refusal
            }
            let headers = config.headers.mapValues { MCPEnvironmentResolver.resolve($0) }
            let transport: MCPTransport
            if config.transport == .http {
                transport = MCPStreamableHTTPTransport(endpoint: url, headers: headers, urlSession: urlSession)
            } else {
                transport = MCPLegacySSETransport(streamURL: url, headers: headers, urlSession: urlSession)
            }
            guard let oauth = transport as? MCPOAuthCapable else { return transport }
            // The configured header always wins over OAuth tokens (see
            // makeRequest), so on a 401 a browser sign-in could never help:
            // its token would be overridden. Report the refused header instead.
            if Self.hasAuthorizationHeader(headers) {
                let host = url.host ?? url.absoluteString
                oauth.attachOAuth(
                    accessToken: { nil },
                    signIn: { _ in throw MCPError.headerTokenRejected(host: host) }
                )
                return transport
            }
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

    /// Header names are case-insensitive in HTTP, and configs spell this one
    /// both ways.
    static func hasAuthorizationHeader(_ headers: [String: String]) -> Bool {
        headers.contains { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame && !$0.value.isEmpty }
    }

    func stop() {
        transport?.close()
        transport = nil
        isRunning = false
        for task in inflightSends.values { task.cancel() }
        inflightSends.removeAll()
        for task in inflightTimeouts.values { task.cancel() }
        inflightTimeouts.removeAll()
        failAllPending(MCPError.serverDisabled)
    }

    private func transportClosed(_ error: Error) {
        guard isRunning else { return }
        isRunning = false
        failAllPending(error)
    }

    // MARK: - Tools

    /// Reads every page of the server's tool catalogue.
    ///
    /// `tools/list` is paginated: a reply carries at most one page and names
    /// the next with `nextCursor`. Reading only the first reply silently
    /// dropped every tool after the first page, which looks to the model
    /// exactly like a server that never had them.
    ///
    /// The cursor loop is bounded twice: a cursor that comes back a second
    /// time ends it, so a server that echoes the same value cannot spin
    /// forever, and `maxToolPages` caps the round trips a single `tools/list`
    /// costs. Tools are also deduplicated by name, because a looping server
    /// would otherwise declare the same tool twice.
    @discardableResult
    func listTools() async throws -> [MCPTool] {
        var collected: [MCPTool] = []
        var seenNames = Set<String>()
        var usedCursors = Set<String>()
        var cursor: String?
        let serverName = config.name

        for _ in 0..<Self.maxToolPages {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let response = try await sendRequest(method: "tools/list", params: params)

            if let toolsArray = response["tools"] as? [[String: Any]] {
                for entry in toolsArray {
                    guard let tool = Self.tool(from: entry, serverName: serverName),
                          seenNames.insert(tool.name).inserted else { continue }
                    collected.append(tool)
                }
            }

            guard let next = response["nextCursor"] as? String,
                  !next.isEmpty,
                  usedCursors.insert(next).inserted else {
                self.tools = collected
                return collected
            }
            cursor = next
        }

        // Out of pages. Keep what was read rather than throwing away a usable
        // catalogue; the cap exists to bound a runaway server, not to fail a
        // chat because a server has thousands of tools.
        self.tools = collected
        return collected
    }

    /// How many `tools/list` round trips one catalogue read may cost.
    static let maxToolPages = 50

    /// One `tools/list` entry, or nil when it has no usable name.
    nonisolated static func tool(from entry: [String: Any], serverName: String) -> MCPTool? {
        guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
        let description = entry["description"] as? String ?? ""
        let schema = entry["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
        return MCPTool(
            serverName: serverName,
            name: name,
            description: description,
            inputSchema: schema,
            annotations: annotations(from: entry["annotations"])
        )
    }

    /// Reads a `tools/list` entry's annotations.
    ///
    /// Absent fields keep the spec's own defaults (`readOnlyHint: false`,
    /// `destructiveHint: true`), so an unannotated tool is never treated as
    /// safe to overlap. A server that sends `annotations` as something other
    /// than an object is treated the same way.
    nonisolated static func annotations(from raw: Any?) -> MCPTool.Annotations {
        guard let object = raw as? [String: Any] else { return MCPTool.Annotations() }
        var annotations = MCPTool.Annotations()
        if let readOnly = object["readOnlyHint"] as? Bool { annotations.readOnlyHint = readOnly }
        if let destructive = object["destructiveHint"] as? Bool { annotations.destructiveHint = destructive }
        return annotations
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let response = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])

        let blocks = MCPToolContent.blocks(in: response)
        if let isError = response["isError"] as? Bool, isError {
            let text = blocks.map(MCPToolContent.describe).joined(separator: "\n")
            throw MCPError.protocolError(text.isEmpty ? "Tool reported an error." : text)
        }
        var lines: [String] = []
        for block in blocks {
            lines.append(await render(block))
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? "(no output)" : text
    }

    /// Where files a tool returns are saved. A property so tests can point
    /// it at a temporary folder.
    var downloads = MCPDownloads()

    /// One block as the model sees it. A file is saved first, so the line
    /// names a path that exists; a failure says why, never "done".
    private func render(_ block: MCPToolContent.Block) async -> String {
        switch block {
        case .embedded(let contents):
            if let text = contents.text, text.count <= MCPToolContent.inlineTextLimit {
                return text
            }
            return save(contents, name: nil)
        case .link(let link):
            return await fetch(link)
        case .text, .other:
            return MCPToolContent.describe(block)
        }
    }

    private func save(_ contents: MCPToolContent.Contents, name: String?) -> String {
        if contents.blobIsInvalid {
            return MCPToolContent.invalidBlobLine(contents.uri)
        }
        let data = contents.blob ?? Data((contents.text ?? "").utf8)
        let fileName = MCPDownloads.fileName(name: name, uri: contents.uri, mimeType: contents.mimeType)
        do {
            let url = try downloads.save(data, name: fileName)
            return MCPToolContent.savedLine(url, bytes: data.count, from: contents.uri)
        } catch {
            return "[Could not save \(fileName): \(error.localizedDescription)]"
        }
    }

    /// A `resource_link` is fetched the way MCP intends, `resources/read` on
    /// this server. A plain web link the server cannot read that way is
    /// downloaded directly.
    private func fetch(_ link: MCPToolContent.Link) async -> String {
        var readError: Error?
        do {
            let result = try await sendRequest(method: "resources/read", params: ["uri": link.uri])
            let contents = MCPToolContent.contents(inReadResult: result)
            if !contents.isEmpty {
                let single = contents.count == 1
                return contents.map { entry in
                    // Text with no MIME type is the server talking ("expired,
                    // ask again"), not the file: saving it would put an error
                    // message on disk under the zip's name.
                    if entry.blob == nil, !entry.blobIsInvalid, entry.mimeType == nil, let text = entry.text {
                        return "[Reading \(link.uri) returned a message instead of a file: \(text)]"
                    }
                    return save(entry, name: single ? link.name : nil)
                }.joined(separator: "\n")
            }
        } catch {
            readError = error
        }

        if let url = URL(string: link.uri), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            do {
                return try await download(url, link: link)
            } catch {
                return "[Could not download \(link.uri): \(error.localizedDescription)]"
            }
        }
        let reason = readError?.localizedDescription ?? "the server returned no contents"
        return "[Could not read resource \(link.uri): \(reason)]"
    }

    /// Larger than this is refused: a tool result is not a way to fill the
    /// disk.
    static let maxDownloadBytes: Int64 = 1 << 30

    private func download(_ url: URL, link: MCPToolContent.Link) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        // This server's credentials go only to this server's own origin. A
        // link to anywhere else is fetched anonymously.
        if Self.isSameOrigin(url, MCPServerConfig.remoteURL(config.url)) {
            for (name, value) in config.headers {
                request.setValue(MCPEnvironmentResolver.resolve(value), forHTTPHeaderField: name)
            }
            if request.value(forHTTPHeaderField: "Authorization") == nil, let token = oauthCredentials {
                request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
            }
        }
        let (temporary, response) = try await urlSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MCPError.protocolError("HTTP \(http.statusCode)")
        }
        let bytes = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(bytes) <= Self.maxDownloadBytes else {
            throw MCPError.protocolError("the file is larger than 1 GB")
        }
        let name = MCPDownloads.fileName(
            name: link.name ?? response.suggestedFilename,
            uri: link.uri,
            mimeType: link.mimeType ?? response.mimeType
        )
        let saved = try downloads.adopt(temporary, name: name)
        return MCPToolContent.savedLine(saved, bytes: bytes, from: link.uri)
    }

    nonisolated static func isSameOrigin(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        func port(_ url: URL) -> Int? {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
        }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && port(a) == port(b)
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
                if let seconds = timeoutSeconds(for: method, transport: transport) {
                    inflightTimeouts[id] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(seconds))
                        guard !Task.isCancelled else { return }
                        self?.timeOutRequest(id: id, method: method, seconds: seconds)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: id)
            }
        }.value
    }

    /// How long a request may go unanswered before it is reported, per method.
    ///
    /// Only the *local* handshake is bounded here, and the narrow scope is the
    /// point. A stdio server that is not an MCP server at all — the
    /// `typstedit` shim without its `mcp` argument, an editor's launcher, a
    /// binary that opened a window — accepts the pipe, writes nothing, and
    /// exits never. Nothing in the protocol says so: it just sits there. Before
    /// this, the `initialize` request waited on its continuation forever, so
    /// the chat showed no progress and looked hung, and the only way out was
    /// Stop.
    ///
    /// A remote server gets no deadline here, because its first request is
    /// exactly where an interactive sign-in runs (`MCPOAuthFlow.signInTimeout`
    /// is five minutes) and a user who is reading the consent page must not be
    /// timed out for it. `tools/call` is never bounded either: a tool may
    /// legitimately run for minutes, and the chat's own Stop is the way out of
    /// one.
    func timeoutSeconds(for method: String, transport: MCPTransport) -> Int? {
        guard transport is MCPStdioTransport, method == "initialize" else { return nil }
        return handshakeTimeoutSeconds
    }

    /// The deadline for a local server's `initialize` reply. A property so a
    /// test does not have to wait the full 30 seconds to see it fire.
    var handshakeTimeoutSeconds = 30

    /// Whatever the child wrote to its error stream, for an error message.
    /// Resolved through the transport rather than stored here, because the
    /// transport is what owns the process.
    var serverErrorOutput: String {
        (transport as? MCPStdioTransport)?.recentErrorOutput ?? ""
    }

    /// Answers a cancelled request locally and tells the server to stop
    /// working on it. Called on the main actor, where `pendingRequests` lives.
    private func cancelRequest(id: Int) {
        inflightTimeouts.removeValue(forKey: id)?.cancel()
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

    /// Reports a request the server never answered.
    ///
    /// Deliberately *not* a `CancellationError`: the user did not stop
    /// anything, and the run must report a failed server rather than quietly
    /// treating it as a stopped chat. A stdio child that is still alive but
    /// silent is killed here, so it cannot linger holding a pipe for the life
    /// of the app.
    private func timeOutRequest(id: Int, method: String, seconds: Int) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        inflightSends.removeValue(forKey: id)?.cancel()
        inflightTimeouts.removeValue(forKey: id)
        let serverSaid = serverErrorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if method == "initialize" { stop() }
        continuation.resume(throwing: MCPError.timedOut(method: method, seconds: seconds, detail: serverSaid))
    }

    private func failRequest(id: Int, _ error: Error) {
        inflightTimeouts.removeValue(forKey: id)?.cancel()
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
            } else {
                handleNotification(method: method)
            }
            return
        }
        guard let id = json["id"] as? Int else { return }
        inflightTimeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if let error = json["error"] as? [String: Any] {
            continuation.resume(throwing: MCPError.protocolError(error["message"] as? String ?? "Unknown MCP error"))
        } else if let result = json["result"] as? [String: Any] {
            continuation.resume(returning: JSONObject(value: result))
        } else {
            continuation.resume(returning: JSONObject(value: [:]))
        }
    }

    /// A server notification (a message with a method and no id).
    ///
    /// Only tool-list changes matter here: they are the one way a running
    /// server can tell TypstEdit its catalogue moved. Everything else is
    /// ignored, as before — TypstEdit declared no capability a server would
    /// need to send anything else for.
    private func handleNotification(method: String) {
        switch method {
        case "notifications/tools/list_changed":
            onToolsChanged?()
        default:
            // `notifications/message` (logging), `resources/updated` and
            // friends: TypstEdit subscribes to none of them.
            break
        }
    }

    /// TypstEdit declares no client capabilities, so the only server request it
    /// can honour is `ping`. Anything else gets JSON-RPC's "method not found"
    /// rather than silence, so the server is not left waiting.
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
        for task in inflightTimeouts.values { task.cancel() }
        inflightTimeouts.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }
}
