import XCTest
@testable import TypstEdit

/// `MCPServerConfig.allowInsecure`: plain http to any host and untrusted certificates, per
/// server, opt-in. ATS is off app-wide, so this policy is the only thing standing between a
/// plain-http URL and the network.
@MainActor
final class MCPInsecureConnectionTests: XCTestCase {
    private func decode(_ json: String) throws -> MCPServerConfig {
        try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
    }

    func testFlagIsOffWhenAbsentAndReadsEverySpelling() throws {
        XCTAssertFalse(try decode(#"{"url": "http://h.example/mcp"}"#).allowInsecure, "absent means off")
        XCTAssertTrue(try decode(#"{"url": "http://h.example/mcp", "allowInsecure": true}"#).allowInsecure)
        XCTAssertTrue(try decode(#"{"url": "http://h.example/mcp", "insecure": true}"#).allowInsecure)
        XCTAssertTrue(try decode(#"{"url": "http://h.example/mcp", "allowInsecureConnections": true}"#).allowInsecure)
        XCTAssertFalse(try decode(#"{"url": "http://h.example/mcp", "allowInsecure": "yes"}"#).allowInsecure,
                       "a malformed value reads as off, not as a broken entry")
    }

    func testFlagRoundTripsThroughTheConfigFile() throws {
        var config = MCPServerConfig(name: "vqt-mcp")
        config.transport = .http
        config.url = "http://prddpkmitvqt001.vistaprint.net/mcp"
        config.allowInsecure = true
        let file = MCPConfigFile(mcpServers: ["vqt-mcp": config])
        let data = try JSONEncoder().encode(file)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""allowInsecure":true"#))
        let read = try JSONDecoder().decode(MCPConfigFile.self, from: data)
        XCTAssertEqual(read.mcpServers["vqt-mcp"]?.allowInsecure, true)
    }

    func testPlainHttpToANonLocalHostNeedsTheFlag() {
        let remote = URL(string: "http://prddpkmitvqt001.vistaprint.net/mcp")!
        XCTAssertNotNil(MCPServerConfig.insecureRefusal(for: remote, allowInsecure: false))
        XCTAssertNil(MCPServerConfig.insecureRefusal(for: remote, allowInsecure: true))
        // https, and http on this Mac or the LAN, never need it.
        XCTAssertNil(MCPServerConfig.insecureRefusal(for: URL(string: "https://mcp.example.com/mcp")!, allowInsecure: false))
        XCTAssertNil(MCPServerConfig.insecureRefusal(for: URL(string: "http://127.0.0.1:6767/sse")!, allowInsecure: false))
        XCTAssertNil(MCPServerConfig.insecureRefusal(for: URL(string: "http://192.168.1.20/mcp")!, allowInsecure: false))
    }

    /// Without the flag the connection is refused before any request is made, with a message
    /// that names the setting to turn on.
    func testClientRefusesPlainHttpWithoutTheFlagAndNamesTheSetting() async {
        var config = MCPServerConfig(name: "vqt-mcp")
        config.transport = .http
        config.url = "http://prddpkmitvqt001.vistaprint.net/mcp"
        // Tokens in memory only: a test must never touch the real Keychain.
        let vault = Vault()
        let store = MCPOAuthStore(keyPrefix: "insecure-test:", read: { vault.values[$0] },
                                  write: { vault.values[$0] = $1 }, remove: { vault.values[$0] = nil })
        let client = MCPClient(config: config, oauthStore: store)
        do {
            try await client.start()
            XCTFail("plain http to a non-local host must be refused without allowInsecure")
        } catch {
            guard case MCPError.insecureConnectionNotAllowed = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Allow insecure connection"), error.localizedDescription)
        }
    }

    /// The certificate override answers only the server-trust challenge; any other challenge
    /// (HTTP auth, client certificate) gets the default handling.
    func testCertificateOverrideOnlyAnswersServerTrust() {
        let delegate = MCPHTTPSessions.TrustAnyCertificate()
        let space = URLProtectionSpace(host: "h.example", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: NoopChallengeSender())
        let answered = expectation(description: "answered")
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .performDefaultHandling)
            XCTAssertNil(credential)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 1)
    }
}

private final class Vault: @unchecked Sendable {
    var values: [String: String] = [:]
}

private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
