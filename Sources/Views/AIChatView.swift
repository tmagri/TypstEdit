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
            Text("File writes, edits, Python runs, and permitted Git actions (stage, commit, fetch, pull) will execute without asking you first for this app session. Push always requires your approval. YOLO does not enable Git permissions. The AI remains limited to this project/notebook, and Git tools require the repository root. YOLO turns itself off when TypstEdit restarts.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundColor(.accentColor)
            // Same squeeze rule as the sidebar section titles: the title and
            // scope line stay on single lines, truncating the scope label
            // with an ellipsis while there's room, and the whole block
            // disappears once even "AI Chat" no longer fits — instead of
            // wrapping into fragments that grow the header.
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI Chat")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(chat.scopeLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Color.clear
                    .frame(width: 0, height: 0)
            }
            Spacer()
            if aiSettings.chatEnabled {
                Text("≈\(Self.contextLabel(chat.estimatedContextTokens)) / \(Self.contextLabel(chat.contextBudgetTokens))")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .foregroundColor(chat.estimatedContextTokens > chat.contextBudgetTokens ? .orange : .secondary)
                    .help("Rough estimate of the conversation context sent with the next message, against this model's budget (a saved model can override the global setting). Older turns are summarized automatically when this is exceeded.")
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
                // Falls back to another visible panel, or hides the sidebar
                // when AI Chat is the only visible feature.
                controller.toggleAIChatPanel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close AI Chat")
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
        let reasoning = chat.liveReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusText = chat.liveStatus ?? "Thinking…"
        if let running = chat.runningTool {
            runningTaskRow(running)
        } else if reasoning.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(statusText).font(.caption).foregroundColor(.secondary)
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
                    Text(statusText).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    /// The live row while a tool task runs: what it is and how long it has
    /// been going, so a long build/export/Git call doesn't look like a stuck
    /// or empty chat. The task's own row in the transcript has the Stop
    /// button; this row only reports.
    private func runningTaskRow(_ running: AIChatManager.RunningTool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(running.startedAt))
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running \(running.displayName) — \(AIChatManager.elapsedLabel(elapsed))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .help("Waiting for this task to finish. Stop it from its row in the transcript.")
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
        HStack(alignment: .center, spacing: 8) {
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
                        .foregroundColor(message.isSubagent || message.toolStatus == .skipped ? .secondary : .primary)
                    if message.toolStatus == .skipped {
                        Text("not run")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            if message.toolStatus == .running {
                runningToolControls(message)
            }
        }
        .padding(8)
        .padding(.leading, message.isSubagent ? 18 : 0)
        .background(Color.secondary.opacity(message.isSubagent ? 0.03 : 0.06))
        .cornerRadius(8)
    }

    /// Elapsed time plus a Stop button for a task that is still running.
    /// Stopping it ends just this call; the assistant receives a "stopped"
    /// result and carries on, unlike the panel's full Stop.
    private func runningToolControls(_ message: ChatMessage) -> some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(message.timestamp))
                Text(AIChatManager.elapsedLabel(elapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Button {
                chat.stopTool(messageID: message.id)
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop this task and let the assistant continue without its result")
            .accessibilityLabel("Stop \(displayName(for: message.toolName ?? "task"))")
        }
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
        AIChatManager.toolDisplayName(qualifiedName)
    }

    @ViewBuilder
    private func statusIcon(_ status: ChatMessage.ToolStatus?) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .denied: Image(systemName: "hand.raised.fill").foregroundColor(.red)
        case .cancelled: Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        case .skipped:
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundColor(.secondary)
                .help("Not run — expand the row to see why")
                .accessibilityLabel("Not run")
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

            case .documentExport(let path, let format, let destination, let existingFile):
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up").foregroundColor(.orange)
                    Text("Export '\(path)' to \(format.uppercased())?").font(.subheadline.bold())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if existingFile {
                        Text("This replaces the existing file.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)

            case .fileCopy(let sources, let destination, let overwrite):
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").foregroundColor(.orange)
                    Text("Copy \(sources.count) item\(sources.count == 1 ? "" : "s") into '\(destination)'?")
                        .font(.subheadline.bold())
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(sources.prefix(20)), id: \.self) { source in
                            Text(source)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if sources.count > 20 {
                            Text("… and \(sources.count - 20) more")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if overwrite {
                            Text("Existing items in the destination will be replaced.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)

            case .createFolder(let path):
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus").foregroundColor(.orange)
                    Text("Create folder '\(path)'?").font(.subheadline.bold())
                }

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

            case .gitStage(let paths, let stage):
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").foregroundColor(.orange)
                    Text("\(stage ? "Stage" : "Unstage") \(paths.count) file\(paths.count == 1 ? "" : "s")?").font(.subheadline.bold())
                }
                gitPathList(paths)
                Text("Only the index changes; file contents are not touched.")
                    .font(.caption2).foregroundColor(.secondary)

            case .gitCommit(let message, let files, let branch, let stageAll):
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").foregroundColor(.orange)
                    Text("Commit \(files.count) file\(files.count == 1 ? "" : "s") on '\(branch)'?").font(.subheadline.bold())
                }
                if stageAll {
                    Text("These files are staged first, including untracked files:")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("Staged files:").font(.caption2).foregroundColor(.secondary)
                }
                gitPathList(files)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Message").font(.caption2).foregroundColor(.secondary)
                    Text(message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)
                Text("This creates a local commit. It does not push.")
                    .font(.caption2).foregroundColor(.secondary)

            case .gitNetwork(let operation, let branch, let upstream):
                HStack(spacing: 6) {
                    Image(systemName: operation == .push ? "arrow.up.circle" : "arrow.down.circle")
                        .foregroundColor(operation == .push ? .red : .orange)
                    Text("\(operation.rawValue) '\(branch)'?").font(.subheadline.bold())
                }
                if let upstream {
                    Text("Upstream: \(upstream)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(gitNetworkWarning(operation))
                    .font(.caption2)
                    .foregroundColor(operation == .push ? .red : .secondary)
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

    /// Paths for the Git approval cards, capped so a huge staging request
    /// cannot make the card unusable.
    @ViewBuilder
    private func gitPathList(_ paths: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(paths.prefix(25)), id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if paths.count > 25 {
                    Text("… and \(paths.count - 25) more")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxHeight: 120)
        .padding(8)
        .background(Color.black.opacity(0.06))
        .cornerRadius(6)
    }

    private func gitNetworkWarning(_ operation: GitNetworkAction) -> String {
        switch operation {
        case .push:
            return "Review before publishing: this sends local commits to the upstream. Your approval is required even in YOLO mode. It never force-pushes."
        case .fetch:
            return "Downloads remote changes without touching your branches or files."
        case .pull:
            return "Fast-forward only: if your branch and the remote have diverged, this fails instead of creating a merge. Files it updates are reloaded in open editors."
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

    // The picker row adapts as the panel narrows instead of overflowing —
    // the menus and the model chip are fixed-size, so the old single line
    // clipped on both edges ("…lls ⌄", "qwen3.8-27b-splas…", YOLO off
    // screen). Candidates are tried in order:
    //   1. all controls with labels, one line
    //   2. labels kept, model chip moved to its own second line
    //   3. icon-only controls on one line (tooltips carry the names)
    //   4. icon-only controls + the named model chip on its own line —
    //      compact enough for the sidebar's 150pt minimum width.
    private var pickersRow: some View {
        ViewThatFits(in: .horizontal) {
            pickersLine(modelOnOwnRow: false, iconOnly: false)
            pickersLine(modelOnOwnRow: true, iconOnly: false)
            pickersLine(modelOnOwnRow: false, iconOnly: true)
            pickersLine(modelOnOwnRow: true, iconOnly: true)
        }
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func pickersLine(modelOnOwnRow: Bool, iconOnly: Bool) -> some View {
        if modelOnOwnRow {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ragToggle(iconOnly: iconOnly)
                    skillsMenu(iconOnly: iconOnly)
                    toolsMenu(iconOnly: iconOnly)
                    Spacer(minLength: 0)
                    yoloToggle(iconOnly: iconOnly)
                }
                // On its own line the chip always has room for the name.
                HStack(spacing: 10) {
                    AIModelPickerMenu(feature: .chat)
                        .disabled(chat.isGenerating)
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(spacing: 10) {
                ragToggle(iconOnly: iconOnly)
                skillsMenu(iconOnly: iconOnly)
                toolsMenu(iconOnly: iconOnly)
                AIModelPickerMenu(feature: .chat, showsName: !iconOnly)
                    .disabled(chat.isGenerating)
                Spacer(minLength: 0)
                yoloToggle(iconOnly: iconOnly)
            }
        }
    }

    /// Icon, plus the text label only when the row variant has room for it.
    private func pickerLabel(_ text: String, systemImage: String, iconOnly: Bool) -> some View {
        Group {
            if iconOnly {
                Image(systemName: systemImage)
            } else {
                Label(text, systemImage: systemImage)
            }
        }
        .font(.caption2)
    }

    private func ragToggle(iconOnly: Bool) -> some View {
        Button {
            chat.ragToolEnabled.toggle()
        } label: {
            pickerLabel(
                "RAG",
                systemImage: chat.ragToolEnabled ? "magnifyingglass.circle.fill" : "magnifyingglass.circle",
                iconOnly: iconOnly
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(chat.ragToolEnabled ? .accentColor : .secondary)
        .help(chat.ragToolEnabled ? "Project search (RAG) is available to the AI. Click to turn off for this session." : "Project search (RAG) is off for this session. Click to turn back on.")
    }

    private func skillsMenu(iconOnly: Bool) -> some View {
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
            pickerLabel("Skills", systemImage: "sparkles.square.filled.on.square", iconOnly: iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which skills are available to the AI for this session")
    }

    private func toolsMenu(iconOnly: Bool) -> some View {
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
            pickerLabel("Tools", systemImage: "wrench.and.screwdriver", iconOnly: iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which MCP tool servers are available to the AI for this session")
    }

    private func yoloToggle(iconOnly: Bool) -> some View {
        Button {
            if chat.yoloMode {
                chat.yoloMode = false
            } else {
                showYoloConfirm = true
            }
        } label: {
            pickerLabel("YOLO", systemImage: chat.yoloMode ? "bolt.shield.fill" : "bolt.shield", iconOnly: iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundColor(chat.yoloMode ? .red : .secondary)
        .help(chat.yoloMode
              ? "YOLO mode is ON — writes, edits, code runs, and permitted local Git actions/pulls are auto-approved. Push still asks. Click to turn off."
              : "YOLO mode: auto-approve writes, edits, code runs, and permitted local Git actions/pulls for this session. Push always asks.")
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
