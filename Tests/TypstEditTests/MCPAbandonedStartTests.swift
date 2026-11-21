import XCTest
@testable import TypstEdit

/// A server whose start the user abandoned must not be remembered as broken.
///
/// This is the second half of the MCP hang, and the half the user actually
/// saw. A launcher configured as a server (an app shim without its `mcp`
/// argument) accepted the pipe and never answered `initialize`, so the chat
/// waited with no progress. Pressing Stop cancelled the wait, and the
/// cancellation was stored in `lastErrors` — which Settings → MCP and the
/// chat's Tools menu render as a red line, so "The operation couldn't be
/// completed. (Swift.CancellationError error 1.)" sat under the server
/// permanently. The server was never at fault, and the next turn would have
/// connected fine.
///
/// A start that fails for a real reason is still recorded: the distinction is
/// cancellation versus an actual error, not "did it fail".
@MainActor
final class MCPAbandonedStartTests: XCTestCase {

    private func refused(_ name: String) -> MCPServerConfig {
        MCPServerConfig(name: name, transport: .http, url: "https://\(name).example.com/mcp")
    }

    /// A cancelled start leaves no error behind, and leaves nothing running.
    func testCancelledStartRecordsNoError() async throws {
        FakeMCPServer.reset { _ in
            // Answering 500 makes `URLSession`-backed cancellation the only
            // way this start ends, so the test controls the timing.
            .init(status: 500)
        }

        let manager = MCPManager(skipConfigLoad: true)
        defer { manager.stopAll() }
        let server = refused("abandoned")
        manager.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }

        // Cancel the start the way Stop does: run it in a task and cancel it.
        let scoped = ScopedMCPServer(config: server, scope: .global)
        let task = Task { await manager.ensureStarted(scoped) }
        task.cancel()
        _ = await task.value

        XCTAssertNil(manager.lastErrors[scoped.id],
                     "Stop is the user's action, not a server fault: \(manager.lastErrors[scoped.id] ?? "")")
        XCTAssertFalse(manager.runningServerIDs.contains(server.id))
        XCTAssertFalse(manager.toolsByServerID[server.id]?.isEmpty ?? false)
    }

    /// A real failure is still reported, so the fix cannot hide a broken
    /// server behind the same silence.
    func testRealFailureIsStillRecorded() async throws {
        FakeMCPServer.reset { request in
            guard let json = request.json, let id = json["id"], let method = json["method"] as? String else {
                return .init(status: 202, headers: [:], body: Data())
            }
            if method == "initialize" {
                return .init(body: FakeMCPServer.json([
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": -32600, "message": "I am not an MCP server"]
                ]))
            }
            return .init(body: FakeMCPServer.json(["jsonrpc": "2.0", "id": id, "result": [:]]))
        }

        let manager = MCPManager(skipConfigLoad: true)
        defer { manager.stopAll() }
        let server = refused("broken")
        manager.makeClient = { MCPClient(config: $0, urlSession: FakeMCPServer.session()) }

        let client = await manager.ensureStarted(ScopedMCPServer(config: server, scope: .global))
        XCTAssertNil(client)
        let error = try XCTUnwrap(manager.lastErrors[ScopedMCPServer(config: server, scope: .global).id])
        XCTAssertTrue(error.contains("not an MCP server"), error)
    }

    /// The two cancellation shapes that actually arrive, checked directly so a
    /// future refactor of the error plumbing cannot quietly stop matching one.
    func testCancellationShapesAreRecognised() {
        XCTAssertTrue(MCPManager.isCancellation(CancellationError()))
        XCTAssertTrue(MCPManager.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(MCPManager.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(MCPManager.isCancellation(MCPError.protocolError("nope")))
    }

    /// Only the local handshake is bounded: a remote `initialize` waits (that
    /// is where an interactive sign-in runs), and a long tool call is never
    /// timed out from here.
    func testOnlyTheLocalHandshakeHasADeadline() {
        let client = MCPClient(config: refused("deadline"))
        let stdio = MCPStdioTransport(command: "true", args: [], env: [:])
        let remote = MCPStreamableHTTPTransport(
            endpoint: URL(string: "https://x.example/mcp")!,
            headers: [:],
            urlSession: FakeMCPServer.session()
        )
        XCTAssertEqual(client.timeoutSeconds(for: "initialize", transport: stdio), 30)
        XCTAssertNil(client.timeoutSeconds(for: "tools/call", transport: stdio), "a tool may run for minutes")
        XCTAssertNil(client.timeoutSeconds(for: "initialize", transport: remote), "sign-in happens on the first remote request")
    }
}
