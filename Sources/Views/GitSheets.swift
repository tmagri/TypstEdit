import SwiftUI

/// What the name-input sheet asks for. `atCommit` is a full commit hash or
/// nil for HEAD. One sheet pattern serves branches, renames and tags.
enum GitNameSheetKind: Identifiable {
    case createBranch(atCommit: String?)
    case renameBranch(current: String)
    case createTag(atCommit: String?)

    var id: String {
        switch self {
        case .createBranch(let at): return "branch:\(at ?? "HEAD")"
        case .renameBranch(let current): return "rename:\(current)"
        case .createTag(let at): return "tag:\(at ?? "HEAD")"
        }
    }
}

/// The sheet that asks for one reference name, with validation. Used for
/// creating branches and tags and renaming the current branch.
struct GitNameSheet: View {
    let kind: GitNameSheetKind
    /// Existing names, so duplicates are rejected before Git runs.
    let existingNames: [String]
    /// (name, optional tag message)
    let onSubmit: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var tagMessage = ""
    @FocusState private var focused: Bool

    init(kind: GitNameSheetKind, existingNames: [String] = [], onSubmit: @escaping (String, String?) -> Void) {
        self.kind = kind
        self.existingNames = existingNames
        self.onSubmit = onSubmit
        if case .renameBranch(let current) = kind {
            _name = State(initialValue: current)
        } else {
            _name = State(initialValue: "")
        }
    }

    private var isTag: Bool {
        if case .createTag = kind { return true }
        return false
    }

    private var title: String {
        switch kind {
        case .createBranch: return "Create Branch"
        case .renameBranch: return "Rename Branch"
        case .createTag: return "Create Tag"
        }
    }

    private var subtitle: String {
        switch kind {
        case .createBranch(let at):
            return at.map { "Create and switch to a new branch at \($0.prefix(7))." }
                ?? "Create a branch from the current commit and switch to it."
        case .renameBranch(let current):
            return "Rename the current branch “\(current)”."
        case .createTag(let at):
            return at.map { "Create a tag at \($0.prefix(7))." }
                ?? "Create a tag at the current commit."
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Renaming a branch to its own name is rejected as a duplicate below,
    /// so the current name is explicitly allowed here.
    private var isCurrentName: Bool {
        if case .renameBranch(let current) = kind, trimmed.caseInsensitiveCompare(current) == .orderedSame {
            return true
        }
        return false
    }

    private var isDuplicate: Bool {
        guard !trimmed.isEmpty, !isCurrentName else { return false }
        return existingNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private var problem: String? {
        if isDuplicate {
            return isTag ? "A tag named “\(trimmed)” already exists." : "A branch named “\(trimmed)” already exists."
        }
        return GitRefNameRules.problem(with: trimmed, reserved: isTag ? [] : ["HEAD"])
    }

    private var submitTitle: String {
        if case .renameBranch = kind { return "Rename" }
        return "Create"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
            TextField(isTag ? "Tag name" : "Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            if isTag {
                TextField("Tag message (optional)", text: $tagMessage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            if let problem {
                Text(problem).font(.caption).foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(submitTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !trimmed.isEmpty, problem == nil else { return }
        onSubmit(trimmed, isTag ? tagMessage : nil)
        dismiss()
    }
}

/// One commit whose message is being rewritten.
struct GitRewordRequest: Identifiable {
    let commit: GitCommit
    var id: String { commit.id }
}

/// Rewrites one unpushed commit's message. Prefilled with the full message
/// (subject and body); saving is disabled until the text changes.
struct GitRewordSheet: View {
    let manager: SourceControlManager
    let commit: GitCommit
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var originalMessage: String?
    @State private var loadError: String?

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard loadError == nil, !trimmed.isEmpty else { return false }
        return message != originalMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reword Commit").font(.headline)
            Text("\(commit.shortHash) · \(commit.subject)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            TextEditor(text: $message)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 320, height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
            if let loadError {
                Text(loadError).font(.caption).foregroundColor(.red)
            }
            Text("The first line becomes the subject; leave one blank line before the body.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task(id: commit.id) { await load() }
    }

    private func load() async {
        do {
            let full = try await manager.fullMessage(of: commit.id)
            guard !Task.isCancelled else { return }
            message = full
            originalMessage = full
        } catch {
            guard !Task.isCancelled else { return }
            loadError = "Could not load the commit message: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(message)
        dismiss()
    }
}
