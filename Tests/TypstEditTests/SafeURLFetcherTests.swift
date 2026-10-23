import XCTest
@testable import TypstEdit

/// The SSRF guard behind `web_fetch` (`SafeURLFetcher`) and the tool's
/// argument/approval/allowlist behavior in `LocalToolExecutor`. The
/// address-classification tests are pure and offline; the end-to-end fetch
/// test needs internet and skips-in-principle on failure of the environment,
/// not the code (see the guard in the test itself).
@MainActor
final class SafeURLFetcherTests: XCTestCase {

    // MARK: - Address classification (offline, security-critical)

    func testPrivateAndLoopbackIPv4AreBlocked() {
        for blocked in ["127.0.0.1", "127.9.9.9", "10.1.2.3", "172.16.0.1", "172.31.255.255",
                        "192.168.1.1", "169.254.169.254", "0.0.0.0", "100.64.1.1",
                        "224.0.0.1", "255.255.255.255", "192.0.2.1", "198.51.100.7", "203.0.113.9"] {
            XCTAssertFalse(SafeURLFetcher.isPublicAddress(blocked), "\(blocked) must be blocked")
        }
    }

    func testPublicIPv4IsAllowed() {
        for allowed in ["1.1.1.1", "8.8.8.8", "93.184.216.34", "172.32.0.1", "100.128.0.1"] {
            XCTAssertTrue(SafeURLFetcher.isPublicAddress(allowed), "\(allowed) must be allowed")
        }
    }

    func testIPv6SpecialRangesAreBlocked() {
        for blocked in ["::1", "::", "fe80::1", "fc00::1", "fd12:3456:789a::1",
                        "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "2001:db8::1"] {
            XCTAssertFalse(SafeURLFetcher.isPublicAddress(blocked), "\(blocked) must be blocked")
        }
    }

    func testPublicIPv6IsAllowed() {
        for allowed in ["2606:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8"] {
            XCTAssertTrue(SafeURLFetcher.isPublicAddress(allowed), "\(allowed) must be allowed")
        }
    }

    // MARK: - web_fetch tool behavior

    @discardableResult
    private func run(_ tool: String, _ args: [String: Any], approve: Bool = true) async throws -> String {
        try await executor.execute(toolName: tool, arguments: args) { _ in approve }
    }

    func testWebFetchThrowsWhenToolDisabled() async {
        // Defaults to disabled — the whole tool must refuse even if the model
        // hallucinates a call before the user opted in.
        executor.webFetchToolEnabled = false
        do {
            _ = try await run("web_fetch", ["url": "https://example.com"], approve: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't enabled"), error.localizedDescription)
        }
    }

    func testWebFetchRejectsNonHTTPSchemeWithoutApproval() async throws {
        executor.webFetchToolEnabled = true
        // approve: false proves the scheme check happens *before* any approval.
        do {
            _ = try await run("web_fetch", ["url": "ftp://example.com/file.txt"], approve: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("http/https"), error.localizedDescription)
        }
    }

    func testWebFetchRefusesLoopbackWithoutApproval() async throws {
        executor.webFetchToolEnabled = true
        // Literal loopback IP — no DNS needed, so this stays offline.
        do {
            _ = try await run("web_fetch", ["url": "http://127.0.0.1:9/x"], approve: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("private, loopback"), error.localizedDescription)
        }
    }

    func testWebFetchRefusesPrivateIPv6Literal() async throws {
        executor.webFetchToolEnabled = true
        do {
            _ = try await run("web_fetch", ["url": "http://[::1]:9/x"], approve: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("private, loopback"), error.localizedDescription)
        }
    }

    func testWebFetchEnforcesTheDomainAllowlist() async throws {
        executor.webFetchToolEnabled = true
        executor.allowedWebFetchDomains = ["example.com", "*.wikipedia.org"]

        do {
            _ = try await run("web_fetch", ["url": "https://other.org/page"], approve: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't in web_fetch's allowed domains"), error.localizedDescription)
        }

        // Wildcard subdomains are covered; the bare domain covers only itself.
        XCTAssertNil(LocalToolExecutor.domainAllowlistViolation(
            for: URL(string: "https://en.wikipedia.org/wiki/Typst")!,
            allowlist: ["*.wikipedia.org"]))
        XCTAssertNotNil(LocalToolExecutor.domainAllowlistViolation(
            for: URL(string: "https://wikipedia.org/")!,
            allowlist: ["*.wikipedia.org"]))
    }

    func testWebFetchFetchesAndConvertsARealPage() async throws {
        executor.webFetchToolEnabled = true
        let out = try await run("web_fetch", ["url": "https://example.com"], approve: true)
        XCTAssertTrue(out.contains("[fetched https://example.com"), out)
        // Assert on the page's stable purpose rather than exact copy, which
        // the owners of example.com can change at any time (and have).
        XCTAssertTrue(out.contains("documentation examples"), out)
    }

    // MARK: - Setup

    private var executor: LocalToolExecutor!

    override func setUp() async throws {
        executor = LocalToolExecutor()
        executor.scope = .project(root: FileManager.default.temporaryDirectory)
    }
}
