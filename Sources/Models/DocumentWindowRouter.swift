import Foundation

/// Decides which window a file opened from Finder, the File menu, Open
/// Recent, the welcome screen or the `typstedit open` command goes to. The
/// app keeps a single process; each document gets its own window.
///
/// Pure value logic so it can be unit tested without AppKit.
enum DocumentWindowRouter {

    /// One document window, as seen by the router.
    struct Slot: Equatable {
        /// The file the window shows, if any.
        var fileURL: URL?
        /// True when the window shows nothing worth keeping: no file, no
        /// project, no unsaved edits. Such a window can take the file.
        var isIdle: Bool
        /// True for the frontmost (key) window.
        var isKey: Bool
        /// True for the main (SwiftUI `WindowGroup`) window.
        var isMain: Bool
    }

    enum Destination: Equatable {
        /// The file is already open in this slot: bring that window forward.
        case focus(Int)
        /// Load the file into this idle slot.
        case load(Int)
        /// No window can take it: open a new document window.
        case newWindow
    }

    /// Where `url` goes. `claimed` lists slots that already received a file
    /// in the same batch (their load is still in flight, so they look idle).
    static func destination(for url: URL, in slots: [Slot], claimed: Set<Int> = []) -> Destination {
        if let index = slots.firstIndex(where: { $0.fileURL.map { isSameFile($0, url) } ?? false }) {
            return .focus(index)
        }
        let free = slots.indices.filter { slots[$0].isIdle && !claimed.contains($0) }
        // The key window first (the click came from it), then the main window.
        if let key = free.first(where: { slots[$0].isKey }) { return .load(key) }
        if let main = free.first(where: { slots[$0].isMain }) { return .load(main) }
        if let any = free.first { return .load(any) }
        return .newWindow
    }

    /// True when both URLs name the same file, ignoring symlinks and
    /// `.`/`..` components.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Decides which window a project folder (or the notebooks folder) opens in.
/// A folder is open in at most one window: opening it again brings that
/// window forward, like VS Code. Each window then owns that project's index,
/// chat history and MCP servers alone.
///
/// Pure value logic so it can be unit tested without AppKit.
enum ProjectWindowRouter {

    struct Slot: Equatable {
        /// The project folder the window shows, if any.
        var projectRoot: URL?
        /// No file, no project, no unsaved edits.
        var isIdle: Bool
        var isKey: Bool
        var isMain: Bool
        /// The window the request came from, when it asked to replace its own
        /// content (an import that opens its result as a project).
        var isPreferred: Bool = false
    }

    enum Destination: Equatable {
        /// The folder is already open in this window.
        case focus(Int)
        /// Open the folder in this window.
        case load(Int)
        /// Open the folder in a new window.
        case newWindow
    }

    /// Where `root` goes. With `forceNewWindow`, an idle window is not
    /// reused, but a window that already shows the folder is still focused.
    ///
    /// With `file`, a window whose project already contains that file is
    /// focused too (the deepest such project wins), as VS Code opens a file in
    /// the window of the folder it belongs to.
    static func destination(for root: URL, file: URL? = nil, in slots: [Slot], forceNewWindow: Bool = false) -> Destination {
        if let index = slots.firstIndex(where: { $0.projectRoot.map { isSameFolder($0, root) } ?? false }) {
            return .focus(index)
        }
        if let file {
            let owners = slots.indices.filter { slots[$0].projectRoot.map { contains($0, file) } ?? false }
            if let deepest = owners.max(by: { canonicalFolder(slots[$0].projectRoot!).count < canonicalFolder(slots[$1].projectRoot!).count }) {
                return .focus(deepest)
            }
        }
        if forceNewWindow { return .newWindow }
        if let preferred = slots.firstIndex(where: \.isPreferred) { return .load(preferred) }
        let idle = slots.indices.filter { slots[$0].isIdle }
        if let key = idle.first(where: { slots[$0].isKey }) { return .load(key) }
        if let main = idle.first(where: { slots[$0].isMain }) { return .load(main) }
        if let any = idle.first { return .load(any) }
        return .newWindow
    }

    /// Exact folder identity. A subfolder is a different project, as in VS
    /// Code, so `/a` and `/a/b` can be open side by side.
    static func isSameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalFolder(lhs) == canonicalFolder(rhs)
    }

    /// True when `item` is inside `folder` (not the folder itself).
    static func contains(_ folder: URL, _ item: URL) -> Bool {
        let base = canonicalFolder(folder)
        let path = canonicalFolder(item)
        return path.hasPrefix(base == "/" ? "/" : base + "/") && path != base
    }

    static func canonicalFolder(_ url: URL) -> String {
        var path = DocumentWindowRouter.canonicalPath(url)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
