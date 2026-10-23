import Foundation
import Network

/// A URL fetcher hardened against SSRF for the AI Chat `web_fetch` tool.
///
/// The risk an agentic web-fetch tool introduces isn't really "the model
/// reads a web page" — it's that a local tool with network access can be
/// pointed at `http://169.254.169.254` (cloud instance metadata),
/// `http://localhost:9999` (some other app's unauthenticated admin port), or
/// anything else only reachable from this machine/network, and relay the
/// response back out. Every request this makes — including each redirect
/// hop, since a redirect is exactly how that check gets bypassed otherwise —
/// resolves the hostname and refuses to proceed unless every address it
/// resolves to is a plain, public, routable address.
///
/// This is a best-effort, defense-in-depth check, not a sandbox: it blocks
/// the well-known private/loopback/link-local/multicast ranges, not every
/// theoretical reserved block, and `web_fetch` itself stays behind an
/// explicit opt-in and a per-call approval regardless.
enum SafeURLFetcher {
    struct FetchedPage {
        let finalURL: URL
        let status: Int
        let contentType: String?
        let data: Data
    }

    enum FetchError: LocalizedError {
        case unsupportedScheme(String)
        case blockedAddress(String)
        case tooManyRedirects
        case crossHostRedirect(from: URL, to: URL)
        case tooLarge(Int)
        case http(Int, String)
        case dns(String)
        case noResponse

        var errorDescription: String? {
            switch self {
            case .unsupportedScheme(let scheme):
                return "Only http/https URLs can be fetched (got '\(scheme)')."
            case .blockedAddress(let host):
                return "'\(host)' resolves to a private, loopback, link-local, or other non-public address — refusing to fetch it. web_fetch only reaches the public internet."
            case .tooManyRedirects:
                return "Too many redirects."
            case .crossHostRedirect(let from, let to):
                return "'\(from.absoluteString)' redirects to a different host:\n\(to.absoluteString)\n\nCross-host redirects aren't followed automatically — call web_fetch again with that URL if you trust it."
            case .tooLarge(let bytes):
                return "Response exceeded the \(bytes)-byte cap."
            case .http(let code, let message):
                return "HTTP \(code): \(message)"
            case .dns(let host):
                return "Could not resolve '\(host)'."
            case .noResponse:
                return "No HTTP response."
            }
        }
    }

    private static let userAgent = "TypstEdit/AI-Chat-web_fetch (+https://github.com/tmagri/TypstEdit)"

    /// Fetches `url`, following same-host redirects — re-validating the
    /// destination address on every hop — and stopping, without following,
    /// the moment a redirect would leave the original host.
    static func fetch(_ url: URL, timeout: TimeInterval = 20, maxBytes: Int = 5_000_000, maxRedirects: Int = 5) async throws -> FetchedPage {
        var currentURL = url
        var hopsLeft = maxRedirects
        let delegate = RedirectBlockingDelegate()

        while true {
            try validate(currentURL)

            var request = URLRequest(url: currentURL)
            request.timeoutInterval = timeout
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html, application/xhtml+xml, text/plain, application/json;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")

            let data: Data
            let response: URLResponse
            (data, response) = try await URLSession.shared.data(for: request, delegate: delegate)

            guard let http = response as? HTTPURLResponse else {
                throw FetchError.noResponse
            }

            if (300...399).contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let redirectURL = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    throw FetchError.http(http.statusCode, "redirect with no Location header")
                }
                guard hopsLeft > 0 else { throw FetchError.tooManyRedirects }
                hopsLeft -= 1
                guard redirectURL.host?.lowercased() == currentURL.host?.lowercased() else {
                    throw FetchError.crossHostRedirect(from: currentURL, to: redirectURL)
                }
                currentURL = redirectURL
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                throw FetchError.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            }
            if let lengthHeader = http.value(forHTTPHeaderField: "Content-Length"), let declared = Int(lengthHeader), declared > maxBytes {
                throw FetchError.tooLarge(maxBytes)
            }
            guard data.count <= maxBytes else {
                throw FetchError.tooLarge(maxBytes)
            }
            return FetchedPage(finalURL: currentURL, status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), data: data)
        }
    }

    /// Scheme + SSRF validation, exposed separately so a caller can reject an
    /// obviously-unsafe request *before* showing an approval prompt for it —
    /// no point asking the user to approve something that's always going to
    /// be refused.
    static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FetchError.unsupportedScheme(url.scheme ?? "(none)")
        }
        guard let host = url.host, !host.isEmpty else {
            throw FetchError.dns(url.absoluteString)
        }
        let lowerHost = host.lowercased()
        if lowerHost == "localhost" || lowerHost.hasSuffix(".local") || lowerHost.hasSuffix(".localhost") {
            throw FetchError.blockedAddress(host)
        }
        let addresses = try resolveAddresses(for: host)
        guard !addresses.isEmpty else { throw FetchError.dns(host) }
        for address in addresses where !isPublicAddress(address) {
            throw FetchError.blockedAddress(host)
        }
    }

    // MARK: - Redirect handling

    /// Blocks `URLSession`'s automatic redirect following so `fetch` can
    /// inspect and re-validate the `Location` header itself before ever
    /// requesting it — an unvalidated auto-follow is exactly how a
    /// scheme/host check at the start of a request gets bypassed.
    private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    // MARK: - DNS resolution + address classification

    private static func resolveAddresses(for host: String) throws -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &resultPointer)
        guard status == 0, let first = resultPointer else {
            throw FetchError.dns(host)
        }
        defer { freeaddrinfo(resultPointer) }

        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let info = pointer {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            pointer = info.pointee.ai_next
        }
        return addresses
    }

    /// True for a routable, public unicast address — false for loopback,
    /// RFC1918 private ranges, link-local (including the
    /// `169.254.169.254` cloud-metadata address), carrier-grade NAT,
    /// multicast/reserved, and their IPv6 equivalents (including
    /// IPv4-mapped IPv6, unwrapped and checked against the same IPv4 rules).
    static func isPublicAddress(_ address: String) -> Bool {
        if let v4 = IPv4Address(address) {
            return isPublicIPv4(v4.rawValue)
        }
        if let v6 = IPv6Address(address) {
            let bytes = [UInt8](v6.rawValue)
            guard bytes.count == 16 else { return false }
            // IPv4-mapped (::ffff:a.b.c.d): unwrap and apply the IPv4 rules.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isPublicIPv4(Data(bytes[12...15]))
            }
            return isPublicIPv6(bytes)
        }
        return false
    }

    private static func isPublicIPv4(_ data: Data) -> Bool {
        guard data.count == 4 else { return false }
        let b = [UInt8](data)
        if b[0] == 0 { return false }                                   // 0.0.0.0/8 "this network"
        if b[0] == 10 { return false }                                  // 10.0.0.0/8 private
        if b[0] == 100, (64...127).contains(b[1]) { return false }      // 100.64.0.0/10 CGNAT
        if b[0] == 127 { return false }                                 // 127.0.0.0/8 loopback
        if b[0] == 169, b[1] == 254 { return false }                    // 169.254.0.0/16 link-local (incl. cloud metadata)
        if b[0] == 172, (16...31).contains(b[1]) { return false }       // 172.16.0.0/12 private
        if b[0] == 192, b[1] == 168 { return false }                    // 192.168.0.0/16 private
        if b[0] == 192, b[1] == 0, b[2] == 0 { return false }           // 192.0.0.0/24 IETF protocol assignments
        if b[0] == 192, b[1] == 0, b[2] == 2 { return false }           // 192.0.2.0/24 documentation
        if b[0] == 198, (18...19).contains(b[1]) { return false }       // 198.18.0.0/15 benchmarking
        if b[0] == 198, b[1] == 51, b[2] == 100 { return false }        // 198.51.100.0/24 documentation
        if b[0] == 203, b[1] == 0, b[2] == 113 { return false }         // 203.0.113.0/24 documentation
        if b[0] >= 224 { return false }                                  // 224.0.0.0/4 multicast, 240.0.0.0/4 reserved, broadcast
        return true
    }

    private static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        if b.allSatisfy({ $0 == 0 }) { return false }                            // :: unspecified
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }      // ::1 loopback
        if (b[0] & 0xfe) == 0xfc { return false }                               // fc00::/7 unique local
        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return false }                 // fe80::/10 link-local
        if b[0] == 0xff { return false }                                       // ff00::/8 multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return false } // 2001:db8::/32 documentation
        return true
    }
}
