import Foundation

/// Keyword matching that complements the embeddings. Vectors are good at
/// meaning and weak at exact terms — a label, a function name, a number —
/// which is exactly what a keyword score is good at.
enum KeywordQuery {
    /// Common English words that carry no topic on their own.
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "does", "for", "from",
        "has", "have", "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not",
        "of", "on", "or", "our", "so", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "to", "was", "we", "were", "what", "when", "where", "which",
        "who", "why", "will", "with", "would", "you", "your", "about", "all", "any", "also",
        "find", "show", "tell", "explain", "explains", "describe", "describes", "section", "file",
        "document", "project", "please", "should", "could", "some", "more", "most"
    ]

    /// Lowercased word tokens, split on anything that is not a letter or a
    /// digit (the same rule as SQLite's unicode61 tokenizer).
    static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The distinct topic words of a query, in order.
    static func terms(in query: String) -> [String] {
        var seen = Set<String>()
        return tokens(in: query).filter { token in
            (token.count > 1 || token.first?.isNumber == true)
                && !stopwords.contains(token)
                && seen.insert(token).inserted
        }
    }

    /// An FTS5 MATCH expression that matches any of the terms, ranked by
    /// BM25. `nil` when the query has no topic words. Terms are letters and
    /// digits only, so quoting them is enough to make them literal.
    static func ftsExpression(for query: String) -> String? {
        let terms = terms(in: query).prefix(16)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}

/// BM25 over a small in-memory corpus, for text that has no SQLite index
/// (the conversation history `recall` searches).
struct KeywordIndex {
    private let documents: [[String: Int]]
    private let lengths: [Int]
    private let averageLength: Double
    private let documentFrequency: [String: Int]

    init(documents texts: [String]) {
        var frequency: [String: Int] = [:]
        var docs: [[String: Int]] = []
        var lengths: [Int] = []
        for text in texts {
            var counts: [String: Int] = [:]
            let tokens = KeywordQuery.tokens(in: text).map(Self.stem)
            for token in tokens { counts[token, default: 0] += 1 }
            for token in counts.keys { frequency[token, default: 0] += 1 }
            docs.append(counts)
            lengths.append(tokens.count)
        }
        self.documents = docs
        self.lengths = lengths
        self.averageLength = lengths.isEmpty ? 0 : Double(lengths.reduce(0, +)) / Double(lengths.count)
        self.documentFrequency = frequency
    }

    /// One score per document, 0 when no query term occurs in it.
    func scores(for query: String) -> [Double] {
        let terms = KeywordQuery.terms(in: query).map(Self.stem)
        let count = Double(documents.count)
        let k1 = 1.2, b = 0.75
        return documents.indices.map { index in
            var score = 0.0
            for term in terms {
                guard let tf = documents[index][term], let df = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(df) + 0.5) / (Double(df) + 0.5))
                let norm = Double(tf) * (k1 + 1) / (Double(tf) + k1 * (1 - b + b * Double(lengths[index]) / max(averageLength, 1)))
                score += idf * norm
            }
            return score
        }
    }

    /// A deliberately light stemmer, so "bars" finds "bar" and "explained"
    /// finds "explain" without a dictionary.
    static func stem(_ token: String) -> String {
        guard token.count > 3, token.allSatisfy(\.isLetter) else { return token }
        for suffix in ["ing", "ed", "es", "s"] where token.hasSuffix(suffix) && token.count - suffix.count >= 3 {
            return String(token.dropLast(suffix.count))
        }
        return token
    }
}
