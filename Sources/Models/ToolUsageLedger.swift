import Foundation
import CryptoKit

// MARK: - Data Model

/// Usage statistics for a single tool within a reference-folder context.
///
/// Persisted as part of the per-folder `tool-usage.json` ledger so the
/// pruning heuristic can survive across app launches.
struct ToolUsageEntry: Codable {
    /// Total invocation count across all recorded sessions.
    var totalCalls: Int
    /// Number of distinct sessions in which the tool was offered at least once.
    var sessions: Int
    /// Consecutive prompts the tool was offered but **not** called.
    /// Reset to zero each time the tool is actually invoked.
    var promptsWithoutCall: Int
    /// Wall-clock timestamp of the most recent successful invocation.
    var lastCalled: Date?
}

// MARK: - Actor

/// Tracks which MCP / agent tools are actually called per reference-folder
/// context, and prunes schemas for chronically-unused tools before they reach
/// the model — saving prompt tokens without the user having to manage tool
/// selection manually.
///
/// ## Persistence
/// Each reference folder gets its own JSON file at
/// `~/.typstedit/ledger/<hash>/tool-usage.json`, where `<hash>` is the first
/// 8 characters of the SHA-256 of the folder's absolute path.  When no
/// reference folder is active the global key `"__global__"` is used.
///
/// ## Threading
/// Declared as a Swift `actor` so all mutations are automatically serialised
/// without manual locking.
actor ToolUsageLedger {

    // MARK: Shared instance

    /// Process-wide singleton.
    static let shared = ToolUsageLedger()

    // MARK: Private state

    /// In-memory cache: folderHash → [toolQualifiedName → entry].
    private var cache: [String: [String: ToolUsageEntry]] = [:]

    /// Tracks which hashes have been loaded from disk at least once.
    private var loaded: Set<String> = []

    // MARK: Public API

    /// Call once at session start for every tool that will be offered to the
    /// model.  Increments `promptsWithoutCall` and `sessions` for each tool
    /// that has not been called in the current prompt.
    ///
    /// - Parameters:
    ///   - qualifiedNames: The qualified names of tools being offered this session.
    ///   - folderPath: The active reference-folder path, or `nil` for global.
    func recordToolsOffered(qualifiedNames: [String], folderPath: String?) async {
        let hash = folderHash(for: folderPath)
        await ensureLoaded(hash: hash)
        for key in qualifiedNames {
            var entry = cache[hash]?[key] ?? ToolUsageEntry(
                totalCalls: 0, sessions: 0, promptsWithoutCall: 0, lastCalled: nil
            )
            entry.sessions += 1
            entry.promptsWithoutCall += 1
            if cache[hash] == nil { cache[hash] = [:] }
            cache[hash]![key] = entry
        }
        save(hash: hash)
    }

    /// Call when a tool is actually invoked by the model.  Resets
    /// `promptsWithoutCall`, increments `totalCalls`, and stamps `lastCalled`.
    ///
    /// - Parameters:
    ///   - toolName: The qualified tool name, e.g. `"fs__run_script"`.
    ///   - folderPath: The active reference-folder path, or `nil` for global.
    func recordToolCalled(_ toolName: String, folderPath: String?) async {
        let hash = folderHash(for: folderPath)
        await ensureLoaded(hash: hash)
        var entry = cache[hash]?[toolName] ?? ToolUsageEntry(
            totalCalls: 0, sessions: 0, promptsWithoutCall: 0, lastCalled: nil
        )
        entry.totalCalls += 1
        entry.promptsWithoutCall = 0
        entry.lastCalled = Date()
        if cache[hash] == nil { cache[hash] = [:] }
        cache[hash]![toolName] = entry
        save(hash: hash)
    }

    /// Returns the set of pruned qualified tool names for `folderPath`.
    func prunedQualifiedNames(for folderPath: String?) async -> Set<String> {
        let hash = folderHash(for: folderPath)
        await ensureLoaded(hash: hash)
        let entries = cache[hash] ?? [:]
        var pruned = Set<String>()
        for (name, entry) in entries {
            if isPruned(entry) {
                pruned.insert(name)
            }
        }
        return pruned
    }

    /// Returns the qualified names of tools that are currently pruned for the
    /// given folder.  Useful for displaying pruning state in a Settings UI.
    ///
    /// - Parameter folderPath: The reference-folder path, or `nil` for global.
    func prunedToolNames(for folderPath: String?) async -> [String] {
        let hash = folderHash(for: folderPath)
        await ensureLoaded(hash: hash)
        return (cache[hash] ?? [:]).compactMap { name, entry in
            isPruned(entry) ? name : nil
        }
    }

    /// Force-reinstates a pruned tool by zeroing its `promptsWithoutCall` and
    /// `sessions` counters, so it passes the pruning check until stats
    /// accumulate again.
    ///
    /// - Parameters:
    ///   - toolName: The qualified tool name to reinstate.
    ///   - folderPath: The active reference-folder path, or `nil` for global.
    func reinstate(_ toolName: String, folderPath: String?) async {
        let hash = folderHash(for: folderPath)
        await ensureLoaded(hash: hash)
        guard var entry = cache[hash]?[toolName] else { return }
        entry.promptsWithoutCall = 0
        entry.sessions = 0
        cache[hash]![toolName] = entry
        save(hash: hash)
    }

    // MARK: - Pruning predicate

    /// Returns `true` when `entry` meets the threshold to be excluded from
    /// the tool list offered to the model.
    ///
    /// A tool is pruned if **either** condition holds:
    /// - It has been offered for ≥ 10 consecutive prompts without a call,
    ///   across at least 2 sessions.
    /// - It has appeared in ≥ 5 sessions and has **never** been called.
    private func isPruned(_ entry: ToolUsageEntry) -> Bool {
        let condition1 = entry.promptsWithoutCall >= 10 && entry.sessions >= 2
        let condition2 = entry.sessions >= 5 && entry.totalCalls == 0
        return condition1 || condition2
    }

    // MARK: - Hashing

    /// Returns the 8-character hex prefix of the SHA-256 of `path`, or the
    /// literal string `"__global__"` when `path` is nil.
    private func folderHash(for path: String?) -> String {
        guard let path else { return "__global__" }
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    // MARK: - Persistence

    /// Returns the directory URL for the given folder hash, creating it if
    /// needed.
    private func ledgerDirectory(for hash: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".typstedit", isDirectory: true)
            .appendingPathComponent("ledger", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            return dir
        } catch {
            return nil
        }
    }

    /// Loads the on-disk ledger for `hash` into the in-memory cache, once.
    /// Subsequent calls are no-ops.
    private func ensureLoaded(hash: String) async {
        guard !loaded.contains(hash) else { return }
        loaded.insert(hash)
        guard let dir = ledgerDirectory(for: hash) else { return }
        let fileURL = dir.appendingPathComponent("tool-usage.json")
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: ToolUsageEntry].self, from: data) {
            cache[hash] = decoded
        }
    }

    /// Atomically writes the in-memory ledger for `hash` to disk.
    private func save(hash: String) {
        guard let dir = ledgerDirectory(for: hash) else { return }
        let entries = cache[hash] ?? [:]
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let fileURL = dir.appendingPathComponent("tool-usage.json")
        let tmpURL  = dir.appendingPathComponent("tool-usage.tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            // Atomic rename so a partial write never corrupts the live file.
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            // Best-effort: if the rename fails, try a direct write as fallback.
            try? data.write(to: fileURL)
        }
    }
}
