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
