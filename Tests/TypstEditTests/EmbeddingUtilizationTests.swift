import XCTest
import Foundation
import CSQLite
@testable import TypstEdit

/// Chunking, keyword search, batching and conversation recall — everything
/// that decides what the embeddings are computed from and how they are used.
@MainActor
final class EmbeddingUtilizationTests: XCTestCase {

    // MARK: - Chunking

    func testTypstPassagesCarryTheirHeadingPathAndLines() {
        let source = """
        = Methods
        We sampled forty sites across the valley floor.

        == Instruments
        A handheld spectrometer was used throughout.

        = Results <results>
        The mean reading rose by twelve percent overall.
        """
        let chunks = DocumentChunker.chunks(in: source, fileExtension: "typ")
        XCTAssertEqual(chunks.map(\.headings), [["Methods"], ["Methods", "Instruments"], ["Results"]],
                       "a sibling heading closes the subsection; the trailing label is not part of the title")
        XCTAssertEqual(chunks.map(\.startLine), [2, 5, 8])
        XCTAssertEqual(chunks[1].endLine, 5)
        XCTAssertFalse(chunks.contains { $0.text.contains("= Methods") }, "headings live in the path, not the passage text")
    }

    func testShortParagraphsArePackedInsteadOfDropped() {
        // Splitting at every blank line and keeping only blocks over 50
        // characters lost list items and one-line definitions entirely.
        let source = (1...6).map { "Item \($0) is short." }.joined(separator: "\n\n")
        let chunks = DocumentChunker.chunks(in: source, fileExtension: "md")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("Item 1") && chunks[0].text.contains("Item 6"))
        XCTAssertEqual(chunks[0].startLine, 1)
        XCTAssertEqual(chunks[0].endLine, 11)
    }

    func testAShortPassageUnderAHeadingIsKept() {
        let chunks = DocumentChunker.chunks(in: "== Deadline\nMarch 3", fileExtension: "typ")
        XCTAssertEqual(chunks.map(\.text), ["March 3"])
    }

    func testMarkdownCodeFencesAreNotHeadings() {
        let source = """
        # Setup
        Run the installer first.

        ```sh
        # not a heading
        ./install.sh --all-components --verbose
        ```
        """
        let chunks = DocumentChunker.chunks(in: source, fileExtension: "md")
        XCTAssertTrue(chunks.allSatisfy { $0.headings == ["Setup"] })
        XCTAssertTrue(chunks.contains { $0.text.contains("# not a heading") })
    }

    func testLongBlocksAreSplitWithinTheSizeLimit() {
        let lines = (1...200).map { "let value\($0) = compute(\($0)) // a line of code" }
        let chunks = DocumentChunker.chunks(in: lines.joined(separator: "\n"), fileExtension: "swift")
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= DocumentChunker.maxChars })
        XCTAssertEqual(chunks.first?.startLine, 1)
        XCTAssertEqual(chunks.last?.endLine, 200)
        // Consecutive pieces cover the block without gaps.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(next.startLine, previous.endLine + 1)
        }
    }

    func testEmbeddingInputNamesTheFileAndSection() {
        let chunk = TextChunk(text: "It defaults to 30 seconds.", startLine: 4, endLine: 4, headings: ["Config", "Timeouts"])
        XCTAssertEqual(chunk.embeddingInput(path: "docs/setup.md"), "File: docs/setup.md\nSection: Config > Timeouts\n\nIt defaults to 30 seconds.")
    }

    func testInputHashIsStableAndContentSensitive() {
        XCTAssertEqual(RAGManager.inputHash("a"), RAGManager.inputHash("a"))
        XCTAssertNotEqual(RAGManager.inputHash("a"), RAGManager.inputHash("b"))
    }

    // MARK: - Keywords

    func testQueryTermsDropStopwordsAndDuplicates() {
        XCTAssertEqual(KeywordQuery.terms(in: "How does the results section explain the error bars? error"), ["results", "error", "bars"])
        XCTAssertEqual(KeywordQuery.ftsExpression(for: "fig:error-bars"), "\"fig\" OR \"error\" OR \"bars\"")
        XCTAssertNil(KeywordQuery.ftsExpression(for: "what is the"))
    }

    func testBM25PrefersTheDocumentWithTheRareTerm() {
        let index = KeywordIndex(documents: [
            "The results are discussed below.",
            "Error bars show one standard deviation of the results.",
            "Results, results and more results."
        ])
        let scores = index.scores(for: "error bars")
        XCTAssertEqual(scores.firstIndex(of: scores.max()!), 1)
        XCTAssertEqual(scores[0], 0)
        XCTAssertEqual(KeywordIndex.stem("bars"), "bar")
    }

    func testKeywordIndexStaysInStepWithChunks() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertTrue(RAGSchema.create(on: handle), "SQLite must be built with FTS5")

        sqlite3_exec(handle, "INSERT INTO files (id, path) VALUES (1, 'a.typ');", nil, nil, nil)
        sqlite3_exec(handle, "INSERT INTO chunks (file_id, text, heading) VALUES (1, 'Error bars show one standard deviation.', 'Results');", nil, nil, nil)
        XCTAssertEqual(try count(handle, "SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH '\"bar\"';"), 1, "porter stemming: bar matches bars")
        XCTAssertEqual(try count(handle, "SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'heading:results';"), 1)

        RAGSchema.deleteFile(id: 1, in: handle)
        XCTAssertEqual(try count(handle, "SELECT count(*) FROM chunks;"), 0)
        XCTAssertEqual(try count(handle, "SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH '\"bars\"';"), 0, "deleted chunks leave the keyword index too")
    }

    private func count(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Batching

    func testEmbeddingResponsesAreReorderedByIndex() throws {
        let json = #"{"data":[{"index":1,"embedding":[0.0,1.0]},{"index":0,"embedding":[1.0,0.0]}]}"#
        let vectors = try GenericAPIEmbeddingProvider.parseEmbeddings(Data(json.utf8), expected: 2)
        XCTAssertEqual(vectors, [[1, 0], [0, 1]])
        XCTAssertThrowsError(try GenericAPIEmbeddingProvider.parseEmbeddings(Data(json.utf8), expected: 3))
    }

    func testTextsAreEmbeddedInBatches() async {
        let provider = FakeEmbeddingProvider()
        let texts = (0..<70).map { "passage \($0)" }
        let vectors = await EmbeddingBatcher.embed(texts, with: provider)
        XCTAssertEqual(vectors.compactMap { $0 }.count, 70)
        XCTAssertEqual(provider.batchCalls, [32, 32, 6])
        XCTAssertEqual(provider.singleCalls, 0)
    }

    func testARejectedBatchFallsBackToSingleRequests() async {
        let provider = FakeEmbeddingProvider(rejectBatches: true, failingText: "bad")
        let vectors = await EmbeddingBatcher.embed(["good", "bad", "fine"], with: provider)
        XCTAssertNotNil(vectors[0])
        XCTAssertNil(vectors[1], "only the passage that fails is lost")
        XCTAssertNotNil(vectors[2])
        XCTAssertEqual(provider.singleCalls, 3)
    }

    // MARK: - Recall

    private func tool(_ name: String, _ args: String, _ output: String, status: ChatMessage.ToolStatus = .succeeded) -> ChatMessage {
        ChatMessage(role: .toolCall, toolName: name, toolArgumentsJSON: args, toolStatus: status, toolOutput: output)
    }

    func testRecallSearchesOnlyWhatLeftTheContext() {
        let messages = [
            ChatMessage(role: .user, text: "Use the Chicago author-date citation style throughout.", isCompacted: true),
            ChatMessage(role: .assistant, text: "Understood, Chicago author-date it is.", isCompacted: true),
            ChatMessage(role: .assistant, text: "[Summary of earlier conversation]\n\nThey want Chicago.", isSummary: true),
            tool("project__web_fetch", #"{"url":"https://example.com/style"}"#, "Chicago author-date puts the year after the author."),
            tool("agent__update_plan", #"{"items":[]}"#, "Plan updated"),
            tool("project__read_file", #"{"path":"a.typ"}"#, "", status: .succeeded),
            tool("project__grep_project", #"{"pattern":"x"}"#, "boom", status: .failed),
            ChatMessage(role: .user, text: "Now fix chapter two.")
        ]
        let sources = ConversationRecall.sources(from: messages)
        XCTAssertEqual(sources.map(\.label), [
            "User, turn 1",
            "Assistant, turn 1",
            "Result of web_fetch(url: \"https://example.com/style\"), turn 1"
        ], "uncompacted turns and the summary are already in the prompt; plans, empty and failed calls carry nothing to recall")
        XCTAssertTrue(ConversationRecall.hasRecallableHistory(messages))
    }

    func testRecallIsOfferedOnlyOnceThereIsSomethingToRecall() {
        XCTAssertFalse(ConversationRecall.hasRecallableHistory([ChatMessage(role: .user, text: "hi")]))
        // A tool result from the current exchange is still in context.
        XCTAssertFalse(ConversationRecall.hasRecallableHistory([
            ChatMessage(role: .user, text: "read it"),
            tool("project__read_file", #"{"path":"a.typ"}"#, "content")
        ]))
        XCTAssertTrue(ConversationRecall.hasRecallableHistory([
            ChatMessage(role: .user, text: "read it"),
            tool("project__read_file", #"{"path":"a.typ"}"#, "content"),
            ChatMessage(role: .user, text: "next")
        ]))
    }

    func testRecallFindsAnExactDetailByKeywordWithoutEmbeddings() async {
        let messages = [
            ChatMessage(role: .user, text: "The figure must be labelled fig-erosion-rates, nothing else.", isCompacted: true),
            ChatMessage(role: .assistant, text: "Noted, I will keep the label as requested.", isCompacted: true),
            ChatMessage(role: .user, text: "Something unrelated about the weather in spring.", isCompacted: true),
            ChatMessage(role: .user, text: "Continue.")
        ]
        let outcome = await ConversationRecall().search("erosion rates figure label", messages: messages, useEmbeddings: false)
        guard case .hits(let hits) = outcome else { return XCTFail("expected hits, got \(outcome)") }
        XCTAssertEqual(hits.first?.label, "User, turn 1")
        XCTAssertNil(hits.first?.similarity)
        XCTAssertTrue(ConversationRecall.format(outcome).contains("--- User, turn 1 (keyword match) ---\nThe figure must be labelled fig-erosion-rates"))
    }

    func testRecallReportsWhenThereIsNothingToSearch() async {
        let outcome = await ConversationRecall().search("anything", messages: [ChatMessage(role: .user, text: "hi")], useEmbeddings: false)
        XCTAssertEqual(outcome, .nothingToSearch)
    }

    // MARK: - Re-fetching after compaction

    func testRehydrationQueryUsesTheMessageObjectiveAndOpenItems() {
        let summary = """
        [Summary of earlier conversation]

        ## Objective
        Shorten the methods chapter to two pages.
        ## Decisions
        Keep the sampling table.
        ## Open items
        None
        """
        XCTAssertEqual(AIChatManager.rehydrationQuery(summary: summary, userText: "Do section 2 next"),
                       "Do section 2 next\nShorten the methods chapter to two pages.")
        XCTAssertNil(AIChatManager.summarySection("Open items", in: summary), "\"None\" means nothing to search for")
        XCTAssertEqual(AIChatManager.rehydrationQuery(summary: "a filtered extract", userText: "go on"), "go on")
    }

    // MARK: - AI Prompt query

    func testPromptQueryIncludesTheTextBeforeTheCursor() {
        XCTAssertEqual(AIContextManager.retrievalQuery(prompt: "continue", textBeforeCursor: "  The erosion rate  "), "continue\n\nThe erosion rate")
        XCTAssertEqual(AIContextManager.retrievalQuery(prompt: "continue", textBeforeCursor: ""), "continue")
        let long = String(repeating: "x", count: 1_000) + "TAIL"
        XCTAssertTrue(AIContextManager.retrievalQuery(prompt: "p", textBeforeCursor: long, contextChars: 10).hasSuffix("xxxxxxTAIL"))
    }
}

/// Records how it was called. Vectors are deterministic and non-zero.
private final class FakeEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _batchCalls: [Int] = []
    private var _singleCalls = 0
    let rejectBatches: Bool
    let failingText: String?

    init(rejectBatches: Bool = false, failingText: String? = nil) {
        self.rejectBatches = rejectBatches
        self.failingText = failingText
    }

    var dimensions: Int { 2 }
    var batchCalls: [Int] { locked { _batchCalls } }
    var singleCalls: Int { locked { _singleCalls } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func getEmbedding(for text: String) async throws -> [Float] {
        locked { _singleCalls += 1 }
        if text == failingText { throw EmbeddingError.generationFailed }
        return [1, Float(text.count)]
    }

    func getEmbeddings(for texts: [String]) async throws -> [[Float]] {
        if rejectBatches { throw EmbeddingError.apiError("no array input") }
        locked { _batchCalls.append(texts.count) }
        return texts.map { [1, Float($0.count)] }
    }
}
