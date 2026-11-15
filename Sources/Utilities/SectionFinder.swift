import Foundation

/// Ranks whole *sections* — heading plus opening text — against a question
/// in plain words.
///
/// `search_project` returns fixed-size passages, which answers "where is X
/// mentioned" but not "which section is about X": the unit a reorganizing
/// edit works on. This scores each section by keyword overlap (heading
/// words count double) blended with embedding similarity from the
/// embedding model the project index uses. Pure: the caller embeds.
enum SectionFinder {

    struct Candidate: Sendable, Equatable {
        let path: String
        let entry: DocumentOutline.Entry
        let lead: String

        var title: String { DocumentOutline.title(of: entry.text) }

        /// What gets embedded: the heading and the start of its prose.
        var embeddingText: String {
            let words = lead.split(whereSeparator: \.isWhitespace).prefix(60)
            return words.isEmpty ? title : title + ". " + words.joined(separator: " ")
        }
    }

    struct Hit: Sendable, Equatable {
        let candidate: Candidate
        let score: Double
        let keywordScore: Double
        let meaningScore: Double?
    }

    /// Every section (heading with a range) in one file.
    static func candidates(in text: String, path: String) -> [Candidate] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return DocumentOutline.entries(in: text).compactMap { entry in
            guard let end = entry.endLine else { return nil }
            return Candidate(path: path, entry: entry, lead: DocumentOutline.sectionLead(lines, after: entry.line, through: end))
        }
    }

    // MARK: Keywords

    /// Lower-cased content words with a light suffix strip, so "errors",
    /// "error" and "erroring" meet. Stopwords are dropped.
    static func terms(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return words.compactMap { word in
            guard !HeuristicTokenFilter.stopwords.contains(word), word.count > 1 || word.first?.isNumber == true else { return nil }
            return stem(word)
        }
    }

    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ies", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// 0…1: the share of query terms found in the heading (full weight) or
    /// the opening text (half weight).
    static func keywordScore(queryTerms: [String], candidate: Candidate) -> Double {
        let unique = Array(Set(queryTerms))
        guard !unique.isEmpty else { return 0 }
        let titleTerms = Set(terms(candidate.title))
        let leadTerms = Set(terms(candidate.lead))
        var total = 0.0
        for term in unique {
            if titleTerms.contains(term) {
                total += 1
            } else if leadTerms.contains(term) {
                total += 0.5
            }
        }
        return total / Double(unique.count)
    }

    // MARK: Ranking

    /// Weight of meaning against keywords for a capable embedding model
    /// (the one configured for the project index).
    static let strongMeaningWeight = 0.6
    /// Weight for Apple's built-in sentence embedding, which separates
    /// related from unrelated text only weakly: keywords lead, meaning
    /// breaks ties.
    static let weakMeaningWeight = 0.3

    /// Sections ordered by combined score, best first. `vectors[i]` is the
    /// embedding of `candidates[i]` (or nil); pass no `queryVector` to rank
    /// on keywords alone.
    ///
    /// Cosine scales differ widely between embedding models (unrelated text
    /// scores ≈0.1 with one, ≈0.45 with another), so similarities are
    /// rescaled within this search: the median candidate maps to 0, the best
    /// to 1. That ranks "more related than the rest of this document", which
    /// is the question being asked.
    static func rank(
        query: String,
        candidates: [Candidate],
        queryVector: [Float]? = nil,
        vectors: [[Float]?] = [],
        meaningWeight: Double = strongMeaningWeight,
        limit: Int
    ) -> [Hit] {
        let queryTerms = terms(query)
        let similarities: [Double?] = candidates.indices.map { index in
            guard let queryVector, index < vectors.count, let vector = vectors[index] else { return nil }
            return cosine(queryVector, vector)
        }
        let known = similarities.compactMap { $0 }.sorted()
        let floor = known.isEmpty ? 0 : known[known.count / 2]
        let top = known.last ?? 0

        var hits: [Hit] = []
        for (index, candidate) in candidates.enumerated() {
            let keyword = keywordScore(queryTerms: queryTerms, candidate: candidate)
            let meaning = similarities[index].map { similarity in
                top > floor ? min(1, max(0, (similarity - floor) / (top - floor))) : 0
            }
            let score = meaning.map { meaningWeight * $0 + (1 - meaningWeight) * keyword } ?? keyword
            hits.append(Hit(candidate: candidate, score: score, keywordScore: keyword, meaningScore: meaning))
        }
        hits.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.candidate.entry.line < rhs.candidate.entry.line
        }
        // A keyword hit always qualifies; a meaning-only hit must be near
        // the top of this document's spread.
        guard let best = hits.first?.score, best > 0 else { return [] }
        return Array(hits.filter { $0.keywordScore > 0 || ($0.meaningScore ?? 0) >= 0.75 }.prefix(limit))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return Double(dot / (normA.squareRoot() * normB.squareRoot()))
    }

    // MARK: Rendering

    /// How the ranking was made, for the result header.
    enum Method: Equatable {
        case keywordsOnly
        case weakMeaning
        case meaning(model: String)

        var description: String {
            switch self {
            case .keywordsOnly: return "keywords (no embedding model reachable)"
            case .weakMeaning: return "keywords, with Apple's on-device embedding as a weak hint — set an embedding model in Settings for search by meaning"
            case .meaning(let model): return "meaning (\(model)) + keywords"
            }
        }
    }

    static func render(_ hits: [Hit], query: String, sectionCount: Int, fileCount: Int, method: Method, note: String? = nil) -> String {
        var output = "[sections matching \"\(query)\" — searched \(sectionCount) section\(sectionCount == 1 ? "" : "s") in \(fileCount) file\(fileCount == 1 ? "" : "s"), ranked by \(method.description)]"
        if let note { output += "\n(\(note))" }
        guard !hits.isEmpty else {
            return output + "\nNo section matches. Try other words, grep_project for an exact phrase, or get_outline to browse the headings."
        }
        for (index, hit) in hits.enumerated() {
            let entry = hit.candidate.entry
            output += "\n\(index + 1). \(hit.candidate.path):\(entry.line)-\(entry.endLine ?? entry.line): \(entry.text)  (score \(String(format: "%.2f", hit.score)))"
            let words = hit.candidate.lead.split(whereSeparator: \.isWhitespace)
            if !words.isEmpty {
                output += "\n   " + words.prefix(25).joined(separator: " ") + (words.count > 25 ? " …" : "")
            }
        }
        if let top = hits.first {
            output += "\nUse a result by name: read_file path: \"\(top.candidate.path)\", section: \"\(top.candidate.entry.text)\" — or move_lines with section: the same name."
        }
        return output
    }
}
