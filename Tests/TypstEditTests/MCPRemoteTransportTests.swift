import XCTest
@testable import TypstEdit

// MARK: - A fake remote MCP server

/// A `URLProtocol` that plays an MCP server, so the HTTP transports run
/// end to end — real `URLSession`, real byte streams — without a network.
///
/// Streamable HTTP: every POST is answered by `respond`. Legacy SSE: a GET
/// opens a stream that stays open; each POST to the announced endpoint gets
/// 202, and its JSON-RPC reply is pushed down that stream.
final class FakeMCPServer: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
    }

    /// Everything the fake was sent, in order, for assertions.
    struct Received {
        var method: String
        var url: URL
        var headers: [String: String]
        var json: [String: Any]?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _received: [Received] = []
    nonisolated(unsafe) private static var _respond: ((Received) -> Reply)?
    /// Legacy SSE: the open GET stream to push replies into.
    nonisolated(unsafe) private static var streamClient: (URLProtocol, URLProtocolClient)?
    nonisolated(unsafe) private static var legacyMode = false

    static var received: [Received] { lock.withLock { _received } }

    static func reset(respond: @escaping (Received) -> Reply) {
        lock.withLock {
            _received = []
            _respond = respond
            streamClient = nil
            legacyMode = false
        }
    }

    /// Switches the fake to the legacy HTTP+SSE transport.
    static func resetLegacy(answer: @escaping ([String: Any]) -> [String: Any]?) {
        reset { request in
            // Replies go down the stream, not in the POST body.
            if let json = request.json, let reply = answer(json) {
                FakeMCPServer.push(event: "message", data: try! JSONSerialization.data(withJSONObject: reply))
            }
            return Reply(status: 202, headers: [:], body: Data())
        }
        lock.withLock { legacyMode = true }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeMCPServer.self]
        return URLSession(configuration: configuration)
    }

    static func push(event: String, data: Data) {
        let chunk = Data("event: \(event)\ndata: ".utf8) + data + Data("\n\n".utf8)
        lock.withLock {
            guard let (proto, client) = streamClient else { return }
            client.urlProtocol(proto, didLoad: chunk)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(of: request)
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let entry = Received(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            json: json
        )
        let (respond, legacy) = Self.lock.withLock { () -> (((Received) -> Reply)?, Bool) in
            Self._received.append(entry)
            return (Self._respond, Self.legacyMode)
        }

        if legacy, entry.method == "GET" {
            // Open the event stream and announce the POST endpoint, relative
            // to the stream URL as real servers do.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.lock.withLock { Self.streamClient = (self, client!) }
            client?.urlProtocol(self, didLoad: Data(": keep-alive\n\nevent: endpoint\ndata: /messages?session=abc\n\n".utf8))
            return  // Stays open until stopLoading.
        }

        let reply = respond?(entry) ?? Reply(status: 500)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock {
            if let (proto, _) = Self.streamClient, proto === self { Self.streamClient = nil }
        }
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: Canned JSON-RPC

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// The reply a well-behaved server gives each method.
    static func standardResult(for request: [String: Any], protocolVersion: String = "2025-06-18") -> [String: Any]? {
        guard let id = request["id"], let method = request["method"] as? String else { return nil }
        switch method {
        case "initialize":
            return ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "fake", "version": "1"],
                "instructions": "Call echo first."
            ]]
        case "tools/list":
            return ["jsonrpc": "2.0", "id": id, "result": ["tools": [
                ["name": "echo", "description": "Echoes", "inputSchema": ["type": "object"]]
            ]]]
        case "tools/call":
            let text = ((request["params"] as? [String: Any])?["arguments"] as? [String: Any])?["text"] as? String ?? ""
            return ["jsonrpc": "2.0", "id": id, "result": [
                "content": [["type": "text", "text": "echo: \(text)"]]
            ]]
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "nope"]]
        }
    }
}

// MARK: - Streamable HTTP

@MainActor
final class MCPStreamableHTTPTests: XCTestCase {

    private func remoteConfig(headers: [String: String] = [:]) -> MCPServerConfig {
        MCPServerConfig(name: "remote", transport: .http, url: "https://mcp.example.com/mcp", headers: headers)
    }

    /// The whole path the chat uses — handshake, list, call — over plain JSON
    /// replies, with the session id and protocol version carried forward.
    func testHandshakeListAndCallOverJSON() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json else { return .init(status: 400) }
            if json["id"] == nil {
                // A notification: accepted, no body.
                return .init(status: 202, headers: [:], body: Data())
            }
            var reply = FakeMCPServer.Reply(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
            if json["method"] as? String == "initialize" {
                reply.headers["Mcp-Session-Id"] = "session-42"
            }
            return reply
        }

        let client = MCPClient(config: remoteConfig(), urlSession: FakeMCPServer.session())
        try await client.start()
        defer { client.stop() }

        XCTAssertEqual(client.instructions, "Call echo first.")
        XCTAssertEqual(client.protocolVersion, "2025-06-18")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.qualifiedName), ["remote__echo"])
        let output = try await client.callTool(name: "echo", arguments: ["text": "hi"])
        XCTAssertEqual(output, "echo: hi")

        let posts = FakeMCPServer.received.filter { $0.method == "POST" }
        XCTAssertEqual(posts.map { $0.json?["method"] as? String },
                       ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        // initialize asks for a Streamable-HTTP-era revision and has no session yet.
        let initParams = posts[0].json?["params"] as? [String: Any]
        XCTAssertEqual(initParams?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(posts[0].headers["Mcp-Session-Id"])
        XCTAssertTrue(posts[0].headers["Accept"]?.contains("text/event-stream") == true)
        // Every later request carries the session and the negotiated version.
        for post in posts.dropFirst() {
            XCTAssertEqual(post.headers["Mcp-Session-Id"], "session-42", "\(post.json ?? [:]) \(post.headers)")
            XCTAssertEqual(post.headers["MCP-Protocol-Version"], "2025-06-18")
        }
    }

    /// A reply streamed as SSE, with a keep-alive comment and a server `ping`
    /// ahead of the answer. The ping must be answered, never mistaken for the
    /// reply to our own request with the same id.
    func testSSEReplyWithServerRequestBeforeAnswer() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json else { return .init(status: 400) }
            guard let id = json["id"] as? Int, json["method"] != nil else {
                // Notifications and our answer to the ping.
                return .init(status: 202, headers: [:], body: Data())
            }
            let answer = FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!)
            // The ping reuses the id of the request it rides on.
            let ping = FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "method": "ping"])
            var body = Data(": keep-alive\n\n".utf8)
            body += Data("data: ".utf8) + ping + Data("\r\n\r\n".utf8)
            body += Data("event: message\ndata: ".utf8) + answer + Data("\n\n".utf8)
            return .init(headers: ["Content-Type": "text/event-stream"], body: body)
        }

        let client = MCPClient(config: remoteConfig(), urlSession: FakeMCPServer.session())
        try await client.start()
        defer { client.stop() }
        XCTAssertEqual(client.instructions, "Call echo first.")
        let output = try await client.callTool(name: "echo", arguments: ["text": "streamed"])
        XCTAssertEqual(output, "echo: streamed")

        // Give the background answer to the ping a moment to go out.
        try await Task.sleep(for: .milliseconds(200))
        let pingAnswers = FakeMCPServer.received.compactMap(\.json).filter {
            $0["method"] == nil && $0["result"] != nil
        }
        XCTAssertFalse(pingAnswers.isEmpty, "the server's ping must get a reply")
    }

    /// Header placeholders resolve before they are sent, inline or whole.
    func testHeadersAreResolvedAndSent() async throws {
        setenv("TYPSTEDIT_TEST_MCP_TOKEN", "s3cret", 1)
        defer { unsetenv("TYPSTEDIT_TEST_MCP_TOKEN") }
        FakeMCPServer.reset { request in
            guard let json = request.json, json["id"] != nil else { return .init(status: 202, headers: [:], body: Data()) }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }
        let config = remoteConfig(headers: ["Authorization": "Bearer ${env:TYPSTEDIT_TEST_MCP_TOKEN}"])
        let client = MCPClient(config: config, urlSession: FakeMCPServer.session())
        try await client.start()
        client.stop()
        XCTAssertEqual(FakeMCPServer.received.first?.headers["Authorization"], "Bearer s3cret")
    }

    /// A server that wants OAuth says so with 401; the error tells the user
    /// what to do instead of a bare status code.
    /// A 401 starts the OAuth flow. When the server publishes no sign-in
    /// settings either (this fake publishes none), the failure must still
    /// tell the user the way in: a token header.
    func testUnauthorizedSignsInOrExplainsTheWayAround() async throws {
        FakeMCPServer.reset { _ in .init(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: Data()) }
        let client = MCPClient(config: remoteConfig(), urlSession: FakeMCPServer.session())
        do {
            try await client.start()
            XCTFail("a 401 with no OAuth discovery must fail the handshake")
        } catch {
            XCTAssertFalse(client.isRunning)
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("sign-in"), message)
            XCTAssertTrue(message.contains("Authorization"), message)
        }
    }

    /// A reply that ends without answering must fail the call, not hang it.
    func testReplyWithoutAnswerFailsInsteadOfHanging() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, json["id"] != nil else { return .init(status: 202, headers: [:], body: Data()) }
            if json["method"] as? String == "tools/call" {
                return .init(status: 202, headers: [:], body: Data())
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }
        let client = MCPClient(config: remoteConfig(), urlSession: FakeMCPServer.session())
        try await client.start()
        defer { client.stop() }
        do {
            _ = try await client.callTool(name: "echo", arguments: [:])
            XCTFail("an unanswered request must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("without answering"), error.localizedDescription)
        }
    }

    /// 404 on a request that carried a session id means the session is gone.
    func testExpiredSessionIsReported() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, json["id"] != nil else { return .init(status: 202, headers: [:], body: Data()) }
            if json["method"] as? String == "tools/call" { return .init(status: 404) }
            var reply = FakeMCPServer.Reply(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
            reply.headers["Mcp-Session-Id"] = "s1"
            return reply
        }
        let client = MCPClient(config: remoteConfig(), urlSession: FakeMCPServer.session())
        try await client.start()
        defer { client.stop() }
        do {
            _ = try await client.callTool(name: "echo", arguments: [:])
            XCTFail("expected sessionExpired")
        } catch MCPError.sessionExpired {
            // expected
        }
    }
}

// MARK: - Legacy HTTP+SSE

@MainActor
final class MCPLegacySSETests: XCTestCase {

    func testHandshakeListAndCallOverEventStream() async throws {
        FakeMCPServer.resetLegacy { FakeMCPServer.standardResult(for: $0, protocolVersion: "2024-11-05") }
        let config = MCPServerConfig(name: "old", transport: .sse, url: "https://legacy.example.com/sse")
        let client = MCPClient(config: config, urlSession: FakeMCPServer.session())
        try await client.start()
        defer { client.stop() }

        XCTAssertEqual(client.protocolVersion, "2024-11-05")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let output = try await client.callTool(name: "echo", arguments: ["text": "legacy"])
        XCTAssertEqual(output, "echo: legacy")

        // Messages go to the endpoint the stream announced, resolved
        // against the stream URL.
        let posts = FakeMCPServer.received.filter { $0.method == "POST" }
        XCTAssertFalse(posts.isEmpty)
        for post in posts {
            XCTAssertEqual(post.url.absoluteString, "https://legacy.example.com/messages?session=abc")
        }
        XCTAssertEqual(FakeMCPServer.received.first?.method, "GET")
        XCTAssertEqual(FakeMCPServer.received.first?.headers["Accept"], "text/event-stream")
    }
}

// MARK: - Live

/// Against a real remote MCP server, when one is named in the environment:
///
///     PORT=3001 npx -y @modelcontextprotocol/server-everything streamableHttp
///     TYPSTEDIT_LIVE_MCP_HTTP_URL=http://127.0.0.1:3001/mcp swift test --filter MCPRemoteLiveTests
///
/// (`server-everything sse` serves the legacy transport for
/// `TYPSTEDIT_LIVE_MCP_SSE_URL`, at `/sse`.) Skips when neither is set.
@MainActor
final class MCPRemoteLiveTests: XCTestCase {

    private func run(_ transport: MCPTransportType, urlVariable: String) async throws {
        guard let url = ProcessInfo.processInfo.environment[urlVariable], !url.isEmpty else {
            throw XCTSkip("\(urlVariable) not set — no live remote MCP server to test against")
        }
        let client = MCPClient(config: MCPServerConfig(name: "live", transport: transport, url: url))
        try await client.start()
        defer { client.stop() }
        let tools = try await client.listTools()
        XCTAssertFalse(tools.isEmpty, "a live server should list tools")
        if tools.contains(where: { $0.name == "echo" }) {
            let output = try await client.callTool(name: "echo", arguments: ["message": "typstedit"])
            XCTAssertTrue(output.contains("clippy"), output)
        }
    }

    func testStreamableHTTP() async throws {
        try await run(.http, urlVariable: "TYPSTEDIT_LIVE_MCP_HTTP_URL")
    }

    func testLegacySSE() async throws {
        try await run(.sse, urlVariable: "TYPSTEDIT_LIVE_MCP_SSE_URL")
    }
}

// MARK: - Pure pieces

final class SSEParserTests: XCTestCase {

    private func events(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var out = lines.compactMap { parser.feed(line: $0) }
        if let last = parser.finish() { out.append(last) }
        return out
    }

    func testDefaultEventTypeIsMessage() {
        XCTAssertEqual(events(["data: {}", ""]), [SSEEvent(event: "message", data: "{}")])
    }

    func testNamedEventsMultiLineDataAndComments() {
        let parsed = events([": comment", "event: endpoint", "data: /a", "data: /b", "", "id: 7", "data:x", ""])
        XCTAssertEqual(parsed, [
            SSEEvent(event: "endpoint", data: "/a\n/b"),
            SSEEvent(event: "message", data: "x", id: "7"),
        ])
    }

    func testBlankLinesWithoutDataDispatchNothing() {
        XCTAssertEqual(events(["", "event: ping", "", ""]), [])
    }

    func testTrailingEventWithoutBlankLineIsKept() {
        XCTAssertEqual(events(["data: last"]), [SSEEvent(event: "message", data: "last")])
    }
}

final class MCPEnvironmentResolverTests: XCTestCase {
    private let env = ["TOKEN": "abc", "USER": "me"]
    private func keychain(_ key: String) -> String? { key == "gh" ? "ghp_1" : nil }

    func testWholeAndInlinePlaceholders() {
        XCTAssertEqual(MCPEnvironmentResolver.resolve("${env:TOKEN}", environment: env, keychain: keychain), "abc")
        XCTAssertEqual(MCPEnvironmentResolver.resolve("Bearer ${keychain:gh}", environment: env, keychain: keychain), "Bearer ghp_1")
        XCTAssertEqual(MCPEnvironmentResolver.resolve("{env:USER}-${env:TOKEN}", environment: env, keychain: keychain), "me-abc")
    }

    func testMissingValuesResolveEmptyAndPlainTextIsUntouched() {
        XCTAssertEqual(MCPEnvironmentResolver.resolve("Bearer ${env:NOPE}", environment: env, keychain: keychain), "Bearer ")
        XCTAssertEqual(MCPEnvironmentResolver.resolve("plain value", environment: env, keychain: keychain), "plain value")
    }
}
