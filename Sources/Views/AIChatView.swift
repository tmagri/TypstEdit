import SwiftUI
import AppKit

/// The AI Chat panel: a persistent, multi-turn conversation about the whole
/// open project (or current notebook) rather than a single insertion point.
/// Sits between the editor and the PDF preview, toggled the same way the
/// preview pane itself is. Disabled/hidden entirely until the user opts in
/// from Settings → AI Assistant → Chat.
struct AIChatView: View {
    @ObservedObject var controller: EditorController
    @ObservedObject private var chat = AIChatManager.shared
    @ObservedObject private var aiSettings = AISettingsManager.shared
    @ObservedObject private var skillsManager = SkillsManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !aiSettings.chatEnabled {
                disabledState
            } else {
                transcript
                if let approval = chat.pendingApproval {
                    Divider()
                    approvalCard(approval)
                }
                Divider()
                inputBar
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { chat.refreshToolSettings() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Chat").font(.subheadline.bold())
                Text(chat.scopeLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if aiSettings.chatEnabled {
                Button {
                    chat.clearHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear chat history")
            }
            Button {
                controller.sidebarContent = .files
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to Files")
        }
        .padding(10)
    }

    private var scopeNoun: String {
        chat.scopeLabel.lowercased().contains("notebook") ? "notebook" : "project"
    }

    // MARK: - Disabled (opt-in) State

    private var disabledState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("AI Chat is off")
                .font(.headline)
            Text("Like every AI feature here, chat is opt-in. Turn it on in Settings to let the AI read, search, and (with your approval) edit files across this \(scopeNoun).")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Open Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        messageRow(message).id(message.id)
                    }
                    if chat.isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.caption).foregroundColor(.secondary)
                        }
                        .id("generating-indicator")
                    }
                    if let error = chat.errorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text(error).font(.caption).foregroundColor(.red)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
                .padding(10)
            }
            .onChange(of: chat.messages.count) { _ in
                if let last = chat.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(message.text)
                    .font(.callout)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        case .assistant:
            HStack {
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(10)
                Spacer(minLength: 30)
            }
        case .toolCall:
            toolCallRow(message)
        }
    }

    @ViewBuilder
    private func toolCallRow(_ message: ChatMessage) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let args = message.toolArgumentsJSON, !args.isEmpty {
                    Text("Arguments").font(.caption2.bold()).foregroundColor(.secondary)
                    Text(args).font(.caption2.monospaced()).textSelection(.enabled)
                }
                if let output = message.toolOutput, !output.isEmpty {
                    Text("Result").font(.caption2.bold()).foregroundColor(.secondary)
                    Text(output).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(10)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                statusIcon(message.toolStatus)
                Text(displayName(for: message.toolName ?? "tool"))
                    .font(.caption.monospaced())
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func displayName(for qualifiedName: String) -> String {
        qualifiedName.replacingOccurrences(of: "__", with: " → ")
    }

    @ViewBuilder
    private func statusIcon(_ status: ChatMessage.ToolStatus?) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .denied: Image(systemName: "hand.raised.fill").foregroundColor(.red)
        case nil: Image(systemName: "wrench.and.screwdriver").foregroundColor(.secondary)
        }
    }

    // MARK: - Approval Card

    @ViewBuilder
    private func approvalCard(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch approval.kind {
            case .fileWrite(let path, let oldContent, let newContent, let isNewFile):
                HStack(spacing: 6) {
                    Image(systemName: isNewFile ? "doc.badge.plus" : "pencil.circle.fill")
                        .foregroundColor(.orange)
                    Text(isNewFile ? "Create '\(path)'?" : "Overwrite '\(path)'?")
                        .font(.subheadline.bold())
                }
                diffPreview(old: oldContent, new: newContent)
                    .frame(maxHeight: 180)

            case .runPython(let code):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text("Run this Python script?").font(.subheadline.bold())
                }
                Text("Runs with your full user permissions, no sandbox or network isolation. Review the code carefully.")
                    .font(.caption2).foregroundColor(.secondary)
                ScrollView {
                    Text(code)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(6)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)
            }

            HStack {
                Spacer()
                Button("Deny") { chat.resolveApproval(approved: false) }
                Button("Approve") { chat.resolveApproval(approved: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private func diffPreview(old: String, new: String) -> some View {
        if let ops = LineDiff.diff(old: old, new: new) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ops.enumerated()), id: \.offset) { _, op in
                        diffLine(op)
                    }
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.06))
            .cornerRadius(6)
        } else {
            // File too large to diff cheaply — fall back to showing both in full.
            HStack(alignment: .top, spacing: 8) {
                ScrollView { Text(old).font(.caption2.monospaced()) }
                ScrollView { Text(new).font(.caption2.monospaced()) }
            }
        }
    }

    @ViewBuilder
    private func diffLine(_ op: LineDiff.Op) -> some View {
        switch op {
        case .equal(let line):
            Text("  " + line).font(.caption2.monospaced()).foregroundColor(.secondary)
        case .insert(let line):
            Text("+ " + line).font(.caption2.monospaced()).foregroundColor(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
        case .delete(let line):
            Text("- " + line).font(.caption2.monospaced()).foregroundColor(.red)
                .strikethrough()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1))
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            pickersRow

            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $draft)
                    .focused($inputFocused)
                    .font(.callout)
                    .frame(height: 50)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    .disabled(chat.isGenerating || chat.pendingApproval != nil)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isGenerating || chat.pendingApproval != nil)
            }
        }
        .padding(10)
    }

    private var pickersRow: some View {
        HStack(spacing: 10) {
            Button {
                chat.ragToolEnabled.toggle()
            } label: {
                Label("RAG", systemImage: chat.ragToolEnabled ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(chat.ragToolEnabled ? .accentColor : .secondary)
            .help(chat.ragToolEnabled ? "Project search (RAG) is available to the AI. Click to turn off for this session." : "Project search (RAG) is off for this session. Click to turn back on.")

            Menu {
                if skillsManager.allSkills.isEmpty {
                    Text("No skills configured yet.")
                } else {
                    ForEach(skillsManager.allSkills) { skill in
                        Toggle(isOn: Binding(
                            get: { chat.selectedSkillIDs.contains(skill.id) },
                            set: { isOn in
                                if isOn { chat.selectedSkillIDs.insert(skill.id) } else { chat.selectedSkillIDs.remove(skill.id) }
                            }
                        )) {
                            Text("\(skill.name) · \(skill.scope.label)")
                        }
                    }
                }
            } label: {
                Label("Skills", systemImage: "sparkles.square.filled.on.square").font(.caption2)
            }
            .menuStyle(.borderlessButton).fixedSize()

            Menu {
                let servers = mcpManager.allServers.filter { $0.config.isConfigured }
                if servers.isEmpty {
                    Text("No MCP servers configured yet.")
                } else {
                    ForEach(servers) { server in
                        Toggle(isOn: Binding(
                            get: { chat.selectedMCPServerIDs.contains(server.id) },
                            set: { isOn in
                                if isOn { chat.selectedMCPServerIDs.insert(server.id) } else { chat.selectedMCPServerIDs.remove(server.id) }
                            }
                        )) {
                            Text("\(server.config.name) · \(server.scope.label)")
                        }
                    }
                }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver").font(.caption2)
            }
            .menuStyle(.borderlessButton).fixedSize()

            Spacer()
        }
        .foregroundColor(.secondary)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await chat.sendMessage(text) }
    }
}
