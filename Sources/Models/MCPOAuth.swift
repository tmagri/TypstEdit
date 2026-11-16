import Foundation
import AppKit
import CryptoKit

// MARK: - Errors

enum MCPOAuthError: LocalizedError {
    case discoveryFailed(String)
    case registrationFailed(String)
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case timedOut
    case cancelled
    case notEnrolled

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let detail):
            // Reached when a server refused with 401 and then published no
            // sign-in settings — the one case where the user must supply a
            // token themselves.
            return "This server needs sign-in, but didn't publish OAuth settings (\(detail)). If it offers an API token, add it in Settings → MCP as a header: Authorization: Bearer ${keychain:name}."
        case .registrationFailed(let detail):
            return "Couldn't register TypstEdit with the sign-in service (\(detail))."
        case .authorizationDenied(let detail):
            return "Sign-in was refused or cancelled\(detail.isEmpty ? "" : ": \(detail)")."
        case .tokenExchangeFailed(let detail):
            return "The sign-in service didn't issue a token (\(detail))."
        case .refreshFailed(let detail):
            return "The saved sign-in expired and couldn't be renewed (\(detail)). Sign in again in Settings → MCP."
        case .timedOut:
            return "Sign-in timed out — no answer came back from the browser in 5 minutes."
        case .cancelled:
            return "Sign-in was cancelled."
        case .notEnrolled:
            return "This server doesn't support OAuth sign-in."
        }
    }
}

// MARK: - PKCE

/// Proof Key for Code Exchange (RFC 7636). Every sign-in uses it: the browser,
/// the URL bar, and the pages the user visits never see the verifier that
/// actually redeems the code, so a stolen authorization code is useless.
enum PKCE {
    /// A verifier: 32 random bytes, base64url — 43 characters, inside the
    /// spec's 43…128 range.
    static func verifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    /// The S256 challenge: base64url of SHA-256 of the verifier's ASCII.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Discovery documents

/// What a protected resource publishes about its sign-in service
/// (RFC 9728). Only `authorization_servers` matters to us.
struct MCPProtectedResourceMetadata: Decodable, Equatable {
    var resource: String?
    var authorizationServers: [String]
    var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

/// An authorization server's published endpoints (RFC 8414 / OIDC
/// discovery). Only the fields TypstEdit uses are read; the rest is ignored.
struct MCPAuthorizationServerMetadata: Decodable, Equatable {
    var issuer: String?
    var authorizationEndpoint: String?
    var tokenEndpoint: String?
    var registrationEndpoint: String?
    var scopesSupported: [String]?
    var codeChallengeMethodsSupported: [String]?
    var tokenEndpointAuthMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }

    var supportsPKCE: Bool {
        // A server that names methods must name S256. One that names none is
        // given the benefit of the doubt (the spec requires S256 support).
        guard let methods = codeChallengeMethodsSupported, !methods.isEmpty else { return true }
        return methods.contains("S256")
    }

    /// Confidential clients get a secret at registration; if the server
    /// supports a public client we prefer it, since TypstEdit ships the same
    /// client id to every user.
    var prefersPublicClient: Bool {
        guard let methods = tokenEndpointAuthMethodsSupported, !methods.isEmpty else { return true }
        return methods.contains("none")
    }
}

/// Everything one sign-in needs, resolved from the two discovery documents.
struct MCPOAuthEndpoint: Equatable {
    var issuer: URL
    var authorizationURL: URL
    var tokenURL: URL
    var registrationURL: URL?
    var scopes: [String]
}

/// Where the discovery documents live. Pure URL arithmetic, per spec.
enum MCPOAuthDiscovery {
    /// `https://host/prefix/path` → `https://host/.well-known/oauth-protected-resource/prefix/path`
    ///
    /// RFC 9728 inserts the well-known segment before the resource's path,
    /// so a server mounted under a prefix is found at the origin, not at the
    /// prefix. Trying the plain origin too covers servers that publish it
    /// without repeating the path.
    static func protectedResourceMetadataURLs(for resource: URL) -> [URL] {
        guard let scheme = resource.scheme, let host = resource.host else { return [] }
        let origin = host + (resource.port.map { ":\($0)" } ?? "")
        let path = resource.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var urls = [
            URL(string: "\(scheme)://\(origin)/.well-known/oauth-protected-resource" + (path.isEmpty ? "" : "/\(path)")),
            URL(string: "\(scheme)://\(origin)/.well-known/oauth-protected-resource"),
        ].compactMap { $0 }
        // A duplicate (no path) would fetch the same document twice.
        if urls.count == 2, urls[0] == urls[1] { urls.removeLast() }
        return urls
    }

    /// RFC 8414 puts the well-known segment before the issuer's path;
    /// OpenID Connect keeps the path and appends `/.well-known/openid-configuration`.
    /// Both are tried, because servers in the wild publish one or the other.
    static func authorizationServerMetadataURLs(issuer: URL) -> [URL] {
        guard let scheme = issuer.scheme, let host = issuer.host else { return [] }
        let origin = host + (issuer.port.map { ":\($0)" } ?? "")
        let path = issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [
            URL(string: "\(scheme)://\(origin)/.well-known/oauth-authorization-server" + (path.isEmpty ? "" : "/\(path)")),
            URL(string: "\(scheme)://\(origin)/.well-known/openid-configuration" + (path.isEmpty ? "" : "/\(path)")),
            URL(string: "\(scheme)://\(origin)/.well-known/openid-configuration"),
        ].compactMap { $0 }.reduce(into: []) { unique, url in
            if !unique.contains(url) { unique.append(url) }
        }
    }

    /// The `resource_metadata` a server may point at in its 401's
    /// `WWW-Authenticate` header, e.g.
    /// `Bearer error="invalid_token", resource_metadata="https://x/.well-known/…"`.
    /// Pointing at the document directly is how a server mounted somewhere
    /// unusual avoids relying on the well-known convention.
    static func resourceMetadataURL(fromWWWAuthenticate header: String) -> URL? {
        let pattern = #"resource_metadata\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return URL(string: String(header[range]))
    }

    /// Client id/secret TypstEdit registers with (RFC 7591). Public client:
    /// no secret, PKCE for proof, and a fixed name a person can recognise
    /// when consenting.
    static let clientName = "TypstEdit"
}

/// The token response (RFC 6749 §5.1 / RFC 7636).
struct MCPOAuthTokenResponse: Decodable, Equatable {
    var accessToken: String
    var tokenType: String?
    var expiresIn: Double?
    var refreshToken: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

/// A registered client, kept so re-signing in after a restart reuses it
/// instead of littering the authorization server with registrations.
struct MCPOAuthClient: Codable, Equatable, Sendable {
    var clientID: String
    var clientSecret: String?
}

/// What TypstEdit stores for one server after a successful sign-in.
struct MCPOAuthCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    /// Absolute expiry; nil when the server did not say (treated as usable).
    var expiresAt: Date?
    var tokenType: String
    var scope: String?
    var client: MCPOAuthClient
    /// The token endpoint, cached so a refresh needs no discovery round.
    var tokenURL: URL
    var issuer: URL
    /// The resource these tokens are for (RFC 8707), resent on refresh so a
    /// multi-service issuer cannot hand back a token for the wrong audience.
    var resource: URL

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// Treated as expired a minute early, so a token cannot lapse between the
    /// check and the request that uses it.
    func isExpiring(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-60) <= now
    }

    var authorizationHeader: String { "\(tokenType) \(accessToken)" }
}

// MARK: - Transport

/// Opens a URL in the user's default browser. Off the main actor so the flow
/// can call it from any context; `NSWorkspace` itself is main-actor work.
enum SystemBrowser {
    static func open(_ url: URL) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { NSWorkspace.shared.open(url) }
        }
        return DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
    }
}

/// The one `URLSession` every remote MCP request uses: ephemeral, so cookies
/// and caches stay in memory. The idle timeout is generous because a tool call
/// can run for minutes before its first byte. Nonisolated so it can be a
/// default argument anywhere.
enum MCPHTTPSessions {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1_800
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

/// The HTTP seam, so the whole flow can run against a fake authorization
/// server in tests without a network or a browser.
protocol MCPOAuthHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`'s implementation. `URLSession` is `Sendable`, so this adds
/// nothing to share.
struct MCPURLSessionHTTP: MCPOAuthHTTP {
    var session: URLSession = MCPHTTPSessions.shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthError.discoveryFailed("the response was not HTTP")
        }
        return (data, http)
    }
}

// MARK: - Flow

/// The OAuth 2.1 flow TypstEdit runs to sign in to an MCP server: discover the
/// authorization server, register a client (once), send the user to the
/// browser with a PKCE challenge, take the code back on a loopback listener,
/// and exchange it for tokens.
@MainActor
final class MCPOAuthFlow {
    var http: any MCPOAuthHTTP
    /// How the authorization URL reaches the user's browser. Injected so a
    /// test can play the browser by fetching the redirect itself.
    var openURL: (URL) -> Bool
    /// How long to wait on the loopback before giving up.
    var signInTimeout: Duration
    var now: () -> Date
    /// How the browser is opened *and* how its redirect comes back. Production
    /// uses the real loopback listener; a test replaces it to play both
    /// halves — the browser that visits the URL, and the server that answers
    /// with a redirect — with no network.
    var browser: (@MainActor (URL) async throws -> URL)?

    init(
        http: any MCPOAuthHTTP = MCPURLSessionHTTP(),
        openURL: @escaping (URL) -> Bool = { SystemBrowser.open($0) },
        signInTimeout: Duration = .seconds(300),
        now: @escaping () -> Date = Date.init
    ) {
        self.http = http
        self.openURL = openURL
        self.signInTimeout = signInTimeout
        self.now = now
    }

    // MARK: Discovery

    /// Resolves the sign-in endpoints for `resource`, following the server's
    /// `WWW-Authenticate` hint when it gave one.
    func discover(resource: URL, resourceMetadataHint: URL? = nil) async throws -> MCPOAuthEndpoint {
        let candidates = resourceMetadataHint.map { [$0] } ?? MCPOAuthDiscovery.protectedResourceMetadataURLs(for: resource)
        var metadata: MCPProtectedResourceMetadata?
        for url in candidates {
            if let found = try? await fetchJSON(url, as: MCPProtectedResourceMetadata.self) {
                metadata = found
                break
            }
        }
        // A server may skip the protected-resource document and be its own
        // authorization server, which is common for small self-hosted ones.
        let issuers: [URL] = (metadata?.authorizationServers ?? []).compactMap(URL.init(string:))
        let issuerCandidates = issuers.isEmpty ? [origin(of: resource)].compactMap { $0 } : issuers

        var lastError: Error = MCPOAuthError.discoveryFailed("no authorization server is published")
        for issuer in issuerCandidates {
            for url in MCPOAuthDiscovery.authorizationServerMetadataURLs(issuer: issuer) {
                guard let server = try? await fetchJSON(url, as: MCPAuthorizationServerMetadata.self) else { continue }
                guard let authorizationURL = server.authorizationEndpoint.flatMap(URL.init(string:)),
                      let tokenURL = server.tokenEndpoint.flatMap(URL.init(string:)) else {
                    lastError = MCPOAuthError.discoveryFailed("the metadata has no authorization or token endpoint")
                    continue
                }
                // Prefer the scope the resource asked for; fall back to what
                // the authorization server offers, then to nothing (many
                // servers issue a full-access token without one).
                let scopes = metadata?.scopesSupported ?? server.scopesSupported ?? []
                return MCPOAuthEndpoint(
                    issuer: server.issuer.flatMap(URL.init(string:)) ?? issuer,
                    authorizationURL: authorizationURL,
                    tokenURL: tokenURL,
                    registrationURL: server.registrationEndpoint.flatMap(URL.init(string:)),
                    scopes: scopes
                )
            }
        }
        if let detail = lastError as? MCPOAuthError, case .discoveryFailed(let text) = detail {
            throw MCPOAuthError.discoveryFailed(text)
        }
        throw lastError
    }

    private func origin(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func fetchJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MCPOAuthError.discoveryFailed("\(url.host ?? url.absoluteString) answered HTTP \(response.statusCode)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MCPOAuthError.discoveryFailed("the document at \(url.lastPathComponent) wasn't readable")
        }
    }

    // MARK: Registration

    /// Registers TypstEdit with the authorization server (RFC 7591), unless
    /// the caller already has a client for it. Servers without a registration
    /// endpoint are given the empty client id some expect for a public
    /// client, so sign-in still has a chance.
    func registerClient(endpoint: MCPOAuthEndpoint, redirectURI: String, existing: MCPOAuthClient?) async throws -> MCPOAuthClient {
        if let existing, !existing.clientID.isEmpty { return existing }
        guard let registrationURL = endpoint.registrationURL else {
            return MCPOAuthClient(clientID: "", clientSecret: nil)
        }
        var request = URLRequest(url: registrationURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "client_name": MCPOAuthDiscovery.clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        if !endpoint.scopes.isEmpty { body["scope"] = endpoint.scopes.joined(separator: " ") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw MCPOAuthError.registrationFailed("HTTP \(response.statusCode)\(text.isEmpty ? "" : ": \(text)")")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String, !clientID.isEmpty else {
            throw MCPOAuthError.registrationFailed("the reply had no client_id")
        }
        return MCPOAuthClient(clientID: clientID, clientSecret: json["client_secret"] as? String)
    }

    // MARK: Sign-in

    /// Runs the whole interactive flow and returns usable credentials.
    ///
    /// `state` is checked on the redirect: an answer carrying a different
    /// state did not come from this attempt and is refused (CSRF).
    func signIn(
        serverName: String,
        resource: URL,
        endpoint: MCPOAuthEndpoint,
        existingClient: MCPOAuthClient?
    ) async throws -> MCPOAuthCredentials {
        guard endpoint.authorizationURL.scheme?.lowercased() == "https"
                || endpoint.authorizationURL.host == "127.0.0.1"
                || endpoint.authorizationURL.host == "localhost" else {
            throw MCPOAuthError.discoveryFailed("the authorization endpoint is not https")
        }

        let listener = try MCPLoopbackListener()
        let redirectURI = listener.redirectURI
        let client = try await registerClient(endpoint: endpoint, redirectURI: redirectURI, existing: existingClient)

        let verifier = PKCE.verifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.verifier(byteCount: 24)

        var components = URLComponents(url: endpoint.authorizationURL, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ])
        if !endpoint.scopes.isEmpty {
            query.append(URLQueryItem(name: "scope", value: endpoint.scopes.joined(separator: " ")))
        }
        // RFC 8707: name the resource the token is for, so an issuer serving
        // several APIs mints one for this server, not for another.
        query.append(URLQueryItem(name: "resource", value: resource.absoluteString))
        components.queryItems = query
        guard let authorizationURL = components.url else {
            throw MCPOAuthError.discoveryFailed("the authorization URL could not be built")
        }

        // One redirect, from the browser. Production: open it and wait on the
        // loopback listener. A test supplies `browser`, so the whole flow runs
        // with no network.
        let testBrowser = browser
        if testBrowser == nil, !openURL(authorizationURL) {
            listener.stop()
            throw MCPOAuthError.cancelled
        }

        // Race the browser against the timeout through one continuation that
        // exactly one of them finishes. A task group was wrong here: cancelling
        // the child that *waits* for the redirect does not cancel the wait
        // itself, so a browser that never answers kept the group open past the
        // timeout. Here the loser's result is discarded, and `listener.stop()`
        // ends any waiter still parked on the loopback.
        let redirect: URL
        do {
            redirect = try await withCheckedThrowingContinuation { continuation in
                let race = RedirectRace(continuation)
                Task { @MainActor in
                    do { race.finish(.success(try await self.awaitRedirect(authorizationURL: authorizationURL, listener: listener, testBrowser: testBrowser))) }
                    catch { race.finish(.failure(error)) }
                }
                let timeout = signInTimeout
                Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    race.finish(.failure(MCPOAuthError.timedOut))
                }
            }
        } catch {
            listener.stop()
            throw error
        }
        listener.stop()

        let items = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let errorCode = value("error") {
            throw MCPOAuthError.authorizationDenied([errorCode, value("error_description")].compactMap { $0 }.joined(separator: ": "))
        }
        guard value("state") == state else {
            throw MCPOAuthError.authorizationDenied("the reply did not match this sign-in attempt")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw MCPOAuthError.authorizationDenied("no authorization code came back")
        }

        let tokens = try await exchangeCode(
            code: code,
            verifier: verifier,
            redirectURI: redirectURI,
            client: client,
            endpoint: endpoint,
            resource: resource
        )
        return MCPOAuthCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresIn.map { now().addingTimeInterval($0) },
            tokenType: tokens.tokenType ?? "Bearer",
            scope: tokens.scope,
            client: client,
            tokenURL: endpoint.tokenURL,
            issuer: endpoint.issuer,
            resource: resource
        )
    }

    private func exchangeCode(
        code: String,
        verifier: String,
        redirectURI: String,
        client: MCPOAuthClient,
        endpoint: MCPOAuthEndpoint,
        resource: URL
    ) async throws -> MCPOAuthTokenResponse {
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "client_id": client.clientID,
            "resource": resource.absoluteString,
        ]
        if let secret = client.clientSecret { form["client_secret"] = secret }
        let (data, response) = try await http.send(formRequest(url: endpoint.tokenURL, form: form))
        guard (200..<300).contains(response.statusCode) else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw MCPOAuthError.tokenExchangeFailed("HTTP \(response.statusCode)\(text.isEmpty ? "" : ": \(text)")")
        }
        guard let tokens = try? JSONDecoder().decode(MCPOAuthTokenResponse.self, from: data) else {
            throw MCPOAuthError.tokenExchangeFailed("the reply had no access token")
        }
        return tokens
    }

    /// Renews an expired (or refused) access token. A server that does not
    /// rotate refresh tokens omits a new one; the old one stays valid.
    func refresh(_ credentials: MCPOAuthCredentials) async throws -> MCPOAuthCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw MCPOAuthError.refreshFailed("this server issued no refresh token")
        }
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.client.clientID,
            "resource": credentials.resource.absoluteString,
        ]
        if let secret = credentials.client.clientSecret { form["client_secret"] = secret }
        let (data, response) = try await http.send(formRequest(url: credentials.tokenURL, form: form))
        guard (200..<300).contains(response.statusCode) else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw MCPOAuthError.refreshFailed("HTTP \(response.statusCode)\(text.isEmpty ? "" : ": \(text)")")
        }
        guard let tokens = try? JSONDecoder().decode(MCPOAuthTokenResponse.self, from: data) else {
            throw MCPOAuthError.refreshFailed("the reply had no access token")
        }
        var updated = credentials
        updated.accessToken = tokens.accessToken
        updated.refreshToken = tokens.refreshToken ?? credentials.refreshToken
        updated.expiresAt = tokens.expiresIn.map { now().addingTimeInterval($0) }
        updated.tokenType = tokens.tokenType ?? credentials.tokenType
        updated.scope = tokens.scope ?? credentials.scope
        return updated
    }

    private func awaitRedirect(
        authorizationURL: URL,
        listener: MCPLoopbackListener,
        testBrowser: (@MainActor (URL) async throws -> URL)?
    ) async throws -> URL {
        if let testBrowser { return try await testBrowser(authorizationURL) }
        return try await listener.waitForRedirect()
    }

    private func formRequest(url: URL, form: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }
}

// MARK: - Storage

/// Completes a checked continuation exactly once, whichever of the two racers
/// (the browser, the timeout) gets there first. A second finish is dropped, so
/// a late timeout cannot crash the process with a double resume.
final class RedirectRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let waiter = continuation
        continuation = nil
        lock.unlock()
        guard let waiter else { return }
        switch result {
        case .success(let url): waiter.resume(returning: url)
        case .failure(let error): waiter.resume(throwing: error)
        }
    }
}

/// The registered client id for one server, cached in the Keychain next to
/// its tokens so a re-sign-in reuses it instead of registering again. A
/// secret, like the tokens: it is only useful with the redirect URI.
@MainActor
final class MCPOAuthClientStore {
    private let read: (String) -> String?
    private let write: (String, String) -> Void

    init(
        read: @escaping (String) -> String? = MCPKeychain.read(key:),
        write: @escaping (String, String) -> Void = MCPKeychain.write(key:value:)
    ) {
        self.read = read
        self.write = write
    }

    private func key(_ serverName: String) -> String { "oauth-client:" + serverName }

    func load(serverName: String) -> MCPOAuthClient? {
        guard let raw = read(key(serverName)), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MCPOAuthClient.self, from: data)
    }

    func save(_ client: MCPOAuthClient, serverName: String) {
        guard let data = try? JSONEncoder().encode(client),
              let text = String(data: data, encoding: .utf8) else { return }
        write(key(serverName), text)
    }
}

/// Tokens and the registered client, one entry per MCP server, in the macOS
/// Keychain. Never in `mcp.json`: that file is meant to be shareable.
@MainActor
final class MCPOAuthStore {
    let keyPrefix: String
    private let read: (String) -> String?
    private let write: (String, String) -> Void
    private let remove: (String) -> Void

    init(
        keyPrefix: String = "oauth:",
        read: @escaping (String) -> String? = MCPKeychain.read(key:),
        write: @escaping (String, String) -> Void = MCPKeychain.write(key:value:),
        remove: @escaping (String) -> Void = MCPKeychain.delete(key:)
    ) {
        self.keyPrefix = keyPrefix
        self.read = read
        self.write = write
        self.remove = remove
    }

    private func key(_ serverName: String) -> String { keyPrefix + serverName }

    func load(serverName: String) -> MCPOAuthCredentials? {
        guard let raw = read(key(serverName)), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MCPOAuthCredentials.self, from: data)
    }

    func save(_ credentials: MCPOAuthCredentials, serverName: String) {
        guard let data = try? JSONEncoder().encode(credentials),
              let text = String(data: data, encoding: .utf8) else { return }
        write(key(serverName), text)
    }

    func delete(serverName: String) {
        remove(key(serverName))
    }
}
