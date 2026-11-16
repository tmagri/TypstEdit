import XCTest
@testable import TypstEdit

/// Signed-in sites for `web_fetch`: which cookies are sent, to which host,
/// and over which scheme. Pure cookie logic — no Keychain, no network.
final class WebSiteSessionTests: XCTestCase {

    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil) -> StoredCookie {
        StoredCookie(name: name, value: "v-\(name)", domain: domain, path: path, isSecure: secure, expiresAt: expires)
    }

    private func session(_ cookies: [StoredCookie], host: String = "example.com") -> WebSiteSession {
        WebSiteSession(host: host, cookies: cookies, savedAt: Date(), accountLabel: nil)
    }

    // MARK: - Domain matching

    func testCookieDomainMatchesLabelBoundaries() {
        XCTAssertTrue(cookie("a", domain: "example.com").domainMatches(requestHost: "example.com"))
        XCTAssertTrue(cookie("a", domain: "example.com").domainMatches(requestHost: "www.example.com"))
        XCTAssertTrue(cookie("a", domain: ".example.com").domainMatches(requestHost: "www.example.com"))
        XCTAssertFalse(cookie("a", domain: "example.com").domainMatches(requestHost: "notexample.com"),
                       "a suffix that is not a label boundary must not match")
        XCTAssertFalse(cookie("a", domain: "example.com").domainMatches(requestHost: "example.com.evil.test"))
    }

    // MARK: - The Cookie header

    func testHeaderJoinsOnlyApplicableCookies() {
        let store = session([
            cookie("session", domain: "example.com"),
            cookie("admin", domain: "admin.example.com"),
            cookie("other", domain: "elsewhere.test"),
        ])
        let header = store.cookieHeader(for: URL(string: "https://example.com/page")!)
        XCTAssertEqual(header, "session=v-session")
    }

    func testSecureCookieIsNotSentOverHTTP() {
        let store = session([cookie("session", domain: "example.com", secure: true)])
        XCTAssertNil(store.cookieHeader(for: URL(string: "http://example.com/")!))
        XCTAssertNotNil(store.cookieHeader(for: URL(string: "https://example.com/")!))
    }

    func testNonSecureCookieIsSentOverEitherScheme() {
        let store = session([cookie("plain", domain: "example.com", secure: false)])
        XCTAssertNotNil(store.cookieHeader(for: URL(string: "http://example.com/")!))
        XCTAssertNotNil(store.cookieHeader(for: URL(string: "https://example.com/")!))
    }

    func testPathPrefixMustMatch() {
        let store = session([cookie("scoped", domain: "example.com", path: "/app")])
        XCTAssertNil(store.cookieHeader(for: URL(string: "https://example.com/")!))
        XCTAssertNotNil(store.cookieHeader(for: URL(string: "https://example.com/app/page")!))
    }

    func testExpiredCookieIsSkipped() {
        let store = session([cookie("gone", domain: "example.com", expires: Date(timeIntervalSinceNow: -60))])
        XCTAssertNil(store.cookieHeader(for: URL(string: "https://example.com/")!))
    }

    func testSessionCookieWithoutExpiryIsUsable() {
        let store = session([cookie("fresh", domain: "example.com", expires: nil)])
        XCTAssertNotNil(store.cookieHeader(for: URL(string: "https://example.com/")!))
    }

    // MARK: - Auth-need wording

    func testSignedOutAndExpiredReadDifferently() {
        let signedOut = WebAuthNeed.signedOut(status: 401).modelMessage
        let expired = WebAuthNeed.expired(status: 403).modelMessage
        XCTAssertTrue(signedOut.contains("no saved session"))
        XCTAssertTrue(expired.contains("expired"))
        XCTAssertNotEqual(signedOut, expired)
    }

    // MARK: - Sign-in address

    func testBareHostGetsHTTPS() {
        XCTAssertEqual(WebSignInAddress.resolve("jira.example.com")?.absoluteString, "https://jira.example.com")
    }

    func testExplicitSchemeIsHonoured() {
        XCTAssertEqual(WebSignInAddress.resolve("http://intranet.local")?.absoluteString, "http://intranet.local")
    }

    func testTypedPathStartsAtHostRoot() {
        XCTAssertEqual(WebSignInAddress.resolve("example.com", path: "login")?.absoluteString, "https://example.com/login")
        XCTAssertEqual(WebSignInAddress.resolve("example.com", path: "/login")?.absoluteString, "https://example.com/login")
    }

    func testEmptyAddressIsRejected() {
        XCTAssertNil(WebSignInAddress.resolve("   "))
    }
}
