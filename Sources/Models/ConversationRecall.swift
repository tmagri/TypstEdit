import Foundation

/// One passage of the chat history that `recall` can search.
struct RecallSource: Equatable {
    /// "<message id>#<passage number>"; stable across turns, so a vector is
    /// embedded once per passage.
    let key: String
    let messageID: UUID
    /// Where the passage came from: "User, turn 3", or the tool call.
    let label: String
    let text: String
    /// When the row happened. Drives vector aging: passages older than the
    /// retention window store int8-quantized vectors.
    let date: Date

    var embeddingInput: String { "\(label)\n\n\(text)" }
}

struct RecallHit: Equatable {
    let label: String
    let text: String
    /// `nil` when the hit came from keywords alone (no embeddings).
    let similarity: Float?
    let keywordMatch: Bool
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
/// result may not be reproducible (a web page, a script's output, a
/// subagent's report).
///
/// Vectors are kept in memory per conversation and rebuilt lazily after a
/// restart; the transcript itself is the persistent store. The computed
/// vectors additionally persist in `VectorStore` — one small binary file per
/// conversation — so reopening a chat tomorrow does not re-embed passages
/// whose words have not changed. Vectors older than the retention setting
/// (`embeddingPreserveDays`) age to int8, in memory and on disk.
@MainActor
final class ConversationRecall {
    nonisolated static let maxSources = 600
    nonisolated static let maxPassagesPerMessage = 12

    private var vectors: [String: CachedVector] = [:]
    /// The embedding model the cached vectors came from.
    private var vectorIdentity: String?
    /// The model's noise floor (`EmbeddingCalibration`) and the model it
    /// was measured for.
    private var noiseFloor: Float?
    private var noiseFloorIdentity: String?
    private var warmUp: Task<Void, Never>?
    /// The conversation this cache belongs to. Set before use; a change
    /// flushes what is in memory and loads the new conversation's file.
    private var boundSessionID: UUID?
    /// Set when the bound session changes, so the next use reads its file.
    private var needsLoad = false
    /// The in-flight background write, so two saves never overlap.
    private var saveTask: Task<Void, Never>?
    /// Replaces the shared store. For tests only.
    var store: VectorStore = .shared
    /// Replaces the Settings provider. For tests only.
    var embeddingProviderOverride: EmbeddingProvider?

    private var provider: EmbeddingProvider { embeddingProviderOverride ?? RAGManager.makeActiveProvider() }

    /// Cache size for the settings' note: how many passages are held, and
    /// the memory their vectors take (int8 passages cost about a quarter).
    var cachedVectorCount: Int { vectors.count }
    var cachedVectorBytes: Int { vectors.values.reduce(0) { $0 + $1.packed.byteCount } }

    /// Tool calls whose output is not worth recalling: the plan has its own
    /// prompt block, a question's answer is in the transcript, and recalling
    /// recall's own output would feed it back on itself.
    nonisolated static let excludedToolNames: Set<String> = [
        "\(AgentHarnessTools.namespace)__update_plan",
        "\(AgentHarnessTools.namespace)__ask_question",
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
                // An image can't be recalled as text, but the row it came from
                // should still be findable — the marker says what was shown.
                text = AIChatManager.foldedText(for: message)
            case .toolCall:
                guard isRecallableToolRow(message) else { continue }
                var call = AgentHarnessTools.workLogLine(message)
                if call.hasPrefix("- ") { call.removeFirst(2) }
                if let arrow = call.range(of: " → ") { call = String(call[..<arrow.lowerBound]) }
                label = "Result of \(call), turn \(max(turn, 1))\(message.isSubagent ? " (subagent)" : "")"
                text = message.toolOutput ?? ""
            }
            let passages = DocumentChunker.chunks(in: text, style: .none).prefix(maxPassagesPerMessage)
            for (number, passage) in passages.enumerated() {
                sources.append(RecallSource(
                    key: "\(message.id.uuidString)#\(number)", messageID: message.id,
                    label: label, text: passage.text, date: message.timestamp
                ))
            }
        }
        return Array(sources.suffix(maxSources))
    }

    /// Embeds the passages that have no vector yet, in the background, so
    /// the first `recall` after a compaction doesn't wait for all of them.
    func prepare(messages: [ChatMessage], sessionID: UUID? = nil) {
        guard warmUp == nil else { return }
        let sources = Self.sources(from: messages)
        guard sources.contains(where: { vectors[$0.key] == nil }) else { return }
        warmUp = Task { [weak self] in
            guard let self else { return }
            await self.bind(to: sessionID)
            await self.embedMissing(sources, provider: self.provider, dimensions: nil)
            self.warmUp = nil
        }
    }

    /// Searches the recallable history. With `useEmbeddings` off (the user
    /// has not allowed sending text to the embedding provider) only keyword
    /// matching runs.
    func search(_ query: String, messages: [ChatMessage], topK: Int = 5, useEmbeddings: Bool, sessionID: UUID? = nil) async -> RecallOutcome {
        let sources = Self.sources(from: messages)
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
            await bind(to: sessionID)
            let provider = self.provider
            if let queryVector = try? await provider.getEmbedding(for: query), !queryVector.isEmpty {
                await embedMissing(sources, provider: provider, dimensions: queryVector.count)
                let live = Set(sources.map(\.key))
                vectors = vectors.filter { live.contains($0.key) }
                for (index, source) in sources.enumerated() {
                    distances[index] = vectors[source.key]?.packed.cosineDistance(to: queryVector)
                }
                let identity = RAGManager.activeFingerprint(dimensions: queryVector.count).identity
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
                path: source.messageID.uuidString,
                text: source.text,
                distance: distance,
                keywordRank: rank,
                sourceID: source.key
            ))
        }

        let byKey = Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0) })
        let selected = RAGRelevance.select(candidates, topK: topK, noiseFloor: floor)
        let hits = selected.compactMap { candidate -> RecallHit? in
            guard let source = byKey[candidate.sourceID] else { return nil }
            let index = sources.firstIndex(of: source)
            return RecallHit(
                label: source.label,
                text: source.text,
                similarity: index.flatMap { distances[$0] }.map { 1 - $0 },
                keywordMatch: candidate.keywordRank != nil
            )
        }
        return hits.isEmpty ? .noMatches : .hits(hits)
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
        if missing.isEmpty {
            saveToDisk()
            return
        }
        let results = await EmbeddingBatcher.embed(missing.map(\.embeddingInput), with: provider)
        guard let length = dimensions ?? results.lazy.compactMap({ $0 }).first?.count else { return }
        let identity = RAGManager.activeFingerprint(dimensions: length).identity
        if identity != vectorIdentity {
            vectors = [:]
            vectorIdentity = identity
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

    // MARK: - Disk cache (VectorStore)

    /// Points the cache at a conversation: a change flushes what is in
    /// memory (it belongs to the old one) and then reads the new one's file;
    /// rebinding the same conversation is a no-op, so a re-entry does not
    /// discard a cache that is already correct.
    func bind(to sessionID: UUID?) async {
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
        guard loaded.identity == RAGManager.activeFingerprint(dimensions: loaded.dimensions).identity else {
            await store.delete(sessionID)
            return
        }
        vectors = loaded.vectors
        vectorIdentity = loaded.identity
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

    /// Writes and waits. Used by teardown paths (session switch), where the
    /// cache is about to be discarded.
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
        // keeps its timestamp, while a tool passage's stored date is when it
        // ran. Falling back to the stored date covers a passage whose
        // source has since left the transcript, which is exactly the aged
        // case this exists for.
        let dateByKey = Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0.date) })
        for (key, entry) in vectors {
            guard case .full(let vector) = entry.packed,
                  let date = dateByKey[key] ?? Optional(entry.date), date < cutoff else { continue }
            vectors[key] = CachedVector(packed: PackedVector.compress(vector), date: entry.date)
        }
    }

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
            return blocks.joined(separator: "\n\n")
                + "\n\n(Recalled from earlier in this conversation. Tool results show what the tool returned at the time; files may have changed since, so read_file for current content before editing.)"
        }
    }
}
