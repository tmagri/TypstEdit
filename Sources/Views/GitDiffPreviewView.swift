import SwiftUI
import AppKit

/// One classified line of `git diff` output.
struct GitDiffLine: Identifiable {
    enum Kind { case header, hunk, added, removed, context }
    let id: Int
    let text: String
    let kind: Kind

    /// Uses hunk state instead of prefixes alone, so an added line that
    /// starts with `++` is not shown as a `+++` file header.
    static func parse(_ diff: String) -> [GitDiffLine] {
        var inHunk = false
        return diff.components(separatedBy: "\n").enumerated().map { index, line in
            let kind: Kind
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                inHunk = false
                kind = .header
            } else if line.hasPrefix("@@") {
                inHunk = true
                kind = .hunk
            } else if !inHunk {
                kind = .header
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            return GitDiffLine(id: index, text: line, kind: kind)
        }
    }
}

/// A read-only, unified diff. It compares Git's index and saved working-tree
/// bytes; it never substitutes an unsaved editor buffer for either side.
struct GitDiffPreviewView: View {
    @ObservedObject var manager: SourceControlManager
    let change: GitChange
    let group: GitChangeGroup
    let repository: URL
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var diff: String?
    @State private var lines: [GitDiffLine] = []
    @State private var error: String?

    private let previewLineLimit = 3000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.path).font(.headline).textSelection(.enabled)
                    Text(group == .staged ? "Staged changes · HEAD → Index" : "Saved changes · Index → Working Tree")
                        .font(.caption)
                        .foregroundColor(themeManager.secondaryTextColor)
                }
                Spacer()
                Button("Copy Diff") {
                    guard let diff else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diff, forType: .string)
                }
                .disabled(diff?.isEmpty ?? true)
                Button("Close") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            }
            .padding(16)
            Divider()
            content
            Divider()
            Text("Diffs show saved files only. Binary changes appear as a Git summary.")
                .font(.caption)
                .foregroundColor(themeManager.secondaryTextColor)
                .padding(12)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(themeManager.editorBackground)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ScrollView {
                Text(error)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else if let diff {
            if diff.isEmpty {
                Text("No text changes to display.")
                    .foregroundColor(themeManager.secondaryTextColor)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines.prefix(previewLineLimit)) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(color(for: line.kind))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(background(for: line.kind))
                            }
                            if lines.count > previewLineLimit {
                                Text("Preview limited to \(previewLineLimit) lines. Use Copy Diff for the full text.")
                                    .font(.caption)
                                    .foregroundColor(themeManager.secondaryTextColor)
                                    .padding(12)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        // Line backgrounds fill the visible width, also when
                        // every line is shorter than the sheet.
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                }
            }
        } else {
            ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard manager.repositoryRoot == repository else {
            error = "The repository changed. Close this preview and select the file again."
            return
        }
        do {
            let result = try await manager.diff(for: change, group: group)
            guard !Task.isCancelled else { return }
            guard manager.repositoryRoot == repository else {
                error = "The repository changed. Close this preview and select the file again."
                return
            }
            lines = GitDiffLine.parse(result)
            diff = result
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func color(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .header: return themeManager.secondaryTextColor
        case .hunk: return themeManager.accentColor
        case .added: return .green
        case .removed: return .red
        case .context: return themeManager.textColor
        }
    }

    private func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: return .green.opacity(0.08)
        case .removed: return .red.opacity(0.08)
        default: return .clear
        }
    }
}
