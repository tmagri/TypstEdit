import XCTest
@testable import TypstEdit

/// A registered MCP server must reach the chat's model, not just the Settings
/// list.
///
/// The reported shape was "registration worked, but no tools are ever run":
/// `mcp.json` loaded, the Settings row showed the server, and every chat turn
/// declared zero MCP tools. Several separate wiring gaps produced that, and
/// each one alone is enough to hide every server tool:
///
/// 1. `AIChatManager.mcp` was never assigned — the store that owns the
///    `ProjectContext` wired `sessionStore` and `context` but not the manager,
///    so `mcp` stayed nil and `enabledMCPServers` was always empty.
/// 2. Selections and the tool catalogue were keyed differently: the Tools menu
///    and `ProjectConfig.enabledMCPServerIDs` write `ScopedMCPServer.id`
///    (`"global:name"`), while `enabledMCPServers` and the catalogue lookups
///    compared the bare `config.name`.
/// 3. Seeding read its candidates from `enabledMCPServers` — the property it
///    had just been filtered by — so a fresh chat started empty, found no
///    candidates, and could never select a server.
/// 4. Seeding ran inside `AIChatManager.init`, before the manager was
///    attached, so even a non-circular seed saw no servers on the first pass.
///
/// `MCPConfigStore.configURLOverride` keeps every case on a throwaway file, so
/// a run never reads or writes the user's real `mcp.json`.
@MainActor
final class MCPChatWiringTests: XCTestCase {

    private var configDirectory: URL!
    private var previousOverride: URL?

    override func setUp() async throws {
        try await super.setUp()
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPChatWiringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        previousOverride = MCPConfigStore.configURLOverride
        MCPConfigStore.configURLOverride = configDirectory.appendingPathComponent("mcp.json")
    }

    override func tearDown() async throws {
        MCPConfigStore.configURLOverride = previousOverride
        if let configDirectory {
            try? FileManager.default.removeItem(at: configDirectory)
        }
        try await super.tearDown()
    }

    private func serverConfig(_ name: String) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .http, url: "https://\(name).example.com/mcp")
    }

    /// The fake transport answers every handshake, so a start succeeds without
    /// a process or a network.
    private func installFakeTransport(on manager: MCPManager) {
        manager.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }
    }

    /// A chat attached to a window's context sees that context's enabled
    /// servers, with tools keyed the same way the Tools menu selects them.
    func testChatReceivesTheWindowsMCPManagerAndItsTools() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, let id = json["id"] else {
                return .init(status: 202, headers: [:], body: Data())
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }

        let context = ProjectContext()
        let server = serverConfig("wired")
        let scoped = ScopedMCPServer(config: server, scope: .global)
        installFakeTransport(on: context.mcp)
        context.mcp.saveServer(server, scope: .global)

        let store = AIChatSessionStore(context: context)
        let chat = store.activeManager

        XCTAssertTrue(chat.mcp === context.mcp,
                      "the store must inject the window's manager; a nil one hides every server tool")

        // The Tools menu's own selection key is what the chat must honour.
        chat.selectedMCPServerIDs = [scoped.id]
        XCTAssertEqual(chat.enabledMCPServers.map(\.id), [scoped.id])

        let tools = await chat.availableTools()
        let serverTools = tools.filter { $0.serverName == server.name }
        XCTAssertFalse(serverTools.isEmpty,
                       "a registered, selected server must contribute tools to the model's declaration")
        XCTAssertTrue(serverTools.allSatisfy { $0.qualifiedName.hasPrefix("\(server.name)__") })
    }

    /// Seeding must run after the manager is attached, and must not ask the
    /// selection it is computing for its own candidates. Otherwise a fresh
    /// chat selects nothing and the model is offered no MCP tools even though
    /// the server is enabled and configured.
    func testAFreshChatSelectsConfiguredServers() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, let id = json["id"] else {
                return .init(status: 202, headers: [:], body: Data())
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }

        let context = ProjectContext()
        let server = serverConfig("seeded")
        let scoped = ScopedMCPServer(config: server, scope: .global)
        installFakeTransport(on: context.mcp)
        context.mcp.saveServer(server, scope: .global)

        let store = AIChatSessionStore(context: context)
        XCTAssertEqual(store.activeManager.selectedMCPServerIDs, [scoped.id],
                       "a server configured before the chat existed must be on without a Settings trip")
    }

    /// A tool's read-only annotation is read from the catalogue under the
    /// scoped key, so a batched read is actually eligible.
    func testConcurrencyEligibilityUsesTheScopedCatalogueKey() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, let id = json["id"] else {
                return .init(status: 202, headers: [:], body: Data())
            }
            if json["method"] as? String == "tools/list" {
                return .init(body: FakeMCPServer.json([
                    "jsonrpc": "2.0", "id": id, "result": ["tools": [[
                        "name": "peek",
                        "description": "",
                        "inputSchema": ["type": "object"],
                        "annotations": ["readOnlyHint": true, "destructiveHint": false]
                    ]]]
                ]))
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }

        let context = ProjectContext()
        var server = serverConfig("batched")
        server.allowConcurrentCalls = true
        let scoped = ScopedMCPServer(config: server, scope: .global)
        installFakeTransport(on: context.mcp)
        context.mcp.saveServer(server, scope: .global)

        let store = AIChatSessionStore(context: context)
        let chat = store.activeManager
        chat.selectedMCPServerIDs = [scoped.id]

        _ = await chat.availableTools()
        XCTAssertTrue(chat.mcpMayRunConcurrentlyForTesting("\(server.name)__peek"),
                      "a read-only tool on an opted-in server must be allowed to batch")
    }

    /// The end-to-end path the bug report describes: a tool the model is
    /// offered can actually be run through the chat's dispatcher.
    func testAnOfferedServerToolCanBeRun() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, let id = json["id"] else {
                return .init(status: 202, headers: [:], body: Data())
            }
            if json["method"] as? String == "tools/call" {
                return .init(body: FakeMCPServer.json([
                    "jsonrpc": "2.0", "id": id,
                    "result": ["content": [["type": "text", "text": "ran"]]]
                ]))
            }
            return .init(body: FakeMCPServer.json(FakeMCPServer.standardResult(for: json)!))
        }

        let context = ProjectContext()
        let server = serverConfig("callable")
        let scoped = ScopedMCPServer(config: server, scope: .global)
        installFakeTransport(on: context.mcp)
        context.mcp.saveServer(server, scope: .global)

        let store = AIChatSessionStore(context: context)
        let chat = store.activeManager
        chat.selectedMCPServerIDs = [scoped.id]

        let tools = await chat.availableTools()
        let offered = try XCTUnwrap(tools.first { $0.serverName == server.name },
                                    "the model must be offered the server's tool")
        let output = await chat.executeToolForTesting(offered.qualifiedName, argumentsJSON: "{}")
        XCTAssertTrue(output.contains("ran"),
                      "the offered tool must reach the live server, got: \(output)")
    }
}
