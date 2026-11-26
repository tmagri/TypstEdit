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
        var guardState = ToolCallRepeatGuard(maxIdenticalRuns: ToolCallRepeatGuard.defaultMaxIdenticalRuns)
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
        var guardState = ToolCallRepeatGuard(maxIdenticalRuns: ToolCallRepeatGuard.defaultMaxIdenticalRuns)
        let name = "project__read_file"
        let args = #"{"path":"a.typ"}"#
        _ = guardState.record(name: name, argumentsJSON: args, output: "v1")
        // The file changed on disk: not a repeat, and the count restarts.
        XCTAssertEqual(guardState.record(name: name, argumentsJSON: args, output: "v2"), "v2")
        _ = guardState.record(name: name, argumentsJSON: args, output: "v2")
        XCTAssertNotNil(guardState.refusal(name: name, argumentsJSON: args))
    }

    func testRepeatGuardClearsAfterAnEditButNotAfterNeutralTools() {
        var guardState = ToolCallRepeatGuard(maxIdenticalRuns: ToolCallRepeatGuard.defaultMaxIdenticalRuns)
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
        var guardState = ToolCallRepeatGuard(maxIdenticalRuns: ToolCallRepeatGuard.defaultMaxIdenticalRuns)
        let name = "project__edit_file"
        let args = #"{"path":"a.typ"}"#
        for _ in 0..<5 {
            XCTAssertNil(guardState.refusal(name: name, argumentsJSON: args))
            XCTAssertEqual(guardState.record(name: name, argumentsJSON: args, output: "Edited"), "Edited")
        }
    }

    // MARK: Validation loop

    func testWorkLogRendersBooleansAsWords() {
        let line = AgentHarnessTools.workLogLine(ChatMessage(
            role: .toolCall, toolName: "project__read_file",
            toolArgumentsJSON: #"{"path":"Mugs.typ","outline":true,"offset":1}"#,
            toolStatus: .succeeded, toolOutput: "[outline of 'Mugs.typ' — 10 lines, 1 heading]"
        ))
        XCTAssertTrue(line.contains("outline: true"), line)
        XCTAssertTrue(line.contains("offset: 1"), line)
    }

    // The old progress-nudge / turn-budget-warning layer (isInvestigativeRound,
    // noProgressNote, turnBudgetNote, planReminderNote) was replaced by the
    // engine's inline wrap-up request at the turn cap and its plan checklist
    // block; those tests were removed with it.
}
