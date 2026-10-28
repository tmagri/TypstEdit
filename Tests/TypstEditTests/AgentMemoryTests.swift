import XCTest
@testable import TypstEdit

/// The chat's working memory: the plan and work log that go into every
/// turn's system prompt, the repeat guard that stops read loops, and the
/// digest that replaces elided tool output.
final class AgentWorkingMemoryTests: XCTestCase {

    // MARK: Plan block

    func testPlanBlockIsNilWithoutAPlan() {
        XCTAssertNil(AgentHarnessTools.planPromptBlock([]))
    }

    func testPlanBlockMarksEveryStatus() throws {
        let block = try XCTUnwrap(AgentHarnessTools.planPromptBlock([
            AgentPlanItem(content: "Map structure", status: .completed),
            AgentPlanItem(content: "Restructure Mugs.typ", status: .inProgress),
            AgentPlanItem(content: "Verify", status: .pending),
        ]))
        XCTAssertTrue(block.hasPrefix("CURRENT PLAN"))
        XCTAssertTrue(block.contains("[x] Map structure"))
        XCTAssertTrue(block.contains("[>] Restructure Mugs.typ (in progress)"))
        XCTAssertTrue(block.contains("[ ] Verify"))
    }

    // MARK: Work log

    private func toolRow(
        _ name: String,
        _ arguments: String,
        status: ChatMessage.ToolStatus = .succeeded,
        output: String = "",
        isSubagent: Bool = false
    ) -> ChatMessage {
        ChatMessage(role: .toolCall, isSubagent: isSubagent, toolName: name,
                    toolArgumentsJSON: arguments, toolStatus: status, toolOutput: output)
    }

    func testWorkLogIsNilWithoutToolCalls() {
        XCTAssertNil(AgentHarnessTools.workLog(from: [ChatMessage(role: .user, text: "hi")]))
    }

    func testWorkLogSummarizesReadsSearchesAndEdits() throws {
        let log = try XCTUnwrap(AgentHarnessTools.workLog(from: [
            ChatMessage(role: .user, text: "restructure"),
            toolRow("project__read_file", #"{"path":"Mugs.typ","offset":1,"limit":400}"#,
                    output: "[lines 1-400 of 2310 in 'Mugs.typ']\n(truncated — call again with offset: 401 to continue reading)\n= Intro"),
            toolRow("project__grep_project", #"{"pattern":"transform"}"#,
                    output: "Mugs.typ:12: transform\nDTF.typ:40: transform"),
            toolRow("project__edit_file", #"{"path":"DTF.typ","old_string":"SECRET OLD","new_string":"SECRET NEW"}"#,
                    output: "Edited 'DTF.typ': replaced 1 place with 10 characters of new text.\n\n✓ Typst check: compiles cleanly."),
            toolRow("project__write_file", #"{"path":"x.typ","content":"…"}"#, status: .denied, output: "You declined this action."),
        ]))
        let lines = log.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], #"- read_file(path: "Mugs.typ", offset: 1, limit: 400) → ok, lines 1-400 of 2310 in 'Mugs.typ'"#)
        XCTAssertEqual(lines[1], #"- grep_project(pattern: "transform") → Mugs.typ:12: transform"#)
        XCTAssertTrue(lines[2].hasPrefix(#"- edit_file(path: "DTF.typ") → Edited 'DTF.typ'"#), lines[2])
        XCTAssertTrue(lines[2].hasSuffix("(compiles cleanly)"), lines[2])
        // Bulky edit arguments never reach the prompt.
        XCTAssertFalse(log.contains("SECRET"))
        XCTAssertEqual(lines[3], #"- write_file(path: "x.typ") → declined by the user"#)
    }

    func testWorkLogSkipsSubagentAndPlanRowsAndCapsLength() throws {
        var messages = [
            toolRow("project__read_file", #"{"path":"inner.typ"}"#, output: "x", isSubagent: true),
            toolRow("agent__update_plan", #"{"items":[]}"#, output: "Plan updated"),
        ]
        for index in 1...25 {
            messages.append(toolRow("project__read_file", "{\"path\":\"f\(index).typ\"}", output: "text"))
        }
        let log = try XCTUnwrap(AgentHarnessTools.workLog(from: messages, limit: 20))
        let lines = log.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 21) // omission note + 20 calls
        XCTAssertEqual(lines[0], "- (5 earlier calls not shown)")
        XCTAssertTrue(lines.last!.contains("f25.typ"))
        XCTAssertFalse(log.contains("inner.typ"))
        XCTAssertFalse(log.contains("update_plan"))
    }

    // MARK: Repeat guard

    func testRepeatGuardLabelsThenRefusesIdenticalReads() {
        var guardState = ToolCallRepeatGuard()
        let name = "project__read_file"
        let args = #"{"path":"Mugs.typ","limit":400}"#
        let reordered = #"{"limit":400,"path":"Mugs.typ"}"#

        XCTAssertNil(guardState.refusal(name: name, argumentsJSON: args))
        XCTAssertEqual(guardState.record(name: name, argumentsJSON: args, output: "body"), "body")

        // Same call (argument order doesn't matter) runs, but is labelled.
        XCTAssertNil(guardState.refusal(name: name, argumentsJSON: reordered))
        XCTAssertEqual(guardState.record(name: name, argumentsJSON: reordered, output: "body"),
                       ToolCallRepeatGuard.repeatNote + "body")

        // Third identical call is refused without running.
        let refusal = guardState.refusal(name: name, argumentsJSON: args)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal!.hasPrefix("Not run"))

        // A different range is a different call.
        XCTAssertNil(guardState.refusal(name: name, argumentsJSON: #"{"path":"Mugs.typ","offset":401}"#))
    }

    func testRepeatGuardResetsWhenOutputChanges() {
        var guardState = ToolCallRepeatGuard()
        let name = "project__read_file"
        let args = #"{"path":"a.typ"}"#
        _ = guardState.record(name: name, argumentsJSON: args, output: "v1")
        // The file changed on disk: not a repeat, and the count restarts.
        XCTAssertEqual(guardState.record(name: name, argumentsJSON: args, output: "v2"), "v2")
        _ = guardState.record(name: name, argumentsJSON: args, output: "v2")
        XCTAssertNotNil(guardState.refusal(name: name, argumentsJSON: args))
    }

    func testRepeatGuardClearsAfterAnEditButNotAfterNeutralTools() {
        var guardState = ToolCallRepeatGuard()
        let name = "project__read_file"
        let args = #"{"path":"a.typ"}"#
        _ = guardState.record(name: name, argumentsJSON: args, output: "same")
        _ = guardState.record(name: name, argumentsJSON: args, output: "same")
        XCTAssertNotNil(guardState.refusal(name: name, argumentsJSON: args))

        // Plan updates don't change files, so the refusal stands.
        _ = guardState.record(name: "agent__update_plan", argumentsJSON: "{}", output: "Plan updated")
        XCTAssertNotNil(guardState.refusal(name: name, argumentsJSON: args))

        // An edit does: re-reading is legitimate again.
        _ = guardState.record(name: "project__edit_file", argumentsJSON: "{}", output: "Edited")
        XCTAssertNil(guardState.refusal(name: name, argumentsJSON: args))
    }

    func testRepeatGuardNeverRefusesWriteTools() {
        var guardState = ToolCallRepeatGuard()
        let name = "project__edit_file"
        let args = #"{"path":"a.typ"}"#
        for _ in 0..<5 {
            XCTAssertNil(guardState.refusal(name: name, argumentsJSON: args))
            XCTAssertEqual(guardState.record(name: name, argumentsJSON: args, output: "Edited"), "Edited")
        }
    }

    // MARK: Elision digest

    func testReadDigestKeepsWindowAndHeadingLineNumbers() {
        let body = (1...400).map { line -> String in
            switch line {
            case 3: return "= Final design"
            case 120: return "== Transform process"
            case 300: return "#set text(size: 10pt)" // Typst code, not a heading
            default: return "Body text line \(line)."
            }
        }.joined(separator: "\n")
        let output = "[lines 401-800 of 2310 in 'Mugs.typ']\n(truncated — call again with offset: 801 to continue reading)\n" + body
        let digest = AICompletionService.elisionDigest(for: AIToolResult(callID: "1", name: "project__read_file", output: output))

        XCTAssertTrue(digest.contains(AICompletionService.elidedToolOutputPhrase))
        XCTAssertTrue(digest.contains("It covered lines 401-800 of 2310 in 'Mugs.typ'."))
        XCTAssertTrue(digest.contains("403: = Final design"), digest)
        XCTAssertTrue(digest.contains("520: == Transform process"), digest)
        XCTAssertFalse(digest.contains("#set"))
        XCTAssertFalse(digest.contains("Re-run the tool if you still need it"))
        XCTAssertLessThan(digest.count, output.count)
    }

    func testReadDigestOfWholeFileCountsFromLineOne() {
        let output = "#import \"x.typ\": *\n= Title\ntext\n# Markdown heading"
        let digest = AICompletionService.elisionDigest(for: AIToolResult(callID: "1", name: "read_file", output: output))
        XCTAssertTrue(digest.contains("2: = Title"), digest)
        XCTAssertTrue(digest.contains("4: # Markdown heading"), digest)
    }

    func testGrepDigestCountsMatchesPerFile() {
        let output = "Mugs.typ:12: transform\nMugs.typ:40: transform again\nDTF.typ:7: transform"
        let digest = AICompletionService.elisionDigest(for: AIToolResult(callID: "1", name: "project__grep_project", output: output))
        XCTAssertTrue(digest.contains("Matches were in: Mugs.typ (2), DTF.typ (1)."), digest)
    }

    func testOutlineDigestKeepsTheMap() {
        let entries = (1...60).map { "\($0 * 10)-\($0 * 10 + 9): = Section \($0)" }
        let output = "[outline of 'Mugs.typ' — 610 lines, 60 headings]\n" + entries.joined(separator: "\n")
            + "\nRead one section with read_file offset/limit from its line range — e.g. lines 10-19 are offset: 10, limit: 10."
        let digest = AICompletionService.elisionDigest(for: AIToolResult(callID: "1", name: "project__read_file", output: output))
        XCTAssertTrue(digest.contains("[outline of 'Mugs.typ' — 610 lines, 60 headings]"))
        XCTAssertTrue(digest.contains("10-19: = Section 1"))
        XCTAssertTrue(digest.contains("400-409: = Section 40"))
        XCTAssertFalse(digest.contains("Section 41\n"))
        XCTAssertTrue(digest.contains("… 20 more"))
    }

    func testWorkLogRendersBooleansAsWords() {
        let line = AgentHarnessTools.workLogLine(ChatMessage(
            role: .toolCall, toolName: "project__read_file",
            toolArgumentsJSON: #"{"path":"Mugs.typ","outline":true,"offset":1}"#,
            toolStatus: .succeeded, toolOutput: "[outline of 'Mugs.typ' — 10 lines, 1 heading]"
        ))
        XCTAssertTrue(line.contains("outline: true"), line)
        XCTAssertTrue(line.contains("offset: 1"), line)
    }

    // MARK: Progress & turn-budget steering

    private func call(_ name: String) -> AIToolCallRequest {
        AIToolCallRequest(id: UUID().uuidString, name: name, argumentsJSON: "{}")
    }

    func testInvestigativeRoundsAreReadOnlyOnly() {
        XCTAssertTrue(AICompletionService.isInvestigativeRound([call("project__read_file"), call("project__grep_project")]))
        XCTAssertTrue(AICompletionService.isInvestigativeRound([call("agent__delegate_task")]))
        XCTAssertFalse(AICompletionService.isInvestigativeRound([call("project__read_file"), call("project__edit_file")]))
        XCTAssertFalse(AICompletionService.isInvestigativeRound([call("agent__update_plan")]))
        XCTAssertFalse(AICompletionService.isInvestigativeRound([call("someserver__unknown")]))
        XCTAssertFalse(AICompletionService.isInvestigativeRound([]))
    }

    func testNoProgressNoteFiresEveryThresholdRounds() {
        let threshold = AICompletionService.defaultNoProgressRoundThreshold
        XCTAssertNil(AICompletionService.noProgressNote(rounds: 0))
        XCTAssertNil(AICompletionService.noProgressNote(rounds: threshold - 1))
        let note = AICompletionService.noProgressNote(rounds: threshold)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.hasPrefix(AICompletionService.harnessNotePrefix))
        XCTAssertTrue(note!.contains("\(threshold) rounds"))
        XCTAssertNil(AICompletionService.noProgressNote(rounds: threshold + 1))
        XCTAssertNotNil(AICompletionService.noProgressNote(rounds: threshold * 2))
    }

    func testTurnBudgetNotes() {
        // Unlimited: never.
        XCTAssertNil(AICompletionService.turnBudgetNote(completedTurn: 100, maxTurns: nil))
        // maxTurns 24 → requests 0...23. After turn 22 the next is the last.
        let final = AICompletionService.turnBudgetNote(completedTurn: 22, maxTurns: 24)
        XCTAssertTrue(final?.contains("last one") == true, final ?? "nil")
        // Heads-up when three requests remain (after turn 20).
        let headsUp = AICompletionService.turnBudgetNote(completedTurn: 20, maxTurns: 24)
        XCTAssertTrue(headsUp?.contains("Only 3 replies") == true, headsUp ?? "nil")
        XCTAssertNil(AICompletionService.turnBudgetNote(completedTurn: 21, maxTurns: 24))
        XCTAssertNil(AICompletionService.turnBudgetNote(completedTurn: 5, maxTurns: 24))
        // Tiny budgets skip the heads-up but keep the final notice.
        XCTAssertNil(AICompletionService.turnBudgetNote(completedTurn: 1, maxTurns: 5))
        XCTAssertNotNil(AICompletionService.turnBudgetNote(completedTurn: 0, maxTurns: 2))
    }

    func testNoProgressThresholdIsConfigurable() {
        XCTAssertNil(AICompletionService.noProgressNote(rounds: 8, threshold: 0)) // off
        XCTAssertNil(AICompletionService.noProgressNote(rounds: 8, threshold: 5))
        XCTAssertNotNil(AICompletionService.noProgressNote(rounds: 5, threshold: 5))
        XCTAssertNotNil(AICompletionService.noProgressNote(rounds: 3, threshold: 1))
    }

    func testTurnLimitWarningIsConfigurable() {
        // 0 = no warnings at all, not even the final notice.
        XCTAssertNil(AICompletionService.turnBudgetNote(completedTurn: 22, maxTurns: 24, warnAt: 0))
        // 1 = final notice only.
        XCTAssertNotNil(AICompletionService.turnBudgetNote(completedTurn: 22, maxTurns: 24, warnAt: 1))
        XCTAssertNil(AICompletionService.turnBudgetNote(completedTurn: 20, maxTurns: 24, warnAt: 1))
        // 5 = heads-up at five replies left, plus the final notice.
        let headsUp = AICompletionService.turnBudgetNote(completedTurn: 18, maxTurns: 24, warnAt: 5)
        XCTAssertTrue(headsUp?.contains("Only 5 replies") == true, headsUp ?? "nil")
        XCTAssertNil(AICompletionService.turnBudgetNote(completedTurn: 20, maxTurns: 24, warnAt: 5))
        XCTAssertNotNil(AICompletionService.turnBudgetNote(completedTurn: 22, maxTurns: 24, warnAt: 5))
    }

    func testRepeatGuardLimitOfOneRefusesTheFirstRepeat() {
        var guardState = ToolCallRepeatGuard(maxIdenticalRuns: 1)
        let args = #"{"path":"a.typ"}"#
        XCTAssertEqual(guardState.record(name: "project__read_file", argumentsJSON: args, output: "body"), "body")
        let refusal = guardState.refusal(name: "project__read_file", argumentsJSON: args)
        XCTAssertTrue(refusal?.contains("already ran once") == true, refusal ?? "nil")
    }

    func testRepeatGuardOffNeverLabelsOrRefuses() {
        var guardState = ToolCallRepeatGuard(maxIdenticalRuns: 0)
        let args = #"{"path":"a.typ"}"#
        for _ in 0..<5 {
            XCTAssertNil(guardState.refusal(name: "project__read_file", argumentsJSON: args))
            XCTAssertEqual(guardState.record(name: "project__read_file", argumentsJSON: args, output: "body"), "body")
        }
    }

    func testRepeatGuardRefusalWordingForSeveralRuns() {
        var guardState = ToolCallRepeatGuard(maxIdenticalRuns: 3)
        let args = #"{"pattern":"mug"}"#
        for _ in 0..<3 {
            _ = guardState.record(name: "project__grep_project", argumentsJSON: args, output: "hits")
        }
        let refusal = guardState.refusal(name: "project__grep_project", argumentsJSON: args)
        XCTAssertTrue(refusal?.contains("already ran 3 times, with the same result each time,") == true, refusal ?? "nil")
    }

    func testWorkLogLeavesOutSkippedRepeats() throws {
        let log = try XCTUnwrap(AgentHarnessTools.workLog(from: [
            toolRow("project__read_file", #"{"path":"a.typ"}"#, output: "text"),
            toolRow("project__read_file", #"{"path":"a.typ"}"#, status: .skipped, output: "Not run: …"),
        ]))
        XCTAssertEqual(log.components(separatedBy: "\n").count, 1)
        XCTAssertFalse(log.contains("Not run"))
        XCTAssertEqual(AgentHarnessTools.workLogOutcome(status: .skipped, output: ""), "not run (identical repeat)")
    }

    func testToolStatusDecodingToleratesUnknownValues() throws {
        let decoder = JSONDecoder()
        let skipped = try decoder.decode([ChatMessage.ToolStatus].self, from: Data(#"["skipped","succeeded"]"#.utf8))
        XCTAssertEqual(skipped, [.skipped, .succeeded])
        // A status from a newer build reads as failed instead of breaking
        // the whole saved transcript.
        let unknown = try decoder.decode([ChatMessage.ToolStatus].self, from: Data(#"["somethingNew"]"#.utf8))
        XCTAssertEqual(unknown, [.failed])
        // Encoding is unchanged.
        let encoded = try JSONEncoder().encode([ChatMessage.ToolStatus.skipped])
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"["skipped"]"#)
    }

    @MainActor
    func testLoopProtectionSettingsClamp() {
        let settings = AISettingsManager.shared
        let original = (settings.chatRepeatCallLimit, settings.chatNoProgressRounds, settings.chatTurnLimitWarningReplies)
        defer {
            settings.chatRepeatCallLimit = original.0
            settings.chatNoProgressRounds = original.1
            settings.chatTurnLimitWarningReplies = original.2
        }
        settings.chatRepeatCallLimit = -3
        settings.chatNoProgressRounds = 10_000
        settings.chatTurnLimitWarningReplies = 99
        XCTAssertEqual(settings.effectiveChatRepeatCallLimit, 0)
        XCTAssertEqual(settings.effectiveChatNoProgressRounds, 100)
        XCTAssertEqual(settings.effectiveChatTurnLimitWarningReplies, 20)
        settings.chatRepeatCallLimit = 4
        XCTAssertEqual(settings.effectiveChatRepeatCallLimit, 4)
    }

    func testHarnessNoteRidesOnTheNewestToolResult() {
        var messages: [AIChatMessage] = [
            .system("s"), .user("u"),
            .toolResult(AIToolResult(callID: "1", name: "read_file", output: "first")),
            .toolResult(AIToolResult(callID: "2", name: "read_file", output: "second")),
        ]
        AICompletionService.appendHarnessNote("[Harness note] act", to: &messages)
        guard case .toolResult(let first) = messages[2], case .toolResult(let second) = messages[3] else { return XCTFail() }
        XCTAssertEqual(first.output, "first")
        XCTAssertEqual(second.output, "second\n\n[Harness note] act")
        XCTAssertEqual(second.callID, "2")

        // Nothing to attach to: no-op.
        var none: [AIChatMessage] = [.user("u")]
        AICompletionService.appendHarnessNote("x", to: &none)
        guard case .user(let text) = none[0] else { return XCTFail() }
        XCTAssertEqual(text, "u")
    }
}

// MARK: - Document Outline

final class DocumentOutlineTests: XCTestCase {

    func testHeadingDetection() {
        XCTAssertTrue(DocumentOutline.isHeadingLine("= Title"))
        XCTAssertTrue(DocumentOutline.isHeadingLine("=== Deep"))
        XCTAssertTrue(DocumentOutline.isHeadingLine("## Markdown"))
        XCTAssertFalse(DocumentOutline.isHeadingLine("#set page(width: 10cm)"))
        XCTAssertFalse(DocumentOutline.isHeadingLine("=> arrow"))
        XCTAssertFalse(DocumentOutline.isHeadingLine("= "))
        XCTAssertFalse(DocumentOutline.isHeadingLine("  = indented"))
        XCTAssertEqual(DocumentOutline.headingLevel("=== Deep"), 3)
    }

    func testEntriesGiveSectionRangesAndIncludes() {
        let text = """
        #import "template.typ": *
        = Final design
        Intro text.
        == Colours
        Red.
        == Sizes
        #include "sizes.typ"
        = Appendix: transform process
        Steps.
        """
        let entries = DocumentOutline.entries(in: text)
        XCTAssertEqual(entries, [
            .init(line: 2, endLine: 7, kind: .heading(level: 1), text: "= Final design"),
            .init(line: 4, endLine: 5, kind: .heading(level: 2), text: "== Colours"),
            .init(line: 6, endLine: 7, kind: .heading(level: 2), text: "== Sizes"),
            .init(line: 7, endLine: nil, kind: .include, text: "#include \"sizes.typ\""),
            .init(line: 8, endLine: 9, kind: .heading(level: 1), text: "= Appendix: transform process"),
        ])
    }

    func testRawBlocksAreSkipped() {
        let text = """
        # Real heading
        ```bash
        # just a shell comment
        ```
        ## Another
        """
        let lines = DocumentOutline.entries(in: text).map(\.line)
        XCTAssertEqual(lines, [1, 5])
    }

    func testRenderHeaderAndExample() {
        let rendered = DocumentOutline.render("= A\nx\n= B\ny", label: "doc.typ")
        let lines = rendered.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "[outline of 'doc.typ' — 4 lines, 2 headings]")
        XCTAssertEqual(lines[1], "1-2: = A")
        XCTAssertEqual(lines[2], "3-4: = B")
        XCTAssertTrue(lines[3].contains("offset: 1, limit: 2"), lines[3])
    }

    func testRenderWithoutStructure() {
        let rendered = DocumentOutline.render("just text\nmore text", label: "notes.txt")
        XCTAssertTrue(rendered.hasPrefix("[outline of 'notes.txt' — 2 lines, 0 headings]"))
        XCTAssertTrue(rendered.contains("No headings"))
    }
}

@MainActor
final class ToolOutputDigestElisionTests: XCTestCase {

    func testDigestsAreNeverDigestedAgain() async {
        let big = "= Heading\n" + String(repeating: "word ", count: 400)
        var messages: [AIChatMessage] = [
            .system("system"),
            .user("go"),
            .toolResult(AIToolResult(callID: "1", name: "read_file", output: big)),
            .toolResult(AIToolResult(callID: "2", name: "read_file", output: big)),
            .toolResult(AIToolResult(callID: "3", name: "read_file", output: big)),
        ]
        await AICompletionService.elideOldToolOutputs(in: &messages, charBudget: 100, compressor: nil, keepRate: 0.5)
        guard case .toolResult(let first) = messages[2] else { return XCTFail() }
        XCTAssertTrue(first.output.contains("1: = Heading"), first.output)

        // A second pass over the same messages leaves the digest as it was.
        await AICompletionService.elideOldToolOutputs(in: &messages, charBudget: 100, compressor: nil, keepRate: 0.5)
        guard case .toolResult(let again) = messages[2] else { return XCTFail() }
        XCTAssertEqual(again.output, first.output)
    }
}
