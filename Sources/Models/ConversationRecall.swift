import Foundation
import CryptoKit

/// Where one recallable passage came from.
///
/// Recall used to search only the transcript, so a passage's source was
/// always a message. Generalising it is what lets one index cover the
/// chat's own scratch files as well — the externalised thoughts, the
/// findings a subagent wrote, and (later) the reference folder. The cases
/// stay separate rather than collapsing to a path string because a message
/// has no line numbers and a file has no message id, and the code that
/// builds result labels needs to tell them apart.
enum RecallOrigin: Equatable {
    case message(UUID)
    /// A file passage. `path` is what the model is shown and what
    /// `scratch__read` takes; `line` is the 1-based line the passage starts
    /// on, so a hit can be followed straight to the text.
    case file(path: String, line: Int)

    /// The unit `RAGRelevance`'s per-source cap counts in — one message, or
    /// one file. A long notes file must not fill every result slot.
    var capKey: String {
        switch self {
        case .message(let id): return id.uuidString
        case .file(let path, _): return path
        }
    }

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

/// Which corpus a passage belongs to.
///
/// Kept apart from `RecallOrigin` because the consent rule is per corpus:
/// conversation text is the user's own words, while notes are text the
/// model wrote. A hit from the model's own earlier notes needs a different
/// hedge than a hit from a turn the user typed.
enum RecallCorpus: String, Equatable, Sendable {
    case conversation
    case notes
    case findings

    /// How a hit from this corpus is introduced to the model.
    var attribution: String {
        switch self {
        case .conversation: return "earlier in this conversation"
        case .notes: return "your own earlier notes in this chat"
        case .findings: return "notes a subagent wrote earlier in this chat"
        }
    }
}

/// One passage that `recall` can search: a turn, a tool result, or a slice
/// of a scratch file.
struct RecallSource: Equatable {
    /// `<origin>#<content hash>`: stable while the passage's words are
    /// unchanged, so a vector is embedded once and survives edits elsewhere
    /// in the same file. A position-based key would silently mis-map every
    /// later passage after one paragraph was inserted above it.
    let key: String
    let origin: RecallOrigin
    /// The transcript is the default so the message builders read cleanly.
    var corpus: RecallCorpus = .conversation
    /// Where the passage came from: "User, turn 3", or a tool call.
    let label: String
    let text: String
    /// 1-based line the passage starts on, for file passages. The transcript
    /// passes 0 — a message has no line numbers.
    var startLine: Int = 0
    /// When it was written — the age the retention setting
    /// (`embeddingPreserveDays`) compresses vectors on.
    let date: Date

    var embeddingInput: String { "\(label)\n\n\(text)" }
}

struct RecallHit: Equatable {
    let label: String
    let text: String
    /// `nil` when the hit came from keywords alone (no embeddings).
    let similarity: Float?
    let keywordMatch: Bool
    /// Which corpus the hit came from, so the result can say whether it is
    /// something the user said or something the model wrote itself.
    var corpus: RecallCorpus = .conversation
}

enum RecallOutcome: Equatable {
    case hits([RecallHit])
    case noMatches
    case nothingToSearch
}

/// Semantic and keyword search over the parts of one conversation that are
/// no longer in the model's context: turns folded into a compaction summary,
/// and the output of earlier tool calls (only the work log of those reaches
/// later turns).
///
/// Compaction is lossy by design. This makes it recoverable: the summary
/// says what happened, and `recall` brings back the exact words when the
/// model needs them, instead of it guessing or re-running a tool whose
/// result may not be reproducible (a web page, a script's output).
///
/// ## What gets embedded, and what never does
///
/// Only passages that have *left* the model's context:
///   - user/assistant turns folded into a compaction summary,
///   - successful tool-call outputs from before the current exchange.
/// Everything still in the prompt (the recent tail, the summary itself) is
/// never embedded — that would spend tokens on text the model already has.
/// Each message yields at most `maxPassagesPerMessage` paragraph-sized
/// passages, and the whole cache holds at most `maxSources` (newest kept).
///
/// ## Where the cache lives, and how it can't blow up
///
/// Vectors live **in memory, per conversation**, keyed by
/// `"<message id>#<passage number>"` — the transcript on disk is the
/// persistent store, and after a restart the cache rebuilds lazily in the
/// background. Worst case is `maxSources × dimensions × 4` bytes (600 ×
/// 768 × 4 ≈ 1.8 MB; 3072-dim OpenAI vectors ≈ 7 MB) — bounded by
/// construction, never grows with conversation length. Cleanup is
/// three-fold: after every embed, keys no longer in the live source set are
/// pruned; switching sessions, starting a new chat, or deleting a session
/// resets the cache outright; and the cache is dropped on system memory
/// pressure (MemoryPressureMonitor), rebuilding on the next search.
///
/// A cache is only valid for the model that built it: the fingerprint
/// (`source|model|endpoint|dimensions`) is checked on every fill, and a
/// model switch drops every vector — searching one model's vectors with
/// another's query would return confident nonsense.
///
/// ## Persistence
///
/// Vectors are written to `VectorStore` after every embed and loaded back
/// when a conversation is bound again, so a tab switch, a relaunch, or a
/// memory-pressure drop no longer re-embeds text that has not changed. The
/// content-hash keys (`RecallSource.key`) are what make that safe: a stored
/// vector stays attached to the exact words it was computed from.
///
/// The disk side is bounded by `VectorStore`'s global budget, its per-file
/// ceiling, and an LRU eviction — not by the in-memory caps alone, which say
/// nothing about how many conversations a user has.
@MainActor
final class ConversationRecall {
    nonisolated static let maxSources = 600
    nonisolated static let maxPassagesPerMessage = 12

    /// One vector per passage key, with the date it was computed from. The
    /// date is part of the cache rather than a lookup: aging has to work after
    /// a relaunch, when the passage's source row may have been compacted away
    /// and only the stored file remembers when it was written.
    private var vectors: [String: CachedVector] = [:]
    /// The embedding model the cached vectors came from.
    private var vectorIdentity: String?
    /// The last model this engine actually embedded with, kept across session
    /// binds.
    ///
    /// Needed because `vectorIdentity` is per-conversation state: it is nil
    /// for a conversation that has no cache yet, so "identity differs from
    /// nil" is not a model change — it is simply a chat with nothing cached.
    /// Treating the two the same made a session switch wipe every other
    /// conversation's vectors.
    private var lastKnownIdentity: String?
    /// The model's noise floor (`EmbeddingCalibration`) and the model it
    /// was measured for.
    private var noiseFloor: Float?
    private var noiseFloorIdentity: String?
    private var warmUp: Task<Void, Never>?
    /// Replaces the Settings provider. For tests only.
    var embeddingProviderOverride: EmbeddingProvider?
    /// Replaces the on-disk store. For tests only (a temp folder).
    var store: VectorStore = .shared

    /// The conversation these vectors belong to, and whether they have been
    /// read back from disk yet. `nil` means this cache is not bound to a
    /// conversation and never persists — which is what the standalone
    /// (test, scheduled-run) usage gets.
    private(set) var boundSessionID: UUID?
    private var needsLoad = false
    /// Set while a disk save is in flight, so a burst of embeds writes once.
    private var saveTask: Task<Void, Never>?

    private var provider: EmbeddingProvider { embeddingProviderOverride ?? EmbeddingProviderFactory.makeActiveProvider() }

    /// Tool calls whose output is not worth recalling: the plan and the case
    /// have their own prompt blocks, a question's answer is in the transcript, and recalling
    /// recall's own output would feed it back on itself.
    nonisolated static let excludedToolNames: Set<String> = [
        "\(AgentHarnessTools.namespace)__update_plan",
        AgentHarnessTools.updateCaseQualifiedName,
        "\(AgentHarnessTools.namespace)__ask_question",
        AgentHarnessTools.showUIQualifiedName,
        "\(AgentHarnessTools.namespace)__recall"
    ]

    nonisolated private static func isRecallableToolRow(_ message: ChatMessage) -> Bool {
        message.role == .toolCall
            && message.toolStatus == .succeeded
            && !(message.toolOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !excludedToolNames.contains(message.toolName ?? "")
    }

    /// Whether `recall` has anything the model cannot already see: a
    /// compacted turn, or a tool result from before the current exchange.
    nonisolated static func hasRecallableHistory(_ messages: [ChatMessage]) -> Bool {
        let lastUser = messages.lastIndex { $0.role == .user && !$0.isCompacted } ?? messages.endIndex
        return messages.indices.contains { index in
            let message = messages[index]
            if message.isCompacted, !message.isSummary, message.role != .toolCall { return true }
            return index < lastUser && isRecallableToolRow(message)
        }
    }

    /// The searchable passages, newest kept when there are too many.
    /// Uncompacted turns are left out: they are already in the prompt.
    nonisolated static func sources(from messages: [ChatMessage]) -> [RecallSource] {
        var sources: [RecallSource] = []
        var turn = 0
        for message in messages {
            if message.role == .user { turn += 1 }
            let label: String
            let text: String
            switch message.role {
            case .user, .assistant:
                guard message.isCompacted, !message.isSummary else { continue }
                label = "\(message.role == .user ? "User" : "Assistant"), turn \(max(turn, 1))"
                text = message.text
            case .screenCapture, .calculation:
                // These are part of the visible transcript; only a compacted
                // one is recallable.
                guard message.isCompacted else { continue }
                label = "\(message.role == .screenCapture ? "Screen capture" : "Calculation"), turn \(max(turn, 1))"
                text = message.text
            case .toolCall:
                guard isRecallableToolRow(message) else { continue }
                let call = AgentHarnessTools.workLogCall(message)
                label = "Result of \(call), turn \(max(turn, 1))\(message.isSubagent ? " (subagent)" : "")"
                text = message.toolOutput ?? ""
            }
            let passages = Self.passages(in: text).prefix(maxPassagesPerMessage)
            for passage in passages {
                sources.append(RecallSource(
                    key: Self.key(for: .message(message.id), text: passage),
                    origin: .message(message.id),
                    label: label,
                    text: passage,
                    date: message.timestamp
                ))
            }
        }
        return Array(sources.suffix(maxSources))
    }

    /// Splits text into paragraph-sized passages for search. The lightweight
    /// stand-in for TypstEdit's `DocumentChunker`: blank-line separated
    /// blocks, merged forward while they stay small.
    ///
    /// The size a passage aims for, and the most any passage may hold.
    nonisolated static let passageTargetChars = 1_200

    /// The cache key for one passage: its origin plus a hash of its own
    /// words.
    ///
    /// Position used to be the key (`<message id>#<passage number>`), which
    /// was safe because a written message never changes. A file does: insert
    /// one paragraph and every later passage renumbers, so every cached
    /// vector below it would be attached to the wrong text — and a
    /// mis-attached vector doesn't fail, it returns confident nonsense.
    /// Hashing the text makes a key follow its passage: appending keeps
    /// every earlier key, and editing one paragraph re-embeds exactly that
    /// paragraph.
    nonisolated static func key(for origin: RecallOrigin, text: String) -> String {
        let originKey: String
        switch origin {
        case .message(let id): originKey = id.uuidString
        case .file(let path, let line): originKey = "\(path):\(line)"
        }
        return "\(originKey)#\(contentHash(text))"
    }

    /// SHA-256 of the passage's words, normalised so a reflow of whitespace
    /// doesn't buy a pointless re-embed, truncated to keep the key readable
    /// in a debugger — 64 bits of a content hash is far past collision risk
    /// for a cache whose entries are bounded by `maxSources`.
    nonisolated static func contentHash(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Splits text into passages for search, keeping each one's 1-based
    /// starting line. The lightweight stand-in for TypstEdit's
    /// `DocumentChunker`: blank-line separated blocks, merged forward while
    /// they stay small.
    ///
    /// The line number is reported so a file hit can be shown as
    /// `notes.md:42` and followed straight to the text with
    /// `scratch__read`. It is only meaningful for files; the transcript
    /// builder ignores it.
    nonisolated static func passagesWithLines(in text: String) -> [(text: String, line: Int)] {
        let target = passageTargetChars
        var passages: [(text: String, line: Int)] = []
        var current = ""
        var currentLine = 1
        var line = 1

        func flush() {
            guard !current.isEmpty else { return }
            passages.append((current, currentLine))
            current = ""
        }

        for block in text.components(separatedBy: "\n\n") {
            let blockLines = block.components(separatedBy: "\n").count
            let blockStart = line
            line += blockLines + 1  // the blank line the split consumed
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // A leading blank line inside the block would offset the number.
            let leadingBlankLines = block.prefix { $0 == "\n" || $0 == " " || $0 == "\t" }
                .filter { $0 == "\n" }.count
            let pieceStart = blockStart + leadingBlankLines
            // Pretty-printed JSON (a Jira search, an API reply) has no blank
            // lines, so one "block" can be hundreds of thousands of
            // characters. Handed to the embedder whole, it crashed the app
            // (`std::bad_alloc` in `NLEmbedding`), so a long block is cut up.
            for piece in splitting(trimmed, limit: target) {
                if !current.isEmpty, current.count + piece.count + 2 > target {
                    flush()
                }
                if current.isEmpty { currentLine = pieceStart }
                current = current.isEmpty ? piece : current + "\n\n" + piece
            }
        }
        flush()
        return passages
    }

    /// The text-only form, for the transcript and for callers that don't
    /// care where a passage starts.
    nonisolated static func passages(in text: String) -> [String] {
        passagesWithLines(in: text).map(\.text)
    }

    /// `block` as pieces of at most `limit` characters: at line breaks where
    /// it has them, and mid-line only for a single line longer than `limit`.
    nonisolated static func splitting(_ block: String, limit: Int) -> [String] {
        guard block.count > limit else { return [block] }
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
        }
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            while rest.count > limit {
                flush()
                pieces.append(String(rest.prefix(limit)))
                rest = rest.dropFirst(limit)
            }
            if !current.isEmpty, current.count + rest.count + 1 > limit { flush() }
            current = current.isEmpty ? String(rest) : current + "\n" + rest
        }
        flush()
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Embeds the passages that have no vector yet, in the background, so
    /// the first `recall` after a compaction doesn't wait for all of them.
    func prepare(messages: [ChatMessage], extra: [RecallSource] = []) {
        guard warmUp == nil else { return }
        let sources = Self.sources(from: messages) + extra
        guard sources.contains(where: { vectors[$0.key] == nil }) else { return }
        warmUp = Task { [weak self] in
            guard let self else { return }
            await self.loadFromDiskIfNeeded()
            await self.embedMissing(sources, provider: self.provider, dimensions: nil)
            self.warmUp = nil
        }
    }

    /// What a forced build did, for the Settings button.
    struct BuildReport: Equatable {
        /// Passages the transcript offers to recall.
        var passages: Int = 0
        /// Passages that now hold a vector.
        var embedded: Int = 0
        /// Passages the provider refused or returned nothing for.
        var failed: Int = 0
        /// Vectors the cache already had (a forced rebuild re-embeds them).
        var alreadyCached: Int = 0
        /// Dimensions of the vectors, when any were produced.
        var dimensions: Int?
        /// Why the build did nothing, when it did nothing.
        var note: String?

        var isComplete: Bool { failed == 0 && passages > 0 }
    }

    /// Builds the whole recall cache now, for the conversation in front.
    ///
    /// Recall's vectors are otherwise built the first time the *model* calls
    /// `recall` (and, in the background, once something has been compacted).
    /// A long chat that was never compacted therefore sits with no vectors at
    /// all until the model happens to ask — and nothing in the UI said so.
    /// This is the button that fills the cache on demand, with a report of
    /// what actually happened.
    ///
    /// - Parameter rebuild: re-embed everything, including passages that
    ///   already hold a vector (a model switch or a bad batch leaves stale
    ///   ones behind).
    @discardableResult
    func buildCache(messages: [ChatMessage], rebuild: Bool = false) async -> BuildReport {
        var report = BuildReport()
        let sources = Self.sources(from: messages)
        report.passages = sources.count
        guard !sources.isEmpty else {
            report.note = "This conversation has nothing to embed yet: recall only indexes compacted turns and tool results from before the current exchange."
            return report
        }
        if rebuild {
            reset()
        } else {
            report.alreadyCached = sources.filter { vectors[$0.key] != nil }.count
            if report.alreadyCached == sources.count {
                report.embedded = sources.count
                report.dimensions = vectors[sources[0].key]?.packed.count
                report.note = "Every passage already had a vector."
                return report
            }
        }

        await warmUp?.value
        await loadFromDiskIfNeeded()
        let provider = self.provider
        let cutoff = Self.compressionCutoff()

        // Only the passages that are actually missing. This used to embed every
        // source and overwrite what was already cached, which spent the
        // provider calls this store exists to save — the count was reported
        // honestly as "already cached" while the work happened anyway.
        let missing = rebuild ? sources : sources.filter { vectors[$0.key] == nil }
        if missing.isEmpty {
            report.embedded = sources.count
            report.dimensions = vectors[sources[0].key]?.packed.count
            report.note = "Every passage already had a vector."
            await flushToDisk()
            return report
        }

        let results = await EmbeddingBatcher.embed(missing.map(\.embeddingInput), with: provider)
        let length = results.lazy.compactMap({ $0 }).first?.count
        if let length {
            let identity = EmbeddingProviderFactory.fingerprintIdentity(dimensions: length)
            if identity != vectorIdentity {
                vectors = [:]
                vectorIdentity = identity
                await noteModelIdentity(identity)
            }
        }
        var sizes: Set<Int> = []
        for (source, vector) in zip(missing, results) {
            guard let vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
                report.failed += 1
                continue
            }
            vectors[source.key] = CachedVector(
                packed: Self.stored(vector, forDate: source.date, cutoff: cutoff),
                date: source.date
            )
            report.embedded += 1
            sizes.insert(vector.count)
        }
        if !sizes.isEmpty {
            report.embedded += report.alreadyCached
        }
        report.dimensions = sizes.count == 1 ? sizes.first : nil
        // A mixed set of lengths would make cosine distance refuse every
        // pair, so say so instead of reporting a half-working cache.
        if sizes.count > 1 {
            report.note = "The provider returned vectors of different lengths (\(sizes.sorted().map(String.init).joined(separator: ", "))) — recall cannot compare them."
        }
        // Drop vectors for passages that no longer exist, the same prune a
        // search does, so the reported count matches the live transcript.
        let live = Set(sources.map(\.key))
        vectors = vectors.filter { live.contains($0.key) }
        // Persist here rather than relying on a caller: this is the button the
        // user pressed to fill the cache, and a cache that is only in memory
        // dies at the next relaunch — the exact waste this store exists to
        // stop.
        await flushToDisk()
        return report
    }

    /// Searches the recallable history. With `useEmbeddings` off (the user
    /// has not allowed sending text to the embedding provider) only keyword
    /// matching runs.
    ///
    /// `extra` is where other corpora join in — the chat's scratch notes,
    /// today. They are searched in the same pass as the transcript so one
    /// query ranks both together: two separate searches would each return
    /// their own best hit and the model would have no way to compare them.
    func search(
        _ query: String,
        messages: [ChatMessage],
        extra: [RecallSource] = [],
        topK: Int = 5,
        useEmbeddings: Bool
    ) async -> RecallOutcome {
        let sources = Self.sources(from: messages) + extra
        guard !sources.isEmpty else { return .nothingToSearch }

        let scores = KeywordIndex(documents: sources.map(\.embeddingInput)).scores(for: query)
        var keywordRank: [Int: Int] = [:]
        for (rank, index) in scores.indices.filter({ scores[$0] > 0 }).sorted(by: { scores[$0] > scores[$1] }).enumerated() {
            keywordRank[index] = rank
        }

        var distances = [Float?](repeating: nil, count: sources.count)
        var floor: Float?
        if useEmbeddings {
            await warmUp?.value
            let provider = self.provider
            if let queryVector = try? await provider.getEmbedding(for: query), !queryVector.isEmpty {
                await embedMissing(sources, provider: provider, dimensions: queryVector.count)
                let live = Set(sources.map(\.key))
                vectors = vectors.filter { live.contains($0.key) }
                for (index, source) in sources.enumerated() {
                    distances[index] = vectors[source.key]?.packed.cosineDistance(to: queryVector)
                }
                let identity = EmbeddingProviderFactory.fingerprintIdentity(dimensions: queryVector.count)
                if noiseFloorIdentity != identity {
                    noiseFloor = await EmbeddingCalibration.measure(with: provider)
                    noiseFloorIdentity = noiseFloor == nil ? nil : identity
                }
                floor = noiseFloor
            }
        }

        var candidates: [RAGCandidate] = []
        for (index, source) in sources.enumerated() {
            let rank = keywordRank[index]
            // Without a vector a passage can only qualify through keywords;
            // the neutral distance lets it through the keyword rule alone.
            guard let distance = distances[index] ?? (rank != nil ? RAGRelevance.keywordMaxDistance : nil) else { continue }
            candidates.append(RAGCandidate(
                path: source.origin.capKey,
                text: source.text,
                distance: distance,
                keywordRank: rank,
                startLine: source.startLine,
                sourceID: source.key
            ))
        }

        // Two sources can legitimately share a content-hash key (see the
        // note on `RecallSource.key` and `compressAgedVectors`), so this
        // must tolerate a collision rather than trap on it. Either source
        // behind a shared key carries the same text, so the pick is
        // arbitrary; `reduce` just needs to not be `uniqueKeysWithValues`.
        let byKey = sources.reduce(into: [String: RecallSource]()) { $0[$1.key] = $1 }
        let selected = RAGRelevance.select(candidates, topK: topK, noiseFloor: floor)
        let hits = selected.compactMap { candidate -> RecallHit? in
            guard let source = byKey[candidate.sourceID] else { return nil }
            let index = sources.firstIndex(of: source)
            return RecallHit(
                label: source.label,
                text: source.text,
                similarity: index.flatMap { distances[$0] }.map { 1 - $0 },
                keywordMatch: candidate.keywordRank != nil,
                corpus: source.corpus
            )
        }
        return hits.isEmpty ? .noMatches : .hits(hits)
    }

    /// Binds this cache to a conversation, loading its vectors from disk.
    ///
    /// Called when the agent shows a conversation. A switch to a *different*
    /// conversation flushes what is in memory (it belongs to the old one) and
    /// then reads the new one's file; rebinding the same conversation is a
    /// no-op, so a re-entry does not discard a cache that is already correct.
    func bind(to sessionID: UUID) async {
        guard boundSessionID != sessionID else { return }
        await flushToDisk()
        vectors = [:]
        vectorIdentity = nil
        noiseFloor = nil
        noiseFloorIdentity = nil
        boundSessionID = sessionID
        needsLoad = true
        await loadFromDiskIfNeeded()
    }

    /// Reads the bound conversation's vectors once, after a bind.
    ///
    /// A file built by a different embedding model is not just skipped but
    /// deleted: its vectors can never be compared with this model's query,
    /// so keeping it would only occupy the disk budget.
    private func loadFromDiskIfNeeded() async {
        guard needsLoad, let sessionID = boundSessionID else { return }
        needsLoad = false
        guard let loaded = await store.load(sessionID) else { return }
        guard loaded.identity == EmbeddingProviderFactory.fingerprintIdentity(dimensions: loaded.dimensions) else {
            await store.delete(sessionID)
            return
        }
        vectors = loaded.vectors
        vectorIdentity = loaded.identity
        lastKnownIdentity = loaded.identity
    }

    /// Writes the cache to disk, if it belongs to a conversation.
    ///
    /// Fire-and-forget by design: the caller is usually mid-turn, and
    /// awaiting a multi-megabyte write there would be a visible stall. Two
    /// writes never overlap — a second request while one is in flight only
    /// notes that another is wanted, and the running task picks that up.
    func saveToDisk() {
        guard let sessionID = boundSessionID, vectorIdentity != nil, !vectors.isEmpty else { return }
        saveTask?.cancel()
        let entries = vectors
        saveTask = Task { [weak self] in
            guard let self else { return }
            await self.store.save(
                sessionID,
                vectors: entries,
                identity: self.vectorIdentity ?? "",
                dimensions: entries.values.first?.packed.count ?? 0
            )
            self.saveTask = nil
        }
    }

    /// Writes and waits. Used by teardown paths (session switch, delete, app
    /// quit) and after a forced build, where the cache is about to be
    /// discarded or has just been asked for.
    ///
    /// It *awaits* the in-flight save rather than cancelling it: cancel
    /// discarded the one write that would have persisted this conversation,
    /// which is how a switch lost the cache it was supposed to keep.
    func flushToDisk() async {
        await saveTask?.value
        saveTask = nil
        guard let sessionID = boundSessionID, vectorIdentity != nil, !vectors.isEmpty else { return }
        await store.save(
            sessionID,
            vectors: vectors,
            identity: vectorIdentity ?? "",
            dimensions: vectors.values.first?.packed.count ?? 0
        )
    }

    /// Writes the cache to disk and waits for it, for app termination.
    ///
    /// Blocking on purpose: the process is ending, so the alternative is
    /// losing every vector the session computed. The write is a few megabytes
    /// at most, on the same serial queue the async path uses — but run
    /// synchronously here because there is nothing after it to await on.
    func flushToDiskBlocking() {
        saveTask?.cancel()
        saveTask = nil
        guard let sessionID = boundSessionID, vectorIdentity != nil, !vectors.isEmpty else { return }
        store.saveBlocking(
            sessionID,
            vectors: vectors,
            identity: vectorIdentity ?? "",
            dimensions: vectors.values.first?.packed.count ?? 0
        )
    }

    /// Forgets which conversation this cache belongs to, without deleting
    /// anything on disk. Used when the cache is dropped under memory pressure
    /// or the conversation is closed.
    func unbind() {
        warmUp?.cancel()
        warmUp = nil
        saveTask?.cancel()
        saveTask = nil
        boundSessionID = nil
        needsLoad = false
        vectors = [:]
        vectorIdentity = nil
        noiseFloor = nil
        noiseFloorIdentity = nil
        // `lastKnownIdentity` deliberately survives: it is what tells a real
        // model change apart from a chat that simply has no cache.
    }

    /// Embeds every source without a vector, and ages the cache: passages
    /// whose message is older than the retention setting
    /// (`embeddingPreserveDays`) store int8-quantized vectors, and full
    /// ones from before the window compress in place. `dimensions` (when
    /// known from the query) guards against storing vectors of another
    /// length.
    private func embedMissing(_ sources: [RecallSource], provider: EmbeddingProvider, dimensions: Int?) async {
        compressAgedVectors(sources: sources, cutoff: Self.compressionCutoff())
        let missing = sources.filter { vectors[$0.key] == nil }
        guard !missing.isEmpty else { return }
        let results = await EmbeddingBatcher.embed(missing.map(\.embeddingInput), with: provider)
        guard let length = dimensions ?? results.lazy.compactMap({ $0 }).first?.count else { return }
        let identity = EmbeddingProviderFactory.fingerprintIdentity(dimensions: length)
        if identity != vectorIdentity {
            vectors = [:]
            vectorIdentity = identity
            await noteModelIdentity(identity)
        }
        let cutoff = Self.compressionCutoff()
        for (source, vector) in zip(missing, results) {
            guard let vector, vector.count == length else { continue }
            vectors[source.key] = CachedVector(
                packed: Self.stored(vector, forDate: source.date, cutoff: cutoff),
                date: source.date
            )
        }
        saveToDisk()
    }

    /// The date before which stored vectors compress, from the retention
    /// setting. `nil` when set to never compress.
    private static func compressionCutoff(now: Date = Date()) -> Date? {
        let days = AISettingsManager.shared.embeddingPreserveDays
        guard days > 0 else { return nil }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Full precision inside the retention window, int8 beyond it —
    /// "compress the embeddings of old data".
    nonisolated private static func stored(_ vector: [Float], forDate date: Date, cutoff: Date?) -> PackedVector {
        guard let cutoff, date < cutoff else { return .full(vector) }
        return .compress(vector)
    }

    /// Compresses stored full-precision vectors whose passage has aged
    /// past the window, so a passage embedded fresh compresses in place as
    /// the conversation gets old instead of waiting to be re-embedded.
    private func compressAgedVectors(sources: [RecallSource], cutoff: Date?) {
        guard let cutoff else { return }
        // The source's own date wins over the stored one: a compacted turn
        // keeps its timestamp, while a file passage's stored date is when it
        // was last read. Falling back to the stored date covers a passage
        // whose source has since left the transcript, which is exactly the
        // aged case this exists for.
        //
        // `key` is a content hash (see `RecallSource.key`), so two distinct
        // sources with identical text — a repeated short message, a file
        // passage unchanged across two reads — legitimately collide. That is
        // not a bug to assert on; `uniqueKeysWithValues` would trap on the
        // very duplication the content-hash scheme is designed to produce.
        // Keep the newest date for a colliding key, since that is the one
        // most likely to still be inside the retention window.
        let dateByKey = sources.reduce(into: [String: Date]()) { result, source in
            if let existing = result[source.key] {
                result[source.key] = max(existing, source.date)
            } else {
                result[source.key] = source.date
            }
        }
        for (key, entry) in vectors {
            guard case .full(let vector) = entry.packed,
                  let date = dateByKey[key] ?? Optional(entry.date), date < cutoff else { continue }
            vectors[key] = CachedVector(packed: PackedVector.compress(vector), date: entry.date)
        }
    }

    /// Drops the whole vector cache. Called when the conversation changes
    /// (new chat, session switch, session delete) and on system memory
    /// pressure — the transcript is the persistent store, so everything
    /// rebuilds lazily on the next search at no cost beyond embedding time.
    /// Drops the in-memory cache *and* its file, for tests that need a clean
    /// slate. Production paths call `unbind()` (keep the disk copy) or
    /// `VectorStore.delete` (the chat is gone); nothing else should throw
    /// vectors away, since re-embedding is the cost this cache exists to avoid.
    func reset() {
        let sessionID = boundSessionID
        unbind()
        if let sessionID {
            Task { await store.delete(sessionID) }
        }
    }

    /// Records the model this engine is embedding with, and deletes every
    /// cached file when it is genuinely a *change* of model.
    ///
    /// Vectors from two models are not comparable — the fingerprint exists
    /// precisely so they are never mixed. `loadFromDiskIfNeeded` already
    /// refuses a file whose identity does not match, so the sweep here is the
    /// same decision made once instead of file by file at the next launch.
    ///
    /// The `lastKnownIdentity` comparison is what keeps this from firing on a
    /// mere session switch: a chat with no cache yet has no identity, and
    /// "nothing yet" is not "a different model".
    private func noteModelIdentity(_ identity: String) async {
        if let previous = lastKnownIdentity, previous != identity {
            await store.clearAll()
        }
        lastKnownIdentity = identity
    }

    /// Launch-time hygiene for the on-disk cache: delete files whose
    /// conversation no longer exists, then trim to the global budget.
    ///
    /// `liveSessionIDs` comes from the conversation index rather than a
    /// directory scan of a guessed path, because `ChatHistoryStore` accepts a
    /// custom directory. An empty list sweeps nothing — see
    /// `VectorStore.sweep`; the safe direction is keeping a cache that could
    /// have been rebuilt.
    nonisolated static func sweepStore(liveSessionIDs: Set<UUID>, store: VectorStore = .shared) async {
        await store.sweep(liveSessionIDs: liveSessionIDs)
        await store.enforceBudget()
    }

    /// Current cache size, for the settings' memory note.
    var cachedVectorCount: Int { vectors.count }

    /// How many of `sources` already hold a vector — the "x of y passages
    /// embedded" figure, which has to be scoped to the live transcript: the
    /// cache can briefly hold keys for passages a compaction has since
    /// removed.
    func cachedVectorCount(in sources: [RecallSource]) -> Int {
        sources.reduce(0) { total, source in
            total + (vectors[source.key] == nil ? 0 : 1)
        }
    }

    /// Approximate bytes the cached vectors occupy — full-precision ones at
    /// 4 bytes per dimension, compressed ones at ~1 — for the settings'
    /// memory note and the retention tests.
    var cachedVectorBytes: Int { vectors.values.reduce(0) { $0 + $1.packed.byteCount } }

    nonisolated static func format(_ outcome: RecallOutcome) -> String {
        switch outcome {
        case .nothingToSearch:
            return "Nothing to recall: every earlier turn is still in your context, and no earlier tool call returned output."
        case .noMatches:
            return "No earlier part of this conversation matches that. The compaction summary is the only record left, or the detail was never discussed."
        case .hits(let hits):
            let blocks = hits.map { hit in
                var notes: [String] = []
                if let similarity = hit.similarity { notes.append("similarity \(String(format: "%.2f", similarity))") }
                if hit.keywordMatch { notes.append("keyword match") }
                let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
                return "--- \(hit.label)\(suffix) ---\n\(hit.text)"
            }
            // Name the corpora the hits came from. A note the model wrote
            // itself is not evidence the same way a turn the user typed is,
            // and the difference has to survive into the text the model
            // reads — a rejected idea recorded in a note would otherwise
            // come back sounding like a decision.
            var sources: [String] = []
            for corpus in [RecallCorpus.conversation, .notes, .findings] where hits.contains(where: { $0.corpus == corpus }) {
                sources.append(corpus.attribution)
            }
            let provenance = sources.isEmpty ? "earlier in this conversation" : ListFormatter.localizedString(byJoining: sources)
            return blocks.joined(separator: "\n\n")
                + "\n\n(Recalled from \(provenance). Recycled text shows what was true when it was written — files may have changed, and an idea you wrote down may since have been rejected, so check before acting on it.)"
        }
    }
}
