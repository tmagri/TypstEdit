import SwiftUI
import AppKit

private struct GitDiffRequest: Identifiable {
    let change: GitChange
    let group: GitChangeGroup
    let repository: URL
    var id: String { "\(repository.path):\(group.rawValue):\(change.path)" }
}

/// Destructive or state-changing actions that need a second click. All
/// confirmations go through one `.alert(item:)`.
private enum GitConfirmation: Identifiable {
    case discard(GitChange)
    case discardAll
    case stageAllWithConflicts
    case acceptCurrent(GitChange)
    case acceptIncoming(GitChange)
    case markResolved(GitChange)
    case checkoutDetached(GitCommit)
    case deleteBranch(GitBranch, force: Bool)
    case deleteTag(String)
    case mergeBranch(String)
    case rebaseOnto(String)
    case revert(GitCommit)
    case abortOperation
    case dropStash(GitStash)

    var id: String {
        switch self {
        case .discard(let change): return "discard:\(change.id)"
        case .discardAll: return "discard-all"
        case .stageAllWithConflicts: return "stage-all-conflicts"
        case .acceptCurrent(let change): return "accept-current:\(change.id)"
        case .acceptIncoming(let change): return "accept-incoming:\(change.id)"
        case .markResolved(let change): return "mark-resolved:\(change.id)"
        case .checkoutDetached(let commit): return "checkout-detached:\(commit.id)"
        case .deleteBranch(let branch, let force): return "delete-branch:\(branch.name):\(force)"
        case .deleteTag(let tag): return "delete-tag:\(tag)"
        case .mergeBranch(let name): return "merge:\(name)"
        case .rebaseOnto(let name): return "rebase:\(name)"
        case .revert(let commit): return "revert:\(commit.id)"
        case .abortOperation: return "abort-operation"
        case .dropStash(let stash): return "drop-stash:\(stash.id)"
        }
    }
}

/// What runs after a successful commit.
private enum GitPostCommitAction {
    case none, push, sync
}

/// A compact Source Control section under the project explorer. The two
/// independent scroll areas keep changes and history usable in narrow sidebars.
struct SourceControlSidebarView: View {
    @ObservedObject var manager: SourceControlManager
    @ObservedObject var editorController: EditorController
    @Binding var selectedFile: URL?
    let projectRoot: URL
    let isLoading: Bool
    let availableHeight: CGFloat
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var isExpanded = true
    @State private var graphExpanded = true
    @State private var treeMode = true
    @State private var message = ""
    @State private var diffRequest: GitDiffRequest?
    @State private var confirmation: GitConfirmation?
    @State private var nameSheet: GitNameSheetKind?
    @State private var rewordRequest: GitRewordRequest?
    @FocusState private var messageFocused: Bool

    // MARK: Derived state

    private var conflicted: [GitChange] { manager.conflictedChanges }
    private var staged: [GitChange] { manager.changes.filter { $0.isStaged && !$0.isConflicted } }
    private var unstaged: [GitChange] { manager.changes.filter { $0.isUnstaged && !$0.isConflicted } }
    private var hasConflicts: Bool { !conflicted.isEmpty }
    private var hasMessage: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isWorking: Bool { manager.isBusy || isLoading }

    private var headCommit: GitCommit? { manager.commits.first(where: \.isHead) }
    private var headIsUnpushed: Bool { headCommit?.isUnpushed ?? false }
    private var currentBranchLabel: String { manager.branch.isEmpty ? "HEAD" : manager.branch }

    private var canCommit: Bool {
        !isWorking && !staged.isEmpty && hasMessage && !hasConflicts && protectedPaths.isEmpty
    }
    /// Amending is allowed with nothing staged (message-only amend), but not
    /// when HEAD is pushed or the repository has no commits.
    private var canAmend: Bool {
        !isWorking && manager.hasCommits && headIsUnpushed
            && !hasConflicts && manager.operationState == .none && protectedPaths.isEmpty
    }
    private var canUndoLastCommit: Bool {
        !isWorking && manager.hasCommits && headIsUnpushed && manager.operationState == .none
    }

    /// Ops that rewrite the working tree are disabled while the open file
    /// has unsaved edits: the next save would silently restore them.
    private var canChangeWorkingTree: Bool { !isWorking && protectedPaths.isEmpty }

    /// The open file is protected from discard while its buffer has edits:
    /// discarding on disk would make the next save restore those edits.
    private var protectedPaths: Set<String> {
        guard editorController.hasUnsavedChanges,
              let url = editorController.currentFileURL,
              let root = manager.repositoryRoot else { return [] }
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard file.hasPrefix(base + "/") else { return [] }
        return [String(file.dropFirst(base.count + 1))]
    }

    /// Fixed chrome is about 190 pt; keep at least four change rows visible.
    private var panelHeight: CGFloat {
        min(460, max(280, availableHeight * 0.5))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = manager.errorMessage {
                        errorBanner(error)
                    }
                    if isLoading && manager.repositoryRoot == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking repository…")
                                .font(.system(size: 12))
                                .foregroundColor(themeManager.secondaryTextColor)
                        }
                        .padding(12)
                        Spacer(minLength: 0)
                    } else if manager.repositoryRoot != nil {
                        repositoryContent
                    } else {
                        emptyRepository
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: panelHeight - 34)
                .clipped()
            }
        }
        .sheet(item: $diffRequest) { request in
            GitDiffPreviewView(manager: manager, change: request.change, group: request.group, repository: request.repository)
                .environmentObject(themeManager)
        }
        .sheet(item: $nameSheet) { kind in
            nameSheetContent(kind)
        }
        .sheet(item: $rewordRequest) { request in
            GitRewordSheet(manager: manager, commit: request.commit) { newMessage in
                rewordCommit(request.commit, message: newMessage)
            }
        }
        .alert(item: $confirmation) { item in
            confirmationAlert(item)
        }
        .task {
            // A merge may already be waiting when the panel appears.
            if manager.operationState == .merging { prefillPendingMergeMessage() }
        }
        .onChange(of: manager.operationState) { newState in
            if newState == .merging { prefillPendingMergeMessage() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Source Control")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(themeManager.textColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse Source Control" : "Expand Source Control")
            Spacer(minLength: 0)
            if isWorking {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 14, height: 14)
            } else if !manager.changes.isEmpty {
                countBadge(manager.changes.count)
            }
            Button { Task { await manager.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(themeManager.textColor.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .help("Refresh Source Control")
            .accessibilityLabel("Refresh Source Control")
            actionsMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(themeManager.sidebarOverlay.opacity(0.5))
    }

    private var actionsMenu: some View {
        Menu {
            Section("Changes View") {
                Button { treeMode = true } label: {
                    Label("Tree", systemImage: treeMode ? "checkmark" : "list.bullet.indent")
                }
                Button { treeMode = false } label: {
                    Label("List", systemImage: !treeMode ? "checkmark" : "list.bullet")
                }
            }
            if manager.repositoryRoot != nil {
                Divider()
                Button("Stage All Changes") { requestStageAll() }
                    .disabled(isWorking || unstaged.isEmpty)
                Button("Unstage All Changes") { Task { await manager.unstageAll() } }
                    .disabled(isWorking || staged.isEmpty)
                Button("Discard All Changes…", role: .destructive) { confirmation = .discardAll }
                    .disabled(isWorking || unstaged.isEmpty || !canChangeWorkingTree)
                Divider()
                stashMenu
                Divider()
                Button("Create Branch…") { nameSheet = .createBranch(atCommit: nil) }
                    .disabled(!canChangeWorkingTree)
                Button("Reveal Repository in Finder") {
                    if let root = manager.repositoryRoot { NSWorkspace.shared.selectFile(root.path, inFileViewerRootedAtPath: "") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Source Control Actions")
        .accessibilityLabel("Source Control Actions")
    }

    private var stashMenu: some View {
        Menu("Stash") {
            Button("Stash Changes") { stash(includeUntracked: false) }
                .disabled(!canStash || !canChangeWorkingTree)
                .help("Stash tracked changes and restore the working tree")
            Button("Stash (Include Untracked)") { stash(includeUntracked: true) }
                .disabled(!canStashUntracked || !canChangeWorkingTree)
            Divider()
            Button("Apply Latest Stash") { applyLatestStash() }
                .disabled(manager.stashes.isEmpty || !canChangeWorkingTree)
            Button("Pop Latest Stash") { popLatestStash() }
                .disabled(manager.stashes.isEmpty || !canChangeWorkingTree)
        }
    }

    private var hasStashableChanges: Bool { manager.changes.contains { !$0.isUntracked } }
    private var canStash: Bool { hasStashableChanges && !isWorking }
    private var canStashUntracked: Bool { !manager.changes.isEmpty && !isWorking }

    private func stash(includeUntracked: Bool) {
        guard canChangeWorkingTree else { return }
        guard includeUntracked ? canStashUntracked : canStash else {
            manager.errorMessage = "There is nothing to stash."
            return
        }
        Task { await manager.stash(message: nil, includeUntracked: includeUntracked) }
    }

    private func applyLatestStash() {
        guard let latest = manager.stashes.first, canChangeWorkingTree else { return }
        Task { await manager.applyStash(latest) }
    }

    private func popLatestStash() {
        guard let latest = manager.stashes.first, canChangeWorkingTree else { return }
        Task { await manager.popStash(latest) }
    }

    // MARK: Repository content

    private var repositoryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            GitBranchBar(
                manager: manager,
                canChangeWorkingTree: canChangeWorkingTree,
                onCheckout: checkoutBranch,
                onCheckoutRemote: checkoutRemote,
                onCreateBranch: { nameSheet = .createBranch(atCommit: nil) },
                onRenameBranch: { nameSheet = .renameBranch(current: manager.branch) },
                onRequestDeleteBranch: { branch, force in confirmation = .deleteBranch(branch, force: force) },
                onRequestMerge: { name in confirmation = .mergeBranch(name) },
                onRequestRebase: { name in confirmation = .rebaseOnto(name) },
                onCreateTag: { nameSheet = .createTag(atCommit: nil) },
                onRequestDeleteTag: { tag in confirmation = .deleteTag(tag) },
                onPull: pull,
                onSync: sync,
                onFetch: { Task { await manager.fetch() } },
                onPush: push,
                onCancelOperation: { Task { await manager.cancelCurrentOperation() } }
            )
            if manager.operationState != .none {
                GitOperationBanner(
                    state: manager.operationState,
                    hasConflicts: hasConflicts,
                    isBusy: manager.isBusy,
                    onAbort: { confirmation = .abortOperation },
                    onContinue: continueOperation
                )
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
            GitCommitControls(
                message: $message,
                messageFocus: $messageFocused,
                isBusy: isWorking,
                canCommit: canCommit,
                canAmend: canAmend,
                canUndoLastCommit: canUndoLastCommit,
                canPush: manager.hasRemote && manager.hasCommits && !manager.isDetachedHead,
                hint: commitHint,
                help: commitHelp,
                onCommit: { commit(amend: false) },
                onCommitAmend: { commit(amend: true) },
                onCommitAndPush: { commit(amend: false, then: .push) },
                onCommitAndSync: { commit(amend: false, then: .sync) },
                onUndoLastCommit: undoLastCommit
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            changesScroll
            Divider()
            graphHeader
            if graphExpanded {
                GitGraphView(manager: manager, actions: graphActions)
                    .frame(height: 92)
            }
        }
    }

    // MARK: Changes list

    private var changesScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !conflicted.isEmpty {
                    changeGroup(conflicted, group: .unstaged, title: "Merge Changes", isConflictGroup: true)
                        .id("merge-changes")
                }
                if !staged.isEmpty {
                    changeGroup(staged, group: .staged, title: "Staged Changes").id(GitChangeGroup.staged)
                }
                if !unstaged.isEmpty {
                    changeGroup(unstaged, group: .unstaged, title: "Changes").id(GitChangeGroup.unstaged)
                }
                if !manager.stashes.isEmpty {
                    GitStashesSection(
                        stashes: manager.stashes,
                        isBusy: isWorking,
                        canChangeWorkingTree: canChangeWorkingTree,
                        onApply: { stash in Task { await manager.applyStash(stash) } },
                        onPop: { stash in Task { await manager.popStash(stash) } },
                        onDrop: { stash in confirmation = .dropStash(stash) }
                    )
                }
                if manager.changes.isEmpty {
                    Label("No changes", systemImage: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.secondaryTextColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func changeGroup(
        _ changes: [GitChange],
        group: GitChangeGroup,
        title: String,
        isConflictGroup: Bool = false
    ) -> some View {
        let protected = protectedPaths
        return GitChangesGroupView(
            changes: changes,
            group: group,
            title: title,
            isConflictGroup: isConflictGroup,
            treeMode: treeMode,
            isBusy: isWorking,
            stageAllBlocked: !isConflictGroup && group == .unstaged && !protected.isEmpty,
            canStage: { change in
                let changePaths = Self.paths(of: change)
                if isConflictGroup { return protected.isDisjoint(with: changePaths) }
                return group == .staged || protected.isDisjoint(with: changePaths)
            },
            canDiscard: { change in canDiscard(change, protected: protected) },
            canAcceptVersions: canChangeWorkingTree,
            onStageAll: {
                if group == .staged { Task { await manager.unstageAll() } } else { requestStageAll() }
            },
            onDiff: { change in
                if let root = manager.repositoryRoot { diffRequest = GitDiffRequest(change: change, group: group, repository: root) }
            },
            onOpen: openFile,
            onStage: { change in
                if isConflictGroup || change.isConflicted {
                    confirmation = .markResolved(change)
                } else if group == .staged {
                    Task { await manager.unstage(change) }
                } else {
                    Task { await manager.stage(change) }
                }
            },
            onDiscard: { change in confirmation = .discard(change) },
            onDiscardAll: isConflictGroup || group == .staged ? nil : { confirmation = .discardAll },
            onAcceptCurrent: { change in confirmation = .acceptCurrent(change) },
            onAcceptIncoming: { change in confirmation = .acceptIncoming(change) },
            onMarkResolved: { change in confirmation = .markResolved(change) }
        )
    }

    private static func paths(of change: GitChange) -> [String] {
        [change.path, change.originalPath].compactMap { $0 }
    }

    private func requestStageAll() {
        if hasConflicts {
            confirmation = .stageAllWithConflicts
        } else {
            Task { await manager.stageAll() }
        }
    }

    private func openFile(_ change: GitChange) {
        guard let root = manager.repositoryRoot else { return }
        let url = root.appendingPathComponent(change.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            manager.errorMessage = "'\(change.path)' does not exist in the working tree."
            return
        }
        guard !isDirectory.boolValue else {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            return
        }
        selectedFile = url
    }

    /// Untracked files move to the Trash; tracked files return to their
    /// staged version. Conflicted files need the merge actions instead.
    private func canDiscard(_ change: GitChange, protected: Set<String>) -> Bool {
        guard !isWorking, !change.isConflicted else { return false }
        return protected.isDisjoint(with: Self.paths(of: change))
    }

    // MARK: Commit

    private var commitHint: String? {
        if !protectedPaths.isEmpty { return "Save the open file before you stage or commit it." }
        if hasConflicts { return "Resolve merge conflicts before you commit." }
        return nil
    }

    private var commitHelp: String {
        if !protectedPaths.isEmpty { return "Save the open file first. Commits use saved files only." }
        if hasConflicts { return "Resolve the merge conflicts first." }
        if staged.isEmpty { return "Stage changes to commit them" }
        if !hasMessage { return "Enter a commit message" }
        return "Commit staged changes only"
    }

    private func commit(amend: Bool, then post: GitPostCommitAction = .none) {
        guard amend ? canAmend : canCommit else { return }
        let submitted = message
        Task {
            var text = submitted
            if amend && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Prefill the message box from HEAD so a message-only amend
                // keeps the original message.
                text = await manager.headCommitMessage() ?? ""
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // `.id(root)` recreates this view for another project, so only
            // the message text needs a check before it is cleared.
            if await manager.commit(message: text, amend: amend) {
                if message == submitted { message = "" }
                switch post {
                case .none: break
                case .push: await manager.push()
                case .sync: await manager.sync(mode: .fastForwardOnly)
                }
            }
        }
    }

    private func undoLastCommit() {
        guard canUndoLastCommit else { return }
        Task {
            if let oldMessage = await manager.undoLastCommit(),
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = oldMessage
            }
        }
    }

    // MARK: In-progress operations

    private func continueOperation() {
        guard manager.operationState != .none, !hasConflicts, !manager.isBusy else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await manager.continueOperation(message: text.isEmpty ? nil : text), !text.isEmpty {
                message = ""
            }
        }
    }

    /// Prefills the message box with the pending merge message (MERGE_MSG)
    /// so "Continue" commits what Git already prepared.
    private func prefillPendingMergeMessage() {
        guard message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if let pending = await manager.pendingOperationMessage(),
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               manager.operationState == .merging {
                message = pending
            }
        }
    }

    // MARK: Remote

    private func pull(_ mode: GitPullMode) {
        guard canChangeWorkingTree, manager.hasRemote else { return }
        Task { await manager.pull(mode: mode) }
    }

    private func sync(_ mode: GitPullMode) {
        guard canChangeWorkingTree, manager.hasRemote else { return }
        Task { await manager.sync(mode: mode) }
    }

    private func push() {
        guard manager.hasRemote, manager.hasCommits, !manager.isDetachedHead, !manager.isBusy else { return }
        Task { await manager.push() }
    }

    // MARK: Branches and tags

    private func checkoutBranch(_ name: String) {
        guard canChangeWorkingTree else { return }
        Task { await manager.checkout(branch: name) }
    }

    private func checkoutRemote(_ name: String) {
        guard canChangeWorkingTree else { return }
        Task { await manager.checkoutRemoteBranch(name) }
    }

    @ViewBuilder
    private func nameSheetContent(_ kind: GitNameSheetKind) -> some View {
        switch kind {
        case .createBranch(let at):
            // Creating a branch switches to it, which rewrites the tree.
            if canChangeWorkingTree {
                GitNameSheet(kind: kind, existingNames: manager.branches.map(\.name)) { name, _ in
                    Task { await manager.createBranch(name: name, at: at) }
                }
            }
        case .renameBranch(let current):
            GitNameSheet(kind: kind, existingNames: manager.branches.map(\.name)) { name, _ in
                Task { await manager.renameBranch(current, to: name) }
            }
        case .createTag:
            GitNameSheet(kind: kind, existingNames: manager.tags) { name, tagMessage in
                let message = tagMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await manager.createTag(name: name, message: (message?.isEmpty == true) ? nil : message, at: atCommit(kind))
                }
            }
        }
    }

    private func atCommit(_ kind: GitNameSheetKind) -> String? {
        switch kind {
        case .createBranch(let at), .createTag(let at): return at
        case .renameBranch: return nil
        }
    }

    // MARK: Graph actions

    private var graphActions: GitGraphRowActions {
        GitGraphRowActions(
            isBusy: isWorking,
            canChangeWorkingTree: canChangeWorkingTree,
            hasOperation: manager.operationState != .none,
            onReword: { commit in rewordRequest = GitRewordRequest(commit: commit) },
            onUndo: { commit in undoCommit(commit) },
            onCheckoutDetached: { commit in confirmation = .checkoutDetached(commit) },
            onCreateBranchHere: { commit in nameSheet = .createBranch(atCommit: commit.id) },
            onCreateTagHere: { commit in nameSheet = .createTag(atCommit: commit.id) },
            onCherryPick: cherryPick,
            onRevert: { commit in confirmation = .revert(commit) }
        )
    }

    private func undoCommit(_ commit: GitCommit) {
        guard commit.isHead, commit.isUnpushed, manager.operationState == .none else { return }
        Task {
            if let oldMessage = await manager.undoLastCommit(),
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = oldMessage
            }
        }
    }

    private func cherryPick(_ commit: GitCommit) {
        guard canChangeWorkingTree, manager.operationState == .none else { return }
        Task { await manager.cherryPick(commit.id) }
    }

    private func rewordCommit(_ commit: GitCommit, message newText: String) {
        guard commit.isUnpushed, manager.operationState == .none else { return }
        Task { _ = await manager.rewordCommit(commit.id, message: newText) }
    }

    // MARK: Graph header

    private var graphHeader: some View {
        HStack(spacing: 10) {
            Button { graphExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: graphExpanded ? "chevron.down" : "chevron.right")
                    Text("Graph").fontWeight(.semibold)
                }
                .foregroundColor(themeManager.textColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(graphExpanded ? "Collapse" : "Expand") commit graph")
            Spacer(minLength: 0)
            if manager.unpushedCount > 0 {
                Text("↑\(manager.unpushedCount) to push")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.secondaryTextColor)
                    .help("\(manager.unpushedCount) commits exist only in this repository")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Other states

    private var emptyRepository: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This project is not in a Git repository.")
                .font(.system(size: 12))
                .foregroundColor(themeManager.secondaryTextColor)
            Button("Initialize Repository") { Task { await manager.initializeRepository() } }
                .buttonStyle(.bordered)
                .disabled(manager.isBusy || isLoading)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
            ScrollView {
                Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 48)
            Button { manager.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Dismiss Git Error")
                .accessibilityLabel("Dismiss Git Error")
        }
        .font(.system(size: 11))
        .padding(8)
        .background(Color.orange.opacity(0.08))
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(themeManager.secondaryTextColor.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityLabel("\(count) changed files")
    }

    // MARK: Confirmations

    private func confirmationAlert(_ item: GitConfirmation) -> Alert {
        switch item {
        case .discard(let change):
            if change.isUntracked {
                return Alert(
                    title: Text("Move new file to the Trash?"),
                    message: Text("“\(change.path)” is not in the repository yet. It moves to the Trash, so you can restore it there."),
                    primaryButton: .destructive(Text("Move to Trash")) { performDiscard(change) },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text("Discard changes?"),
                message: Text("Discard the saved, unstaged changes to \(change.path)? You cannot undo this. Staged changes stay."),
                primaryButton: .destructive(Text("Discard")) { performDiscard(change) },
                secondaryButton: .cancel()
            )
        case .discardAll:
            return Alert(
                title: Text("Discard all changes?"),
                message: Text("Discard all unstaged changes? Modified files return to their staged versions and new files move to the Trash. Staged changes stay."),
                primaryButton: .destructive(Text("Discard All")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.discardAllChanges() }
                },
                secondaryButton: .cancel()
            )
        case .stageAllWithConflicts:
            return Alert(
                title: Text("Stage files with conflicts?"),
                message: Text("Staging all changes also marks every merge conflict as resolved. Remove all conflict markers first."),
                primaryButton: .default(Text("Stage All")) { Task { await manager.stageAll() } },
                secondaryButton: .cancel()
            )
        case .acceptCurrent(let change):
            return Alert(
                title: Text("Accept current version?"),
                message: Text("Replaces the conflicted file \(change.path) with this branch's version and stages it. Your edits in the other version are lost."),
                primaryButton: .default(Text("Accept Current")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.acceptCurrent(change) }
                },
                secondaryButton: .cancel()
            )
        case .acceptIncoming(let change):
            return Alert(
                title: Text("Accept incoming version?"),
                message: Text("Replaces the conflicted file \(change.path) with the incoming version and stages it. Your current edits are lost."),
                primaryButton: .default(Text("Accept Incoming")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.acceptIncoming(change) }
                },
                secondaryButton: .cancel()
            )
        case .markResolved(let change):
            return Alert(
                title: Text("Mark conflict as resolved?"),
                message: Text("Staging \(change.path) marks its merge conflict as resolved. Remove all conflict markers first."),
                primaryButton: .default(Text("Stage")) {
                    // State can change while the alert is open; check again.
                    guard !isWorking, protectedPaths.isDisjoint(with: Self.paths(of: change)) else { return }
                    Task { await manager.markResolved(change) }
                },
                secondaryButton: .cancel()
            )
        case .checkoutDetached(let commit):
            return Alert(
                title: Text("Check out commit?"),
                message: Text("HEAD detaches at \(commit.shortHash) “\(commit.subject)”. Create a branch here to keep new commits."),
                primaryButton: .default(Text("Check Out")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.checkoutDetached(commit.id) }
                },
                secondaryButton: .cancel()
            )
        case .deleteBranch(let branch, let force):
            return Alert(
                title: Text(force ? "Force delete branch?" : "Delete branch?"),
                message: Text(force
                              ? "“\(branch.name)” is not fully merged. Force delete removes it permanently; its commits may become unreachable."
                              : "Delete branch “\(branch.name)”?"),
                primaryButton: .destructive(Text(force ? "Force Delete" : "Delete")) {
                    Task { await manager.deleteBranch(branch.name, force: force) }
                },
                secondaryButton: .cancel()
            )
        case .deleteTag(let tag):
            return Alert(
                title: Text("Delete tag?"),
                message: Text("Delete tag “\(tag)” from this repository?"),
                primaryButton: .destructive(Text("Delete")) { Task { await manager.deleteTag(tag) } },
                secondaryButton: .cancel()
            )
        case .mergeBranch(let name):
            return Alert(
                title: Text("Merge branch?"),
                message: Text("Merge “\(name)” into “\(currentBranchLabel)”? Conflicts pause the merge so you can resolve them."),
                primaryButton: .default(Text("Merge")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.mergeBranch(name) }
                },
                secondaryButton: .cancel()
            )
        case .rebaseOnto(let name):
            return Alert(
                title: Text("Rebase branch?"),
                message: Text("Replay “\(currentBranchLabel)” on top of “\(name)”? Conflicts pause the rebase so you can resolve them."),
                primaryButton: .default(Text("Rebase")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.rebaseCurrentBranch(onto: name) }
                },
                secondaryButton: .cancel()
            )
        case .revert(let commit):
            return Alert(
                title: Text("Revert commit?"),
                message: Text("Create a new commit that undoes \(commit.shortHash) “\(commit.subject)”? Conflicts pause the revert so you can resolve them."),
                primaryButton: .default(Text("Revert")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.revertCommit(commit.id) }
                },
                secondaryButton: .cancel()
            )
        case .abortOperation:
            let name = manager.operationState.displayName
            return Alert(
                title: Text("Abort \(name)?"),
                message: Text("The repository returns to the state before the \(name.lowercased()) started. Uncommitted changes are kept."),
                primaryButton: .destructive(Text("Abort")) {
                    guard canChangeWorkingTree else { return }
                    Task { await manager.abortOperation() }
                },
                secondaryButton: .cancel()
            )
        case .dropStash(let stash):
            return Alert(
                title: Text("Drop stash?"),
                message: Text("Delete \(stash.id) permanently? Files on disk are not affected."),
                primaryButton: .destructive(Text("Drop")) { Task { await manager.dropStash(stash) } },
                secondaryButton: .cancel()
            )
        }
    }

    private func performDiscard(_ change: GitChange) {
        // State can change while the alert is open; examine it again.
        guard canDiscard(change, protected: protectedPaths) else { return }
        // The manager posts `.gitWorkingTreeDidChange` after the discard, so
        // every window with the file open reloads it at once (clean buffers
        // only — no edits can be lost).
        Task { await manager.discard(change) }
    }
}
