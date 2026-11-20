import Foundation

/// The on-disk store behind the recall vector cache.
///
/// ## Why it exists
///
/// Vectors used to live only in memory, so every tab switch, relaunch, or
/// memory-pressure event threw them away and the next search re-embedded the
/// whole conversation — thousands of provider calls over a chat's life for
/// text that had not changed by a single character. The engine's own comment
/// called the transcript "the persistent store"; that is true for 600
/// transcript passages and false the moment a chat has scratch notes, a
/// reference folder, or a user who comes back tomorrow.
///
/// The keys are content hashes (`ConversationRecall.key`), which is what makes
/// this worth persisting at all: a vector stays attached to the exact words it
/// was computed from, so an edit invalidates one passage instead of silently
/// re-pointing every later one.
///
/// ## Layout
///
/// ```
/// ~/Library/Application Support/TypstEdit/RecallVectors/<session id>.vec
/// ```
///
/// One file per conversation, so deleting a chat deletes its vectors and two
/// open chats never share a writable file. The format is a small binary
/// record — a JSON array of 768-float vectors per passage would be megabytes
/// of digits per chat — and it carries the embedding identity, so a file built
/// by another model can never be read as if it were this one's.
///
/// ## How it stays small
///
/// Six independent bounds, because "it cannot grow" has to survive a user who
/// chats for a year:
///
/// 1. **Per-conversation caps** on the number of passages
///    (`ConversationRecall.maxSources`, `Scratchpad.maxScratchPassages`).
/// 2. **Aging** — vectors past `embeddingPreserveDays` are stored quantized to
///    int8, a quarter of the size, which cosine ranking tolerates.
/// 3. **A global disk budget** (`maxDiskBytes`). Past it, whole conversations
///    are evicted least-recently-used first. This is the bound that actually
///    holds, because it is the only one that does not assume anything about
///    how many conversations exist.
/// 4. **A per-file size ceiling** (`maxFileBytes`), so one pathological
///    conversation cannot evict every other before the budget is checked.
/// 5. **Identity invalidation** — a file from a different embedding model is
///    deleted on sight, since no future request could use it.
/// 6. **An orphan sweep** for files whose conversation no longer exists.
///
/// Every failure mode is "delete the file": a cache that cannot be read is
/// worthless, and the transcript can always rebuild it.
final class VectorStore: @unchecked Sendable {
    static let shared = VectorStore()

    /// Total bytes of vectors kept across every conversation. At 1536
    /// dimensions a full-precision passage costs ~6 KB, so this holds roughly
    /// 16 full-size chats before the oldest is evicted; aging to int8 pushes
    /// that to ~60.
    static let defaultMaxDiskBytes = 96 * 1_024 * 1_024

    /// Ceiling for one conversation's file, well under the global budget so a
    /// single chat cannot evict all the others by itself.
    static let defaultMaxFileBytes = 24 * 1_024 * 1_024

    /// The limits this store enforces. Instance properties rather than
    /// constants so a test can shrink them and exercise the eviction rules
    /// without writing hundreds of megabytes.
    let maxDiskBytes: Int
    let maxFileBytes: Int

    /// Written at the head of every file. Checked before anything else so a
    /// file from a future format is deleted rather than misread.
    static let magic: UInt32 = 0x5450_4556  // "TPEV"
    static let version: UInt16 = 1

    /// File work runs here, never on the main actor: writing a few megabytes
    /// of vectors mid-turn would be a visible stall.
    private let queue = DispatchQueue(label: "com.tmagri.TypstEdit.vectorstore", qos: .utility)

    private let directory: URL

    init(
        directory: URL? = nil,
        maxDiskBytes: Int = VectorStore.defaultMaxDiskBytes,
        maxFileBytes: Int = VectorStore.defaultMaxFileBytes
    ) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("TypstEdit/RecallVectors", isDirectory: true)
        }
        self.maxDiskBytes = maxDiskBytes
        self.maxFileBytes = maxFileBytes
    }

    private func fileURL(_ sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).vec", isDirectory: false)
    }

    // MARK: - Reading

    /// The conversation's vectors, or `nil` when there is no file, it is
    /// unreadable, or it was built by a different embedding model.
    ///
    /// A mismatched or corrupt file is deleted here: it can never be used
    /// again, and leaving it behind only wastes the budget.
    func load(_ sessionID: UUID) async -> LoadedVectors? {
        await perform { self.loadSync(sessionID) }
    }

    private func loadSync(_ sessionID: UUID) -> LoadedVectors? {
        let url = fileURL(sessionID)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let loaded = Self.decode(data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return loaded
    }

    // MARK: - Writing

    /// Replaces the conversation's file. Evicts other conversations when the
    /// result would exceed `maxDiskBytes`, and drops the file outright when it
    /// alone would exceed `maxFileBytes` (a cache that large is a bug, not a
    /// conversation worth caching).
    @discardableResult
    func save(_ sessionID: UUID, vectors: [String: CachedVector], identity: String, dimensions: Int) async -> Bool {
        await perform {
            let encoded = Self.encode(vectors, identity: identity, dimensions: dimensions)
            guard !encoded.isEmpty, encoded.count <= self.maxFileBytes else {
                // Too big to be worth keeping. Deleting rather than skipping is
                // deliberate: a stale file would answer searches with vectors
                // that no longer describe the transcript.
                try? FileManager.default.removeItem(at: self.fileURL(sessionID))
                return false
            }
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try encoded.write(to: self.fileURL(sessionID), options: .atomic)
            } catch {
                return false
            }
            self.enforceBudgetSync(keeping: sessionID)
            return true
        }
    }

    /// Writes synchronously, blocking the caller.
    ///
    /// For `applicationWillTerminate` only: the process is about to end, so
    /// there is no later turn to finish an async write, and a cache lost at
    /// quit costs a full re-embed on the next launch.
    func saveBlocking(_ sessionID: UUID, vectors: [String: CachedVector], identity: String, dimensions: Int) {
        let encoded = Self.encode(vectors, identity: identity, dimensions: dimensions)
        guard !encoded.isEmpty, encoded.count <= maxFileBytes else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoded.write(to: fileURL(sessionID), options: .atomic)
    }

    /// Removes one conversation's vectors. Called when the chat is deleted, so
    /// a deleted conversation leaves nothing of itself behind.
    func delete(_ sessionID: UUID) async {
        await perform { try? FileManager.default.removeItem(at: self.fileURL(sessionID)) }
    }

    // MARK: - Cleanup

    /// Deletes files whose conversation no longer exists.
    ///
    /// The set of live ids is passed in rather than derived from the history
    /// folder: `ChatHistoryStore` accepts a custom directory (tests, and any
    /// future relocation), so a path guess here would sweep the wrong place.
    ///
    /// An empty set sweeps nothing. That is the safe direction: a launch that
    /// failed to read the conversation index would otherwise delete every
    /// vector the user had.
    func sweep(liveSessionIDs: Set<UUID>) async {
        guard !liveSessionIDs.isEmpty else { return }
        await perform {
            for url in self.filesSync() {
                guard let id = Self.sessionID(from: url), !liveSessionIDs.contains(id) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Enforces the global budget now. Exposed for the sweep at launch, so the
    /// first launch after a big import trims before the user notices the disk.
    func enforceBudget() async {
        await perform { self.enforceBudgetSync(keeping: nil) }
    }

    /// Deletes every cached vector. Two callers: the Settings button, and a
    /// change of embedding model — vectors from two models cannot be compared,
    /// so after a switch every file on disk is dead weight that the next
    /// launch would have to delete one by one anyway.
    func clearAll() async {
        await perform {
            for url in self.filesSync() {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Evicts least-recently-used files until the total is inside the budget.
    ///
    /// `keeping` is exempt: the file just written is the one the user is
    /// actively searching, and evicting it immediately would re-embed what we
    /// just embedded.
    private func enforceBudgetSync(keeping: UUID?) {
        var files = filesSync().compactMap { url -> (url: URL, size: Int, modified: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > self.maxDiskBytes else { return }

        // Oldest first: the conversations the user has not searched in longest
        // are the ones whose vectors are cheapest to rebuild.
        files.sort { $0.modified < $1.modified }
        for file in files where total > self.maxDiskBytes {
            guard Self.sessionID(from: file.url) != keeping else { continue }
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
        }
    }

    /// Reads a file on the calling thread. For a test that must prove a
    /// blocking write landed before it returned.
    func saveAndLoadSynchronouslyForTesting(_ sessionID: UUID) -> LoadedVectors? {
        loadSync(sessionID)
    }

    /// Bytes on disk across every conversation, for the Settings note.
    func totalBytes() async -> Int {
        await perform { self.filesSync().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) } }
    }

    /// How many conversations currently have vectors on disk.
    func fileCount() async -> Int {
        await perform { self.filesSync().count }
    }

    private func filesSync() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func sessionID(from url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Running off the main actor

    private func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Format

    struct LoadedVectors: Sendable {
        var vectors: [String: CachedVector]
        var identity: String
        var dimensions: Int
    }

    /// `CLPV`, version, dimensions, identity, count, then per vector:
    /// key, date, kind, values.
    ///
    /// The date travels with each vector so aging still works after a
    /// relaunch: a chat reopened a month later re-saves its old passages as
    /// int8 without re-embedding anything.
    nonisolated static func encode(
        _ vectors: [String: CachedVector],
        identity: String,
        dimensions: Int
    ) -> Data {
        guard dimensions > 0, dimensions <= Int(UInt16.max) else { return Data() }
        var out = Data()
        out.reserveCapacity(vectors.count * (dimensions * 4 + 64))

        // Drop anything of the wrong width *before* the count is written: the
        // count is what decode trusts to find the records, so counting
        // unfiltered entries desynchronised the file and made every subsequent
        // record unreadable.
        let writable = vectors
            .filter { $0.value.packed.count == dimensions }
            .sorted { $0.key < $1.key }

        append(magic, to: &out)
        append(version, to: &out)
        append(UInt16(dimensions), to: &out)
        appendString(identity, to: &out)
        append(UInt32(min(writable.count, Int(UInt32.max))), to: &out)

        // Sorted so the file is byte-stable for the same input, which makes a
        // cache that rewrites identical content a no-op on disk.
        for (key, entry) in writable {
            appendString(key, to: &out)
            // `timeIntervalSinceReferenceDate`, not since 1970: that is the
            // basis `Date` stores, so it round-trips bit-exactly. Converting
            // to another epoch and back loses low bits, which showed up as a
            // date that was equal to the eye but not by `==`.
            append(entry.date.timeIntervalSinceReferenceDate.bitPattern, to: &out)
            switch entry.packed {
            case .full(let vector):
                out.append(0)
                for value in vector { append(value.bitPattern, to: &out) }
            case .int8(let codes, let scale):
                out.append(1)
                for code in codes { out.append(UInt8(bitPattern: code)) }
                append(scale.bitPattern, to: &out)
            }
        }
        return out
    }

    /// `nil` for anything that is not a complete, self-consistent file of this
    /// version. The caller deletes on `nil`.
    nonisolated static func decode(_ data: Data) -> LoadedVectors? {
        var reader = Reader(data)
        guard let fileMagic = reader.u32(), fileMagic == VectorStore.magic,
              let fileVersion = reader.u16(), fileVersion == VectorStore.version,
              let dimensions = reader.u16(), dimensions > 0,
              let identity = reader.string(),
              let count = reader.u32() else { return nil }

        // A count larger than the file could possibly hold is a corrupt
        // header, not a reason to allocate for it.
        let minimumRecordBytes = 2 + 8 + 1
        guard Int(count) <= (data.count - reader.offset) / minimumRecordBytes else { return nil }

        var vectors: [String: CachedVector] = [:]
        vectors.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let key = reader.string(),
                  let dateBits = reader.u64(),
                  let kind = reader.u8() else { return nil }
            let date = Date(timeIntervalSinceReferenceDate: Double(bitPattern: dateBits))
            let packed: PackedVector
            switch kind {
            case 0:
                guard let values = reader.floats(count: Int(dimensions)) else { return nil }
                packed = .full(values)
            case 1:
                guard let codes = reader.int8s(count: Int(dimensions)),
                      let scaleBits = reader.u32() else { return nil }
                packed = .int8(codes: codes, scale: Float(bitPattern: scaleBits))
            default:
                // An unknown kind means a newer format wrote this file, and
                // the bytes after it cannot be located. Refuse the whole file.
                return nil
            }
            vectors[key] = CachedVector(packed: packed, date: date)
        }
        return LoadedVectors(vectors: vectors, identity: identity, dimensions: Int(dimensions))
    }

    // MARK: - Little-endian primitives

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Array(value.utf8.prefix(Int(UInt16.max)))
        append(UInt16(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private struct Reader {
        let data: Data
        var offset = 0

        init(_ data: Data) { self.data = data }

        private mutating func take(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func u8() -> UInt8? {
            take(1).flatMap { $0.first }
        }

        mutating func u16() -> UInt16? {
            guard let bytes = take(2) else { return nil }
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
        }

        mutating func u32() -> UInt32? {
            guard let bytes = take(4) else { return nil }
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        }

        mutating func u64() -> UInt64? {
            guard let bytes = take(8) else { return nil }
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        }

        mutating func string() -> String? {
            guard let length = u16(), let bytes = take(Int(length)) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }

        mutating func floats(count: Int) -> [Float]? {
            guard let bytes = take(count * 4) else { return nil }
            return bytes.withUnsafeBytes { raw in
                (0..<count).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
            }
        }

        mutating func int8s(count: Int) -> [Int8]? {
            guard let bytes = take(count) else { return nil }
            return bytes.map { Int8(bitPattern: $0) }
        }
    }
}

/// One cached vector and the day it was computed from. The date is what aging
/// reads, and it has to survive a relaunch, so it lives beside the vector
/// rather than being looked up from the source each time — the source may have
/// been compacted away by then.
struct CachedVector: Equatable, Sendable {
    var packed: PackedVector
    var date: Date
}
