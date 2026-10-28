import Foundation
import Combine

/// App-wide registry of open documents with unsaved edits, keyed by the
/// identity of the editor controller showing them. The Source Control panel
/// uses it to protect every dirty file inside the repository — not just the
/// one in the frontmost window — from working-tree-rewriting git operations
/// (discard, checkout, merge, stash, and so on): the next save would
/// otherwise silently restore the on-disk version over git's changes.
@MainActor
final class OpenDocumentRegistry: ObservableObject {
    static let shared = OpenDocumentRegistry()

    /// Standardized URLs of every open document that has unsaved edits.
    @Published private(set) var dirtyFiles: Set<URL> = []

    /// Editor identity -> the file it shows, for editors with unsaved edits.
    private var entries: [ObjectIdentifier: URL] = [:]

    /// Records the current state of one editor. Only editors that have
    /// unsaved edits and an open file are kept.
    func updateEditor(_ id: ObjectIdentifier, fileURL: URL?, hasUnsavedChanges: Bool) {
        let newEntry = hasUnsavedChanges ? fileURL : nil
        guard entries[id] != newEntry else { return }
        entries[id] = newEntry
        recompute()
    }

    /// Removes an editor entirely (window closed, controller deallocated).
    func removeEditor(_ id: ObjectIdentifier) {
        guard entries[id] != nil else { return }
        entries[id] = nil
        recompute()
    }

    /// True when some editor shows `url` with unsaved edits.
    func isDirty(_ url: URL) -> Bool {
        dirtyFiles.contains(url.resolvingSymlinksInPath().standardizedFileURL)
    }

    /// Every dirty file inside `root` (paths relative to it). Symlinks are
    /// resolved and paths standardized so a file reached through a symlink
    /// is still recognized.
    func dirtyPaths(in root: URL) -> Set<String> {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var paths = Set<String>()
        for url in dirtyFiles {
            let file = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard file.hasPrefix(base + "/") else { continue }
            paths.insert(String(file.dropFirst(base.count + 1)))
        }
        return paths
    }

    private func recompute() {
        let urls = Set(entries.values.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        guard urls != dirtyFiles else { return }
        dirtyFiles = urls
    }
}
