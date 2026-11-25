import XCTest
@testable import TypstEdit

/// Pure message-building logic around the "model returned nothing" case —
/// the actual network-driven nudge-and-retry loop in
/// `fetchCompletionWithTools` isn't covered here (it needs a live provider),
/// but the text it decides to show is, so the empty-response UX can't
/// silently regress.
final class AICompletionServiceTests: XCTestCase {

    func testFailureMessageWithoutNudgesOrReasoningSuggestsRephrasing() {
        let message = AICompletionService.emptyAnswerFailureMessage(nudges: 0, hadReasoning: false)
        XCTAssertFalse(message.contains("follow-up attempt"))
        XCTAssertTrue(message.contains("rephrasing"))
    }

    func testFailureMessageCountsNudgesWithCorrectPluralization() {
        let one = AICompletionService.emptyAnswerFailureMessage(nudges: 1, hadReasoning: false)
        XCTAssertTrue(one.contains("1 follow-up attempt"), one)
        XCTAssertFalse(one.contains("1 follow-up attempts"), one)

        let two = AICompletionService.emptyAnswerFailureMessage(nudges: 2, hadReasoning: false)
        XCTAssertTrue(two.contains("2 follow-up attempts"), two)
    }

    func testFailureMessageWithReasoningPointsAtMaxTokensInsteadOfRephrasing() {
        let message = AICompletionService.emptyAnswerFailureMessage(nudges: 2, hadReasoning: true)
        XCTAssertTrue(message.contains("Max Tokens"))
        XCTAssertFalse(message.contains("rephrasing"))
    }

    // MARK: - The current engine's empty/overflow wording

    func testAnEmptyReplyErrorNamesTheAttempts() {
        let error = AICompletionService.emptyReplyError(
            meta: AIChatStepMeta(finishReason: "stop"),
            budget: 4_096,
            attempts: 2
        )
        guard case AIError.emptyReply(let attempts) = error else {
            return XCTFail("expected .emptyReply, got \(error)")
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(error.localizedDescription.contains("no reply"))
    }

    func testABudgetEatenByReasoningIsNamedInsteadOfBlamedOnTheModel() {
        // A reply cut off at the shared ceiling with only hidden reasoning
        // spent cannot be improved by retrying the same request.
        let meta = AIChatStepMeta(
            finishReason: "length",
            usage: TokenUsage(input: 10, output: 0, reasoning: 32_000)
        )
        let error = AICompletionService.emptyReplyError(
            meta: meta,
            budget: AISettingsManager.learnedMaxTokensCeiling,
            attempts: 1
        )
        guard case AIError.reasoningAteTheBudget(let tokens, let budget) = error else {
            return XCTFail("expected .reasoningAteTheBudget, got \(error)")
        }
        XCTAssertEqual(tokens, 32_000)
        XCTAssertEqual(budget, AISettingsManager.learnedMaxTokensCeiling)
        XCTAssertTrue(error.localizedDescription.contains("hidden reasoning"))
    }

    func testWideningIsRefusedAtTheCeilingAndBoundedBelowIt() {
        let cutOff = AIChatStepMeta(finishReason: "length")
        XCTAssertNil(
            AICompletionService.widenedBudgetAfterCutoff(
                meta: cutOff, budget: AISettingsManager.learnedMaxTokensCeiling
            ),
            "a reply already at the ceiling cannot grow"
        )
        XCTAssertEqual(
            AICompletionService.widenedBudgetAfterCutoff(meta: cutOff, budget: 4_096),
            8_192,
            "with no evidence about the answer, doubling is the fallback"
        )
        // A reply that finished is never widened.
        XCTAssertNil(AICompletionService.widenedBudgetAfterCutoff(
            meta: AIChatStepMeta(finishReason: "stop"), budget: 4_096
        ))
    }

    func testReasoningEvidenceSetsTheWidenedBudget() {
        // 6,000 reasoning tokens in a 4,096 cap: the cap is what cut it off,
        // so the suggested budget is the reasoning plus room for an answer.
        let meta = AIChatStepMeta(
            finishReason: "length",
            usage: TokenUsage(input: 10, output: 4_096, reasoning: 6_000)
        )
        let suggested = meta.suggestedBudgetAfterCutoff(currentBudget: 4_096)
        XCTAssertGreaterThanOrEqual(suggested, 6_000)
        XCTAssertLessThanOrEqual(suggested, 8_192, "never more than doubling in one step")
        XCTAssertEqual(
            AICompletionService.widenedBudgetAfterCutoff(meta: meta, budget: 4_096),
            suggested
        )
    }

    // MARK: - Never send a non-positive cap

    @MainActor
    func testAnUnresolvedAutomaticReplySizeIsFlooredNotSentAsZero() {
        // Reply Size 0 means "automatic" in Settings. The chat resolves that
        // before calling, but a 0 that still reaches a builder must not go on
        // the wire: providers answer it with HTTP 400
        // "max_tokens must be a positive integer" and no reply at all.
        XCTAssertEqual(AICompletionService.outputBudget(0), 1)
        XCTAssertEqual(AICompletionService.outputBudget(-5), 1)
        XCTAssertEqual(AICompletionService.outputBudget(2_048), 2_048)

        let body = AICompletionService.openAIBody(
            messages: [.user("hi")], tools: [], maxTokens: 0,
            effort: .auto, stream: true
        )
        XCTAssertEqual(body["max_tokens"] as? Int, AICompletionService.minimumOutputBudget)

        let anthropic = AICompletionService.anthropicBody(
            messages: [.user("hi")], tools: [], maxTokens: 0, effort: .auto
        )
        XCTAssertEqual(anthropic["max_tokens"] as? Int, AICompletionService.minimumOutputBudget)
    }

    func testAProviderRejectingTheRaisedCapIsRecognisedAndKeptApartFromOverflow() {
        XCTAssertTrue(AICompletionService.isTokenCapRejection("max_tokens must be a positive integer"))
        XCTAssertTrue(AICompletionService.isTokenCapRejection("max_tokens must be less than 8192"))
        XCTAssertTrue(AICompletionService.isTokenCapRejection("max_completion_tokens is too large"))
        // A prompt that is too long is a different recovery: send less of the
        // conversation, not a smaller reply cap.
        XCTAssertFalse(AICompletionService.isTokenCapRejection("This model's maximum context length is 8192 tokens"))
        XCTAssertFalse(AICompletionService.isTokenCapRejection("invalid api key"))
    }

    func testWideningRespectsACallerSuppliedCeiling() {
        // The chat's Reply Size governs how far a cut-off reply may grow; the
        // shared learned-budget ceiling is only the default.
        let cutOff = AIChatStepMeta(finishReason: "length")
        XCTAssertEqual(
            AICompletionService.widenedBudgetAfterCutoff(meta: cutOff, budget: 4_096, ceiling: 8_192),
            8_192
        )
        XCTAssertNil(AICompletionService.widenedBudgetAfterCutoff(
            meta: cutOff, budget: 8_192, ceiling: 8_192
        ))
    }

    func testAStatedCapIsReadFromTheRejectionInsteadOfGuessed() {
        // Using the number the provider states is exact; guessing costs
        // another refused request per step.
        XCTAssertEqual(
            AICompletionService.statedTokenCap(in: "max_tokens must be less than 8192"),
            8_191,
            "\"less than N\" is exclusive"
        )
        XCTAssertEqual(
            AICompletionService.statedTokenCap(in: "maximum is 4096 tokens"),
            4_096
        )
        // The smallest plausible number wins: a smaller cap is the safe read,
        // and it still strictly lowers whatever was refused.
        XCTAssertEqual(
            AICompletionService.statedTokenCap(in: "max_tokens: 4096 is above the 2048 allowed"),
            2_048
        )
        // Numbers outside a plausible cap range are not a cap statement.
        XCTAssertNil(AICompletionService.statedTokenCap(in: "invalid api key"))
        XCTAssertNil(AICompletionService.statedTokenCap(in: "model gpt-4 refused"))
    }

    func testToolArgumentsMustBeAJSONObject() {
        XCTAssertTrue(AICompletionService.isValidToolArguments(""))
        XCTAssertTrue(AICompletionService.isValidToolArguments("{\"a\":1}"))
        XCTAssertFalse(AICompletionService.isValidToolArguments("{\"a\":"), "cut off mid-object")
        XCTAssertFalse(AICompletionService.isValidToolArguments("[1,2]"))
    }

    func testACancelledRequestIsRecognisedWhateverShapeItArrivesIn() {
        XCTAssertTrue(AICompletionService.isCancellation(CancellationError()))
        XCTAssertTrue(AICompletionService.isCancellation(AIError.cancelled))
        XCTAssertTrue(AICompletionService.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(AICompletionService.isCancellation(AIError.noData))
    }

    func testContextOverflowShrinkStepsDescendFromACacheFriendlyFirstStep() {
        let steps = AICompletionService.contextOverflowShrinkSteps
        XCTAssertEqual(steps.count, AICompletionService.maxContextShrinks)
        XCTAssertEqual(steps, steps.sorted(by: >))
        XCTAssertTrue(steps.allSatisfy { $0 > 0 && $0 < 1 })
        XCTAssertGreaterThanOrEqual(steps.first!, 0.5)
        XCTAssertLessThanOrEqual(steps.last!, 0.25)
    }

    func testARateLimitIsNeverClassifiedAsAnOverflow() {
        // Shrinking would not fix a throttle and would throw context away.
        let rateLimits = [
            "HTTP 429: Rate limit reached for gpt-4",
            "HTTP 429: Too many requests, please slow down",
            "HTTP 429: Too many tokens per day",
            "HTTP 429: throttling error",
        ]
        for message in rateLimits {
            XCTAssertFalse(AICompletionService.isContextOverflowMessage(message), message)
        }
        XCTAssertTrue(AICompletionService.isContextOverflowMessage("HTTP 400: context_length_exceeded"))
        XCTAssertTrue(AICompletionService.isContextOverflowMessage("prompt is too long"))
        XCTAssertFalse(AICompletionService.isContextOverflowMessage("max_tokens must be less than 8192"))
        XCTAssertFalse(AICompletionService.isContextOverflowMessage(""))
    }

    func testTheOverflowStatusLineNamesTheAttempt() {
        let line = AICompletionService.contextOverflowStatusLine(attempt: 2, total: 3)
        XCTAssertTrue(line.contains("2 of 3"), line)
        XCTAssertTrue(line.lowercased().contains("too long"), line)
    }

    func testAHarnessNoteRidesOnTheNewestToolResult() {
        var messages: [AIChatMessage] = [
            .system("sys"),
            .user("task"),
            .assistantToolCalls([AIToolCallRequest(id: "a", name: "project__read_file", argumentsJSON: "{}")]),
            .toolResult(AIToolResult(callID: "a", name: "project__read_file", output: "text")),
            .assistantText("carry on"),
        ]
        // Nothing to attach to after a final answer: the note is dropped.
        AICompletionService.appendHarnessNote("late note", to: &messages)
        guard case .assistantText = messages.last else {
            return XCTFail("the final answer must not be rewritten")
        }

        // After a tool result, it lands there and the output survives.
        messages.append(.assistantToolCalls([AIToolCallRequest(id: "b", name: "project__grep_project", argumentsJSON: "{}")]))
        messages.append(.toolResult(AIToolResult(callID: "b", name: "project__grep_project", output: "2 matches")))
        AICompletionService.appendHarnessNote(AICompletionService.steerNote("Stop at section two"), to: &messages)
        guard case .toolResult(let result) = messages.last else {
            return XCTFail("last message should still be the tool result")
        }
        XCTAssertEqual(result.callID, "b")
        XCTAssertTrue(result.output.contains("2 matches"))
        XCTAssertTrue(result.output.contains("Stop at section two"))
    }
}
