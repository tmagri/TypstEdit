import SwiftUI
import AppKit

/// Actions available from one graph row, pre-resolved by the sidebar.
struct GitGraphRowActions {
    let isBusy: Bool
    let canChangeWorkingTree: Bool
    let hasOperation: Bool
    let onReword: (GitCommit) -> Void
    let onUndo: (GitCommit) -> Void
    let onCheckoutDetached: (GitCommit) -> Void
    let onCreateBranchHere: (GitCommit) -> Void
    let onCreateTagHere: (GitCommit) -> Void
    let onCherryPick: (GitCommit) -> Void
    let onRevert: (GitCommit) -> Void
}

/// The scrolling commit history with lanes. Unpushed commits draw a hollow
/// dot (with a "Not pushed" tooltip); HEAD gets a ring around its dot.
struct GitGraphView: View {
    @ObservedObject var manager: SourceControlManager
    let actions: GitGraphRowActions
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        ScrollView {
            if manager.commits.isEmpty {
                Text("No commits yet")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.secondaryTextColor)
                    .padding(10)
            } else {
                let rows = GitGraphRow.build(from: manager.commits)
                let laneCount = max(1, rows.map(\.laneCount).max() ?? 1)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        GitCommitGraphRowView(row: row, laneCount: laneCount, actions: actions)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }
}

struct GitCommitGraphRowView: View {
    let row: GitGraphRow
    let laneCount: Int
    let actions: GitGraphRowActions
    @EnvironmentObject private var themeManager: ThemeManager
    private let laneWidth: CGFloat = 10
    private static let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]

    private var mark: GitGraphDotMark {
        GitGraphDotMark.mark(isHead: row.commit.isHead, isUnpushed: row.commit.isUnpushed)
    }
    private var canReword: Bool { row.commit.isUnpushed && !actions.hasOperation && !actions.isBusy }
    private var canUndo: Bool {
        row.commit.isHead && row.commit.isUnpushed && !actions.hasOperation && !actions.isBusy
    }

    var body: some View {
        HStack(spacing: 5) {
            lanes
                .frame(width: CGFloat(min(laneCount, 8)) * laneWidth + 4, height: 23)
                .clipped()
                .accessibilityHidden(true)
            Text(row.commit.subject)
                .font(.system(size: 11))
                .foregroundColor(themeManager.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !row.commit.refs.isEmpty {
                Text(row.commit.refs)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(themeManager.textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(themeManager.accentColor.opacity(0.2))
                    .clipShape(Capsule())
                    .frame(maxWidth: 90)
            }
        }
        .frame(height: 23)
        .contentShape(Rectangle())
        .help(tooltip)
        .contextMenu { rowContextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var lanes: some View {
        Canvas { context, size in
            let originX: CGFloat = 2
            for segment in row.segments {
                let start = CGPoint(x: originX + CGFloat(segment.startLane) * laneWidth + 5, y: segment.startY * size.height)
                let end = CGPoint(x: originX + CGFloat(segment.endLane) * laneWidth + 5, y: segment.endY * size.height)
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let middle = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
                }
                context.stroke(path, with: .color(Self.colors[segment.colorLane % Self.colors.count]), lineWidth: 1.3)
            }
            let center = CGPoint(x: originX + CGFloat(row.lane) * laneWidth + 5, y: size.height / 2)
            let laneColor = Self.colors[row.lane % Self.colors.count]
            let dot = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            if mark.isHollow {
                context.stroke(Path(ellipseIn: dot), with: .color(laneColor), lineWidth: 1.5)
            } else {
                context.fill(Path(ellipseIn: dot), with: .color(laneColor))
            }
            if mark.hasHeadRing {
                let ring = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
                context.stroke(Path(ellipseIn: ring), with: .color(themeManager.textColor.opacity(0.8)), lineWidth: 1)
            }
        }
    }

    private var tooltip: String {
        var text = "\(row.commit.shortHash) · \(row.commit.author) · \(row.commit.date.formatted())\n\(row.commit.subject)"
        if !row.commit.refs.isEmpty { text += "\n\(row.commit.refs)" }
        if row.commit.isUnpushed { text += "\nNot pushed" }
        return text
    }

    private var accessibilityText: String {
        "Commit \(row.commit.shortHash): \(row.commit.subject)\(row.commit.refs.isEmpty ? "" : ", \(row.commit.refs)"), by \(row.commit.author)\(row.commit.isUnpushed ? ", not pushed" : "")"
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button("Reword Message…") { actions.onReword(row.commit) }
            .disabled(!canReword)
            .help(row.commit.isUnpushed ? "" : "This commit is already pushed; its message cannot be changed here.")
        Button("Undo Commit") { actions.onUndo(row.commit) }
            .disabled(!canUndo)
        Divider()
        Button("Checkout (Detached)…") { actions.onCheckoutDetached(row.commit) }
            .disabled(!actions.canChangeWorkingTree)
            .help(actions.canChangeWorkingTree ? "" : "Save the open file before you check out a commit.")
        Button("Create Branch Here…") { actions.onCreateBranchHere(row.commit) }
            .disabled(!actions.canChangeWorkingTree)
            .help(actions.canChangeWorkingTree ? "" : "Save the open file first.")
        Button("Create Tag Here…") { actions.onCreateTagHere(row.commit) }
        Divider()
        Button("Cherry-pick") { actions.onCherryPick(row.commit) }
            .disabled(!actions.canChangeWorkingTree || actions.hasOperation)
            .help(actions.canChangeWorkingTree ? "" : "Save the open file before you cherry-pick.")
        Button("Revert…") { actions.onRevert(row.commit) }
            .disabled(!actions.canChangeWorkingTree || actions.hasOperation)
            .help(actions.canChangeWorkingTree ? "" : "Save the open file before you revert.")
        Divider()
        Button("Copy Commit Hash") { copy(row.commit.id) }
        Button("Copy Commit Message") { copy(row.commit.subject) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
