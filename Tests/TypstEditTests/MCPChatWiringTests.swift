import XCTest
@testable import TypstEdit

/// A registered MCP server must reach the chat's model, not just the Settings
/// list.
///
/// The reported shape was "registration worked, but no tools are ever run":
/// `mcp.json` loaded, the Settings row showed the server, and every chat turn
/// declared zero MCP tools. Three separate wiring gaps produced that, and each
/// one alone is enough to hide every server tool:
///
/// 1. `AIChatManager.mcp` was never assigned — the store that owns the
///    `ProjectContext` wired `sessionStore` and `context` but not the manager,
///    so `mcp` stayed nil and `enabledMCPServers` was always empty.
/// 2. Selections and the tool catalogue were keyed differently: the Tools menu
///    and `ProjectConfig.enabledMCPServerIDs` write `ScopedMCPServer.id`
///    (`"global:name"`), while `enabledMCPServers` and the catalogue lookups
///    compared the bare `config.name`.
/// 3. Seeding ran inside `AIChatManager.init`, before the manager was
///    attached, so the first pass saw zero servers and selected none.
@MainActor
final class MCPChatWiringTests: XCTestCase {

    private func serverConfig(_ name: String) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .http, url: "https://\(name).example.com/mcp")
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
        context.mcp.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }
        context.mcp.saveServer(server, scope: .global)
        defer { context.mcp.deleteServer(name: server.name, scope: .global) }

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

    /// Seeding must run after the manager is attached. Otherwise a fresh chat
    /// selects nothing and the model is offered no MCP tools even though the
    /// server is enabled and configured.
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
        context.mcp.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }
        context.mcp.saveServer(server, scope: .global)
        defer { context.mcp.deleteServer(name: server.name, scope: .global) }

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
        context.mcp.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }
        context.mcp.saveServer(server, scope: .global)
        defer { context.mcp.deleteServer(name: server.name, scope: .global) }

        let store = AIChatSessionStore(context: context)
        let chat = store.activeManager
        chat.selectedMCPServerIDs = [scoped.id]

        _ = await chat.availableTools()
        XCTAssertTrue(chat.mcpMayRunConcurrentlyForTesting("\(server.name)__peek"),
                      "a read-only tool on an opted-in server must be allowed to batch")
    }
}
