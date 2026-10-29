import XCTest
@testable import TypstEdit

/// Plan mode, steering, and the goal loop (all modeled on opencode): Plan
/// mode withholds every mutating tool and rejects them at dispatch; steering
/// routes messages sent mid-turn into the running turn; the goal loop keeps
/// working an armed objective with reviewer-judged continuations. Covers the
/// pure rules — descriptor filtering, the dispatch guard, reminder text,
/// persistence, the steering drain points, and the goal verdict parsing and
/// stall rule. The full turn loop itself is network-bound and covered by the
/// E2E tests.
@MainActor
final class AIChatModeTests: XCTestCase {

    // MARK: - Descriptor Filtering

    /// The full built-in tool list a project-scoped chat gets, with every
    /// optional tool turned on.
    private func fullToolList() -> [MCPTool] {
        let localTools = LocalToolExecutor()
        localTools.scope = .project(root: URL(fileURLWithPath: "/tmp/plan-mode-test"))
        localTools.pythonToolEnabled = true
        localTools.webFetchToolEnabled = true
        localTools.activeSkillAttachments = [
            LocalToolExecutor.SkillAttachmentInfo(
                skillID: "typst-reference",
                folder: URL(fileURLWithPath: "/tmp/plan-mode-test/.typstedit/skills/typst-reference"),
                files: ["reference.md"]
            )
        ]
        return localTools.toolDescriptors()
            + GitTools.descriptors(permissions: GitToolPermissions(enabled: true, fetchEnabled: true, pullEnabled: true, pushEnabled: true))
            + [AgentHarnessTools.updatePlanTool, AgentHarnessTools.delegateTaskTool]
    }

    func testPlanModeFilterRemovesEveryWriter() {
        let filtered = AIChatManager.descriptorsForPlanMode(fullToolList())
        let names = Set(filtered.map(\.qualifiedName))
        for writer in ["project__edit_file", "project__move_lines", "project__write_file",
                       "project__export_document", "project__export_markdown",
                       "project__copy_files", "project__create_folder", "python__run"] {
            XCTAssertFalse(names.contains(writer), "\(writer) must not be offered in Plan mode")
        }
        for mutator in ["git__git_stage", "git__git_commit", "git__git_fetch", "git__git_pull", "git__git_push"] {
            XCTAssertFalse(names.contains(mutator), "\(mutator) must not be offered in Plan mode")
        }
    }

    func testPlanModeFilterKeepsReadersAndPlanningTools() {
        let filtered = AIChatManager.descriptorsForPlanMode(fullToolList())
        let names = Set(filtered.map(\.qualifiedName))
        for reader in ["project__list_files", "project__read_file", "project__grep_project",
                       "project__search_project", "project__read_skill_file",
                       "project__run_typst_check", "project__convert_markdown_to_typst",
                       "project__web_fetch", "git__git_status", "git__git_diff", "git__git_log",
                       "agent__update_plan", "agent__delegate_task"] {
            XCTAssertTrue(names.contains(reader), "\(reader) must stay available in Plan mode")
        }
    }

    func testPlanModeFilterLeavesUserConfiguredMCPToolsAlone() {
        // MCP servers are opt-in per session; the restriction (like
        // opencode's) only covers the built-in edit tools, so an MCP tool —
        // even a hypothetical writer — passes through untouched.
        let mcpTool = MCPTool(serverName: "myserver", name: "anything", description: "", inputSchema: [:])
        XCTAssertEqual(AIChatManager.descriptorsForPlanMode([mcpTool]).count, 1)
    }

    // MARK: - Dispatch Guard

    func testValidateToolAccessRejectsWritersInPlanMode() {
        for writer in ["project__edit_file", "project__write_file", "python__run",
                       "git__git_commit", "git__git_push", "git__git_stage"] {
            XCTAssertThrowsError(
                try AIChatManager.validateToolAccess(qualifiedName: writer, isSubagent: false, planMode: true),
                "\(writer) must be rejected in Plan mode"
            ) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("Plan mode"), "message should name the mode: \(message)")
            }
        }
    }

    func testValidateToolAccessAllowsReadersInPlanMode() {
        for reader in ["project__read_file", "project__grep_project", "project__run_typst_check",
                       "git__git_status", "agent__update_plan", "agent__delegate_task",
                       "myserver__anything"] {
            XCTAssertNoThrow(
                try AIChatManager.validateToolAccess(qualifiedName: reader, isSubagent: false, planMode: true),
                "\(reader) must stay allowed in Plan mode"
            )
        }
    }

    func testValidateToolAccessWithoutPlanModeKeepsAllowingWriters() {
        // The guard must be inert while Plan mode is off — normal chats
        // still edit files.
        XCTAssertNoThrow(try AIChatManager.validateToolAccess(qualifiedName: "project__edit_file", isSubagent: false, planMode: false))
    }

    // MARK: - Reminder Block

    func testReminderBlockTellsTheModelToStopAndHandBackControl() {
        let block = AIChatManager.planModeReminderBlock
        XCTAssertTrue(block.contains("Plan mode"))
        XCTAssertTrue(block.contains("Do not modify any files"))
        // The hand-off rule is the whole point: the model must not start
        // implementing just because the user asks mid-plan.
        XCTAssertTrue(block.contains("turn Plan mode off"))
    }

    // MARK: - Persistence

    func testSessionRecordRoundTripsPlanMode() {
        let manager = AIChatManager(
            messages: [ChatMessage(role: .user, text: "Plan something")]
        )
        manager.planMode = true
        XCTAssertTrue(manager.sessionRecord.planMode == true)

        let data = try! AIChatSessionStore.encodeRecord(manager.sessionRecord)
        guard let decoded = AIChatSessionStore.decodeRecord(from: data) else {
            return XCTFail("encoded record did not decode")
        }
        let reloaded = AIChatManager(record: decoded, scope: .none)
        XCTAssertTrue(reloaded.planMode, "Plan mode must survive a save/reload cycle")
    }

    func testOldRecordWithoutPlanModeLoadsAsOff() throws {
        // Older session files predate the key entirely; decoding must not
        // fail, and the mode must come back off.
        let record = ChatSessionRecord(
            id: UUID(),
            title: "Old chat",
            titleIsAutoGenerated: true,
            createdAt: Date(),
            updatedAt: Date(),
            messages: [],
            plan: nil
        )
        let data = try AIChatSessionStore.encodeRecord(record)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("planMode"), "this fixture must predate the key")
        guard let decoded = AIChatSessionStore.decodeRecord(from: data) else {
            return XCTFail("record without planMode did not decode")
        }
        XCTAssertNil(decoded.planMode)
        let reloaded = AIChatManager(record: decoded, scope: .none)
        XCTAssertFalse(reloaded.planMode)
    }

    // MARK: - Steering

    func testSteerNoteWrapsTheUserTextAndStatesTheRule() {
        let note = AICompletionService.steerNote("Keep the old title")
        XCTAssertTrue(note.contains("STEERING"))
        XCTAssertTrue(note.contains("Keep the old title"))
        // The note rides on a tool result, so it must name what happened —
        // a bare instruction with no context would read like the harness's.
        XCTAssertTrue(note.contains("while you were working"))
    }

    func testSteerNoteLandsOnTheNewestToolResult() {
        // The injection path: harness notes and steering both append to the
        // newest tool result, so a steer sent during a long round is the
        // freshest thing the model reads before its next request.
        var messages: [AIChatMessage] = [
            .system("sys"),
            .user("original task"),
            .assistantToolCalls([AIToolCallRequest(id: "a", name: "project__read_file", argumentsJSON: "{}")]),
            .toolResult(AIToolResult(callID: "a", name: "project__read_file", output: "chapter text")),
            .assistantToolCalls([AIToolCallRequest(id: "b", name: "project__grep_project", argumentsJSON: "{}")]),
            .toolResult(AIToolResult(callID: "b", name: "project__grep_project", output: "2 matches")),
        ]
        AICompletionService.appendHarnessNote(AICompletionService.steerNote("Stop at section two"), to: &messages)
        guard case .toolResult(let result) = messages.last else {
            return XCTFail("last message should still be the tool result")
        }
        XCTAssertTrue(result.callID == "b")
        XCTAssertTrue(result.output.contains("2 matches"), "the tool output must be preserved")
        XCTAssertTrue(result.output.contains("Stop at section two"))
    }

    func testSendMessageWhileGeneratingRoutesToSteering() async {
        let chat = AIChatManager()
        chat.isGenerating = true // a turn is "already running"
        await chat.sendMessage("steer toward the appendix")
        // The message lands in the transcript immediately…
        XCTAssertEqual(chat.messages.last?.role, .user)
        XCTAssertEqual(chat.messages.last?.text, "steer toward the appendix")
        // …and no new turn started: no answer, no error, still "generating".
        XCTAssertNil(chat.messages.last(where: { $0.role == .assistant }))
        XCTAssertNil(chat.errorMessage)
        XCTAssertTrue(chat.isGenerating)
        // And it is persisted with the conversation.
        XCTAssertTrue(chat.sessionRecord.messages.contains(where: { $0.text == "steer toward the appendix" }))
    }

    func testStopAfterSteeringKeepsTranscript() async {
        let chat = AIChatManager()
        chat.isGenerating = true
        await chat.sendMessage("half-sent steer") // routed to the queue, no turn started
        chat.stop()
        // The transcript keeps the message (it was sent and persisted);
        // the queued delivery is dropped with the cancelled turn, so it
        // can't fire a surprise follow-up request later. (`isGenerating`
        // itself is faked here — a real turn clears it in `sendMessage`'s
        // defer when the cancelled task unwinds.)
        XCTAssertEqual(chat.messages.last?.text, "half-sent steer")
        XCTAssertNil(chat.errorMessage)
    }

    // MARK: - Tool Input Repair

    /// A schema shaped like the built-in `read_file` descriptor.
    private var readFileSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "offset": ["type": "integer"],
                "limit": ["type": "integer"],
                "literal": ["type": "boolean"],
                "outline": ["type": "boolean"],
            ],
            "required": ["path"]
        ]
    }

    func testRepairCoercesStringNumbersAndBooleans() {
        let repaired = AICompletionService.repairToolInput(
            ["path": "ch/main.typ", "offset": "5", "limit": "20", "outline": "true"],
            schema: readFileSchema
        )
        XCTAssertEqual(repaired["offset"] as? Double, 5)
        XCTAssertEqual(repaired["limit"] as? Double, 20)
        XCTAssertEqual(repaired["outline"] as? Bool, true)
        XCTAssertEqual(repaired["path"] as? String, "ch/main.typ", "declared strings stay untouched")
    }

    func testRepairLeavesNonIntegralStringsForIntegerFields() {
        let repaired = AICompletionService.repairToolInput(
            ["path": "a.typ", "offset": "2.5"],
            schema: readFileSchema
        )
        XCTAssertEqual(repaired["offset"] as? String, "2.5", "an integer field can't take 2.5 — leave it for the call to refuse")
    }

    func testRepairDropsNullPlaceholderFromOptionalField() {
        let repaired = AICompletionService.repairToolInput(
            ["path": "a.typ", "offset": NSNull()],
            schema: readFileSchema
        )
        XCTAssertNil(repaired["offset"])
        XCTAssertEqual(repaired["path"] as? String, "a.typ")
    }

    func testRepairParsesStringifiedObjectProperty() {
        // Like update_plan: items is an array of {content, status} objects.
        let planSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "content": ["type": "string"],
                            "status": ["type": "string"]
                        ],
                        "required": ["content", "status"]
                    ]
                ]
            ],
            "required": ["items"]
        ]
        let repaired = AICompletionService.repairToolInput(
            ["items": "[{\"content\":\"Draft\",\"status\":\"pending\"}]"],
            schema: planSchema
        )
        let items = repaired["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["status"] as? String, "pending")
    }

    func testRepairKeepsUndeclaredKeysUnlessTheSchemaClosesTheObject() {
        let open = AICompletionService.repairToolInput(
            ["path": "a.typ", "extra": "kept"],
            schema: readFileSchema
        )
        XCTAssertEqual(open["extra"] as? String, "kept")

        var closedSchema = readFileSchema
        closedSchema["additionalProperties"] = false
        let closed = AICompletionService.repairToolInput(
            ["path": "a.typ", "extra": "dropped"],
            schema: closedSchema
        )
        XCTAssertNil(closed["extra"])
    }

    func testRepairWithoutSchemaOrWithCompositionsIsUntouched() {
        let noSchema = AICompletionService.repairToolInput(["limit": "20"], schema: nil)
        XCTAssertEqual(noSchema["limit"] as? String, "20")

        // anyOf-typed fields may genuinely accept a string — leave them.
        let composed: [String: Any] = [
            "type": "object",
            "properties": ["value": ["anyOf": [["type": "string"], ["type": "number"]]]]
        ]
        let untouched = AICompletionService.repairToolInput(["value": "20"], schema: composed)
        XCTAssertEqual(untouched["value"] as? String, "20")
    }

    // MARK: - Goal Loop

    private func activeGoal(objective: String = "Restructure the document into an appendix") -> ChatGoal {
        ChatGoal(
            objective: objective,
            status: .active,
            rounds: 2,
            maxRounds: AIChatManager.goalMaxRounds,
            stalls: 0,
            reason: "Two sections still in the body",
            toolCallsAtBaseline: 5,
            updatedAt: Date()
        )
    }

    func testGoalObjectiveSanitizing() {
        XCTAssertEqual(AIChatManager.sanitizedGoalObjective("  Ship the release  "), "Ship the release")
        // Newlines flatten — an objective is one line in the banner.
        XCTAssertEqual(AIChatManager.sanitizedGoalObjective("Ship\nthe\nrelease"), "Ship the release")
        XCTAssertNil(AIChatManager.sanitizedGoalObjective("   "))
        XCTAssertNil(AIChatManager.sanitizedGoalObjective(""))
        let long = String(repeating: "x", count: AIChatManager.goalObjectiveLimit + 500)
        XCTAssertEqual(AIChatManager.sanitizedGoalObjective(long)?.count, AIChatManager.goalObjectiveLimit)
    }

    func testGoalVerdictParsing() {
        let plain = AIChatManager.parseGoalVerdict(#"{"verdict":"continue","reason":"Two sections remain","next_step":"Move the appendix"}"#)
        XCTAssertEqual(plain?.verdict, "continue")
        XCTAssertEqual(plain?.reason, "Two sections remain")
        XCTAssertEqual(plain?.nextStep, "Move the appendix")

        // Fenced or prose-wrapped verdicts (a fussy local model) still parse.
        let fenced = AIChatManager.parseGoalVerdict("Sure!\n```json\n{\"verdict\":\"done\",\"reason\":\"All sections moved\"}\n```")
        XCTAssertEqual(fenced?.verdict, "done")

        // Missing or unknown verdict, or an empty reason — unusable.
        XCTAssertNil(AIChatManager.parseGoalVerdict(#"{"verdict":"maybe","reason":"x"}"#))
        XCTAssertNil(AIChatManager.parseGoalVerdict(#"{"reason":"no verdict"}"#))
        XCTAssertNil(AIChatManager.parseGoalVerdict(#"{"verdict":"done","reason":"   "}"#))
        XCTAssertNil(AIChatManager.parseGoalVerdict("no json at all"))
    }

    func testStallDetectionComparesNormalizedReasons() {
        XCTAssertTrue(AIChatManager.sameReason("Two  sections remain", "two sections remain"))
        XCTAssertFalse(AIChatManager.sameReason("Two sections remain", "Three sections remain"))
        XCTAssertFalse(AIChatManager.sameReason(nil, "anything"))
    }

    func testGoalTextsCarryRoundAndReason() {
        let goal = activeGoal()
        let prompt = AIChatManager.goalReviewPrompt(
            objective: goal.objective,
            transcript: "User: restructure it\n\nAssistant: moved one section",
            checklist: "[x] done item",
            rounds: goal.rounds,
            maxRounds: goal.maxRounds
        )
        XCTAssertTrue(prompt.contains(goal.objective))
        XCTAssertTrue(prompt.contains("round 2/\(AIChatManager.goalMaxRounds)"))
        XCTAssertTrue(prompt.contains("\"done\""), "the reviewer must see the exact verdict words")

        let continuation = AIChatManager.goalContinuationText(
            goal: goal,
            verdict: AIChatManager.GoalVerdict(verdict: "continue", reason: "Keep going", nextStep: "  Move the last section  ")
        )
        // The loop increments `rounds` before injecting, so the label names
        // the round this instruction starts.
        XCTAssertTrue(continuation.contains("round 2/\(AIChatManager.goalMaxRounds)"))
        XCTAssertTrue(continuation.contains("Keep going"))
        XCTAssertTrue(continuation.contains("Move the last section"), "next_step is trimmed and included")

        let noStep = AIChatManager.goalContinuationText(
            goal: goal,
            verdict: AIChatManager.GoalVerdict(verdict: "continue", reason: "Keep going", nextStep: "  ")
        )
        XCTAssertFalse(noStep.contains("Next step:"), "a blank next_step is dropped")
        XCTAssertTrue(AIChatManager.goalKickoffText(goal).contains(goal.objective))
        XCTAssertTrue(AIChatManager.goalPromptBlock(goal).contains("ACTIVE GOAL"))
    }

    func testGoalPersistsWithTheSession() throws {
        let manager = AIChatManager(record: ChatSessionRecord(
            id: UUID(), title: "t", titleIsAutoGenerated: true,
            createdAt: Date(), updatedAt: Date(), messages: [], plan: nil,
            planMode: false, goal: activeGoal()
        ), scope: .none)
        XCTAssertEqual(manager.goal?.status, .active)
        XCTAssertEqual(manager.goal?.rounds, 2)

        // The goal survives the real save/load path (JSON encode + decode).
        let data = try AIChatSessionStore.encodeRecord(manager.sessionRecord)
        let decoded = try XCTUnwrap(AIChatSessionStore.decodeRecord(from: data))
        let reloaded = AIChatManager(record: decoded, scope: .none)
        XCTAssertEqual(reloaded.goal?.objective, activeGoal().objective)
        XCTAssertEqual(reloaded.goal?.status, .active)
        XCTAssertEqual(reloaded.goal?.toolCallsAtBaseline, 5)

        // Pause and clear work without a network — they only touch state.
        manager.pauseGoal()
        XCTAssertEqual(manager.goal?.status, .paused)
        XCTAssertEqual(manager.goal?.reason, "Paused by the user")
        manager.clearGoal()
        XCTAssertNil(manager.goal)

        // The loaded record carries the goal back to disk.
        let persisted = manager.sessionRecord
        XCTAssertNil(persisted.goal, "cleared goal is persisted as absent")
    }

    func testOldRecordWithoutGoalLoadsAsNil() throws {
        let data = try AIChatSessionStore.encodeRecord(ChatSessionRecord(
            id: UUID(), title: "old", titleIsAutoGenerated: true,
            createdAt: Date(), updatedAt: Date(), messages: [], plan: nil
        ))
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("goal") ?? true, "fixture must predate the key")
        let decoded = try XCTUnwrap(AIChatSessionStore.decodeRecord(from: data))
        XCTAssertNil(decoded.goal)
    }
}
