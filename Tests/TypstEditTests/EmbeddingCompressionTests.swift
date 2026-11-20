import XCTest
@testable import TypstEdit

/// The vector cache's memory behavior: int8 compression of old passages and
/// the retention window that decides when it happens.
@MainActor
final class EmbeddingCompressionTests: XCTestCase {

    private func vector(_ values: [Float]) -> [Float] { values }

    // MARK: - PackedVector

    func testFullVectorReportsItsOwnSize() {
        let packed = PackedVector.full(vector([0.5, -0.25, 1, 0]))
        XCTAssertEqual(packed.count, 4)
        XCTAssertEqual(packed.byteCount, 16)
    }

    func testCompressCutsMemoryToAboutAQuarter() {
        let values = (0..<768).map { Float(sin(Double($0))) }
        let full = PackedVector.full(values)
        let compressed = PackedVector.compress(values)
        XCTAssertEqual(compressed.count, 768)
        XCTAssertLessThan(compressed.byteCount, full.byteCount / 3)
        XCTAssertGreaterThan(compressed.byteCount, 700)
    }

    func testCompressedVectorPreservesCosineRanking() {
        // A query vector and three candidates; ordering must be identical
        // before and after compression, and the distances must stay close.
        let query = vector([0.9, 0.1, -0.4, 0.3, 0.0, 0.7])
        let candidates: [[Float]] = [
            vector([0.8, 0.0, -0.5, 0.2, 0.1, 0.6]),   // near
            vector([-0.7, 0.4, 0.3, -0.2, 0.9, 0.1]),  // far
            vector([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])     // empty
        ]
        var full: [Float?] = []
        var packed: [Float?] = []
        for candidate in candidates {
            full.append(RAGRelevance.cosineDistance(query, candidate))
            packed.append(PackedVector.compress(candidate).cosineDistance(to: query))
        }
        // The all-zero vector has no direction in either representation.
        XCTAssertNil(full[2])
        XCTAssertNil(packed[2])
        // Ranking is unchanged (index 0 is the near one) and the error is tiny.
        XCTAssertLessThan(full[0]!, full[1]!)
        XCTAssertLessThan(packed[0]!, packed[1]!)
        XCTAssertEqual(full[0]!, packed[0]!, accuracy: 0.01)
        XCTAssertEqual(full[1]!, packed[1]!, accuracy: 0.01)
    }

    func testCompressLeavesZeroVectorAlone() {
        // Nothing to scale: stays full precision, and distance keeps the
        // same all-zero contract.
        let packed = PackedVector.compress([0, 0, 0])
        XCTAssertEqual(packed, .full([0, 0, 0]))
        XCTAssertNil(packed.cosineDistance(to: [1, 2, 3]))
    }

    func testCompressedDistanceRejectsLengthMismatch() {
        let packed = PackedVector.compress([1, 2, 3, 4])
        XCTAssertNil(packed.cosineDistance(to: [1, 2, 3]))
    }

    // MARK: - Retention window

    private struct FixedProvider: EmbeddingProvider {
        var dimensions: Int { 4 }
        func getEmbedding(for text: String) async throws -> [Float] { [0.5, 0.25, -0.5, 0.0] }
    }

    private func compactedMessages(age: TimeInterval) -> [ChatMessage] {
        var user = ChatMessage(role: .user)
        user.text = "Question about the citation style"
        user.isCompacted = true
        user.timestamp = Date().addingTimeInterval(-age)
        var assistant = ChatMessage(role: .assistant)
        assistant.text = "You asked for APA, and the number 42719."
        assistant.isCompacted = true
        assistant.timestamp = Date().addingTimeInterval(-age)
        var live = ChatMessage(role: .user)
        live.text = "Remind me of the citations again."
        return [user, assistant, live]
    }

    /// Ages in days, which is what the retention window counts in.
    private func days(_ count: Double) -> TimeInterval { count * 86_400 }

    private func recallWithVectors(_ messages: [ChatMessage]) async -> ConversationRecall {
        let recall = ConversationRecall()
        recall.embeddingProviderOverride = FixedProvider()
        let query = "citation 42719"
        _ = await recall.search(query, messages: messages, useEmbeddings: true)
        return recall
    }

    /// Fresh passages stay full precision, and the per-vector cost matches
    /// four bytes per dimension.
    func testRecentPassagesStayFullPrecision() async {
        let settings = AISettingsManager.shared
        let original = settings.embeddingPreserveDays
        defer { settings.embeddingPreserveDays = original }
        settings.embeddingPreserveDays = 7

        let recall = await recallWithVectors(compactedMessages(age: 0))
        XCTAssertEqual(recall.cachedVectorCount, 2)
        XCTAssertEqual(recall.cachedVectorBytes, 2 * 4 * 4)
    }

    /// Passages older than the window compress, cutting the cache.
    func testOldPassagesCompress() async {
        let settings = AISettingsManager.shared
        let original = settings.embeddingPreserveDays
        defer { settings.embeddingPreserveDays = original }
        settings.embeddingPreserveDays = 7

        let fresh = await recallWithVectors(compactedMessages(age: 0))
        let old = await recallWithVectors(compactedMessages(age: days(30)))
        XCTAssertEqual(old.cachedVectorCount, fresh.cachedVectorCount)
        // A 4-dim vector's int8 form carries a scale header, so the saving
        // here is the floor of the ratio (~half); real 512/768-dim vectors
        // land near a quarter.
        XCTAssertLessThanOrEqual(old.cachedVectorBytes, fresh.cachedVectorBytes / 2)
    }

    /// "Never compress" keeps everything at full precision regardless of age.
    func testZeroDaysDisablesCompression() async {
        let settings = AISettingsManager.shared
        let original = settings.embeddingPreserveDays
        defer { settings.embeddingPreserveDays = original }
        settings.embeddingPreserveDays = 0

        let recall = await recallWithVectors(compactedMessages(age: days(365)))
        XCTAssertEqual(recall.cachedVectorBytes, 2 * 4 * 4)
    }

    /// Aging a passage mid-session compresses its already-stored full vector
    /// in place, without needing a re-embed.
    func testAgedVectorsCompressInPlace() async {
        let settings = AISettingsManager.shared
        let original = settings.embeddingPreserveDays
        defer { settings.embeddingPreserveDays = original }

        settings.embeddingPreserveDays = 0
        let messages = compactedMessages(age: days(60))
        let recall = ConversationRecall()
        recall.embeddingProviderOverride = FixedProvider()
        _ = await recall.search("citation", messages: messages, useEmbeddings: true)
        let before = recall.cachedVectorBytes
        XCTAssertEqual(before, 2 * 4 * 4)

        // Tightening the window now must compress the stored vectors.
        settings.embeddingPreserveDays = 7
        _ = await recall.search("citation", messages: messages, useEmbeddings: true)
        XCTAssertLessThanOrEqual(recall.cachedVectorBytes, before / 2)
    }

    /// Compression must not break recall quality: the same query still finds
    /// the same passage from a compressed cache.
    func testCompressedCacheStillFindsThePassage() async {
        let settings = AISettingsManager.shared
        let original = settings.embeddingPreserveDays
        defer { settings.embeddingPreserveDays = original }
        settings.embeddingPreserveDays = 0

        let recall = ConversationRecall()
        recall.embeddingProviderOverride = FixedProvider()
        let messages = compactedMessages(age: days(90))
        _ = await recall.search("citation", messages: messages, useEmbeddings: true)
        let fullOutcome = await recall.search("citation", messages: messages, useEmbeddings: true)

        settings.embeddingPreserveDays = 1
        let compressedOutcome = await recall.search("citation", messages: messages, useEmbeddings: true)

        guard case .hits(let fullHits) = fullOutcome, case .hits(let compressedHits) = compressedOutcome else {
            return XCTFail("expected hits from both caches")
        }
        XCTAssertEqual(fullHits.count, compressedHits.count)
        XCTAssertEqual(fullHits.first?.text, compressedHits.first?.text)
    }
}
