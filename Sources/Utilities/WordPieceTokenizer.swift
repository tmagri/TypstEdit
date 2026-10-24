import Foundation

/// A BERT WordPiece tokenizer for `bert-base-multilingual-cased` — the
/// vocabulary used by Microsoft's small LLMLingua-2 model
/// (`microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank`).
///
/// Implements the original BERT pipeline faithfully enough for token
/// *classification* parity:
///   1. clean text (drop control/format characters, normalize whitespace)
///   2. pad CJK ideographs with spaces (each becomes its own word)
///   3. split on whitespace, then split punctuation into separate words
///   4. greedy longest-match-first WordPiece against the vocab, `##` for
///      continuations, `[UNK]` for words over 100 characters or with no
///      full decomposition
/// "Cased" means step 3.5 (lowercasing + accent stripping) is *skipped* —
/// case is preserved, matching the model card.
struct WordPieceTokenizer: Sendable {

    let vocab: [String: Int]
    let unkID: Int
    let clsID: Int
    let sepID: Int
    let padID: Int

    /// Largest word the WordPiece stage will even attempt; longer words
    /// become `[UNK]` exactly like the reference implementation.
    private static let maxInputCharsPerWord = 100

    /// Builds the lookup from a Hugging Face `vocab.txt` (one token per line,
    /// line number = id).
    init(vocabText: String) {
        var map: [String: Int] = [:]
        map.reserveCapacity(vocabText.count / 4)
        for (index, line) in vocabText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let token = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { map[token] = index }
        }
        self.vocab = map
        self.unkID = map["[UNK]"] ?? 100
        self.clsID = map["[CLS]"] ?? 101
        self.sepID = map["[SEP]"] ?? 102
        self.padID = map["[PAD]"] ?? 0
    }

    // MARK: BasicTokenizer

    /// Whitespace+punctuation words, CJK pre-split, control chars removed.
    /// Public so tests can pin the normalization behavior.
    static func basicWords(_ text: String) -> [String] {
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for character in text {
            let scalar = character.unicodeScalars.first!
            if scalar.properties.isWhitespace {
                cleaned.append(" ")
            } else if scalar.value == 0 || scalar.value == 0xFFFD
                        || (scalar.value < 0x20 && !scalar.properties.isWhitespace)
                        || scalar.properties.generalCategory == .format {
                continue // control / replacement / format characters
            } else {
                cleaned.append(character)
            }
        }

        // CJK ideographs have no spaces around them in real prose; the
        // reference tokenizer splits every ideograph into its own "word".
        var padded = ""
        padded.reserveCapacity(cleaned.count + 16)
        for character in cleaned {
            if Self.isCJK(character) {
                padded.append(" ")
                padded.append(character)
                padded.append(" ")
            } else {
                padded.append(character)
            }
        }

        // Whitespace split, then split punctuation out as standalone words.
        var words: [String] = []
        for token in padded.split(separator: " ", omittingEmptySubsequences: true) {
            var current = ""
            for character in token {
                if let scalar = character.unicodeScalars.first, Self.isPunctuation(scalar) {
                    if !current.isEmpty { words.append(current); current = "" }
                    words.append(String(character))
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { words.append(current) }
        }
        return words
    }

    /// The reference BERT `_is_punctuation`: ASCII punctuation ranges, plus
    /// any Unicode category starting with "P" (typographic quotes, dashes…).
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 33...47, 58...64, 91...96, 123...126:
            return true
        default:
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation,
                 .closePunctuation, .initialPunctuation, .finalPunctuation,
                 .otherPunctuation:
                return true
            default:
                return false
            }
        }
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,
             0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF,
             0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }

    // MARK: WordPiece

    /// Greedy longest-match-first decomposition, e.g. "unaffable" →
    /// ["un", "##aff", "##able"]. Returns nil when the word can't be
    /// represented (caller substitutes `[UNK]`), mirroring the reference.
    func pieces(for word: String) -> [String]? {
        if word.count > Self.maxInputCharsPerWord { return nil }
        var start = word.startIndex
        var output: [String] = []
        while start < word.endIndex {
            var end = word.endIndex
            var match: Substring?
            // Longest suffix first, shrinking until something matches.
            while start < end {
                let candidate = word[start..<end]
                let piece = start == word.startIndex ? String(candidate) : "##" + String(candidate)
                if vocab[piece] != nil {
                    match = candidate
                    output.append(piece)
                    break
                }
                end = word.index(before: end)
            }
            guard match != nil else { return nil }
            start = end
        }
        return output
    }

    /// Encodes one BasicTokenizer word to ids, `[UNK]` on failure.
    func encodeWord(_ word: String) -> [Int] {
        if let pieces = pieces(for: word) {
            return pieces.compactMap { vocab[$0] }
        }
        return [unkID]
    }

    /// Full pipeline for free text: basic words → ids. Special tokens are
    /// deliberately *not* added — callers control CLS/SEP placement so words
    /// can be mapped back to model positions deterministically.
    func encode(_ text: String) -> [Int] {
        Self.basicWords(text).flatMap { encodeWord($0) }
    }
}
