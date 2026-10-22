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
    case runPython(code: String)
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let kind: PendingApprovalKind
    let toolCallName: String
}
