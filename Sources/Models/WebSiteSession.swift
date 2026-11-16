import Foundation
import Security

/// One cookie captured from a sign-in, in the shape the Keychain can hold.
///
/// `HTTPCookie` is not `Codable`, and its `properties` dictionary mixes
/// `String`/`Number`/`Date` values that do not survive a round trip cleanly,
/// so the four fields that decide whether a cookie is *sent* are stored
/// explicitly: which hosts it belongs to, which paths, whether it is
/// https-only, and when it dies.
struct StoredCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    /// The `Domain` attribute, lowercased. WebKit reports a host-only cookie
    /// with the bare host and a domain cookie with a leading dot; both are
    /// kept as reported, because the dot is a hint the site chose.
    var domain: String
    var path: String
    var isSecure: Bool
    /// nil for a session cookie. Replayed from a fresh request each time, so
    /// a cookie without an expiry is as usable as its browser counterpart
    /// until the site refuses it.
    var expiresAt: Date?

    init(name: String, value: String, domain: String, path: String, isSecure: Bool, expiresAt: Date? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.expiresAt = expiresAt
    }

    init(cookie: HTTPCookie) {
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain.lowercased(),
            path: cookie.path.isEmpty ? "/" : cookie.path,
            isSecure: cookie.isSecure,
            expiresAt: cookie.expiresDate
        )
    }

    /// Whether this cookie may be sent to `requestHost`.
    ///
    /// The match is on dot-separated label boundaries, so `example.com`
    /// covers `www.example.com` but never `notexample.com` or
    /// `example.com.evil.test`.
    func domainMatches(requestHost: String) -> Bool {
        let host = requestHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let cookieDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !cookieDomain.isEmpty else { return false }
        return host == cookieDomain || host.hasSuffix("." + cookieDomain)
    }
}

/// Why a site needs a human: the words the model can act on, and the copy
/// Settings shows.
enum WebAuthNeed: Equatable {
    /// Nothing saved and the server refused. Only a sign-in can fix it.
    case signedOut(status: Int)
    /// A saved session exists but the server still refused it: the site
    /// expired it, so the answer is "sign in again", not "sign in".
    case expired(status: Int)

    var modelMessage: String {
        switch self {
        case .signedOut(let status):
            return "The page needs a sign-in (HTTP \(status)) and no saved session exists for this site. Ask the user to sign in to that site in Settings → AI Chat → Signed-in sites, then retry."
        case .expired(let status):
            return "The page refused the saved sign-in (HTTP \(status)), so the site's session has expired. Ask the user to sign in to that site again in Settings → AI Chat → Signed-in sites, then retry."
        }
    }
}

/// One site the user signed in to, and the cookies that sign-in produced.
///
/// This is deliberately *not* a password store. TypstEdit never sees the
/// password: the user types it into the site itself, inside a WebKit view
/// with its own empty cookie jar, and only the resulting session cookies are
/// kept. When the site expires them, the fetch says so and the user signs in
/// again — nothing here can reconstruct a credential the user did not
/// already hold.
struct WebSiteSession: Codable, Equatable, Sendable {
    /// The host the user signed in to (`jira.example.com`), lowercased.
    var host: String
    var cookies: [StoredCookie]
    var savedAt: Date
    /// What the site called the account, when the login page said so. Shown
    /// in Settings only; it never changes what is sent.
    var accountLabel: String?

    /// The `Cookie` header value for `url`, or nil when no cookie applies.
    ///
    /// The same rules a browser applies: `Secure` cookies only over https,
    /// the path prefix must match, and expired cookies are skipped.
    func cookieHeader(for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let usable = cookies.filter { cookie in
            guard cookie.domainMatches(requestHost: host) else { return false }
            guard requestPath.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path) else { return false }
            if cookie.isSecure, scheme != "https" { return false }
            if let expiresAt = cookie.expiresAt, expiresAt <= now { return false }
            return true
        }
        guard !usable.isEmpty else { return nil }
        return usable.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Where signed-in sites live: the macOS Keychain, one entry per host, never
/// in `UserDefaults` and never in a file.
///
/// The account key is the host, so signing in again to the same site replaces
/// its cookies instead of piling up entries. Read/write/remove are injected
/// so tests can run without touching the real Keychain.
@MainActor
final class WebSessionStore: ObservableObject {
    static let shared = WebSessionStore()

    /// Bumped whenever a site is saved or removed, so Settings redraws without
    /// re-reading the Keychain on every render.
    @Published private(set) var revision = 0

    private let read: (String) -> String?
    private let write: (String, String) -> Void
    private let remove: (String) -> Void
    /// Non-secret index of the hosts that have an entry, kept in defaults so
    /// Settings can list them without enumerating the Keychain. Losing it
    /// costs only the list: a lookup by host reads the Keychain directly.
    private let hostsKey = "webSessionHosts"

    init(
        read: @escaping (String) -> String? = WebSessionKeychain.read,
        write: @escaping (String, String) -> Void = WebSessionKeychain.write,
        remove: @escaping (String) -> Void = WebSessionKeychain.delete
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    // MARK: - Storage

    func save(_ session: WebSiteSession) {
        // Normalise once, here: the Keychain account, the host index, and the
        // session's own `host` must agree, or a lookup by one spelling misses
        // a save made under another.
        var normalized = session
        normalized.host = session.host.lowercased()
        guard let data = try? JSONEncoder().encode(normalized),
              let text = String(data: data, encoding: .utf8) else { return }
        write(normalized.host, text)
        remember(host: normalized.host)
        revision += 1
    }

    func remove(host: String) {
        remove(host.lowercased())
        forget(host: host)
        revision += 1
    }

    /// Wipes every saved site ("Sign out of all sites").
    func removeAll() {
        for host in rememberedHosts() { remove(host: host) }
        UserDefaults.standard.removeObject(forKey: hostsKey)
        revision += 1
    }

    func load(host: String) -> WebSiteSession? {
        guard let raw = read(host.lowercased()),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WebSiteSession.self, from: data)
    }

    /// Every stored site, most recently saved first — what Settings lists.
    func allSessions() -> [WebSiteSession] {
        rememberedHosts()
            .compactMap { load(host: $0) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: - Lookup

    /// The saved session that answers for `host`, walking parent domains so a
    /// sign-in on `example.com` also covers `wiki.example.com`.
    ///
    /// The most specific saved host wins: signing in separately to
    /// `admin.example.com` is not overridden by the parent's session.
    func session(forHost host: String) -> WebSiteSession? {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !lower.isEmpty else { return nil }
        var labels = lower.split(separator: ".").map(String.init)
        while labels.count > 1 {
            if let session = load(host: labels.joined(separator: ".")), !session.cookies.isEmpty {
                return session
            }
            labels.removeFirst()
        }
        // A single-label host (an intranet name) is a valid exact match.
        return load(host: lower).flatMap { $0.cookies.isEmpty ? nil : $0 }
    }

    /// The `Cookie` header to replay for `url`, if any saved site applies.
    func cookieHeader(for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host else { return nil }
        return session(forHost: host)?.cookieHeader(for: url, now: now)
    }

    /// Whether a cookie-bearing session exists for the URL's host, without
    /// revealing the cookies (for the approval card's wording).
    func hasSession(for url: URL) -> Bool {
        cookieHeader(for: url) != nil
    }

    // MARK: - Host index

    private func rememberedHosts() -> [String] {
        UserDefaults.standard.stringArray(forKey: hostsKey) ?? []
    }

    private func remember(host: String) {
        let lower = host.lowercased()
        var hosts = rememberedHosts()
        guard !hosts.contains(lower) else { return }
        hosts.append(lower)
        UserDefaults.standard.set(hosts, forKey: hostsKey)
    }

    private func forget(host: String) {
        let lower = host.lowercased()
        UserDefaults.standard.set(rememberedHosts().filter { $0 != lower }, forKey: hostsKey)
    }
}

/// The smallest Keychain wrapper this file needs. Separate from `MCPKeychain`
/// on purpose: MCP tokens and web sessions are different trust domains, and
/// the service name is the boundary the user sees in Keychain Access.
enum WebSessionKeychain {
    private static let service = "com.tmagri.TypstEdit.WebSessions"

    static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let query = base(account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
