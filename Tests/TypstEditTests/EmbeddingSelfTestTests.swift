import XCTest
@testable import TypstEdit

@MainActor
final class EmbeddingSelfTestTests: XCTestCase {
    private struct HealthyProvider: EmbeddingProvider {
        var dimensions: Int { 8 }

        func getEmbedding(for text: String) async throws -> [Float] {
            let citation = text.localizedCaseInsensitiveContains("apa")
                || text.localizedCaseInsensitiveContains("citation")
                || text.localizedCaseInsensitiveContains("reference format")
                || text.localizedCaseInsensitiveContains("recommend")
            var vector = [Float](repeating: 0, count: dimensions)
            vector[citation ? 0 : 1] = 1
            vector[7] = 0.5
            return vector
        }
    }

    private struct EmptyProvider: EmbeddingProvider {
        var dimensions: Int { 0 }
        func getEmbedding(for text: String) async throws -> [Float] { [] }
    }

    private struct FlatProvider: EmbeddingProvider {
        var dimensions: Int { 4 }
        func getEmbedding(for text: String) async throws -> [Float] { [1, 0, 0, 0] }
    }

    private struct BrokenProvider: EmbeddingProvider {
        var dimensions: Int { 8 }
        func getEmbedding(for text: String) async throws -> [Float] {
            throw EmbeddingError.apiError("test failure")
        }
    }

    func testHealthyProviderPassesSemanticAndStabilityChecks() async {
        let result = await EmbeddingSelfTest.run(provider: HealthyProvider())

        XCTAssertEqual(result.status, .passed, result.details.joined(separator: "\n"))
        XCTAssertTrue(result.details.contains { $0.hasPrefix("Stability:") })
        XCTAssertTrue(result.details.contains { $0.hasPrefix("Semantic check:") })
        XCTAssertTrue(result.details.contains { $0.hasPrefix("Calibration:") })
    }

    func testEmptyProviderFailsClearly() async {
        let result = await EmbeddingSelfTest.run(provider: EmptyProvider())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.headline.contains("unusable"))
    }

    func testProviderFailureIsReported() async {
        let result = await EmbeddingSelfTest.run(provider: BrokenProvider())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.details.contains { $0.contains("test failure") })
    }

    func testWeakSemanticRankingIsReportedAsWarning() async {
        let result = await EmbeddingSelfTest.run(provider: FlatProvider())

        XCTAssertEqual(result.status, .warning)
        XCTAssertTrue(result.headline.contains("weak"))
    }
}
