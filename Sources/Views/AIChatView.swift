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
    @State private var showYoloConfirm = false
    @FocusState private var inputFocused: Bool
    @State private var shiftEnterMonitor: Any?

    /// Which past messages' "Thought process" disclosures are expanded.
    @State private var expandedThinkingIDs: Set<UUID> = []
    /// Whether the live "Thinking…" indicator (shown while generating) is
    /// expanded to follow the model's reasoning as it streams in.
    @State private var liveThinkingExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !aiSettings.chatEnabled {
                disabledState
            } else {
                transcript
                if !chat.plan.isEmpty {
                    Divider()
                    planCard
                }
                if chat.isCompacting {
                    Divider()
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing older turns…").font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                if let approval = chat.pendingApproval {
                    Divider()
                    approvalCard(approval)
                }
                Divider()
                inputBar
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            chat.refreshToolSettings()
            // Covers launches where no file or project was ever opened: the
            // `EditorController` observers that normally call `updateContext`
            // only fire on value *changes*, so the one-time skill seeding
            // would otherwise never run. Same-scope calls are no-ops once
            // seeded, so this is safe to call on every appearance.
            chat.updateContext(projectRoot: controller.projectRootURL, currentFileURL: controller.currentFileURL)
            installShiftEnterMonitor()
        }
        .onDisappear { removeShiftEnterMonitor() }
        .alert("Enable YOLO mode?", isPresented: $showYoloConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable", role: .destructive) { chat.yoloMode = true }
        } message: {
            Text("Every file write, edit, and Python run will execute without asking you first for the rest of this app session. The AI can still only touch files inside this project/notebook. YOLO turns itself off when TypstEdit restarts.")
        }
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
                Text("≈\(Self.contextLabel(chat.estimatedContextTokens)) / \(Self.contextLabel(aiSettings.chatContextBudgetTokens))")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(chat.estimatedContextTokens > aiSettings.chatContextBudgetTokens ? .orange : .secondary)
                    .help("Rough estimate of the conversation context sent with the next message, against the configured budget. Older turns are summarized automatically when this is exceeded.")
                Button {
                    Task { await chat.compactHistory() }
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .buttonStyle(.plain)
                .disabled(chat.isGenerating || chat.isCompacting || chat.messages.isEmpty)
                .help("Summarize older turns now to free up context")
                if liveThinkingExpanded || !expandedThinkingIDs.isEmpty {
                    Button {
                        expandedThinkingIDs = []
                        liveThinkingExpanded = false
                    } label: {
                        Image(systemName: "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .help("Collapse all thinking sections to keep the chat lean")
                }
                Button {
                    chat.clearHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear chat history — starts a new chat, so skills reset to their \"on by default\" settings")
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

    /// `0.8k`-style label that never collapses a small non-zero value to `0k`.
    private static func contextLabel(_ tokens: Int) -> String {
        if tokens < 1_000 {
            return "\(max(0, tokens))"
        }
        let thousands = Double(tokens) / 1_000
        return thousands < 10 ? String(format: "%.1fk", thousands) : "\(Int(thousands.rounded()))k"
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
                        generatingRow.id("generating-indicator")
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

    /// The live "Thinking…" row shown while a response is being generated.
    /// Plain spinner until the model actually streams some reasoning text —
    /// at that point it becomes a disclosure so there's something to open:
    /// click to follow the thinking live, click again (or "Collapse all
    /// thinking" in the header) to close it back down to just the spinner.
    @ViewBuilder
    private var generatingRow: some View {
        if chat.liveReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.caption).foregroundColor(.secondary)
            }
        } else {
            DisclosureGroup(isExpanded: $liveThinkingExpanded) {
                ScrollViewReader { innerProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(chat.liveReasoning)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("live-reasoning-end")
                        }
                    }
                    .frame(maxHeight: 180)
                    .onChange(of: chat.liveReasoning) { _ in
                        innerProxy.scrollTo("live-reasoning-end", anchor: .bottom)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        Group {
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
                if message.isSummary {
                    summaryBubble(message)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if let reasoning = message.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            thinkingDisclosure(reasoning, id: message.id)
                        }
                        HStack {
                            Text(message.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(10)
                            Spacer(minLength: 30)
                        }
                    }
                }
            case .toolCall:
                toolCallRow(message)
            }
        }
        .opacity(message.isCompacted ? 0.45 : 1)
    }

    @ViewBuilder
    private func summaryBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Earlier turns summarized", systemImage: "rectangle.compress.vertical")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(message.text.replacingOccurrences(of: "[Summary of earlier conversation]\n\n", with: ""))
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(10)
            }
            Spacer(minLength: 30)
        }
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundColor(.accentColor)
                Text("Plan").font(.caption.bold())
                Spacer()
                Text("\(chat.plan.filter { $0.status == .completed }.count)/\(chat.plan.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chat.plan) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            switch item.status {
                            case .completed:
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            case .inProgress:
                                Image(systemName: "circle.dotted").foregroundColor(.accentColor)
                            case .pending:
                                Image(systemName: "circle").foregroundColor(.secondary)
                            }
                            Text(item.content)
                                .font(.caption)
                                .foregroundColor(item.status == .completed ? .secondary : .primary)
                                .strikethrough(item.status == .completed)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
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
                if message.isSubagent {
                    Image(systemName: "person.2")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(displayName(for: message.toolName ?? "tool"))
                    .font(.caption.monospaced())
                    .foregroundColor(message.isSubagent ? .secondary : .primary)
            }
        }
        .padding(8)
        .padding(.leading, message.isSubagent ? 18 : 0)
        .background(Color.secondary.opacity(message.isSubagent ? 0.03 : 0.06))
        .cornerRadius(8)
    }

    /// Collapsed-by-default disclosure for whatever reasoning/"thinking"
    /// content the model returned alongside this answer — only shown when
    /// there's something to show, since not every model or provider exposes
    /// it. Expanding doesn't change anything else in the transcript; it's
    /// purely a window into what the model worked through. Expansion state
    /// is keyed by message id so "Collapse all thinking" in the header can
    /// close every one of these at once.
    @ViewBuilder
    private func thinkingDisclosure(_ reasoning: String, id: UUID) -> some View {
        DisclosureGroup(isExpanded: thinkingBinding(for: id)) {
            Text(reasoning)
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label("Thought process", systemImage: "brain")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func thinkingBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedThinkingIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedThinkingIDs.insert(id) } else { expandedThinkingIDs.remove(id) }
            }
        )
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
        case .cancelled: Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
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

            case .fileEdit(let path, let oldSnippet, let newSnippet, let occurrences):
                HStack(spacing: 6) {
                    Image(systemName: "pencil.circle.fill").foregroundColor(.orange)
                    Text("Edit '\(path)'\(occurrences > 1 ? " (\(occurrences) places)" : "")?")
                        .font(.subheadline.bold())
                }
                diffPreview(old: oldSnippet, new: newSnippet)
                    .frame(maxHeight: 180)

            case .webFetch(let urlString):
                HStack(spacing: 6) {
                    Image(systemName: "globe").foregroundColor(.orange)
                    Text("Fetch this web page?").font(.subheadline.bold())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(urlString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Glance at the URL before approving — the destination server sees this request, so a crafted page could try to encode project data into it. Only public internet addresses can be fetched.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)

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

                if chat.isGenerating {
                    // A sibling of the (disabled) TextEditor, so it stays
                    // pressable while generation runs — including while an
                    // approval is pending, since `isGenerating` covers that.
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 24)).foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isGenerating || chat.pendingApproval != nil)
                }
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

            Button {
                if chat.yoloMode {
                    chat.yoloMode = false
                } else {
                    showYoloConfirm = true
                }
            } label: {
                Label("YOLO", systemImage: chat.yoloMode ? "bolt.shield.fill" : "bolt.shield")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(chat.yoloMode ? .red : .secondary)
            .help(chat.yoloMode
                  ? "YOLO mode is ON — every write, edit, and code run is auto-approved for this session. Click to turn off."
                  : "YOLO mode: auto-approve every write, edit, and code run for the rest of this session (still limited to this project/notebook).")
        }
        .foregroundColor(.secondary)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await chat.sendMessage(text) }
    }

    // Shift+Enter submits the draft, like the send button. A local key monitor
    // (the same pattern EditorController uses for its paste shortcuts) is
    // installed while the panel is visible and removed when it leaves the
    // hierarchy, so it never outlives the sidebar tab.
    private func installShiftEnterMonitor() {
        guard shiftEnterMonitor == nil else { return }
        shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak chat = self.chat] event in
            let isShiftEnter = event.charactersIgnoringModifiers == "\r"
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.shift]
            guard isShiftEnter,
                  let chat,
                  !chat.isGenerating,
                  chat.pendingApproval == nil,
                  self.inputFocused,
                  !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return event }
            self.send()
            return nil // Consume it so the TextEditor doesn't also insert a newline
        }
    }

    private func removeShiftEnterMonitor() {
        if let monitor = shiftEnterMonitor {
            NSEvent.removeMonitor(monitor)
            shiftEnterMonitor = nil
        }
    }
}
