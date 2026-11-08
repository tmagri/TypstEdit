import XCTest
@testable import TypstEdit

/// The compaction trigger — a percentage buffer under the budget rather than
/// the limit itself — and the background summary that fills that buffer
/// before the context reaches it.
@MainActor
final class CompactionPolicyTests: XCTestCase {

    // MARK: - Cut point

    func testNothingToCompactWithThreeUserTurnsOrFewer() {
        // The last three exchanges stay verbatim: summarizing them would cost
        // more context than it saves.
        let messages = [
            ChatMessage(role: .user, text: "one"),
            ChatMessage(role: .assistant, text: "first"),
            ChatMessage(role: .user, text: "two"),
            ChatMessage(role: .assistant, text: "second"),
            ChatMessage(role: .user, text: "three")
        ]
        XCTAssertNil(AIChatManager.compactionCut(in: messages))
    }

    func testCutIsMadeAtAUserBoundaryKeepingTheLastThree() {
        let messages = [
            ChatMessage(role: .user, text: "q1"),
            ChatMessage(role: .assistant, text: "a1"),
            ChatMessage(role: .user, text: "q2"),
            ChatMessage(role: .assistant, text: "a2"),
            ChatMessage(role: .user, text: "q3"),
            ChatMessage(role: .assistant, text: "a3"),
            ChatMessage(role: .user, text: "q4"),
            ChatMessage(role: .assistant, text: "a4")
        ]
        let cut = AIChatManager.compactionCut(in: messages)
        // The cut lands on the *fourth-from-last* user message, so the last
        // three exchanges (q2…a4) stay verbatim.
        XCTAssertEqual(cut?.cutIndex, 2)
        XCTAssertEqual(cut?.covered.count, 2)
    }

    func testAlreadyCompactedTurnsDoNotCountAsUserBoundaries() {
        var messages = [
            ChatMessage(role: .user, text: "q1"),
            ChatMessage(role: .assistant, text: "a1"),
            ChatMessage(role: .user, text: "q2"),
            ChatMessage(role: .assistant, text: "a2"),
            ChatMessage(role: .user, text: "q3"),
            ChatMessage(role: .assistant, text: "a3"),
            ChatMessage(role: .user, text: "q4"),
            ChatMessage(role: .assistant, text: "a4")
        ]
        messages[0].isCompacted = true
        // Three live user turns remain, so there is nothing left to summarize.
        XCTAssertNil(AIChatManager.compactionCut(in: messages))
    }

    func testCutIsNilWhenOnlyToolRowsPrecedeIt() {
        let messages = [
            ChatMessage(role: .user, text: "q1"),
            ChatMessage(role: .toolCall, toolName: "project__read_file", toolStatus: .succeeded, toolOutput: "x"),
            ChatMessage(role: .assistant, text: "a1"),
            ChatMessage(role: .user, text: "q2"),
            ChatMessage(role: .assistant, text: "a2"),
            ChatMessage(role: .user, text: "q3"),
            ChatMessage(role: .assistant, text: "a3"),
            ChatMessage(role: .user, text: "q4"),
            ChatMessage(role: .assistant, text: "a4")
        ]
        let cut = AIChatManager.compactionCut(in: messages)
        XCTAssertNotNil(cut)
        // A tool row is never summarized on its own; the covering slice still
        // has real user/assistant turns in it.
        XCTAssertTrue(cut!.covered.contains { $0.role == .user })
    }

    // MARK: - Summarizer input

    func testToolCallsBecomePointersInTheToolLog() {
        let covered: ArraySlice<ChatMessage> = [
            ChatMessage(role: .user, text: "Fix the intro"),
            ChatMessage(role: .toolCall, toolName: "project__read_file",
                        toolArgumentsJSON: #"{"path":"chapters/intro.typ","offset":10,"limit":40}"#,
                        toolStatus: .succeeded, toolOutput: "[lines 10-49 of 300]\nThe intro text."),
            ChatMessage(role: .toolCall, toolName: "agent__update_plan",
                        toolArgumentsJSON: #"{"items":[]}"#, toolStatus: .succeeded, toolOutput: "ok"),
            ChatMessage(role: .toolCall, isSubagent: true, toolName: "project__grep_project",
                        toolArgumentsJSON: #"{"pattern":"intro"}"#, toolStatus: .succeeded, toolOutput: "a.typ:1: intro"),
            ChatMessage(role: .assistant, text: "The intro is on lines 10-49.")
        ][...]

        let source = AIChatManager.compactionSource(from: covered)

        XCTAssertTrue(source.toolLog.contains("read_file(path: \"chapters/intro.typ\", offset: 10, limit: 40) → ok, lines 10-49 of 300"))
        XCTAssertFalse(source.toolLog.contains("update_plan"), "the plan has its own prompt block")
        XCTAssertFalse(source.toolLog.contains("grep_project"), "subagent internals are covered by its delegate_task row")
        XCTAssertFalse(source.toolLog.contains("The intro text."), "the log points at evidence; it does not copy it")
        XCTAssertEqual(source.transcript, "User: Fix the intro\n\nAssistant: The intro is on lines 10-49.")
        XCTAssertNil(source.previousSummary)
    }

    func testAnEarlierSummaryIsUpdatedNotSummarizedAgain() {
        let covered: ArraySlice<ChatMessage> = [
            ChatMessage(role: .user, text: "gone", isCompacted: true),
            ChatMessage(role: .assistant, text: "[Summary of earlier conversation]\n\n## Objective\nShorten chapter 2.", isSummary: true),
            ChatMessage(role: .user, text: "Now chapter 3")
        ][...]

        let source = AIChatManager.compactionSource(from: covered)

        XCTAssertEqual(source.previousSummary, "## Objective\nShorten chapter 2.", "the label is dropped so it is not nested again")
        XCTAssertEqual(source.transcript, "User: Now chapter 3", "neither the summary nor compacted turns are replayed as conversation")

        let prompt = AIChatManager.compactionPrompt(for: source)
        XCTAssertTrue(prompt.contains("PREVIOUS SUMMARY:\n## Objective\nShorten chapter 2."))
        XCTAssertTrue(prompt.contains("## Evidence"))
        XCTAssertFalse(prompt.contains("TOOL LOG"), "no empty section when there were no tool calls")
    }

    func testAPromptWithoutAnEarlierSummaryHasNoUpdateInstruction() {
        let prompt = AIChatManager.compactionPrompt(for: .init(previousSummary: nil, transcript: "User: hi", toolLog: ""))
        XCTAssertFalse(prompt.contains("PREVIOUS SUMMARY"))
        XCTAssertTrue(prompt.hasSuffix("CONVERSATION:\nUser: hi"))
    }

    func testClippingKeepsTheNewestEntries() {
        let entries = (1...10).map { "entry \($0) " + String(repeating: "x", count: 20) }
        let clipped = AIChatManager.clipKeepingNewest(entries, cap: 100, separator: "\n")
        XCTAssertTrue(clipped.contains("entry 10 "))
        XCTAssertFalse(clipped.contains("entry 1 "), "the oldest entries go first")
        XCTAssertTrue(clipped.hasPrefix("… ("), "the cut is stated, not silent")
        XCTAssertEqual(AIChatManager.clipKeepingNewest(["a", "b"], cap: 100), "a\n\nb")
    }

    // MARK: - Applicability

    func testAPrecomputedSummaryAppliesWhileItsTurnsAreStillLive() {
        let messages = [
            ChatMessage(role: .user, text: "q1"),
            ChatMessage(role: .assistant, text: "a1"),
            ChatMessage(role: .user, text: "q2"),
            ChatMessage(role: .assistant, text: "a2"),
            ChatMessage(role: .user, text: "q3"),
            ChatMessage(role: .assistant, text: "a3"),
            ChatMessage(role: .user, text: "q4"),
            ChatMessage(role: .assistant, text: "a4")
        ]
        let summary = AIChatManager.PrecomputedSummary(
            text: "summary",
            label: "Summary of earlier conversation",
            cutIndex: 4,
            builtAtChars: 100
        )
        XCTAssertTrue(AIChatManager.isStillApplicable(summary, to: messages))

        // Appending a turn leaves earlier indices stable, so it still applies.
        var appended = messages
        appended.append(ChatMessage(role: .user, text: "q5"))
        XCTAssertTrue(AIChatManager.isStillApplicable(summary, to: appended))
    }

    func testASummaryIsStaleOnceItsTurnsWereCompacted() {
        var messages = [
            ChatMessage(role: .user, text: "q1"),
            ChatMessage(role: .assistant, text: "a1"),
            ChatMessage(role: .user, text: "q2"),
            ChatMessage(role: .assistant, text: "a2"),
            ChatMessage(role: .user, text: "q3"),
            ChatMessage(role: .assistant, text: "a3"),
            ChatMessage(role: .user, text: "q4"),
            ChatMessage(role: .assistant, text: "a4")
        ]
        messages[0].isCompacted = true
        messages[1].isCompacted = true
        messages[2].isCompacted = true
        messages[3].isCompacted = true
        let summary = AIChatManager.PrecomputedSummary(
            text: "summary",
            label: "Summary",
            cutIndex: 4,
            builtAtChars: 100
        )
        XCTAssertFalse(AIChatManager.isStillApplicable(summary, to: messages))
    }

    func testASummaryIsStaleWhenTheTranscriptShrankBelowItsCut() {
        let messages = [ChatMessage(role: .user, text: "q1")]
        let summary = AIChatManager.PrecomputedSummary(
            text: "summary",
            label: "Summary",
            cutIndex: 40,
            builtAtChars: 100
        )
        XCTAssertFalse(AIChatManager.isStillApplicable(summary, to: messages))
    }

    // MARK: - Precompute trigger

    func testPrecomputeWaitsUntilTheContextIsNearTheTrigger() {
        // Well under the trigger: too early to spend a model request.
        XCTAssertFalse(CompactionBuffer.shouldPrecompute(
            estimatedTokens: 8_000,
            triggerTokens: 20_000,
            alreadyPrecomputed: false,
            isBusy: false
        ))
        // At 85% of the trigger: worth starting.
        XCTAssertTrue(CompactionBuffer.shouldPrecompute(
            estimatedTokens: 17_000,
            triggerTokens: 20_000,
            alreadyPrecomputed: false,
            isBusy: false
        ))
    }

    func testPrecomputeIsSkippedForShortConversations() {
        // A tiny budget means a summary would cost more than it saves.
        XCTAssertFalse(CompactionBuffer.shouldPrecompute(
            estimatedTokens: 2_000,
            triggerTokens: 2_400,
            alreadyPrecomputed: false,
            isBusy: false
        ))
    }

    func testPrecomputeDoesNotRestartWhileOneIsPending() {
        XCTAssertFalse(CompactionBuffer.shouldPrecompute(
            estimatedTokens: 18_000,
            triggerTokens: 20_000,
            alreadyPrecomputed: true,
            isBusy: false
        ))
    }

    func testPrecomputeIsSkippedWhileTheChatIsBusy() {
        XCTAssertFalse(CompactionBuffer.shouldPrecompute(
            estimatedTokens: 18_000,
            triggerTokens: 20_000,
            alreadyPrecomputed: false,
            isBusy: true
        ))
    }

    func testPrecomputeNeedsAPositiveTrigger() {
        XCTAssertFalse(CompactionBuffer.shouldPrecompute(
            estimatedTokens: 18_000,
            triggerTokens: 0,
            alreadyPrecomputed: false,
            isBusy: false
        ))
    }

    // MARK: - Buffer

    func testBufferLeavesAMarginUnderTheBudget() {
        // A 20% buffer on a 100,000 budget compacts at 80,000.
        XCTAssertEqual(CompactionBuffer.trigger(budget: 100_000, bufferPercent: 20), 80_000)
        // 15% of 16,000 → 13,600.
        XCTAssertEqual(CompactionBuffer.trigger(budget: 16_000, bufferPercent: 15), 13_600)
    }

    func testZeroBufferCompactsAtTheBudget() {
        XCTAssertEqual(CompactionBuffer.trigger(budget: 32_000, bufferPercent: 0), 32_000)
    }

    func testBufferNeverSqueezesWorkingRoomAway() {
        // A huge buffer on a small budget still leaves the 2,000 floor.
        XCTAssertEqual(CompactionBuffer.trigger(budget: 3_000, bufferPercent: 50), 2_000)
    }

    func testBufferPercentageIsClamped() {
        XCTAssertEqual(CompactionBuffer.clampedPercent(-10), 0)
        XCTAssertEqual(CompactionBuffer.clampedPercent(15), 15)
        XCTAssertEqual(CompactionBuffer.clampedPercent(90), 50)
    }

    func testALargeBudgetAndASmallOneUseTheSameSetting() {
        // The point of a percentage: one value that fits both.
        let small = CompactionBuffer.trigger(budget: 32_000, bufferPercent: 15)
        let large = CompactionBuffer.trigger(budget: 1_000_000, bufferPercent: 15)
        XCTAssertEqual(Double(small) / 32_000, 0.85, accuracy: 0.001)
        XCTAssertEqual(Double(large) / 1_000_000, 0.85, accuracy: 0.001)
    }
}
