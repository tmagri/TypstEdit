import Foundation

/// One entry in an AI Chat transcript. Persisted verbatim (see
/// `AIChatManager`), so this is deliberately a plain `Codable` value rather
/// than something tied to the live tool-calling loop's internal types.
struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        /// A tool the model called mid-conversation. Rendered as a compact
        /// activity line rather than a normal chat bubble.
        case toolCall
    }

    enum ToolStatus: String, Codable {
        case running
        case succeeded
        case failed
        case denied
    }

    var id: UUID = UUID()
    var role: Role
    var text: String = ""
    var timestamp: Date = Date()

    /// Captured reasoning/"thinking" content, when the model and provider
    /// expose it (OpenAI-compatible `reasoning_content`/`reasoning` fields,
    /// or inline `<think>`/`<thought>` tags some local/open models emit).
    /// Shown collapsed under the final answer rather than discarded — only
    /// set on `.assistant` messages, and only when the model actually
    /// returned something.
    var reasoning: String? = nil

    /// True for work done inside a `delegate_task` subagent, so the trace can
    /// be drawn as nested activity instead of the main agent's own steps.
    var isSubagent: Bool = false

    /// Older turns folded into a summary. Kept on disk (so the transcript is
    /// still readable as history) but excluded from the prompt sent to the
    /// model, which sees the summary instead.
    var isCompacted: Bool = false

    /// Marks the message that holds a compaction summary, so it can be
    /// styled distinctly from a normal answer.
    var isSummary: Bool = false

    // Only set when role == .toolCall
    var toolName: String? = nil
    var toolArgumentsJSON: String? = nil
    var toolStatus: ToolStatus? = nil
    var toolOutput: String? = nil
}

/// What's being asked of the user before a tool call is allowed to proceed.
/// The chat's agentic loop blocks on this — see `AIChatManager.pendingApproval`.
enum PendingApprovalKind {
    case fileWrite(relativePath: String, oldContent: String, newContent: String, isNewFile: Bool)
    /// A precise `edit_file` replacement: the snippets that matched, not the
    /// whole file, so the diff preview stays readable on a huge document.
    case fileEdit(relativePath: String, oldSnippet: String, newSnippet: String, occurrences: Int)
    case runPython(code: String)
    /// A `web_fetch` request. The full URL is shown for approval — worth
    /// glancing at the query string, since a fetch is also a request the
    /// destination server sees (a compromised page could try to exfiltrate
    /// project secrets by encoding them into URL parameters).
    case webFetch(url: String)
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let kind: PendingApprovalKind
    let toolCallName: String
}
