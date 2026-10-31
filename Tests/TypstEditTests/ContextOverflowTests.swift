import XCTest
@testable import TypstEdit

/// Detection for a provider rejecting the prompt as too long, and the shrink
/// schedule the turn loop uses to recover from it.
///
/// The false negatives matter as much as the matches: a rate limit phrased as
/// "too many tokens" must not be mistaken for an overflow, because the
/// recovery is completely different — waiting beats shrinking.
final class ContextOverflowTests: XCTestCase {

    // MARK: - Detected as overflow

    func testRecognizesTheShapesProvidersActuallyEmit() {
        let messages = [
            "API Error (400): prompt is too long",
            "API Error (400): This model's maximum context length is 8192 tokens",
            "API Error (400): exceeded this model context window limit",
            "API Error (413): request_too_large",
            "context_length_exceeded",
            "Input length 12000 exceeds maximum input length 8192",
            "API Error (400): reduce the length of the messages",
            "number of input tokens exceeds maximum length",
            "This model's context length is only 4096 tokens",
            "Prompt exceeds max length"
        ]
        for message in messages {
            XCTAssertTrue(
                AICompletionService.isContextOverflowMessage(message),
                "expected overflow: \(message)"
            )
        }
    }

    func testIsCaseInsensitive() {
        XCTAssertTrue(AICompletionService.isContextOverflowMessage("PROMPT IS TOO LONG"))
    }

    // MARK: - Not an overflow

    func testRateLimitsAreNotTreatedAsOverflow() {
        // Shrinking the prompt would not fix a throttle, and would throw away
        // context for nothing.
        let messages = [
            "API Error (429): Rate limit reached for gpt-4",
            "API Error (429): Too many requests, please slow down",
            "API Error (429): Too many tokens, please wait",
            "API Error (429): Too many tokens per day",
            "API Error (429): throttling error"
        ]
        for message in messages {
            XCTAssertFalse(
                AICompletionService.isContextOverflowMessage(message),
                "should not be overflow: \(message)"
            )
        }
    }

    func testAnOutputCapRejectionIsNotOverflow() {
        // "max_tokens must be less than N" is about the reply cap; the prompt
        // is fine.
        XCTAssertFalse(AICompletionService.isContextOverflowMessage(
            "max_tokens must be less than 8192"
        ))
    }

    func testUnrelatedErrorsAreNotOverflow() {
        XCTAssertFalse(AICompletionService.isContextOverflowMessage("API Error (401): invalid api key"))
        XCTAssertFalse(AICompletionService.isContextOverflowMessage("API Error (404): model not found"))
        XCTAssertFalse(AICompletionService.isContextOverflowMessage("Parsing Error: bad JSON"))
        XCTAssertFalse(AICompletionService.isContextOverflowMessage(""))
    }

    // MARK: - Shrink schedule

    func testShrinkStepsDescendAndEndWellBelowTheOriginal() {
        let steps = AICompletionService.contextOverflowShrinkSteps
        XCTAssertFalse(steps.isEmpty)
        XCTAssertEqual(steps, steps.sorted(by: >), "steps should descend")
        XCTAssertTrue(steps.allSatisfy { $0 > 0 && $0 < 1 })
        // A provider that rejects a second time gets a much smaller prompt
        // rather than a barely-there trim.
        XCTAssertLessThanOrEqual(steps.last!, 0.4)
    }

    func testFirstShrinkKeepsMostOfTheConversation() {
        // The first retry aims just below the refused size, so the cache
        // prefix and most of the transcript survive.
        XCTAssertGreaterThanOrEqual(AICompletionService.contextOverflowShrinkSteps.first!, 0.8)
    }

    // MARK: - Status line

    func testStatusLineNamesTheAttempt() {
        let line = AICompletionService.contextOverflowStatusLine(attempt: 2, total: 4)
        XCTAssertTrue(line.contains("too long"), line)
        XCTAssertTrue(line.contains("2 of 4"), line)
    }
}
