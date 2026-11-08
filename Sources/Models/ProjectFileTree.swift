import Foundation
import CoreServices

// MARK: - Tree model

/// One row of the Projects file list.
///
/// Identity is the file's URL — never its contents. SwiftUI's outline diffs
/// rows by `id`, so a value whose `Hashable` conformance changed whenever a
/// descendant changed looked like a different item. That mismatch is what
/// left stale rows on screen after a reload, and what forced the old
/// "rebuild the whole List" workaround. `hasSameStructure(as:)` is the
/// content comparison, used to decide whether a reload should publish.
struct FileNode: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

extension FileNode {
    /// Deep comparison of what the list actually shows: paths, names, kinds
    /// and loaded children. Identity-only `==` can't answer this.
    func hasSameStructure(as other: FileNode) -> Bool {
        guard url == other.url,
              name == other.name,
              isDirectory == other.isDirectory else { return false }

        switch (children, other.children) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.hasSameStructure(as: rhs)
        default:
            return false
        }
    }
}

extension Array where Element == FileNode {
    func hasSameStructure(as other: [FileNode]) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).allSatisfy { $0.hasSameStructure(as: $1) }
    }
}

// MARK: - Visible rows

/// A single row of the flattened Projects list.
///
/// The list renders exactly these rows, in order, so the tree's depth never
/// reaches SwiftUI's recursive `List(_:children:)` diffing (which could leave
/// stale rows and crash on deep trees). Collapsed subtrees are simply not
/// flattened, so a change inside one costs the list nothing.
struct VisibleFileRow: Identifiable {
    var id: URL { node.url }
    let node: FileNode
    /// Nesting level, used for indentation.
    let depth: Int
    let isExpanded: Bool
}

// MARK: - Tree loading

/// Pure, off-main-thread scanning for the Projects sidebar. None of this
/// touches UI state, so the expensive part (one directory listing per folder
/// the list is showing) runs away from the main actor.
enum ProjectTreeLoader {

    /// Generated folders that never belong in the project list.
    static let ignoredFolderNames: Set<String> = ["backups", "temp", "vectorcaches"]

    /// Canonical form of a directory URL.
    ///
    /// `contentsOfDirectory` hands back resolved paths (on macOS `/tmp` and
    /// `/var` are symlinks into `/private`), while a URL built with
    /// `appendingPathComponent` keeps the unresolved one. Mixing the two makes
    /// every identity comparison silently miss — the tree rebuilt correctly
    /// but never replaced the row it was meant to replace. Resolving at the
    /// entry points keeps every node in one consistent form.
    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Loads **one level** of a directory. Subdirectories start with a
    /// placeholder `children: []` so SwiftUI renders the disclosure chevron;
    /// their contents load on demand. Never recurses, which is what kept the
    /// old deep tree from tripping SwiftUI's recursive row diffing.
    static func loadDirectory(at url: URL) -> [FileNode] {
        let directory = canonical(url)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sorted = contents.sorted { lhs, rhs in
            let lhsDir = isDirectory(lhs)
            let rhsDir = isDirectory(rhs)
            if lhsDir != rhsDir { return lhsDir } // Directories first
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        return sorted.compactMap { file in
            let isDir = isDirectory(file)
            let name = file.lastPathComponent
            if isDir && ignoredFolderNames.contains(name) { return nil }
            return FileNode(
                // Built from the canonical parent so the whole tree shares one
                // path form (see `canonical(_:)`).
                url: directory.appendingPathComponent(name, isDirectory: isDir),
                name: name,
                isDirectory: isDir,
                children: isDir ? [] : nil
            )
        }
    }

    /// Every directory whose contents are currently in the tree and still
    /// expanded. Reloads only revisit these: a collapsed folder is not on
    /// screen, so nothing inside it can make the visible list stale.
    static func loadedDirectories(in nodes: [FileNode], expanded: Set<URL>) -> Set<URL> {
        let expanded = Set(expanded.map(canonical))
        var result: Set<URL> = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes where node.isDirectory && expanded.contains(node.url) {
                result.insert(node.url)
                if let children = node.children { walk(children) }
            }
        }
        walk(nodes)
        return result
    }

    /// Rebuilds the tree the list is showing: the root's top level, then only
    /// the folders that were already loaded. Shallowest first, so a child is
    /// still reachable after its parent has been refilled.
    static func buildTree(root: URL, reloading loadedDirectories: Set<URL>) -> [FileNode] {
        let treeRoot = canonical(root)
        var tree = loadDirectory(at: treeRoot)
        let ordered = loadedDirectories
            .map(canonical)
            .filter { $0 != treeRoot }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }

        for url in ordered {
            let children = loadDirectory(at: url)
            tree = replacingChildren(of: url, with: children, in: tree)
        }
        return tree
    }

    /// Returns `nodes` with the directory at `target` replaced by `children`.
    /// A target that isn't in the tree is left alone (it was collapsed away or
    /// removed while the scan was running).
    static func replacingChildren(of target: URL, with children: [FileNode], in nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            if node.url == target {
                var updated = node
                updated.children = children
                return updated
            }
            guard let existing = node.children else { return node }
            var updated = node
            updated.children = replacingChildren(of: target, with: children, in: existing)
            return updated
        }
    }

    /// Returns `nodes` with the loaded listing of `target` discarded
    /// (`children` back to the `[]` placeholder), leaving the rest of the tree
    /// untouched. Used when a folder is collapsed: its rows are not on screen,
    /// and expanding re-reads the directory anyway.
    static func droppingChildren(of target: URL, in nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            if node.url == target {
                var updated = node
                updated.children = updated.isDirectory ? [] : nil
                return updated
            }
            guard let existing = node.children else { return node }
            var updated = node
            updated.children = droppingChildren(of: target, in: existing)
            return updated
        }
    }

    /// True when a changed path is noise for the Projects list: hidden
    /// (`.git`, `.typstedit`, `.DS_Store`) or inside a generated folder
    /// (`temp/`, `backups/`, `vectorcaches/`). Filtering here keeps compiles,
    /// git housekeeping and index writes from waking the UI.
    static func isIgnoredPath(_ url: URL, inProject root: URL) -> Bool {
        let rootPath = canonical(root).path
        let path = canonical(url).path
        guard path != rootPath else { return false }

        let relative: String
        if path.hasPrefix(rootPath + "/") {
            relative = String(path.dropFirst(rootPath.count + 1))
        } else {
            relative = path
        }

        for component in relative.split(separator: "/") {
            if component.hasPrefix(".") { return true }
            if ignoredFolderNames.contains(String(component)) { return true }
        }
        return false
    }

    /// Rows the list should render right now: the tree flattened down to the
    /// folders that are expanded. Runs on the main actor with the tree the
    /// list is already showing, so it never touches a snapshot being scanned
    /// in the background.
    static func visibleRows(in nodes: [FileNode], expanded: Set<URL>) -> [VisibleFileRow] {
        visibleRows(in: nodes, canonicalExpanded: Set(expanded.map(canonical)), depth: 0)
    }

    private static func visibleRows(in nodes: [FileNode], canonicalExpanded: Set<URL>, depth: Int) -> [VisibleFileRow] {
        var rows: [VisibleFileRow] = []
        rows.reserveCapacity(nodes.count)
        for node in nodes {
            let isExpanded = node.isDirectory && canonicalExpanded.contains(node.url)
            rows.append(VisibleFileRow(node: node, depth: depth, isExpanded: isExpanded))
            if isExpanded, let children = node.children {
                rows.append(contentsOf: visibleRows(in: children, canonicalExpanded: canonicalExpanded, depth: depth + 1))
            }
        }
        return rows
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

// MARK: - Directory watcher

/// One path reported by `DirectoryWatcher`.
struct DirectoryChange: Sendable {
    let url: URL
    /// The item itself was created, removed or renamed, so the listing of the
    /// folder that *contains* it may need re-reading.
    let changesParentListing: Bool
    /// The changed item is a directory. A modified directory means *its own*
    /// listing may need re-reading (only worth doing while it is expanded).
    let isDirectory: Bool
}

/// Recursive directory watcher built on FSEvents.
///
/// One kernel subscription covers the whole project tree, so an idle project
/// costs nothing — no polling, no one-file-descriptor-per-folder. FSEvents
/// coalesces bursts (a compile writing dozens of files, a git checkout) and
/// the watcher adds a short settle delay, so callers see at most a few
/// batches per second no matter what happened on disk.
final class DirectoryWatcher: @unchecked Sendable {
    /// Changed paths, delivered on the main queue.
    typealias Handler = ([DirectoryChange]) -> Void

    private let root: URL
    /// The canonical root this watcher covers. Callers compare against it to
    /// avoid tearing down and recreating an equivalent subscription.
    var watchedRoot: URL { root }
    private let latency: TimeInterval
    private let settleDelay: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "TypstEdit.DirectoryWatcher", qos: .utility)

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var contextInfo: UnsafeMutableRawPointer?
    private var stopped = true

    /// Accumulated between flushes; touched only on `queue`.
    private struct PendingChange {
        var changesParentListing = false
        var isDirectory = false
    }
    private var pendingPaths: [String: PendingChange] = [:]
    private var flushWorkItem: DispatchWorkItem?

    init(root: URL,
         latency: TimeInterval = 0.4,
         settleDelay: TimeInterval = 0.2,
         handler: @escaping Handler) {
        // FSEvents reports resolved paths, so the root has to be resolved too
        // or the "the root itself changed" comparison below never matches.
        self.root = ProjectTreeLoader.canonical(root)
        self.latency = latency
        self.settleDelay = settleDelay
        self.handler = handler
    }

    var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    func start() {
        lock.lock()
        guard stream == nil else { lock.unlock(); return }
        // Retained so the callback can never reach a deallocated watcher:
        // `stop()` balances this reference.
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.onEvents,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Unmanaged<DirectoryWatcher>.fromOpaque(info).release()
            lock.unlock()
            return
        }

        self.stream = stream
        self.contextInfo = info
        self.stopped = false
        lock.unlock()

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops delivery and releases the stream. Idempotent.
    func stop() {
        lock.lock()
        let stream = self.stream
        let info = self.contextInfo
        self.stream = nil
        self.contextInfo = nil
        self.stopped = true
        lock.unlock()

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if let info {
            Unmanaged<DirectoryWatcher>.fromOpaque(info).release()
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Called on `queue` with one batch from FSEvents.
    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !isStopped else { return }
        for (index, path) in paths.enumerated() {
            let eventFlags = index < flags.count ? flags[index] : 0
            var pending = pendingPaths[path] ?? PendingChange()
            if Self.canChangeParentListing(eventFlags) { pending.changesParentListing = true }
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { pending.isDirectory = true }
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink) != 0 { pending.isDirectory = false }
            pendingPaths[path] = pending

            // FSEvents can't describe this change at all: mark the watch root
            // as changed, which tells the caller to rescan everything.
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                pendingPaths[root.path] = PendingChange(changesParentListing: true, isDirectory: true)
            }
        }
        scheduleFlush()
    }

    /// A created, removed or renamed item changes the listing of the folder
    /// that contains it. A plain content write does not, which is what keeps
    /// ordinary saves from re-reading any directory.
    private static func canChangeParentListing(_ flags: FSEventStreamEventFlags) -> Bool {
        let structural =
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        return flags & structural != 0
    }

    /// Restarts the settle window on every event, so a long write settles
    /// into one delivery instead of a stream of them.
    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = item
        queue.asyncAfter(deadline: .now() + settleDelay, execute: item)
    }

    private func flush() {
        guard !isStopped else { return }
        let paths = pendingPaths
        pendingPaths.removeAll()
        guard !paths.isEmpty else { return }

        let changes = paths.map { path, pending in
            DirectoryChange(
                url: URL(fileURLWithPath: path),
                changesParentListing: pending.changesParentListing,
                isDirectory: pending.isDirectory
            )
        }
        let handler = self.handler
        DispatchQueue.main.async { handler(changes) }
    }

    private static let onEvents: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info, count > 0 else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        // `kFSEventStreamCreateFlagUseCFTypes` means `eventPaths` is a CFArray
        // of CFStrings, so it can be bridged directly — no manual array copy.
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
        watcher.receive(paths: paths, flags: flags)
    }
}
