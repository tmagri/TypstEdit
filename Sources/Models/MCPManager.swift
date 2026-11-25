import Foundation
import Combine

/// Owns configured MCP server definitions (global + project scoped) and the
/// live `MCPClient` process for each one that's actually running. Settings UI
/// reads/writes configs through this; `AICompletionService`'s tool-calling
/// loop reads live tools and executes calls through this.
///
/// One instance per window (see `ProjectContext`): project servers only run
/// for the window whose project defines them.
@MainActor
final class MCPManager: ObservableObject {
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
    /// Reconnects in flight, per server id. A burst of session expiries must
    /// produce one handshake, not one per call — see `reconnectAndRetry`.
    private var reconnects: [String: Task<Void, Never>] = [:]
    private var peerObserver: NSObjectProtocol?
    /// Replaces the clients a start builds, so a test can point them at a
    /// fake transport. Nil in production.
    var makeClient: ((MCPServerConfig) -> MCPClient)?

    init(skipConfigLoad: Bool = false) {
        if !skipConfigLoad { refreshGlobal() }
        peerObserver = NotificationCenter.default.addObserver(
            forName: .globalAIConfigurationDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.refreshAll()
                self.stopOutdatedClients()
            }
        }
    }

    /// Another window changed a global server: a running client started from
    /// the old definition is stopped and restarts on its next use.
    private func stopOutdatedClients() {
        let current = Dictionary(allServers.map { ($0.id, $0.config) }, uniquingKeysWith: { first, _ in first })
        for (id, client) in clients where current[id] != client.config {
            stopClient(id: id)
        }
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
        globalServers = Array(MCPConfigStore.load().mcpServers.values)
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
        notifyPeers()
    }

    func deleteServer(name: String, scope: ConfigScope) {
        let url = configURL(for: scope)
        var file = MCPConfigStore.load(from: url)
        file.mcpServers.removeValue(forKey: name)
        MCPConfigStore.save(file, to: url)
        stopClient(id: ScopedMCPServer(config: MCPServerConfig(name: name), scope: scope).id)
        refreshAll()
        notifyPeers()
    }

    private func notifyPeers() {
        NotificationCenter.default.post(name: .globalAIConfigurationDidChange, object: self)
    }

    private func configURL(for scope: ConfigScope) -> URL {
        switch scope {
        case .builtin:
            // MCP servers have no built-in scope; park any request in a config
            // nobody reads from, like the missing-project fallback below.
            return FileManager.default.temporaryDirectory.appendingPathComponent("typstedit-no-builtin-mcp.json")
        case .global:
            // `configURL()` honours a test's override and keeps an XCTest run
            // away from the user's real server list; `globalConfigURL()`
            // would write through to `~/Library/Application Support`.
            return MCPConfigStore.configURL()
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

        let client = makeClient.map { $0(scoped.config) } ?? MCPClient(config: scoped.config)
        // A server that adds or removes a tool mid-session says so with
        // `notifications/tools/list_changed`. Re-read its catalogue then, so
        // the model's next turn declares what the server has now, rather than
        // offering a tool that is gone or hiding one that just appeared.
        client.onToolsChanged = { [weak self, weak client] in
            guard let self, let client else { return }
            Task { await self.refreshTools(scoped, client: client) }
        }
        clients[scoped.id] = client
        do {
            try await client.start()
            let tools = try await client.listTools()
            toolsByServerID[scoped.id] = tools
            runningServerIDs.insert(scoped.id)
            lastErrors.removeValue(forKey: scoped.id)
            return client
        } catch {
            clients.removeValue(forKey: scoped.id)
            runningServerIDs.remove(scoped.id)
            toolsByServerID.removeValue(forKey: scoped.id)
            // The user's Stop is not the server's fault.
            //
            // This is the shape the MCP hang is reported in: the handshake
            // never answered, the user pressed Stop, and the cancellation
            // was written into `lastErrors` — which Settings and the chat's
            // Tools menu then showed forever as "Swift.CancellationError
            // error 1". The server was fine; the start was abandoned.
            // Recording nothing leaves the row honest ("not running"), and
            // the next turn simply tries again.
            guard !Self.isCancellation(error) else { return nil }
            lastErrors[scoped.id] = error.localizedDescription
            return nil
        }
    }

    /// Whether a failed start was really the user stopping the run.
    ///
    /// Matches the shapes cancellation actually arrives in: the MCP client
    /// resumes with `CancellationError`, `URLSession` reports
    /// `URLError.cancelled`, and a task asked to stop may surface either.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        return false
    }

    func stopClient(id: String) {
        clients[id]?.stop()
        clients.removeValue(forKey: id)
        runningServerIDs.remove(id)
        toolsByServerID.removeValue(forKey: id)
    }

    /// Re-reads one live server's catalogue after it announced a change.
    ///
    /// Guarded on identity: a notification can arrive after the client was
    /// replaced by a reconnect, and the old one's reply must not overwrite the
    /// new one's list. A failed re-read keeps the previous catalogue and
    /// records the error — a server whose `tools/list` transiently fails is
    /// still better used with its last known tools than dropped entirely.
    func refreshTools(_ scoped: ScopedMCPServer, client: MCPClient) async {
        guard clients[scoped.id] === client, client.isRunning else { return }
        do {
            let tools = try await client.listTools()
            guard clients[scoped.id] === client else { return }
            toolsByServerID[scoped.id] = tools
            lastErrors.removeValue(forKey: scoped.id)
        } catch {
            guard clients[scoped.id] === client else { return }
            lastErrors[scoped.id] = error.localizedDescription
        }
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

    /// Usage guidance each server's author wrote for the model, keyed by server
    /// name. Servers that send none are absent.
    ///
    /// Read after `availableTools(for:)` has started the servers, since the
    /// text only arrives in the `initialize` handshake.
    func instructions(for scopedServers: [ScopedMCPServer]) -> [String: String] {
        var result: [String: String] = [:]
        for scoped in scopedServers where scoped.config.enabled {
            guard let client = clients[scoped.id], client.isRunning,
                  let text = client.instructions else { continue }
            result[scoped.config.name] = text
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
        do {
            return try await client.callTool(name: toolName, arguments: arguments)
        } catch MCPError.sessionExpired {
            // A Streamable HTTP server that dropped the session answers 404 to
            // a request carrying the old id. One reconnect and retry is the
            // documented recovery; a second failure surfaces to the model.
            //
            // The reconnect is serialised per server rather than done inline:
            // the first failure tearing down the shared client would kill the
            // sibling calls still in flight on it, and a burst of expiries
            // would each start its own handshake. See `reconnectAndRetry`.
            return try await reconnectAndRetry(
                scoped: scoped,
                staleClient: client,
                toolName: toolName,
                arguments: arguments
            )
        }
    }

    /// Recovers from an expired session without stranding concurrent callers.
    ///
    /// Serialised per server so a burst of expiries produces one reconnect, not
    /// one per call. A caller whose client is already gone simply uses the
    /// replacement; a caller that arrives while a reconnect is in flight waits
    /// for it rather than starting a second handshake.
    private func reconnectAndRetry(
        scoped: ScopedMCPServer,
        staleClient: MCPClient,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> String {
        // Already replaced by a sibling: just use the replacement.
        if clients[scoped.id] !== staleClient, clients[scoped.id]?.isRunning == true {
            guard let current = clients[scoped.id] else { throw MCPError.sessionExpired }
            return try await current.callTool(name: toolName, arguments: arguments)
        }
        if let inflight = reconnects[scoped.id] {
            _ = await inflight.value
            guard let current = clients[scoped.id], current.isRunning else {
                throw MCPError.sessionExpired
            }
            return try await current.callTool(name: toolName, arguments: arguments)
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopClient(id: scoped.id)
            _ = await self.ensureStarted(scoped)
        }
        reconnects[scoped.id] = task
        await task.value
        reconnects[scoped.id] = nil

        guard let fresh = clients[scoped.id], fresh.isRunning else {
            throw MCPError.sessionExpired
        }
        return try await fresh.callTool(name: toolName, arguments: arguments)
    }

    // MARK: - Sign-in

    /// Whether a remote server currently has usable OAuth credentials.
    func isSignedIn(_ scoped: ScopedMCPServer) -> Bool {
        guard scoped.config.transport.isRemote else { return false }
        return MCPOAuthStore().load(serverName: scoped.config.name) != nil
    }

    /// Runs the browser sign-in (or a silent refresh) for a remote server and
    /// restarts its client, so the next request carries the new token — and
    /// the connection is verified to actually work with it.
    func signIn(_ scoped: ScopedMCPServer) async throws {
        stopClient(id: scoped.id)
        let client = MCPClient(config: scoped.config)
        try await client.signInInteractively()
        notifyPeers()
        if await ensureStarted(scoped) == nil {
            throw MCPOAuthError.tokenExchangeFailed(lastErrors[scoped.id] ?? "the server still refused the connection")
        }
    }

    /// Forgets a server's tokens and closes its connection.
    func signOut(_ scoped: ScopedMCPServer) {
        MCPClient(config: scoped.config).signOut()
        stopClient(id: scoped.id)
        notifyPeers()
    }

    /// The most recent error for a server, for the Settings row.
    func lastError(for scoped: ScopedMCPServer) -> String? {
        lastErrors[scoped.id]
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
