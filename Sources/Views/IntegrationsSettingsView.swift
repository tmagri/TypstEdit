import SwiftUI
import AppKit

/// Settings > Integrations: lets external tools and AI agents find and use
/// TypstEdit's compiler (the `typstedit` command and the MCP server).
struct IntegrationsSettingsView: View {
    @State private var installedTool: URL? = AgentIntegrationManager.installedCommandLineTool()
    @State private var client: AgentIntegrationManager.AgentClient = .claudeCode
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var copied = false

    private var command: String { installedTool?.path ?? AgentIntegrationManager.executablePath }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                commandLineCard
                agentCard
                toolsCard
            }
            .padding(24)
            .frame(maxWidth: 820)
        }
        .onAppear { refresh() }
    }

    // MARK: - Command-line tool

    private var commandLineCard: some View {
        SettingsCard(
            title: "Command-Line Tool",
            icon: "terminal",
            description: "Install the `typstedit` command so scripts, terminals and AI agents can compile documents with TypstEdit's compiler — no window needed."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Status:") {
                    if let installedTool {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text(installedTool.path)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.dashed").foregroundColor(.secondary)
                            Text("Not installed")
                        }
                    }
                }

                if let installedTool, !AgentIntegrationManager.isOnPath(installedTool.deletingLastPathComponent()) {
                    Text("\(installedTool.deletingLastPathComponent().path) is not on your PATH. Add `export PATH=\"$HOME/.local/bin:$PATH\"` to ~/.zshrc, or install to /usr/local/bin instead.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.leading, 152)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsRow(label: "") {
                    HStack(spacing: 8) {
                        Button(installedTool == nil ? "Install" : "Reinstall") { install(admin: false) }
                        Button("Install to /usr/local/bin…") { install(admin: true) }
                            .help("Asks for an administrator password. /usr/local/bin is on every macOS PATH.")
                        if installedTool != nil {
                            Button("Uninstall") { uninstall() }
                        }
                    }
                }

                SettingsRow(label: "Try it:") {
                    Text("typstedit check report.typ   ·   typstedit compile report.typ --format png")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusIsError ? .red : .green)
                        .padding(.leading, 152)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - MCP

    private var agentCard: some View {
        SettingsCard(
            title: "AI Agents (MCP Server)",
            icon: "sparkles",
            description: "TypstEdit includes a Model Context Protocol server. Add it to your agent and it can check, compile and preview Typst documents with the same compiler and Markdown/Note conversion as the editor."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Agent:") {
                    Picker("", selection: $client) {
                        ForEach(AgentIntegrationManager.AgentClient.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }

                Text(client.hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 152)
                    .fixedSize(horizontal: false, vertical: true)

                let snippet = AgentIntegrationManager.configSnippet(for: client, command: command)
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy") { copy(snippet) }
                    if client == .claudeDesktop {
                        Button("Add to Claude Desktop") { addToClaudeDesktop() }
                    }
                    Spacer()
                    if installedTool == nil {
                        Text("Tip: install the command-line tool first for a path that survives moving the app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var toolsCard: some View {
        SettingsCard(title: "What Agents Can Do", icon: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 6) {
                Label("typst_check — errors and warnings with file, line, column and hints", systemImage: "checkmark.seal").font(.caption)
                Label("typst_compile — write PDF, PNG or SVG (pages, ppi, sys.inputs, root)", systemImage: "doc.richtext").font(.caption)
                Label("typst_render_preview — return rendered pages as images the agent can see", systemImage: "photo").font(.caption)
                Label("typstedit_open — open a file in TypstEdit for you to review", systemImage: "macwindow").font(.caption)
                Label("typstedit_info — versions and paths of TypstEdit and Typst", systemImage: "info.circle").font(.caption)
                Text("Agents without MCP support can run `typstedit check <file> --json` in a shell instead.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        installedTool = AgentIntegrationManager.installedCommandLineTool()
    }

    private func install(admin: Bool) {
        do {
            let url = admin
                ? try AgentIntegrationManager.installCommandLineToolWithAdministrator()
                : try AgentIntegrationManager.installCommandLineTool()
            report("Installed \(url.path). Run `typstedit --help` in a new terminal.")
        } catch AgentIntegrationManager.InstallError.cancelled {
            statusMessage = nil
        } catch {
            report(error.localizedDescription, isError: true)
        }
        refresh()
    }

    private func uninstall() {
        do {
            try AgentIntegrationManager.uninstallCommandLineTool()
            report("Removed the typstedit command.")
        } catch {
            report("Could not remove it: \(error.localizedDescription). Files in /usr/local/bin may need `sudo rm /usr/local/bin/typstedit`.", isError: true)
        }
        refresh()
    }

    private func addToClaudeDesktop() {
        do {
            try AgentIntegrationManager.addToClaudeDesktop()
            report("Added TypstEdit to Claude Desktop. Restart Claude Desktop to load it.")
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func report(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
    }
}
