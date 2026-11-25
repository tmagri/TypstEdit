import Foundation
import NaturalLanguage

// Embedding providers shared by the project RAG index and the chat engine's
// conversation recall. Ported from Clippy's `EmbeddingProvider.swift` and
// TypstEdit's own RAGManager versions (same lineage, now unified here so both
// consumers embed with the same models).

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

// MARK: - Factory (TypstEdit settings)

/// The embedding model selected in Settings, shared by the provider, the RAG
/// index fingerprint and the chat's conversation recall, so a model switch
/// invalidates every vector cache together.
@MainActor
enum EmbeddingProviderFactory {
    static func context() -> (source: ModelSource, model: String, endpoint: String, apiKey: String) {
        let ctx = AISettingsManager.shared.modelContext(for: .embedding)
        return (ctx.source, ctx.model, ctx.embeddingEndpoint, ctx.apiKey)
    }

    static func makeActiveProvider() -> EmbeddingProvider {
        let ctx = context()
        switch ctx.source {
        case .openAI:
            return GenericAPIEmbeddingProvider(
                dimensions: ctx.model.contains("large") ? 3072 : 1536,
                endpointURL: URL(string: ctx.endpoint),
                apiKey: ctx.apiKey,
                modelName: ctx.model
            )
        case .local:
            guard let url = URL(string: ctx.endpoint),
                  url.scheme?.hasPrefix("http") == true, url.host != nil else {
                return LocalEmbeddingProvider()
            }
            // The configured server first. When that server is down or
            // refuses the request, Apple's on-device embedding keeps
            // semantic recall alive instead of silently degrading to
            // keywords. A failover changes the vector length (512 vs 768+),
            // which the recall fingerprint catches — cached vectors drop
            // wholesale rather than mixing vector spaces.
            return FallbackEmbeddingProvider(
                primary: GenericAPIEmbeddingProvider(
                    dimensions: ctx.model.contains("mxbai") ? 1024 : 768,
                    endpointURL: url,
                    apiKey: ctx.apiKey,
                    modelName: ctx.model
                ),
                fallback: LocalEmbeddingProvider()
            )
        default:
            return LocalEmbeddingProvider()
        }
    }

    /// Identifies the vector space: vectors from two embedding models are
    /// not comparable, so recall drops its cache when this changes.
    static func fingerprintIdentity(dimensions: Int) -> String {
        let ctx = context()
        switch ctx.source {
        case .openAI, .local:
            return "\(ctx.source.rawValue)|\(ctx.model)|\(ctx.endpoint)|\(dimensions)"
        default:
            return "Apple NLEmbedding|sentenceEmbedding.english||\(dimensions)"
        }
    }
}

/// Tries the configured provider first; on failure falls back to Apple's
/// on-device embedding, so semantic recall survives a server that is down,
/// offline, or rejecting the key. The fingerprint guards the cache: a
/// failover's vectors are a different length (512 vs the network models'
/// 768+), so the identity changes and stale vectors drop.
struct FallbackEmbeddingProvider: EmbeddingProvider {
    let primary: EmbeddingProvider
    let fallback: LocalEmbeddingProvider

    var dimensions: Int { primary.dimensions }

    func getEmbedding(for text: String) async throws -> [Float] {
        if let vector = try? await primary.getEmbedding(for: text), !vector.isEmpty {
            return vector
        }
        return try await fallback.getEmbedding(for: text)
    }

    func getEmbeddings(for texts: [String]) async throws -> [[Float]] {
        if let vectors = try? await primary.getEmbeddings(for: texts), vectors.count == texts.count {
            return vectors
        }
        return try await fallback.getEmbeddings(for: texts)
    }
}
