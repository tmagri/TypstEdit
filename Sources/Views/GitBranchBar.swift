import SwiftUI

/// The branch bar: the branch dropdown menu plus the sync/publish button.
/// The bar shows the current network operation with a Cancel button while
/// one is running.
struct GitBranchBar: View {
    @ObservedObject var manager: SourceControlManager
    /// False while the open file has unsaved edits: ops that rewrite the
    /// working tree are disabled then.
    let canChangeWorkingTree: Bool
    let onCheckout: (String) -> Void
    let onCheckoutRemote: (String) -> Void
    let onCreateBranch: () -> Void
    let onRenameBranch: () -> Void
    let onRequestDeleteBranch: (GitBranch, Bool) -> Void
    let onRequestMerge: (String) -> Void
    let onRequestRebase: (String) -> Void
    let onCreateTag: () -> Void
    let onRequestDeleteTag: (String) -> Void
    let onPull: (GitPullMode) -> Void
    let onSync: (GitPullMode) -> Void
    let onFetch: () -> Void
    let onPush: () -> Void
    let onCancelOperation: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    private var otherLocalBranches: [GitBranch] { manager.branches.filter { !$0.isCurrent } }
    private var mergeTargets: [GitBranch] { otherLocalBranches + manager.remoteBranches }
    private var hasOperation: Bool { manager.operationState != .none }
    /// False when a fast-forward-only pull/sync cannot succeed (ahead and
    /// behind at the same time).
    private var canFastForwardSync: Bool { !manager.hasDiverged }
    private var canPull: Bool {
        manager.hasRemote && manager.upstreamBranch != nil && !manager.isBusy && canChangeWorkingTree
    }
    private var canPush: Bool {
        manager.hasRemote && manager.hasCommits && !manager.isDetachedHead && !manager.isBusy
    }
    private var needsPublish: Bool {
        manager.hasRemote && manager.upstreamBranch == nil
            && !manager.isDetachedHead && manager.hasCommits
    }
    private var detachedLabel: String {
        manager.commits.first(where: \.isHead).map { "Detached at \($0.shortHash)" } ?? "Detached HEAD"
    }

    var body: some View {
        HStack(spacing: 4) {
            branchMenu
            if manager.isDetachedHead {
                Button("Create Branch…", action: onCreateBranch)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .fixedSize()
                    .disabled(!canChangeWorkingTree)
                    .help("HEAD is detached. Create a branch to keep new commits.")
            }
            Spacer(minLength: 0)
            if let operation = manager.currentOperation {
                operationIndicator(operation)
            } else if manager.hasRemote {
                syncButton
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: Branch menu

    private var branchMenu: some View {
        Menu {
            if manager.isDetachedHead {
                Button("Create Branch…") { onCreateBranch() }
                    .disabled(!canChangeWorkingTree)
            } else {
                ForEach(manager.branches) { branch in
                    Button(branch.name) { onCheckout(branch.name) }
                        .disabled(branch.isCurrent || !canChangeWorkingTree)
                }
                if !manager.remoteBranches.isEmpty {
                    Menu("Remote Branches") {
                        ForEach(manager.remoteBranches) { remote in
                            Button(GitRefName.shortName(ofRemoteBranch: remote.name)) {
                                onCheckoutRemote(remote.name)
                            }
                            .disabled(!canChangeWorkingTree)
                        }
                    }
                }
                Divider()
            }
            Button("Create Branch…") { onCreateBranch() }
                .disabled(!canChangeWorkingTree)
            Button("Rename Current Branch…") { onRenameBranch() }
                .disabled(manager.isDetachedHead || manager.branch.isEmpty || manager.isBusy)
            if !otherLocalBranches.isEmpty {
                Menu("Delete Branch…") {
                    ForEach(otherLocalBranches) { branch in
                        Menu(branch.name) {
                            Button("Delete", role: .destructive) { onRequestDeleteBranch(branch, false) }
                            Button("Force Delete (Unmerged)", role: .destructive) {
                                onRequestDeleteBranch(branch, true)
                            }
                        }
                    }
                }
            }
            if !mergeTargets.isEmpty {
                Menu("Merge Branch into Current…") {
                    ForEach(mergeTargets) { target in
                        Button(target.name) { onRequestMerge(target.name) }
                            .disabled(!canChangeWorkingTree || hasOperation)
                    }
                }
                .disabled(hasOperation)
                Menu("Rebase Current Branch onto…") {
                    ForEach(mergeTargets) { target in
                        Button(target.name) { onRequestRebase(target.name) }
                            .disabled(!canChangeWorkingTree || hasOperation)
                    }
                }
                .disabled(hasOperation)
            }
            Divider()
            tagsMenu
        } label: {
            Label(manager.isDetachedHead ? detachedLabel : manager.branch, systemImage: "arrow.triangle.branch")
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(manager.isDetachedHead
              ? "HEAD is detached. Create a branch to keep new commits."
              : (canChangeWorkingTree ? "Switch Branch" : "Save the open file before you switch branches"))
        .accessibilityLabel("Branch: \(manager.isDetachedHead ? "detached HEAD" : manager.branch)")
    }

    private var tagsMenu: some View {
        Menu("Tags") {
            Button("Create Tag…") { onCreateTag() }
            if !manager.tags.isEmpty {
                Divider()
                ForEach(manager.tags, id: \.self) { tag in
                    Button("Delete \(tag)…", role: .destructive) { onRequestDeleteTag(tag) }
                }
            }
        }
    }

    // MARK: Sync

    /// A split button: clicking synchronizes (or publishes); the dropdown
    /// offers pull modes, fetch and push.
    private var syncButton: some View {
        Menu {
            Menu("Pull") {
                Button("Fast-forward Only") { onPull(.fastForwardOnly) }
                    .disabled(!canPull || !canFastForwardSync)
                    .help(canFastForwardSync ? "" : "Branch has diverged — use Pull (Merge) or Pull (Rebase)")
                Button("Merge") { onPull(.merge) }.disabled(!canPull)
                Button("Rebase") { onPull(.rebase) }.disabled(!canPull)
            }
            Button("Fetch") { onFetch() }
                .disabled(manager.isBusy)
            Button("Push") { onPush() }
                .disabled(!canPush)
                .help(manager.isDetachedHead
                      ? "Push is disabled while HEAD is detached."
                      : (manager.hasCommits ? "" : "Create a commit before pushing."))
        } label: {
            HStack(spacing: 4) {
                if needsPublish {
                    Image(systemName: "cloudUpload")
                    Text("Publish Branch")
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    if let counts = GitSyncBadge.label(ahead: manager.ahead, behind: manager.behind) {
                        Text(counts)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
            .font(.system(size: 11))
        } primaryAction: {
            if needsPublish {
                onPush()
            } else if canFastForwardSync {
                onSync(.fastForwardOnly)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(manager.isBusy)
        .help(syncHelp)
        .accessibilityLabel("Synchronize")
    }

    private var syncHelp: String {
        if needsPublish { return "Publish the current branch to its remote" }
        if !canFastForwardSync { return "Branch has diverged — use Pull (Merge) or Pull (Rebase)" }
        if !canChangeWorkingTree { return "Save the open file before you synchronize" }
        return "Synchronize: pull, then push"
    }

    private func operationIndicator(_ label: String) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
                .frame(width: 14, height: 14)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(themeManager.secondaryTextColor)
                .lineLimit(1)
            Button {
                onCancelOperation()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Cancel \(label)")
            .accessibilityLabel("Cancel \(label)")
        }
    }
}
