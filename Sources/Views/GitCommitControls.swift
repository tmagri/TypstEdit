import SwiftUI

extension GitOperationState {
    /// User-facing name, e.g. "Merge" for the operation banner.
    var displayName: String {
        switch self {
        case .none: return ""
        case .merging: return "Merge"
        case .rebasing: return "Rebase"
        case .cherryPicking: return "Cherry-pick"
        case .reverting: return "Revert"
        }
    }
}

/// The commit message box and the split Commit button: the primary action
/// commits staged changes; the dropdown offers amend, push, sync and undo.
struct GitCommitControls: View {
    @Binding var message: String
    /// The focus state lives in the sidebar so ⌘Enter only fires while the
    /// message field is focused.
    let messageFocus: FocusState<Bool>.Binding
    let isBusy: Bool
    let canCommit: Bool
    let canAmend: Bool
    let canUndoLastCommit: Bool
    let canPush: Bool
    /// False while the branch is both ahead of and behind its upstream: a
    /// fast-forward-only sync would always fail then.
    let canCommitAndSync: Bool
    let hint: String?
    let help: String
    let onCommit: () -> Void
    let onCommitAmend: () -> Void
    let onCommitAndPush: () -> Void
    let onCommitAndSync: () -> Void
    let onUndoLastCommit: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 6) {
            TextField("Message (⌘Enter to commit)", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
                .padding(6)
                .background(themeManager.searchFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(themeManager.secondaryTextColor.opacity(0.25)))
                .focused(messageFocus)
                .accessibilityLabel("Commit message")
            commitMenu
                .opacity(canCommit ? 1 : 0.55)
            if let hint {
                Label(hint, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A split button: clicking the label commits; the chevron opens the
    /// dropdown with the remaining commit actions.
    private var commitMenu: some View {
        Menu {
            Button("Commit") { onCommit() }
                .disabled(!canCommit)
            Button("Commit (Amend)") { onCommitAmend() }
                .disabled(!canAmend)
            Button("Commit & Push") { onCommitAndPush() }
                .disabled(!canCommit || !canPush)
            Button("Commit & Sync") { onCommitAndSync() }
                .disabled(!canCommit || !canPush || !canCommitAndSync)
                .help(canCommitAndSync ? "" : "Branch has diverged — use Pull (Merge) or Pull (Rebase)")
            Divider()
            Button("Undo Last Commit") { onUndoLastCommit() }
                .disabled(!canUndoLastCommit)
        } label: {
            HStack(spacing: 4) {
                Label("Commit", systemImage: "checkmark")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
        } primaryAction: {
            onCommit()
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)
        .disabled(isBusy)
        .help(help)
        .accessibilityLabel("Commit staged changes")
        .accessibilityHint("Open the dropdown for amend, push, sync and undo")
        .background {
            // The shortcut exists only while the message field has focus, so
            // it cannot take ⌘Enter from the editor or the insert sheets.
            if messageFocus.wrappedValue {
                Button("Commit Staged", action: onCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCommit)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Banner shown while a merge, rebase, cherry-pick or revert is in progress.
/// "Continue" finishes it (a merge commits the message box); "Abort" asks
/// for confirmation in the sidebar first.
struct GitOperationBanner: View {
    let state: GitOperationState
    let hasConflicts: Bool
    let isBusy: Bool
    /// False while an open file has unsaved edits: continuing would rewrite
    /// the working tree and the next save would restore them.
    let canContinue: Bool
    let onAbort: () -> Void
    let onContinue: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(.orange)
                Text("\(state.displayName) in progress")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Button("Continue") { onContinue() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || hasConflicts || !canContinue)
                    .help(continueHelp)
                    .accessibilityLabel("Continue \(state.displayName)")
                Button("Abort…") { onAbort() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                    .accessibilityLabel("Abort \(state.displayName)")
            }
            if hasConflicts {
                Text("Resolve the conflicts below, then continue.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    private var continueHelp: String {
        if !canContinue { return "Save the open file first" }
        if hasConflicts { return "Resolve the conflicts first" }
        return "Continue the \(state.displayName.lowercased())"
    }
}
