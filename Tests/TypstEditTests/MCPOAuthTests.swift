import XCTest
@testable import TypstEdit

// MARK: - A fake authorization server

/// Plays the documents and endpoints of an OAuth 2.1 authorization server,
/// plus the resource-metadata document, so the whole sign-in can run with no
/// network and no browser.
struct FakeAuthorizationServer: Sendable {
    var authorizationURL = URL(string: "https://auth.example.com/authorize")!
    var tokenURL = URL(string: "https://auth.example.com/token")!
    var registrationURL = URL(string: "https://auth.example.com/register")!
    var issuer = URL(string: "https://auth.example.com")!
    var codeChallengeMethods: [String]? = ["S256"]

    /// The code the token endpoint accepts.
    var issuedCode = "the-code"
    /// Set false to refuse the code exchange.
    var acceptsCode = true
    var acceptsRefresh = true

    /// The PKCE challenge the authorization URL carried. The fake browser
    /// records it here, and the token endpoint checks the verifier against
    /// it — the same two-step a real authorization server performs.
    let challenge: ChallengeBox

    final class ChallengeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        var current: String {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Every token POST seen, for assertions.
    let posted: Posted

    final class Posted: @unchecked Sendable {
        private let lock = NSLock()
        private var forms: [[String: String]] = []
        func append(_ form: [String: String]) { lock.withLock { forms.append(form) } }
        var all: [[String: String]] { lock.withLock { forms } }
    }
}

extension FakeAuthorizationServer: MCPOAuthHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func reply(_ status: Int, _ json: Any?, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            let data = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }

        switch url.path {
        case "/.well-known/oauth-protected-resource/mcp":
            return reply(200, [
                "resource": "https://mcp.example.com/mcp",
                "authorization_servers": [issuer.absoluteString],
                "scopes_supported": ["tools"],
            ])
        case "/.well-known/oauth-authorization-server":
            return reply(200, [
                "issuer": issuer.absoluteString,
                "authorization_endpoint": authorizationURL.absoluteString,
                "token_endpoint": tokenURL.absoluteString,
                "registration_endpoint": registrationURL.absoluteString,
                "scopes_supported": ["tools"],
                "code_challenge_methods_supported": codeChallengeMethods ?? [],
            ])
        case "/register":
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            XCTAssertEqual(body["token_endpoint_auth_method"] as? String, "none")
            XCTAssertEqual(body["grant_types"] as? [String], ["authorization_code", "refresh_token"])
            XCTAssertEqual(body["client_name"] as? String, MCPOAuthDiscovery.clientName)
            return reply(201, ["client_id": "client-abc", "client_secret": NSNull()])
        case "/token":
            let form = Self.form(request.httpBody ?? Data())
            posted.append(form)
            let grant = form["grant_type"]
            if grant == "authorization_code" {
                // Verify PKCE the way a real server does: the challenge that
                // was sent must equal S256(verifier) from the token request.
                let verifier = form["code_verifier"] ?? ""
                let expected = PKCE.challenge(for: verifier)
                guard acceptsCode,
                      form["code"] == issuedCode,
                      !verifier.isEmpty,
                      form["client_id"] == "client-abc",
                      expected == challenge.current else {
                    return reply(400, ["error": "invalid_grant"])
                }
                return reply(200, [
                    "access_token": "access-1",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "refresh_token": "refresh-1",
                    "scope": "tools",
                ])
            }
            if grant == "refresh_token" {
                guard acceptsRefresh, form["refresh_token"] == "refresh-1" else {
                    return reply(400, ["error": "invalid_grant"])
                }
                return reply(200, ["access_token": "access-2", "token_type": "Bearer", "expires_in": 3600])
            }
            return reply(400, ["error": "unsupported_grant_type"])
        default:
            return reply(404, nil)
        }
    }

    static func form(_ body: Data) -> [String: String] {
        guard let text = String(data: body, encoding: .utf8),
              let components = URLComponents(string: "?" + text) else { return [:] }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

// MARK: - Flow

@MainActor
final class MCPOAuthFlowTests: XCTestCase {

    /// A server whose browser immediately redirects, using the challenge and
    /// state the flow actually sent. This is the happy path end to end.
    private func makeServer(
        answer: ((URL) -> URL?)?,
        mutate: (inout FakeAuthorizationServer) -> Void = { _ in }
    ) -> (FakeAuthorizationServer, MCPOAuthFlow) {
        var server = FakeAuthorizationServer(challenge: FakeAuthorizationServer.ChallengeBox(), posted: FakeAuthorizationServer.Posted())
        mutate(&server)
        let flow = MCPOAuthFlow(http: server)
        let challenge = server.challenge
        // The browser: it "visits" the authorization URL and answers with a
        // redirect, exactly what a real authorization server does once the
        // user signs in. No network, no window.
        flow.browser = { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            challenge.current = items.first { $0.name == "code_challenge" }?.value ?? ""
            guard let redirect = answer?(authorizationURL) else {
                // Never answering: a browser the user abandoned. The sleep
                // must be cancellable, or the flow's timeout could never end
                // the race — exactly the bug this test exists to catch.
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    throw MCPOAuthError.cancelled
                }
                throw MCPOAuthError.timedOut
            }
            return redirect
        }
        return (server, flow)
    }

    func testSignInDiscoversRegistersAndExchanges() async throws {
        var seenChallenge = ""
        var seenRedirectURI = ""
        var seenState = ""
        let (_, flow) = makeServer(answer: { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            seenChallenge = value("code_challenge")
            seenRedirectURI = value("redirect_uri")
            seenState = value("state")
            return URL(string: "\(seenRedirectURI)?code=the-code&state=\(seenState)")
        }, mutate: { $0.acceptsCode = true })

        let resource = URL(string: "https://mcp.example.com/mcp")!
        let endpoint = try await flow.discover(resource: resource)
        XCTAssertEqual(endpoint.tokenURL, URL(string: "https://auth.example.com/token")!)
        XCTAssertEqual(endpoint.scopes, ["tools"])
        XCTAssertTrue(endpoint.registrationURL != nil)

        let credentials = try await flow.signIn(
            serverName: "srv", resource: resource, endpoint: endpoint, existingClient: nil
        )

        XCTAssertEqual(credentials.accessToken, "access-1")
        XCTAssertEqual(credentials.refreshToken, "refresh-1")
        XCTAssertEqual(credentials.client.clientID, "client-abc")
        XCTAssertEqual(credentials.tokenType, "Bearer")
        XCTAssertEqual(seenChallenge.count, 43, "S256 challenge is base64url of a 32-byte digest")
        XCTAssertTrue(seenRedirectURI.hasPrefix("http://127.0.0.1:"), seenRedirectURI)
        XCTAssertTrue(seenRedirectURI.hasSuffix("/callback"))
        XCTAssertFalse(seenState.isEmpty)
    }

    func testPKCEChallengeMatchesVerifier() {
        let verifier = PKCE.verifier()
        XCTAssertEqual(verifier.count, 43)
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge.count, 43)
        XCTAssertEqual(PKCE.challenge(for: verifier), challenge, "S256 is deterministic")
        XCTAssertFalse(challenge.contains("+") || challenge.contains("/") || challenge.contains("="))
        XCTAssertNotEqual(PKCE.challenge(for: PKCE.verifier()), challenge)
    }

    func testSignInRejectsAMismatchedState() async throws {
        let (_, flow) = makeServer(answer: { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            return URL(string: "\(redirect)?code=the-code&state=not-the-state-we-sent")
        })
        let resource = URL(string: "https://mcp.example.com/mcp")!
        let endpoint = try await flow.discover(resource: resource)
        do {
            _ = try await flow.signIn(serverName: "srv", resource: resource, endpoint: endpoint, existingClient: nil)
            XCTFail("a foreign state must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not match"), error.localizedDescription)
        }
    }

    func testSignInSurfacesAnAuthorizationError() async throws {
        let (_, flow) = makeServer(answer: { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            let state = items.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(redirect)?error=access_denied&error_description=user+cancelled&state=\(state)")
        })
        let resource = URL(string: "https://mcp.example.com/mcp")!
        let endpoint = try await flow.discover(resource: resource)
        do {
            _ = try await flow.signIn(serverName: "srv", resource: resource, endpoint: endpoint, existingClient: nil)
            XCTFail("an error redirect must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("refused"), error.localizedDescription)
        }
    }

    /// A server that answers no redirect at all must time out, not hang.
    func testSignInTimesOutWithoutARedirect() async throws {
        let (_, flow) = makeServer(answer: { _ in nil })
        flow.signInTimeout = .milliseconds(300)
        let resource = URL(string: "https://mcp.example.com/mcp")!
        let endpoint = try await flow.discover(resource: resource)
        do {
            _ = try await flow.signIn(serverName: "srv", resource: resource, endpoint: endpoint, existingClient: nil)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
        }
    }

    func testRefreshReplacesAccessTokenAndKeepsRotatingRefreshToken() async throws {
        let (server, flow) = makeServer(answer: { _ in nil })
        let credentials = MCPOAuthCredentials(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(-10),
            tokenType: "Bearer",
            scope: "tools",
            client: MCPOAuthClient(clientID: "client-abc", clientSecret: nil),
            tokenURL: server.tokenURL,
            issuer: server.issuer,
            resource: URL(string: "https://mcp.example.com/mcp")!
        )
        let refreshed = try await flow.refresh(credentials)
        XCTAssertEqual(refreshed.accessToken, "access-2")
        // The reply omitted a new refresh token: the old one stays.
        XCTAssertEqual(refreshed.refreshToken, "refresh-1")
        XCTAssertFalse(refreshed.isExpiring(), "a fresh hour is not expiring")
        // The resource is resent, so a multi-service issuer scopes the token.
        XCTAssertEqual(server.posted.all.last?["resource"], "https://mcp.example.com/mcp")
    }

    func testRefusedRefreshThrows() async throws {
        let (server, flow) = makeServer(answer: { _ in nil }, mutate: { $0.acceptsRefresh = false })
        let credentials = MCPOAuthCredentials(
            accessToken: "old", refreshToken: "refresh-1", expiresAt: nil,
            tokenType: "Bearer", scope: nil,
            client: MCPOAuthClient(clientID: "client-abc", clientSecret: nil),
            tokenURL: server.tokenURL, issuer: server.issuer,
            resource: URL(string: "https://mcp.example.com/mcp")!
        )
        do {
            _ = try await flow.refresh(credentials)
            XCTFail("expected a refresh failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("renew"), error.localizedDescription)
        }
    }

    func testNoRefreshTokenCannotRefresh() async throws {
        let (server, flow) = makeServer(answer: { _ in nil })
        let credentials = MCPOAuthCredentials(
            accessToken: "old", refreshToken: nil, expiresAt: nil, tokenType: "Bearer", scope: nil,
            client: MCPOAuthClient(clientID: "client-abc", clientSecret: nil),
            tokenURL: server.tokenURL, issuer: server.issuer,
            resource: URL(string: "https://mcp.example.com/mcp")!
        )
        do {
            _ = try await flow.refresh(credentials)
            XCTFail("no refresh token means no refresh")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no refresh token"), error.localizedDescription)
        }
    }

    /// A client registered for this exact redirect URI is reused, so
    /// re-signing in does not register again.
    func testExistingClientForTheSameRedirectSkipsRegistration() async throws {
        let (_, flow) = makeServer(answer: { _ in nil })
        let endpoint = try await flow.discover(resource: URL(string: "https://mcp.example.com/mcp")!)
        let redirect = "http://127.0.0.1:1234/callback"
        let client = try await flow.registerClient(
            endpoint: endpoint,
            redirectURI: redirect,
            existing: MCPOAuthClient(clientID: "already-registered", clientSecret: nil, redirectURI: redirect)
        )
        // The fake would have answered "client-abc" had it been asked.
        XCTAssertEqual(client.clientID, "already-registered")
    }

    /// The loopback port changes on every sign-in, and Atlassian matches the
    /// redirect URI exactly: the old client with a new port gets HTTP 500 on
    /// /authorize. A saved client for a different redirect URI — or one saved
    /// before the URI was recorded — must be registered again.
    func testExistingClientForAnotherRedirectIsRegisteredAgain() async throws {
        let (_, flow) = makeServer(answer: { _ in nil })
        let endpoint = try await flow.discover(resource: URL(string: "https://mcp.example.com/mcp")!)
        let redirect = "http://127.0.0.1:64501/callback"

        let otherPort = try await flow.registerClient(
            endpoint: endpoint,
            redirectURI: redirect,
            existing: MCPOAuthClient(clientID: "old", clientSecret: nil, redirectURI: "http://127.0.0.1:50001/callback")
        )
        XCTAssertEqual(otherPort.clientID, "client-abc")
        XCTAssertEqual(otherPort.redirectURI, redirect, "the new client remembers what it was registered for")

        let legacy = try await flow.registerClient(
            endpoint: endpoint,
            redirectURI: redirect,
            existing: MCPOAuthClient(clientID: "old", clientSecret: nil)
        )
        XCTAssertEqual(legacy.clientID, "client-abc")
    }

    /// A client saved by an earlier build has no `redirectURI` key.
    func testClientSavedWithoutARedirectURIStillDecodes() throws {
        let data = Data(#"{"clientID":"DrlWR3XhsyrKZTvs"}"#.utf8)
        let client = try JSONDecoder().decode(MCPOAuthClient.self, from: data)
        XCTAssertEqual(client.clientID, "DrlWR3XhsyrKZTvs")
        XCTAssertNil(client.redirectURI)
    }

    // MARK: - Discovery documents

    func testWellKnownURLsFollowTheSpec() {
        let resource = URL(string: "https://host.example.com/prefix/path")!
        let urls = MCPOAuthDiscovery.protectedResourceMetadataURLs(for: resource).map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://host.example.com/.well-known/oauth-protected-resource/prefix/path",
            "https://host.example.com/.well-known/oauth-protected-resource",
        ])

        let issuer = URL(string: "https://auth.example.com/tenant")!
        let serverURLs = MCPOAuthDiscovery.authorizationServerMetadataURLs(issuer: issuer).map(\.absoluteString)
        XCTAssertEqual(serverURLs, [
            "https://auth.example.com/.well-known/oauth-authorization-server/tenant",
            "https://auth.example.com/.well-known/openid-configuration/tenant",
            "https://auth.example.com/.well-known/openid-configuration",
        ])
    }

    func testResourceMetadataHintIsParsed() {
        let header = #"Bearer error="invalid_token", resource_metadata="https://x.example/meta.json""#
        XCTAssertEqual(MCPOAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: header)?.absoluteString, "https://x.example/meta.json")
        XCTAssertNil(MCPOAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: "Bearer realm=\"x\""))
        XCTAssertNil(MCPOAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: ""))
    }

    func testLocalHostCoversLoopbackAndPrivateRangesOnly() {
        for host in ["localhost", "127.0.0.1", "::1", "[::1]", "10.1.2.3", "192.168.0.10", "172.16.5.4", "172.31.255.1", "169.254.1.1", "printer.local"] {
            XCTAssertTrue(MCPOAuthDiscovery.isLocalHost(host), "\(host) should be local")
        }
        for host in ["example.com", "prddpkmitvqt001.vistaprint.net", "8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.1.1", ""] {
            XCTAssertFalse(MCPOAuthDiscovery.isLocalHost(host), "\(host) should not be local")
        }
        XCTAssertFalse(MCPOAuthDiscovery.isLocalHost(nil))
    }

    /// An internal server reached over plain http (no certificate) signs in on its own
    /// host; a plain-http sign-in page on a different host is still refused.
    func testHttpSignInIsAllowedOnlyOnTheMCPServersOwnOrigin() {
        let resource = URL(string: "http://prddpkmitvqt001.vistaprint.net/mcp")!
        XCTAssertTrue(MCPOAuthDiscovery.isAcceptableAuthorizationEndpoint(
            URL(string: "http://prddpkmitvqt001.vistaprint.net/McpOAuth/Authorize")!, resource: resource))
        XCTAssertTrue(MCPOAuthDiscovery.isAcceptableAuthorizationEndpoint(
            URL(string: "http://PRDDPKMITVQT001.vistaprint.net:80/McpOAuth/Authorize")!, resource: resource),
            "host case and an explicit default port are the same origin")
        XCTAssertTrue(MCPOAuthDiscovery.isAcceptableAuthorizationEndpoint(
            URL(string: "https://cimpress.auth0.com/authorize")!, resource: resource), "https is always fine")

        XCTAssertFalse(MCPOAuthDiscovery.isAcceptableAuthorizationEndpoint(
            URL(string: "http://evil.example.com/authorize")!, resource: resource), "another host over http")
        XCTAssertFalse(MCPOAuthDiscovery.isAcceptableAuthorizationEndpoint(
            URL(string: "http://prddpkmitvqt001.vistaprint.net:8080/authorize")!, resource: resource), "another port")
        XCTAssertFalse(MCPOAuthDiscovery.isAcceptableAuthorizationEndpoint(
            URL(string: "http://auth.example.com/authorize")!,
            resource: URL(string: "https://mcp.example.com/mcp")!), "https server, http sign-in elsewhere")
    }

    // MARK: HTTP sign-ins end to end

    func testSignInCompletesOnAnHttpServerThatIsItsOwnAuthorizationServer() async throws {
        let base = "http://vqt.corp.example"
        let (_, flow) = makeServer(answer: { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            return URL(string: "\(value("redirect_uri"))?code=the-code&state=\(value("state"))")
        }, mutate: { server in
            server.issuer = URL(string: base)!
            server.authorizationURL = URL(string: "\(base)/McpOAuth/Authorize")!
            server.tokenURL = URL(string: "\(base)/token")!
            server.registrationURL = URL(string: "\(base)/register")!
        })
        let resource = URL(string: "\(base)/mcp")!
        let endpoint = try await flow.discover(resource: resource)
        let credentials = try await flow.signIn(serverName: "vqt", resource: resource, endpoint: endpoint, existingClient: nil)
        XCTAssertEqual(credentials.accessToken, "access-1")
    }

    /// The same http MCP server must not hand its sign-in to a different plain-http host.
    func testHttpSignInOnAnotherHostIsRefusedBeforeTheBrowserOpens() async throws {
        var browserOpened = false
        let (_, flow) = makeServer(answer: { _ in browserOpened = true; return nil }, mutate: { server in
            server.issuer = URL(string: "http://auth.other.example")!
            server.authorizationURL = URL(string: "http://auth.other.example/authorize")!
            server.tokenURL = URL(string: "http://auth.other.example/token")!
            server.registrationURL = URL(string: "http://auth.other.example/register")!
        })
        let resource = URL(string: "http://vqt.corp.example/mcp")!
        let endpoint = try await flow.discover(resource: resource)
        do {
            _ = try await flow.signIn(serverName: "vqt", resource: resource, endpoint: endpoint, existingClient: nil)
            XCTFail("an http sign-in on another host must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not https"), error.localizedDescription)
        }
        XCTAssertFalse(browserOpened)
    }

    /// With the server's `allowInsecure` on, the same http sign-in on another host completes.
    func testAllowInsecureLetsHttpSignInUseAnotherHost() async throws {
        let (_, flow) = makeServer(answer: { authorizationURL in
            let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            return URL(string: "\(value("redirect_uri"))?code=the-code&state=\(value("state"))")
        }, mutate: { server in
            server.issuer = URL(string: "http://auth.other.example")!
            server.authorizationURL = URL(string: "http://auth.other.example/authorize")!
            server.tokenURL = URL(string: "http://auth.other.example/token")!
            server.registrationURL = URL(string: "http://auth.other.example/register")!
        })
        flow.allowInsecure = true
        let resource = URL(string: "http://vqt.corp.example/mcp")!
        let endpoint = try await flow.discover(resource: resource)
        let credentials = try await flow.signIn(serverName: "vqt", resource: resource, endpoint: endpoint, existingClient: nil)
        XCTAssertEqual(credentials.accessToken, "access-1")
    }
}

// MARK: - Storage

@MainActor
final class MCPOAuthStoreTests: XCTestCase {
    func testRoundTripAndDelete() {
        var box: [String: String] = [:]
        let store = MCPOAuthStore(
            read: { box[$0] },
            write: { box[$0] = $1 },
            remove: { box[$0] = nil }
        )
        let credentials = MCPOAuthCredentials(
            accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_000),
            tokenType: "Bearer", scope: "tools",
            client: MCPOAuthClient(clientID: "c", clientSecret: nil),
            tokenURL: URL(string: "https://t.example/token")!,
            issuer: URL(string: "https://t.example")!,
            resource: URL(string: "https://r.example/mcp")!
        )
        XCTAssertNil(store.load(serverName: "srv"))
        store.save(credentials, serverName: "srv")
        XCTAssertEqual(store.load(serverName: "srv"), credentials)
        store.delete(serverName: "srv")
        XCTAssertNil(store.load(serverName: "srv"))
    }

    func testExpiryBoundary() {
        let now = Date(timeIntervalSince1970: 10_000)
        var credentials = MCPOAuthCredentials(
            accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(30), tokenType: "Bearer",
            scope: nil, client: MCPOAuthClient(clientID: "c", clientSecret: nil),
            tokenURL: URL(string: "https://t.example/token")!, issuer: URL(string: "https://t.example")!,
            resource: URL(string: "https://r.example/mcp")!
        )
        // Inside the one-minute early window: refresh now rather than lose a call.
        XCTAssertTrue(credentials.isExpiring(now: now))
        credentials.expiresAt = now.addingTimeInterval(120)
        XCTAssertFalse(credentials.isExpiring(now: now))
        credentials.expiresAt = nil
        XCTAssertFalse(credentials.isExpiring(now: now), "no stated expiry is not an expiry")
    }

    func testClientStoreRoundTripsTheRedirectURI() {
        var box: [String: String] = [:]
        let store = MCPOAuthClientStore(
            read: { box[$0] },
            write: { box[$0] = $1 }
        )
        let client = MCPOAuthClient(
            clientID: "c", clientSecret: nil,
            redirectURI: "http://127.0.0.1:50001/callback"
        )
        store.save(client, serverName: "srv")
        XCTAssertEqual(store.load(serverName: "srv"), client)
    }

    /// The header is built from `token_type` as the server wrote it, and some
    /// servers write it lowercase while refusing anything but `Bearer`.
    /// Atlassian's MCP endpoint answers `"token_type": "bearer"` and then 401s
    /// on `Authorization: bearer <token>` — the token it just issued. The
    /// scheme is case-insensitive per RFC 7235, so canonicalising is always
    /// correct and is what makes such a server work.
    func testAuthorizationHeaderCanonicalisesTheBearerScheme() {
        func header(_ type: String) -> String {
            MCPOAuthCredentials(
                accessToken: "the-token", refreshToken: nil, expiresAt: nil, tokenType: type,
                scope: nil, client: MCPOAuthClient(clientID: "c", clientSecret: nil),
                tokenURL: URL(string: "https://t.example/token")!, issuer: URL(string: "https://t.example")!,
                resource: URL(string: "https://r.example/mcp")!
            ).authorizationHeader
        }
        XCTAssertEqual(header("bearer"), "Bearer the-token")
        XCTAssertEqual(header("BEARER"), "Bearer the-token")
        XCTAssertEqual(header("Bearer"), "Bearer the-token")
        // Any other scheme is a different credential and is left alone.
        XCTAssertEqual(header("MAC"), "MAC the-token")
    }
}

// MARK: - Loopback

/// The loopback receiver, exercised over a real TCP connection on 127.0.0.1.
final class MCPLoopbackListenerTests: XCTestCase {

    private func get(_ url: URL) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let body = LockedBox<String?>(nil)
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            body.set(data.map { String(decoding: $0, as: UTF8.self) })
            semaphore.signal()
        }
        task.resume()
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success)
        return body.get() ?? ""
    }

    func testItReceivesTheRedirect() async throws {
        let listener = try MCPLoopbackListener()
        defer { listener.stop() }
        XCTAssertTrue(listener.redirectURI.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(listener.redirectURI.hasSuffix("/callback"))

        async let redirected = listener.waitForRedirect()
        // A non-redirect request (a favicon, a scanner) must not settle it.
        _ = try get(URL(string: "http://127.0.0.1:\(listener.port)/favicon.ico")!)
        _ = try get(URL(string: "http://127.0.0.1:\(listener.port)/callback?code=abc&state=xyz")!)

        let url = try await redirected
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "abc")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "xyz")
    }

    func testTheBrowserSeesAConfirmationPage() async throws {
        let listener = try MCPLoopbackListener()
        defer { listener.stop() }
        async let redirected = listener.waitForRedirect()
        let page = try get(URL(string: "http://127.0.0.1:\(listener.port)/callback?code=c")!)
        _ = try? await redirected
        XCTAssertTrue(page.contains("Signed in"), page)
    }

    func testStopCancelsTheWait() async throws {
        let listener = try MCPLoopbackListener()
        let waiting = Task { try await listener.waitForRedirect() }
        listener.stop()
        do {
            _ = try await waiting.value
            XCTFail("a stopped listener must not wait forever")
        } catch {
            // Expected: cancelled or timed out by the stop.
        }
    }
}
