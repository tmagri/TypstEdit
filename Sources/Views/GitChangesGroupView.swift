import SwiftUI

/// Callbacks shared by every row in one change group.
private struct GitChangeActions {
    let group: GitChangeGroup
    /// True for the dedicated "Merge Changes" group of conflicted files.
    let isConflictGroup: Bool
    let isBusy: Bool
    let canStage: (GitChange) -> Bool
    let canDiscard: (GitChange) -> Bool
    /// False while the open file has unsaved edits: accepting a version
    /// overwrites the file on disk.
    let canAcceptVersions: Bool
    /// False when the file is not in the working tree (e.g. it was deleted).
    let canOpenExternal: (GitChange) -> Bool
    let onDiff: (GitChange) -> Void
    let onOpen: (GitChange) -> Void
    let onOpenExternal: (GitChange) -> Void
    let onStage: (GitChange) -> Void
    let onDiscard: (GitChange) -> Void
    let canIgnore: (GitChange) -> Bool
    let onIgnore: (GitChange) -> Void
    let onIgnoreFolder: (String) -> Void
    let onAcceptCurrent: (GitChange) -> Void
    let onAcceptIncoming: (GitChange) -> Void
    let onMarkResolved: (GitChange) -> Void
}

struct GitChangesGroupView: View {
    let changes: [GitChange]
    let group: GitChangeGroup
    let title: String
    var isConflictGroup = false
    let treeMode: Bool
    let isBusy: Bool
    let stageAllBlocked: Bool
    let canStage: (GitChange) -> Bool
    let canDiscard: (GitChange) -> Bool
    let canAcceptVersions: Bool
    let canOpenExternal: (GitChange) -> Bool
    let onStageAll: () -> Void
    let onDiff: (GitChange) -> Void
    let onOpen: (GitChange) -> Void
    let onOpenExternal: (GitChange) -> Void
    let onStage: (GitChange) -> Void
    let onDiscard: (GitChange) -> Void
    let canIgnore: (GitChange) -> Bool
    let onIgnore: (GitChange) -> Void
    let onIgnoreFolder: (String) -> Void
    var onDiscardAll: (() -> Void)? = nil
    let onAcceptCurrent: (GitChange) -> Void
    let onAcceptIncoming: (GitChange) -> Void
    let onMarkResolved: (GitChange) -> Void
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var isExpanded = true

    private var actions: GitChangeActions {
        GitChangeActions(
            group: group, isConflictGroup: isConflictGroup, isBusy: isBusy,
            canStage: canStage, canDiscard: canDiscard, canAcceptVersions: canAcceptVersions,
            canOpenExternal: canOpenExternal,
            onDiff: onDiff, onOpen: onOpen, onOpenExternal: onOpenExternal, onStage: onStage, onDiscard: onDiscard,
            canIgnore: canIgnore, onIgnore: onIgnore, onIgnoreFolder: onIgnoreFolder,
            onAcceptCurrent: onAcceptCurrent, onAcceptIncoming: onAcceptIncoming, onMarkResolved: onMarkResolved
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if treeMode {
                    ForEach(GitChangeTreeNode.build(from: changes)) { node in
                        GitChangeTreeRowView(node: node, depth: 0, actions: actions)
                    }
                } else {
                    ForEach(changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) { change in
                        GitChangeRowView(change: change, depth: 0, showFullPath: true, actions: actions)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(title).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(themeManager.textColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(title)")
            Spacer(minLength: 0)
            Text("\(changes.count)")
                .font(.system(size: 10))
                .foregroundColor(themeManager.secondaryTextColor)
            if !isConflictGroup {
                Button(action: onStageAll) {
                    Image(systemName: group == .staged ? "minus" : "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(isBusy || stageAllBlocked)
                .help(stageAllBlocked ? "Save the open file before you stage all changes"
                      : (group == .staged ? "Unstage All Changes" : "Stage All Changes"))
                .accessibilityLabel(group == .staged ? "Unstage all changes" : "Stage all changes")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contextMenu {
            if let onDiscardAll {
                Button("Discard All Changes…", role: .destructive) { onDiscardAll() }
                    .disabled(isBusy || changes.isEmpty)
            }
        }
    }
}

private struct GitChangeTreeRowView: View {
    let node: GitChangeTreeNode
    let depth: Int
    let actions: GitChangeActions
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let change = node.change {
                GitChangeRowView(change: change, depth: depth, showFullPath: false, actions: actions)
            } else {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .frame(width: 8)
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .foregroundColor(.blue)
                        Text(node.name)
                            .foregroundColor(themeManager.textColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .padding(.leading, CGFloat(depth) * 12 + 12)
                    .padding(.trailing, 12)
                    .frame(height: 23)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.path)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") folder \(node.path)")
                .contextMenu {
                    Button(isExpanded ? "Collapse Folder" : "Expand Folder") { isExpanded.toggle() }
                    Divider()
                    Button("Add Folder to .gitignore…") { actions.onIgnoreFolder(node.path) }
                        .disabled(actions.isBusy)
                        .help("Stop versioning everything under \(node.path)")
                }
                if isExpanded {
                    ForEach(node.children) { child in
                        GitChangeTreeRowView(node: child, depth: depth + 1, actions: actions)
                    }
                }
            }
        }
    }
}

private struct GitChangeRowView: View {
    let change: GitChange
    let depth: Int
    let showFullPath: Bool
    let actions: GitChangeActions
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var hovering = false

    private var group: GitChangeGroup { actions.group }
    private var isConflictRow: Bool { actions.isConflictGroup }
    private var canStage: Bool { !actions.isBusy && actions.canStage(change) }

    private var status: String {
        if change.isConflicted { return "!" }
        if change.isUntracked { return "U" }
        let letter = change.statusLetter(for: group)
        return letter.isEmpty ? "M" : letter
    }
    private var statusDescription: String {
        switch status {
        case "!": return "Merge conflict"
        case "U", "?": return "Untracked"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        default: return "Modified"
        }
    }
    private var statusColor: Color {
        switch status {
        case "A", "U", "?": return .green
        case "D", "!": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }
    private var stageLabel: String {
        if isConflictRow { return "Mark as Resolved and Stage…" }
        if group == .staged { return "Unstage Changes" }
        return change.isConflicted ? "Mark as Resolved and Stage…" : "Stage Changes"
    }
    private var discardLabel: String {
        change.isUntracked ? "Delete File (Move to Trash)…" : "Discard Changes…"
    }

    var body: some View {
        HStack(spacing: 5) {
            Button { actions.onDiff(change) } label: {
                HStack(spacing: 5) {
                    Image(systemName: change.isConflicted ? "exclamationmark.triangle" : "doc.text")
                        .foregroundColor(statusColor)
                    Text(showFullPath ? change.path : (change.path as NSString).lastPathComponent)
                        .foregroundColor(themeManager.textColor)
                        .strikethrough(status == "D")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(actions.isBusy)
            .help("\(change.path) — \(statusDescription)\(change.originalPath.map { "\nRenamed from \($0)" } ?? "")\nClick to view changes")
            .accessibilityLabel("View \(group == .staged ? "staged" : "unstaged") changes for \(change.path), \(statusDescription)")
            Button { actions.onOpen(change) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityHidden(true) // The context menu has "Open File".
                .help("Open File")
            Button { actions.onStage(change) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .disabled(!canStage)
                .help(actions.canStage(change) ? stageLabel : "Save the open file before you stage it")
                .accessibilityLabel("\(stageLabel) \(change.path)")
            Text(status)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(minWidth: 12)
                .fixedSize()
                .help(statusDescription)
                .accessibilityHidden(true)
        }
        .font(.system(size: 11))
        .padding(.leading, CGFloat(depth) * 12 + 25)
        .padding(.trailing, 12)
        .frame(height: 23)
        .background(hovering ? themeManager.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu { rowMenu }
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button("View Changes") { actions.onDiff(change) }.disabled(actions.isBusy)
        Button("Open File") { actions.onOpen(change) }
        Button("Open in External Program") { actions.onOpenExternal(change) }
            .disabled(!actions.canOpenExternal(change))
            .help(actions.canOpenExternal(change)
                  ? "Open the file on disk with your default application"
                  : "The file does not exist in the working tree")
        Divider()
        Button("Add to .gitignore…") { actions.onIgnore(change) }
            .disabled(actions.isBusy || !actions.canIgnore(change))
            .help(actions.canIgnore(change)
                  ? "Ignore \(change.path) and stop tracking it if it is already committed"
                  : "Resolve the merge conflict first")
        if isConflictRow {
            Divider()
            Button("Accept Current…") { actions.onAcceptCurrent(change) }
                .disabled(actions.isBusy || !actions.canAcceptVersions)
                .help(actions.canAcceptVersions ? "Keep this branch's version of the file" : "Save the open file first.")
            Button("Accept Incoming…") { actions.onAcceptIncoming(change) }
                .disabled(actions.isBusy || !actions.canAcceptVersions)
                .help(actions.canAcceptVersions ? "Keep the incoming version of the file" : "Save the open file first.")
            Button("Mark as Resolved…") { actions.onMarkResolved(change) }
                .disabled(!canStage)
        } else {
            Button(stageLabel) { actions.onStage(change) }.disabled(!canStage)
            if group == .unstaged && !change.isConflicted {
                Divider()
                Button(discardLabel, role: .destructive) { actions.onDiscard(change) }
                    .disabled(!actions.canDiscard(change))
                    .help(change.isUntracked ? "Moves the file to the Trash." : "Restores the file's staged version.")
            }
        }
    }
}
