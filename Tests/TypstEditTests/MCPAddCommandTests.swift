import XCTest
@testable import TypstEdit

/// `mcp add` command lines are how server READMEs tell you to install them, so
/// pasting one must produce the same server clicking through the editor would.
/// Every case here is a real line from published setup instructions.
@MainActor
final class MCPAddCommandTests: XCTestCase {

    // MARK: - The line the user asked about

    /// `codex mcp add affinity -- uvx mcp-proxy --transport sse http://…`
    ///
    /// The inner `--transport sse` belongs to `mcp-proxy`, not to the add
    /// command, so it must survive as an argument rather than switch
    /// TypstEdit's own transport.
    func testCodexAddWithProxyCommand() throws {
        let servers = try MCPAddCommand.parse(
            "codex mcp add affinity -- uvx mcp-proxy --transport sse http://localhost:6767/sse"
        )
        XCTAssertEqual(servers.count, 1)
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server.name, "affinity")
        XCTAssertEqual(server.transport, .stdio)
        XCTAssertEqual(server.command, "uvx")
        XCTAssertEqual(server.args, ["mcp-proxy", "--transport", "sse", "http://localhost:6767/sse"])
        XCTAssertTrue(server.isConfigured)
    }

    // MARK: - Remote servers

    func testClaudeAddHTTPWithTransportFlag() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse("claude mcp add --transport http notion https://mcp.notion.com/mcp").first
        )
        XCTAssertEqual(server.name, "notion")
        XCTAssertEqual(server.transport, .http)
        XCTAssertEqual(server.url, "https://mcp.notion.com/mcp")
        XCTAssertNil(server.command)
    }

    func testClaudeAddSSE() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse("claude mcp add --transport sse asana https://mcp.asana.com/sse").first
        )
        XCTAssertEqual(server.transport, .sse)
        XCTAssertEqual(server.url, "https://mcp.asana.com/sse")
    }

    /// Without `--transport`, the endpoint decides: `/sse` is the legacy
    /// transport, everything else is Streamable HTTP.
    func testTransportIsInferredFromURL() throws {
        let sse = try XCTUnwrap(try MCPAddCommand.parse("mcp add demo https://example.com/sse").first)
        XCTAssertEqual(sse.transport, .sse)

        let http = try XCTUnwrap(try MCPAddCommand.parse("mcp add demo https://example.com/mcp").first)
        XCTAssertEqual(http.transport, .http)
    }

    /// Codex puts the URL behind a flag instead of a positional.
    func testCodexAddURLFlag() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse("codex mcp add docs --url https://mcp.example.com/mcp").first
        )
        XCTAssertEqual(server.name, "docs")
        XCTAssertEqual(server.url, "https://mcp.example.com/mcp")
        XCTAssertEqual(server.transport, .http)
    }

    /// The token stays in the environment: `--bearer-token-env-var` becomes an
    /// Authorization header that resolves `${env:…}` at startup, so the secret
    /// never lands in `mcp.json`.
    func testCodexBearerTokenEnvVarBecomesHeader() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse(
                "codex mcp add docs --url https://x.example.com/mcp --bearer-token-env-var DOCS_TOKEN"
            ).first
        )
        XCTAssertEqual(server.headers["Authorization"], "Bearer ${env:DOCS_TOKEN}")
        XCTAssertTrue(server.env.isEmpty, "the token variable is not a server environment variable")
    }

    func testHeaderFlag() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse(
                #"claude mcp add --transport http secure https://api.example.com/mcp --header "Authorization: Bearer abc123""#
            ).first
        )
        XCTAssertEqual(server.headers["Authorization"], "Bearer abc123")
    }

    // MARK: - Local servers

    func testEnvFlagBeforeCommand() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse(
                "claude mcp add --env AIRTABLE_API_KEY=secret --transport stdio airtable -- npx -y airtable-mcp-server"
            ).first
        )
        XCTAssertEqual(server.name, "airtable")
        XCTAssertEqual(server.transport, .stdio)
        XCTAssertEqual(server.command, "npx")
        XCTAssertEqual(server.args, ["-y", "airtable-mcp-server"])
        XCTAssertEqual(server.env, ["AIRTABLE_API_KEY": "secret"])
    }

    func testRepeatedEnvFlags() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse("mcp add --env A=1 --env B=2 demo -- python server.py").first
        )
        XCTAssertEqual(server.env, ["A": "1", "B": "2"])
        XCTAssertEqual(server.command, "python")
        XCTAssertEqual(server.args, ["server.py"])
    }

    /// The server's own flags must not be read as the add command's options,
    /// even without a `--` separator.
    func testServerFlagsAfterCommandAreKept() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse("mcp add demo -- python server.py --port 8080 --transport http").first
        )
        XCTAssertEqual(server.command, "python")
        XCTAssertEqual(server.args, ["server.py", "--port", "8080", "--transport", "http"])
        XCTAssertEqual(server.transport, .stdio)
    }

    /// `--scope` is accepted and dropped: the paste sheet's scope picker
    /// decides where the server lands, not the command line.
    func testScopeFlagIsIgnored() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse(
                "claude mcp add --scope user --transport http notion https://mcp.notion.com/mcp"
            ).first
        )
        XCTAssertEqual(server.name, "notion")
        XCTAssertEqual(server.url, "https://mcp.notion.com/mcp")
    }

    // MARK: - JSON

    func testAddJSONCommand() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse(
                #"claude mcp add-json example '{"command":"npx","args":["-y","@example/mcp-server"]}'"#
            ).first
        )
        XCTAssertEqual(server.name, "example")
        XCTAssertEqual(server.transport, .stdio)
        XCTAssertEqual(server.command, "npx")
        XCTAssertEqual(server.args, ["-y", "@example/mcp-server"])
    }

    func testPastedJSONBlock() throws {
        let servers = try MCPAddCommand.parse(
            """
            {
              "mcpServers": {
                "rea": { "command": "npx", "args": ["-y", "rea-agents@6.9.0", "mcp"] },
                "docs": { "type": "http", "url": "https://mcp.example.com/mcp" }
              }
            }
            """
        )
        XCTAssertEqual(servers.map(\.name), ["docs", "rea"])
        let docs = try XCTUnwrap(servers.first { $0.name == "docs" })
        XCTAssertEqual(docs.transport, .http)
        XCTAssertEqual(docs.url, "https://mcp.example.com/mcp")
    }

    // MARK: - Refusals

    func testUnrecognizedTextIsRefused() {
        for text in ["", "just some words", "npm install thing", "https://example.com"] {
            XCTAssertThrowsError(try MCPAddCommand.parse(text), "should have refused: \(text)")
        }
    }

    func testNamedServerWithNoTargetIsRefused() {
        XCTAssertThrowsError(try MCPAddCommand.parse("codex mcp add lonely")) { error in
            XCTAssertTrue(error.localizedDescription.contains("lonely"))
        }
    }

    func testBadPairIsRefused() {
        XCTAssertThrowsError(try MCPAddCommand.parse("mcp add --env NOEQUALS demo -- python s.py"))
    }

    /// A quoted run stays one word, so an Authorization header with a space is
    /// not split into two tokens.
    func testTokenizeKeepsQuotedRunsTogether() {
        let tokens = MCPAddCommand.tokenize(#"add --header "Authorization: Bearer a b" s https://x/y"#)
        XCTAssertEqual(tokens, ["add", "--header", "Authorization: Bearer a b", "s", "https://x/y"])
    }

    /// A name that cannot be a tool prefix is normalized rather than rejected.
    func testServerNameIsSanitized() throws {
        let server = try XCTUnwrap(
            try MCPAddCommand.parse("mcp add My Server! -- python s.py").first
        )
        // "My" is the name; "Server!" is the command. A name with a space has
        // to be quoted, which the tokenizer then keeps whole.
        let quoted = try XCTUnwrap(
            try MCPAddCommand.parse(#"mcp add "My Server!" -- python s.py"#).first
        )
        XCTAssertEqual(quoted.name, "My-Server")
        XCTAssertEqual(server.name, "My")
    }
}
