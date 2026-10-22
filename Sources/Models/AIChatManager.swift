import Foundation
import Combine

/// Drives the AI Chat panel: a persistent, multi-turn conversation scoped to
/// the whole open project (or, for notes, just the current notebook) rather
/// than a single insertion point — unlike AI Prompt, which only ever touches
/// the current selection. This is the actual "harness" piece: it always has
/// the built-in project/notebook tools from `LocalToolExecutor` available,
/// plus whatever MCP servers and skills the user enables for it, run through
/// the same agentic tool-calling loop as AI Prompt.
///
/// One shared instance; `updateContext` is called whenever the active
/// project or file changes (see `EditorController`) and swaps in the right
/// scope, tool set, and persisted transcript.
@MainActor
final class AIChatManager: ObservableObject {
    static let shared = AIChatManager()

    @Published private(set) var messages: [ChatMessage] = []
    @Published var isGenerating: Bool = false
    @Published private(set) var pendingApproval: PendingApproval?
    @Published private(set) var scopeLabel: String = "Standalone — no file tools available"
    @Published var errorMessage: String?

    /// Skill/MCP server selections, mirroring `EditorController`'s AI Prompt
    /// selections but kept independent since chat and prompt requests can
    /// reasonably want different tools enabled.
    @Published var selectedSkillIDs: Set<String> = []
    @Published var selectedMCPServerIDs: Set<String> = []
    /// Per-session override for the built-in `search_project` (RAG) tool,
    /// toggleable right from the chat panel. Starts from
    /// `AISettingsManager.chatRAGToolEnabledDefault` and then persists for
    /// the rest of the app session regardless of scope changes — same
    /// behavior as the skill/MCP selections above.
    @Published var ragToolEnabled: Bool = AISettingsManager.shared.chatRAGToolEnabledDefault

    private let localTools = LocalToolExecutor()
    private var persistenceURL: URL?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    private init() {}

    // MARK: - Context Switching

    func updateContext(projectRoot: URL?, currentFileURL: URL?) {
        localTools.pythonToolEnabled = AISettingsManager.shared.chatPythonToolEnabled
        let newScope = Self.resolveScope(projectRoot: projectRoot, currentFileURL: currentFileURL)
        guard newScope != localTools.scope else { return }

        persist() // flush the outgoing scope's transcript before switching

        // Any approval still pending from the previous scope is moot now.
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        pendingApproval = nil

        localTools.scope = newScope
        persistenceURL = Self.persistenceURL(for: newScope)
        messages = Self.loadMessages(from: persistenceURL)
        scopeLabel = newScope.label
    }

    /// Re-reads the Python-tool opt-in from Settings — called when the chat
    /// panel appears, since the user may have just toggled it there.
    func refreshToolSettings() {
        localTools.pythonToolEnabled = AISettingsManager.shared.chatPythonToolEnabled
    }

    private static func resolveScope(projectRoot: URL?, currentFileURL: URL?) -> LocalToolExecutor.Scope {
        if let projectRoot {
            return .project(root: projectRoot)
        }
        if let currentFileURL {
            let notebooksRoot = NotebookManager.shared.rootDirectory.standardizedFileURL
            let filePath = currentFileURL.standardizedFileURL.path
            let rootPath = notebooksRoot.path
            if filePath.hasPrefix(rootPath + "/") {
                let relative = filePath.dropFirst(rootPath.count + 1)
                if let firstComponent = relative.split(separator: "/").first {
                    return .notebook(root: notebooksRoot.appendingPathComponent(String(firstComponent), isDirectory: true))
                }
            }
        }
        return .none
    }

    private static func persistenceURL(for scope: LocalToolExecutor.Scope) -> URL? {
        switch scope {
        case .project(let root):
            return ProjectSettingsManager.dotFolderURL(for: root).appendingPathComponent("chat/history.json")
        case .notebook(let root):
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let hash = AppTempDirectoryManager.projectHash(for: root)
            return appSupport.appendingPathComponent("TypstEdit/ChatHistory/\(hash).json")
        case .none:
            return nil
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let persistenceURL else { return }
        let folder = persistenceURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private static func loadMessages(from url: URL?) -> [ChatMessage] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatMessage].self, from: data)) ?? []
    }

    func clearHistory() {
        messages = []
        if let persistenceURL {
            try? FileManager.default.removeItem(at: persistenceURL)
        }
    }

    // MARK: - Sending Messages

    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        let history = messages.filter { $0.role != .toolCall }
        messages.append(ChatMessage(role: .user, text: trimmed))
        persist()

        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        let activeSkills = SkillsManager.shared.allSkills.filter { selectedSkillIDs.contains($0.id) }
        let scopedServers = MCPManager.shared.allServers.filter { selectedMCPServerIDs.contains($0.id) }
        let mcpTools = await MCPManager.shared.availableTools(for: scopedServers)
        localTools.ragToolEnabled = ragToolEnabled
        let tools = localTools.toolDescriptors() + mcpTools

        var systemPrompt = """
        You are the AI Chat assistant embedded in TypstEdit, a Typst/Markdown editor. Unlike a single-insertion prompt, you are having an ongoing conversation about the user's \(localTools.scope.noun) as a whole. Prefer using the available tools to read files, search the project, and verify Typst code rather than guessing at contents you haven't looked at. Explain briefly what you're about to do before calling a tool that changes anything.
        Current scope: \(scopeLabel)
        """
        if !activeSkills.isEmpty {
            systemPrompt += "\n\n" + activeSkills.map { "SKILL: \($0.name)\n\($0.body)" }.joined(separator: "\n\n---\n\n")
        }

        // fetchCompletionWithTools only takes a single prompt string, so prior
        // turns are folded into it as plain transcript text rather than a
        // structured message array — simplest way to give the chat real
        // multi-turn memory without changing that method's signature again.
        var transcript = ""
        for message in history.suffix(20) {
            let speaker = message.role == .user ? "User" : "Assistant"
            transcript += "\(speaker): \(message.text)\n\n"
        }
        let prompt = transcript.isEmpty ? trimmed : "\(transcript)User: \(trimmed)"

        do {
            let result = try await AICompletionService.shared.fetchCompletionWithTools(
                prompt: prompt,
                systemPrompt: systemPrompt,
                maxTokens: AISettingsManager.shared.maxTokens,
                tools: tools,
                executeTool: { [weak self] qualifiedName, argumentsJSON in
                    guard let self else { throw LocalToolError.invalidArguments("Chat session ended") }
                    return try await self.trackedToolCall(qualifiedName: qualifiedName, argumentsJSON: argumentsJSON)
                }
            )
            messages.append(ChatMessage(role: .assistant, text: result))
            persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Tool Dispatch

    /// Records a `.toolCall` transcript entry, executes the tool (routing to
    /// the built-in project/notebook tools or out to a configured MCP
    /// server), and updates that entry with the outcome — so the chat shows
    /// a live trace of everything the model did, not just its final answer.
    private func trackedToolCall(qualifiedName: String, argumentsJSON: String) async throws -> String {
        let messageID = UUID()
        messages.append(ChatMessage(
            id: messageID,
            role: .toolCall,
            toolName: qualifiedName,
            toolArgumentsJSON: argumentsJSON,
            toolStatus: .running
        ))
        persist()

        do {
            let output = try await performTool(qualifiedName: qualifiedName, argumentsJSON: argumentsJSON)
            updateToolMessage(id: messageID, status: .succeeded, output: output)
            return output
        } catch {
            let status: ChatMessage.ToolStatus
            if case LocalToolError.approvalDenied = error {
                status = .denied
            } else {
                status = .failed
            }
            updateToolMessage(id: messageID, status: status, output: error.localizedDescription)
            throw error
        }
    }

    private func updateToolMessage(id: UUID, status: ChatMessage.ToolStatus, output: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].toolStatus = status
        messages[index].toolOutput = output
        persist()
    }

    private func performTool(qualifiedName: String, argumentsJSON: String) async throws -> String {
        guard let separatorRange = qualifiedName.range(of: "__") else {
            throw MCPError.toolNotFound(qualifiedName)
        }
        let namespace = String(qualifiedName[..<separatorRange.lowerBound])
        let toolName = String(qualifiedName[separatorRange.upperBound...])
        let argumentsData = Data(argumentsJSON.utf8)
        let arguments = (try? JSONSerialization.jsonObject(with: argumentsData)) as? [String: Any] ?? [:]

        if namespace == LocalToolExecutor.namespace || namespace == LocalToolExecutor.pythonNamespace {
            return try await localTools.execute(toolName: toolName, arguments: arguments) { [weak self] kind in
                guard let self else { return false }
                return await self.requestApproval(kind, toolCallName: qualifiedName)
            }
        }
        return try await MCPManager.shared.callTool(serverName: namespace, toolName: toolName, arguments: arguments)
    }

    // MARK: - Approval Gate

    private func requestApproval(_ kind: PendingApprovalKind, toolCallName: String) async -> Bool {
        pendingApproval = PendingApproval(kind: kind, toolCallName: toolCallName)
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
    }

    func resolveApproval(approved: Bool) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
    }
}
