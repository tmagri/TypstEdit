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
    @ObservedObject private var store = AIChatSessionStore.shared
    @ObservedObject private var aiSettings = AISettingsManager.shared
    @ObservedObject private var skillsManager = SkillsManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared

    @State private var draft: String = ""
    @State private var showYoloConfirm = false
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
    /// hundreds of messages on every update.
    @State private var transcriptWindow = 120
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
    /// a new `.user` message, because the goal loop appends user-role
    /// continuations while the turn is still running, and those are not the
    /// user asking to be taken back to the bottom.
    @State private var scrollToLatestRequest = 0

    /// Height of the transcript's viewport. Cards under it (plan, goal,
    /// approval, compaction) come and go mid-run and resize it; a lazy stack
    /// whose visible rect changed under it can end up showing nothing until
    /// the next scroll, so a resize re-anchors the follow target.
    @State private var transcriptViewportHeight: CGFloat = 0

    @State private var showRename = false
    @State private var renameDraft: String = ""
    @State private var actionError: String?
    @State private var showGoalSet = false
    @State private var goalDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !aiSettings.chatEnabled {
                disabledState
            } else {
                transcript
                if let goal = chat.goal {
                    Divider()
                    goalBanner(goal)
                }
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
        .alert("Set a Goal", isPresented: $showGoalSet) {
            TextField("Objective", text: $goalDraft)
            Button("Cancel", role: .cancel) {}
            Button("Set & Start") {
                let draft = goalDraft
                goalDraft = ""
                scrollToLatestRequest += 1
                Task { await chat.armGoal(draft) }
            }
        } message: {
            Text("The AI keeps working toward this objective across replies — a reviewer continues or pauses it after each round. Stop parks it.")
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
                sessionsMenu
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
    private static let transcriptWindowStep = 120

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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
                    ForEach(visibleMessages) { message in
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
                    // Always present, so the bottom is reachable even in an
                    // empty (new) conversation with no last message.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomID)
                }
                .padding(10)
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
            // transcript shrinks it, and the lazy stack needs to re-resolve
            // which rows are visible.
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
            // Streaming updates only grow the live row, so they take the
            // coalesced path: a stream of deltas costs at most one scroll.
            .onChange(of: chat.liveReasoning) { _ in followBottom(proxy) }
            .onChange(of: chat.liveStatus) { _ in followBottom(proxy) }
            .onChange(of: chat.runningTool) { _ in followBottom(proxy) }
        }
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

    /// The live "Thinking…" row shown while a response is being generated.
    /// While the model streams reasoning, the box is open by default so the
    /// thinking is actually visible as it arrives; it can be collapsed (and
    /// the header's "Collapse all thinking" closes it too) without stopping
    /// the response. A running tool call is reported on its own line beneath
    /// the thinking, so the reasoning doesn't vanish while a task runs.
    @ViewBuilder
    private var generatingRow: some View {
        let reasoning = chat.liveReasoning
        let statusText = chat.liveStatus ?? "Thinking…"
        VStack(alignment: .leading, spacing: 6) {
            if reasoning.isEmpty {
                // Nothing to show yet (or the model doesn't expose its
                // reasoning): spinner plus why it's still working.
                if let running = chat.runningTool {
                    runningTaskRow(running)
                } else {
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
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
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
            .help("Stop this task, aborting it if it is still running, and let the assistant continue without its result")
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
                    // Stays enabled while the AI works: sending then steers
                    // the running task instead of starting a new turn.
                    .disabled(chat.pendingApproval != nil)
                    .help(chat.isGenerating
                          ? "The AI is working. Sending now steers the current task — it reads your message at its next step."
                          : "Ask anything. Shift+Return sends.")

                if chat.isGenerating {
                    // A sibling of the (still enabled) TextEditor, so it stays
                    // pressable while generation runs — including while an
                    // approval is pending, since `isGenerating` covers that.
                    // A non-empty draft gets a steering send next to Stop.
                    if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            send()
                        } label: {
                            Image(systemName: "arrow.up.circle").font(.system(size: 24))
                        }
                        .buttonStyle(.plain)
                        .help("Send as steering input — the AI adjusts course at its next step")
                    }
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
                    goalMenu(iconOnly: iconOnly)
                    Spacer(minLength: 0)
                    planToggle(iconOnly: iconOnly)
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
                goalMenu(iconOnly: iconOnly)
                AIModelPickerMenu(feature: .chat, showsName: !iconOnly)
                    .disabled(chat.isGenerating)
                Spacer(minLength: 0)
                planToggle(iconOnly: iconOnly)
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

    /// Goal menu (opencode's `/goal`): arms an objective the chat keeps
    /// working toward, with pause/resume/clear for the loop it starts.
    private func goalMenu(iconOnly: Bool) -> some View {
        Menu {
            Button("Set goal…") {
                goalDraft = chat.goal?.objective ?? ""
                showGoalSet = true
            }
            if let goal = chat.goal {
                switch goal.status {
                case .active:
                    Button("Pause goal") { chat.pauseGoal() }
                    Button("Clear goal", role: .destructive) { chat.clearGoal() }
                case .paused:
                    Button("Resume goal") {
                        scrollToLatestRequest += 1
                        Task { await chat.resumeGoal() }
                    }
                    Button("Clear goal", role: .destructive) { chat.clearGoal() }
                case .complete:
                    Button("Clear goal") { chat.clearGoal() }
                }
            }
        } label: {
            pickerLabel(
                "Goal",
                systemImage: "flag.checkered",
                iconOnly: iconOnly
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundColor(goalLabelColor)
        .help(goalHelpText)
    }

    private var goalLabelColor: Color {
        guard let goal = chat.goal else { return .secondary }
        switch goal.status {
        case .active: return .accentColor
        case .complete: return .green
        case .paused: return .orange
        }
    }

    private var goalHelpText: String {
        guard let goal = chat.goal else {
            return "Goal mode: set an objective and the AI keeps working toward it across replies — a reviewer continues or pauses it after each round."
        }
        switch goal.status {
        case .active: return "Goal active — the AI keeps working toward it. Click to pause or clear."
        case .paused: return "Goal paused (\(goal.reason ?? "no reason recorded")). Click to resume or clear."
        case .complete: return "Goal complete: \(goal.reason ?? ""). Click to clear."
        }
    }

    /// The banner row shown while a goal exists — objective, round progress,
    /// and the reviewer's last word. The checklist card below it is what the
    /// goal actually drives.
    private func goalBanner(_ goal: ChatGoal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "flag.checkered")
                .foregroundColor(goal.status == .active ? .accentColor : goal.status == .complete ? .green : .orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(goalBannerTitle(goal))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(goal.objective)
                    .font(.caption)
                    .lineLimit(2)
                if let reason = goal.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if goal.status == .active {
                Button {
                    chat.pauseGoal()
                } label: {
                    Image(systemName: "pause.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Pause the goal — the loop stops after this reply; resume it from the Goal menu")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func goalBannerTitle(_ goal: ChatGoal) -> String {
        switch goal.status {
        case .active: return "Goal · round \(min(goal.rounds + 1, goal.maxRounds))/\(goal.maxRounds)"
        case .paused: return "Goal · paused"
        case .complete: return "Goal · complete"
        }
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
        // A send is an explicit "take me to the newest exchange" — it ends
        // manual mode, so the reply that follows is followed live again.
        scrollToLatestRequest += 1
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

        @objc private func contentResized() {
            report()
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
            // Our own scrolls (and the lazy-row height corrections right
            // after them) are not the user moving; reacting to them would
            // pause autoscroll in the middle of a generation. A live gesture
            // is the exception: it is always the user.
            guard force || isLiveUserScroll || !isProgrammaticScroll() else { return }
            // SwiftUI's document view is flipped (y = 0 at the top), so the
            // remaining distance is document height minus the visible bottom.
            let distanceToBottom: CGFloat
            if document.isFlipped {
                let maxOffset = max(0, document.frame.height - clipView.bounds.height)
                distanceToBottom = maxOffset - clipView.bounds.origin.y
            } else {
                distanceToBottom = clipView.bounds.origin.y
            }
            let atBottom = distanceToBottom <= TranscriptBottomProbe.slack
            guard atBottom != isAtBottom.wrappedValue else { return }
            isAtBottom.wrappedValue = atBottom
        }

        /// Keeps the viewport inside the document. A programmatic scroll is
        /// resolved against the lazy stack's *estimated* row heights; when the
        /// rows below then measure shorter (a big thinking preview replaced by
        /// a finished answer, a collapsed disclosure, the tail of a long
        /// transcript re-measured), the offset it picked can end up past the
        /// real content. Nothing constrains the clip view afterwards, so the
        /// panel would sit on empty space until the user scrolled — which is
        /// what "the chat view went blank, scrolling brings it back" is. This
        /// only ever pulls the viewport back to the last real position; it
        /// never scrolls away from where the user put it.
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
