import Foundation

/// One candidate passage before the relevance rules are applied.
/// Copied verbatim from TypstEdit's `RAGManager.swift` — in TypstEditMacOS it
/// carries the conversation-recall results, which (keyword-only here) always
/// sit at the neutral `keywordMaxDistance`.
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
/// Copied verbatim from TypstEdit's `RAGManager.swift`.
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
    /// With a measured `noiseFloor` the cutoff follows the model's own scale:
    /// a hit must beat the similarity that unrelated texts reach, and must be
    /// at least `floorShare` of the way from that floor to the best hit.
    /// Without one, the fixed `maxDistance` and `relativeMargin` apply.
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

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Exact cosine distance, `1 - cos(a, b)`. `nil` when the lengths differ
    /// or either vector is zero.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for (x, y) in zip(a, b) {
            dot += x * y
            normA += x * x
            normB += y * y
        }
        let denominator = (normA * normB).squareRoot()
        guard denominator > 0 else { return nil }
        return 1 - dot / denominator
    }
}
