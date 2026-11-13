import Foundation
import NaturalLanguage
import Accelerate
import CryptoKit
import CSQLite
import vector
// MARK: - Precompiled Regexes

enum RAGRegex {
    static let xmlTags = try! NSRegularExpression(pattern: "<[^>]+>")
}

// MARK: - Safe SQLite bindings

/// `SQLITE_TRANSIENT` is a `#define` cast that Swift cannot import, so it has
/// to be built by hand. Internal (not `private`) so the bind-safety tests can
/// exercise the same helpers the manager uses.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binding helpers that keep the bound bytes alive until `sqlite3_step`.
///
/// Passing `nil` as the destructor means `SQLITE_STATIC`: SQLite stores the
/// raw pointer and reads it later, at `sqlite3_step`. Binding a temporary's
/// pointer that way (`sqlite3_bind_text(stmt, 1, (s as NSString).utf8String,
/// -1, nil)`) is a use-after-free — the temporary is released at the end of
/// the statement, so SQLite can read freed memory. That corrupts the heap
/// silently and intermittently, which is exactly the kind of damage that
/// surfaces later as a crash in unrelated code (a refcount write into a
/// read-only page, for example) minutes after the faulty write.
///
/// Both helpers ask SQLite to take its own copy instead, so no Swift buffer
/// outlives its own statement. Internal (not `private`) for the bind-safety
/// tests.
extension OpaquePointer {
    func bind(_ text: String, at index: Int32) {
        sqlite3_bind_text(self, index, text, -1, sqliteTransient)
    }

    /// Binds `data` as a blob. `SQLITE_TRANSIENT` copies it, so the caller's
    /// buffer only has to survive this call — an empty blob binds as zero bytes
    /// rather than a null pointer.
    func bind(blob data: Data, at index: Int32) {
        if data.isEmpty {
            sqlite3_bind_zeroblob(self, index, 0)
        } else {
            _ = data.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(self, index, rawBuffer.baseAddress, Int32(rawBuffer.count), sqliteTransient)
            }
        }
    }
}

// MARK: - Core Data Models
struct DocumentChunk: Codable {
    let fileURL: URL
    let text: String
    /// The chunk's stored embedding. Empty for results handed to callers:
    /// ranking happens inside the vector scan, so shipping the vector back
    /// only allocated and immediately freed `topK` copies of it.
    let embedding: [Float]
    /// Path relative to the project root, as stored in the index. Two files
    /// can share a name, so callers show this rather than the last component.
    var relativePath: String = ""
    /// Exact cosine distance to the query (0 = same direction, 2 = opposite).
    var distance: Float = 0
    /// Line range in the file (1-based, inclusive); 0 when unknown.
    var startLine: Int = 0
    var endLine: Int = 0
    /// The headings the passage sits under, "Results > Error bars".
    var heading: String = ""
    /// The passage also matched the query's words, not only its meaning.
    var keywordMatch: Bool = false
    /// The file changed (or was removed) after this passage was indexed, so
    /// the text and line numbers may no longer match it.
    var isStale: Bool = false

    var similarity: Float { 1 - distance }

    /// "chapters/intro.typ:10-24", or the path alone when lines are unknown.
    var location: String {
        let path = relativePath.isEmpty ? fileURL.lastPathComponent : relativePath
        guard startLine > 0 else { return path }
        return endLine > startLine ? "\(path):\(startLine)-\(endLine)" : "\(path):\(startLine)"
    }
}

/// What a semantic search produced. Kept apart from a plain hit list so a
/// caller can tell "nothing relevant" from "the index can't answer".
enum RAGSearchOutcome {
    case hits([DocumentChunk])
    /// The index was searched, but no chunk passed the relevance cutoff.
    case noRelevantHits
    /// There is no usable index: none built yet, built with another
    /// embedding model, or the query could not be embedded.
    case unavailable(String)
}

/// One candidate passage before the relevance rules are applied.
struct RAGCandidate: Equatable {
    /// The unit the per-source cap counts in: a file path, or a message id.
    let path: String
    let text: String
    /// Exact cosine distance to the query.
    let distance: Float
    /// Position in the keyword (BM25) ranking, 0 = best. `nil` when the
    /// passage did not match the query's words.
    var keywordRank: Int? = nil
    var startLine: Int = 0
    var endLine: Int = 0
    var heading: String = ""
    var indexedAt: Double = 0
    /// Caller-defined key for mapping a selected candidate back to its source.
    var sourceID: String = ""
}

/// Rules that decide which nearest neighbours are worth showing the model.
///
/// A vector scan always returns `k` rows, however unrelated they are. Without
/// a cutoff every request got three to five chunks injected even when the
/// project has nothing on the topic, which reads to the model as evidence.
///
/// The values are deliberately lenient defaults. Similarity scales differ
/// between embedding models, so the relative margin does most of the work:
/// it keeps hits that are close to the best one rather than relying on one
/// absolute number fitting every model.
enum RAGRelevance {
    /// Hits farther than this are dropped outright (similarity below 0.15).
    static let maxDistance: Float = 0.85
    /// Hits more than this far behind the best hit are dropped.
    static let relativeMargin: Float = 0.3
    /// Most chunks returned from one file, so one long document cannot fill
    /// every slot with near-duplicates of the same passage.
    static let perFileCap = 2
    /// The best keyword matches are kept even when their meaning scores
    /// low: an exact label, symbol or number is what embeddings miss most.
    static let keywordSlots = 3
    /// …unless they point the opposite way in meaning.
    static let keywordMaxDistance: Float = 1.0
    /// Reciprocal-rank-fusion constant. Larger values flatten the ranks.
    static let fusionK: Float = 60
    /// How far above the measured noise floor a hit must be at least.
    static let floorMargin: Float = 0.02
    /// Share of the gap between the noise floor and the best hit that a hit
    /// must cover. With nomic-embed-text (floor ≈ 0.42), a best hit of 0.53
    /// keeps hits down to ≈ 0.48 — the next-best passages at 0.44 were about
    /// other topics.
    static let floorShare: Float = 0.5

    /// Applies the cutoffs, the per-file cap and duplicate removal, and
    /// returns at most `topK` candidates, best first.
    ///
    /// A candidate is eligible when its meaning is close enough (within the
    /// absolute ceiling and the margin behind the best hit) or when it is
    /// one of the top keyword matches. Eligible candidates are ordered by
    /// reciprocal rank fusion of the two rankings, so a passage that both
    /// means and says the right thing comes first.
    ///
    /// With a measured `noiseFloor` (see `EmbeddingCalibration`) the cutoff
    /// follows the model's own scale: a hit must beat the similarity that
    /// unrelated texts reach, and must be at least `floorShare` of the way
    /// from that floor to the best hit. Without one, the fixed
    /// `maxDistance` and `relativeMargin` apply.
    static func select(
        _ candidates: [RAGCandidate],
        topK: Int,
        noiseFloor: Float? = nil,
        maxDistance: Float = maxDistance,
        relativeMargin: Float = relativeMargin,
        perFileCap: Int = perFileCap
    ) -> [RAGCandidate] {
        let byDistance = candidates.sorted { $0.distance < $1.distance }
        guard let best = byDistance.first?.distance, topK > 0 else { return [] }
        let ceiling: Float
        if let noiseFloor {
            let bestSimilarity = 1 - best
            let cut = max(noiseFloor + floorMargin, noiseFloor + (bestSimilarity - noiseFloor) * floorShare)
            ceiling = 1 - cut
        } else {
            ceiling = min(maxDistance, best + relativeMargin)
        }

        var fused: [(candidate: RAGCandidate, score: Float)] = []
        for (vectorRank, candidate) in byDistance.enumerated() {
            let semantic = candidate.distance <= ceiling
            let keyword = candidate.keywordRank.map { $0 < keywordSlots } ?? false
            guard semantic || (keyword && candidate.distance <= keywordMaxDistance) else { continue }
            var score = 1 / (fusionK + Float(vectorRank))
            if let rank = candidate.keywordRank { score += 1 / (fusionK + Float(rank)) }
            fused.append((candidate, score))
        }
        // Stable for equal scores: nearer in meaning first.
        let ordered = fused.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element.candidate)

        var kept: [RAGCandidate] = []
        var keptTexts: [String] = []
        var perFile: [String: Int] = [:]
        for candidate in ordered {
            guard perFile[candidate.path, default: 0] < perFileCap else { continue }
            let normalized = normalize(candidate.text)
            guard !keptTexts.contains(where: { $0.contains(normalized) || normalized.contains($0) }) else { continue }
            kept.append(candidate)
            keptTexts.append(normalized)
            perFile[candidate.path, default: 0] += 1
            if kept.count == topK { break }
        }
        return kept
    }

    /// Exact cosine distance, `1 - cos(a, b)`. The quantized scan only gives
    /// an approximation, which is fine for ranking but too noisy for a cutoff.
    /// `nil` when the lengths differ or either vector is zero.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        guard normA > 0, normB > 0 else { return nil }
        return 1 - dot / (normA.squareRoot() * normB.squareRoot())
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Index Fingerprint

/// Identifies the vector space an index was built in. Vectors from two
/// embedding models are not comparable, even when they happen to have the
/// same length, so an index is only searched with the model that built it.
struct EmbeddingIndexFingerprint: Equatable {
    /// Bump when chunking or the stored schema changes, so existing indexes
    /// are rebuilt. 2: section-aware chunks with line ranges, embedded with
    /// their file and heading path, plus the keyword table.
    static let chunkerVersion = 2

    let source: String
    let model: String
    let endpoint: String
    let dimensions: Int
    var chunkerVersion: Int = EmbeddingIndexFingerprint.chunkerVersion

    /// Everything except the dimension count, which is only known after a
    /// probe embedding. Searches compare this without making that request.
    var identity: String { "\(chunkerVersion)|\(source)|\(model)|\(endpoint)" }

    static let identityKey = "identity"
    static let dimensionsKey = "dimensions"

    /// Whether a stored index may be reused. An index with chunks but no
    /// stored fingerprint predates this check: its model is unknown and its
    /// dimension count was guessed from the model name, so it is rebuilt.
    static func isCompatible(stored: [String: String], hasChunks: Bool, current: EmbeddingIndexFingerprint) -> Bool {
        guard let identity = stored[identityKey], let dimensions = stored[dimensionsKey] else {
            return !hasChunks
        }
        return identity == current.identity && Int(dimensions) == current.dimensions
    }

    static func readMeta(_ db: OpaquePointer) -> [String: String] {
        var meta: [String: String] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM index_meta;", -1, &stmt, nil) == SQLITE_OK else { return meta }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let key = sqlite3_column_text(stmt, 0), let value = sqlite3_column_text(stmt, 1) else { continue }
            meta[String(cString: key)] = String(cString: value)
        }
        return meta
    }

    func writeMeta(_ db: OpaquePointer) {
        Self.writeMetaValue(identity, forKey: Self.identityKey, in: db)
        Self.writeMetaValue(String(dimensions), forKey: Self.dimensionsKey, in: db)
    }

    static func writeMetaValue(_ value: String, forKey key: String, in db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO index_meta (key, value) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        stmt?.bind(key, at: 1)
        stmt?.bind(value, at: 2)
        sqlite3_step(stmt)
    }

    static let createMetaSQL = "CREATE TABLE IF NOT EXISTS index_meta (key TEXT PRIMARY KEY, value TEXT);"
}

// MARK: - Schema

/// The index's tables. Internal so tests can build the same schema on a
/// plain SQLite connection (without the vector extension).
enum RAGSchema {
    static let baseSQL = """
    CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT UNIQUE,
        last_modified REAL,
        file_size INTEGER DEFAULT 0,
        content_hash TEXT DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER,
        text TEXT,
        embedding BLOB,
        start_line INTEGER DEFAULT 0,
        end_line INTEGER DEFAULT 0,
        heading TEXT DEFAULT '',
        input_hash TEXT DEFAULT '',
        FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    """

    /// Columns added after the first release. `ALTER TABLE … ADD COLUMN`
    /// fails harmlessly once a column exists.
    static let migrations = [
        "ALTER TABLE files ADD COLUMN file_size INTEGER DEFAULT 0;",
        "ALTER TABLE files ADD COLUMN content_hash TEXT DEFAULT '';",
        "ALTER TABLE chunks ADD COLUMN start_line INTEGER DEFAULT 0;",
        "ALTER TABLE chunks ADD COLUMN end_line INTEGER DEFAULT 0;",
        "ALTER TABLE chunks ADD COLUMN heading TEXT DEFAULT '';",
        "ALTER TABLE chunks ADD COLUMN input_hash TEXT DEFAULT '';"
    ]

    /// The keyword index: an FTS5 table over `chunks` (external content, so
    /// the text is stored once), kept in step by triggers. Porter stemming
    /// lets "bars" match "bar".
    static let keywordSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text, heading, content='chunks', content_rowid='id',
        tokenize='porter unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER IF NOT EXISTS chunks_fts_insert AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text, heading) VALUES (new.id, new.text, new.heading);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_fts_delete AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text, heading) VALUES ('delete', old.id, old.text, old.heading);
    END;
    """

    /// Removes a file and its chunks. Chunks are deleted explicitly rather
    /// than left to the foreign-key cascade, so the keyword trigger runs for
    /// each one whatever the connection's foreign-key setting.
    static func deleteFile(id: Int64, in db: OpaquePointer) {
        sqlite3_exec(db, "DELETE FROM chunks WHERE file_id = \(id); DELETE FROM files WHERE id = \(id);", nil, nil, nil)
    }

    /// Creates every table on `db`. Returns false when the keyword table
    /// could not be created (an SQLite built without FTS5); vector search
    /// then works alone.
    @discardableResult
    static func create(on db: OpaquePointer) -> Bool {
        sqlite3_exec(db, baseSQL, nil, nil, nil)
        for migration in migrations { sqlite3_exec(db, migration, nil, nil, nil) }
        sqlite3_exec(db, EmbeddingIndexFingerprint.createMetaSQL, nil, nil, nil)
        return sqlite3_exec(db, keywordSQL, nil, nil, nil) == SQLITE_OK
    }
}

enum EmbeddingError: LocalizedError {
    case modelUnavailable
    case generationFailed
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "Embedding model is unavailable. Check that the endpoint is running and the model is loaded."
        case .generationFailed: return "Failed to generate embedding. The response format was unexpected."
        case .apiError(let msg): return msg
        }
    }
}

// MARK: - Embedding Interface
protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    func getEmbedding(for text: String) async throws -> [Float]
    /// One vector per text, in order. Providers that can embed several texts
    /// in one request override this; the default makes one call per text.
    func getEmbeddings(for texts: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    func getEmbeddings(for texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(try await getEmbedding(for: text))
        }
        return vectors
    }
}

// MARK: - Local Provider (Apple Native)
struct LocalEmbeddingProvider: EmbeddingProvider {
    var dimensions: Int { return 512 }
    
    func getEmbedding(for text: String) async throws -> [Float] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelUnavailable
        }
        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.generationFailed
        }
        return vector.map { Float($0) }
    }
}

// MARK: - Generic API Provider (Handles OpenAI & Ollama via /v1/embeddings)
struct GenericAPIEmbeddingProvider: EmbeddingProvider {
    var dimensions: Int
    /// `nil` when the configured endpoint is not a valid URL; every request
    /// then fails with an error instead of the app crashing on a typo.
    let endpointURL: URL?
    let apiKey: String
    let modelName: String
    
    func getEmbedding(for text: String) async throws -> [Float] {
        guard let vector = try await getEmbeddings(for: [text]).first else {
            throw EmbeddingError.generationFailed
        }
        return vector
    }

    /// OpenAI's `/v1/embeddings` takes an array of inputs, and so do
    /// Ollama's and LM Studio's OpenAI-compatible endpoints. One request
    /// for a whole batch instead of one per passage.
    func getEmbeddings(for texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let endpointURL else {
            throw EmbeddingError.apiError("The embeddings endpoint is not a valid URL. Check it in Settings.")
        }
        // Embeddings often share a local server with the chat model.
        let activity = ModelServerActivity.shared.begin(endpointURL)
        defer { ModelServerActivity.shared.end(activity) }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        
        if !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let cleanTexts = texts.map { $0.replacingOccurrences(of: "\n", with: " ") }
        let body: [String: Any] = [
            "input": cleanTexts.count == 1 ? cleanTexts[0] as Any : cleanTexts as Any,
            "model": modelName
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw EmbeddingError.apiError("API failed. Make sure the endpoint is correct and running.")
        }
        return try Self.parseEmbeddings(data, expected: texts.count)
    }

    /// Reads an OpenAI-style embeddings response. Results are put back in
    /// input order by their `index`, which the API does not promise to keep.
    static func parseEmbeddings(_ data: Data, expected: Int) throws -> [[Float]] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              dataArray.count == expected else {
            throw EmbeddingError.generationFailed
        }
        var vectors = [[Float]?](repeating: nil, count: expected)
        for (position, item) in dataArray.enumerated() {
            guard let embedding = item["embedding"] as? [Double] else { throw EmbeddingError.generationFailed }
            let index = (item["index"] as? Int) ?? position
            guard vectors.indices.contains(index), vectors[index] == nil else { throw EmbeddingError.generationFailed }
            vectors[index] = embedding.map { Float($0) }
        }
        return try vectors.map { vector in
            guard let vector else { throw EmbeddingError.generationFailed }
            return vector
        }
    }
}

/// Measures where "unrelated" sits for an embedding model.
///
/// Similarity scales differ widely between models: with nomic-embed-text,
/// two texts about nothing in common still score around 0.35–0.45, while
/// OpenAI's models put them near 0.1. A fixed cutoff is either useless for
/// the first or too strict for the second. Embedding a fixed set of mutually
/// unrelated sentences once per index shows the model's own noise level.
enum EmbeddingCalibration {
    /// Deliberately about nothing in common with each other.
    static let sentences = [
        "The quick brown fox jumps over the lazy dog.",
        "Quarterly earnings beat analyst expectations.",
        "Add two cups of flour and stir gently.",
        "The train to the airport leaves every ten minutes.",
        "Photosynthesis converts light into chemical energy.",
        "She tuned the guitar before the concert.",
        "The committee postponed the vote until Friday.",
        "Glaciers carve deep valleys over thousands of years."
    ]

    /// Stored with the index; versioned so a change of method re-measures.
    static let metaKey = "noise_floor_v1"

    /// The 90th percentile of pairwise similarity between unrelated texts.
    /// `nil` with fewer than three vectors.
    static func noiseFloor(from vectors: [[Float]]) -> Float? {
        guard vectors.count >= 3 else { return nil }
        var similarities: [Float] = []
        for i in vectors.indices {
            for j in vectors.indices where j > i {
                if let distance = RAGRelevance.cosineDistance(vectors[i], vectors[j]) {
                    similarities.append(1 - distance)
                }
            }
        }
        guard !similarities.isEmpty else { return nil }
        similarities.sort()
        return similarities[Int(Double(similarities.count - 1) * 0.9)]
    }

    /// Embeds the calibration sentences (one batch request where the
    /// provider supports it) and returns the model's noise floor.
    static func measure(with provider: EmbeddingProvider) async -> Float? {
        let vectors = await EmbeddingBatcher.embed(sentences, with: provider).compactMap { $0 }
        guard vectors.count == sentences.count else { return nil }
        return noiseFloor(from: vectors)
    }
}

/// Embeds many texts with as few requests as the provider allows.
enum EmbeddingBatcher {
    static let batchSize = 32
    /// Keeps one request comfortably under typical request-size limits.
    static let maxBatchChars = 48_000

    /// One vector per text, `nil` where that text could not be embedded. A
    /// batch the server rejects is retried one text at a time, so a server
    /// without array input — or one bad passage — costs only speed, not the
    /// whole batch.
    static func embed(_ texts: [String], with provider: EmbeddingProvider) async -> [[Float]?] {
        var results = [[Float]?](repeating: nil, count: texts.count)
        var start = 0
        while start < texts.count {
            var end = start
            var chars = 0
            while end < texts.count, end - start < batchSize, end == start || chars + texts[end].count <= maxBatchChars {
                chars += texts[end].count
                end += 1
            }
            let batch = Array(texts[start..<end])
            if let vectors = try? await provider.getEmbeddings(for: batch), vectors.count == batch.count {
                for (offset, vector) in vectors.enumerated() { results[start + offset] = vector }
            } else {
                for offset in batch.indices {
                    results[start + offset] = try? await provider.getEmbedding(for: batch[offset])
                }
            }
            if Task.isCancelled { break }
            start = end
        }
        return results
    }
}

@MainActor
class RAGManager: ObservableObject {
    
    @Published var isIndexing: Bool = false
    @Published var indexProgress: Double = 0.0     
    @Published var indexStatus: String = ""      
    
    private var currentProjectDir: URL?
    private var db: OpaquePointer?
    /// The vector space the open index was built in. `nil` until a pass has
    /// set the database up.
    private var indexedFingerprint: EmbeddingIndexFingerprint?
    /// Project and database path the open connection belongs to, so a pass
    /// over the same project reuses it. Reopening `:memory:` on every pass
    /// threw the whole in-memory index away and re-embedded every file.
    private var openConnectionKey: String?
    /// Whether the connection has the FTS5 keyword table.
    private var keywordSearchAvailable = false
    /// The embedding model's measured similarity between unrelated texts,
    /// which the relevance cutoff is set against. `nil` until measured.
    private var indexNoiseFloor: Float?
    
    init() {}
    
    static func shouldUseRAG(for projectDir: URL) -> Bool {
        guard let specialDir = SafeDirectoryManager.containsSpecialDirectory(projectDir) else {
            return true
        }

        return specialDir != "backups" && specialDir != "temp" && specialDir != "vectorcaches" && specialDir != ProjectSettingsManager.dotFolderName
    }

    /// Extensions `gatherFiles` indexes. Shared with the file watcher so a
    /// A change to a file the index doesn't read, such as an image, never
    /// schedules an indexing pass.
    ///
    /// Source code is included: AI Chat searches the whole project, and the
    /// question "where is this parsed?" is as likely to point at a `.py` or
    /// `.ts` file as at the document. Other binary media stays out.
    nonisolated static let indexedFileExtensions: Set<String> = [
        "typ", "md", "markdown", "note", "json", "bib", "txt", "csv", "pdf", "yaml",
        "yml", "toml", "html", "css", "xml",
        "py", "js", "jsx", "ts", "tsx", "sh", "bash", "zsh",
        "c", "h", "cc", "cpp", "hpp", "cs", "java", "kt", "swift", "go",
        "rs", "rb", "php", "scala", "dart", "lua", "ex", "exs", "hs", "ml",
        "sql", "zig",
    ]

    /// True when editing `url` can change the semantic index.
    nonisolated static func isIndexableFile(_ url: URL) -> Bool {
        indexedFileExtensions.contains(url.pathExtension.lowercased())
    }
    
    // MARK: - Path Configuration
    
    private var cacheFolderURL: URL? {
        guard let projectDir = currentProjectDir else { return nil }
        return SafeDirectoryManager.safeVectorcachesDirectory(in: projectDir)
    }
    
    private var dbFileURL: URL? {
        if AISettingsManager.shared.cacheEmbeddingsToDisk {
            return cacheFolderURL?.appendingPathComponent("project_index.sqlite")
        }
        return nil
    }
    
    /// Replaces the Settings provider. For tests only.
    var embeddingProviderOverride: EmbeddingProvider?
    /// Path to the vector extension, ahead of the app-bundle locations. For
    /// tests only: a test runner has no app bundle to look in.
    static var vectorExtensionPathOverride: String?

    private var activeProvider: EmbeddingProvider { embeddingProviderOverride ?? Self.makeActiveProvider() }

    /// The embedding provider selected in Settings. Shared with the chat's
    /// conversation recall, which embeds with the same model.
    static func makeActiveProvider() -> EmbeddingProvider {
        let ctx = AISettingsManager.shared.modelContext(for: .embedding)

        switch ctx.source {
        case .openAI:
            return GenericAPIEmbeddingProvider(
                dimensions: ctx.model.contains("large") ? 3072 : 1536,
                endpointURL: URL(string: ctx.embeddingEndpoint),
                apiKey: ctx.apiKey,
                modelName: ctx.model
            )
            
        case .local:
            return GenericAPIEmbeddingProvider(
                dimensions: ctx.model.contains("mxbai") ? 1024 : 768,
                endpointURL: URL(string: ctx.embeddingEndpoint),
                apiKey: ctx.apiKey,
                modelName: ctx.model
            )
            
        default:
            return LocalEmbeddingProvider()
        }
    }

    private func currentFingerprint(dimensions: Int) -> EmbeddingIndexFingerprint {
        Self.activeFingerprint(dimensions: dimensions)
    }

    /// The fingerprint of the embedding model currently selected in Settings.
    static func activeFingerprint(dimensions: Int) -> EmbeddingIndexFingerprint {
        let ctx = AISettingsManager.shared.modelContext(for: .embedding)
        switch ctx.source {
        case .openAI, .local:
            return EmbeddingIndexFingerprint(
                source: ctx.source.rawValue,
                model: ctx.model,
                endpoint: ctx.embeddingEndpoint,
                dimensions: dimensions
            )
        default:
            return EmbeddingIndexFingerprint(
                source: "Apple NLEmbedding",
                model: "sentenceEmbedding.english",
                endpoint: "",
                dimensions: dimensions
            )
        }
    }
    
    // MARK: - Database Management
    
    private func setupDatabase(fingerprint: EmbeddingIndexFingerprint) {
         guard let projectDir = currentProjectDir else {
            print("Standalone mode active: Aborting vector database setup.")
            return
        }

        guard Self.shouldUseRAG(for: projectDir) else {
            print("RAGManager: Skipping vector DB setup for protected directory \(projectDir.path)")
            return
        }
        
        if let folderURL = cacheFolderURL, AISettingsManager.shared.cacheEmbeddingsToDisk {
            if !FileManager.default.fileExists(atPath: folderURL.path) {
                try? SafeDirectoryManager.createDirectorySafely(at: folderURL, withIntermediateDirectories: true)
            }
        }
        
        // Use :memory: if dbFileURL is nil (though our guard above makes this safer)
        let dbPath = dbFileURL?.path ?? ":memory:"
        let connectionKey = projectDir.path + "|" + dbPath

        if db != nil, openConnectionKey == connectionKey, indexedFingerprint == fingerprint {
            return
        }
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        openConnectionKey = nil
        indexedFingerprint = nil
        indexNoiseFloor = nil

        guard openConnection(at: dbPath) else { return }

        // An index built with another embedding model (or one too old to
        // say) is in a different vector space: searching it with this
        // model's query vectors returns confident nonsense. Start over.
        if let db {
            let stored = EmbeddingIndexFingerprint.readMeta(db)
            if !EmbeddingIndexFingerprint.isCompatible(stored: stored, hasChunks: Self.hasChunks(db), current: fingerprint) {
                print("[RAG] Index was built with a different embedding model or chunker. Rebuilding it.")
                sqlite3_close(db)
                self.db = nil
                if dbPath != ":memory:" {
                    try? FileManager.default.removeItem(atPath: dbPath)
                }
                guard openConnection(at: dbPath) else { return }
            }
        }
        guard let db else { return }

        fingerprint.writeMeta(db)
        indexNoiseFloor = EmbeddingIndexFingerprint.readMeta(db)[EmbeddingCalibration.metaKey].flatMap(Float.init)
        sqlite3_exec(db, "SELECT vector_init('chunks', 'embedding', 'type=FLOAT32,dimension=\(fingerprint.dimensions),distance=COSINE');", nil, nil, nil)
        sqlite3_exec(db, "SELECT vector_quantize_preload('chunks', 'embedding');", nil, nil, nil)
        indexedFingerprint = fingerprint
        openConnectionKey = connectionKey
    }

    /// `fileURL` relative to `root`, the key the index stores. Both sides are
    /// resolved first: the file enumerator reports `/private/var/…` for a
    /// project opened as `/var/…`, and a plain prefix strip then produced
    /// keys like "/privatechapters/a.typ" — every file looked deleted on the
    /// next pass and the whole project was re-embedded.
    nonisolated static func relativePath(of fileURL: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    /// Identifies an embedding input, so an unchanged passage can keep its vector.
    nonisolated static func inputHash(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored vectors of one file, keyed by embedding-input hash.
    private func storedVectors(forFile fileId: Int64, in db: OpaquePointer, dimensions: Int) -> [String: Data] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT input_hash, embedding FROM chunks WHERE file_id = ? AND input_hash != '';", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        var vectors: [String: Data] = [:]
        let expectedBytes = dimensions * MemoryLayout<Float>.size
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hash = sqlite3_column_text(stmt, 0),
                  Int(sqlite3_column_bytes(stmt, 1)) == expectedBytes,
                  let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            vectors[String(cString: hash)] = Data(bytes: bytes, count: expectedBytes)
        }
        return vectors
    }

    private static func hasChunks(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM chunks LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Opens `dbPath`, loads the vector extension and creates the tables.
    /// Returns false when the database cannot be opened.
    private func openConnection(at dbPath: String) -> Bool {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Failed to open vector DB.")
            sqlite3_close(db)
            db = nil
            return false
        }
        
        sqlite3_enable_load_extension(db, 1)
        var errMsg: UnsafeMutablePointer<Int8>?
        // Packaged apps keep vector.framework in Contents/Frameworks (the
        // standard location, on the app's rpath). Older bundles placed it
        // next to the executable, so keep that as a fallback.
        let candidates = [
            Self.vectorExtensionPathOverride,
            Bundle.main.privateFrameworksURL?
                .appendingPathComponent("vector.framework/vector").path,
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("vector.framework/vector").path,
        ].compactMap { $0 }
        let vectorExtPath = candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? candidates.first ?? "vector.framework/vector"
        if sqlite3_load_extension(db, vectorExtPath, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            print("Failed to load sqlite-vector: \(msg)")
            sqlite3_free(errMsg)
        }
        
        if let db {
            keywordSearchAvailable = RAGSchema.create(on: db)
            if !keywordSearchAvailable {
                print("[RAG] Keyword index unavailable (SQLite without FTS5); using vector search only.")
            }
        }
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return true
    }
    // MARK: - Standalone Mode Management
    
    /// Completely disables the RAG Manager and closes any active DB connections for standalone editing.
    public func disableForStandaloneMode() {
        self.currentProjectDir = nil
        
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        openConnectionKey = nil
        indexedFingerprint = nil
        indexNoiseFloor = nil
        
        // Reset any indexing state just in case it was interrupted
        isIndexing = false
        indexProgress = 0.0
        indexStatus = ""
        
        print("RAGManager: Vector DB locked out and closed for standalone mode.")
    }
    
    public func clearIndexCache() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        openConnectionKey = nil
        indexedFingerprint = nil
        indexNoiseFloor = nil
        
        if let fileURL = dbFileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
            print("Project vector db cleared successfully.")
        } else {
            print("In-memory vector db cleared successfully.")
        }
    }
    
    // MARK: - Indexing
    
    func indexProject(at projectDir: URL, forceReindex: Bool = false) async {
        let isDirectory = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else {
            print("RAGManager: Aborting index. Provided URL is a standalone file, not a directory.")
            return
        }

        guard !isIndexing else { return }
        isIndexing = true
        indexProgress = 0.0
        indexStatus = "Gathering files..."
        
        defer { 
            isIndexing = false 
            indexStatus = ""
            indexProgress = 0.0
        }
        
        guard Self.shouldUseRAG(for: projectDir) else {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
            openConnectionKey = nil
            indexedFingerprint = nil
            indexNoiseFloor = nil
            self.currentProjectDir = nil
            isIndexing = false
            indexProgress = 0.0
            indexStatus = "RAG disabled for protected directory"
            print("RAGManager: Skipping indexing for protected directory \(projectDir.path)")
            return
        }

        self.currentProjectDir = projectDir
        
        if forceReindex {
            clearIndexCache()
        }

        // The vector length comes from the model itself. Guessing it from the
        // model name ("large" → 3072, "mxbai" → 1024, else 768) was wrong for
        // most local models, and every insert then had the wrong size.
        let provider = activeProvider
        let dimensions: Int
        do {
            dimensions = try await provider.getEmbedding(for: "TypstEdit embedding probe").count
        } catch {
            print("[RAG] Embedding model unavailable, index not updated: \(error.localizedDescription)")
            return
        }
        guard dimensions > 0 else { return }

        setupDatabase(fingerprint: currentFingerprint(dimensions: dimensions))
        guard let db = db else { return }

        if indexNoiseFloor == nil, let floor = await EmbeddingCalibration.measure(with: provider) {
            indexNoiseFloor = floor
            EmbeddingIndexFingerprint.writeMetaValue(String(floor), forKey: EmbeddingCalibration.metaKey, in: db)
        }

        // `gatherFiles` walks the whole tree and `contentsOfDirectory`-style
        // enumeration is blocking I/O. On the main actor it stalled the UI for
        // the duration of every indexing pass — including the automatic ones
        // the file watcher triggers. Walk off the actor and only come back
        // with the list.
        indexStatus = "Checking index..."
        let filesToProcess = await Task.detached(priority: .utility) {
            Self.gatherFiles(in: projectDir)
        }.value
        var cacheUpdated = false

        let cleanupSQL = "SELECT id, path FROM files;"
        var cleanupStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cleanupSQL, -1, &cleanupStmt, nil) == SQLITE_OK {
            var idsToDelete: [Int64] = []
            while sqlite3_step(cleanupStmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(cleanupStmt, 0)
                let path = String(cString: sqlite3_column_text(cleanupStmt, 1))
                let fullURL = projectDir.appendingPathComponent(path)
                
                if !FileManager.default.fileExists(atPath: fullURL.path) {
                    idsToDelete.append(id)
                }
            }
            sqlite3_finalize(cleanupStmt)
            
            if !idsToDelete.isEmpty {
                sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
                for id in idsToDelete {
                    RAGSchema.deleteFile(id: id, in: db)
                }
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                print("Cleaned up \(idsToDelete.count) deleted files from vector DB.")
            }
        }
        
        let totalFiles = filesToProcess.count
        guard totalFiles > 0 else { return }
        
        for (index, fileURL) in filesToProcess.enumerated() {
            guard isIndexing else { break }
            
            self.indexProgress = Double(index) / Double(totalFiles)
            self.indexStatus = "Indexing \(fileURL.lastPathComponent)..."
            
            let ext = fileURL.pathExtension.lowercased()
            let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let lastModifiedDate = resourceValues?.contentModificationDate else { continue }
            let lastModified = lastModifiedDate.timeIntervalSince1970
            let currentFileSize = Int64(resourceValues?.fileSize ?? 0)
            
            let fileKey = Self.relativePath(of: fileURL, in: projectDir)
            
            var needsIndexing = true
            var fileId: Int64 = -1
            
            // Step 1: Fast metadata check (size + mtime) — free, no I/O
            let checkSQL = "SELECT id, last_modified, file_size, content_hash FROM files WHERE path = ?;"
            var checkStmt: OpaquePointer?
            var storedHash = ""
            if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
                checkStmt?.bind(fileKey, at: 1)
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    fileId = sqlite3_column_int64(checkStmt, 0)
                    let storedModified = sqlite3_column_double(checkStmt, 1)
                    let storedSize = sqlite3_column_int64(checkStmt, 2)
                    storedHash = sqlite3_column_text(checkStmt, 3).map { String(cString: $0) } ?? ""
                    
                    if storedSize == currentFileSize && storedModified >= lastModified {
                        // Metadata matches exactly — skip without reading the file
                        needsIndexing = false
                    }
                }
            }
            sqlite3_finalize(checkStmt)
            
            if !needsIndexing { continue }
            
            // Step 2: Metadata differed — compute SHA-256 hash to confirm real content change
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            let newHash = SHA256.hash(data: fileData)
                .compactMap { String(format: "%02x", $0) }.joined()
            
            if !storedHash.isEmpty && storedHash == newHash {
                // Content is identical despite metadata change (e.g. git checkout, copy).
                // Just update the metadata columns to avoid hashing again next sync.
                let updateMetaSQL = "UPDATE files SET last_modified = ?, file_size = ? WHERE id = ?;"
                var updateMetaStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, updateMetaSQL, -1, &updateMetaStmt, nil) == SQLITE_OK {
                    sqlite3_bind_double(updateMetaStmt, 1, lastModified)
                    sqlite3_bind_int64(updateMetaStmt, 2, currentFileSize)
                    sqlite3_bind_int64(updateMetaStmt, 3, fileId)
                    sqlite3_step(updateMetaStmt)
                }
                sqlite3_finalize(updateMetaStmt)
                print("[RAG] \(fileURL.lastPathComponent): metadata changed but content unchanged — skipping re-embed.")
                continue
            }
            
            // Content actually changed (or new file) — fall through to re-index.

            let passages: [TextChunk]
            if ext == "pdf" {
                self.indexStatus = "Reading PDF \(fileURL.lastPathComponent)..."
                var importer = PDFImporter(
                    sourceURL: fileURL,
                    outputDirectory: fileURL.deletingLastPathComponent(),
                    baseName: fileURL.deletingPathExtension().lastPathComponent
                )
                importer.options.extractFigures = false
                importer.options.writeAssets = false
                importer.options.removeRunningHeaders = false
                importer.options.useAI = false
                importer.aiTarget = nil
                do {
                    let converted = try await importer.run()
                    passages = DocumentChunker.chunks(in: converted.markdown, fileExtension: "md")
                } catch {
                    print("[RAG Error] \(fileURL.lastPathComponent): PDF conversion failed; "
                        + "the file will be retried next pass. \(error.localizedDescription)")
                    continue
                }
            } else if ext == "json" {
                let json = try? JSONSerialization.jsonObject(with: fileData)
                passages = json.map {
                    DocumentChunker.unlinedChunks(extractSemanticChunks(from: $0, fileName: fileURL.lastPathComponent))
                } ?? []
            } else {
                passages = DocumentChunker.chunks(in: TextFileEncoding.decode(fileData).text, fileExtension: ext)
            }
            let inputs = passages.map { $0.embeddingInput(path: fileKey) }
            let inputHashes = inputs.map(Self.inputHash)

            // Most saves change a paragraph or two. Passages whose embedding
            // input is unchanged keep their stored vector, so only the edited
            // ones cost an embedding request.
            let reusable = fileId != -1 ? storedVectors(forFile: fileId, in: db, dimensions: dimensions) : [:]
            var vectors: [Data?] = inputHashes.map { reusable[$0] }
            let missing = vectors.indices.filter { vectors[$0] == nil }
            if !missing.isEmpty {
                self.indexStatus = "Embedding \(fileURL.lastPathComponent) (\(missing.count) passage\(missing.count == 1 ? "" : "s"))..."
                let fresh = await EmbeddingBatcher.embed(missing.map { inputs[$0] }, with: provider)
                for (offset, index) in missing.enumerated() {
                    guard let vector = fresh[offset], vector.count == dimensions else { continue }
                    vectors[index] = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                }
            }
            let embeddingFailed = vectors.contains { $0 == nil }
            if embeddingFailed {
                print("[RAG Error] \(fileURL.lastPathComponent): \(vectors.filter { $0 == nil }.count) passage(s) could not be embedded; the file is retried next pass.")
            }
            guard isIndexing else { break }

            // Embedding happens before the transaction, so the database is
            // never held locked across network requests.
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)

            if fileId != -1 {
                RAGSchema.deleteFile(id: fileId, in: db)
            }

            let insertFileSQL = "INSERT INTO files (path, last_modified, file_size, content_hash) VALUES (?, ?, ?, ?);"
            var insertFileStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertFileSQL, -1, &insertFileStmt, nil) == SQLITE_OK {
                insertFileStmt?.bind(fileKey, at: 1)
                // A file with missing passages must not look up to date, or an
                // endpoint outage during one pass leaves it out of the index
                // until the file happens to change again.
                sqlite3_bind_double(insertFileStmt, 2, embeddingFailed ? 0 : lastModified)
                sqlite3_bind_int64(insertFileStmt, 3, currentFileSize)
                insertFileStmt?.bind(embeddingFailed ? "" : newHash, at: 4)
                if sqlite3_step(insertFileStmt) == SQLITE_DONE {
                    fileId = sqlite3_last_insert_rowid(db)
                }
            }
            sqlite3_finalize(insertFileStmt)

            let insertChunkSQL = "INSERT INTO chunks (file_id, text, embedding, start_line, end_line, heading, input_hash) VALUES (?, ?, ?, ?, ?, ?, ?);"
            var insertChunkStmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertChunkSQL, -1, &insertChunkStmt, nil)
            for (index, passage) in passages.enumerated() {
                guard let vectorData = vectors[index] else { continue }
                sqlite3_bind_int64(insertChunkStmt, 1, fileId)
                insertChunkStmt?.bind(passage.text, at: 2)
                insertChunkStmt?.bind(blob: vectorData, at: 3)
                sqlite3_bind_int64(insertChunkStmt, 4, Int64(passage.startLine))
                sqlite3_bind_int64(insertChunkStmt, 5, Int64(passage.endLine))
                insertChunkStmt?.bind(passage.headingPath, at: 6)
                insertChunkStmt?.bind(inputHashes[index], at: 7)
                sqlite3_step(insertChunkStmt)
                sqlite3_reset(insertChunkStmt)
            }
            sqlite3_finalize(insertChunkStmt)

            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            cacheUpdated = true
        }
        
        if isIndexing {
            self.indexProgress = 1.0
            self.indexStatus = "Finishing up..."
            
            if cacheUpdated {
                print("Local project vector db updated successfully.")
                // Build a TurboQuant index to significantly speed up searches
                sqlite3_exec(db, "SELECT vector_quantize('chunks', 'embedding', 'qtype=TURBO');", nil, nil, nil)
            } else {
                print("Using cached embeddings from local vectorcaches folder.")
            }
        }
    }

    nonisolated private static func gatherFiles(in projectDir: URL) -> [URL] {
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        var validFiles: [URL] = []
        
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            
            // Exclude the vector cache, temp build, rotating backups, and
            // TypstEdit project-config (.typstedit/ — skills, mcp.json, etc.)
            // directories from indexing.
            if isDirectory && (filename == "vectorcaches" || filename == "temp" || filename == "backups" || filename == ProjectSettingsManager.dotFolderName) {
                enumerator.skipDescendants()
                continue
            }
            
            if isDirectory { continue }
            
            if let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, fileSize > 50 * 1024 * 1024 {
                continue
            }
            
            let ext = fileURL.pathExtension.lowercased()
            if indexedFileExtensions.contains(ext) {
                validFiles.append(fileURL)
            }
        }
        
        return validFiles
    }
    
    // MARK: - Searching

    /// The nearest chunks that pass `RAGRelevance`, or an empty list. For
    /// callers that only inject context and have no use for the reason.
    func search(query: String, topK: Int = 3, excluding excludeURL: URL? = nil) async -> [DocumentChunk] {
        if case .hits(let chunks) = await searchOutcome(query: query, topK: topK, excluding: excludeURL) {
            return chunks
        }
        return []
    }

    func searchOutcome(query: String, topK: Int = 3, excluding excludeURL: URL? = nil) async -> RAGSearchOutcome {
        guard let db = db, let currentProjectDir = currentProjectDir, let indexed = indexedFingerprint else {
            return .unavailable("the project has not been indexed yet")
        }
        // Settings may have switched the embedding model since the index was
        // built. Its query vectors would be compared against another model's.
        guard currentFingerprint(dimensions: indexed.dimensions).identity == indexed.identity else {
            return .unavailable("the index was built with a different embedding model; it is rebuilt on the next indexing pass")
        }

        // The DB stores paths relative to the project root. Convert the URL to match.
        let excludedPath = excludeURL.map { Self.relativePath(of: $0, in: currentProjectDir) }

        // Fetch more than will be shown: the relevance rules drop weak,
        // duplicate and same-file hits, and the WHERE clause drops the
        // excluded file after the scan has picked its `k`.
        let fetchLimit = max(topK * 4, 12) + (excludedPath != nil ? 5 : 0)

        let queryVector: [Float]
        do {
            queryVector = try await activeProvider.getEmbedding(for: query)
        } catch {
            print("Search failed: \(error)")
            return .unavailable("the query could not be embedded (\(error.localizedDescription))")
        }
        guard queryVector.count == indexed.dimensions else {
            return .unavailable("the embedding model returned \(queryVector.count) values, the index expects \(indexed.dimensions)")
        }

        var byID: [Int64: RAGCandidate] = [:]
        for row in vectorRows(db: db, query: queryVector, limit: fetchLimit, excluding: excludedPath) {
            byID[row.id] = row.candidate
        }
        // Keyword matches the vector scan did not reach are scored exactly
        // too, so the same relevance rules apply to both.
        if keywordSearchAvailable, let expression = KeywordQuery.ftsExpression(for: query) {
            for (rank, row) in keywordRows(db: db, expression: expression, query: queryVector, limit: max(topK * 2, 8), excluding: excludedPath).enumerated() {
                var candidate = byID[row.id] ?? row.candidate
                candidate.keywordRank = rank
                byID[row.id] = candidate
            }
        }

        let selected = RAGRelevance.select(Array(byID.values), topK: topK, noiseFloor: indexNoiseFloor)
        guard !selected.isEmpty else { return .noRelevantHits }
        return .hits(selected.map { candidate in
            let fileURL = currentProjectDir.appendingPathComponent(candidate.path)
            return DocumentChunk(
                fileURL: fileURL,
                text: candidate.text,
                embedding: [],
                relativePath: candidate.path,
                distance: candidate.distance,
                startLine: candidate.startLine,
                endLine: candidate.endLine,
                heading: candidate.heading,
                keywordMatch: candidate.keywordRank != nil,
                isStale: Self.changedSinceIndexed(fileURL, indexedAt: candidate.indexedAt)
            )
        })
    }

    /// True when the file is gone or was modified after the indexed copy.
    /// The watcher re-indexes within seconds of a save, but a search can land
    /// in between, and line numbers from a stale passage point at the wrong
    /// text.
    private static func changedSinceIndexed(_ url: URL, indexedAt: Double) -> Bool {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return true
        }
        return indexedAt <= 0 || modified.timeIntervalSince1970 > indexedAt + 1
    }

    private typealias CandidateRow = (id: Int64, candidate: RAGCandidate)

    private static let candidateColumns = "c.id, c.text, f.path, c.embedding, c.start_line, c.end_line, c.heading, f.last_modified"

    /// Nearest neighbours by meaning. The quantized scan ranks; its
    /// distances are approximate, so each row is re-scored exactly.
    private func vectorRows(db: OpaquePointer, query: [Float], limit: Int, excluding excludedPath: String?) -> [CandidateRow] {
        let whereClause = excludedPath != nil ? "WHERE f.path != ?" : ""
        func sql(_ scan: String) -> String {
            """
            SELECT \(Self.candidateColumns)
            FROM chunks AS c
            JOIN files AS f ON c.file_id = f.id
            JOIN \(scan)('chunks', 'embedding', ?, ?) AS v
            ON c.id = v.rowid
            \(whereClause)
            ORDER BY v.distance ASC
            LIMIT \(limit);
            """
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql("vector_quantize_scan"), -1, &stmt, nil) != SQLITE_OK {
            // Fallback to brute-force full scan if quantization index isn't built yet
            if sqlite3_prepare_v2(db, sql("vector_full_scan"), -1, &stmt, nil) != SQLITE_OK {
                print("Search query prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
        }
        defer { sqlite3_finalize(stmt) }
        stmt?.bind(blob: query.withUnsafeBufferPointer { Data(buffer: $0) }, at: 1)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        if let excludedPath { stmt?.bind(excludedPath, at: 3) }
        return Self.readCandidates(stmt, query: query)
    }

    /// Passages that contain the query's words, best BM25 score first. The
    /// heading column counts double: a term in the section title is a
    /// strong signal.
    private func keywordRows(db: OpaquePointer, expression: String, query: [Float], limit: Int, excluding excludedPath: String?) -> [CandidateRow] {
        let exclusion = excludedPath != nil ? "AND f.path != ?" : ""
        let sql = """
        SELECT \(Self.candidateColumns)
        FROM chunks_fts
        JOIN chunks AS c ON c.id = chunks_fts.rowid
        JOIN files AS f ON c.file_id = f.id
        WHERE chunks_fts MATCH ? \(exclusion)
        ORDER BY bm25(chunks_fts, 1.0, 2.0)
        LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("Keyword query prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        stmt?.bind(expression, at: 1)
        if let excludedPath { stmt?.bind(excludedPath, at: 2) }
        return Self.readCandidates(stmt, query: query)
    }

    /// Reads rows in `candidateColumns` order, scoring each stored vector
    /// against `query`. Rows whose vector has the wrong size are skipped.
    private static func readCandidates(_ stmt: OpaquePointer?, query: [Float]) -> [CandidateRow] {
        var rows: [CandidateRow] = []
        let expectedBytes = query.count * MemoryLayout<Float>.size
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard Int(sqlite3_column_bytes(stmt, 3)) == expectedBytes,
                  let bytes = sqlite3_column_blob(stmt, 3) else { continue }
            // Copied rather than reinterpreted: SQLite does not promise the
            // blob is aligned for Float.
            var stored = [Float](repeating: 0, count: query.count)
            _ = stored.withUnsafeMutableBytes { memcpy($0.baseAddress!, bytes, expectedBytes) }
            guard let distance = RAGRelevance.cosineDistance(query, stored) else { continue }
            let heading = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            rows.append((
                id: sqlite3_column_int64(stmt, 0),
                candidate: RAGCandidate(
                    path: String(cString: sqlite3_column_text(stmt, 2)),
                    text: String(cString: sqlite3_column_text(stmt, 1)),
                    distance: distance,
                    startLine: Int(sqlite3_column_int64(stmt, 4)),
                    endLine: Int(sqlite3_column_int64(stmt, 5)),
                    heading: heading,
                    indexedAt: sqlite3_column_double(stmt, 7)
                )
            ))
        }
        return rows
    }
    
    // MARK: - Helpers
    
    private func flattenJSON(_ json: Any, prefix: String = "") -> [String] {
        var result: [String] = []
        
        if let dict = json as? [String: Any] {
            for (key, value) in dict {
                let newPrefix = prefix.isEmpty ? key : "\(prefix) > \(key)"
                result.append(contentsOf: flattenJSON(value, prefix: newPrefix))
            }
        } else if let array = json as? [Any] {
            for (index, value) in array.enumerated() {
                let newPrefix = "\(prefix) [\(index)]"
                result.append(contentsOf: flattenJSON(value, prefix: newPrefix))
            }
        } else if let str = json as? String {
            if !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append("\(prefix): \(str)")
            }
        } else {
            result.append("\(prefix): \(json)")
        }
        
        return result
    }

    private func extractSemanticChunks(from json: Any, path: String = "", parentMetadata: String = "", fileName: String) -> [String] {
        var chunks: [String] = []
        
        if let dict = json as? [String: Any] {
            var localMetadata = parentMetadata
            
            for (key, value) in dict {
                if let str = value as? String, str.count < 50 {
                    localMetadata += "\(key.capitalized): \(str), "
                } else if let num = value as? NSNumber {
                    localMetadata += "\(key.capitalized): \(num), "
                } else if let bool = value as? Bool {
                    localMetadata += "\(key.capitalized): \(bool), "
                }
            }
            
            for (key, value) in dict {
                let currentPath = path.isEmpty ? key : "\(path) > \(key)"
                
                if let str = value as? String, str.count >= 50 {
                    let cleanText = RAGRegex.xmlTags.stringByReplacingMatches(in: str, options: [], range: NSRange(0..<str.utf16.count), withTemplate: "")
                    let chunk = "Source: \(fileName) | Path: \(currentPath)\nContext: \(localMetadata)\nContent: \(cleanText)"
                    chunks.append(chunk)
                } else if let nestedDict = value as? [String: Any] {
                    chunks.append(contentsOf: extractSemanticChunks(from: nestedDict, path: currentPath, parentMetadata: localMetadata, fileName: fileName))
                } else if let nestedArray = value as? [Any] {
                    chunks.append(contentsOf: extractSemanticChunks(from: nestedArray, path: currentPath, parentMetadata: localMetadata, fileName: fileName))
                }
            }
        } else if let array = json as? [Any] {
            for (index, value) in array.enumerated() {
                let currentPath = "\(path)[\(index)]"
                chunks.append(contentsOf: extractSemanticChunks(from: value, path: currentPath, parentMetadata: parentMetadata, fileName: fileName))
            }
        } else if let str = json as? String, str.count >= 50 {
            let cleanText = RAGRegex.xmlTags.stringByReplacingMatches(in: str, options: [], range: NSRange(0..<str.utf16.count), withTemplate: "")
            let chunk = "Source: \(fileName) | Path: \(path)\nContext: \(parentMetadata)\nContent: \(cleanText)"
            chunks.append(chunk)
        }
        
        return chunks
    }

    private func chunkStrings(_ strings: [String], maxChunkSize: Int) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        
        for string in strings {
            if currentChunk.count + string.count > maxChunkSize {
                chunks.append(currentChunk)
                currentChunk = ""
            }
            currentChunk += string + "\n"
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }
        return chunks
    }
}