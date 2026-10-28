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
    /// The window this view is hosted in (set by `WindowAccessor` below), so
    /// Close works both in a standalone preview window and in a sheet.
    @State private var hostingWindow: NSWindow?

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
                Button("Close") {
                    if let hostingWindow {
                        hostingWindow.performClose(nil)
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
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
        .background(WindowAccessor { hostingWindow = $0 })
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
                                    // Single line, never wrapped: long lines
                                    // grow past the window and scroll.
                                    .fixedSize(horizontal: true, vertical: false)
                                    // Width goes on each row so it re-measures
                                    // on every window resize; a wrapper-level
                                    // width kept a stale, "thin" column that
                                    // did not flex.
                                    .frame(minWidth: geometry.size.width, alignment: .leading)
                                    .background(background(for: line.kind))
                            }
                            if lines.count > previewLineLimit {
                                Text("Preview limited to \(previewLineLimit) lines. Use Copy Diff for the full text.")
                                    .font(.caption)
                                    .foregroundColor(themeManager.secondaryTextColor)
                                    .padding(12)
                            }
                        }
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

/// Opens the diff preview in its own AppKit window — resizable and full
/// screen capable — instead of a fixed sheet. Several previews can be open
/// at once; each closes with the Close button, Escape, or Cmd+W.
@MainActor
enum GitDiffPreviewWindow {
    static func open(
        manager: SourceControlManager,
        change: GitChange,
        group: GitChangeGroup,
        repository: URL,
        themeManager: ThemeManager
    ) {
        GitDiffWindowKeeper.shared.open(
            manager: manager,
            change: change,
            group: group,
            repository: repository,
            themeManager: themeManager
        )
    }
}

/// Retains visible diff windows and their delegates so they stay alive while
/// open and are released when closed.
@MainActor
private final class GitDiffWindowKeeper {
    static let shared = GitDiffWindowKeeper()
    private var windows: [NSWindow] = []
    private var delegates: [NSWindow: GitDiffWindowDelegate] = [:]

    func open(
        manager: SourceControlManager,
        change: GitChange,
        group: GitChangeGroup,
        repository: URL,
        themeManager: ThemeManager
    ) {
        let content = GitDiffPreviewView(
            manager: manager,
            change: change,
            group: group,
            repository: repository
        )
        .environmentObject(themeManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        window.title = change.path
        window.identifier = NSUserInterfaceItemIdentifier("git-diff-preview-\(UUID().uuidString)")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)

        let delegate = GitDiffWindowDelegate { [weak self] window in
            self?.windows.removeAll { $0 === window }
            self?.delegates[window] = nil
        }
        window.delegate = delegate
        delegates[window] = delegate
        windows.append(window)

        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// Retained by the keeper so the weak `window.delegate` stays set until the
/// window closes.
@MainActor
private final class GitDiffWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void

    init(onClose: @escaping (NSWindow) -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            onClose(window)
        }
    }
}
