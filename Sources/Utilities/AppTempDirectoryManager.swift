import Foundation
import CryptoKit

/// Resolves and owns the lifecycle of the OS-temp mirror used when a project
/// opts out of keeping its `temp/` (compiler scratch) or `vectorcaches/`
/// (embedding index) folders inside the project directory itself.
///
/// macOS does **not** promptly or reliably purge `NSTemporaryDirectory()` —
/// the `periodic` housekeeping job only sweeps items untouched for several
/// days, on its own schedule, with no guarantee it runs before disk fills up
/// or the folder is inspected. So unlike the in-project folders (which are
/// cleaned explicitly by `TypstCompiler`/`RAGManager` already), anything
/// placed here is TypstEdit's own responsibility to prune — on launch, on
/// project close, and via a manual "Clear All Temp Files" action in Settings.
@MainActor
enum AppTempDirectoryManager {

    /// What an OS-temp mirror directory is being used for. Deliberately avoids
    /// the literal names "temp"/"vectorcaches" used for the in-project
    /// counterparts — `SafeDirectoryManager.containsSpecialDirectory` matches
    /// on exact path components, and reusing those names here would make
    /// cleanup logic that guards against deleting an in-project special
    /// directory misfire against these OS-temp paths too.
    enum Kind: String {
        case compilerScratch = "build"
        case vectorCache = "cache"
    }

    /// Root folder under the OS temp directory that every TypstEdit-managed
    /// out-of-project cache lives under: `<tmp>/TypstEdit/<projectHash>/<kind>/`.
    static var rootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TypstEdit", isDirectory: true)
    }

    /// A stable identifier for a project so the same project path always
    /// resolves to the same OS-temp subfolder across launches.
    static func projectHash(for projectRoot: URL) -> String {
        let path = projectRoot.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private static func projectDirectory(for projectRoot: URL) -> URL {
        rootURL.appendingPathComponent(projectHash(for: projectRoot), isDirectory: true)
    }

    static func directory(for projectRoot: URL, kind: Kind) -> URL {
        projectDirectory(for: projectRoot).appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// Creates (if needed) and returns the OS-temp mirror directory for `kind`.
    static func ensureDirectory(for projectRoot: URL, kind: Kind) -> URL {
        let dir = directory(for: projectRoot, kind: kind)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Touch the project directory's modification date so launch-time
        // pruning treats recently-used projects as fresh.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: projectDirectory(for: projectRoot).path)
        return dir
    }

    /// Removes the OS-temp mirror for a single project (both kinds at once).
    static func clear(for projectRoot: URL) {
        try? FileManager.default.removeItem(at: projectDirectory(for: projectRoot))
    }

    /// Removes every TypstEdit OS-temp mirror, for every project. Used by the
    /// "Clear All Temp Files" action in Settings.
    static func clearAll() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// Prunes per-project subfolders untouched for longer than `days`. Call
    /// once at app launch — this is the actual cleanup guarantee, since the
    /// OS won't reliably provide one.
    static func pruneStale(olderThan days: Int = 7) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Combined size, in bytes, of all OS-temp mirrors — surfaced in Settings
    /// so the toggle's effect is visible rather than a folder nobody can find.
    static func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
