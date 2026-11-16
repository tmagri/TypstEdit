import Foundation

/// Receives one inbound JSON-RPC message (or a JSON array of them — an HTTP
/// reply may batch) exactly as the server sent it.
typealias MCPMessageSink = @MainActor @Sendable (Data) -> Void
/// Told once that the connection is gone, with the reason.
typealias MCPCloseSink = @MainActor @Sendable (Error) -> Void

/// How `MCPClient` talks to one server. The client owns JSON-RPC — ids,
/// pending requests, cancellation, the handshake — and a transport only
/// moves bytes: it opens a connection, sends one encoded message, and feeds
/// every message the server sends into the sink.
@MainActor
protocol MCPTransport: AnyObject, Sendable {
    /// True when every reply to a request arrives *during* `send` (HTTP: the
    /// reply is the POST's own response body). The client then knows a
    /// `send` that returned without answering a request will never answer
    /// it, instead of waiting forever. False when replies arrive on a
    /// separate channel (stdio's stdout, the legacy SSE stream).
    var repliesInline: Bool { get }

    /// Signs in when a request comes back 401. `nil` for a transport that
    /// cannot (stdio, or a remote server with no OAuth): the 401 then
    /// surfaces as an error telling the user what to do.
    var signIn: (@MainActor (URL?) async throws -> Void)? { get set }

    func open(onMessage: @escaping MCPMessageSink, onClose: @escaping MCPCloseSink) async throws
    func send(_ message: Data) async throws
    /// The protocol version the `initialize` reply settled on. Streamable
    /// HTTP repeats it on every later request.
    func didNegotiate(protocolVersion: String)
    func close()
}

/// A remote transport that can carry an OAuth token and sign in when asked
/// to. Kept as a separate protocol so `MCPClient` can wire OAuth into the
/// HTTP transports without the stdio one pretending to have it.
@MainActor
protocol MCPOAuthCapable: AnyObject {
    /// True when the endpoint is remote and no usable token is stored yet.
    var requiresSignIn: Bool { get }
    /// Hands the transport both the current token (read per request, on the
    /// main actor where the store lives) and the sign-in the 401 path runs.
    func attachOAuth(
        accessToken: @escaping @MainActor () -> MCPOAuthCredentials?,
        signIn: @escaping @MainActor (URL?) async throws -> Void
    )
    /// Takes the token the client just obtained.
    func adopt(_ credentials: MCPOAuthCredentials)
}

extension MCPStreamableHTTPTransport: MCPOAuthCapable {
    var requiresSignIn: Bool { false }   // The 401 path decides, per request.

    func attachOAuth(
        accessToken: @escaping @MainActor () -> MCPOAuthCredentials?,
        signIn: @escaping @MainActor (URL?) async throws -> Void
    ) {
        self.accessToken = accessToken
        self.signIn = signIn
    }

    func adopt(_ credentials: MCPOAuthCredentials) {
        // The token closure reads the store, which `MCPClient` has already
        // updated; nothing to copy here.
    }
}

extension MCPLegacySSETransport: MCPOAuthCapable {
    var requiresSignIn: Bool { false }

    func attachOAuth(
        accessToken: @escaping @MainActor () -> MCPOAuthCredentials?,
        signIn: @escaping @MainActor (URL?) async throws -> Void
    ) {
        self.accessToken = accessToken
        self.signIn = signIn
    }

    func adopt(_ credentials: MCPOAuthCredentials) {}
}

// MARK: - stdio

/// MCP's stdio transport: a child process speaking newline-delimited
/// JSON-RPC 2.0 — every message is exactly one line, UTF-8, no embedded
/// newlines (unlike LSP, there is no Content-Length framing).
@MainActor
final class MCPStdioTransport: MCPTransport {
    let command: String
    let args: [String]
    let env: [String: String]

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var onMessage: MCPMessageSink?

    var repliesInline: Bool { false }

    /// stdio has no HTTP status to refuse with, and no browser to open.
    var signIn: (@MainActor (URL?) async throws -> Void)?

    init(command: String, args: [String], env: [String: String]) {
        self.command = command
        self.args = args
        self.env = env
    }

    func open(onMessage: @escaping MCPMessageSink, onClose: @escaping MCPCloseSink) async throws {
        self.onMessage = onMessage
        let process = Process()
        // Always shell out through `env` so bare commands (npx, uvx, a
        // binary on PATH, …) resolve the same way they would in a terminal,
        // regardless of whether `command` is absolute or not.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.environment = Self.resolvedEnvironment(overrides: env)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdinHandle = stdin.fileHandleForWriting
        stdoutHandle = stdout.fileHandleForReading

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.handleIncoming(data)
            }
        }

        process.terminationHandler = { _ in
            Task { @MainActor in
                onClose(MCPError.protocolError("Server process exited unexpectedly."))
            }
        }

        do {
            try process.run()
        } catch {
            throw MCPError.processLaunchFailed(error.localizedDescription)
        }
        self.process = process
    }

    func send(_ message: Data) async throws {
        guard let stdinHandle, process?.isRunning == true else {
            throw MCPError.protocolError("Server is not running.")
        }
        var line = message
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)
    }

    func didNegotiate(protocolVersion: String) {}

    func close() {
        stdoutHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        onMessage = nil
    }

    private func handleIncoming(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            onMessage?(lineData)
        }
    }

    /// Augments the inherited environment with common install locations so
    /// GUI-launched processes (which don't source `~/.zshrc`) can still find
    /// `npx`, `uvx`, Homebrew binaries, etc.
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
}

// MARK: - Streamable HTTP

/// The Streamable HTTP transport (MCP 2025-03-26 and later), which is what
/// remote servers serve today: every client message is a POST to one URL,
/// and the reply is that POST's body — plain JSON, or a short SSE stream when
/// the server has progress or a request of its own to send first.
///
/// The server may hand out a session id on the `initialize` reply; every
/// later request carries it back (`Mcp-Session-Id`), along with the
/// negotiated protocol version. Closing sends a best-effort DELETE so the
/// server can drop the session.
///
/// TypstEdit does not open the optional standalone GET stream for
/// unsolicited server messages: it advertises no client capabilities (no
/// sampling, no roots), so a server has nothing to push outside a reply.
@MainActor
final class MCPStreamableHTTPTransport: MCPTransport {
    let endpoint: URL
    let headers: [String: String]
    private let urlSession: URLSession
    private var sessionID: String?
    private var protocolVersion: String?
    private var onMessage: MCPMessageSink?

    /// The current access token, when signed in. Read fresh on every
    /// request, so a refresh that happened in between is picked up.
    var accessToken: (@MainActor () -> MCPOAuthCredentials?)?
    /// Signs in, given the resource-metadata URL the 401 pointed at (nil
    /// when the server did not name one).
    var signIn: (@MainActor (URL?) async throws -> Void)?

    var repliesInline: Bool { true }

    init(endpoint: URL, headers: [String: String], urlSession: URLSession) {
        self.endpoint = endpoint
        self.headers = headers
        self.urlSession = urlSession
    }

    func open(onMessage: @escaping MCPMessageSink, onClose: @escaping MCPCloseSink) async throws {
        // Nothing to connect: the first POST (`initialize`) is the handshake.
        self.onMessage = onMessage
    }

    func send(_ message: Data) async throws {
        try await send(message, maySignIn: true)
    }

    /// Sends once. On a 401 it signs in (or refreshes) and tries once more:
    /// a second 401 after a fresh token is a real refusal, not staleness.
    private func send(_ message: Data, maySignIn: Bool) async throws {
        let sink = onMessage
        let hadSession = sessionID != nil
        let outcome = try await MCPHTTP.post(
            makeRequest(message),
            session: urlSession,
            // Adopted from the headers, before any body message is
            // delivered: the `initialize` reply resumes the handshake the
            // moment it is parsed, and the very next message
            // (`notifications/initialized`) must already carry the session.
            onHeaders: { [weak self] newSession in
                await self?.adoptSession(newSession)
            },
            deliver: { data in
                await sink?(data)
            }
        )

        if outcome.isUnauthorized, maySignIn, let signIn {
            // A 401 also means the server dropped the session it was
            // holding for us, so the retry must not send the old id.
            sessionID = nil
            let hint = outcome.wwwAuthenticate.flatMap(MCPOAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate:))
            try await signIn(hint)
            try await send(message, maySignIn: false)
            return
        }
        try MCPHTTP.check(outcome, hadSession: hadSession, url: endpoint)
    }

    private func makeRequest(_ message: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = message
        // A tool call can legitimately take minutes. This is the *idle*
        // timeout between bytes, not a cap on the whole call.
        request.timeoutInterval = 1_800
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        // An explicit Authorization header in the server config wins: some
        // deployments use a fixed token rather than OAuth.
        if request.value(forHTTPHeaderField: "Authorization") == nil,
           let token = accessToken?() {
            request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func adoptSession(_ id: String?) {
        if let id, !id.isEmpty { sessionID = id }
    }

    func didNegotiate(protocolVersion: String) {
        self.protocolVersion = protocolVersion
    }

    func close() {
        onMessage = nil
        guard let sessionID else { return }
        self.sessionID = nil
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        let session = urlSession
        Task.detached {
            _ = try? await session.data(for: request)
        }
    }
}

// MARK: - Legacy HTTP+SSE

/// The HTTP+SSE transport from MCP 2024-11-05, still served by older
/// remote servers: the client holds a GET event stream open, the server's
/// first `endpoint` event names the URL to POST messages to, and every reply
/// comes back on the stream as a `message` event.
@MainActor
final class MCPLegacySSETransport: MCPTransport {
    let streamURL: URL
    let headers: [String: String]
    private let urlSession: URLSession
    private let endpointTimeout: Duration

    private var postURL: URL?
    private var endpointWaiter: CheckedContinuation<URL, Error>?
    private var streamTask: Task<Void, Never>?
    private var onMessage: MCPMessageSink?
    private var onClose: MCPCloseSink?

    /// The current access token, when signed in.
    var accessToken: (@MainActor () -> MCPOAuthCredentials?)?
    /// Signs in, given the resource-metadata URL a 401 pointed at.
    var signIn: (@MainActor (URL?) async throws -> Void)?

    var repliesInline: Bool { false }

    init(streamURL: URL, headers: [String: String], urlSession: URLSession, endpointTimeout: Duration = .seconds(30)) {
        self.streamURL = streamURL
        self.headers = headers
        self.urlSession = urlSession
        self.endpointTimeout = endpointTimeout
    }

    func open(onMessage: @escaping MCPMessageSink, onClose: @escaping MCPCloseSink) async throws {
        self.onMessage = onMessage
        self.onClose = onClose
        try await openStream()
    }

    /// Opens (or reopens, after signing in) the event stream.
    private func openStream() async throws {
        var request = URLRequest(url: streamURL)
        request.httpMethod = "GET"
        // The stream stays open for the life of the connection and may sit
        // silent between calls; only a dead connection should end it.
        request.timeoutInterval = 86_400
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "Authorization") == nil,
           let token = accessToken?() {
            request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        let session = urlSession
        let baseURL = streamURL
        streamTask = Task.detached { [weak self] in
            do {
                let (bytes, response) = try await session.bytes(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    // The stream itself can be the thing refused. Hand the
                    // 401 to the client's sign-in hook, then let the caller
                    // reopen once signed in.
                    if status == 401, let signIn = await self?.signIn {
                        let hint = http?.value(forHTTPHeaderField: "WWW-Authenticate")
                            .flatMap(MCPOAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate:))
                        try await signIn(hint)
                        await self?.reopen()
                        return
                    }
                    throw MCPHTTP.statusError(status: status, body: "", url: baseURL)
                }
                try await MCPHTTP.readEvents(bytes) { event in
                    if event.event == "endpoint" {
                        let target = URL(string: event.data.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL)?.absoluteURL
                        await self?.receivedEndpoint(target)
                    } else if event.event == "message", !event.data.isEmpty {
                        await self?.deliver(Data(event.data.utf8))
                    }
                }
                await self?.streamEnded(MCPError.protocolError("The server closed the event stream."))
            } catch {
                await self?.streamEnded(error)
            }
        }

        let timeout = endpointTimeout
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            endpointWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.failEndpointWait(MCPError.protocolError("The server did not announce its message endpoint within \(timeout.components.seconds) seconds."))
            }
        }
        postURL = url
    }

    /// After a sign-in on the stream connection: open it again with the new
    /// token. The waiter for this attempt was already resumed by the
    /// failure path, so the endpoint arrives for whoever is listening next.
    private func reopen() async {
        endpointWaiter = nil
        postURL = nil
        try? await openStream()
    }

    func send(_ message: Data) async throws {
        try await send(message, maySignIn: true)
    }

    private func send(_ message: Data, maySignIn: Bool) async throws {
        guard let target = postURL else { throw MCPError.protocolError("Server is not connected.") }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.httpBody = message
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "Authorization") == nil,
           let token = accessToken?() {
            request.setValue(token.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        // The reply belongs on the stream. A server that also (or only)
        // answers in the POST body is delivered too — the client ignores a
        // second answer to the same id.
        let sink = onMessage
        let outcome = try await MCPHTTP.post(request, session: urlSession, deliver: { data in
            await sink?(data)
        })
        if outcome.isUnauthorized, maySignIn, let signIn {
            let hint = outcome.wwwAuthenticate.flatMap(MCPOAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate:))
            try await signIn(hint)
            try await send(message, maySignIn: false)
            return
        }
        try MCPHTTP.check(outcome, hadSession: false, url: target)
    }

    func didNegotiate(protocolVersion: String) {}

    func close() {
        streamTask?.cancel()
        streamTask = nil
        onMessage = nil
        onClose = nil
        failEndpointWait(MCPError.serverDisabled)
    }

    private func receivedEndpoint(_ url: URL?) {
        guard let waiter = endpointWaiter else { return }
        endpointWaiter = nil
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            waiter.resume(returning: url)
        } else {
            waiter.resume(throwing: MCPError.protocolError("The server announced an invalid message endpoint."))
        }
    }

    private func failEndpointWait(_ error: Error) {
        guard let waiter = endpointWaiter else { return }
        endpointWaiter = nil
        waiter.resume(throwing: error)
    }

    private func deliver(_ data: Data) {
        onMessage?(data)
    }

    private func streamEnded(_ error: Error) {
        failEndpointWait(error)
        let sink = onClose
        onClose = nil
        sink?(error)
    }
}

// MARK: - HTTP plumbing

/// The network half of the HTTP transports, kept nonisolated: response bytes
/// are read off the main actor and only finished messages hop back.
enum MCPHTTP {
    struct PostOutcome: Sendable {
        var status: Int
        /// The start of an error response's body, for the message the user
        /// sees. Empty on success.
        var errorBody: String
        /// The 401's `WWW-Authenticate`, which may point at the resource
        /// metadata that says where to sign in.
        var wwwAuthenticate: String?

        var isUnauthorized: Bool { status == 401 }
    }

    /// Upper bound on a plain-JSON reply. A tool result is text the model
    /// reads; anything this size is a misbehaving server.
    static let maxJSONBody = 20 * 1024 * 1024

    static func post(
        _ request: URLRequest,
        session: URLSession,
        onHeaders: @Sendable (String?) async -> Void = { _ in },
        deliver: @Sendable (Data) async -> Void
    ) async throws -> PostOutcome {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.protocolError("The server sent a non-HTTP response.")
        }
        let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if (200..<300).contains(http.statusCode) {
            await onHeaders(sessionID)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try await collect(bytes, limit: 2_000)
            return PostOutcome(status: http.statusCode,
                               errorBody: String(decoding: body, as: UTF8.self),
                               wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate"))
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            try await readEvents(bytes) { event in
                // Streamable HTTP sends JSON-RPC as unnamed (`message`)
                // events; anything else is not for us.
                guard event.event == "message", !event.data.isEmpty else { return }
                await deliver(Data(event.data.utf8))
            }
        } else {
            let body = try await collect(bytes, limit: maxJSONBody)
            if !body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                await deliver(body)
            }
        }
        return PostOutcome(status: http.statusCode, errorBody: "")
    }

    /// Turns a non-success outcome into the error the user should read.
    static func check(_ outcome: PostOutcome, hadSession: Bool, url: URL) throws {
        guard !(200..<300).contains(outcome.status) else { return }
        // 404 on a request that carried a session id is the spec's way of
        // saying the session is gone — the caller reconnects.
        if outcome.status == 404, hadSession {
            throw MCPError.sessionExpired
        }
        throw statusError(status: outcome.status, body: outcome.errorBody, url: url)
    }

    static func statusError(status: Int, body: String, url: URL) -> MCPError {
        if status == 401 || status == 403 {
            return .authenticationRequired(host: url.host ?? url.absoluteString, status: status)
        }
        let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        return .httpStatus(status, String(snippet))
    }

    /// Reads at most `limit` bytes of a body.
    static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    /// Splits a byte stream into lines and SSE events. Lines are split by
    /// hand: `AsyncBytes.lines` drops blank lines, and a blank line is what
    /// ends an SSE event.
    static func readEvents(
        _ bytes: URLSession.AsyncBytes,
        onEvent: (SSEEvent) async -> Void
    ) async throws {
        var parser = SSEParser()
        var line: [UInt8] = []
        for try await byte in bytes {
            if byte == 0x0A {
                if line.last == 0x0D { line.removeLast() }
                if let event = parser.feed(line: String(decoding: line, as: UTF8.self)) {
                    await onEvent(event)
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty, let event = parser.feed(line: String(decoding: line, as: UTF8.self)) {
            await onEvent(event)
        }
        if let event = parser.finish() {
            await onEvent(event)
        }
    }
}

/// One server-sent event.
struct SSEEvent: Equatable, Sendable {
    /// The `event:` field; `message` when the server sent none.
    var event: String
    /// Every `data:` line of the event, joined with newlines.
    var data: String
    var id: String?
}

/// A line-at-a-time parser for the `text/event-stream` format (WHATWG HTML
/// §9.2): `field: value` lines accumulate, a blank line dispatches the event,
/// lines starting with `:` are comments (servers send them as keep-alives).
struct SSEParser {
    private var eventType = ""
    private var dataLines: [String] = []
    private var lastEventID: String?

    /// Feeds one line, without its line ending. Returns an event when the
    /// line completes one.
    mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventType = String(value)
        case "data": dataLines.append(String(value))
        case "id": lastEventID = String(value)
        default: break   // `retry` and unknown fields: nothing to do.
        }
        return nil
    }

    /// The event still being built when the stream ends. The spec discards
    /// it; a server that closes the stream right after its last `data:` line
    /// is common enough that dropping its reply would be the worse choice.
    mutating func finish() -> SSEEvent? {
        dispatch()
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = ""
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(
            event: eventType.isEmpty ? "message" : eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID
        )
    }
}
