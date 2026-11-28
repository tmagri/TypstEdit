import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The AI Chat panel: a persistent, multi-turn conversation about the whole
/// open project (or current notebook) rather than a single insertion point.
/// Sits between the editor and the PDF preview, toggled the same way the
/// preview pane itself is. Disabled/hidden entirely until the user opts in
/// from Settings → AI Assistant → Chat.
///
/// `chat` is the conversation currently shown — one of the sessions owned by
/// `AIChatSessionStore` (which also owns the session menu: switching, new
/// chat, rename, import/export, delete). Switching away never stops a
/// conversation that's still generating; it keeps working in the background.
struct AIChatView: View {
    @ObservedObject var controller: EditorController
    @ObservedObject var chat: AIChatManager
    /// The window's own session store, skills and MCP servers (see
    /// `ProjectContext`).
    @ObservedObject var store: AIChatSessionStore
    @ObservedObject var skillsManager: SkillsManager
    @ObservedObject var mcpManager: MCPManager
    @ObservedObject private var aiSettings = AISettingsManager.shared

    /// The composer's text lives on the conversation (`chat.draft`), not here:
    /// the panel is destroyed when the sidebar switches to Files or the
    /// Calculator, and SwiftUI would take a local `@State` draft with it.
    @State private var showYoloConfirm = false
    @State private var showBypassConfirm = false
    @FocusState private var inputFocused: Bool
    @State private var shiftEnterMonitor: Any?

    /// Which past messages' "Thought process" disclosures are expanded.
    @State private var expandedThinkingIDs: Set<UUID> = []
    /// Which of those are showing the complete reasoning rather than the
    /// preview slice. Only set when the user clicks "Show full thought".
    @State private var fullThinkingIDs: Set<UUID> = []
    /// How many of the most recent messages the transcript keeps in the view.
    /// The full history stays in the model (and on disk); the extra rows are
    /// loaded on demand, so a long chat doesn't rebuild a `ForEach` over
    /// hundreds of messages on every update. The transcript stack is eager
    /// (see `transcript`), so this also bounds how many rows are laid out.
    @State private var transcriptWindow = 60
    /// The answer whose thinking was opened automatically when it finished —
    /// replaced (and closed) by the next answer, so one open thinking section
    /// carries over from the live row without every old one piling up.
    @State private var autoExpandedThinkingID: UUID?
    /// Whether the live "Thinking…" indicator (shown while generating) is
    /// expanded to follow the model's reasoning as it streams in. On by
    /// default: the thinking is part of what the user asked to see, not
    /// something buried behind an extra click. "Collapse all thinking" in the
    /// header still closes it, and each new turn opens it again.
    @State private var liveThinkingExpanded = true

    /// Shown when a paste, drop or pick left something out (too many images,
    /// too large, unreadable), so a silently dropped photo doesn't become a
    /// mystery. Cleared by the next successful attach.
    @State private var attachmentNotice: String?
    /// True while an image is dragged over the composer, so the drop target is
    /// visible before the user lets go.
    @State private var composerDropTargeted = false
    /// Set when the draft held a secret and Send was pressed: the review card
    /// replaces the field until the user sends or goes back to edit. The
    /// delivery the user asked for (send or queue) is replayed on approval.
    @State private var pendingRedaction: SecretRedaction?
    @State private var pendingRedactionQueued = false

    /// The in-conversation Find bar (⌘F). `findQuery` is matched live
    /// against every message; `findIndex` steps through the hits.
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findMatches: [ConversationSearch.Match] = []
    /// Bumped to pull keyboard focus onto the Find field when the bar opens.
    @State private var findFocusToken = 0
    /// The message a Find step should scroll to; consumed by an `onChange`
    /// inside the transcript's `ScrollViewReader`.
    @State private var findScrollTarget: UUID?
    /// Set when "Undo file changes" is pressed: the turn's revert plan,
    /// shown for confirmation before anything is written back.
    @State private var pendingUndo: (messageID: UUID, plan: FileRevert.Plan)?

    /// Guards the one-pending follow-up scroll, so a burst of streaming
    /// updates schedules at most one extra `scrollTo` instead of one per token.
    /// Deliberately *not* `@State`: flagging every schedule as UI state would
    /// rebuild the whole transcript many times a second, which is what made
    /// the live row flicker while it streamed.
    ///
    /// Also owns the programmatic-scroll window: while one of *our* follow
    /// scrolls is in flight (plus a short settle time), the bottom probe must
    /// not report, because a lazy stack lands a scroll using estimated row
    /// heights and only corrects them as rows materialize. Treating that
    /// landing as "the user scrolled away" used to disable autoscroll
    /// mid-generation, leaving the viewport parked on stale (often blank)
    /// space until the next click scrolled it back.
    @StateObject private var transcriptScroller = TranscriptScroller()

    /// Whether the transcript is scrolled to (or within a few points of) the
    /// bottom. Autoscroll only follows while this is true, so scrolling up to
    /// read an earlier step doesn't get yanked back down by the next token.
    /// Cleared by a genuine user scroll (see `TranscriptBottomProbe`), and set
    /// again only by an explicit "give me the newest part" action: the
    /// jump-to-latest pill, sending a message, or switching chats.
    @State private var transcriptAtBottom = true

    /// Bumped by the composer's send path. The transcript watches it to jump
    /// to the newest exchange on a real send — deliberately not inferred from
    /// a new `.user` message, because auto-proceed appends user-role
    /// continuations while the turn is still running, and those are not the
    /// user asking to be taken back to the bottom.
    @State private var scrollToLatestRequest = 0

    /// Height of the transcript's viewport. Cards under it (plan, case file,
    /// approval, compaction) come and go mid-run and resize it, which moves
    /// the bottom out of view; a resize re-anchors the follow target.
    @State private var transcriptViewportHeight: CGFloat = 0

    @State private var showRename = false
    @State private var renameDraft: String = ""
    @State private var actionError: String?
    @State private var showChatHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = store.storageNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }

            if !aiSettings.chatEnabled {
                disabledState
            } else {
                transcriptWithFind
                if let review = chat.ariaResult {
                    Divider()
                    ariaReviewCard(review)
                }
                if !chat.plan.isEmpty {
                    Divider()
                    planCard
                }
                if aiSettings.chatCaseFileEnabled, let caseFile = chat.caseFile {
                    Divider()
                    CaseFileCard(agent: chat, caseFile: caseFile)
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
                if let question = chat.pendingQuestion {
                    Divider()
                    questionCard(question)
                }
                if let surface = chat.pendingSurfaceUI {
                    Divider()
                    SurfaceCardView(agent: chat, pending: surface)
                }
                if let autoProceed = chat.autoProceed {
                    Divider()
                    autoProceedCard(autoProceed)
                }
                if let reason = chat.autoProceedStoppedReason, !chat.isGenerating {
                    Divider()
                    autoProceedStoppedCard(reason)
                }
                if chat.isPaused {
                    Divider()
                    pausedStrip
                }
                Divider()
                inputBar
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            chat.refreshToolSettings()
            // Covers launches where no file or project was ever opened: the
            // `EditorController` observers that normally call the store's
            // `updateContext` only fire on value *changes*, so the one-time
            // skill seeding would otherwise never run. Same-scope calls are
            // no-ops once seeded, so this is safe to call on every appearance.
            store.updateContext(projectRoot: controller.projectRootURL, currentFileURL: controller.currentFileURL)
            installShiftEnterMonitor()
        }
        .onDisappear { removeShiftEnterMonitor() }
        .alert("Enable YOLO mode?", isPresented: $showYoloConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable", role: .destructive) { chat.yoloMode = true }
        } message: {
            Text("File writes, edits, Python runs, and permitted Git actions (stage, commit, fetch, pull) will execute without asking you first for this app session. Push always requires your approval. YOLO does not enable Git permissions. The AI remains limited to this project/notebook, and Git tools require the repository root. YOLO turns itself off when TypstEdit restarts.")
        }
        .alert("Enable Bypass Permissions?", isPresented: $showBypassConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable", role: .destructive) { chat.bypassPermissions = true }
        } message: {
            Text("Every tool call in this conversation will run immediately with no approval card, no safety-monitor pause, no sandbox, network reachable, and sudo allowed. This turns off when TypstEdit restarts or when you turn off Unlock Bypass Permissions in Settings.")
        }
        .alert("Rename Chat", isPresented: $showRename) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.renameSession(chat.id, to: renameDraft) }
        } message: {
            Text("Names are shown in the chat menu and saved with the conversation.")
        }
        .alert("Couldn't Do That", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .alert("Undo file changes?", isPresented: Binding(
            get: { pendingUndo != nil },
            set: { if !$0 { pendingUndo = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingUndo = nil }
            Button("Undo", role: .destructive) {
                if let pending = pendingUndo, let outcome = chat.revertFileChanges(from: pending.messageID) {
                    if !outcome.failed.isEmpty {
                        actionError = "Some files could not be restored: "
                            + outcome.failed.map { "\($0.path) — \($0.reason)" }.joined(separator: "; ")
                    }
                }
                pendingUndo = nil
            }
        } message: {
            Text(undoAlertMessage)
        }
        .sheet(isPresented: $showChatHistory) {
            ChatHistorySheet(store: store, activeSessionID: chat.id)
        }
    }

    /// The confirmation for "Undo file changes": which files go back, and a
    /// warning on any that were touched since the AI wrote them.
    private var undoAlertMessage: String {
        guard let pending = pendingUndo else { return "" }
        let entries = pending.plan.entries
        var lines: [String] = []
        if entries.count == 1 {
            lines.append("This puts \(entries[0].relativePath) back the way it was before the AI changed it.")
        } else {
            lines.append("This puts \(entries.count) files back the way they were before the AI changed them, and removes files it created:")
            for entry in entries.prefix(10) {
                lines.append("• \(entry.relativePath)")
            }
            if entries.count > 10 {
                lines.append("• … and \(entries.count - 10) more")
            }
        }
        let changed = chat.filesChangedSinceRevert(pending.plan)
        if !changed.isEmpty {
            lines.append("")
            lines.append("These have changed since the AI wrote them — undoing also discards that later work: "
                + changed.map(\.relativePath).joined(separator: ", "))
        }
        lines.append("")
        lines.append("The conversation stays; the AI is told its edits were undone.")
        return lines.joined(separator: "\n")
    }

    private func askUndoFiles(messageID: UUID) {
        let plan = chat.fileRevertPlan(from: messageID)
        guard !plan.isEmpty else { return }
        pendingUndo = (messageID, plan)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundColor(.accentColor)
            // Same squeeze rule as the sidebar section titles: the title and
            // scope line stay on single lines, truncating the scope label
            // with an ellipsis while there's room, and the whole block
            // disappears once even the title no longer fits — instead of
            // wrapping into fragments that grow the header. The title is the
            // conversation's name (auto-written after the first reply, or
            // renamed by the user from the chat menu).
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.displayTitle)
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
                Text("\(chat.contextEstimate.isMeasured ? "" : "≈")\(Self.contextLabel(chat.estimatedContextTokens)) / \(Self.contextLabel(chat.contextBudgetTokens))")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .foregroundColor(chat.estimatedContextTokens > chat.contextBudgetTokens ? .orange : .secondary)
                    .help(contextHelpText)
                if let cost = sessionCostLabel {
                    Text(cost)
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                        .help(costHelpText)
                }
                Button {
                    Task { await chat.compactHistory() }
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .buttonStyle(.plain)
                .disabled(chat.isGenerating || chat.isCompacting || chat.messages.isEmpty)
                .help("Summarize older turns now to free up context")
                sessionsMenu
                Button {
                    showChatHistory = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Search and label conversations")
                Button {
                    // Starts a fresh conversation; the current one stays
                    // saved in the chat menu.
                    store.startNewSession()
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .buttonStyle(.plain)
                .help("New chat — the current conversation stays in the chat menu")
                if liveThinkingExpanded || !expandedThinkingIDs.isEmpty || !fullThinkingIDs.isEmpty {
                    Button {
                        expandedThinkingIDs = []
                        fullThinkingIDs = []
                        autoExpandedThinkingID = nil
                        liveThinkingExpanded = false
                    } label: {
                        Image(systemName: "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .help("Collapse all thinking sections to keep the chat lean")
                }
                Button {
                    store.clearSession(chat.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear this conversation — starts fresh, and skills reset to their \"on by default\" settings. The chat disappears from the menu.")
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

    // MARK: - Session Menu

    /// The conversation list and its actions: switching (any number can run
    /// at once — a still-generating one shows a live badge), plus rename,
    /// import/export and delete for the current conversation.
    private var sessionsMenu: some View {
        Menu {
            Button {
                store.startNewSession()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
            }
            if !store.sessions.isEmpty {
                Divider()
            }
            ForEach(store.sessions) { summary in
                let summaryManager = store.manager(for: summary.id)
                Button {
                    store.switchSession(to: summary.id)
                } label: {
                    Label {
                        Text(summary.displayTitle)
                    } icon: {
                        Image(systemName: Self.sessionIcon(isActive: summary.id == chat.id, manager: summaryManager))
                    }
                }
            }
            Divider()
            Button {
                renameDraft = chat.title
                showRename = true
            } label: {
                Label("Rename This Chat…", systemImage: "pencil")
            }
            Button {
                exportActiveSession()
            } label: {
                Label("Export Conversation…", systemImage: "square.and.arrow.up")
            }
            Button {
                importSession()
            } label: {
                Label("Import Conversation…", systemImage: "square.and.arrow.down.on.square")
            }
            Divider()
            Button(role: .destructive) {
                store.deleteSession(chat.id)
            } label: {
                Label("Delete This Chat", systemImage: "trash")
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .overlay(alignment: .topTrailing) {
                    // A dot while some *other* conversation is still
                    // generating or waiting for an approval.
                    if store.hasBackgroundActivity {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Conversations — switch, rename, import/export. Chats keep running while you're in another one.")
    }

    /// Icon per session row: a checkmark for the open one, live badges for a
    /// conversation still generating or waiting for an approval.
    private static func sessionIcon(isActive: Bool, manager: AIChatManager?) -> String {
        if isActive { return "checkmark" }
        if manager?.pendingApproval != nil { return "hand.raised.fill" }
        if manager?.isGenerating == true { return "ellipsis.bubble" }
        return "bubble.left"
    }

    private func exportActiveSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = AIChatSessionStore.exportFileName(from: chat.displayTitle) + ".json"
        panel.title = "Export Conversation"
        panel.message = "Save this conversation as a JSON file you can import again later."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportSession(chat.id, to: url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func importSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import Conversation"
        panel.message = "Select a TypstEdit conversation export (or an old chat history file)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.importSession(from: url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var scopeNoun: String {
        chat.scopeLabel.lowercased().contains("notebook") ? "notebook" : "project"
    }

    /// `0.8k`-style label that never collapses a small non-zero value to `0k`.
    /// Delegates to `TokenLabel` so the header, the tooltip and Settings all
    /// spell token counts the same way.
    private static func contextLabel(_ tokens: Int) -> String {
        TokenLabel.text(tokens)
    }

    /// The conversation's running cost, when any usage has been priced. A
    /// provider-reported figure is exact; an estimate from the saved model's
    /// pricing reads with a "≈", like the context figure does when no
    /// measurement has arrived yet.
    private var sessionCostLabel: String? {
        let usage = chat.sessionUsage
        guard let cost = usage.costUSD, !usage.isEmpty else { return nil }
        return (usage.isCostEstimated ? "≈" : "") + CostFormatter.usd(cost)
    }

    /// Tooltip for the cost figure in the header.
    private var costHelpText: String {
        let usage = chat.sessionUsage
        var text = "This conversation's running cost so far: \(Self.contextLabel(usage.promptTotal)) input"
        if usage.cacheRead > 0 {
            text += " (\(Self.contextLabel(usage.cacheRead)) cached)"
        }
        text += ", \(Self.contextLabel(usage.outputTotal)) output."
        if let cost = chat.sessionCostUSD {
            text += usage.isCostEstimated
                ? " Cost ≈ \(CostFormatter.usd(cost)) (estimated from the model's prices)."
                : " Cost: \(CostFormatter.usd(cost))."
        }
        return text
    }

    /// Tooltip for the header's context figure. Spells out whether the number
    /// is measured or estimated, and adds the conversation's running token and
    /// cost totals when they are known.
    private var contextHelpText: String {
        var text = chat.contextEstimate.isMeasured
            ? "The provider's own token count for the last request, plus an estimate of what has been added since, against this model's budget (a saved model can override the global setting)."
            : "Rough estimate of the conversation context sent with the next message, against this model's budget (a saved model can override the global setting). It becomes exact once the provider reports token usage."

        let usage = chat.sessionUsage
        if !usage.isEmpty {
            var totals = "\n\nThis conversation so far: \(Self.contextLabel(usage.promptTotal)) input"
            if usage.cacheRead > 0 {
                totals += " (\(Self.contextLabel(usage.cacheRead)) cached)"
            }
            totals += ", \(Self.contextLabel(usage.outputTotal)) output."
            if let cost = chat.sessionCostUSD {
                totals += usage.isCostEstimated
                    ? " Cost ≈ \(CostFormatter.usd(cost)) (estimated from the model's prices)."
                    : " Cost: \(CostFormatter.usd(cost))."
            }
            text += totals
        }

        text += " Older turns are summarized automatically when the budget is exceeded."
        return text
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

    /// Bookkeeping for the coalesced bottom scroll. A reference type so
    /// tracking a pending scroll doesn't invalidate the view.
    private final class TranscriptScroller: ObservableObject {
        var pending: Task<Void, Never>?

        /// How long after a programmatic scroll the bottom probe stays
        /// muted. Covers the scroll itself plus the lazy-row materialization
        /// (and height correction) it triggers.
        private var autoScrollGraceUntil = Date.distantPast

        /// Marks that a scroll we initiated is starting; opens (or extends)
        /// the grace window.
        func markProgrammaticScroll() {
            autoScrollGraceUntil = Date().addingTimeInterval(0.3)
        }

        /// True while a programmatic scroll (or its settle window) is
        /// active — the probe must not report in that period, or our own
        /// scrolls would read as user scrolls and strand the transcript.
        var isAutoScrolling: Bool {
            Date() < autoScrollGraceUntil
        }

        /// True from the moment a trackpad/wheel/scroller gesture starts
        /// until it (and its momentum) ends. Set from the probe's live-scroll
        /// notifications, i.e. only by the user. Following is suspended while
        /// this is set: a scroll we issue mid-gesture would fight the hand on
        /// the trackpad, and the gesture is precisely when its result must not
        /// be overwritten.
        var userIsScrolling = false
    }

    /// Anchor id for the invisible row pinned to the end of the transcript.
    /// Scrolling targets this instead of the last message: the live
    /// "Thinking…"/tool row sits *below* the last message, so scrolling to the
    /// message left both that row and the newest message's true (measured)
    /// height off the bottom — the "always one short" behaviour this fixes.
    private static let transcriptBottomID = "transcript-bottom"
    /// How many extra messages "Show earlier messages" reveals each time.
    private static let transcriptWindowStep = 60

    /// The newest slice of the transcript shown in the view. The manager still
    /// holds the whole conversation, so the model is unaffected.
    private var visibleMessages: [ChatMessage] {
        chat.messages.count <= transcriptWindow
            ? chat.messages
            : Array(chat.messages.suffix(transcriptWindow))
    }

    private var hiddenMessageCount: Int {
        max(0, chat.messages.count - transcriptWindow)
    }

    private var transcriptWithFind: some View {
        VStack(spacing: 0) {
            if showFind {
                findBar
            }
            transcript
        }
        // ⌘G steps through the Find hits — the menu does not claim it, so a
        // hidden shortcut button is enough. ⌘F comes through the Find menu
        // command instead, which routes here when this panel is showing.
        .background(
            Group {
                Button("") { stepFind(forward: true) }
                    .keyboardShortcut("g", modifiers: .command)
                    .opacity(0)
                Button("") { stepFind(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .opacity(0)
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .menuCommand)) { notification in
            guard notification.object as? String == "findInChat",
                  let target = notification.userInfo?["target"] as? EditorController,
                  target === controller else { return }
            openFind()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Deliberately not lazy. A `LazyVStack` sizes rows it hasn't
                // measured from an estimate; in a long chat of very uneven
                // rows (tool calls, code, thinking) that estimate inflates the
                // content height, and every bottom scroll then parks on empty
                // space below the real rows — the "messages vanish while it
                // runs" glitch, which only a manual scroll (re-measuring) fixed.
                // An eager stack lays out exactly; the message window above
                // keeps the row count bounded so that stays affordable.
                VStack(alignment: .leading, spacing: 10) {
                    if hiddenMessageCount > 0 {
                        Button {
                            // Looking at older output means the user is no
                            // longer following the live end of the chat, so
                            // pause autoscroll until they jump back.
                            transcriptAtBottom = false
                            transcriptWindow += Self.transcriptWindowStep
                        } label: {
                            Label(
                                "Show \(hiddenMessageCount) earlier message\(hiddenMessageCount == 1 ? "" : "s")",
                                systemImage: "arrow.up"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                    // Isolated so a streamed update — which only changes the
                    // live row below — doesn't re-render the whole history.
                    TranscriptHistory(
                        messages: visibleMessages,
                        expandedThinkingIDs: expandedThinkingIDs,
                        fullThinkingIDs: fullThinkingIDs,
                        findQuery: showFind ? findQuery.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                        currentFindHitID: showFind ? findMatches[safe: findIndex]?.messageID : nil,
                        row: { messageRow($0) }
                    )
                    if chat.isGenerating {
                        generatingRow.id("generating-indicator")
                    }
                    if let saveFailure = chat.transcriptSaveFailure {
                        // The transcript could not reach the disk. Distinct
                        // from a run error: the conversation keeps working,
                        // but what it says is at risk when the app quits —
                        // amber rather than red, and not dismissible, because
                        // it clears itself the next time a write lands (and
                        // takes precedence over the error row, which the
                        // engine mirrors it into).
                        saveFailureRow(saveFailure)
                    } else if let error = chat.errorMessage {
                        // Dismissible: the banner reports what went wrong but
                        // does not itself stop the conversation — a failed
                        // compaction, for one, leaves the turn running with
                        // the transcript intact — so the user must be able to
                        // clear it without sending a new message to do it.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { chat.errorMessage = nil } label: {
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("Dismiss this error")
                            .accessibilityLabel("Dismiss error")
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                    }
                    // Always present, so the bottom is reachable even in an
                    // empty (new) conversation with no last message. It is
                    // the very last thing in the content — no padding below
                    // it — so scrolling to it lands on the true bottom, not
                    // 10 points short; the stack's spacing above it gives the
                    // last row the same breathing room the padding used to.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomID)
                }
                .padding([.horizontal, .top], 10)
                // Passive probe for the real scroll position: it flips
                // `transcriptAtBottom` when *you* scroll the transcript, so
                // autoscroll can stop fighting you while you read earlier
                // output. It never scrolls anything itself, it stays muted
                // while the panel's own follow scrolls are in flight, and it
                // still reports real gestures during those mutes — otherwise
                // a stream of follow scrolls would hide the user's scroll for
                // the whole generation.
                .background(TranscriptBottomProbe(
                    isAtBottom: $transcriptAtBottom,
                    isProgrammaticScroll: { [transcriptScroller] in transcriptScroller.isAutoScrolling },
                    userIsScrolling: { [transcriptScroller] isScrolling in
                        transcriptScroller.userIsScrolling = isScrolling
                    }
                ))
            }
            .overlay(alignment: .bottomTrailing) {
                if !transcriptAtBottom {
                    jumpToLatestButton(proxy)
                }
            }
            // The viewport, not the content: a card appearing below the
            // transcript shrinks it and pushes the newest rows out of view.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { transcriptViewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { height in
                            transcriptViewportHeight = height
                        }
                }
            )
            .onChange(of: transcriptViewportHeight) { _ in followBottom(proxy) }
            // Opened on an existing conversation (or a newly switched one):
            // start at the newest exchange, not the top of the history.
            .onAppear { followBottom(proxy, force: true, animate: true) }
            // New chat / new session: reset the per-chat thinking state and
            // start at the bottom (which is all there is, usually).
            .onChange(of: chat.id) { _ in
                expandedThinkingIDs = []
                fullThinkingIDs = []
                autoExpandedThinkingID = nil
                liveThinkingExpanded = true
                transcriptWindow = Self.transcriptWindowStep
                transcriptAtBottom = true
                followBottom(proxy, force: true, animate: true)
            }
            // Structural changes: a message, tool row or error was added or
            // updated, or the live row appeared/disappeared.
            .onChange(of: chat.messages) { messages in
                // Carry an open live thinking box over to the finished answer,
                // so the reasoning doesn't disappear the moment it lands.
                if liveThinkingExpanded,
                   let last = messages.last,
                   last.role == .assistant,
                   last.id != autoExpandedThinkingID,
                   last.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    if let previous = autoExpandedThinkingID, previous != last.id {
                        expandedThinkingIDs.remove(previous)
                    }
                    autoExpandedThinkingID = last.id
                    expandedThinkingIDs.insert(last.id)
                }
                // A row was added or re-measured: keep following, but only if
                // the user hasn't taken the viewport over (see `followBottom`).
                followBottom(proxy)
            }
            // An explicit send (new turn or steer) is the user asking for the
            // newest exchange, so it overrides a manual scroll. Kept separate
            // from the message change above so machine-appended user-role
            // messages (goal continuations) never count as that request.
            .onChange(of: scrollToLatestRequest) { _ in
                followBottom(proxy, force: true)
            }
            .onChange(of: chat.isGenerating) { isGenerating in
                if isGenerating { liveThinkingExpanded = true }
                followBottom(proxy)
            }
            .onChange(of: chat.errorMessage) { _ in followBottom(proxy) }
            .onChange(of: chat.transcriptSaveFailure) { _ in followBottom(proxy) }
            .onChange(of: chat.isPaused) { _ in followBottom(proxy) }
            // Streaming updates only grow the live row, so they take the
            // coalesced path: a stream of deltas costs at most one scroll.
            .onChange(of: chat.liveReasoning) { _ in followBottom(proxy) }
            .onChange(of: chat.liveNarration) { _ in followBottom(proxy) }
            .onChange(of: chat.parallelWorkers) { _ in followBottom(proxy) }
            .onChange(of: chat.liveStatus) { _ in followBottom(proxy) }
            .onChange(of: chat.autoProceed) { _ in followBottom(proxy) }
            .onChange(of: chat.runningTool) { _ in followBottom(proxy) }
            // The A2UI form suspends the run on it, so bring it into view the
            // moment it appears (same rule as the question card).
            .onChange(of: chat.pendingSurfaceUI?.id) { _ in followBottom(proxy, force: true) }
            .onChange(of: chat.pendingApproval?.id) { _ in followBottom(proxy, force: true) }
            .onChange(of: chat.pendingQuestion?.id) { _ in followBottom(proxy, force: true) }
            // A Find step lands on its message, centered, without the live
            // end dragging the viewport away afterwards.
            .onChange(of: findScrollTarget) { target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                findScrollTarget = nil
            }
            // A fresh search updates the matches and resets to the first hit
            // without stealing focus.
            .onChange(of: findQuery) { query in
                findIndex = 0
                findMatches = ConversationSearch.matches(for: query, in: chat.messages)
            }
            .onChange(of: chat.messages.count) { _ in
                if showFind {
                    findMatches = ConversationSearch.matches(for: findQuery, in: chat.messages)
                }
            }
        }
    }

    // MARK: Find in conversation

    /// Opens the Find bar. Called from the Find menu command when the AI
    /// Chat panel is the visible sidebar content.
    func openFind() {
        showFind = true
        findFocusToken += 1
        findMatches = ConversationSearch.matches(for: findQuery, in: chat.messages)
    }

    private func closeFind() {
        showFind = false
        findQuery = ""
        findIndex = 0
        findMatches = []
    }

    /// Steps to the next/previous hit and scrolls the transcript there. With
    /// no hits yet it does nothing, so ⌘G in a chat you have not searched
    /// stays harmless.
    private func stepFind(forward: Bool) {
        guard showFind else {
            openFind()
            return
        }
        let matches = findMatches
        guard !matches.isEmpty else { return }
        let target: ConversationSearch.Match
        if findIndex < 0 || findIndex >= matches.count {
            target = forward ? matches.first! : matches.last!
            findIndex = forward ? 0 : matches.count - 1
        } else if let next = ConversationSearch.stepping(matches, from: findIndex, forward: forward) {
            target = next
            findIndex = matches.firstIndex(of: next) ?? findIndex
        } else {
            return
        }
        scrollToMatch(target)
    }

    /// Scrolls the message holding a hit into view. Rows are keyed by
    /// message id, so the anchor is the message, not the character offset.
    /// A hit older than the visible window first widens the window ("Show
    /// earlier messages" does the same by hand), since a scroll target that
    /// is not in the stack cannot be scrolled to.
    private func scrollToMatch(_ match: ConversationSearch.Match) {
        if let index = chat.messages.firstIndex(where: { $0.id == match.messageID }),
           chat.messages.count - index > transcriptWindow {
            transcriptWindow = chat.messages.count - index + Self.transcriptWindowStep
        }
        // Reading an earlier hit is a manual scroll: the live end must not
        // yank the viewport back while the user steps through results.
        transcriptAtBottom = false
        findScrollTarget = match.messageID
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            FindField(
                text: $findQuery,
                focusToken: $findFocusToken,
                onSubmit: { stepFind(forward: true) },
                onCancel: { closeFind() }
            )
            .frame(minWidth: 120)

            Text(findCountLabel)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(findMatches.isEmpty ? .secondary : .primary)
                .fixedSize()

            Button { stepFind(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(findMatches.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button { stepFind(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(findMatches.isEmpty)
            .help("Next match (⌘G)")

            Button { closeFind() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close find (esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var findCountLabel: String {
        guard !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Find in conversation"
        }
        let count = findMatches.count
        guard count > 0 else { return "No matches" }
        let position = min(max(findIndex + 1, 1), count)
        let suffix = count >= 1000 ? "1000+ matches" : "\(count) \(count == 1 ? "match" : "matches")"
        return "\(position) of \(suffix)"
    }

    /// The pill that brings you back after reading older output.
    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            transcriptAtBottom = true
            followBottom(proxy, force: true, animate: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.caption.bold())
                .padding(7)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .padding(12)
        .help("Jump to the newest part of the conversation")
        .accessibilityLabel("Jump to latest message")
    }

    /// Pins the transcript to its bottom — unless the user has taken over.
    /// A manual scroll (or a click on "Show earlier messages") puts the
    /// transcript in manual mode: `transcriptAtBottom` goes false and nothing
    /// here moves the viewport, however much the answer streams. It stays
    /// that way until the user asks for the newest part again — the
    /// jump-to-latest pill, a new send, or a session switch. The only
    /// exception is while a scroll gesture is *in progress*, where following
    /// is suspended outright so the view can't be yanked out from under the
    /// hand on the trackpad.
    ///
    /// The single short delay lets a row that was just appended finish being
    /// measured, which is what makes the scroll land on the real bottom
    /// instead of one row short. Scheduling is coalesced, so a burst of
    /// streamed reasoning costs one scroll rather than a visible jump per
    /// token.
    ///
    /// Streaming follows scroll without animation: an animated scroll over a
    /// lazy stack lands on estimated row heights, and the corrections that
    /// arrive as rows materialize can leave the landing short of the real
    /// bottom — which the bottom probe then misreads as the user scrolling
    /// away, killing autoscroll mid-generation. Every follow scroll opens the
    /// scroller's programmatic-scroll grace window first, so the probe stays
    /// muted while this scroll (and its settle) happens. `animate` stays on
    /// for the user-initiated paths (opening the panel, switching sessions,
    /// the jump-to-latest button), where the layout is settled.
    private func followBottom(_ proxy: ScrollViewProxy, force: Bool = false, animate: Bool = false) {
        guard force || transcriptAtBottom else { return }
        // Never move the transcript under a hand that is currently scrolling
        // it: the gesture decides where the viewport ends up, and the probe
        // will report that position when the gesture finishes.
        guard force || !transcriptScroller.userIsScrolling else { return }
        if force { transcriptAtBottom = true }
        guard transcriptScroller.pending == nil else { return }
        transcriptScroller.pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            transcriptScroller.pending = nil
            // Re-checked after the delay: a token can land in the same tick
            // the user starts scrolling, and the scroll scheduled here must
            // not drag them back after they have moved away.
            guard force || (transcriptAtBottom && !transcriptScroller.userIsScrolling) else { return }
            transcriptScroller.markProgrammaticScroll()
            if animate {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
            }
        }
    }

    /// The live row shown while a response is being generated.
    ///
    /// Two independent streams feed it: the model's reasoning (in the
    /// collapsible box) and the answer it is writing. Showing the answer as it
    /// arrives is what stops a slow model from looking stuck for a minute and
    /// then dropping a whole reply at once. A running tool call is reported on
    /// its own line, so neither stream has to hide while a task runs.
    @ViewBuilder
    private var generatingRow: some View {
        let reasoning = chat.liveReasoning
        let answer = chat.liveAnswer
        let statusText = chat.liveStatus ?? "Thinking…"
        VStack(alignment: .leading, spacing: 6) {
            // One row per delegate_parallel worker. They cannot share the
            // reasoning box below: four streams in one buffer tangle together,
            // and nobody could tell which job stalled.
            ForEach(chat.parallelWorkers) { worker in
                parallelWorkerRow(worker)
            }
            // The rounds that already finished this turn, zipped: a long
            // engineering turn narrates before each of its dozens of rounds,
            // and drawn in full they push the answer being written off screen.
            if !chat.liveNarration.isEmpty {
                narrationBox
            }
            if reasoning.isEmpty {
                // No thinking to show (or the model doesn't expose any).
                if let running = chat.runningTool {
                    runningTaskRow(running)
                } else if answer.isEmpty && chat.parallelWorkers.isEmpty && chat.liveNarration.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(statusText).font(.caption).foregroundColor(.secondary)
                    }
                }
            } else {
                liveThinkingBox(statusText: statusText)
                if let running = chat.runningTool {
                    runningTaskRow(running)
                }
            }
            if !answer.isEmpty {
                liveAnswerPreview(answer)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    /// One `delegate_parallel` worker: what its brief is doing, and (when it
    /// has streamed any) its reasoning in a zipped disclosure — ported from
    /// Clippy's live row, which solves the same four-streams-one-buffer
    /// problem this engine's `parallelWorkers` exists for.
    @ViewBuilder
    private func parallelWorkerRow(_ worker: ParallelWorkerState) -> some View {
        if worker.reasoning.isEmpty {
            Text("Brief \(worker.index) · \(worker.status)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            DisclosureGroup {
                ScrollView {
                    Text(worker.reasoning)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            } label: {
                Text("Brief \(worker.index) · \(worker.status)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The finished rounds' narration of this turn, zipped and capped like
    /// the reasoning box. The round in flight stays below it, always visible.
    private var narrationBox: some View {
        DisclosureGroup {
            ScrollView {
                MarkdownText(text: chat.liveNarration, font: .caption2)
                    .equatable()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(.top, 2)
        } label: {
            Text("Earlier steps (\(chat.liveNarrationStepCount))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// The newest slice of the answer being written. Bounded for the same
    /// reason as the reasoning preview: a long reply would otherwise re-lay
    /// out on every token. The finished message carries the full text.
    private func liveAnswerPreview(_ answer: String) -> some View {
        let limit = 1_500
        let text = answer.count > limit ? "…\n" + String(answer.suffix(limit)) : answer
        return HStack(alignment: .top, spacing: 6) {
            ProgressView().controlSize(.small).padding(.top, 2)
            MarkdownText(text: text, font: .callout)
                .equatable()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.10))
        .cornerRadius(8)
    }

    /// The newest slice of the live reasoning, and the only part laid out in
    /// the panel. Very long thoughts would otherwise re-lay out the entire
    /// transcript on every streamed token; the full text is kept on the
    /// finished message.
    private var liveReasoningPreview: String {
        let limit = 1_500
        let text = chat.liveReasoning
        guard text.count > limit else { return text }
        return "…\n" + String(text.suffix(limit))
    }

    /// Expandable live reasoning, following the newest text as it streams.
    private func liveThinkingBox(statusText: String) -> some View {
        DisclosureGroup(isExpanded: $liveThinkingExpanded) {
            ScrollViewReader { innerProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(liveReasoningPreview)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("live-reasoning-end")
                    }
                }
                .frame(maxHeight: 180)
                .onAppear { innerProxy.scrollTo("live-reasoning-end", anchor: .bottom) }
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
    }

    /// The live row while a tool task runs: what it is and how long it has
    /// been going, so a long build/export/Git call doesn't look like a stuck
    /// or empty chat.
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
            .help("Waiting for this task to finish. Stop ends the whole run from the composer.")
        }
    }

    /// The transcript-write failure: what went wrong, in the file layer's own
    /// words. Not dismissible on purpose — a full disk emptied an hour later
    /// clears it on its own, and until then the risk must stay visible.
    private func saveFailureRow(_ failure: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "tray.full.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This conversation could not be saved to disk.")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                Text(failure)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("The conversation stays here while TypstEdit is open, but what it holds will be lost when the app quits if the problem is not fixed.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(6)
    }

    /// A paused run: the turn finished and the agent is holding, waiting for
    /// the user rather than for a clock. Deliberately not an auto-proceed
    /// countdown — a pause has no round to spend and no reset time to wait
    /// out, so a "Continuing automatically in…" would be a lie. Ported from
    /// Clippy's paused strip.
    private var pausedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Paused — the last instruction finished.", systemImage: "pause.circle")
                    .font(.caption)
                Spacer()
                Button("Resume") {
                    scrollToLatestRequest += 1
                    chat.resumeFromPause()
                }
                .controlSize(.small)
                Button("Stop") { chat.stop() }
                    .controlSize(.small)
            }
            Text("Resume carries on from exactly where it stopped. Nothing is re-sent, and the plan and case file are untouched.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        messageRowContent(message, undoableFileTurns: undoableFileTurns)
            .overlay {
                // The Find bar's hits are marked with a tint, the one it is
                // currently on with an accent outline — the same "highlighted
                // vs selected" language as a text editor's find.
                if isCurrentFindHit(message) {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .padding(1)
                }
            }
            .background {
                if !isCurrentFindHit(message), !findQuery.isEmpty, containsFindHit(message) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.yellow.opacity(0.14))
                }
            }
            .opacity(message.isCompacted ? 0.45 : 1)
    }

    private var trimmedFindQuery: String {
        findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCurrentFindHit(_ message: ChatMessage) -> Bool {
        guard let id = findMatches[safe: findIndex]?.messageID else { return false }
        return id == message.id
    }

    private func containsFindHit(_ message: ChatMessage) -> Bool {
        ConversationSearch.searchableText(of: message)
            .localizedCaseInsensitiveContains(trimmedFindQuery)
    }

    /// Computed once per transcript render, not once per row: the map is
    /// linear in messages, and a row-by-row lookup would make it quadratic.
    private var undoableFileTurns: [UUID: Int] { chat.undoableFileTurns }

    /// The chat whose turn this row belongs to changed `count` distinct
    /// project files.
    @ViewBuilder
    private func messageRowContent(_ message: ChatMessage, undoableFileTurns: [UUID: Int]) -> some View {
        Group {
            switch message.role {
            case .user:
                HStack {
                    Spacer(minLength: 30)
                    VStack(alignment: .trailing, spacing: 6) {
                        if message.hasImages {
                            ChatImageGridView(images: message.imageAttachments)
                        }
                        if !message.text.isEmpty {
                            Text(message.text)
                                .font(.callout)
                                .padding(8)
                                .background(Color.accentColor.opacity(0.85))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .textSelection(.enabled)
                        }
                        if let fileCount = undoableFileTurns[message.id] {
                            Button { askUndoFiles(messageID: message.id) } label: {
                                Label("Undo file changes (\(fileCount))", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.link)
                            .help("Put every project file this turn changed back the way it was, and remove files the AI created")
                        }
                    }
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
                            MarkdownText(text: message.text, font: .callout)
                                .equatable()
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
            case .screenCapture:
                // A capture the agent read with OCR: its own card, so the
                // source of an answer is never ambiguous (ported from Clippy).
                HStack {
                    ScreenCaptureRow(message: message)
                    Spacer(minLength: 30)
                }
            case .calculation:
                // A calculator run — a result, or a drawn chart (ported from
                // Clippy, which styles math like math rather than as prose).
                HStack {
                    CalculationRow(message: message)
                    Spacer(minLength: 30)
                }
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
                MarkdownText(
                    text: message.text.replacingOccurrences(of: "[Summary of earlier conversation]\n\n", with: ""),
                    font: .caption
                )
                .equatable()
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
                    // Its file changes were taken back from the transcript
                    // (see `FileRevert`), so nobody reads this row as "the
                    // edit still stands".
                    if let changes = message.fileChanges, !changes.isEmpty, changes.allSatisfy(\.isReverted) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("This call's file changes were undone")
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

    /// Elapsed time for a task that is still running. The ported engine runs
    /// one tool at a time inside the turn's own task — there is no per-call
    /// task to cancel any more, so the composer's Stop (which ends the run,
    /// and with it this call) is the way to stop a task.
    private func runningToolControls(_ message: ChatMessage) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(message.timestamp))
            Text(AIChatManager.elapsedLabel(elapsed))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .help("Waiting for this task to finish. Stop ends the whole run from the composer.")
        }
    }

    /// Collapsed-by-default disclosure for whatever reasoning/"thinking"
    /// content the model returned alongside this answer — only shown when
    /// there's something to show, since not every model or provider exposes
    /// it. Expanding doesn't change anything else in the transcript; it's
    /// purely a window into what the model worked through. Expansion state
    /// is keyed by message id so "Collapse all thinking" in the header can
    /// close every one of these at once.
    ///
    /// Only a preview slice is laid out by default. A reasoning block can be
    /// enormous, and rendering it all made the panel sluggish; the full text
    /// is one click away and still saved on the message.
    private static let thinkingPreviewLimit = 6_000

    @ViewBuilder
    private func thinkingDisclosure(_ reasoning: String, id: UUID) -> some View {
        let showingFull = fullThinkingIDs.contains(id)
        let isTruncated = reasoning.utf8.count > Self.thinkingPreviewLimit
        DisclosureGroup(isExpanded: thinkingBinding(for: id)) {
            // Scrollable and capped like the live box: an expanded thinking
            // section should never push the answer itself out of the panel.
            ScrollView {
                Text(showingFull || !isTruncated ? reasoning : thinkingPreview(reasoning))
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(.top, 4)
            if isTruncated {
                Button(showingFull ? "Show less" : "Show full thought") {
                    if showingFull {
                        fullThinkingIDs.remove(id)
                    } else {
                        fullThinkingIDs.insert(id)
                    }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .padding(.top, 2)
            }
        } label: {
            Label("Thought process", systemImage: "brain")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func thinkingPreview(_ reasoning: String) -> String {
        String(reasoning.prefix(Self.thinkingPreviewLimit))
            + "\n\n… (the rest is hidden to keep the panel responsive)"
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

    /// The Auto-proceed countdown: shown between the finished reply and the
    /// automatic continuation, with a live second count. "Continue now" sends
    /// at once; "Cancel" goes idle (and a message typed in the composer also
    /// cancels it, since that message becomes the next exchange instead).
    private func autoProceedCard(_ state: AutoProceedState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state.trigger.isFailure ? "arrow.clockwise.circle.fill" : "forward.end.fill")
                    .foregroundColor(.accentColor)
                Text(state.trigger.isFailure ? "Retrying automatically…" : "Continuing automatically…")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(state.remainingSeconds)s")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Text(autoProceedExplanation(state.trigger))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Continue now") { chat.continueAutoProceedNow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { chat.cancelAutoProceed() }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .overlay(alignment: .top) { Divider() }
    }

    private func autoProceedExplanation(_ trigger: AIChatAutoProceed.Trigger) -> String {
        switch trigger {
        case .unfinished:
            return "The reply said work was still left, so the next step will be sent when the countdown ends. Type a message or click Cancel to take over."
        case .failure(let message):
            let clipped = message.count > 200 ? String(message.prefix(200)) + "…" : message
            return "The last attempt failed (\(clipped)). Another try will be sent when the countdown ends — Cancel to stop, or turn this off in Settings → AI Chat → Auto-proceed."
        }
    }

    /// Shown when Auto-proceed stopped itself (round cap reached, or a failed
    /// attempt with the budget spent) so an unattended run never just goes
    /// quiet. "Keep going" grants a fresh budget and continues.
    private func autoProceedStoppedCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill").foregroundColor(.orange)
                Text("Auto-proceed stopped").font(.subheadline.bold())
                Spacer()
            }
            Text(reason)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep going") {
                    scrollToLatestRequest += 1
                    chat.keepGoingAfterAutoProceedStop()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Dismiss") { chat.dismissAutoProceedStop() }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    /// The `ask_question` card: one block per question, each with its
    /// suggested options, an always-available free-text field, and a skip.
    /// The run is suspended until Send or Dismiss, so this card is the whole
    /// interaction — nothing else in the panel is actionable meanwhile.
    private func questionCard(_ pending: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(.accentColor)
                Text(pending.questions.count == 1 ? "The assistant has a question" : "The assistant has \(pending.questions.count) questions")
                    .font(.subheadline.bold())
                Spacer()
            }

            ForEach(pending.questions) { question in
                questionBlock(question, answer: pending.answers[question.id])
                if question.id != pending.questions.last?.id {
                    Divider()
                }
            }

            HStack(spacing: 8) {
                Button("Dismiss") { chat.dismissQuestion() }
                    .controlSize(.small)
                    .help("Skip these questions — the assistant will state an assumption and carry on")
                Spacer()
                Button("Send answer\(pending.questions.count == 1 ? "" : "s")") {
                    chat.submitQuestionAnswers()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!pending.hasAnyAnswer)
            }

            Text("The run is paused until you answer. Dismissing lets it continue on a stated assumption.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func questionBlock(_ question: AgentQuestion, answer: AgentQuestionAnswer?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.header)
                .font(.caption2.bold())
                .foregroundColor(.accentColor)
            Text(question.question)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                let selected = answer?.selections.contains(option.label) ?? false
                Button {
                    toggleQuestionOption(question, label: option.label)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: selected
                              ? (question.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                              : (question.multiple ? "square" : "circle"))
                            .foregroundColor(selected ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                            if let detail = option.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Always available, per the tool's description: the options are a
            // shortcut, never a limit on what the user may answer.
            TextField(
                "Or type your own answer",
                text: Binding(
                    get: { answer?.custom ?? "" },
                    set: { text in
                        var next = answer ?? AgentQuestionAnswer(questionID: question.id)
                        next.custom = text.isEmpty ? nil : text
                        chat.setQuestionAnswer(next)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
    }

    /// Single-select replaces the selection; multi-select toggles one entry.
    private func toggleQuestionOption(_ question: AgentQuestion, label: String) {
        var answer = chat.pendingQuestion?.answers[question.id]
            ?? AgentQuestionAnswer(questionID: question.id)
        if question.multiple {
            if let index = answer.selections.firstIndex(of: label) {
                answer.selections.remove(at: index)
            } else {
                answer.selections.append(label)
            }
        } else {
            answer.selections = answer.selections.contains(label) ? [] : [label]
        }
        chat.setQuestionAnswer(answer)
    }

    /// The ARIA safety review of this conversation: a score, what it means,
    /// and the model that answered. Dismissible — it is a report, not a gate.
    @ViewBuilder
    private func ariaReviewCard(_ review: ARIAAssessment.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: review.score.symbol)
                    .foregroundColor(review.score == .attemptedAndFailed ? .orange : .green)
                Text("Safety review: \(review.score.title)")
                    .font(.caption.bold())
                Spacer()
                Button {
                    chat.clearARIAReview()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(review.score.explanation)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("Scored by \(review.modelName) · \(review.assessedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
    }

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

            case .fileMoveLines(let path, let startLine, let endLine, let beforeLine, let movedSnippet):
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down.text.horizontal").foregroundColor(.orange)
                    let count = endLine - startLine + 1
                    Text("Move \(count) line\(count == 1 ? "" : "s") (lines \(startLine)–\(endLine)) before line \(beforeLine) in '\(path)'?")
                        .font(.subheadline.bold())
                }
                ScrollView {
                    Text(movedSnippet)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 180)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)

            case .webFetch(let urlString, let savedSignInHost):
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
                    if let savedSignInHost {
                        HStack(spacing: 4) {
                            Image(systemName: "person.badge.key.fill").foregroundColor(.orange)
                            Text("Sends your saved sign-in for \(savedSignInHost) with this request.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
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

            case .pdfImport(let source, let destination, let pages, let aiModel, let existingFile):
                HStack(spacing: 6) {
                    Image(systemName: "doc.viewfinder").foregroundColor(.orange)
                    Text("Import '\(source)' to Typst?").font(.subheadline.bold())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Pages: \(pages). Figures are saved in a folder next to it.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let aiModel {
                        Text("Cropped images of formulas and complex tables go to \(aiModel).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if existingFile {
                        Text("This replaces the existing file.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)

            case .batchPatch(let changes):
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundColor(.orange)
                    Text("Apply a patch to \(changes.count) file\(changes.count == 1 ? "" : "s")?")
                        .font(.subheadline.bold())
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(changes) { change in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(patchChangeLetter(change.kind))
                                        .font(.caption.bold().monospaced())
                                        .foregroundColor(patchChangeColor(change.kind))
                                    Text(change.path)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    if let from = change.fromPath {
                                        Text("← \(from)")
                                            .font(.caption2.monospaced())
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if change.kind != .deleted {
                                    diffPreview(old: change.oldContent, new: change.newContent)
                                        .frame(maxHeight: 120)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
                Text("Reviewed as one batch. Every listed file changes together, so approving is a single step and denying leaves all of them untouched.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

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

            case .runPython(let code, let wantsElevation, let sudoAuthentication):
                HStack(spacing: 6) {
                    Image(systemName: wantsElevation ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(wantsElevation ? "Run this Python script with sudo?" : "Run this Python script?")
                        .font(.subheadline.bold())
                }
                if wantsElevation {
                    // The elevated gate (executor) refuses these unless the
                    // sudo opt-in is on and the sandbox is off, so this
                    // warning only ever appears for a run that can actually
                    // elevate. The text follows the probed sudo setup, so it
                    // never promises a dialog that won't appear.
                    Text(sudoAuthentication.approvalWarning)
                        .font(.caption2).foregroundColor(.red)
                }
                Text(aiSettings.chatPythonSandboxEnabled
                     ? "Runs under macOS sandbox-exec: no network access, writes limited to a scratch folder. Review the code carefully."
                     : "Runs with your full user permissions, no sandbox or network isolation. Review the code carefully.")
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

            case .screenCapture(let scope, let purpose):
                HStack(spacing: 6) {
                    Image(systemName: "eye.circle.fill").foregroundColor(.red)
                    Text("Look at your screen?").font(.subheadline.bold())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("TypstEdit would capture \(scope) and read the text in it (OCR), on this Mac only — nothing is uploaded.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Reason: \(purpose)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Every capture needs its own approval, even in YOLO mode.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)

            case .runShell(let command):
                // Ported from Clippy's approval card: a command line is
                // opaque — `ls` and `rm -rf ~/…` are the same length on a
                // card — so the whole line is shown verbatim and the card
                // spells out that YOLO never approves one.
                VStack(alignment: .leading, spacing: 4) {
                    Text("$ " + command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black.opacity(0.06))
                        .cornerRadius(6)
                    Text("Runs as a shell command on this Mac. Read the whole line before approving — YOLO never approves these automatically. (A rule you saved for this exact command can, with “Always allow…” below.)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .skillCreate(let name, let description, let bodyPreview):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create skill “\(name)”?").font(.subheadline.bold())
                    if !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        Text(bodyPreview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.black.opacity(0.06))
                    .cornerRadius(6)
                    Text("This becomes a reusable skill in \(SkillsManager.globalSkillsDirectory.path) — enabled for this chat and future ones.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .skillWriteFile(let skillName, let relativePath, let oldContent, let newContent, let isNewFile, let isSKILLFile):
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNewFile
                         ? "Create \(relativePath) in skill “\(skillName)”?"
                         : "Overwrite \(relativePath) in skill “\(skillName)”?")
                        .font(.subheadline.bold())
                    if !isNewFile, isSKILLFile {
                        // The whole SKILL.md rewritten: the same diff preview
                        // a project-file edit gets, so the change reads at a
                        // glance instead of as a wall of text.
                        diffPreview(old: oldContent, new: newContent)
                            .frame(maxHeight: 160)
                    } else {
                        ScrollView {
                            Text(newContent)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(maxHeight: 160)
                        .background(Color.black.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .skillDelete(let skillName, let fileCount):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash").foregroundColor(.red)
                        Text("Delete skill “\(skillName)”?").font(.subheadline.bold())
                    }
                    Text(fileCount == 0
                         ? "Its SKILL.md will be removed. This cannot be undone."
                         : "Its SKILL.md and \(fileCount) attachment\(fileCount == 1 ? "" : "s") will be removed. This cannot be undone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Deleting a skill is always manual — unlike a project-file write there is no other copy, so YOLO never wipes a skill you may have authored.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .mcpServerAdd(let name, let transportLabel, let target, let summary, let replacesExisting):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").foregroundColor(.red)
                        Text("\(replacesExisting ? "Replace" : "Add") MCP server “\(name)”?").font(.subheadline.bold())
                    }
                    Text("\(transportLabel) — \(target)")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(summary)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 140)
                    .background(Color.black.opacity(0.06))
                    .cornerRadius(6)
                    Text("This server's tools become available in this chat and every future one. A local server runs its command on this Mac. Adding or changing a server always asks — YOLO never does it.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .mcpServerDelete(let name, let toolCount):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").foregroundColor(.red)
                        Text("Remove MCP server “\(name)”?").font(.subheadline.bold())
                    }
                    Text(toolCount == 0
                         ? "Its configuration will be deleted. This cannot be undone."
                         : "Its configuration and \(toolCount) tool\(toolCount == 1 ? "" : "s") will be removed. This cannot be undone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Removing a server is always manual — YOLO never deletes one.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A safety rule can only ever *add* a card that YOLO would have
            // skipped, so say which rule did — otherwise a re-approval looks
            // like YOLO forgot.
            if !approval.safetyHits.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill").foregroundColor(.red)
                        Text("Safety check held this call").font(.caption.bold())
                    }
                    ForEach(approval.safetyHits) { hit in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title).font(.caption2.bold())
                            Text(hit.explanation).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            }

            HStack {
                if chat.pendingApprovalCount > 1 {
                    Text("\(chat.pendingApprovalCount - 1) more waiting")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                // A saved rule turns "ask every time" into "allow this from
                // now on". The menu is absent for kinds a rule may never
                // allow (elevated runs, screen captures, Git push), so the
                // two settings are not silently merged into one.
                let suggestions = approval.kind.permissionSuggestions
                if !suggestions.isEmpty {
                    Menu("Always allow…") {
                        ForEach(suggestions) { suggestion in
                            Button(suggestion.title) {
                                // Saves the rule, approves this call, and
                                // lets through queued calls the rule now
                                // covers — see `approvePendingAlways`.
                                chat.approvePendingAlways(suggestion.rule)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                }
                Spacer()
                Button("Deny") { chat.denyPending() }
                Button("Approve") { chat.approvePending() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    /// Short letter for a batch-patch row, matching the diff convention.
    private func patchChangeLetter(_ kind: PatchChange.Kind) -> String {
        switch kind {
        case .added: return "A"
        case .deleted: return "D"
        case .modified, .moved: return "M"
        }
    }

    /// Colour for that letter: green for a new file, red for a deletion,
    /// orange for a change in place.
    private func patchChangeColor(_ kind: PatchChange.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .deleted: return .red
        case .modified, .moved: return .orange
        }
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

            if !chat.draftImages.isEmpty {
                attachmentStrip
            }

            if let redaction = pendingRedaction {
                // The review card replaces the field entirely: while it is
                // up, nothing can send, and the draft stays in place for
                // "Edit" to return to.
                SecretRedactionReviewCard(redaction: redaction) { approved in
                    finishRedactionReview(sending: approved)
                }
            } else {
                composerRow
            }

            if let notice = attachmentNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if chat.isGenerating && !chat.pendingQueued.isEmpty {
                queuedStrip
            }
        }
        .padding(10)
    }

    /// The field and its buttons, extracted from `inputBar` so the secret
    /// redaction review card can stand in for it while it is up.
    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton

            TextEditor(text: $chat.draft)
                .focused($inputFocused)
                .font(.callout)
                .frame(height: 50)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                // Stays enabled while the AI works: sending then steers
                // the running task instead of starting a new turn.
                .disabled(chat.pendingApproval != nil)
                .help(chat.isGenerating
                      ? "The AI is working. Return steers the current task (it reads this at its next step); ⌘⇧Return queues it for after."
                      : "Ask anything. Return sends. Drop or paste an image to attach it.")
                // Anything dropped here attaches to the draft; the whole
                // composer accepts images, not just a small corner.
                .onDrop(of: [.fileURL, .image], isTargeted: $composerDropTargeted) { providers in
                    loadDroppedImages(providers)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: composerDropTargeted ? 2 : 0)
                )

            if chat.isGenerating {
                // A sibling of the (still enabled) TextEditor, so it stays
                // pressable while generation runs — including while an
                // approval is pending, since `isGenerating` covers that.
                // A non-empty draft gets both deliveries next to Stop:
                // steer joins the running turn, queue waits for it.
                if hasDraft {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .help(chat.draftImages.isEmpty
                          ? "Steer — send this into the running task. The AI adjusts course at its next step."
                          : "Queue — images need a turn of their own, so this waits for the current task to finish.")

                    Button {
                        enqueue()
                    } label: {
                        Image(systemName: "text.append").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .help("Queue — let the current task finish, then run this as its own turn.")
                }
                Button {
                    chat.togglePause()
                } label: {
                    pauseControlGlyph
                }
                .buttonStyle(.plain)
                .disabled(chat.pauseControl == .unavailable)
                .help(pauseButtonHelp)

                Button {
                    chat.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 24)).foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop generating and abort the task that is running (Python, compile, Git, and so on)")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(!hasDraft || chat.pendingApproval != nil)
            }
        }
    }

    /// The pause control's glyph, one per state — ported from Clippy's
    /// composer. A spinner rather than a disabled pause icon for `pausing`:
    /// the press was accepted and the run is finishing its turn, so the
    /// control must show work happening, not a dead button.
    @ViewBuilder
    private var pauseControlGlyph: some View {
        switch chat.pauseControl {
        case .paused:
            Image(systemName: "play.circle.fill").font(.system(size: 24)).foregroundColor(.accentColor)
        case .pausing:
            ProgressView().controlSize(.regular)
        case .ready, .unavailable:
            Image(systemName: "pause.circle").font(.system(size: 24)).foregroundColor(.secondary)
        }
    }

    /// What the Pause/Resume button says. Every state names what the next
    /// press does, because the same button does three different things.
    private var pauseButtonHelp: String {
        switch chat.pauseControl {
        case .paused:
            return "Resume the run from where it stopped"
        case .pausing:
            return "Waiting for the current instruction to finish — press again to carry straight on"
        case .ready:
            return "Pause after the current instruction finishes"
        case .unavailable:
            return "Pause is not available for this run"
        }
    }

    /// A photo picker button for the composer. Disabled while AI Chat is off
    /// (the whole bar is hidden then) and once a message already carries the
    /// maximum, with the reason in its tooltip.
    private var attachButton: some View {
        Button {
            pickImages()
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 18))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundColor(chat.draftImages.isEmpty ? .secondary : .accentColor)
        .disabled(chat.draftImages.count >= ChatImageLoader.maxPerMessage || chat.pendingApproval != nil)
        .help(chat.draftImages.count >= ChatImageLoader.maxPerMessage
              ? "This message already has the maximum of \(ChatImageLoader.maxPerMessage) images."
              : "Attach an image for the AI to look at (or drop/paste one). Only models that accept images can use it.")
    }

    /// Thumbnails of what the next message will carry. Images are part of the
    /// message, not of the draft text, so they need to be visible before it is
    /// sent — and removable without retyping anything.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.draftImages) { image in
                    ChatAttachmentThumbnail(image: image) {
                        chat.draftImages.removeAll { $0.id == image.id }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Attaching Images

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ChatImageLoader.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Attach Images"
        panel.message = "Choose images for the AI to use as reference. They are shrunk to a size providers accept."
        guard panel.runModal() == .OK else { return }
        attach(urls: panel.urls)
    }

    /// Loads images off the main thread (decoding and re-encoding a photo can
    /// take a moment) and folds them into the draft.
    private func attach(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let remaining = max(0, ChatImageLoader.maxPerMessage - chat.draftImages.count)
        guard remaining > 0 else {
            attachmentNotice = "This message already has \(ChatImageLoader.maxPerMessage) images."
            return
        }
        let overflow = max(0, urls.count - remaining)
        let toLoad = Array(urls.prefix(remaining))
        Task.detached(priority: .userInitiated) {
            var loaded: [ChatImage] = []
            var failures = 0
            var tooLarge = 0
            for url in toLoad {
                do {
                    loaded.append(try ChatImageLoader.load(from: url))
                } catch ChatImageError.tooLarge {
                    tooLarge += 1
                } catch {
                    failures += 1
                }
            }
            let images = loaded
            let failed = failures
            let oversized = tooLarge
            await MainActor.run {
                self.applyAttachments(images, failures: failed, tooLarge: oversized, overflow: overflow)
            }
        }
    }

    /// Reports what was left out of an attach attempt, using the loader's own
    /// wording so the picker, the drop and the paste all say the same thing.
    private func attachmentProblemNotice(failures: Int, tooLarge: Int) -> String? {
        var parts: [String] = []
        if tooLarge > 0 {
            parts.append(tooLarge == 1
                ? ChatImageError.tooLarge.localizedDescription
                : "\(tooLarge) images were too large, even after shrinking.")
        }
        if failures > 0 {
            parts.append(failures == 1
                ? ChatImageError.unsupportedFormat.localizedDescription
                : "\(failures) files couldn't be read as images.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Publishes newly loaded images into the draft and reports what was left
    /// out. Kept in one place so the picker, the drop and the paste agree.
    private func applyAttachments(
        _ images: [ChatImage],
        failures: Int = 0,
        tooLarge: Int = 0,
        overflow: Int = 0
    ) {
        guard !images.isEmpty else {
            attachmentNotice = attachmentProblemNotice(failures: failures, tooLarge: tooLarge)
            return
        }
        let fit = ChatImageLoader.fit(chat.draftImages + images)
        chat.draftImages = fit.accepted
        let droppedForCount = fit.droppedForCount + overflow
        var parts: [String] = []
        if droppedForCount > 0 {
            parts.append("\(droppedForCount) left out — a message can carry \(ChatImageLoader.maxPerMessage).")
        }
        if fit.droppedForSize > 0 {
            parts.append("\(fit.droppedForSize) left out — too large for one message.")
        }
        if let problem = attachmentProblemNotice(failures: failures, tooLarge: tooLarge) {
            parts.append(problem)
        }
        attachmentNotice = parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Accepts images dragged onto the composer. Folders and non-image files
    /// are ignored rather than raising an error.
    private func loadDroppedImages(_ providers: [NSItemProvider]) -> Bool {
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !imageProviders.isEmpty else { return false }
        for provider in imageProviders {
            // A file from Finder: load its URL and go through the same path as
            // the picker (which re-encodes whatever format it is).
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          ChatImageLoader.isImageFile(url) else { return }
                    DispatchQueue.main.async { self.attach(urls: [url]) }
                }
                continue
            }
            // Image data dragged from another app (a browser, Preview): there
            // is no file path, so decode the image bytes directly.
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task.detached(priority: .userInitiated) {
                        do {
                            let image = try ChatImageLoader.make(from: data)
                            await MainActor.run { self.applyAttachments([image]) }
                        } catch ChatImageError.tooLarge {
                            await MainActor.run {
                                self.attachmentNotice = ChatImageError.tooLarge.localizedDescription
                            }
                        } catch {
                            await MainActor.run {
                                self.attachmentNotice = ChatImageError.unsupportedFormat.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    /// Handles ⌘V in the composer when the clipboard holds an image: the image
    /// is attached instead of pasted as inline text the model can't see. Text
    /// on the clipboard always wins, so copying a table from a web page still
    /// pastes the table.
    private func attachClipboardImageIfPresent() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string)?.isEmpty == false { return false }
        // Cheapest encoding first: a screenshot is on the clipboard as a PNG
        // and an uncompressed TIFF of the same pixels, and the TIFF is often
        // twenty times the size. Read the bytes eagerly on the main thread:
        // NSImage(pasteboard:) uses a lazy provider that can IPC back to the
        // source app and deadlock.
        guard let data = ChatImageLoader.clipboardImageData(from: pasteboard) else { return false }
        guard let image = try? ChatImageLoader.make(from: data) else { return false }
        applyAttachments([image])
        return true
    }

    private var hasDraft: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.draftImages.isEmpty
    }

    /// The messages waiting for the running turn to finish. Each row can jump
    /// the line as steering input or go back to the composer; the whole strip
    /// is only shown while a turn is running, which is the only time "queue"
    /// means anything.
    private var queuedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "text.append").font(.caption2)
                Text(chat.pendingQueued.count == 1
                     ? "1 message queued — runs when this task finishes"
                     : "\(chat.pendingQueued.count) messages queued — run when this task finishes")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundColor(.secondary)

            ForEach(chat.pendingQueued) { item in
                HStack(spacing: 6) {
                    if !item.images.isEmpty {
                        Label("\(item.images.count)", systemImage: "photo")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help(item.images.count == 1 ? "1 attached image" : "\(item.images.count) attached images")
                    }
                    Text(item.text.isEmpty ? "Image" : item.text)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button("Steer") { chat.steerQueued(item.id) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .disabled(!item.images.isEmpty)
                        .help(item.images.isEmpty
                              ? "Send this into the running task instead of waiting"
                              : "Attachments need their own turn, so this waits for the current task to finish")
                    Button {
                        chat.dropQueued(item.id)
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from the queue and put it back in the composer")
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
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
                    planToggle(iconOnly: iconOnly)
                    yoloToggle(iconOnly: iconOnly)
                    if aiSettings.bypassPermissionsUnlocked {
                        bypassToggle(iconOnly: iconOnly)
                    }
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
                planToggle(iconOnly: iconOnly)
                yoloToggle(iconOnly: iconOnly)
                if aiSettings.bypassPermissionsUnlocked {
                    bypassToggle(iconOnly: iconOnly)
                }
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
            Divider()
            Button("Review safety with ARIA…") {
                Task { await chat.assessSafety() }
            }
            .disabled(chat.isAssessingSafety || chat.messages.filter { $0.role == .toolCall }.isEmpty)
            if chat.ariaResult != nil {
                Button("Clear safety review") { chat.clearARIAReview() }
            }
        } label: {
            pickerLabel("Tools", systemImage: "wrench.and.screwdriver", iconOnly: iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which MCP tool servers are available to the AI for this session")
    }

    /// Plan mode (opencode-style): the AI explores and plans, but every
    /// mutating tool is withheld, so the turn cannot touch files. Unlike
    /// YOLO there is no confirmation — turning it *on* only removes
    /// abilities, and the reminder telling the model what it may do goes out
    /// with the very next message.
    private func planToggle(iconOnly: Bool) -> some View {
        Button {
            chat.planMode.toggle()
        } label: {
            pickerLabel("Plan", systemImage: chat.planMode ? "lightbulb.fill" : "lightbulb", iconOnly: iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundColor(chat.planMode ? .accentColor : .secondary)
        .help(chat.planMode
              ? "Plan mode is ON — the AI can read, search, and keep its plan checklist current, but cannot edit files, write files, export, run Python, or change Git state. Click to turn off."
              : "Plan mode: the AI explores the project and discusses a plan without touching files. Click to turn on.")
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

    private func bypassToggle(iconOnly: Bool) -> some View {
        Button {
            if chat.bypassPermissions {
                chat.bypassPermissions = false
            } else {
                showBypassConfirm = true
            }
        } label: {
            pickerLabel("Bypass", systemImage: chat.bypassPermissions ? "flame.fill" : "flame", iconOnly: iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundColor(chat.bypassPermissions ? .red : .secondary)
        .help(chat.bypassPermissions
              ? "Bypass Permissions is ON for this conversation — every tool call runs without approval cards or sandboxing. Click to turn off."
              : "Bypass Permissions: run every tool call in this conversation without approval cards or sandboxing.")
    }

    private func send() {
        let text = chat.draft
        guard redactionGatePasses(for: text, queued: false) else { return }
        let images = chat.draftImages
        chat.draft = ""
        chat.draftImages = []
        attachmentNotice = nil
        // A send is an explicit "take me to the newest exchange" — it ends
        // manual mode, so the reply that follows is followed live again.
        scrollToLatestRequest += 1
        // While a turn runs, `.steer` joins it (images fall through to the
        // queue, which gives attachments a turn the model can actually see);
        // idle, it starts a fresh turn. See `AIChatManager.send(_:images:as:)`.
        chat.send(text, images: images, as: .steer)
    }

    /// Sends the draft to the queue instead of into the running turn. A send
    /// while idle is never queued (there is nothing to wait for), so this
    /// falls through to a normal send — the same rule opencode applies.
    private func enqueue() {
        let text = chat.draft
        guard redactionGatePasses(for: text, queued: true) else { return }
        let images = chat.draftImages
        guard chat.isGenerating else { return send() }
        chat.draft = ""
        chat.draftImages = []
        attachmentNotice = nil
        scrollToLatestRequest += 1
        chat.send(text, images: images, as: .queue)
    }

    /// A secret in the draft stops here (see `SecretRedaction`): the review
    /// card replaces the field until the user sends or goes back to edit, so
    /// Edit loses nothing — the draft stays in place underneath.
    private func redactionGatePasses(for text: String, queued: Bool) -> Bool {
        guard aiSettings.redactSecretsBeforeSending,
              let redaction = SecretRedaction(scanning: text) else { return true }
        pendingRedaction = redaction
        pendingRedactionQueued = queued
        return false
    }

    /// The review card's answer. `text` is what the user approved — the
    /// redacted message, or the original when they chose to send it as is.
    /// Nil goes back to the field with the draft untouched.
    private func finishRedactionReview(sending text: String?) {
        let queued = pendingRedactionQueued
        pendingRedaction = nil
        pendingRedactionQueued = false
        guard let text else {
            inputFocused = true
            return
        }
        let images = chat.draftImages
        chat.draft = ""
        chat.draftImages = []
        attachmentNotice = nil
        scrollToLatestRequest += 1
        if queued && chat.isGenerating {
            chat.send(text, images: images, as: .queue)
        } else {
            chat.send(text, images: images, as: .steer)
        }
    }

    // Shift+Enter submits the draft, like the send button; ⌘Shift+Enter
    // queues it instead when a turn is running. A local key monitor (the same
    // pattern EditorController uses for its paste shortcuts) is installed
    // while the panel is visible and removed when it leaves the hierarchy, so
    // it never outlives the sidebar tab.
    private func installShiftEnterMonitor() {
        guard shiftEnterMonitor == nil else { return }
        shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak chat = self.chat] event in
            let isReturn = event.charactersIgnoringModifiers == "\r"
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘V with an image on the clipboard attaches it instead of pasting
            // text/nothing: a screenshot dropped into the text view would
            // otherwise leave the model with nothing to look at.
            if event.charactersIgnoringModifiers?.lowercased() == "v",
               flags == [.command],
               self.inputFocused,
               chat?.pendingApproval == nil,
               self.attachClipboardImageIfPresent() {
                return nil
            }
            let isShiftEnter = isReturn && flags == [.shift]
            let isQueueEnter = isReturn && flags == [.shift, .command]
            guard isShiftEnter || isQueueEnter,
                  let chat,
                  chat.pendingApproval == nil,
                  self.inputFocused,
                  !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.draftImages.isEmpty
            else { return event }
            if isQueueEnter {
                self.enqueue()
            } else {
                self.send()
            }
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

/// The finished part of the transcript. Every `@Published` change on the chat
/// re-renders the panel, and while a reply streams that is ten times a second
/// for changes that only touch the live row; as an `Equatable` view whose
/// inputs are only what the rows actually show, the history is skipped on
/// those updates instead of being rebuilt and re-laid out row by row. Its
/// body is a bare `ForEach`, so the rows still sit directly in the
/// transcript's stack (spacing, ids and scroll targets unchanged).
///
/// `row` is left out of `==` on purpose: it is the panel's own row builder,
/// and everything a row renders is covered by the other inputs (the stop
/// action goes through the chat object, which doesn't change identity).
private struct TranscriptHistory<Row: View>: View, Equatable {
    let messages: [ChatMessage]
    let expandedThinkingIDs: Set<UUID>
    let fullThinkingIDs: Set<UUID>
    /// The active Find query (trimmed, empty when the bar is closed), so a
    /// row can tint itself when it holds a hit. Part of the equality: a new
    /// query must re-render the rows even when no message changed.
    let findQuery: String
    /// The message the Find bar is currently stepped onto, outlined.
    let currentFindHitID: UUID?
    let row: (ChatMessage) -> Row

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages
            && lhs.expandedThinkingIDs == rhs.expandedThinkingIDs
            && lhs.fullThinkingIDs == rhs.fullThinkingIDs
            && lhs.findQuery == rhs.findQuery
            && lhs.currentFindHitID == rhs.currentFindHitID
    }

    var body: some View {
        ForEach(messages) { message in
            row(message).id(message.id)
        }
    }
}

/// Reports whether the transcript's backing `NSScrollView` is scrolled to the
/// bottom, by watching the clip view's bounds. SwiftUI has no scroll-position
/// API on macOS 13, and without this the chat would keep jerking you back to
/// the bottom while you were trying to read an earlier step. The probe is
/// passive — it never scrolls, and if no scroll view can be found the binding
/// simply stays at its initial `true` (the old always-follow behaviour).
///
/// The probe also stays silent while a *programmatic* scroll is in flight (per
/// `isProgrammaticScroll`): a scroll the panel issued itself is not the user
/// scrolling away, and the lazy stack's post-scroll height corrections would
/// otherwise read as one — which is what used to disable autoscroll mid-
/// generation and leave the transcript stranded on blank space until the next
/// click.
///
/// That mute must never swallow a real gesture, though: while a response
/// streams, follow scrolls keep extending the mute window, so for most of a
/// generation the probe would be blind. A live scroll (trackpad, wheel, or
/// scroller knob) is reported through `userIsScrolling` and *bypasses* the
/// mute — it is the one movement we know is not ours.
private struct TranscriptBottomProbe: NSViewRepresentable {
    @Binding var isAtBottom: Bool
    var isProgrammaticScroll: () -> Bool
    var userIsScrolling: (Bool) -> Void

    /// Distance from the bottom still treated as "at the bottom", so a
    /// one-pixel rounding difference or a short scroll doesn't flip it.
    private static let slack: CGFloat = 24

    final class ProbeView: NSView {
        var onWindowChange: (() -> Void)?

        /// The probe is invisible bookkeeping, never a target: it must not
        /// swallow clicks, text selection, or scroll-wheel events from the
        /// transcript behind it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }
    }

    final class Coordinator: NSObject {
        var isAtBottom: Binding<Bool>
        var isProgrammaticScroll: () -> Bool
        var userIsScrolling: (Bool) -> Void
        private var scrollView: NSScrollView?
        /// Mirrors the live-scroll state of `scrollView`; the probe reports
        /// from a gesture even while the programmatic-scroll mute is open.
        private var isLiveUserScroll = false

        init(
            isAtBottom: Binding<Bool>,
            isProgrammaticScroll: @escaping () -> Bool,
            userIsScrolling: @escaping (Bool) -> Void
        ) {
            self.isAtBottom = isAtBottom
            self.isProgrammaticScroll = isProgrammaticScroll
            self.userIsScrolling = userIsScrolling
        }

        /// Finds the enclosing scroll view once the probe is in the window
        /// hierarchy. Called more than once because SwiftUI may attach the
        /// view before the scroll view is in place.
        func attach(to view: NSView) {
            guard scrollView == nil, let scroll = view.enclosingScrollView else { return }
            scrollView = scroll
            let clipView = scroll.contentView
            clipView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            // Live-scroll notifications fire only for user input (trackpad and
            // wheel gestures, scroller-knob drags), so they are what separates
            // "the user moved the transcript" from "the panel followed along".
            center.addObserver(
                self,
                selector: #selector(liveScrollBegan),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scroll
            )
            center.addObserver(
                self,
                selector: #selector(liveScrollMoved),
                name: NSScrollView.didLiveScrollNotification,
                object: scroll
            )
            center.addObserver(
                self,
                selector: #selector(liveScrollEnded),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scroll
            )
            // The content can also change size without the clip view moving —
            // a lazy row measuring shorter than estimated is the blank-space
            // case, and the clamp has to hear about it.
            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                center.addObserver(
                    self,
                    selector: #selector(contentResized),
                    name: NSView.frameDidChangeNotification,
                    object: document
                )
            }
            report()
        }

        /// Clamp only — never a report. Content growing below a pinned
        /// viewport puts it "away from the bottom" until the follow scroll
        /// lands; treating that as the user leaving would switch following
        /// off at the start of every streamed burst.
        @objc private func contentResized() {
            guard let scrollView, let document = scrollView.documentView else { return }
            clampIntoRange(scrollView: scrollView, document: document, clipView: scrollView.contentView)
        }

        @objc private func liveScrollBegan() {
            isLiveUserScroll = true
            userIsScrolling(true)
        }

        @objc private func liveScrollMoved() {
            isLiveUserScroll = true
            userIsScrolling(true)
            report()
        }

        @objc private func liveScrollEnded() {
            isLiveUserScroll = false
            userIsScrolling(false)
            // Authoritative: where the gesture left the viewport decides
            // whether following resumes, even if a follow scroll issued just
            // before the gesture opened is still inside its mute window.
            report(force: true)
        }

        /// Drops a gesture flag that would otherwise outlive its scroll view.
        func detach() {
            NotificationCenter.default.removeObserver(self)
            if isLiveUserScroll {
                isLiveUserScroll = false
                userIsScrolling(false)
            }
        }

        @objc private func boundsChanged() {
            report()
        }

        private func report(force: Bool = false) {
            guard let scrollView, let document = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            // Not a report: the clamp runs even inside a programmatic-scroll
            // mute, because a bad landing is exactly what happens there.
            clampIntoRange(scrollView: scrollView, document: document, clipView: clipView)
            let originY = clipView.bounds.origin.y
            let previousOriginY = lastOriginY
            lastOriginY = originY
            // SwiftUI's document view is flipped (y = 0 at the top), so the
            // remaining distance is document height minus the visible bottom.
            let distanceToBottom: CGFloat
            if document.isFlipped {
                let maxOffset = max(0, document.frame.height - clipView.bounds.height)
                distanceToBottom = maxOffset - originY
            } else {
                distanceToBottom = originY
            }

            // Asymmetric on purpose. Reaching the bottom always (re)enables
            // following, whatever moved us there. *Leaving* it only counts
            // when the user did it: a live gesture, the end of one, or the
            // viewport moving up outside our own scrolls (Page Up, scroller
            // arrows — input that posts no live-scroll notifications). Being
            // merely "not at the bottom" proves nothing: on open the view
            // starts at the top before the first follow lands, and content
            // streaming in below a pinned viewport does the same — both used
            // to switch following off with nobody touching anything.
            let following: Bool
            if distanceToBottom <= TranscriptBottomProbe.slack {
                following = true
            } else if force || isLiveUserScroll {
                following = false
            } else if let previousOriginY, originY < previousOriginY - 1, !isProgrammaticScroll() {
                following = false
            } else {
                return
            }
            guard following != isAtBottom.wrappedValue else { return }
            isAtBottom.wrappedValue = following
        }

        /// Last clip origin the probe saw, to tell an upward move (the user)
        /// from content growing underneath (not the user).
        private var lastOriginY: CGFloat?

        /// Keeps the viewport inside the document. When the content shrinks
        /// under a viewport pinned to the bottom (the live "Thinking…" row
        /// going away at the end of a turn, a disclosure collapsing), nothing
        /// constrains the clip view, so the panel would sit on empty space
        /// past the last row until the user scrolled. This only ever pulls
        /// the viewport back to the last real position; it never scrolls
        /// away from where the user put it.
        ///
        /// Skipped during a live gesture so the elastic overscroll at the end
        /// of a trackpad scroll isn't fought frame by frame.
        private func clampIntoRange(scrollView: NSScrollView, document: NSView, clipView: NSClipView) {
            guard !isLiveUserScroll else { return }
            // Before the first layout pass the document has no height yet;
            // clamping then would yank the view to the top.
            guard document.frame.height > 0 else { return }
            let maxOffset = max(0, document.frame.height - clipView.bounds.height)
            let origin = clipView.bounds.origin
            let clampedY: CGFloat
            if document.isFlipped {
                // Beyond the bottom is the blank-space case; above the top is
                // elastic overscroll, which AppKit settles itself.
                guard origin.y > maxOffset + Self.clampTolerance else { return }
                clampedY = maxOffset
            } else {
                guard origin.y < -Self.clampTolerance else { return }
                clampedY = 0
            }
            clipView.scroll(to: NSPoint(x: origin.x, y: clampedY))
            scrollView.reflectScrolledClipView(clipView)
        }

        /// A hair of slack so a sub-point rounding difference isn't a clamp.
        private static let clampTolerance: CGFloat = 1
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isAtBottom: $isAtBottom,
            isProgrammaticScroll: isProgrammaticScroll,
            userIsScrolling: userIsScrolling
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView(frame: .zero)
        view.onWindowChange = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isAtBottom = $isAtBottom
        context.coordinator.isProgrammaticScroll = isProgrammaticScroll
        context.coordinator.userIsScrolling = userIsScrolling
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

/// Shows the window's active conversation, and follows the session store
/// when the user switches chats.
struct AIChatPanel: View {
    @ObservedObject var controller: EditorController
    @ObservedObject var store: AIChatSessionStore

    var body: some View {
        AIChatView(
            controller: controller,
            chat: store.activeManager,
            store: store,
            skillsManager: controller.projectContext.skills,
            mcpManager: controller.projectContext.mcp
        )
    }
}

// MARK: - Attachments

/// Thumbnails of the images a sent message carried. Clicking opens the full
/// image, so a small preview isn't the only thing the user ever sees.
struct ChatImageGridView: View {
    let images: [ChatImage]

    var body: some View {
        // A plain `HStack` in a horizontal `ScrollView` rather than a `LazyVGrid`:
        // the transcript stack above is eager, and a lazy container inside it
        // would claim no height until it scrolled into view.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(images) { image in
                    ChatAttachmentThumbnail(image: image, onRemove: nil)
                }
            }
        }
        .frame(maxWidth: 340, alignment: .trailing)
    }
}

/// One attachment: a decoded thumbnail with its file name in the tooltip.
/// `onRemove` non-nil makes it an editable chip in the composer's strip.
struct ChatAttachmentThumbnail: View {
    let image: ChatImage
    var onRemove: (() -> Void)? = nil

    @State private var showPreview = false

    private var side: CGFloat { onRemove == nil ? 92 : 56 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                showPreview = true
            } label: {
                thumbnail
            }
            .buttonStyle(.plain)
            .help(image.fileName ?? "Attached image")

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .shadow(radius: 1)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help("Remove this image")
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let nsImage = ChatImageCache.image(for: image) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 560)
                } else {
                    Text("Couldn't decode this image.").font(.caption)
                }
                Text("\(image.width) × \(image.height)\(image.fileName.map { " · \($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let nsImage = ChatImageCache.image(for: image) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: side, height: side)
                .overlay(Image(systemName: "photo").foregroundColor(.secondary))
        }
    }
}

/// The pre-send review for a message that holds a secret (see
/// `SecretRedaction`). It shows the final submission as a delta — each secret
/// struck out with its placeholder beside it — and lets the user keep any one
/// of them in the clear. The secret itself is only ever shown masked here.
struct SecretRedactionReviewCard: View {
    let redaction: SecretRedaction
    /// The approved text, or nil to go back and edit.
    let onFinish: (String?) -> Void

    /// Findings the user chose to send as written. Empty by default: the
    /// safe answer is the one a quick Send gives.
    @State private var kept: Set<Int> = []

    private var redactedCount: Int { redaction.findings.count - kept.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                Text("This message contains \(redaction.countLabel)")
                    .font(.caption.bold())
                Spacer()
            }
            Text("Review what will be sent. Struck-out text is replaced by the green placeholder.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(deltaText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 160)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                ForEach(redaction.findings) { finding in
                    Toggle(isOn: Binding(
                        get: { !kept.contains(finding.id) },
                        set: { redact in
                            if redact { kept.remove(finding.id) } else { kept.insert(finding.id) }
                        }
                    )) {
                        Text("Redact \(finding.kind.displayName) (\(finding.masked))")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .trailing, spacing: 6) { buttons }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Edit") { onFinish(nil) }
            .keyboardShortcut(.cancelAction)
            .help("Go back to the message without sending it")
        Button("Send as Written") { onFinish(redaction.original) }
            .help("Send the message with every secret in it, unchanged")
        Button(redactedCount == 0 ? "Send" : "Send Redacted") {
            onFinish(redaction.text(keeping: kept))
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .help("Send the message as shown above")
    }

    /// The delta as one styled run, so it wraps like the message itself.
    private var deltaText: AttributedString {
        var result = AttributedString()
        for segment in redaction.segments(keeping: kept) {
            switch segment {
            case .unchanged(let text):
                result += AttributedString(text)
            case .replaced(_, let masked, let placeholder):
                var removed = AttributedString(masked)
                removed.foregroundColor = .red
                removed.strikethroughStyle = .single
                var added = AttributedString(placeholder)
                added.foregroundColor = .green
                added.backgroundColor = Color.green.opacity(0.12)
                result += removed + AttributedString(" ") + added
            case .kept(let id, _):
                let masked = redaction.findings.first { $0.id == id }?.masked ?? "…"
                var shown = AttributedString("\(masked) (sent as written)")
                shown.foregroundColor = .orange
                result += shown
            }
        }
        return result
    }
}


// MARK: - Case File (ported from Clippy's WorkPanel case tab)

/// The open case: the charter (ratified or still a proposal), the done-when
/// standard, the decisions and claims recorded so far, the trade-study
/// options, the risks, and the adversarial review's tally — with the drift
/// warning, the checkpoints menu, and Close case. Ported from Clippy's
/// `CaseTabContent` and docked as a card, matching the plan card above it.
struct CaseFileCard: View {
    @ObservedObject var agent: AIChatManager
    let caseFile: CaseFile

    @State private var confirmClose = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass").foregroundColor(.purple)
                Text("Case file").font(.caption.bold())
                methodLine
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    phaseStepper
                    charterBlock
                    if let drift = caseFile.drift {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Label(drift, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("Dismiss") { agent.dismissCaseDrift() }
                                .font(.caption2)
                                .buttonStyle(.borderless)
                                .help("The work is on track — clear this warning")
                        }
                    }
                    standard
                    section("Open issues", lines: caseFile.openIssues.map { issue in
                        "\(issue.id) \(issue.text)" + (issue.needsUser ? " — needs you" : "") + (issue.fromReview ? " — objection" : "")
                    })
                    optionsBlock
                    section("Risks", lines: caseFile.risks.map { risk in
                        "\(risk.id) [\(risk.status.rawValue)\(risk.isHigh ? ", high" : "")] \(risk.text) — \(risk.likelihood)×\(risk.impact)"
                            + (risk.mitigation.map { " — mitigation: \($0)" } ?? "")
                    })
                    section("Settled", lines: caseFile.settled.filter(\.isInForce).map { "\($0.id) \($0.text) — \($0.reason)" })
                    section("Claims", lines: caseFile.claims.filter { $0.status != .withdrawn }.map {
                        "\($0.id) [\($0.status.rawValue)] \($0.claim) — refuted if: \($0.rebuttal)"
                    })
                    reviewBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            footer
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06))
        .confirmationDialog("Close this case?", isPresented: $confirmClose) {
            Button("Close case", role: .destructive) { agent.closeCase() }
        } message: {
            Text("The charter, standard and checkpoints are removed from this chat. The transcript stays.")
        }
    }

    /// Method, iteration and budget: the small header line.
    @ViewBuilder
    private var methodLine: some View {
        Text(caseFile.method.name)
            .font(.caption2.bold())
            .foregroundColor(.purple)
            .help(caseFile.method.summary)
        if caseFile.iteration > 1 || caseFile.charter?.iterationBudget != nil {
            Text("Iteration \(caseFile.iteration)\(caseFile.charter?.iterationBudget.map { " of \($0)" } ?? "")")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        if let turns = caseFile.charter?.turnBudget {
            Text("Turns \(caseFile.turnsUsed)/\(turns)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(caseFile.budgetExhausted ? .orange : .secondary)
        }
        if caseFile.budgetExhausted {
            Label("Budget spent", systemImage: "hourglass")
                .font(.caption2)
                .foregroundColor(.orange)
                .help("The assistant stops and waits for you to extend the budget or narrow the scope.")
        }
    }

    /// Wraps instead of truncating: the docked strip is too narrow for five
    /// phase names on one line.
    private var phaseStepper: some View {
        HStack(spacing: 2) {
            ForEach(CaseFile.Phase.allCases, id: \.self) { phase in
                Text(caseFile.title(for: phase))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(phase == caseFile.phase ? Color.purple.opacity(0.25) : Color.clear)
                    .foregroundColor(phase.index <= caseFile.phase.index ? .primary : .secondary)
                    .cornerRadius(3)
            }
        }
    }

    /// The charter with its ratify state: a proposal is a working assumption,
    /// a ratified one is the standard the work is judged against.
    @ViewBuilder
    private var charterBlock: some View {
        if let charter = caseFile.charter {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(charter.objective)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(caseFile.charterRatified ? "Ratified" : "Proposed")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((caseFile.charterRatified ? Color.green : Color.orange).opacity(0.18))
                        .cornerRadius(4)
                        .help(caseFile.charterRatified
                              ? "You approved this charter; the work is judged against it. Changing it asks you first."
                              : "Not approved yet — the assistant treats it as a working assumption.")
                }
                ForEach(Array((charter.definitions.map { "Means: \($0)" }
                    + charter.constraints.map { "Constraint: \($0)" }
                    + charter.outOfScope.map { "Out of scope: \($0)" }).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("No charter yet — the assistant is agreeing the goal with you.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// The done-when standard: a criterion counts as met only with evidence.
    @ViewBuilder
    private var standard: some View {
        if !caseFile.criteria.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Standard").font(.caption2.bold()).foregroundColor(.purple)
                ForEach(caseFile.criteria) { criterion in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: criterion.met ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(criterion.met ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(criterion.id) \(criterion.text)").font(.caption)
                            if let evidence = criterion.evidence {
                                Text(evidence).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The trade study: one row per option, the chosen one marked, with its
    /// total score when the options were scored.
    @ViewBuilder
    private var optionsBlock: some View {
        if !caseFile.options.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Options").font(.caption2.bold()).foregroundColor(.purple)
                ForEach(caseFile.options) { option in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: option.status == .chosen ? "star.fill" : (option.status == .rejected ? "xmark.circle" : "circle"))
                            .foregroundColor(option.status == .chosen ? .yellow : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(option.id) \(option.title)\(option.scores.isEmpty ? "" : " — \(option.total) pts")")
                                .font(.caption)
                                .foregroundColor(option.status == .rejected ? .secondary : .primary)
                            if !option.summary.isEmpty {
                                Text(option.summary).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The last adversarial review: its tally, and the stale items — which
    /// are the list a re-review will actually work through, so showing them
    /// is what makes the round's cost visible before it is spent.
    @ViewBuilder
    private var reviewBlock: some View {
        if let review = caseFile.lastReview {
            let checklist = caseFile.reviewChecklist
            VStack(alignment: .leading, spacing: 3) {
                Text("Review").font(.caption2.bold()).foregroundColor(.purple)
                if checklist.isEmpty {
                    Text("Last review: \(review.objections) objection\(review.objections == 1 ? "" : "s")\(caseFile.isReviewCurrent ? "" : " (stale — evidence changed since)")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    let passed = checklist.filter(\.passed).count
                    Text("\(passed) of \(checklist.count) checked · \(review.objections) objection\(review.objections == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(checklist.filter(\.isStale)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "circle.dashed")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            Text("\(item.id) \(item.kind.label) — \(item.subject)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption2.bold()).foregroundColor(.purple)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !agent.caseCheckpoints.isEmpty {
                Menu {
                    ForEach(agent.caseCheckpoints.reversed()) { checkpoint in
                        Menu("\(checkpoint.label) · \(checkpoint.date.formatted(date: .omitted, time: .shortened))") {
                            Button("Restore the case to this point") {
                                agent.restoreCaseCheckpoint(checkpoint.id)
                            }
                            Button("Branch a new chat from here") {
                                _ = agent.branchFromCaseCheckpoint(checkpoint.id)
                            }
                        }
                    }
                } label: {
                    Label("Checkpoints", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(agent.isGenerating)
                .help("Go back to an earlier state of the case, or try another approach in a new chat")
            }
            Spacer()
            Button("Close case") { confirmClose = true }
                .font(.caption2)
                .buttonStyle(.borderless)
                .disabled(agent.isGenerating)
        }
    }
}

// MARK: - A2UI Surface Card (ported from Clippy's ChatView)

/// The `agent__show_ui` form: the rendered A2UI surfaces, with the dismiss
/// that resumes the suspended tool call. The run is paused until a button is
/// pressed or the card is dismissed, exactly like the question card.
struct SurfaceCardView: View {
    @ObservedObject var agent: AIChatManager
    let pending: PendingSurfaceUI

    private var surfaces: [A2UIRenderedSurface] {
        A2UIBuilder.surfaces(of: pending.document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(surfaces) { surface in
                A2UISurfaceView(
                    surface: surface,
                    onBinding: { path, value in
                        agent.setSurfaceBinding(value, at: path, on: surface.id)
                    },
                    onAction: { surfaceId, componentId, action in
                        agent.submitSurfaceAction(
                            surfaceId: surfaceId,
                            sourceComponentId: componentId,
                            action: action
                        )
                    },
                    onEffect: { agent.performSurfaceEffect($0) }
                )
            }
            footer
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accentColor.opacity(0.6), lineWidth: 1)
        )
    }

    /// The theme's own primary colour when the model set one, otherwise the
    /// system accent: a card that names its agent should look like that agent.
    private var accentColor: Color {
        guard let rgb = surfaces.first?.theme.rgb else { return .accentColor }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .foregroundColor(accentColor)
            Text(pending.title
                 ?? pending.agentDisplayName.map { "\($0) asks" }
                 ?? "The assistant asks")
                .font(.subheadline.bold())
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Dismiss") { agent.dismissSurfaceUI() }
                    .controlSize(.small)
                    .help("Close this form — the assistant will state an assumption and carry on")
                Spacer()
            }
            Text("The run is paused until you press one of the buttons above.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Draws one surface's component tree. Each case maps a catalog component to
/// the nearest native control; the enums are handled explicitly so a new
/// catalog component is a compile error here rather than a silent blank.
struct A2UISurfaceView: View {
    let surface: A2UIRenderedSurface
    let onBinding: (String, A2UIValue) -> Void
    let onAction: (String, String, A2UIAction) -> Void
    let onEffect: (A2UIEffect) -> Void

    var body: some View {
        A2UINodeView(
            node: surface.root,
            surfaceId: surface.id,
            theme: surface.theme,
            onBinding: onBinding,
            onAction: onAction,
            onEffect: onEffect
        )
    }
}

/// One node and, recursively, its children.
///
/// `@State` here holds only view-local state (a Modal's disclosure, which tab a
/// Tabs component is on). Everything that the model can read back lives in the
/// surface's data model, so a redraw cannot lose an answer.
struct A2UINodeView: View {
    let node: A2UINode
    let surfaceId: String
    let theme: A2UITheme
    let onBinding: (String, A2UIValue) -> Void
    let onAction: (String, String, A2UIAction) -> Void
    let onEffect: (A2UIEffect) -> Void

    @State private var modalPresented = false
    @State private var selectedTab = 0
    @State private var filterText = ""

    private var accent: Color {
        guard let rgb = theme.rgb else { return .accentColor }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        switch node {
        case .text(_, let text, let variant):
            markdown(text, variant: variant)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .image(_, let url, let description, let fit, let variant):
            remoteImage(url: url, description: description, fit: fit, variant: variant)

        case .icon(_, let name, let svgPath):
            // Only the named icons are drawn: an inline SVG path would need a
            // path parser, and a glyph that is wrong is worse than one that is
            // absent.
            if svgPath != nil {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
                    .help("Inline SVG icons are not drawn")
            } else {
                Image(systemName: name).foregroundColor(accent)
            }

        case .video(_, let url):
            A2UILinkRow(symbol: "play.rectangle", text: url, url: url)

        case .audio(_, let url, let description):
            A2UILinkRow(
                symbol: "waveform",
                text: description.isEmpty ? url : description,
                url: url
            )

        case .divider(_, let axis):
            if axis == "vertical" {
                Divider().frame(height: 18)
            } else {
                Divider()
            }

        case .textField(_, let label, let value, let variant, let boundPath, let errors):
            field(label: label, errors: errors) {
                if variant == "longText" {
                    TextField(label.isEmpty ? "Text" : label, text: binding(for: boundPath, current: .string(value), as: .string), axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                } else if variant == "obscured" {
                    SecureField(label.isEmpty ? "Password" : label, text: binding(for: boundPath, current: .string(value), as: .string))
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(
                        label.isEmpty ? "Text" : label,
                        text: binding(
                            for: boundPath,
                            current: .string(value),
                            as: variant == "number" ? .number : .string
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

        case .checkBox(_, let label, let isOn, let boundPath, let errors):
            field(label: "", errors: errors) {
                Toggle(isOn: boolBinding(for: boundPath, current: isOn)) {
                    Text(label).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }

        case .choicePicker(_, let label, let options, let selected, let multiple, let displayStyle, let filterable, let boundPath, let errors):
            field(label: label, errors: errors) {
                choicePicker(
                    options: options,
                    selected: selected,
                    multiple: multiple,
                    displayStyle: displayStyle,
                    filterable: filterable,
                    boundPath: boundPath
                )
            }

        case .slider(_, let label, let value, let min, let max, let boundPath, let errors):
            field(label: label, errors: errors) {
                HStack(spacing: 8) {
                    if max > min {
                        Slider(
                            value: numberBinding(for: boundPath, current: value),
                            in: min...max,
                            step: sliderStep(min: min, max: max)
                        )
                    }
                    Text(A2UIFunctions.formatNumber(
                        numberBinding(for: boundPath, current: value).wrappedValue,
                        decimals: nil,
                        grouping: true,
                        currency: nil
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                }
            }

        case .dateTime(_, let label, let value, let enableDate, let enableTime, let min, let max, let boundPath, let errors):
            field(label: label, errors: errors) {
                dateTimeInput(
                    current: value,
                    enableDate: enableDate,
                    enableTime: enableTime,
                    min: min,
                    max: max,
                    boundPath: boundPath
                )
            }

        case .button(_, let label, let isIconOnly, let variant, let action, let disabled, let disabledReason):
            button(
                label: label,
                isIconOnly: isIconOnly,
                variant: variant,
                action: action,
                disabled: disabled,
                disabledReason: disabledReason
            )

        case .row(_, let children, let justify, let align):
            layout(children: children, axis: .horizontal, justify: justify, align: align)

        case .column(_, let children, let justify, let align):
            layout(children: children, axis: .vertical, justify: justify, align: align)

        case .list(_, let children, let direction, let align, let listStyle):
            list(children: children, direction: direction, align: align, listStyle: listStyle)

        case .card(_, let child):
            childView(child)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

        case .tabs(_, let tabs):
            tabsView(tabs)

        case .modal(_, let trigger, let content, let opensOnPress):
            VStack(alignment: .leading, spacing: 8) {
                if opensOnPress {
                    // The spec: the trigger "opens the modal when interacted
                    // with". A trigger with no action of its own would draw a
                    // dead button, so the whole subtree is made tappable.
                    childView(trigger)
                        .contentShape(Rectangle())
                        .onTapGesture { modalPresented.toggle() }
                } else {
                    childView(trigger)
                }
                if modalPresented {
                    childView(content)
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.5)))
                }
            }

        case .unsupported(_, let type, let note):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type == "depth" || type == "cycle"
                         ? "Could not draw this part"
                         : "Unsupported component: \(type)")
                        .font(.caption.bold())
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(6)
        }
    }

    // MARK: - Children

    private func childView(_ child: A2UINode) -> some View {
        A2UINodeView(
            node: child,
            surfaceId: surfaceId,
            theme: theme,
            onBinding: onBinding,
            onAction: onAction,
            onEffect: onEffect
        )
    }

    @ViewBuilder
    private func layout(children: [A2UINode], axis: Axis, justify: String, align: String) -> some View {
        let spacing: CGFloat = 8
        if axis == .horizontal {
            // A wrap, not an HStack: a docked chat cannot afford a row that
            // overflows, and a form's two short fields should sit side by
            // side until they cannot.
            A2UIWrapLayout(spacing: spacing, lineSpacing: 6) {
                ForEach(children) { child in
                    childView(child)
                }
            }
            .frame(maxWidth: .infinity, alignment: justifyAlignment(justify, axis: axis))
        } else {
            VStack(alignment: horizontalAlignment(align), spacing: spacing) {
                ForEach(children) { child in
                    childView(child)
                        .frame(maxWidth: .infinity, alignment: justifyAlignment(justify, axis: axis))
                }
            }
            .frame(maxWidth: .infinity, alignment: justifyAlignment(justify, axis: axis))
        }
    }

    private func justifyAlignment(_ justify: String, axis: Axis) -> Alignment {
        switch justify {
        case "center": return .center
        case "end": return axis == .horizontal ? .trailing : .bottom
        case "spaceBetween", "spaceAround", "spaceEvenly", "stretch": return .leading
        default: return axis == .horizontal ? .leading : .top
        }
    }

    private func horizontalAlignment(_ align: String) -> HorizontalAlignment {
        switch align {
        case "center": return .center
        case "end": return .trailing
        default: return .leading
        }
    }

    private func list(children: [A2UINode], direction: String, align: String, listStyle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                HStack(alignment: .top, spacing: 6) {
                    if direction == "vertical", listStyle != "none" {
                        Text(listStyle == "ordered" ? "\(index + 1)." : "•")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                    }
                    childView(child)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabsView(_ tabs: [A2UITab]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $selectedTab) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    Text(tab.title.isEmpty ? "Tab \(index + 1)" : tab.title).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tabs.indices.contains(selectedTab) {
                childView(tabs[selectedTab].node)
            }
        }
    }

    // MARK: - Leaves

    @ViewBuilder
    private func markdown(_ text: String, variant: String) -> some View {
        switch variant {
        case "h1": MarkdownText(text: text, font: .title2.bold())
        case "h2": MarkdownText(text: text, font: .title3.bold())
        case "h3": MarkdownText(text: text, font: .headline)
        case "h4": MarkdownText(text: text, font: .subheadline.bold())
        case "h5": MarkdownText(text: text, font: .caption.bold())
        case "caption": MarkdownText(text: text, font: .caption).foregroundColor(.secondary)
        default: MarkdownText(text: text, font: .callout)
        }
    }

    @ViewBuilder
    private func remoteImage(url: String, description: String, fit: String, variant: String) -> some View {
        if let resolved = URL(string: url), resolved.scheme?.hasPrefix("http") == true {
            AsyncImage(url: resolved) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode(fit))
                case .failure:
                    Label(description.isEmpty ? "Image could not be loaded" : description, systemImage: "photo")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: imageHeight(variant))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(description)
        } else {
            Label(description.isEmpty ? url : description, systemImage: "photo")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func contentMode(_ fit: String) -> ContentMode {
        switch fit {
        case "contain": return .fit
        case "fill", "cover": return .fill
        default: return .fit
        }
    }

    private func imageHeight(_ variant: String) -> CGFloat? {
        switch variant {
        case "icon": return 24
        case "avatar": return 40
        case "smallFeature": return 80
        case "mediumFeature": return 140
        case "largeFeature": return 220
        case "header": return 120
        default: return 140
        }
    }

    private func button(
        label: String,
        isIconOnly: Bool,
        variant: String,
        action: A2UIAction?,
        disabled: Bool,
        disabledReason: String?
    ) -> some View {
        Button {
            guard let action else { return }
            onAction(surfaceId, node.sourceComponentId, action)
        } label: {
            if isIconOnly, label.isEmpty {
                // The child was an Icon, whose resolved name is the SF Symbol
                // the builder chose. Reading it back off the label is not
                // possible, so the catalog's neutral one is used rather than a
                // blank button.
                Image(systemName: "arrow.right.circle")
                    .frame(minWidth: 20)
            } else {
                Text(label.isEmpty ? (action?.name ?? "Submit") : label)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .modifier(A2UIButtonStyle(variant: variant, accent: accent))
        .disabled(action == nil || disabled)
        .help(disabledReason ?? (action == nil ? "This button has no action." : (action.map { "Sends “\($0.name)”" } ?? "")))
    }

    // MARK: - Inputs

    private func field<Content: View>(
        label: String,
        errors: [String],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
            ForEach(errors, id: \.self) { message in
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    /// A field's binding writes to the data model as the user types, which is
    /// the protocol's two-way binding. An unbound field (a literal value and no
    /// `path`) keeps its text view-locally and is never read back, which is
    /// what the spec says a literal means.
    private func binding(for path: String?, current: A2UIValue, as kind: A2UIInputKind) -> Binding<String> {
        guard let path else {
            return .constant(current.displayString)
        }
        return Binding(
            get: { current.displayString },
            set: { onBinding(path, kind.vocabulary($0)) }
        )
    }

    private func boolBinding(for path: String?, current: Bool) -> Binding<Bool> {
        guard let path else { return .constant(current) }
        return Binding(
            get: { current },
            set: { onBinding(path, .bool($0)) }
        )
    }

    private func numberBinding(for path: String?, current: Double) -> Binding<Double> {
        guard let path else { return .constant(current) }
        return Binding(
            get: { current },
            set: { onBinding(path, .number($0)) }
        )
    }

    private func sliderStep(min: Double, max: Double) -> Double {
        let span = max - min
        if span <= 10 { return 1 }
        if span <= 100 { return 1 }
        return (span / 100).rounded()
    }

    @ViewBuilder
    private func choicePicker(
        options: [A2UIOption],
        selected: [String],
        multiple: Bool,
        displayStyle: String,
        filterable: Bool,
        boundPath: String?
    ) -> some View {
        let visible = filterable && !filterText.isEmpty
            ? options.filter { $0.label.localizedCaseInsensitiveContains(filterText) }
            : options
        VStack(alignment: .leading, spacing: 5) {
            if filterable {
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            if displayStyle == "chips" {
                A2UIWrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(visible) { option in
                        let isSelected = selected.contains(option.value)
                        Button {
                            toggle(option.value, selected: selected, multiple: multiple, boundPath: boundPath)
                        } label: {
                            Text(option.label)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? accent.opacity(0.2) : Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isSelected ? accent : Color.secondary.opacity(0.3))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ForEach(visible) { option in
                    let isSelected = selected.contains(option.value)
                    Button {
                        toggle(option.value, selected: selected, multiple: multiple, boundPath: boundPath)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: isSelected
                                  ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                  : (multiple ? "square" : "circle"))
                                .foregroundColor(isSelected ? accent : .secondary)
                            Text(option.label)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ value: String, selected: [String], multiple: Bool, boundPath: String?) {
        guard let boundPath else { return }
        var next = selected
        if multiple {
            if let index = next.firstIndex(of: value) {
                next.remove(at: index)
            } else {
                next.append(value)
            }
        } else {
            next = selected.contains(value) ? [] : [value]
        }
        onBinding(boundPath, .array(next.map { .string($0) }))
    }

    @ViewBuilder
    private func dateTimeInput(
        current: String,
        enableDate: Bool,
        enableTime: Bool,
        min: String?,
        max: String?,
        boundPath: String?
    ) -> some View {
        // The stored form is ISO 8601, as the catalog requires. A date-only
        // field writes `yyyy-MM-dd`, a time-only one `HH:mm`, and both together
        // the full timestamp, so the model gets a value it can parse.
        HStack(spacing: 6) {
            if enableDate {
                DatePicker(
                    "",
                    selection: dateBinding(current: current, enableTime: enableTime, boundPath: boundPath),
                    displayedComponents: enableTime ? [.date, .hourAndMinute] : [.date]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
            } else if enableTime {
                DatePicker(
                    "",
                    selection: timeBinding(current: current, boundPath: boundPath),
                    displayedComponents: [.hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
            } else {
                Text(current.isEmpty ? "Choose a date" : current)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if let min, !min.isEmpty, let max, !max.isEmpty {
                Text("\(min) – \(max)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func dateBinding(current: String, enableTime: Bool, boundPath: String?) -> Binding<Date> {
        let fallback = A2UIFunctions.date(fromISO: current) ?? Date()
        return Binding(
            get: { A2UIFunctions.date(fromISO: current) ?? fallback },
            set: { date in
                guard let boundPath else { return }
                let formatter = ISO8601DateFormatter()
                if enableTime {
                    formatter.formatOptions = [.withInternetDateTime]
                    onBinding(boundPath, .string(formatter.string(from: date)))
                } else {
                    formatter.formatOptions = [.withFullDate]
                    formatter.timeZone = .current
                    onBinding(boundPath, .string(formatter.string(from: date)))
                }
            }
        )
    }

    private func timeBinding(current: String, boundPath: String?) -> Binding<Date> {
        let fallback = A2UIFunctions.date(fromISO: current) ?? Date()
        return Binding(
            get: { A2UIFunctions.date(fromISO: current) ?? fallback },
            set: { date in
                guard let boundPath else { return }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HH:mm"
                onBinding(boundPath, .string(formatter.string(from: date)))
            }
        )
    }
}

/// What kind of value an input writes into the data model. A `number` field
/// stores a number, not the digits as a string, so a `numeric` check on it
/// works without the model having to coerce.
enum A2UIInputKind {
    case string
    case number

    func vocabulary(_ text: String) -> A2UIValue {
        switch self {
        case .string:
            return .string(text)
        case .number:
            // Keep the text while it is not yet a number ("", "-", "1."), so a
            // half-typed value does not overwrite the field with nothing.
            if let value = Double(text) { return .number(value) }
            return .string(text)
        }
    }
}

/// The catalog's three button styles, mapped onto SwiftUI's. A `borderless`
/// button reads as a link, which is what the catalog means by it.
struct A2UIButtonStyle: ViewModifier {
    let variant: String
    let accent: Color

    func body(content: Content) -> some View {
        switch variant {
        case "primary":
            content
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.small)
        case "borderless":
            content
                .buttonStyle(.borderless)
                .controlSize(.small)
        default:
            content
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// A one-line link, for the catalog's `Video` and `AudioPlayer` components,
/// which this client does not play inline: opening them in the default app is
/// more useful than a dead player, and keeps the card's height bounded.
struct A2UILinkRow: View {
    let symbol: String
    let text: String
    let url: String

    var body: some View {
        Button {
            guard let resolved = URL(string: url),
                  let scheme = resolved.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            NSWorkspace.shared.open(resolved)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
    }
}

/// A wrapping layout: children sit in a row until the width runs out, then
/// start a new line. Used for `Row` and for chips, because a docked chat is
/// narrow and a plain `HStack` would push a form's second column off the edge
/// where it cannot be reached.
struct A2UIWrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth == .infinity ? width : maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: nil, height: nil))
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: nil, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Transcript rows for the new message roles (ported from Clippy)

/// A screen capture that was OCR'd: the recognized text, how confident
/// Vision was, and a copy button — so the model's answer is traceable to
/// exactly what was read.
struct ScreenCaptureRow: View {
    let message: ChatMessage
    @State private var copied = false

    private var confidencePercent: Int {
        Int(((message.ocrConfidence ?? 1) * 100).rounded())
    }

    private var confidenceColor: Color {
        switch message.ocrConfidence ?? 1 {
        case ..<0.5: return .red
        case ..<0.75: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Screen capture", systemImage: "text.viewfinder")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("OCR \(confidencePercent)%")
                    .font(.caption2)
                    .foregroundColor(confidenceColor)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy the recognized text")
            }
            Text(message.text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}

/// A calculator run — a result, or a drawn chart. Rendered with the
/// calculator's own styling so math reads like math, and with a copy button.
struct CalculationRow: View {
    let message: ChatMessage
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Calculator", systemImage: "function")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Copy the result")
            }

            if let plot = message.plot {
                PlotChartView(spec: plot, dark: colorScheme == .dark)
                    .frame(height: 200)
            }

            Text(message.text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.black.opacity(0.06))
                .cornerRadius(6)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
    }
}


private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The Find bar's text field. An `NSTextField` rather than a SwiftUI
/// `TextField` so Esc reliably closes the bar and Return steps to the next
/// hit, and so focus can be pulled onto it when the bar opens (⌘F) — the
/// same field the editor's find panel uses.
struct FindField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusToken: Int
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = "Find in conversation"
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        // Be a real search field for assistive tech and VoiceOver.
        field.setAccessibilityLabel("Find in conversation")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Don't overwrite the field editor's contents while the user is actively typing in it.
        if let editor = field.currentEditor() {
            if editor.string != text {
                let selectedRange = editor.selectedRange
                editor.string = text
                editor.selectedRange = selectedRange
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            // The field may not be in a window yet on the frame the bar is
            // inserted, so try now and again on the next runloop turn.
            focus(field)
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                focus(field)
            }
        }
    }

    /// Makes the field editable and focused, retrying on the next turn when
    /// it is still being attached (the common case: the bar is inserted by
    /// the same state change that asked for focus).
    ///
    /// `makeFirstResponder` alone leaves an `NSTextField` merely focused —
    /// typing goes nowhere because its field editor was never started.
    /// `selectText(_:)` is the API that both takes first responder and
    /// begins editing (and selects what is there, ready to be replaced).
    private func focus(_ field: NSTextField) {
        guard let window = field.window else { return }
        if window.firstResponder !== field.currentEditor() {
            window.makeFirstResponder(field)
        }
        field.selectText(nil)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindField
        var lastFocusToken: Int

        init(_ parent: FindField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return steps to the next hit (the caller's `onSubmit`).
        @objc func submit() {
            parent.onSubmit()
        }

        /// Esc closes the bar. `control(_:textView:doCommandBy:)` is the only
        /// reliable way to see Esc in an NSTextField.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
