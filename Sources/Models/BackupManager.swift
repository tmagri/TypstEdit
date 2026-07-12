import Foundation

/// Manages rotating per-file backups created each time the user presses **Save**.
///
/// Backups are written *before* the file is overwritten with the new content, so they
/// always hold the previously-saved state. This is what makes them useful when an
/// "insert at cursor" bug wipes the document: even if the user hits Save on the now-empty
/// buffer, the good on-disk content is first preserved as a backup.
///
/// Backups always live in `<file's-parent>/backups/` — co-located with the source file
/// (inside the notebook for `.note` files), never in a parent/base directory or App Support.
///
/// Up to `maxBackups` (UserDefaults key "maxBackups", default 3, bound via
/// `@AppStorage` in GeneralSettingsView) copies are kept per file, named
/// `<name>_<hash>.bak.<n>` where `1` is the newest and `<maxBackups>` is the oldest.
@MainActor
final class BackupManager {
    static let shared = BackupManager()

    private init() {}

    /// Reads the "maxBackups" UserDefaults key (the same one bound by
    /// `@AppStorage("maxBackups")` in GeneralSettingsView). Falls back to 3 when the
    /// key hasn't been written yet — `@AppStorage` only persists to UserDefaults once
    /// the user actually changes the value, so `integer(forKey:)` alone would return 0.
    private var maxBackups: Int {
        if let value = UserDefaults.standard.object(forKey: "maxBackups") as? Int {
            return value
        }
        return 3
    }

    // MARK: - Path Resolution

    /// Directory holding all backups for the given source file.
    /// Always co-located with the source: `<parent>/backups/`. This keeps backups inside
    /// each notebook (for `.note` files) instead of pooling in the base notebooks directory.
    private func backupDirectory(for originalURL: URL, projectRoot: URL?) -> URL {
        originalURL.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
    }

    /// Stable, cross-launch hash of a file path (djb2). Swift's `String.hash` is not
    /// stable across process launches, so we can't rely on it for on-disk filenames.
    private func stableHash(of path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private func backupFileURL(for originalURL: URL, projectRoot: URL?, index: Int) -> URL {
        let dir = backupDirectory(for: originalURL, projectRoot: projectRoot)
        let safeName = originalURL.lastPathComponent.replacingOccurrences(of: ".", with: "_")
        let hash = stableHash(of: originalURL.path)
        return dir.appendingPathComponent("\(safeName)_\(hash).bak.\(index)")
    }

    // MARK: - Backup Creation

    /// Captures the **current on-disk** content of `originalURL` as a rotating backup,
    /// intended to be called immediately *before* `performSave` writes the new content.
    ///
    /// - If backups are disabled (`maxBackups <= 0`), does nothing.
    /// - If the file doesn't exist yet (first save), there's nothing to back up.
    /// - If the on-disk content is empty/whitespace, the backup is skipped so that an
    ///   existing good backup isn't clobbered by an empty state (e.g. after the
    ///   insert-clears-text bug fires and auto-save flushes an empty buffer for a
    ///   `.note` file before the user hits Save).
    func backupExistingFile(at originalURL: URL, projectRoot: URL?) {
        let maxBackups = self.maxBackups
        guard maxBackups > 0 else { return }
        guard FileManager.default.fileExists(atPath: originalURL.path) else { return }

        guard let existingContent = try? String(contentsOf: originalURL, encoding: .utf8) else {
            print("[Backup] Could not read existing file to back up: \(originalURL.lastPathComponent)")
            return
        }
        if existingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Preserve the last good backup instead of rotating in an empty snapshot.
            return
        }

        let dir = backupDirectory(for: originalURL, projectRoot: projectRoot)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[Backup] Could not create backup directory: \(error)")
            return
        }

        // Rotate: drop the oldest slot, then shift each remaining backup up by one.
        let oldest = backupFileURL(for: originalURL, projectRoot: projectRoot, index: maxBackups)
        if FileManager.default.fileExists(atPath: oldest.path) {
            try? FileManager.default.removeItem(at: oldest)
        }
        for n in stride(from: maxBackups - 1, through: 1, by: -1) {
            let from = backupFileURL(for: originalURL, projectRoot: projectRoot, index: n)
            let to = backupFileURL(for: originalURL, projectRoot: projectRoot, index: n + 1)
            if FileManager.default.fileExists(atPath: from.path) {
                try? FileManager.default.moveItem(at: from, to: to)
            }
        }

        // Write the previous on-disk content into the newest slot (.1).
        let newest = backupFileURL(for: originalURL, projectRoot: projectRoot, index: 1)
        do {
            try existingContent.write(to: newest, atomically: true, encoding: .utf8)
            print("[Backup] Saved backup for \(originalURL.lastPathComponent) → \(newest.lastPathComponent)")
        } catch {
            print("[Backup] Failed to write backup: \(error)")
        }
    }

    // MARK: - Discovery & Restore

    /// Returns backup URLs for the given file, newest first. Each entry is annotated
    /// with its modification date via the returned tuple so the UI can show timestamps.
    func listBackups(for originalURL: URL, projectRoot: URL?) -> [(url: URL, modified: Date)] {
        let maxBackups = self.maxBackups
        guard maxBackups > 0 else { return [] }
        var results: [(URL, Date)] = []
        // Scan up to maxBackups slots; also tolerate a higher count if the setting was
        // previously larger (so old backups remain restorable until they age out).
        let scanLimit = max(maxBackups, 10)
        for n in 1...scanLimit {
            let u = backupFileURL(for: originalURL, projectRoot: projectRoot, index: n)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            let date = (try? u.resourceValues(forKeys: [URLResourceKey.contentModificationDateKey]).contentModificationDate) ?? Date()
            results.append((u, date))
        }
        // n=1 is newest by convention, but sort by date desc to be safe.
        return results.sorted { $0.1 > $1.1 }
    }

    /// Reads the textual content of a backup file, if readable.
    func restoreContent(from backupURL: URL) -> String? {
        return try? String(contentsOf: backupURL, encoding: .utf8)
    }

    /// Removes all backups for a file (e.g. when the file is deleted).
    func clearBackups(for originalURL: URL, projectRoot: URL?) {
        let entries = listBackups(for: originalURL, projectRoot: projectRoot)
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
