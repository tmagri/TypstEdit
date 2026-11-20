import SwiftUI

/// Settings UI for MCP (Model Context Protocol) servers. A server is a local
/// command (most MCP servers today ship as `npx`/`uvx`/a binary) that
/// exposes a set of tools the AI can call mid-generation from the AI Prompt
/// panel, when the user enables that server for a request. Matches the
/// `mcpServers` config convention shared by Claude Desktop, Cursor, VS Code,
/// and OpenCode, so configs can be pasted in with minimal changes.
struct MCPServersSettingsView: View {
    @ObservedObject var mcpManager: MCPManager
    @State private var editingServer: ScopedMCPServer?
    @State private var isCreatingNew = false
    @State private var newServerScope: ConfigScope = .global
    @State private var isPastingCommand = false
    @State private var pasteCommandScope: ConfigScope = .global
    @State private var testingServerID: String?
    @State private var signingInServerID: String?
    @State private var signInError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsCard(
                    title: "What is MCP?",
                    icon: "wrench.and.screwdriver",
                    description: "MCP servers give the AI extra tools it can call while generating a response in the AI Prompt panel — reading files, querying an API, searching a reference library, and so on. Servers run as local commands on your Mac and only start when you enable them for a request. Treat any server you add the same as running its command directly: only add ones you trust."
                ) {
                    EmptyView()
                }

                serversCard(title: "Global MCP Servers", scope: .global, servers: mcpManager.globalServers)

                if let projectRoot = mcpManager.projectRoot {
                    serversCard(title: "Project MCP Servers", scope: .project, servers: mcpManager.projectServers, subtitle: projectRoot.path)
                } else {
                    SettingsCard(
                        title: "Project MCP Servers",
                        icon: "folder.badge.gearshape",
                        description: "Open a project folder to add servers scoped to it (stored in .typstedit/mcp.json, shareable via git — use ${env:VAR} or ${keychain:name} instead of literal secrets)."
                    ) {
                        EmptyView()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditorSheet(mode: .edit(server), mcpManager: mcpManager)
        }
        .sheet(isPresented: $isCreatingNew) {
            MCPServerEditorSheet(mode: .create(scope: newServerScope), mcpManager: mcpManager)
        }
        .sheet(isPresented: $isPastingCommand) {
            MCPPasteCommandSheet(initialScope: pasteCommandScope, mcpManager: mcpManager)
        }
    }

    @ViewBuilder
    private func serversCard(title: String, scope: ConfigScope, servers: [MCPServerConfig], subtitle: String? = nil) -> some View {
        SettingsCard(title: title, icon: scope == .global ? "globe" : "folder", description: subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                if servers.isEmpty {
                    Text("No MCP servers yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(servers) { server in
                        serverRow(ScopedMCPServer(config: server, scope: scope))
                        if server.id != servers.last?.id {
                            Divider()
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        newServerScope = scope
                        isCreatingNew = true
                    } label: {
                        Label("Add Server…", systemImage: "plus.circle")
                    }
                    Button {
                        pasteCommandScope = scope
                        isPastingCommand = true
                    } label: {
                        Label("Paste Command…", systemImage: "doc.on.clipboard")
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ scoped: ScopedMCPServer) -> some View {
        let isRunning = mcpManager.runningServerIDs.contains(scoped.id)
        let toolCount = mcpManager.toolsByServerID[scoped.id]?.count
        let error = mcpManager.lastErrors[scoped.id]

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { scoped.config.enabled },
                    set: { newValue in
                        var updated = scoped.config
                        updated.enabled = newValue
                        mcpManager.saveServer(updated, scope: scoped.scope)
                    }
                ))
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(scoped.config.name).font(.body.weight(.medium))
                        Text(scoped.config.transport.label)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                        if isRunning {
                            Label("Running", systemImage: "circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundColor(.green)
                                .font(.caption2)
                        }
                    }
                    Text(commandPreview(scoped.config))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let toolCount {
                        Text("\(toolCount) tool\(toolCount == 1 ? "" : "s") available")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if scoped.config.transport.isRemote {
                        remoteSignInRow(scoped)
                    }
                    if let error {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button {
                    testingServerID = scoped.id
                    Task {
                        _ = await mcpManager.ensureStarted(scoped)
                        testingServerID = nil
                    }
                } label: {
                    if testingServerID == scoped.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                }
                .buttonStyle(.plain)
                .disabled(testingServerID != nil || !scoped.config.isConfigured)
                .help("Start the server and list its tools")

                Button { editingServer = scoped } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)

                Button {
                    mcpManager.deleteServer(name: scoped.config.name, scope: scoped.scope)
                } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A remote server has no process to start, so its state is "signed in or
    /// not". A server with an explicit Authorization header skips this: that
    /// header is the credential, and OAuth would only fight it.
    @ViewBuilder
    private func remoteSignInRow(_ scoped: ScopedMCPServer) -> some View {
        let hasStaticAuth = scoped.config.headers.keys.contains { $0.lowercased() == "authorization" }
        if !hasStaticAuth {
            let signedIn = mcpManager.isSignedIn(scoped)
            HStack(spacing: 6) {
                Image(systemName: signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    .foregroundColor(signedIn ? .green : .secondary)
                Text(signedIn ? "Signed in" : "Not signed in")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button(signedIn ? "Sign in again…" : "Sign in…") {
                    signingInServerID = scoped.id
                    Task {
                        do {
                            try await mcpManager.signIn(scoped)
                        } catch {
                            signInError = error.localizedDescription
                        }
                        signingInServerID = nil
                    }
                }
                .buttonStyle(.link)
                .font(.caption2)
                .disabled(signingInServerID != nil)
                if signedIn {
                    Button("Sign out") {
                        mcpManager.signOut(scoped)
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
                if signingInServerID == scoped.id {
                    ProgressView().controlSize(.small)
                }
            }
            if let signInError {
                Text(signInError)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
        }
    }

    private func commandPreview(_ config: MCPServerConfig) -> String {
        switch config.transport {
        case .stdio:
            let parts = [config.command ?? ""] + config.args
            return parts.joined(separator: " ")
        case .sse, .http:
            return config.url ?? "(no URL set)"
        }
    }
}

private enum MCPServerEditorMode {
    case create(scope: ConfigScope)
    case edit(ScopedMCPServer)
}

private struct MCPServerEditorSheet: View {
    let mode: MCPServerEditorMode
    @ObservedObject var mcpManager: MCPManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var scope: ConfigScope = .global
    @State private var transport: MCPTransportType = .stdio
    @State private var command: String = ""
    @State private var argsText: String = ""
    @State private var envText: String = ""
    @State private var url: String = ""
    @State private var headersText: String = ""
    @State private var enabled: Bool = true

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canUseProjectScope: Bool { mcpManager.projectRoot != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit MCP Server" : "New MCP Server")
                .font(.headline)

            TextField("Name (e.g. \"filesystem\")", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(isEditing)

            if !isEditing {
                Picker("Scope", selection: $scope) {
                    Text("Global").tag(ConfigScope.global)
                    Text("Project").tag(ConfigScope.project).disabled(!canUseProjectScope)
                }
                .pickerStyle(.segmented)
            }

            Picker("Transport", selection: $transport) {
                ForEach(MCPTransportType.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)

            if transport == .stdio {
                TextField("Command (e.g. npx)", text: $command)
                    .textFieldStyle(.roundedBorder)
                TextField("Arguments, space-separated (e.g. -y @org/some-mcp-server)", text: $argsText)
                    .textFieldStyle(.roundedBorder)

                Text("Environment Variables — one per line, KEY=VALUE. Use ${env:VAR} or ${keychain:name} instead of a literal secret for servers you'll share via git.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $envText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 70)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                if scope == .project && envText.split(separator: "\n").contains(where: { line in
                    guard let eq = line.firstIndex(of: "=") else { return false }
                    return MCPEnvironmentResolver.looksLikeLiteralSecret(String(line[line.index(after: eq)...]))
                }) {
                    Label("One of these values looks like a real secret. Project configs may be committed to git — consider ${keychain:name} instead.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                TextField("Server URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                Text("Remote servers speak \(transport == .http ? "Streamable HTTP (MCP 2025-03-26), which is what servers offer today" : "the older HTTP+SSE transport (MCP 2024-11-05)"). A server that answers 401 gets a browser sign-in: TypstEdit discovers the service, registers itself, and keeps the token in the Keychain — never in mcp.json.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Headers — one per line, NAME: VALUE. Use ${env:VAR} or ${keychain:name} instead of a literal token for servers you'll share via git.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $headersText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 70)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                if scope == .project && headersText.split(separator: "\n").contains(where: { line in
                    guard let colon = line.firstIndex(of: ":") else { return false }
                    return MCPEnvironmentResolver.looksLikeLiteralSecret(String(line[line.index(after: colon)...]))
                }) {
                    Label("One of these values looks like a real secret. Project configs may be committed to git — consider ${keychain:name} instead.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Toggle("Enabled", isOn: $enabled)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isEditing ? "Save" : "Create") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func load() {
        switch mode {
        case .create(let initialScope):
            scope = initialScope
        case .edit(let scoped):
            name = scoped.config.name
            scope = scoped.scope
            transport = scoped.config.transport
            command = scoped.config.command ?? ""
            argsText = scoped.config.args.joined(separator: " ")
            envText = scoped.config.env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            url = scoped.config.url ?? ""
            headersText = scoped.config.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            enabled = scoped.config.enabled
        }
    }

    private func save() {
        var config = MCPServerConfig(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        config.transport = transport
        config.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        config.args = argsText.split(separator: " ").map(String.init)
        config.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        config.enabled = enabled

        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = value }
        }
        config.env = env

        var headers: [String: String] = [:]
        for line in headersText.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        config.headers = headers

        if case .edit(let scoped) = mode {
            config.disabledTools = scoped.config.disabledTools
        }

        mcpManager.saveServer(config, scope: scope)
        dismiss()
    }
}

/// Add one or more MCP servers by pasting the command a server's README tells
/// you to run — `codex mcp add …`, `claude mcp add …`, `mcp add-json …` — or
/// an `mcpServers` JSON block. Nothing is executed: the line is parsed into a
/// config by `MCPAddCommand`, and the user sees exactly what will be saved
/// before it is.
private struct MCPPasteCommandSheet: View {
    let initialScope: ConfigScope
    @ObservedObject var mcpManager: MCPManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var parsed: [MCPServerConfig] = []
    @State private var errorMessage: String?
    @State private var scope: ConfigScope = .global

    private var canUseProjectScope: Bool { mcpManager.projectRoot != nil }

    /// Names already configured in the chosen scope, so the preview can warn
    /// before a paste overwrites one.
    private var existingNames: Set<String> {
        let servers = scope == .global ? mcpManager.globalServers : mcpManager.projectServers
        return Set(servers.map(\.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add MCP Server from Command")
                .font(.headline)

            Picker("Scope", selection: $scope) {
                Text("Global").tag(ConfigScope.global)
                Text("Project").tag(ConfigScope.project).disabled(!canUseProjectScope)
            }
            .pickerStyle(.segmented)

            Text("Paste the setup line from the server's documentation. TypstEdit reads it — it never runs it — and shows the server it describes. Examples:\n\n`codex mcp add affinity -- uvx mcp-proxy --transport sse http://localhost:6767/sse`\n`claude mcp add --transport http notion https://mcp.notion.com/mcp`\n`claude mcp add --env KEY=value airtable -- npx -y airtable-mcp-server`")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .onChange(of: text) { _ in parse() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !parsed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Will be added")
                        .font(.caption.weight(.semibold))
                    ForEach(parsed, id: \.name) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(server.name)
                                    .font(.caption.weight(.medium))
                                if existingNames.contains(server.name) {
                                    Text("replaces the existing entry")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            Text(summary(server))
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !server.env.isEmpty {
                                // Keys only: the values may carry tokens.
                                Text("env: " + server.env.keys.sorted().joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if !server.headers.isEmpty {
                                // Names only: a header value can be a token.
                                Text("headers: " + server.headers.keys.sorted().joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(parsed.count == 1 ? "Add" : "Add \(parsed.count) Servers") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            scope = initialScope
            parse()
        }
    }

    private func summary(_ server: MCPServerConfig) -> String {
        switch server.transport {
        case .stdio:
            return ([server.command ?? ""] + server.args).joined(separator: " ")
        case .sse, .http:
            return "\(server.transport.label): \(server.url ?? "")"
        }
    }

    private func parse() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = []
            errorMessage = nil
            return
        }
        do {
            parsed = try MCPAddCommand.parse(text)
            errorMessage = nil
        } catch {
            parsed = []
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        for server in parsed {
            mcpManager.saveServer(server, scope: scope)
        }
        dismiss()
    }
}
