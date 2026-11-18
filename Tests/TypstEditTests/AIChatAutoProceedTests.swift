import XCTest
@testable import TypstEdit

/// The Auto-proceed heuristic: which finished replies count as "work is still
/// left", and the continuation text injected when they do.
final class AIChatAutoProceedTests: XCTestCase {

    // MARK: - Unfinished replies

    func testNextStepsHeadingIsUnfinished() {
        let reply = """
        I updated the introduction and the methods section.

        ## Next steps
        - Move the appendix to the end
        - Regenerate the figures
        """
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished(reply))
    }

    func testBoldMarkdownHeadingIsUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Done with chapter 1.\n\n**Next Steps:**\n1. Chapter 2"))
    }

    func testNumberedAndBulletedHeadingsAreUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Chapters 1–3 are done.\n\n2. Remaining work\n- Chapter 4"))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("- Still to do\n- Bibliography"))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("### What's left\n- Peer review"))
    }

    func testPlainStatementIsUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("I converted the first two tables, but I still need to convert the third one."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("The export step is not yet implemented."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("I haven't finished the bibliography yet."))
    }

    func testFinishedReplyIsNotUnfinished() {
        let reply = """
        I finished the whole request: the introduction is rewritten, the appendix moved to the end, and the document compiles cleanly.

        Let me know if you'd like me to also add a table of contents.
        """
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished(reply))
    }

    func testEmptyReplyIsNotUnfinished() {
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished(""))
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("   \n\n  "))
    }

    func testWordNextStepsInsideProseDoesNotCount() {
        // A heading match must be a whole line, not a phrase buried in text.
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("The document does not have a next step section, so I left it as is."))
    }

    func testDetectionLooksOnlyAtTheTail() {
        let longHistory = String(repeating: "Paragraph of finished work.\n\n", count: 1_000)
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished(longHistory + "Everything is complete."))
    }

    // MARK: - Ready-for-go-ahead replies

    func testReadyWhenYouAreIsUnfinished() {
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("I've mapped out chapters 4–6. Next step when you're ready."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("The outline is ready. Let me know when you're ready and I'll continue."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Everything else is set. Ready when you are."))
        XCTAssertTrue(AIChatAutoProceed.looksUnfinished("Say the word and I'll convert the remaining tables."))
    }

    func testReadyProseThatIsNotAHandoffStaysFinished() {
        // "ready" on its own, in ordinary prose, must not hold the run open.
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("The PDF is ready and the document compiles cleanly."))
        XCTAssertFalse(AIChatAutoProceed.looksUnfinished("All six sections are written and ready for review."))
    }

    // MARK: - Continuation text

    func testUnfinishedContinuationNamesTheRound() {
        let text = AIChatAutoProceed.continuationText(trigger: .unfinished, round: 3, maxRounds: 10)
        XCTAssertTrue(text.contains("round 3 of 10"))
        XCTAssertTrue(text.contains("Auto-proceed"))
        XCTAssertTrue(text.lowercased().contains("continue"))
    }

    func testUnlimitedRoundsOmitTheCap() {
        let text = AIChatAutoProceed.continuationText(trigger: .unfinished, round: 4, maxRounds: 0)
        XCTAssertTrue(text.contains("round 4"))
        XCTAssertFalse(text.contains("round 4 of"))
    }

    func testFailureContinuationIncludesTheErrorAndIsClipped() {
        let longError = String(repeating: "timeout ", count: 200)
        let text = AIChatAutoProceed.continuationText(trigger: .failure(longError), round: 1, maxRounds: 5)
        XCTAssertTrue(text.contains("timeout"))
        XCTAssertTrue(text.contains("…"))
        XCTAssertLessThan(text.count, 1_200)
    }

    func testUsageLimitFailureWaitsUntilTheReportedResetTime() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T13:30:25Z"))
        let chinaTime = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let failure = "API Error (429): Usage limit reached for 5 hour. Your limit will reset at 2026-11-18 22:00:47"

        XCTAssertEqual(
            try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(
                in: failure,
                timeZone: chinaTime,
                now: now
            )),
            1_822,
            accuracy: 1
        )
    }

    /// z.ai uses three phrasings across its plan-limit codes: 1308 and 1310 say
    /// "will reset at", while 1316–1321 say "Resets at … ." — a different verb
    /// and a trailing period.
    func testUsageLimitFailureAcceptsEveryZaiPhrasing() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T13:30:25Z"))
        let chinaTime = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let messages = [
            "API Error (429): Usage limit reached for 5 hour. Your limit will reset at 2026-11-18 22:00:47",
            "API Error (429): Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-11-18 22:00:47",
            "API Error (429): Usage limit reached for the past 5 hours. Insufficient balance for extra usage. Resets at 2026-11-18 22:00:47.",
            "API Error (429): Usage limit reached for the past 7 days. Extra usage is not available due to monthly spend limit. Resets at 2026-11-18 22:00:47.",
        ]
        for message in messages {
            XCTAssertEqual(
                try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(
                    in: message,
                    timeZone: chinaTime,
                    now: now
                )),
                1_822,
                accuracy: 1,
                message
            )
        }
    }

    /// A `UTC` or `GMT` suffix used to be mangled into `…TZ` and silently
    /// dropped, so every zoned timestamp fell back to the 10-second countdown.
    func testUsageLimitFailureAcceptsWordZones() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T20:30:25Z"))
        let messages = [
            "API Error (429): your limit will reset at 2026-11-18 22:00:47 UTC",
            "API Error (429): your limit will reset at 2026-11-18 22:00:47 GMT",
            "API Error (429): your limit will reset at 2026-11-18T22:00:47Z",
        ]
        for message in messages {
            XCTAssertEqual(
                try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(in: message, now: now)),
                5_422,
                accuracy: 1,
                message
            )
        }
    }

    /// `GMT+8` is a zone, not part of the time. It used to be captured as a
    /// bare `GMT` and read as UTC, an eight-hour error.
    func testUsageLimitFailureHonoursAWordZoneWithAnOffset() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T13:30:25Z"))
        let chinaTime = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        for suffix in ["GMT+8", "UTC+08:00", "+08:00", "+0800"] {
            XCTAssertEqual(
                try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(
                    in: "API Error (429): your limit will reset at 2026-11-18 22:00:47 \(suffix)",
                    timeZone: chinaTime,
                    now: now
                )),
                1_822,
                accuracy: 1,
                suffix
            )
        }
    }

    func testUsageLimitFailureAcceptsFractionalSecondsAndMinutePrecision() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T20:30:25Z"))
        XCTAssertEqual(
            try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(
                in: "API Error (429): reset at 2026-11-18T22:00:47.123Z",
                now: now
            )),
            5_422.123,
            accuracy: 1
        )
        // Anthropic's spend cap states the time without seconds.
        XCTAssertEqual(
            try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(
                in: "API Error (429): You have reached your API usage limits. You will regain access on 2026-11-18 at 22:00 UTC.",
                now: now
            )),
            5_375,
            accuracy: 1
        )
    }

    /// An unzoned timestamp is the one case where the setting matters, so pin
    /// it: the same text is a different instant in each Server Time Zone.
    func testUsageLimitFailureReadsUnzonedTimestampsInTheConfiguredZone() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T13:30:25Z"))
        let failure = "API Error (429): your limit will reset at 2026-11-18 22:00:47"

        XCTAssertEqual(
            try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(
                in: failure,
                timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")),
                now: now
            )),
            1_822,
            accuracy: 1
        )
        // In UTC the same wall-clock time is 8.5 hours out — past the cap, so
        // no wait is offered rather than a silently wrong one.
        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: failure,
            timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")),
            now: now
        ))
    }

    /// The regression that matters most: a reset in the past used to clamp to
    /// zero, making the countdown empty and re-sending into the same limit
    /// immediately, once per auto-proceed round.
    func testUsageLimitFailureInThePastFallsBackToTheNormalCountdown() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: "API Error (429): reset at \(formatter.string(from: now.addingTimeInterval(-3_600)))",
            timeZone: formatter.timeZone,
            now: now
        ))
        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: "API Error (429): reset at \(formatter.string(from: now.addingTimeInterval(-0.5)))",
            timeZone: formatter.timeZone,
            now: now
        ))
    }

    /// Despite the third-party comment suggesting z.ai runs on UTC, its stated
    /// unit is China time; a wrong zone must not park the chat for weeks.
    func testUsageLimitFailureBeyondTheMaximumWaitIsNotHonoured() throws {        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T13:30:25Z"))
        let chinaTime = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: "API Error (429): Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-11-25 22:00:47",
            timeZone: chinaTime,
            now: now
        ))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTime
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func message(offsetBy seconds: TimeInterval) -> String {
            "API Error (429): reset at \(formatter.string(from: now.addingTimeInterval(seconds)))"
        }

        XCTAssertEqual(
            try XCTUnwrap(AIChatAutoProceed.usageLimitRetryDelay(
                in: message(offsetBy: AIChatAutoProceed.maxUsageLimitWait),
                timeZone: chinaTime,
                now: now
            )),
            AIChatAutoProceed.maxUsageLimitWait,
            accuracy: 1
        )
        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: message(offsetBy: AIChatAutoProceed.maxUsageLimitWait + 1),
            timeZone: chinaTime,
            now: now
        ))
    }

    /// Only a 429 with a stated reset gets the long wait. Everything else —
    /// other statuses, and 429s that state a relative delay or nothing at all —
    /// keeps the ordinary countdown.
    func testUsageLimitRetryDelayIgnoresOtherErrorsAndUnparseableResets() {
        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: "API Error (500): Your limit will reset at 2026-11-18 22:00:47"
        ))
        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: "API Error (429): Your limit will reset soon"
        ))
        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: "API Error (429): Rate limit reached. Please try again in 120ms."
        ))
        XCTAssertNil(AIChatAutoProceed.usageLimitRetryDelay(
            in: "API Error (429): Rate limit exceeded: free-models-per-min."
        ))
    }

    func testUsageLimitResetTimestampExtraction() {
        XCTAssertEqual(
            AIChatAutoProceed.usageLimitResetTimestamp(
                in: "API Error (429): Usage limit reached for 5 hour. Your limit will reset at 2026-11-18 22:00:47"
            ),
            "2026-11-18 22:00:47"
        )
        XCTAssertEqual(
            AIChatAutoProceed.usageLimitResetTimestamp(
                in: "API Error (429): your limit will reset at 2026-11-18 22:00:47 GMT+8"
            ),
            "2026-11-18 22:00:47 GMT+8"
        )
        XCTAssertNil(AIChatAutoProceed.usageLimitResetTimestamp(in: "API Error (429): Try later."))
    }

    func testTriggerFailureFlag() {
        XCTAssertTrue(AIChatAutoProceed.Trigger.failure("boom").isFailure)
        XCTAssertFalse(AIChatAutoProceed.Trigger.unfinished.isFailure)
    }
}
