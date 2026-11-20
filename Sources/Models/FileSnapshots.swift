import Foundation
import CryptoKit

/// One project file a tool call changed.
struct ProjectFileChange: Equatable {
    var relativePath: String
    var absolutePath: String
    /// The file's bytes before the call; nil when the call created it.
    var before: Data?
    /// The file's bytes after the call; nil when the call removed it.
    var after: Data?
}

/// What the transcript remembers about a file change, on the tool row that
/// made it. Metadata only: the old content lives in `FileSnapshotStore`, so
/// a chat that rewrote a long document does not carry it twice on disk.
struct FileChangeRecord: Codable, Equatable {
    var relativePath: String
    var absolutePath: String
    var existedBefore: Bool
    /// SHA-256 of what the tool wrote, so undo can tell whether the file has
    /// been changed since by something else (the user, another app). Empty
    /// means the call *removed* the file.
    var afterHash: String
    var isReverted: Bool = false
}

/// The content files had before a tool call changed them, one blob per tool
/// call: `<root>/<session id>/<tool call id>.snapshot`.
///
/// Snapshots are a convenience for undoing recent work, not a backup: they
/// are deleted with their chat and pruned after `FileRevert.retention`.
struct FileSnapshotStore {
    let root: URL

    /// `~/Library/Application Support/TypstEdit/FileSnapshots/`.
    static var defaultRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport.appendingPathComponent("TypstEdit/FileSnapshots", isDirectory: true)
    }

    init(root: URL = FileSnapshotStore.defaultRoot) {
        self.root = root
    }

    private func folder(for sessionID: UUID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func blobURL(sessionID: UUID, toolCallID: UUID) -> URL {
        folder(for: sessionID).appendingPathComponent("\(toolCallID.uuidString).snapshot")
    }

    func save(before: Data, sessionID: UUID, toolCallID: UUID) throws {
        let folder = folder(for: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try before.write(to: blobURL(sessionID: sessionID, toolCallID: toolCallID), options: .atomic)
    }

    func before(sessionID: UUID, toolCallID: UUID) -> Data? {
        try? Data(contentsOf: blobURL(sessionID: sessionID, toolCallID: toolCallID))
    }

    func remove(sessionID: UUID, toolCallIDs: some Sequence<UUID>) {
        for id in toolCallIDs {
            try? FileManager.default.removeItem(at: blobURL(sessionID: sessionID, toolCallID: id))
        }
    }

    func removeAll(sessionID: UUID) {
        try? FileManager.default.removeItem(at: folder(for: sessionID))
    }

    /// Deletes snapshots older than `age`. Run at launch so the store cannot
    /// grow without bound from chats nobody deletes.
    func prune(olderThan age: TimeInterval, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-age)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let sessions = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for session in sessions {
            let blobs = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: keys)) ?? []
            for blob in blobs {
                let modified = (try? blob.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                if modified < cutoff { try? FileManager.default.removeItem(at: blob) }
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: session.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: session)
            }
        }
    }
}

/// Undoing the file changes of a turn: which files, back to what, and
/// whether anything else touched them since.
///
/// The model follows opencode's revert. Picking a user message reverts every
/// file change made from that message to the end of the chat. Each file
/// goes back to its state before the *first* of those changes, and a file
/// a tool created is removed. Files no tool changed are left alone.
enum FileRevert {
    /// How long a change stays undoable. Matches the snapshot pruning.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    struct Entry: Equatable, Identifiable {
        var relativePath: String
        var absolutePath: String
        /// Whether the file existed before the first change being undone.
        var existedBefore: Bool
        /// The call whose snapshot holds the content to restore.
        var firstToolCallID: UUID
        /// What the last change wrote, to detect later outside edits. Empty
        /// when the last change removed the file.
        var lastAfterHash: String
        /// Every call being undone for this file, oldest first.
        var toolCallIDs: [UUID]
        var id: String { absolutePath }
    }

    struct Plan: Equatable {
        var entries: [Entry]
        var isEmpty: Bool { entries.isEmpty }
    }

    struct Outcome: Equatable {
        var restored: [String] = []
        /// Relative path and why it could not be restored.
        var failed: [(path: String, reason: String)] = []
        var revertedToolCallIDs: Set<UUID> = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.restored == rhs.restored
                && lhs.failed.map(\.path) == rhs.failed.map(\.path)
                && lhs.revertedToolCallIDs == rhs.revertedToolCallIDs
        }
    }

    /// The undoable changes from the user message `userMessageID` on.
    static func plan(messages: [ChatMessage], from userMessageID: UUID, now: Date = Date()) -> Plan {
        guard let start = messages.firstIndex(where: { $0.id == userMessageID }) else { return Plan(entries: []) }
        var entries: [Entry] = []
        var indexByPath: [String: Int] = [:]
        for message in messages[start...] {
            for record in undoableRecords(message, now: now) {
                if let index = indexByPath[record.absolutePath] {
                    entries[index].lastAfterHash = record.afterHash
                    entries[index].toolCallIDs.append(message.id)
                } else {
                    indexByPath[record.absolutePath] = entries.count
                    entries.append(Entry(
                        relativePath: record.relativePath,
                        absolutePath: record.absolutePath,
                        existedBefore: record.existedBefore,
                        firstToolCallID: message.id,
                        lastAfterHash: record.afterHash,
                        toolCallIDs: [message.id]
                    ))
                }
            }
        }
        return Plan(entries: entries)
    }

    /// For each user message whose own turn changed files, how many distinct
    /// files undoing from there would restore. Drives the transcript's
    /// "Undo file changes" buttons; computed from the transcript alone.
    static func undoableTurns(in messages: [ChatMessage], now: Date = Date()) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var turnStarts: [(id: UUID, ownsChange: Bool)] = []
        var pathsFrom: [Set<String>] = []
        for message in messages {
            if message.role == .user {
                turnStarts.append((message.id, false))
                pathsFrom.append([])
                continue
            }
            let records = undoableRecords(message, now: now)
            guard !records.isEmpty, !turnStarts.isEmpty else { continue }
            turnStarts[turnStarts.count - 1].ownsChange = true
            // A change counts for its own turn and every turn before it.
            for index in pathsFrom.indices {
                for record in records { pathsFrom[index].insert(record.absolutePath) }
            }
        }
        for (index, turn) in turnStarts.enumerated() where turn.ownsChange {
            result[turn.id] = pathsFrom[index].count
        }
        return result
    }

    /// The not-yet-reverted file changes of one tool row, while they are
    /// still young enough to undo.
    private static func undoableRecords(_ message: ChatMessage, now: Date) -> [FileChangeRecord] {
        guard message.role == .toolCall,
              now.timeIntervalSince(message.timestamp) < retention else { return [] }
        return (message.fileChanges ?? []).filter { !$0.isReverted }
    }

    /// The entries whose file is no longer what the tool last wrote — edited,
    /// replaced, or deleted since. Undoing them discards those changes, so
    /// the user is told first. A removal is unchanged while the file is
    /// still gone, and changed once something recreated it.
    static func changedSince(_ plan: Plan) -> [Entry] {
        plan.entries.filter { entry in
            if entry.lastAfterHash.isEmpty {
                return FileManager.default.fileExists(atPath: entry.absolutePath)
            }
            guard let current = FileManager.default.contents(atPath: entry.absolutePath) else { return true }
            return sha256(current) != entry.lastAfterHash
        }
    }

    /// Restores every file in the plan. A file whose snapshot is gone is
    /// reported and left as it is; the rest are still restored.
    static func apply(_ plan: Plan, store: FileSnapshotStore, sessionID: UUID) -> Outcome {
        var outcome = Outcome()
        for entry in plan.entries {
            do {
                if entry.existedBefore {
                    guard let before = store.before(sessionID: sessionID, toolCallID: entry.firstToolCallID) else {
                        outcome.failed.append((entry.relativePath, "its saved copy is no longer available"))
                        continue
                    }
                    let parent = (entry.absolutePath as NSString).deletingLastPathComponent
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    try before.write(to: URL(fileURLWithPath: entry.absolutePath), options: .atomic)
                } else if FileManager.default.fileExists(atPath: entry.absolutePath) {
                    try FileManager.default.removeItem(atPath: entry.absolutePath)
                }
                outcome.restored.append(entry.relativePath)
                outcome.revertedToolCallIDs.formUnion(entry.toolCallIDs)
            } catch {
                outcome.failed.append((entry.relativePath, error.localizedDescription))
            }
        }
        return outcome
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
