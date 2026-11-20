import Foundation

/// One row of the chat's visible task list — the same "keep the model (and
/// you) honest about multi-step work" idea as Claude Code's todo list. Kept
/// intentionally small: an imperative description and a status.
struct AgentPlanItem: Equatable, Identifiable, Codable {
    enum Status: String, Codable {
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

    /// Searches the parts of the conversation that left the context. Offered
    /// only once there is something to recall (`ConversationRecall`).
    static var recallTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "recall",
        description: "Search the earlier parts of this conversation that are no longer in your context: turns that were folded into the summary, and what earlier tool calls returned (file reads, searches, web pages, script output, subagent reports). Use it when you need the exact words behind something the summary or work log mentions — what the user asked for, a decision and its reason, a value a tool returned — instead of guessing or re-running a call whose result may differ. For the current content of a file, use read_file instead.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "What you are trying to find, in plain words, e.g. \"the citation style the user asked for\"."]
            ],
            "required": ["query"]
        ]
    ) }

    /// Asks the user a structured question and waits for the answer in place,
    /// instead of ending the turn and hoping the reply covers it. Only offered
    /// while Settings → AI Chat → Ask Questions is on, since a question blocks
    /// the run until someone answers — the wrong default for an unattended
    /// job, but a good one while planning.
    static var askQuestionTool: MCPTool { MCPTool(
        serverName: namespace,
        name: "ask_question",
        description: "Ask the user one or more questions and wait for the answers before continuing. Use it when a decision would otherwise be a guess: which of several structures they want, what a vague requirement means, or which of two conflicting instructions wins. Prefer it over asking in your reply, because the run resumes with the answer attached instead of ending. Keep it to what blocks you — a question costs the user's attention. The user can always type an answer that isn't in your options, and can dismiss the whole card, in which case you should proceed on a stated assumption. Do not use it to confirm something you were already asked to do.",
        inputSchema: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "description": "One or more questions to ask at once. Asking them together is cheaper than several rounds.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string", "description": "The question itself, in one sentence."],
                            "header": ["type": "string", "description": "Two or three words naming the topic, shown as the card's title."],
                            "options": [
                                "type": "array",
                                "description": "Suggested answers. If you recommend one, put it first and end its label with \" (Recommended)\".",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string", "description": "The answer, as short text."],
                                        "detail": ["type": "string", "description": "Optional one line on what choosing this means."]
                                    ],
                                    "required": ["label"]
                                ]
                            ],
                            "multiple": ["type": "boolean", "description": "Allow more than one option to be chosen. Default false."]
                        ],
                        "required": ["question"]
                    ]
                ]
            ],
            "required": ["questions"]
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
        "start_line", "end_line", "before_line",
        "source", "output", "format", "destination", "files", "sources", "task", "message"
    ]

    static func workLogLine(_ row: ChatMessage) -> String {
        "- \(workLogCall(row)) → \(workLogOutcome(status: row.toolStatus, output: row.toolOutput ?? ""))"
    }

    /// The call half of a work-log line, `name(key: value, …)`, without the
    /// outcome — for callers that only label the call and would otherwise
    /// scan its whole output for nothing.
    static func workLogCall(_ row: ChatMessage) -> String {
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

        return argumentText.isEmpty ? name : "\(name)(\(argumentText))"
    }

    /// Short outcome for a work-log line: the read window, the compile
    /// verdict, or the first line of the result.
    static func workLogOutcome(status: ChatMessage.ToolStatus?, output: String) -> String {
        switch status {
        case .failed: return "failed: \(oneLine(output, max: 120))"
        case .denied: return "declined by the user"
        case .cancelled: return "stopped before it finished"
        case .running: return "still running"
        case .skipped: return "not run"
        case .succeeded, .none: break
        }
        // Lazily: only the first few lines are read, and splitting a
        // multi-megabyte output whole to look at them dominated every caller.
        // read_file / read_skill_file / web_fetch window header.
        if let window = firstLine(in: output, within: 3, where: { $0.hasPrefix("[lines ") && $0.hasSuffix("]") }) {
            return "ok, " + String(window.dropFirst().dropLast())
        }
        let firstLine = firstLine(in: output, where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map(String.init) ?? ""
        var outcome = oneLine(firstLine, max: 120)
        if output.contains("✓ Typst check: compiles cleanly") {
            outcome += " (compiles cleanly)"
        } else if output.contains("⚠️ Typst check") {
            outcome += " (Typst check reported problems)"
        }
        return outcome.isEmpty ? "ok" : outcome
    }

    /// The first of the first `limit` lines of `text` that matches, reading
    /// no further into the text than that line.
    private static func firstLine(
        in text: String,
        within limit: Int = .max,
        where matches: (Substring) -> Bool
    ) -> Substring? {
        var start = text.startIndex
        var seen = 0
        while seen < limit {
            // Bytes, not Characters: `\r\n` is one Character and would hide
            // the break, where the old Foundation split found it.
            let end = text.utf8[start...].firstIndex(of: UInt8(ascii: "\n")) ?? text.endIndex
            let line = text[start..<end]
            if matches(line) { return line }
            seen += 1
            guard end < text.endIndex else { return nil }
            start = text.index(after: end)
        }
        return nil
    }

    private static func oneLine(_ text: String, max: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    // MARK: - Code mode (code__execute)

    /// The JavaScript escape hatch (`code__execute`). It lives here rather
    /// than in `LocalToolExecutor` because it is harness infrastructure: it
    /// does not touch files itself, it calls the tools that do, through the
    /// manager.
    ///
    /// The catalog in the description is what makes it usable. A model that
    /// cannot see the exact call signatures guesses at them and wastes the
    /// round, so every offered tool is listed with its arguments.
    static func executeTool(catalog: [MCPTool], computeSeconds: Int) -> MCPTool { MCPTool(
        serverName: "code",
        name: "execute",
        description: """
        Run a short JavaScript program that calls your other tools, and return only what you need from the results.

        Use it when one answer needs several reads or a filter over what they return. Example: read six files with Promise.all, then return only the headings that matched — one round instead of six, and the raw text never enters the conversation. For a single simple call, call that tool directly instead.

        The available tools, as `tools.<namespace>.<name>(arguments)`:

        \(catalogListing(catalog))

        Rules:
        - `await` and `return` work at the top level. Run independent calls together with `await Promise.all([...])`; a call that needs another's result must wait for it.
        - A tool that fails rejects the promise, so wrap calls in `try`/`catch` when a failure is possible (a declined approval, a missing file). Every call is still shown to the user for approval exactly as it would be on its own.
        - Return the smallest thing that answers the question — a count, a filtered array, a few lines. Returning a whole file defeats the purpose.
        - No imports, network, filesystem, timers or fetch: only `tools`. JavaScript runs in a restricted interpreter with \(computeSeconds) seconds of compute; waiting on a tool does not count against that.
        - The reply lists the tool calls the script made, so you do not need to report them yourself.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "description": "The JavaScript to run. Use `return` for the result you want back."
                ]
            ],
            "required": ["code"]
        ]
    ) }

    /// One line per tool, `namespace.name(arguments) → what it returns`, for
    /// the `execute` description. Only the argument names fit; the direct
    /// tool definition has the rest, and this is a reminder of what exists
    /// rather than a manual.
    ///
    /// Capped at `catalogBudget` characters: a session with several MCP
    /// servers can offer dozens of tools, and the listing duplicates names
    /// the declared tool schemas already carry. Past the budget the catalog
    /// degrades to one summary line per namespace — every tool is still
    /// declared to the model with its full signature, and
    /// `tools.<namespace>.<name>(...)` calls it all the same, so nothing is
    /// unreachable, only unnamed here.
    nonisolated static let catalogBudget = 2_400

    static func catalogListing(_ tools: [MCPTool], budget: Int = catalogBudget) -> String {
        guard !tools.isEmpty else { return "(none right now)" }
        var byNamespace: [String: [String]] = [:]
        for tool in tools {
            let signature = "\(tool.name)(\(argumentSummary(tool.inputSchema)))"
            byNamespace[tool.serverName, default: []].append(signature)
        }
        let namespaces = byNamespace.keys.sorted()
        let full = namespaces.map { namespace in
            "  tools.\(namespace): " + (byNamespace[namespace] ?? []).joined(separator: ", ")
        }.joined(separator: "\n")
        guard full.count > budget else { return full }
        let summaries = namespaces.map { namespace -> String in
            let count = byNamespace[namespace]?.count ?? 0
            return "  tools.\(namespace): \(count) tool\(count == 1 ? "" : "s")"
        }.joined(separator: "\n")
        return summaries
            + "\n  (catalog shortened to fit the prompt budget — every tool of these namespaces is also declared to you with its full signature, and `tools.<namespace>.<name>(...)` calls it the same way)"
    }

    /// `path, start_line?, end_line?` from a JSON Schema's `properties` and
    /// `required`.
    static func argumentSummary(_ schema: [String: Any]) -> String {
        guard let properties = schema["properties"] as? [String: Any], !properties.isEmpty else {
            return ""
        }
        let required = Set(schema["required"] as? [String] ?? [])
        return properties.keys.sorted().map { key in
            required.contains(key) ? key : key + "?"
        }.joined(separator: ", ")
    }

    /// Tools a `code__execute` script may call: everything offered, minus
    /// the one that makes no sense inside a script. `code__execute` itself
    /// would nest interpreters, and `agent__ask_question` blocks the run
    /// waiting on a card — a script waiting on a question, inside a call
    /// that is already waiting, is a deadlock the user would have to
    /// untangle by hand.
    nonisolated static func codeModeCanCall(_ qualifiedName: String) -> Bool {
        qualifiedName != "code__execute"
            && qualifiedName != "\(namespace)__ask_question"
    }
}
