import XCTest
@testable import TypstEdit

// MARK: - Segmentation / Assembly

@MainActor
final class PromptCompressionTests: XCTestCase {

    func testSegmentAssembleRoundTripIsIdentity() {
        let text = "  First line.\n\nSecond\tline  ends here. "
        let segmentation = PromptCompression.segment(text)
        XCTAssertEqual(segmentation.assemble(keeping: Set(segmentation.segments.indices)), text)
    }

    func testSegmentCapturesLeadingWhitespaceAndNewlines() {
        let segmentation = PromptCompression.segment("a\n  b")
        XCTAssertEqual(segmentation.segments.count, 2)
        XCTAssertEqual(segmentation.segments[0].lead, "")
        XCTAssertEqual(segmentation.segments[0].text, "a")
        XCTAssertEqual(segmentation.segments[1].lead, "\n  ")
        XCTAssertEqual(segmentation.segments[1].text, "b")
        XCTAssertEqual(segmentation.trailing, "")
    }

    func testSegmentCapturesTrailingWhitespace() {
        XCTAssertEqual(PromptCompression.segment("a b  ").trailing, "  ")
        XCTAssertEqual(PromptCompression.segment("ab").trailing, "")
    }

    func testAssembleKeepsParagraphStructureOfSurvivors() {
        let segmentation = PromptCompression.segment("one\ntwo\n\nthree")
        // Keep only "two" and "three" — each survivor brings its original
        // leading whitespace, so the blank line between them survives.
        let output = segmentation.assemble(keeping: [1, 2])
        XCTAssertEqual(output, "\ntwo\n\nthree")
    }

    // MARK: - Token Selection

    func testKeepIndicesHitsTargetRate() {
        let scores: [Double] = [1, 5, 2, 4, 3, 0, 6, 7]
        let keeping = TokenSelection.keepIndices(scores: scores, keepRate: 0.5, forced: [])
        XCTAssertEqual(keeping.count, 4)
        // The four best words are indices 7, 6, 1, 3.
        XCTAssertEqual(keeping, [1, 3, 6, 7])
    }

    func testKeepIndicesForcedAlwaysSurvive() {
        let scores: [Double] = [0, 0, 0, 0, 0, 0, 0, 0]
        let keeping = TokenSelection.keepIndices(scores: scores, keepRate: 0.25, forced: [5, 6, 7])
        XCTAssertTrue(keeping.isSuperset(of: [5, 6, 7]))
        XCTAssertEqual(keeping.count, 3) // the 2 rate picks are themselves forced
    }

    func testKeepIndicesClampsRateAndNeverEmpties() {
        XCTAssertEqual(TokenSelection.keepIndices(scores: [1, 2, 3], keepRate: 0, forced: []).count, 1)
        XCTAssertEqual(TokenSelection.keepIndices(scores: [1, 2, 3], keepRate: 2, forced: []).count, 3)
        XCTAssertTrue(TokenSelection.keepIndices(scores: [], keepRate: 0.5, forced: []).isEmpty)
    }

    // MARK: - Heuristic Filter

    func testFullRateIsIdentity() async {
        let text = "The user asked about #set heading and file: /Users/x/doc.typ."
        let compressed = await HeuristicTokenFilter().compress(text, keepRate: 1.0, forceTokens: [], isCode: false)
        XCTAssertEqual(compressed, text)
    }

    func testNumbersAndPathsBeatStopwords() async {
        let text = "the of and 42 /Users/tm/report.typ the a an"
        let compressed = await HeuristicTokenFilter().compress(text, keepRate: 0.25, forceTokens: [], isCode: false)
        XCTAssertTrue(compressed.contains("42"))
        XCTAssertTrue(compressed.contains("/Users/tm/report.typ"))
        XCTAssertFalse(compressed.contains("and"))
    }

    func testForcedTokensSurviveAggressiveCompression() async {
        let text = "alpha beta gamma delta epsilon"
        let compressed = await HeuristicTokenFilter().compress(text, keepRate: 0.2, forceTokens: ["gamma"], isCode: false)
        XCTAssertTrue(compressed.contains("gamma"))
    }

    func testCodeModeClampsRateAndKeepsBraces() async {
        let code = "#let f(x) = { x + 1 }\nplain prose word another more"
        let compressed = await HeuristicTokenFilter().compress(code, keepRate: 0.1, forceTokens: [], isCode: true)
        XCTAssertTrue(compressed.contains("{"))
        XCTAssertTrue(compressed.contains("}"))
        // The 0.8 rate floor keeps most of the snippet.
        let keptWords = compressed.split(separator: "\n").flatMap { $0.split(separator: " ") }.count
        let originalWords = code.split(separator: "\n").flatMap { $0.split(separator: " ") }.count
        XCTAssertGreaterThan(Double(keptWords) / Double(originalWords), 0.6)
    }

    func testCodeRatioDetectsFencedBlocks() {
        let withFence = "Explanation here.\n\n```typ\n#let x = 5\n#let y = x * 2\n```\n\nDone."
        XCTAssertGreaterThan(PromptCompression.codeRatio(withFence), 0.3)
        XCTAssertLessThan(PromptCompression.codeRatio("Just a plain English paragraph, nothing else."), 0.3)
    }

    // MARK: - WordPiece Tokenizer

    /// Tiny fixture vocab mirroring bert-base-multilingual-cased's shape:
    /// specials, whole common words, and subword continuations.
    private static let fixtureVocab = """
    [PAD]
    [UNK]
    [CLS]
    [SEP]
    [MASK]
    un
    ##aff
    ##able
    heading
    Hello
    ,
    .
    你
    好
    """

    private func makeTokenizer() -> WordPieceTokenizer {
        WordPieceTokenizer(vocabText: Self.fixtureVocab)
    }

    func testWordPieceGreedyLongestMatch() {
        let tokenizer = makeTokenizer()
        XCTAssertEqual(tokenizer.pieces(for: "unaffable"), ["un", "##aff", "##able"])
        XCTAssertEqual(tokenizer.pieces(for: "heading"), ["heading"])
    }

    func testWordPieceReturnsNilForUndecomposableWord() {
        XCTAssertNil(makeTokenizer().pieces(for: "zzzzzz"))
    }

    func testEncodeWordFallsBackToUnk() {
        XCTAssertEqual(makeTokenizer().encodeWord("zzzzzz"), [1]) // [UNK]
    }

    func testBasicTokenizerSplitsPunctuation() {
        let words = WordPieceTokenizer.basicWords("Hello, world.")
        XCTAssertEqual(words, ["Hello", ",", "world", "."])
    }

    func testBasicTokenizerSplitsCJKCharacters() {
        XCTAssertEqual(WordPieceTokenizer.basicWords("你好"), ["你", "好"])
    }

    func testEncodeDropsSpecialTokens() {
        // "Hello" + "," → ids 9 (Hello) + 10 (,); no [CLS]/[SEP] appended —
        // callers control special-token placement.
        XCTAssertEqual(makeTokenizer().encode("Hello,"), [9, 10])
    }

    func testCasedTokenizerPreservesCase() {
        // The cased model keeps case: "Hello" is in the vocab, "hello" is not.
        XCTAssertEqual(makeTokenizer().encode("Hello"), [9])
        XCTAssertEqual(makeTokenizer().encode("hello"), [1]) // [UNK]
    }

    // MARK: - Settings plumbing

    func testCompressionMethodRoundTripsAndClampsRate() {
        let settings = AISettingsManager.shared
        let originalMethod = settings.chatCompressionMethod
        let originalRate = settings.chatCompressionKeepRate
        defer {
            settings.chatCompressionMethod = originalMethod
            settings.chatCompressionKeepRate = originalRate
        }

        settings.chatCompressionMethod = .llmlingua2
        XCTAssertEqual(settings.chatCompressionMethod, .llmlingua2)

        settings.chatCompressionKeepRate = 0
        XCTAssertEqual(settings.effectiveChatCompressionKeepRate, 0.1)
        settings.chatCompressionKeepRate = 5
        XCTAssertEqual(settings.effectiveChatCompressionKeepRate, 0.9)
        settings.chatCompressionKeepRate = 0.35
        XCTAssertEqual(settings.effectiveChatCompressionKeepRate, 0.35)
    }
}

// MARK: - Tool Output Elision

@MainActor
final class ToolOutputElisionTests: XCTestCase {

    /// Answers with a fixed share of the input — enough to verify pass-1
    /// behavior without any model.
    private struct RecordingCompressor: PromptCompressor {
        func compress(_ text: String, keepRate: Double, forceTokens: [String], isCode: Bool) async -> String {
            String(text.suffix(Int(Double(text.count) * 0.5)))
        }
    }

    private func toolResult(_ callID: String, output: String) -> AIChatMessage {
        .toolResult(AIToolResult(callID: callID, name: "read_file", output: output))
    }

    func testCompressionPassKeepsContentInsteadOfPlaceholder() async {
        let big = String(repeating: "word ", count: 400) // 2000 chars
        var messages: [AIChatMessage] = [
            .system("system"),
            .user("go"),
            toolResult("1", output: big), // oldest — eligible
            toolResult("2", output: big), // second-newest — protected
            toolResult("3", output: big), // newest — protected
            .assistantText("done"),
        ]
        // Sized so compressing the oldest result alone gets under it, but
        // the raw text can never fit — pass 2 must not run.
        let budget = 1062 + 2000 + 2000 + 15
        await AICompletionService.elideOldToolOutputs(
            in: &messages,
            charBudget: budget,
            compressor: RecordingCompressor(),
            keepRate: 0.5
        )

        guard case .toolResult(let first) = messages[2] else { return XCTFail() }
        XCTAssertTrue(first.output.hasPrefix(AICompletionService.compressedToolOutputMarker))
        XCTAssertLessThan(first.output.count, big.count)
        // Both protected results are untouched.
        guard case .toolResult(let second) = messages[3] else { return XCTFail() }
        XCTAssertEqual(second.output, big)
        guard case .toolResult(let third) = messages[4] else { return XCTFail() }
        XCTAssertEqual(third.output, big)
    }

    func testCompressedOutputsAreNeverCompressedAgain() async {
        let big = String(repeating: "word ", count: 400)
        var messages: [AIChatMessage] = [
            .system("system"),
            .user("go"),
            toolResult("1", output: AICompletionService.compressedToolOutputMarker + big), // old, already filtered
            toolResult("2", output: big), // second-newest — protected
            toolResult("3", output: big), // newest — protected
            .assistantText("done"),
        ]
        await AICompletionService.elideOldToolOutputs(
            in: &messages,
            charBudget: 200,
            compressor: RecordingCompressor(),
            keepRate: 0.5
        )

        // The marked output was skipped by the compression pass (no second
        // marker stacked on it); the last-resort placeholder pass is what
        // replaced it.
        guard case .toolResult(let first) = messages[2] else { return XCTFail() }
        XCTAssertTrue(first.output.contains("elided"))
        XCTAssertFalse(first.output.contains(AICompletionService.compressedToolOutputMarker))
        guard case .toolResult(let third) = messages[4] else { return XCTFail() }
        XCTAssertEqual(third.output, big)
    }

    func testWithoutCompressorOnlyPlaceholdersRun() async {
        let big = String(repeating: "word ", count: 400)
        var messages: [AIChatMessage] = [
            .system("system"),
            .user("go"),
            toolResult("1", output: big),
            toolResult("2", output: big),
            toolResult("3", output: big),
            .assistantText("done"),
        ]
        await AICompletionService.elideOldToolOutputs(
            in: &messages,
            charBudget: 4200,
            compressor: nil,
            keepRate: 0.5
        )

        guard case .toolResult(let first) = messages[2] else { return XCTFail() }
        XCTAssertTrue(first.output.contains("elided"))
        guard case .toolResult(let second) = messages[3] else { return XCTFail() }
        XCTAssertEqual(second.output, big)
        guard case .toolResult(let third) = messages[4] else { return XCTFail() }
        XCTAssertEqual(third.output, big)
    }

    func testUnderBudgetChangesNothing() async {
        let small = "short result"
        var messages: [AIChatMessage] = [
            .system("system"),
            .user("go"),
            toolResult("1", output: small),
            .assistantText("done"),
        ]
        await AICompletionService.elideOldToolOutputs(
            in: &messages,
            charBudget: 10_000,
            compressor: RecordingCompressor(),
            keepRate: 0.5
        )
        guard case .toolResult(let result) = messages[2] else { return XCTFail() }
        XCTAssertEqual(result.output, small)
    }
}

// MARK: - Real Model (skipped unless installed)

@MainActor
final class LLMLingua2EngineTests: XCTestCase {

    /// End-to-end check against the actually-installed Core ML model:
    /// tokenizer → Core ML logits → word selection → verbatim rebuild.
    /// Skips (rather than fails) on machines without the optional model.
    func testEngineCompressesVerbatimWhenInstalled() async throws {
        guard let engine = await LLMLingua2Manager.shared.loadEngineIfNeeded() else {
            throw XCTSkip("LLMLingua-2 model not installed — download it in Settings → Typst → Updates")
        }
        let compressor = LLMLingua2Compressor(engine: engine)

        let text = """
        The user asked about heading numbering in chapter 3, specifically the file /Users/tm/thesis/chapters/intro.typ.
        It contains 42 references and the bibliography compiled at 14:32 without errors.
        The and of but so a an to in on at by for with from as is are was were be been.
        """
        let compressed = await compressor.compress(text, keepRate: 0.3, forceTokens: [], isCode: false)

        // Output shrank, stayed verbatim (exact words from the input), and
        // roughly honored the keep rate.
        XCTAssertLessThan(compressed.count, text.count)
        let originalWords = Set(PromptCompression.segment(text).segments.map(\.text))
        for word in PromptCompression.segment(compressed).segments.map(\.text) {
            XCTAssertTrue(originalWords.contains(word), "non-verbatim word leaked in: \(word)")
        }
        let originalCount = PromptCompression.segment(text).segments.count
        let keptCount = PromptCompression.segment(compressed).segments.count
        XCTAssertLessThanOrEqual(Double(keptCount), Double(originalCount) * 0.6 + 1)
    }

    /// Code safety must hold with the real model too: the 0.8 rate floor and
    /// forced structural words protect Typst syntax regardless of what the
    /// classifier thinks.
    func testEngineRespectsCodeSafetyWhenInstalled() async throws {
        guard let engine = await LLMLingua2Manager.shared.loadEngineIfNeeded() else {
            throw XCTSkip("LLMLingua-2 model not installed — download it in Settings → Typst → Updates")
        }
        let compressor = LLMLingua2Compressor(engine: engine)

        let code = "#let heading-numbering(n..) = { numbering(\"1.1\", ..n) }"
        let compressed = await compressor.compress(code, keepRate: 0.2, forceTokens: [], isCode: true)
        for structural in ["#let", "(", ")", "{", "}"] {
            XCTAssertTrue(compressed.contains(structural), "code safety lost: \(structural)")
        }
    }
}
