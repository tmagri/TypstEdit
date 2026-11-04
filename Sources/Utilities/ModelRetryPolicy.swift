import Foundation

/// Backoff policy for provider requests that failed for a reason that is
/// worth another try — a rate limit, an overloaded endpoint, a dropped
/// connection — as opposed to one that will fail the same way every time
/// (bad credentials, an unknown model, a malformed request).
///
/// Modelled on opencode's `model-retry`: exponential growth capped per gap,
/// jitter so several chats don't retry in lockstep, and a provider-supplied
/// `retry-after` treated as a floor rather than an override — a hostile or
/// buggy header must not park a request for hours, so it is clamped.
///
/// The important restriction is *when* this may be used. A retry re-sends the
/// whole request, so it is only safe while nothing has been shown to the user
/// yet: before the HTTP status is known to be 200, and before any streamed
/// token has been forwarded. Once output exists, resuming is the
/// auto-continue path's job, not this one's.
enum ModelRetryPolicy {

    /// Attempts after the first, by default. Five retries spread over roughly
    /// 30 seconds covers the usual rate-limit blip and a briefly overloaded
    /// endpoint without leaving the user staring at nothing for minutes.
    static let defaultRetries = 5
    /// Hard upper bound, so a fat-fingered setting can't retry forever.
    static let maxRetries = 12

    /// The base gap. Doubles per attempt (2, 4, 8, 16…).
    static let baseDelay: TimeInterval = 2
    /// The gap never grows past this, so a long outage still retries regularly
    /// instead of sleeping for minutes.
    static let maxDelay: TimeInterval = 10
    /// A provider's `retry-after` is trusted up to this, then ignored as
    /// pathological.
    static let maxRetryAfter: TimeInterval = 15 * 60

    /// Whether a response status is worth retrying.
    ///
    /// 429 is a rate limit; 408 a request timeout; 5xx are the endpoint's own
    /// failures — including the 529 that Anthropic and Cloudflare use for
    /// "overloaded". Everything else (400, 401, 403, 404, 422, …) is a request
    /// or account problem that a retry would repeat exactly.
    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    /// Whether a `URLError` represents a connection-level problem that might
    /// not recur. A cancelled or timed-out request is excluded: cancellation
    /// is the user's Stop, and a timeout already waits minutes before failing.
    static func isRetryable(urlError code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotFindHost, .resourceUnavailable,
             .badServerResponse, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Whether a `URLError` unambiguously means this machine lost its own
    /// network — what a dropped Wi-Fi, a dead VPN, or a pulled cable produce.
    /// macOS can take a moment to retract a satisfied path after a drop, so
    /// these are worth waiting on even when the path monitor still claims a
    /// link. Backoff retries against a dead link burn the whole retry budget
    /// inside a minute; a wait actually survives the outage.
    static func isConnectivityLoss(code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Whether a `URLError` could be either a lost network or a dead endpoint
    /// — a failed DNS lookup and an unreachable host are both sides of that
    /// line. These wait only when the system currently reports no path at
    /// all, so a typo'd host or an offline server fails through the retry
    /// budget instead of parking the request forever.
    static func mayBeConnectivityLoss(code: URLError.Code) -> Bool {
        switch code {
        case .dnsLookupFailed, .cannotFindHost, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    /// The line shown while a request is parked for a lost network, counting
    /// the wait so a long outage still looks alive rather than hung.
    static func offlineWaitStatusLine(seconds: Int) -> String {
        let readable = seconds < 60
            ? "\(seconds)s"
            : "\(seconds / 60)m \(seconds % 60)s"
        return "Network lost — waiting for the connection to come back (\(readable))…"
    }

    /// Gap before attempt `attempt` (1-based: 1 is the first retry).
    ///
    /// `retryAfter` is a floor; `jitter` is a multiplier in `0.5...1.5` so
    /// callers can spread retries out instead of synchronising them. Pure and
    /// injectable so the schedule is directly testable.
    static func delay(
        forAttempt attempt: Int,
        retryAfter: TimeInterval? = nil,
        jitter: Double = 1
    ) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let base = min(maxDelay, baseDelay * pow(2, Double(exponent)))
        let floor = retryAfter.map { min(max(0, $0), maxRetryAfter) } ?? 0
        let jittered = base * jitter
        return max(floor, jittered)
    }

    /// Retries actually allowed for a configured value, clamped so a typo
    /// can't turn a dead provider into an unbounded request loop.
    static func effectiveRetries(_ configured: Int) -> Int {
        min(max(configured, 0), maxRetries)
    }

    /// Reads `Retry-After` from a response. The header is either a number of
    /// seconds or an HTTP date; anything else is ignored.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        if let seconds = TimeInterval(raw) {
            return seconds >= 0 ? seconds : nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    /// The line shown in the chat's generating row while it waits, so a silent
    /// pause is explained instead of looking like a hang.
    static func statusLine(attempt: Int, retries: Int, delay: TimeInterval, reason: String) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return "\(reason) — retrying in \(seconds)s (attempt \(attempt + 1) of \(retries + 1))…"
    }

    /// A short human reason for a retryable status.
    static func reason(forStatus status: Int) -> String {
        switch status {
        case 408: return "The request timed out at the provider"
        case 429: return "Rate limited by the provider"
        case 529, 503: return "The provider is overloaded"
        default: return "The provider returned an error (\(status))"
        }
    }
}
