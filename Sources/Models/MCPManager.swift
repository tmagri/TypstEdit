import Foundation
import Combine

/// Owns configured MCP server definitions (global + project scoped) and the
/// live `MCPClient` process for each one that's actually running. Settings UI
/// reads/writes configs through this; `AICompletionService`'s tool-calling
/// loop reads live tools and executes calls through this.
@MainActor
final class MCPManager: ObservableObject {
    static let shared = MCPManager()

    @Published private(set) var globalServers: [MCPServerConfig] = []
    @Published private(set) var projectServers: [MCPServerConfig] = []
    @Published private(set) var toolsByServerID: [String: [MCPTool]] = [:]
    @Published private(set) var runningServerIDs: Set<String> = []
    @Published private(set) var lastErrors: [String: String] = [:]
    /// The active project's root, so the Settings window (which has no
    /// direct reference to `EditorController`) can still show/manage
    /// project-scoped servers and know when none is open.
    @Published private(set) var projectRoot: URL?

    private var clients: [String: MCPClient] = [:]

    private init() {
        refreshGlobal()
    }

    var allServers: [ScopedMCPServer] {
        globalServers.map { ScopedMCPServer(config: $0, scope: .global) } +
        projectServers.map { ScopedMCPServer(config: $0, scope: .project) }
    }

    var enabledServers: [ScopedMCPServer] {
        allServers.filter { $0.config.enabled && $0.config.isConfigured }
    }

    // MARK: - Project switching

    func setProjectRoot(_ url: URL?) {
        guard projectRoot != url else { return }
        for server in projectServers {
            stopClient(id: ScopedMCPServer(config: server, scope: .project).id)
        }
        projectRoot = url
        refreshProject()
    }

    func refreshAll() {
        refreshGlobal()
        refreshProject()
    }

    private func refreshGlobal() {
        globalServers = Array(MCPConfigStore.load(from: MCPConfigStore.globalConfigURL()).mcpServers.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshProject() {
        guard let root = projectRoot else {
            projectServers = []
            return
        }
        projectServers = Array(MCPConfigStore.load(from: ProjectSettingsManager.mcpConfigURL(for: root)).mcpServers.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - CRUD

    func saveServer(_ server: MCPServerConfig, scope: ConfigScope) {
        let url = configURL(for: scope)
        var file = MCPConfigStore.load(from: url)
        file.mcpServers[server.name] = server
        MCPConfigStore.save(file, to: url)
        // Restart to pick up the new definition if it was already running.
        stopClient(id: ScopedMCPServer(config: server, scope: scope).id)
        refreshAll()
    }

    func deleteServer(name: String, scope: ConfigScope) {
        let url = configURL(for: scope)
        var file = MCPConfigStore.load(from: url)
        file.mcpServers.removeValue(forKey: name)
        MCPConfigStore.save(file, to: url)
        stopClient(id: ScopedMCPServer(config: MCPServerConfig(name: name), scope: scope).id)
        refreshAll()
    }

    private func configURL(for scope: ConfigScope) -> URL {
        switch scope {
        case .global:
            return MCPConfigStore.globalConfigURL()
        case .project:
            guard let projectRoot else {
                // No active project: fall back to a config nobody reads from,
                // rather than crashing a Settings UI that's momentarily out
                // of sync with the active window.
                return FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-no-project-mcp.json")
            }
            return ProjectSettingsManager.mcpConfigURL(for: projectRoot)
        }
    }

    // MARK: - Lifecycle & Tool Access

    /// Starts the server's process (if not already running) and returns its
    /// client. Returns `nil` — recording the error in `lastErrors` — if the
    /// server is disabled, unconfigured, or fails to launch/handshake.
    @discardableResult
    func ensureStarted(_ scoped: ScopedMCPServer) async -> MCPClient? {
        guard scoped.config.enabled, scoped.config.isConfigured else { return nil }
        if let existing = clients[scoped.id], existing.isRunning {
            return existing
        }

        let client = MCPClient(config: scoped.config)
        clients[scoped.id] = client
        do {
            try await client.start()
            let tools = try await client.listTools()
            toolsByServerID[scoped.id] = tools
            runningServerIDs.insert(scoped.id)
            lastErrors.removeValue(forKey: scoped.id)
            return client
        } catch {
            lastErrors[scoped.id] = error.localizedDescription
            clients.removeValue(forKey: scoped.id)
            runningServerIDs.remove(scoped.id)
            return nil
        }
    }

    func stopClient(id: String) {
        clients[id]?.stop()
        clients.removeValue(forKey: id)
        runningServerIDs.remove(id)
        toolsByServerID.removeValue(forKey: id)
    }

    func stopAll() {
        for id in Array(clients.keys) { stopClient(id: id) }
    }

    /// Starts every enabled server in `scopedServers` that isn't already
    /// running and returns the union of their (non-disabled) tools, ready to
    /// hand to a provider's function-calling API.
    func availableTools(for scopedServers: [ScopedMCPServer]) async -> [MCPTool] {
        var result: [MCPTool] = []
        for scoped in scopedServers where scoped.config.enabled {
            guard let client = await ensureStarted(scoped) else { continue }
            let serverTools = client.tools.filter { !scoped.config.disabledTools.contains($0.name) }
            result.append(contentsOf: serverTools)
        }
        return result
    }

    func callTool(serverName: String, toolName: String, arguments: [String: Any]) async throws -> String {
        guard let (scoped, client) = findRunningClient(serverName: serverName) else {
            throw MCPError.toolNotFound(toolName)
        }
        if scoped.config.disabledTools.contains(toolName) {
            throw MCPError.serverDisabled
        }
        return try await client.callTool(name: toolName, arguments: arguments)
    }

    private func findRunningClient(serverName: String) -> (ScopedMCPServer, MCPClient)? {
        for scoped in allServers where scoped.config.name == serverName {
            if let client = clients[scoped.id], client.isRunning {
                return (scoped, client)
            }
        }
        return nil
    }
}
