import Foundation

// Storage compression for the conversation-recall vector cache.
// Per-vector int8 scalar quantization: the transcript is the persistent
// store, so compression only has to keep cosine ranking intact, not
// survive bit-exact reloads.

/// One stored embedding vector. Fresh passages sit at full precision;
/// passages older than the Settings retention window
/// (`embeddingPreserveDays`) compress to per-vector int8 — roughly a
/// quarter of the size — which cosine ranking tolerates without measurably
/// changing which passages a query finds (each component's quantization
/// error is bounded by half a scale step, far below the relevance cutoffs'
/// margins).
///
/// `Sendable` because it is written off the main actor (`VectorStore`),
/// not only held in the recall cache's memory.
enum PackedVector: Equatable, Sendable {
    /// Full precision — what the provider returned.
    case full([Float])
    /// Symmetric per-vector int8 quantization: `value ≈ Float(code) * scale`.
    /// The scale spans the vector's own range, so nothing saturates and
    /// near-zero values stay near zero.
    case int8(codes: [Int8], scale: Float)

    var count: Int {
        switch self {
        case .full(let vector): return vector.count
        case .int8(let codes, _): return codes.count
        }
    }

    /// Approximate memory in bytes, for the settings' cache note.
    var byteCount: Int {
        switch self {
        case .full(let vector): return vector.count * 4
        case .int8(let codes, _): return codes.count + MemoryLayout<Float>.size
        }
    }

    /// Quantizes to int8. A vector with no range (all zeros, or empty) has
    /// nothing to squeeze — it stays full, and its distance keeps the same
    /// all-zero behavior as an uncompressed one.
    static func compress(_ vector: [Float]) -> PackedVector {
        guard let maxAbs = vector.map({ abs($0) }).max(), maxAbs > 0 else {
            return .full(vector)
        }
        let scale = maxAbs / 127
        let codes = vector.map { Int8(clamping: Int(($0 / scale).rounded())) }
        return .int8(codes: codes, scale: scale)
    }

    /// The cosine distance from `query` (always full precision — one
    /// freshly embedded vector) to this stored vector, converting codes as
    /// it goes rather than materializing a Float copy. `nil` when the
    /// lengths differ or the stored vector is all zeros — the same contract
    /// as `RAGRelevance.cosineDistance`.
    func cosineDistance(to query: [Float]) -> Float? {
        guard query.count == count else { return nil }
        var dot: Float = 0
        var normQuery: Float = 0
        var normStored: Float = 0
        switch self {
        case .full(let vector):
            for (x, y) in zip(query, vector) {
                dot += x * y
                normQuery += x * x
                normStored += y * y
            }
        case .int8(let codes, let scale):
            for (x, code) in zip(query, codes) {
                let y = Float(code) * scale
                dot += x * y
                normQuery += x * x
                normStored += y * y
            }
        }
        let denominator = (normQuery * normStored).squareRoot()
        guard denominator > 0 else { return nil }
        return 1 - dot / denominator
    }
}
