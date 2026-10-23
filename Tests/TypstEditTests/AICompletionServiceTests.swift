import XCTest
@testable import TypstEdit

/// Pure message-building logic around the "model returned nothing" case —
/// the actual network-driven nudge-and-retry loop in
/// `fetchCompletionWithTools` isn't covered here (it needs a live provider),
/// but the text it decides to show is, so the empty-response UX can't
/// silently regress.
final class AICompletionServiceTests: XCTestCase {

    func testNudgeMessageWithoutReasoningAsksForAnAnswerAnyway() {
        let message = AICompletionService.emptyAnswerNudgeMessage(hadReasoning: false)
        XCTAssertTrue(message.contains("already found"))
        XCTAssertTrue(message.contains("couldn't find anything"))
    }

    func testNudgeMessageWithReasoningMentionsTheThinking() {
        let message = AICompletionService.emptyAnswerNudgeMessage(hadReasoning: true)
        XCTAssertTrue(message.contains("thought that through"))
    }

    func testFailureMessageWithoutNudgesOrReasoningSuggestsRephrasing() {
        let message = AICompletionService.emptyAnswerFailureMessage(nudges: 0, hadReasoning: false)
        XCTAssertFalse(message.contains("follow-up attempt"))
        XCTAssertTrue(message.contains("rephrasing"))
    }

    func testFailureMessageCountsNudgesWithCorrectPluralization() {
        let one = AICompletionService.emptyAnswerFailureMessage(nudges: 1, hadReasoning: false)
        XCTAssertTrue(one.contains("1 follow-up attempt"), one)
        XCTAssertFalse(one.contains("attempts"))

        let two = AICompletionService.emptyAnswerFailureMessage(nudges: 2, hadReasoning: false)
        XCTAssertTrue(two.contains("2 follow-up attempts"), two)
    }

    func testFailureMessageWithReasoningPointsAtMaxTokensInsteadOfRephrasing() {
        let message = AICompletionService.emptyAnswerFailureMessage(nudges: 2, hadReasoning: true)
        XCTAssertTrue(message.contains("Max Tokens"))
        XCTAssertFalse(message.contains("rephrasing"))
    }

    func testMaxEmptyAnswerNudgesIsBoundedAndSmall() {
        // A sanity bound: nudges must stay well under a typical maxTurns
        // budget, or a stuck model could burn the whole turn budget nudging
        // instead of actually making progress.
        XCTAssertGreaterThan(AICompletionService.maxEmptyAnswerNudges, 0)
        XCTAssertLessThanOrEqual(AICompletionService.maxEmptyAnswerNudges, 3)
    }
}
