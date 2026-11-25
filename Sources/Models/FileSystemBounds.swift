import Foundation

/// The two guards that keep a `file__*` tool from freezing the app.
///
/// Written after a real hang (incident `96C6CD0E…`, 2026-11-24): the model
/// asked for `file__find` with `"root": "."` while reviewing a case, the
/// recursive walk took that to be the process's working directory — `/`, for
/// a GUI app launched by launchd — and descended into an SMB share that had
/// stopped answering. The main thread sat in `smbfs_enum_dir` →
/// `smb_iod_waitrq` for **739 seconds** and the UI never drew again.
///
/// Two separate things were wrong, and each needs its own guard:
///
/// 1. **A relative path must never mean "the process's working directory".**
///    A tool's relative path means "relative to what the model is working
///    on" — the chat's reference folder. Resolving `"."` against `cwd` sent
///    it to the filesystem root, which is how it ever reached a network
///    mount. `FileToolbox.resolvePath(_:relativeTo:)` now requires a base.
/// 2. **Blocking I/O must never run on the main actor, and must have a
///    deadline.** `nonisolated` waives an isolation *check*; it does not move
///    work to another thread, so a `contentsOfDirectory` inside a
///    `@MainActor` executor still ran on the main thread. `runWithDeadline`
///    puts the walk on a background queue and abandons it at a deadline.
///
/// Together with the per-volume check (`networkVolume(for:)`), a dead share
/// costs one bounded, named tool error instead of an unresponsive app.
enum FileSystemBounds {

    // MARK: - Network volumes

    /// One mounted filesystem, and whether it lives on this Mac.
    struct Mount: Sendable, Equatable {
        let path: String
        let fileSystemType: String
        let isLocal: Bool

        /// Types that are remote even when the kernel does not clear
        /// `MNT_LOCAL` — `autofs` is the automounter, which *blocks on
        /// access* while it brings a share up, so it is the worst case for
        /// an unbounded walk even when nothing is currently mounted on it.
        static let remoteTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "autofs", "cddafs"]

        var isRemote: Bool {
            if !isLocal { return true }
            return Self.remoteTypes.contains(fileSystemType)
        }
    }

    /// Every mounted filesystem, cheapest possible read.
    ///
    /// `MNT_NOWAIT` is deliberate: it returns the cached mount list instead
    /// of asking each filesystem to refresh, so this call itself cannot
    /// block on a dying server. That is the entire point — a guard that
    /// hangs while checking for hangs is worse than none.
    nonisolated static func mounts() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        var result: [Mount] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            var entry = buffer[index]
            let path = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            let type = withUnsafePointer(to: &entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) {
                    String(cString: $0)
                }
            }
            result.append(Mount(
                path: path,
                fileSystemType: type,
                isLocal: (entry.f_flags & UInt32(MNT_LOCAL)) != 0
            ))
        }
        return result
    }

    /// The mount a path lives on: the longest matching mount point wins, so
    /// a share mounted inside a local folder is reported as the share.
    ///
    /// Purely lexical — it never stats the path, so asking cannot block.
    nonisolated static func mount(for path: String, among known: [Mount]? = nil) -> Mount? {
        let all = known ?? mounts()
        var best: Mount?
        for candidate in all {
            // `/` is a prefix of every absolute path, but `"/" + "/"` is not,
            // so it needs its own rule.
            let matches = candidate.path == "/"
                ? path.hasPrefix("/")
                : (path == candidate.path || path.hasPrefix(candidate.path + "/"))
            guard matches else { continue }
            if best == nil || candidate.path.count > best!.path.count {
                best = candidate
            }
        }
        return best
    }

    /// The refusal message for a path on a network volume, or `nil` when the
    /// path is local (or the user has allowed network volumes).
    ///
    /// The message is a tool error, not a crash, and it names the way out:
    /// a model that reads "refused" with no alternative just retries the same
    /// call, which is exactly the loop this guard exists to break.
    nonisolated static func networkRefusal(
        for path: String, allowNetworkVolumes: Bool
    ) -> String? {
        guard !allowNetworkVolumes else { return nil }
        guard let mount = mount(for: path), mount.isRemote else { return nil }
        return """
        Not searched: \(path) is on a network volume (\(mount.fileSystemType) at \(mount.path)), \
        and walking a network share can block for minutes if the server stops answering. \
        Give a path on this Mac instead — the reference folder, a folder under your home \
        directory, or a path from an earlier tool result. \
        To allow network volumes, turn on "File tools may read network volumes" in \
        Settings → AI Chat → Tools.
        """
    }

    /// The message for a walk that hit its deadline.
    nonisolated static func timeoutMessage(tool: String, path: String, seconds: Double) -> String {
        """
        \(tool) stopped after \(Int(seconds))s without finishing at \(path). \
        The folder is either very large or on a slow volume. Narrow the search — \
        a deeper `path`, a `glob`/`name_glob`, or a single file — rather than \
        re-running the same call.
        """
    }

    // MARK: - Deadlines

    /// The outcome of a bounded piece of blocking work.
    enum Deadline<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
        /// The work threw. Carried as text because it must cross a thread
        /// boundary, and a tool error is a message the model reads — losing
        /// it here would turn a named refusal ("that is a network volume")
        /// into a misleading "Path not found".
        case failed(String)
    }

    /// Runs blocking work on a background queue and gives up at `seconds`.
    ///
    /// A blocking `getattrlistbulk` cannot be interrupted — there is no
    /// cancellation point inside the kernel call — so a cooperative
    /// `Task.isCancelled` check would never be reached. Racing the work
    /// against a timer is the only way to bound it: the caller gets
    /// `.timedOut` and the wedged thread is abandoned (it finishes or never
    /// does; either way it no longer holds the turn).
    ///
    /// Verified on this Mac: a 5-second blocking call with a 1-second
    /// deadline returns `.timedOut` after 1.07 s instead of blocking.
    nonisolated static func runWithDeadline<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () throws -> T
    ) async -> Deadline<T> {
        await withCheckedContinuation { continuation in
            let settleLock = NSLock()
            var settled = false
            func settle(_ outcome: Deadline<T>) {
                settleLock.lock()
                defer { settleLock.unlock() }
                guard !settled else { return }
                settled = true
                continuation.resume(returning: outcome)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    settle(.finished(try work()))
                } catch {
                    settle(.failed(error.localizedDescription))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                settle(.timedOut)
            }
        }
    }
}
