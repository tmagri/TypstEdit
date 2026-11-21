import XCTest
@testable import TypstEdit

/// A tool set a fake server can swap while a client is connected.
///
/// Declared at file scope, deliberately: `FakeMCPServer`'s responder runs on a
/// CFNetwork thread, and a closure or type nested inside a `@MainActor` test
/// inherits that isolation. Touching one from the responder traps on the
/// isolation check, so the state it reads must live in a non-isolated type
/// like this one.
private final class MutableToolCatalogue: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]
    private var rendered: [String: Data] = [:]

    init(_ names: [String]) {
        self.names = names
    }

    /// The JSON array of `tools/list` entries for the current set.
    var toolsJSON: Data {
        lock.withLock {
            let key = names.joined(separator: ",")
            if let cached = rendered[key] { return cached }
            var tools: [[String: Any]] = []
            for name in names {
                tools.append(["name": name, "description": "", "inputSchema": ["type": "object"]])
            }
            let data = FakeMCPServer.json(tools)
            rendered[key] = data
            return data
        }
    }

    func set(_ newNames: [String]) {
        lock.withLock { names = newNames }
    }

    /// Whether `tools/list` should fail, to exercise a failed re-read.
    var failing: Bool {
        get { lock.withLock { isFailing } }
        set { lock.withLock { isFailing = newValue } }
    }
    private var isFailing = false
}

/// A server that changes its tools mid-session must reach the model, not just
/// the client that noticed.
///
/// The client half is covered in `MCPStreamableHTTPTests`; this is the wiring
/// that matters in the app: `MCPManager` re-reads the catalogue when the
/// server says it changed, and the model's next turn is built from
/// `toolsByServerID`. A tool the server just removed must stop being offered —
/// the dangerous direction, because a stale declaration calls a tool that no
/// longer exists — and one it just added must appear.
///
/// The manager owns a client that talks to a fake `URLProtocol`, injected
/// through `makeClient`, so no process is spawned and no network is used. The
/// real `mcp.json` is never read: the manager is created with
/// `skipConfigLoad`, and `ensureStarted` is called with a config directly,
/// which is what the app does once a server is enabled.
@MainActor
final class MCPToolRefreshTests: XCTestCase {

    private func config(_ name: String) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .http, url: "https://\(name).example.com/mcp")
    }

    /// The path the model actually sees: a `list_changed` notification moves
    /// the catalogue in `toolsByServerID`, in both directions.
    func testNotificationRepublishesTheCatalogue() async throws {
        let catalogue = MutableToolCatalogue(["old_tool"])

        FakeMCPServer.resetStreaming { request in
            guard let json = request.json else { return .init(status: 400) }
            guard let id = json["id"], let method = json["method"] as? String else {
                return .init(status: 202, headers: [:], body: Data())
            }
            switch method {
            case "initialize":
                return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": ["tools": ["listChanged": true]],
                    "serverInfo": ["name": "changing", "version": "1"]
                ]]))
            case "tools/list":
                // Spliced by hand: a helper call inside this closure would be
                // an isolated call on a non-main thread.
                var body = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
                body += Data("\(id)".utf8)
                body += Data(#","result":{"tools":"#.utf8)
                body += catalogue.toolsJSON
                body += Data("}}".utf8)
                return .init(body: body)
            default:
                return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "nope"]]))
            }
        }

        let manager = MCPManager(skipConfigLoad: true)
        defer { manager.stopAll() }
        let server = config("changing")
        manager.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }

        let scoped = ScopedMCPServer(config: server, scope: .global)
        let started = await manager.ensureStarted(scoped)
        let client = try XCTUnwrap(started)
        XCTAssertTrue(client.isRunning)
        XCTAssertEqual(manager.toolsByServerID[scoped.id]?.map(\.name), ["old_tool"])

        // The server swaps one tool for another and says so.
        try await waitUntil { FakeMCPServer.received.contains { $0.method == "GET" } }
        catalogue.set(["new_tool"])
        FakeMCPServer.push(event: "message", data: FakeMCPServer.json([
            "jsonrpc": "2.0", "method": "notifications/tools/list_changed"
        ]))

        try await waitUntil { manager.toolsByServerID[scoped.id]?.map(\.name) == ["new_tool"] }
        XCTAssertEqual(manager.toolsByServerID[scoped.id]?.map(\.name), ["new_tool"],
                       "the model's next turn must not be offered the tool the server removed")
    }

    /// A client the manager does not own must not publish a catalogue under a
    /// server's name. A notification can arrive after a reconnect replaced the
    /// client, and the stale one's reply must not overwrite the live list.
    func testRefreshIsIgnoredForAClientTheManagerNoLongerOwns() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, let id = json["id"] else {
                return .init(status: 202, headers: [:], body: Data())
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }
        let manager = MCPManager(skipConfigLoad: true)
        defer { manager.stopAll() }
        let server = config("orphan")
        let orphan = MCPClient(config: server, urlSession: FakeMCPServer.session())
        try await orphan.start()
        defer { orphan.stop() }

        await manager.refreshTools(ScopedMCPServer(config: server, scope: .global), client: orphan)
        let scoped = ScopedMCPServer(config: server, scope: .global)
        XCTAssertNil(manager.toolsByServerID[scoped.id],
                     "a client the manager does not own must not publish a catalogue")    }

    /// A failed re-read keeps the last known catalogue and records the error.
    /// Dropping the server would be worse: the tools listed at the handshake
    /// still work while a transient `tools/list` failure clears.
    func testFailedRefreshKeepsThePreviousCatalogue() async throws {
        let broken = MutableToolCatalogue(["echo"])

        FakeMCPServer.reset { request in
            guard let json = request.json else { return .init(status: 400) }
            guard let id = json["id"], let method = json["method"] as? String else {
                return .init(status: 202, headers: [:], body: Data())
            }
            if method == "tools/list", broken.failing { return .init(status: 500) }
            if method == "initialize" {
                return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "flaky", "version": "1"]
                ]]))
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }

        let manager = MCPManager(skipConfigLoad: true)
        defer { manager.stopAll() }
        let server = config("flaky")
        manager.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }

        let scoped = ScopedMCPServer(config: server, scope: .global)
        let started = await manager.ensureStarted(scoped)
        let client = try XCTUnwrap(started)
        XCTAssertEqual(manager.toolsByServerID[scoped.id]?.map(\.name), ["echo"])

        broken.failing = true
        await manager.refreshTools(ScopedMCPServer(config: server, scope: .global), client: client)

        XCTAssertEqual(manager.toolsByServerID[scoped.id]?.map(\.name), ["echo"],
                       "a transient failure must not empty the catalogue the model is using")
        XCTAssertNotNil(manager.lastErrors[scoped.id], "the failure must be visible, not silent")
    }

    /// The client fires the hook for a tool-list change and nothing else, so
    /// an unrelated notification cannot cost a round trip.
    func testOnlyTheToolListNotificationFiresTheHook() async throws {
        FakeMCPServer.resetStreaming { request in
            guard let json = request.json else { return .init(status: 400) }
            guard let id = json["id"], json["method"] != nil else {
                return .init(status: 202, headers: [:], body: Data())
            }
            if json["method"] as? String == "initialize" {
                return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": ["tools": ["listChanged": true]],
                    "serverInfo": ["name": "chatty", "version": "1"]
                ]]))
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }

        let client = MCPClient(config: config("chatty"), urlSession: FakeMCPServer.session())
        var changes = 0
        client.onToolsChanged = { changes += 1 }
        try await client.start()
        defer { client.stop() }
        try await waitUntil { FakeMCPServer.received.contains { $0.method == "GET" } }

        FakeMCPServer.push(event: "message", data: FakeMCPServer.json([
            "jsonrpc": "2.0", "method": "notifications/resources/updated",
            "params": ["uri": "file:///x"]
        ]))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(changes, 0, "an unrelated notification must not trigger a re-read")

        FakeMCPServer.push(event: "message", data: FakeMCPServer.json([
            "jsonrpc": "2.0", "method": "notifications/tools/list_changed"
        ]))
        try await waitUntil { changes == 1 }
        XCTAssertEqual(changes, 1)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
