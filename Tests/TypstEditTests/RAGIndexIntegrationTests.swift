import XCTest
import Foundation
@testable import TypstEdit

/// Drives the real index — the vector extension, the quantized scan, the
/// keyword table — on a temporary project. Skipped when the extension
/// binary has not been built yet.
@MainActor
final class RAGIndexIntegrationTests: XCTestCase {
    private var project: URL!

    override func setUp() async throws {
        guard let path = Self.vectorExtensionPath() else {
            throw XCTSkip("vector.framework not found under .build — build the package first")
        }
        RAGManager.vectorExtensionPathOverride = path
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("rag-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("chapters"), withIntermediateDirectories: true)
        try write("chapters/results.typ", """
        = Results

        == Error bars
        Error bars show one standard deviation of the mean across all sites.

        == Sampling
        Forty sites were sampled along the valley floor during the dry season.
        """)
        try write("notes.md", """
        # Weather
        Spring weather was mild and dry on most days of the survey.
        """)
    }

    override func tearDown() async throws {
        RAGManager.vectorExtensionPathOverride = nil
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    private func write(_ relative: String, _ text: String, modifiedOffset: TimeInterval = 0) throws {
        let url = project.appendingPathComponent(relative)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if modifiedOffset != 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(modifiedOffset)], ofItemAtPath: url.path)
        }
    }

    private func hits(_ outcome: RAGSearchOutcome, file: StaticString = #filePath, line: UInt = #line) -> [DocumentChunk] {
        guard case .hits(let chunks) = outcome else {
            XCTFail("expected hits, got \(outcome)", file: file, line: line)
            return []
        }
        return chunks
    }

    func testSearchReturnsSectionsWithLinesAndKeywordMatches() async throws {
        let rag = RAGManager()
        rag.embeddingProviderOverride = HashingEmbeddingProvider()
        await rag.indexProject(at: project)

        let semantic = hits(await rag.searchOutcome(query: "error bars standard deviation", topK: 3))
        let top = try XCTUnwrap(semantic.first)
        XCTAssertEqual(top.relativePath, "chapters/results.typ")
        XCTAssertEqual(top.heading, "Results > Error bars")
        XCTAssertEqual(top.location, "chapters/results.typ:4")
        XCTAssertFalse(top.isStale)

        let keyword = hits(await rag.searchOutcome(query: "valley", topK: 3))
        XCTAssertTrue(keyword.contains { $0.heading == "Results > Sampling" && $0.keywordMatch })

        // Excluding the file removes its passages, as AI Prompt does for the open document.
        let excluded = await rag.search(query: "error bars", topK: 3, excluding: project.appendingPathComponent("chapters/results.typ"))
        XCTAssertFalse(excluded.contains { $0.relativePath == "chapters/results.typ" })
    }

    func testAnEditReEmbedsOnlyTheChangedPassages() async throws {
        let provider = HashingEmbeddingProvider()
        let rag = RAGManager()
        rag.embeddingProviderOverride = provider
        await rag.indexProject(at: project)
        let firstPass = provider.embeddedTexts.count
        XCTAssertEqual(firstPass, 1 + EmbeddingCalibration.sentences.count + 3, "probe, calibration, and one embedding per passage")

        try write("notes.md", """
        # Weather
        Spring weather was mild and dry on most days of the survey.

        # Wind
        Winds came mostly from the north west in the afternoons.
        """, modifiedOffset: 30)

        // Before the next pass, hits from the edited file are flagged.
        let stale = hits(await rag.searchOutcome(query: "spring weather mild", topK: 3))
        XCTAssertTrue(stale.first { $0.relativePath == "notes.md" }?.isStale ?? false)
        let beforeSecondPass = provider.embeddedTexts.count

        await rag.indexProject(at: project)
        let secondPass = Array(provider.embeddedTexts.dropFirst(beforeSecondPass))
        XCTAssertEqual(secondPass.count, 2, "the probe and the one new passage; the unchanged one keeps its vector: \(secondPass)")
        XCTAssertTrue(secondPass.last?.contains("Winds came mostly") ?? false)

        let fresh = hits(await rag.searchOutcome(query: "winds north west", topK: 3))
        XCTAssertEqual(fresh.first?.heading, "Wind")
        XCTAssertFalse(fresh.first?.isStale ?? true)
    }

    func testRecallRanksByMeaningAndReusesVectors() async throws {
        let provider = HashingEmbeddingProvider()
        let recall = ConversationRecall()
        recall.embeddingProviderOverride = provider
        let messages = [
            ChatMessage(role: .user, text: "Cite every dataset with its DOI and the access date.", isCompacted: true),
            ChatMessage(role: .assistant, text: "Will do — DOIs and access dates for every dataset.", isCompacted: true),
            ChatMessage(role: .user, text: "Make the figures greyscale so they print well.", isCompacted: true),
            ChatMessage(role: .user, text: "Carry on with chapter three.")
        ]

        let outcome = await recall.search("dataset citation DOI", messages: messages, useEmbeddings: true)
        guard case .hits(let hits) = outcome else { return XCTFail("expected hits, got \(outcome)") }
        XCTAssertTrue(hits.first?.text.contains("DOI") ?? false)
        XCTAssertNotNil(hits.first?.similarity)
        XCTAssertFalse(hits.contains { $0.text.contains("greyscale") }, "an unrelated instruction is not recalled")

        // A second search embeds only the query: passages keep their vectors,
        // and the noise floor is measured once per model.
        let before = provider.embeddedTexts.count
        _ = await recall.search("figures print", messages: messages, useEmbeddings: true)
        XCTAssertEqual(provider.embeddedTexts.count - before, 1)
    }

    /// Runs against a local Ollama `nomic-embed-text` when one is listening,
    /// and prints the similarities, which is how the relevance cutoffs are
    /// calibrated. Skipped otherwise.
    func testWithALocalEmbeddingModel() async throws {
        let provider = GenericAPIEmbeddingProvider(
            dimensions: 768,
            endpointURL: URL(string: "http://localhost:11434/v1/embeddings"),
            apiKey: "",
            modelName: "nomic-embed-text"
        )
        guard (try? await provider.getEmbedding(for: "probe")) != nil else {
            throw XCTSkip("no local nomic-embed-text at localhost:11434")
        }
        let rag = RAGManager()
        rag.embeddingProviderOverride = provider
        await rag.indexProject(at: project)

        // A paraphrase with none of the passage's words.
        let paraphrase = hits(await rag.searchOutcome(query: "how much do the measurements vary", topK: 3))
        print("[calibration] paraphrase:", paraphrase.map { "\($0.heading) \(String(format: "%.3f", $0.similarity))" })
        XCTAssertEqual(paraphrase.first?.heading, "Results > Error bars")

        let unrelated = await rag.searchOutcome(query: "recipe for chocolate cake with buttercream icing", topK: 3)
        if case .hits(let chunks) = unrelated {
            print("[calibration] unrelated:", chunks.map { "\($0.heading) \(String(format: "%.3f", $0.similarity))" })
        } else {
            print("[calibration] unrelated: \(unrelated)")
        }
    }

    private static func vectorExtensionPath() -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build")
        let suffix = "artifacts/sqlite-vector/vectorBinary/vector.xcframework/macos-arm64_x86_64/vector.framework/vector"
        let scratch = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return (["."] + scratch)
            .map { root.appendingPathComponent($0).appendingPathComponent(suffix).path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Bag-of-words vectors: each (stemmed) word adds to one hashed dimension.
/// Texts that share words point the same way, which is enough to test
/// ranking without a model. Records every text it embeds.
private final class HashingEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var dimensions: Int { 128 }

    var embeddedTexts: [String] { locked { texts } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func getEmbedding(for text: String) async throws -> [Float] {
        locked { texts.append(text) }
        var vector = [Float](repeating: 0, count: dimensions)
        vector[0] = 0.1
        for token in KeywordQuery.terms(in: text) {
            var hash: UInt32 = 2_166_136_261
            for byte in KeywordIndex.stem(token).utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            vector[1 + Int(hash % UInt32(dimensions - 1))] += 1
        }
        return vector
    }
}
