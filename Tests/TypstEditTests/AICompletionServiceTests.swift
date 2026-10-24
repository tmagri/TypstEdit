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

    func testAutoContinueAttemptsClampToSaneBounds() {
        // A sanity bound: the Settings value must land in 0...5 — 0 turns the
        // feature off, and anything larger would let a stuck model burn the
        // turn budget continuing instead of making progress.
        XCTAssertEqual(AICompletionService.clampedAutoContinueAttempts(0), 0)
        XCTAssertEqual(AICompletionService.clampedAutoContinueAttempts(2), 2)
        XCTAssertEqual(AICompletionService.clampedAutoContinueAttempts(-3), 0)
        XCTAssertEqual(AICompletionService.clampedAutoContinueAttempts(99), 5)
        XCTAssertLessThanOrEqual(AICompletionService.clampedAutoContinueAttempts(Int.max), 5)
    }

    // MARK: - Stall Detection & Auto-Continue

    func testStallContinueMessageTellsTheModelToResume() {
        let message = AICompletionService.stallContinueMessage(idleSeconds: 150, timeoutSeconds: 150)
        XCTAssertTrue(message.contains("stalled"), message)
        XCTAssertTrue(message.contains("150s"), message)
        XCTAssertTrue(message.contains("final answer"), message)
    }

    func testStallStatusNoteShowsProgressAgainstTheBudget() {
        let note = AICompletionService.stallContinueStatusNote(attempt: 1, maxAttempts: 3, idleSeconds: 150)
        XCTAssertTrue(note.contains("1 of 3"), note)
        XCTAssertTrue(note.contains("150s"), note)
    }

    func testStallFailureMessageWithoutAttemptsPointsAtTheServer() {
        let message = AICompletionService.stallFailureMessage(attempts: 0, idleSeconds: 150, timeoutSeconds: 150)
        XCTAssertFalse(message.contains("continue attempt"), message)
        XCTAssertTrue(message.contains("server"), message)
        XCTAssertTrue(message.contains("150s"), message)
    }

    func testStallFailureMessageCountsAttemptsWithCorrectPluralization() {
        let one = AICompletionService.stallFailureMessage(attempts: 1, idleSeconds: 150, timeoutSeconds: 150)
        XCTAssertTrue(one.contains("1 automatic continue attempt"), one)
        XCTAssertFalse(one.contains("1 automatic continue attempts"), one)

        let two = AICompletionService.stallFailureMessage(attempts: 2, idleSeconds: 150, timeoutSeconds: 150)
        XCTAssertTrue(two.contains("2 automatic continue attempts"), two)
    }

    func testStalledResponseErrorDescribesTheSilence() {
        let error = AIError.stalledResponse(idleSeconds: 150, timeoutSeconds: 150)
        let description = (error as LocalizedError).errorDescription ?? ""
        XCTAssertTrue(description.contains("150s"), description)
        XCTAssertTrue(description.contains("stopped sending output"), description)
    }

    func testInterruptedReplyPlaceholderIsNeverEmpty() {
        // It stands in for the abandoned attempt in the transcript, where a
        // literally empty assistant message breaks providers that require
        // strict role alternation.
        XCTAssertFalse(AICompletionService.interruptedReplyPlaceholder
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
