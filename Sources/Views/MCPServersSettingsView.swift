import SwiftUI

/// Settings UI for MCP (Model Context Protocol) servers. A server is a local
/// command (most MCP servers today ship as `npx`/`uvx`/a binary) that
/// exposes a set of tools the AI can call mid-generation from the AI Prompt
/// panel, when the user enables that server for a request. Matches the
/// `mcpServers` config convention shared by Claude Desktop, Cursor, VS Code,
/// and OpenCode, so configs can be pasted in with minimal changes.
struct MCPServersSettingsView: View {
    @ObservedObject private var mcpManager = MCPManager.shared
    @State private var editingServer: ScopedMCPServer?
    @State private var isCreatingNew = false
    @State private var newServerScope: ConfigScope = .global
    @State private var testingServerID: String?

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
            MCPServerEditorSheet(mode: .edit(server))
        }
        .sheet(isPresented: $isCreatingNew) {
            MCPServerEditorSheet(mode: .create(scope: newServerScope))
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

                Button {
                    newServerScope = scope
                    isCreatingNew = true
                } label: {
                    Label("Add Server…", systemImage: "plus.circle")
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
    @ObservedObject private var mcpManager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var scope: ConfigScope = .global
    @State private var transport: MCPTransportType = .stdio
    @State private var command: String = ""
    @State private var argsText: String = ""
    @State private var envText: String = ""
    @State private var url: String = ""
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
                Label("\(transport.label) is not wired up to tool calling yet — the config is saved, but this server won't be usable until support is added.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

        if case .edit(let scoped) = mode {
            config.disabledTools = scoped.config.disabledTools
        }

        mcpManager.saveServer(config, scope: scope)
        dismiss()
    }
}
