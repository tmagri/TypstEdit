import Foundation

@MainActor
enum EmbeddingSelfTest {
    struct Result: Equatable {
        enum Status: Equatable {
            case passed
            case warning
            case failed
        }

        var status: Status
        var headline: String
        var details: [String]
    }

    static let target = "The report uses APA citations in the thesis."
    static let paraphrase = "Which reference format did you recommend?"
    static let unrelated = "A sourdough recipe with an overnight autolyse."

    static func run(provider override: EmbeddingProvider? = nil) async -> Result {
        let context = AISettingsManager.shared.modelContext(for: .embedding)
        let provider = override ?? RAGManager.makeActiveProvider()
        let route = context.isLocal ? "Local server — \(context.model) at \(context.embeddingEndpoint)"
            : context.source == .openAI ? "OpenAI — \(context.model)"
            : "Apple on-device sentence embeddings"
        let texts = [target, paraphrase, unrelated]
        var details = ["Configured provider: \(route)"]

        let vectors: [[Float]]
        do {
            vectors = try await provider.getEmbeddings(for: texts)
        } catch {
            details.append("Error: \(error.localizedDescription)")
            return Result(status: .failed, headline: "Embeddings failed", details: details)
        }

        guard vectors.count == texts.count,
              let dimensions = vectors.first?.count, dimensions > 0,
              vectors.allSatisfy({ $0.count == dimensions && $0.allSatisfy(\.isFinite) }),
              vectors.allSatisfy({ $0.contains(where: { abs($0) >= .ulpOfOne }) }) else {
            details.append("The provider returned empty, non-finite, or inconsistent vectors.")
            return Result(status: .failed, headline: "Embeddings returned unusable vectors", details: details)
        }
        details.append("Vectors: \(vectors.count) texts, \(dimensions) dimensions each.")

        var status: Result.Status = .passed
        var headline = "Embeddings work"
        do {
            let first = try await provider.getEmbedding(for: target)
            let second = try await provider.getEmbedding(for: target)
            guard first.count == dimensions, second.count == dimensions,
                  let repeatDistance = RAGRelevance.cosineDistance(first, second) else {
                details.append("The repeated-text stability check returned incompatible vectors.")
                status = .warning
                headline = "Embeddings work, but stability could not be checked"
                return Result(status: status, headline: headline, details: details)
            }
            if repeatDistance > 0.01 {
                status = .warning
                headline = "Embedding results vary between calls"
                details.append("Stability: repeated text distance \(String(format: "%.4f", repeatDistance)); lower is more stable.")
            } else {
                details.append("Stability: repeated text returned the same vector.")
            }
        } catch {
            status = .warning
            headline = "Embeddings work, but the stability check failed"
            details.append("Stability check failed: \(error.localizedDescription)")
        }

        guard let paraphraseDistance = RAGRelevance.cosineDistance(vectors[0], vectors[1]),
              let unrelatedDistance = RAGRelevance.cosineDistance(vectors[2], vectors[1]) else {
            details.append("The provider's vectors could not be compared.")
            return Result(status: .failed, headline: "Embedding vectors cannot be compared", details: details)
        }
        let margin = unrelatedDistance - paraphraseDistance
        details.append("Semantic check: paraphrase distance \(String(format: "%.3f", paraphraseDistance)); unrelated distance \(String(format: "%.3f", unrelatedDistance)).")
        if margin < 0.02 {
            status = .warning
            headline = "Vectors work, but semantic ranking is weak"
            details.append("The paraphrase is not clearly closer than unrelated text; keyword search remains available.")
        }

        if let floor = await EmbeddingCalibration.measure(with: provider) {
            details.append("Calibration: noise floor \(String(format: "%.2f", floor)).")
        } else {
            if status == .passed {
                status = .warning
                headline = "Embeddings work, but calibration failed"
            }
            details.append("Calibration failed; relevance filtering will use its fallback cutoff.")
        }
        details.append("The probe was not saved or added to the project index.")
        return Result(status: status, headline: headline, details: details)
    }
}
