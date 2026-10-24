import Foundation

// MARK: - Chat Compression Method

/// How old context is squeezed back under the token budget when a chat
/// conversation (or a single long agentic turn) gets too big.
///
/// - `llmSummary`: the original approach — ask the model itself to write a
///   prose summary of the older turns. Small local models are mediocre at
///   this: they omit, paraphrase away details, or invent facts.
/// - `tokenFilter`: a rule-based, verbatim token filter (see
///   `HeuristicTokenFilter`). Never touches the LLM — zero cost, zero
///   hallucination risk, and the text that survives is the *original* text.
/// - `llmlingua2`: the same verbatim-filtering idea, but the keep/drop
///   decision comes from Microsoft's LLMLingua-2 token classifier running
///   locally through Core ML (an optional download — see
///   `LLMLingua2Manager`). Falls back to `tokenFilter` when the model isn't
///   installed, so every setting remains usable out of the box.
enum ChatCompressionMethod: String, CaseIterable, Identifiable {
    case llmSummary
    case tokenFilter
    case llmlingua2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .llmSummary: return "LLM summary (default)"
        case .tokenFilter: return "Token filter (basic, offline)"
        case .llmlingua2: return "LLMLingua-2 (Core ML model)"
        }
    }
}

// MARK: - Prompt Compressor Protocol

/// Compresses a prompt-sized text by dropping the least important *words*
/// while keeping the survivors verbatim and in their original order — the
/// LLMLingua family's core idea. `keepRate` is the fraction of words to keep
/// (0.5 = keep the best half), mirroring LLMLingua-2's `rate` parameter.
///
/// Implementations must be deterministic and must never *grow* the text:
/// `compress(x, keepRate: 1.0, …)` returns `x` unchanged.
protocol PromptCompressor: Sendable {
    func compress(
        _ text: String,
        keepRate: Double,
        forceTokens: [String],
        isCode: Bool
    ) async -> String
}

// MARK: - Word Segmentation

/// Pure helpers shared by both compressor implementations: the app filters
/// whole *words* (never sub-words), so a compressed text stays readable
/// word-by-word and a word can never be torn in half.
enum PromptCompression {

    /// One whitespace-delimited word plus the whitespace that preceded it.
    /// Keeping the leading run (which may include newlines and indentation)
    /// means a filtered text preserves the original paragraph and code
    /// structure between the words that survived.
    struct Segment: Sendable, Equatable {
        let lead: String
        let text: String
    }

    /// The result of segmentation: the words, plus whatever whitespace came
    /// after the last one (attached to nothing, so `assemble` can restore
    /// the text byte-for-byte when everything is kept).
    struct Segmentation: Sendable {
        let segments: [Segment]
        let trailing: String

        /// Rebuilds a text from the kept segment indices. Survivors keep
        /// their original spacing, so newlines and indentation survive
        /// filtering.
        func assemble(keeping: Set<Int>) -> String {
            var output = ""
            for (index, segment) in segments.enumerated() where keeping.contains(index) {
                output += segment.lead
                output += segment.text
            }
            return output + trailing
        }
    }

    /// Splits `text` into words on Unicode whitespace, recording each word's
    /// preceding whitespace. `assemble` with all indices kept is an identity
    /// round-trip.
    static func segment(_ text: String) -> Segmentation {
        var segments: [Segment] = []
        segments.reserveCapacity(text.count / 5 + 1)
        var lead = ""
        var current = ""
        for character in text {
            if character.isWhitespace {
                if !current.isEmpty {
                    segments.append(Segment(lead: lead, text: current))
                    current = ""
                    lead = ""
                }
                lead.append(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            segments.append(Segment(lead: lead, text: current))
            lead = ""
        }
        return Segmentation(segments: segments, trailing: lead)
    }

    /// Rough fraction (0…1) of the text that looks like code: fenced blocks,
    /// brace/Typst-marker density, and indented lines all count. Used to
    /// route text through the gentler "code" filtering rules — dropping a
    /// `{` or a `#` breaks syntax in ways dropping "the" never does.
    static func codeRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }

        // Fenced code blocks: measure how much of the text sits inside ``` pairs.
        var fencedChars = 0
        var insideFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                fencedChars += line.count
                continue
            }
            if insideFence { fencedChars += line.count }
        }

        // Structural-marker density outside any counting subtleties: the
        // characters that carry Typst/code syntax.
        let structural = CharacterSet(charactersIn: "{}()[]#$=;<>\\|")
        var structuralCount = 0
        for scalar in text.unicodeScalars where structural.contains(scalar) {
            structuralCount += 1
        }

        // Indented lines (typical of pasted code without fences).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        let indentRatio = lines.isEmpty ? 0 : Double(indented) / Double(lines.count)

        let fencedRatio = Double(fencedChars) / Double(text.count)
        let punctuationRatio = Double(structuralCount) / Double(max(text.count, 1))
        return min(1, fencedRatio * 1.5 + punctuationRatio * 0.6 + indentRatio * 0.5)
    }
}

// MARK: - Keep Selection (shared by both compressors)

/// Deterministic keep/drop selection given per-word scores. Both the
/// heuristic filter and the LLMLingua-2 model path funnel through this, so
/// rate handling and forced-keep behavior are identical no matter which
/// scorer produced the numbers.
enum TokenSelection {

    /// Picks the indices to keep: the top `keepRate` fraction by score, in
    /// the *original* order (ordering is restored by `assemble`, not here).
    /// Forced indices are always kept even when that pushes past the rate —
    /// the same contract as LLMLingua-2's `force_tokens`.
    /// Ties break toward the earlier word so results are stable.
    static func keepIndices(
        scores: [Double],
        keepRate: Double,
        forced: Set<Int>,
        minimumKeep: Int = 1
    ) -> Set<Int> {
        guard !scores.isEmpty else { return [] }
        let clampedRate = min(max(keepRate, 0), 1)
        let target = max(minimumKeep, Int((Double(scores.count) * clampedRate).rounded(.down)))
        let boosted = scores.enumerated().map { index, score in
            score + (forced.contains(index) ? 1_000_000 : 0)
        }
        let order = boosted.indices.sorted {
            boosted[$0] > boosted[$1] || (boosted[$0] == boosted[$1] && $0 < $1)
        }
        return Set(order.prefix(target)).union(forced)
    }
}

// MARK: - Heuristic Token Filter

/// The zero-dependency compressor: scores each word with deterministic
/// rules tuned for this app's context (editing transcripts, file contents,
/// grep output, Typst sources) and keeps the top slice verbatim. It exists
/// both as the always-available fallback and as the baseline the Core ML
/// model has to beat.
struct HeuristicTokenFilter: PromptCompressor {

    /// Words that are always kept when the text is code-heavy, regardless of
    /// score — dropping one of these silently changes meaning.
    static let structuralTokens: Set<String> = ["{", "}", "(", ")", "[", "]", "#", "$", "="]

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "of", "to", "in",
        "on", "at", "by", "for", "with", "from", "as", "is", "are", "was", "were",
        "be", "been", "being", "am", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "not", "it", "its", "this", "that", "these", "those", "i", "you", "he",
        "she", "we", "they", "them", "his", "her", "their", "our", "your", "my",
        "me", "us", "what", "which", "who", "when", "where", "why", "how", "than",
        "too", "very", "just", "also", "there", "here", "about", "into", "over",
        "under", "again", "all", "any", "both", "each", "few", "more", "most",
        "other", "some", "such", "only", "own", "same", "get", "got",
    ]

    /// Words that mark content worth keeping in editor/AI-chat context:
    /// Typst and programming keywords, plus common transcript vocabulary
    /// (decisions, files, todo items).
    static let contentKeywords: Set<String> = [
        "let", "set", "show", "import", "include", "func", "fn", "def", "class",
        "return", "struct", "enum", "type", "theorem", "proof", "figure", "table",
        "equation", "heading", "outline", "bibliography", "cite", "ref", "label",
        "link", "file", "path", "error", "warning", "compile", "compiled",
        "decision", "goal", "constraint", "todo", "note", "important", "summary",
        "read", "write", "edit", "changed", "verify", "verified", "result",
    ]

    func compress(
        _ text: String,
        keepRate: Double,
        forceTokens: [String],
        isCode: Bool
    ) async -> String {
        Self.compressSync(text, keepRate: keepRate, forceTokens: forceTokens, isCode: isCode)
    }

    /// Synchronous core, also used directly by tests and by the LLMLingua-2
    /// path for its code-detection rule.
    static func compressSync(
        _ text: String,
        keepRate: Double,
        forceTokens: [String],
        isCode: Bool
    ) -> String {
        let segmentation = PromptCompression.segment(text)
        let segments = segmentation.segments
        guard segments.count > 3 else { return text }

        // Code gets a floor on the rate — syntax dies before prose does.
        let effectiveRate = isCode ? max(keepRate, 0.8) : keepRate

        let forcedWords = Set(forceTokens.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            .union(isCode ? structuralTokens : [])

        var scores: [Double] = []
        scores.reserveCapacity(segments.count)
        var forced = Set<Int>()

        for (index, segment) in segments.enumerated() {
            let word = segment.text
            let lower = word.lowercased()
            scores.append(
                Self.score(
                    word: word,
                    isFirstOnLine: segment.lead.contains("\n"),
                    isLastOnLine: index + 1 >= segments.count
                        || segments[index + 1].lead.contains("\n")
                )
            )
            // Forced matching ignores the punctuation a word carries with
            // it — but braces are matched RAW, since stripping them is what
            // would erase the very tokens we're protecting.
            let bare = lower.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:!?()[]{}"))
            if forcedWords.contains(bare) || forcedWords.contains(lower)
                || (isCode && structuralTokens.contains(lower)) {
                forced.insert(index)
            }
            if isCode && word.contains(where: { "{}()[]#$=;<>\\".contains($0) }) {
                scores[index] += 1.5
            }
        }

        let keeping = TokenSelection.keepIndices(scores: scores, keepRate: effectiveRate, forced: forced)
        return segmentation.assemble(keeping: keeping)
    }

    /// Additive word score. Higher keeps; only *relative* order matters.
    static func score(word: String, isFirstOnLine: Bool, isLastOnLine: Bool) -> Double {
        let lower = word.lowercased()
        let bare = lower.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:!?()[]{}"))
        var score = 0.0

        if word.rangeOfCharacter(from: .decimalDigits) != nil { score += 3 }
        if lower.hasPrefix("http") || lower.hasPrefix("www.") || word.contains("://") { score += 3 }
        if word.contains("/") || word.contains("\\") { score += 2.5 }
        if word.contains("_") || isIdentifierLike(word) { score += 2 }
        if word.contains("`") || word.contains("\"") { score += 1.5 }
        if contentKeywords.contains(bare) { score += 1.5 }
        if word.hasSuffix(":") { score += 1 }
        if isFirstOnLine { score += 1 }
        if isLastOnLine { score += 0.5 }
        if word.count >= 8 { score += 0.5 }
        if let first = word.first, first.isUppercase, !isFirstOnLine { score += 0.4 }
        if stopwords.contains(bare) { score -= 2.5 }
        if word.count <= 2 && word.rangeOfCharacter(from: .decimalDigits) == nil { score -= 0.5 }
        return score
    }

    /// camelCase, ALLCAPS and dash-joined technical words read as identifiers.
    private static func isIdentifierLike(_ word: String) -> Bool {
        guard word.count > 1 else { return false }
        var sawLower = false
        var sawUpper = false
        for character in word {
            if character.isLowercase { sawLower = true }
            if character.isUppercase { sawUpper = true }
        }
        if sawLower && sawUpper { return true }
        let letters = word.filter { $0.isLetter }
        return letters.count >= 2 && letters == word && word == word.uppercased() && word.count >= 2
    }
}

// MARK: - Facade

/// Resolves a settings method into a usable compressor. Never fails: the
/// LLMLingua-2 path silently degrades to the heuristic filter when the
/// optional model isn't installed (or can't load), so the chat keeps working
/// — just with the simpler scorer.
@MainActor
enum ChatCompressor {

    /// Returns nil only for `.llmSummary` (no pre-model compression wanted).
    /// The rate comes straight from Settings, already clamped.
    static func resolve(method: ChatCompressionMethod) async -> (compressor: any PromptCompressor, keepRate: Double)? {
        let settings = AISettingsManager.shared
        let rate = settings.effectiveChatCompressionKeepRate
        switch method {
        case .llmSummary:
            return nil
        case .tokenFilter:
            return (HeuristicTokenFilter(), rate)
        case .llmlingua2:
            if let engine = await LLMLingua2Manager.shared.loadEngineIfNeeded() {
                return (LLMLingua2Compressor(engine: engine), rate)
            }
            return (HeuristicTokenFilter(), rate)
        }
    }
}
