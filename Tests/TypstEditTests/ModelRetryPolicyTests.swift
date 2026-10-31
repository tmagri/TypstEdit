import XCTest
@testable import TypstEdit

/// The backoff policy for provider requests that failed before any output
/// arrived: what is worth retrying, how long to wait, and how a provider's
/// `Retry-After` is respected without letting it park a request for hours.
final class ModelRetryPolicyTests: XCTestCase {

    // MARK: - What is retryable

    func testRateLimitAndServerErrorsAreRetryable() {
        XCTAssertTrue(ModelRetryPolicy.isRetryable(status: 429))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(status: 408))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(status: 500))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(status: 502))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(status: 503))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(status: 529))
    }

    func testRequestAndAccountErrorsAreNotRetryable() {
        // These fail identically on a second attempt, so retrying only delays
        // telling the user what to fix.
        for status in [400, 401, 403, 404, 413, 422] {
            XCTAssertFalse(ModelRetryPolicy.isRetryable(status: status), "\(status) should not retry")
        }
    }

    func testConnectionErrorsAreRetryableButCancellationIsNot() {
        XCTAssertTrue(ModelRetryPolicy.isRetryable(urlError: .cannotConnectToHost))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(urlError: .networkConnectionLost))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(urlError: .notConnectedToInternet))
        XCTAssertTrue(ModelRetryPolicy.isRetryable(urlError: .dnsLookupFailed))
        XCTAssertFalse(ModelRetryPolicy.isRetryable(urlError: .cancelled))
        XCTAssertFalse(ModelRetryPolicy.isRetryable(urlError: .timedOut))
    }

    // MARK: - Delay

    func testDelayGrowsExponentiallyThenCaps() {
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 1), 2)
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 2), 4)
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 3), 8)
        // Capped, so a long outage keeps retrying rather than sleeping minutes.
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 4), 10)
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 10), 10)
    }

    func testDelayNeverGoesBelowTheFloor() {
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 0), 2)
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: -3), 2)
    }

    func testRetryAfterActsAsAFloor() {
        // A provider asking for 30 s wins over the 2 s base.
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 1, retryAfter: 30), 30)
        // A smaller value does not shorten the schedule.
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 3, retryAfter: 1), 8)
    }

    func testRetryAfterIsClampedAgainstAJeckyllHeader() {
        // A hostile or buggy header must not stall a request for hours.
        XCTAssertEqual(
            ModelRetryPolicy.delay(forAttempt: 1, retryAfter: 60 * 60 * 24),
            ModelRetryPolicy.maxRetryAfter
        )
    }

    func testNegativeRetryAfterIsIgnored() {
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 1, retryAfter: -5), 2)
    }

    func testJitterScalesTheSchedule() {
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 2, jitter: 0.5), 2)
        XCTAssertEqual(ModelRetryPolicy.delay(forAttempt: 2, jitter: 1.5), 6)
    }

    // MARK: - Clamping

    func testEffectiveRetriesAreClamped() {
        XCTAssertEqual(ModelRetryPolicy.effectiveRetries(-4), 0)
        XCTAssertEqual(ModelRetryPolicy.effectiveRetries(0), 0)
        XCTAssertEqual(ModelRetryPolicy.effectiveRetries(3), 3)
        XCTAssertEqual(ModelRetryPolicy.effectiveRetries(999), ModelRetryPolicy.maxRetries)
    }

    func testDefaultRetriesIsWithinTheBound() {
        XCTAssertLessThanOrEqual(ModelRetryPolicy.defaultRetries, ModelRetryPolicy.maxRetries)
        XCTAssertGreaterThan(ModelRetryPolicy.defaultRetries, 0)
    }

    // MARK: - Retry-After parsing

    func testRetryAfterParsesSeconds() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "42"]
        ))
        XCTAssertEqual(ModelRetryPolicy.retryAfter(from: response), 42)
    }

    func testRetryAfterParsesAnHTTPDate() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let inOneMinute = Date().addingTimeInterval(60)

        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: inOneMinute)]
        ))
        let parsed = try XCTUnwrap(ModelRetryPolicy.retryAfter(from: response))
        XCTAssertEqual(parsed, 60, accuracy: 5)
    }

    func testRetryAfterIsNilWhenAbsentOrUnparseable() throws {
        let absent = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        ))
        XCTAssertNil(ModelRetryPolicy.retryAfter(from: absent))

        let garbage = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "soon"]
        ))
        XCTAssertNil(ModelRetryPolicy.retryAfter(from: garbage))
    }

    // MARK: - Status line

    func testStatusLineNamesTheAttemptAndWaitsOneBased() {
        let line = ModelRetryPolicy.statusLine(
            attempt: 1,
            retries: 4,
            delay: 4,
            reason: "Rate limited by the provider"
        )
        XCTAssertTrue(line.contains("Rate limited by the provider"), line)
        XCTAssertTrue(line.contains("retrying in 4s"), line)
        // attempt 1 is the first retry, so this is attempt 2 of 5.
        XCTAssertTrue(line.contains("attempt 2 of 5"), line)
    }

    func testStatusLineRoundsASubSecondWaitUpToOne() {
        let line = ModelRetryPolicy.statusLine(attempt: 1, retries: 4, delay: 0.2, reason: "x")
        XCTAssertTrue(line.contains("retrying in 1s"), line)
    }

    func testReasonForStatusIsHumanReadable() {
        XCTAssertTrue(ModelRetryPolicy.reason(forStatus: 429).contains("Rate limited"))
        XCTAssertTrue(ModelRetryPolicy.reason(forStatus: 503).contains("overloaded"))
        XCTAssertTrue(ModelRetryPolicy.reason(forStatus: 500).contains("500"))
    }
}
