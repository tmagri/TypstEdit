import Foundation

/// One row of the chat's visible task list — the same "keep the model (and
/// you) honest about multi-step work" idea as Claude Code's todo list. Kept
/// intentionally small: an imperative description and a status.
struct AgentPlanItem: Equatable, Identifiable {
    enum Status: String {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    var id = UUID()
    var content: String
    var status: Status
}

/// Tools that belong to the agent loop itself rather than to the filesystem,
/// so they live in `AIChatManager` (which can start a nested completion and
/// own transcript state) instead of `LocalToolExecutor`.
enum AgentHarnessTools {
    static let namespace = "agent"

    static var updatePlanTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "update_plan",
        description: "Create or update the task list shown to the user during a multi-step job. Use it when a request needs 3+ distinct actions, and update it as you go: exactly one item in_progress at a time, mark items completed immediately when done. Skip it for single-step or conversational requests.",
        inputSchema: [
            "type": "object",
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "content": ["type": "string", "description": "Imperative description, e.g. \"Rewrite the Status section\""],
                            "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]]
                        ],
                        "required": ["content", "status"]
                    ],
                    "description": "The complete list, in order. Omit finished-and-no-longer-relevant items entirely."
                ]
            ],
            "required": ["items"]
        ]
    ) }

    static var delegateTaskTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "delegate_task",
        description: "Hand a self-contained research or reading job to a subagent. It runs in its own context, can read/search files but cannot write, edit, run code, or delegate further, and returns only its written findings. Use it when exploring a large document or several files would otherwise flood this conversation with raw text — ask for the specific facts, quotes, and file locations you need back.",
        inputSchema: [
            "type": "object",
            "properties": [
                "task": ["type": "string", "description": "What to find out or verify, written as a complete brief — the subagent can't see this conversation."],
                "files": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Optional starting points: relative paths it should look at first."
                ]
            ],
            "required": ["task"]
        ]
    ) }

    /// Rebuilds the plan from the most recent `update_plan` tool call in a
    /// persisted transcript, so the checklist survives app restarts without
    /// a second storage format.
    static func plan(from messages: [ChatMessage]) -> [AgentPlanItem] {
        guard let last = messages.last(where: { $0.role == .toolCall && $0.toolName == "\(namespace)__update_plan" }),
              let json = last.toolArgumentsJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let content = item["content"] as? String,
                  let rawStatus = item["status"] as? String,
                  let status = AgentPlanItem.Status(rawValue: rawStatus) else { return nil }
            return AgentPlanItem(content: content, status: status)
        }
    }

    // MARK: - Working Memory

    /// The plan as a system-prompt block, so the checklist steers the model
    /// on every new turn instead of only being drawn in the panel. `nil` when
    /// there is no plan.
    static func planPromptBlock(_ plan: [AgentPlanItem]) -> String? {
        guard !plan.isEmpty else { return nil }
        let lines = plan.map { item -> String in
            switch item.status {
            case .completed: return "[x] \(item.content)"
            case .inProgress: return "[>] \(item.content) (in progress)"
            case .pending: return "[ ] \(item.content)"
            }
        }
        return """
        CURRENT PLAN (from your last update_plan call). Continue from the in-progress item, and call update_plan as soon as an item is done or the plan changes:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Default number of tool calls `workLog` lists.
    static let workLogLimit = 20

    /// One line per tool call from earlier turns: what was called, on what,
    /// and how it went. Earlier turns' raw tool output never reaches the
    /// model again (`buildPrompt` sends only the prose), so without this a
    /// follow-up turn starts blind and re-lists, re-greps and re-reads to
    /// find out what it already knew. Subagent internals and plan updates are
    /// left out — the delegate_task row and the plan block cover those.
    static func workLog(from messages: [ChatMessage], limit: Int = workLogLimit) -> String? {
        let planToolName = "\(namespace)__update_plan"
        let rows = messages.filter {
            $0.role == .toolCall && !$0.isSubagent
                && $0.toolName != planToolName
                && $0.toolStatus != .running
                && $0.toolStatus != .skipped
        }
        guard !rows.isEmpty, limit > 0 else { return nil }
        let recent = rows.suffix(limit)
        var lines = recent.map(workLogLine)
        if rows.count > recent.count {
            let omitted = rows.count - recent.count
            lines.insert("- (\(omitted) earlier call\(omitted == 1 ? "" : "s") not shown)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// The work log as a system-prompt block. `nil` when there's nothing to log.
    static func workLogPromptBlock(from messages: [ChatMessage], limit: Int = workLogLimit) -> String? {
        guard let log = workLog(from: messages, limit: limit) else { return nil }
        return """
        WORK LOG — tool calls from earlier turns of this chat, oldest first. Their raw output is no longer in context, and files may have changed since. Use this to go straight to the right file and line range instead of re-listing, re-searching and re-reading everything. You still have to read a file in this turn before editing it.
        \(log)
        """
    }

    /// Arguments worth showing in a work-log line, in display order. Bulky
    /// ones (old_string, new_string, content, code, items) are left out.
    private static let workLogArgumentKeys = [
        "path", "outline", "pattern", "glob", "query", "url", "offset", "limit",
        "source", "output", "format", "destination", "files", "sources", "task", "message"
    ]

    static func workLogLine(_ row: ChatMessage) -> String {
        let qualified = row.toolName ?? "tool"
        let name = qualified.range(of: "__").map { String(qualified[$0.upperBound...]) } ?? qualified

        var arguments: [String: Any] = [:]
        if let json = row.toolArgumentsJSON, let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = object
        }
        let argumentText = workLogArgumentKeys.compactMap { key -> String? in
            guard let value = arguments[key] else { return nil }
            let rendered: String
            if let list = value as? [Any] {
                let strings = list.map { "\($0)" }
                rendered = strings.prefix(3).joined(separator: ", ") + (strings.count > 3 ? ", +\(strings.count - 3) more" : "")
            } else if let string = value as? String {
                rendered = "\"\(oneLine(string, max: 60))\""
            } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                // JSON booleans arrive as NSNumber; don't print `true` as 1.
                rendered = number.boolValue ? "true" : "false"
            } else {
                rendered = "\(value)"
            }
            return "\(key): \(rendered)"
        }.joined(separator: ", ")

        let header = argumentText.isEmpty ? name : "\(name)(\(argumentText))"
        return "- \(header) → \(workLogOutcome(status: row.toolStatus, output: row.toolOutput ?? ""))"
    }

    /// Short outcome for a work-log line: the read window, the compile
    /// verdict, or the first line of the result.
    static func workLogOutcome(status: ChatMessage.ToolStatus?, output: String) -> String {
        switch status {
        case .failed: return "failed: \(oneLine(output, max: 120))"
        case .denied: return "declined by the user"
        case .cancelled: return "stopped before it finished"
        case .running: return "still running"
        case .skipped: return "not run (identical repeat)"
        case .succeeded, .none: break
        }
        let lines = output.components(separatedBy: "\n")
        // read_file / read_skill_file / web_fetch window header.
        if let window = lines.prefix(3).first(where: { $0.hasPrefix("[lines ") && $0.hasSuffix("]") }) {
            return "ok, " + String(window.dropFirst().dropLast())
        }
        let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        var outcome = oneLine(firstLine, max: 120)
        if output.contains("✓ Typst check: compiles cleanly") {
            outcome += " (compiles cleanly)"
        } else if output.contains("⚠️ Typst check") {
            outcome += " (Typst check reported problems)"
        }
        return outcome.isEmpty ? "ok" : outcome
    }

    private static func oneLine(_ text: String, max: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}
