import XCTest
@testable import TypstEdit

/// `mcp.json` must read what the other MCP clients write, not just what
/// TypstEdit itself writes — a pasted Claude Desktop config used to decode
/// as nothing at all.
final class MCPConfigDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> [String: MCPServerConfig] {
        try JSONDecoder().decode(MCPConfigFile.self, from: Data(json.utf8)).mcpServers
    }

    /// A Claude Desktop config: no name, transport, env, or enabled keys.
    /// This used to make the whole file read as empty.
    func testClaudeDesktopEntryDecodes() throws {
        let servers = try decode(#"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "server-fs"]}}}"#)
        let fs = try XCTUnwrap(servers["fs"])
        XCTAssertEqual(fs.name, "fs")
        XCTAssertEqual(fs.transport, .stdio)
        XCTAssertEqual(fs.command, "npx")
        XCTAssertEqual(fs.args, ["-y", "server-fs"])
        XCTAssertTrue(fs.enabled)
    }

    func testRemoteSpellingsFromOtherClients() throws {
        let servers = try decode(#"""
        {"mcpServers": {
          "a": {"type": "http", "url": "https://a.example/mcp", "headers": {"X-Key": "${keychain:a}"}},
          "b": {"type": "sse", "url": "https://b.example/sse"},
          "c": {"type": "streamable-http", "url": "https://c.example/mcp"},
          "d": {"url": "https://d.example/mcp"},
          "e": {"type": "local", "command": ["bunx", "@playwright/mcp", "--headless"], "disabled": true}
        }}
        """#)
        XCTAssertEqual(servers["a"]?.transport, .http)
        XCTAssertEqual(servers["a"]?.headers, ["X-Key": "${keychain:a}"])
        XCTAssertEqual(servers["b"]?.transport, .sse)
        XCTAssertEqual(servers["c"]?.transport, .http)
        XCTAssertEqual(servers["d"]?.transport, .http, "a bare url means remote")
        XCTAssertEqual(servers["e"]?.command, "bunx")
        XCTAssertEqual(servers["e"]?.args, ["@playwright/mcp", "--headless"])
        XCTAssertEqual(servers["e"]?.enabled, false)
        XCTAssertTrue(servers.values.allSatisfy(\.isConfigured))
    }

    /// One broken entry must not take the rest of the file with it.
    func testMalformedEntryIsSkipped() throws {
        let servers = try decode(#"{"mcpServers": {"good": {"command": "x"}, "bad": {"args": "not-an-array"}}}"#)
        XCTAssertEqual(Array(servers.keys), ["good"])
    }

    /// What TypstEdit writes, it reads back unchanged.
    func testRoundTrip() throws {
        var original = MCPServerConfig(name: "r", transport: .http, url: "https://r.example/mcp", headers: ["A": "b"])
        original.disabledTools = ["drop"]
        let data = try JSONEncoder().encode(MCPConfigFile(mcpServers: ["r": original]))
        XCTAssertEqual(try JSONDecoder().decode(MCPConfigFile.self, from: data).mcpServers["r"], original)
    }

    func testRemoteURLValidation() {
        XCTAssertNotNil(MCPServerConfig.remoteURL("https://x.example/mcp"))
        XCTAssertNotNil(MCPServerConfig.remoteURL(" http://localhost:3001/mcp "))
        XCTAssertNil(MCPServerConfig.remoteURL("x.example/mcp"))
        XCTAssertNil(MCPServerConfig.remoteURL("file:///etc/passwd"))
        XCTAssertNil(MCPServerConfig.remoteURL(""))
    }
}
