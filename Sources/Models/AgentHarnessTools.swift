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
}
