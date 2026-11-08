import XCTest
import Foundation
import CSQLite
@testable import TypstEdit

/// Which nearest neighbours reach the model, and when a stored index may be
/// searched at all.
@MainActor
final class RAGRelevanceTests: XCTestCase {

    private func hit(_ path: String, _ text: String, _ distance: Float) -> RAGCandidate {
        RAGCandidate(path: path, text: text, distance: distance)
    }

    // MARK: - Selection

    func testHitsFarBehindTheBestAreDropped() {
        let selected = RAGRelevance.select([
            hit("c.typ", "unrelated passage", 0.6),
            hit("a.typ", "best passage", 0.2),
            hit("b.typ", "close passage", 0.45)
        ], topK: 5, maxDistance: 0.85, relativeMargin: 0.3)
        XCTAssertEqual(selected.map(\.path), ["a.typ", "b.typ"], "nearest first, and only within the margin of the best")
    }

    func testNothingIsReturnedWhenNoHitIsClose() {
        // A scan always returns k rows. When none of them is near the query,
        // injecting them would read to the model as evidence.
        let selected = RAGRelevance.select([
            hit("a.typ", "one", 0.9),
            hit("b.typ", "two", 0.95)
        ], topK: 3, maxDistance: 0.85)
        XCTAssertTrue(selected.isEmpty)
    }

    func testOneFileCannotFillEverySlot() {
        let selected = RAGRelevance.select([
            hit("long.typ", "first part", 0.10),
            hit("long.typ", "second part", 0.11),
            hit("long.typ", "third part", 0.12),
            hit("other.typ", "another file", 0.2)
        ], topK: 3, perFileCap: 2)
        XCTAssertEqual(selected.map(\.text), ["first part", "second part", "another file"])
    }

    func testDuplicateAndContainedPassagesAreDropped() {
        let selected = RAGRelevance.select([
            hit("a.typ", "The error bars show one standard deviation.", 0.1),
            hit("copy/a.typ", "the error bars   show one standard\ndeviation.", 0.11),
            hit("b.typ", "error bars show one standard", 0.12),
            hit("c.typ", "A different point entirely.", 0.2)
        ], topK: 5)
        XCTAssertEqual(selected.map(\.path), ["a.typ", "c.typ"], "whitespace/case variants and contained text are the same passage")
    }

    func testAtMostTopKAreReturned() {
        let candidates = (0..<10).map { hit("f\($0).typ", "passage \($0)", 0.1 + Float($0) * 0.01) }
        XCTAssertEqual(RAGRelevance.select(candidates, topK: 3).count, 3)
        XCTAssertTrue(RAGRelevance.select(candidates, topK: 0).isEmpty)
    }

    // MARK: - Noise floor

    func testTheCutoffFollowsTheModelsNoiseFloor() {
        // nomic-embed-text numbers: unrelated texts reach ≈ 0.42, so 0.44
        // is noise for it, though a fixed cutoff would keep it.
        let candidates = [
            hit("results.typ", "error bars", 1 - 0.530),
            hit("sampling.typ", "sampling", 1 - 0.445),
            hit("weather.md", "weather", 1 - 0.435)
        ]
        XCTAssertEqual(RAGRelevance.select(candidates, topK: 3, noiseFloor: 0.42).map(\.path), ["results.typ"])
        XCTAssertEqual(RAGRelevance.select(candidates, topK: 3).count, 3, "without a floor the fixed rules apply")
    }

    func testNothingIsKeptWhenTheBestHitIsAtTheNoiseFloor() {
        // The unrelated query from the calibration run: best hit 0.38.
        let candidates = [hit("a.typ", "a", 1 - 0.382), hit("b.typ", "b", 1 - 0.378)]
        XCTAssertTrue(RAGRelevance.select(candidates, topK: 3, noiseFloor: 0.42).isEmpty)
    }

    func testNoiseFloorIsTheNinetiethPercentileOfUnrelatedPairs() throws {
        // Orthogonal unit vectors: every pair has similarity 0.
        let vectors: [[Float]] = (0..<4).map { i in (0..<4).map { $0 == i ? 1 : 0 } }
        XCTAssertEqual(try XCTUnwrap(EmbeddingCalibration.noiseFloor(from: vectors)), 0, accuracy: 1e-6)
        XCTAssertNil(EmbeddingCalibration.noiseFloor(from: [[1, 0], [0, 1]]), "too few vectors to say")
    }

    func testRelativePathsSurviveSymlinkedProjectRoots() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("rag-real-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("rag-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try "x".write(to: real.appendingPathComponent("chapters/a.typ"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        // The project is opened through the link; the enumerator reports the real path.
        XCTAssertEqual(RAGManager.relativePath(of: real.appendingPathComponent("chapters/a.typ"), in: link), "chapters/a.typ")
        XCTAssertEqual(RAGManager.relativePath(of: link.appendingPathComponent("chapters/a.typ"), in: link), "chapters/a.typ")
    }

    // MARK: - Exact scoring

    func testCosineDistance() throws {
        XCTAssertEqual(try XCTUnwrap(RAGRelevance.cosineDistance([1, 2, 3], [2, 4, 6])), 0, accuracy: 1e-6, "same direction")
        XCTAssertEqual(try XCTUnwrap(RAGRelevance.cosineDistance([1, 0], [0, 1])), 1, accuracy: 1e-6, "orthogonal")
        XCTAssertEqual(try XCTUnwrap(RAGRelevance.cosineDistance([1, 0], [-1, 0])), 2, accuracy: 1e-6, "opposite")
        XCTAssertNil(RAGRelevance.cosineDistance([1, 0], [1, 0, 0]), "vectors from different models")
        XCTAssertNil(RAGRelevance.cosineDistance([0, 0], [1, 0]), "a zero vector has no direction")
    }

    // MARK: - Fingerprint

    private func fingerprint(model: String = "nomic-embed-text", dimensions: Int = 768, chunker: Int = EmbeddingIndexFingerprint.chunkerVersion) -> EmbeddingIndexFingerprint {
        EmbeddingIndexFingerprint(
            source: "Local (Ollama/LMStudio)",
            model: model,
            endpoint: "http://localhost:11434/v1/embeddings",
            dimensions: dimensions,
            chunkerVersion: chunker
        )
    }

    private func meta(for fingerprint: EmbeddingIndexFingerprint) -> [String: String] {
        [EmbeddingIndexFingerprint.identityKey: fingerprint.identity,
         EmbeddingIndexFingerprint.dimensionsKey: String(fingerprint.dimensions)]
    }

    func testAnEmptyDatabaseWithoutAFingerprintIsUsable() {
        XCTAssertTrue(EmbeddingIndexFingerprint.isCompatible(stored: [:], hasChunks: false, current: fingerprint()))
    }

    func testAnIndexFromBeforeFingerprintsIsRebuilt() {
        // Its model is unknown, and its dimension count was guessed.
        XCTAssertFalse(EmbeddingIndexFingerprint.isCompatible(stored: [:], hasChunks: true, current: fingerprint()))
    }

    func testOnlyTheSameModelDimensionsAndChunkerAreCompatible() {
        let built = fingerprint()
        XCTAssertTrue(EmbeddingIndexFingerprint.isCompatible(stored: meta(for: built), hasChunks: true, current: fingerprint()))
        XCTAssertFalse(EmbeddingIndexFingerprint.isCompatible(stored: meta(for: built), hasChunks: true, current: fingerprint(model: "mxbai-embed-large")))
        XCTAssertFalse(EmbeddingIndexFingerprint.isCompatible(stored: meta(for: built), hasChunks: true, current: fingerprint(dimensions: 1024)))
        XCTAssertFalse(EmbeddingIndexFingerprint.isCompatible(stored: meta(for: built), hasChunks: true, current: fingerprint(chunker: built.chunkerVersion + 1)))
    }

    func testFingerprintRoundTripsThroughTheDatabase() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, EmbeddingIndexFingerprint.createMetaSQL, nil, nil, nil), SQLITE_OK)

        let built = fingerprint()
        built.writeMeta(handle)
        // Writing twice replaces rather than duplicates.
        built.writeMeta(handle)

        let stored = EmbeddingIndexFingerprint.readMeta(handle)
        XCTAssertEqual(stored, meta(for: built))
        XCTAssertTrue(EmbeddingIndexFingerprint.isCompatible(stored: stored, hasChunks: true, current: built))
    }

    // MARK: - Tool output

    func testSemanticHitsNameTheRelativePathAndSimilarity() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let output = LocalToolExecutor.formatSemanticHits([
            DocumentChunk(fileURL: root.appendingPathComponent("chapters/intro.typ"), text: "Opening text.", embedding: [], relativePath: "chapters/intro.typ", distance: 0.25)
        ])
        XCTAssertTrue(output.contains("--- chapters/intro.typ (similarity 0.75) ---\nOpening text."))
        XCTAssertTrue(output.contains("read_file the path with offset/limit"))
    }

    func testSemanticHitsCiteLinesSectionKeywordAndStaleness() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let output = LocalToolExecutor.formatSemanticHits([
            DocumentChunk(fileURL: root.appendingPathComponent("a.typ"), text: "Bars show one SD.", embedding: [],
                          relativePath: "a.typ", distance: 0.4, startLine: 10, endLine: 14,
                          heading: "Results > Error bars", keywordMatch: true, isStale: true)
        ])
        XCTAssertTrue(output.contains("--- a.typ:10-14 · Results > Error bars (similarity 0.60, keyword match, file changed since indexed — line numbers may be off) ---"))
    }

    // MARK: - Hybrid ranking

    func testATopKeywordMatchSurvivesAWeakMeaningScore() {
        // An exact label is what embeddings miss: its meaning score is far
        // behind, but it is the best keyword match.
        let selected = RAGRelevance.select([
            hit("a.typ", "General discussion of results.", 0.30),
            RAGCandidate(path: "b.typ", text: "See <fig:error-bars> for details.", distance: 0.80, keywordRank: 0)
        ], topK: 5, maxDistance: 0.85, relativeMargin: 0.2)
        XCTAssertEqual(Set(selected.map(\.path)), ["a.typ", "b.typ"])
    }

    func testOnlyTheTopKeywordMatchesGetTheExemption() {
        let selected = RAGRelevance.select([
            hit("a.typ", "close in meaning", 0.2),
            RAGCandidate(path: "b.typ", text: "fourth keyword match", distance: 0.9, keywordRank: 3)
        ], topK: 5)
        XCTAssertEqual(selected.map(\.path), ["a.typ"])
    }

    func testAPassageMatchingInBothRankingsComesFirst() {
        let selected = RAGRelevance.select([
            hit("meaning-only.typ", "close in meaning only", 0.20),
            RAGCandidate(path: "both.typ", text: "close and says the words", distance: 0.22, keywordRank: 0)
        ], topK: 2)
        XCTAssertEqual(selected.first?.path, "both.typ")
    }

    func testDocumentChunkLocation() {
        let url = URL(fileURLWithPath: "/p/a.typ")
        XCTAssertEqual(DocumentChunk(fileURL: url, text: "", embedding: [], relativePath: "a.typ", startLine: 3, endLine: 9).location, "a.typ:3-9")
        XCTAssertEqual(DocumentChunk(fileURL: url, text: "", embedding: [], relativePath: "a.typ", startLine: 3, endLine: 3).location, "a.typ:3")
        XCTAssertEqual(DocumentChunk(fileURL: url, text: "", embedding: [], relativePath: "a.typ").location, "a.typ")
    }
}
