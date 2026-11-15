import Foundation
import Accelerate

/// Finds content written twice: passages copied with small changes
/// (overlapping 5-word sequences), passages that say the same thing in
/// other words (embedding similarity), repeated sentences, repeated
/// headings, and doubled words ("the the").
///
/// Pure: the caller reads files and supplies embeddings.
enum RepetitionFinder {

    /// One paragraph of prose.
    struct Unit: Equatable, Sendable {
        let path: String
        let startLine: Int
        let endLine: Int
        let text: String
        /// The heading of the innermost section holding the paragraph.
        let section: String?
        /// Index of this paragraph within its file, for adjacency.
        let order: Int
    }

    /// Paragraphs shorter than this are too short to call a duplicate.
    static let minimumWords = 12

    static func units(in source: String, path: String) -> [Unit] {
        let lines = ProseText.lines(in: source, isMarkdown: ProseText.isMarkdown(path), inline: .keep)
        let paragraphs = ProseText.paragraphs(from: lines).filter { $0.kind == .paragraph }
        let headings = DocumentOutline.entries(in: source).filter { $0.endLine != nil }
        func section(_ line: Int) -> String? {
            headings.last { $0.line <= line && ($0.endLine ?? 0) >= line }?.text
        }
        return paragraphs.enumerated().compactMap { index, paragraph in
            guard ProseText.wordCount(paragraph.text) >= minimumWords else { return nil }
            return Unit(path: path, startLine: paragraph.startLine, endLine: paragraph.endLine,
                        text: paragraph.text, section: section(paragraph.startLine), order: index)
        }
    }

    // MARK: Copied passages

    struct CopyMatch: Equatable, Sendable {
        /// First and last unit of each side of the run.
        let first: (start: Unit, end: Unit)
        let second: (start: Unit, end: Unit)
        /// Share of the shorter side's 5-word sequences found in the other.
        let overlap: Double
        let paragraphs: Int

        static func == (lhs: CopyMatch, rhs: CopyMatch) -> Bool {
            lhs.first.start == rhs.first.start && lhs.second.start == rhs.second.start && lhs.paragraphs == rhs.paragraphs
        }
    }

    static let shingleSize = 5
    /// Overlap from which two paragraphs count as copies.
    static let copyThreshold = 0.5
    /// A 5-word sequence in more paragraphs than this is boilerplate.
    private static let maxShingleFrequency = 25

    /// Lowercased words, split by `NLTokenizer` for scripts without spaces,
    /// so copy detection works in Chinese or Japanese too.
    static func normalizedWords(_ text: String) -> [String] {
        ProseLanguage.words(text)
    }

    static func shingles(_ text: String) -> Set<Int> {
        let words = normalizedWords(text)
        guard words.count >= shingleSize else { return words.isEmpty ? [] : [words.joined(separator: " ").hashValue] }
        var result = Set<Int>()
        for start in 0...(words.count - shingleSize) {
            result.insert(words[start..<(start + shingleSize)].joined(separator: " ").hashValue)
        }
        return result
    }

    /// Pairs of paragraphs that share most of their wording, with runs of
    /// consecutive copied paragraphs merged into one match ("lines 120-160
    /// ≈ lines 840-880") — a repeated section reads as one finding.
    static func copiedPassages(_ units: [Unit]) -> [CopyMatch] {
        let sets = units.map { shingles($0.text) }
        var index: [Int: [Int]] = [:]
        for (unit, set) in sets.enumerated() {
            for shingle in set { index[shingle, default: []].append(unit) }
        }
        var shared: [Int: Int] = [:] // pair key → shared shingles
        let count = units.count
        for (_, holders) in index where holders.count > 1 && holders.count <= maxShingleFrequency {
            for a in holders.indices {
                for b in holders.indices where b > a {
                    shared[holders[a] * count + holders[b], default: 0] += 1
                }
            }
        }
        var overlaps: [Int: Double] = [:]
        for (key, sharedCount) in shared where sharedCount >= 2 {
            let a = key / count, b = key % count
            let overlap = Double(sharedCount) / Double(max(1, min(sets[a].count, sets[b].count)))
            if overlap >= copyThreshold { overlaps[key] = overlap }
        }

        func key(_ a: Int, _ b: Int) -> Int { a * count + b }
        func follows(_ next: Int, _ previous: Int) -> Bool {
            next < count && units[next].path == units[previous].path && units[next].order == units[previous].order + 1
        }
        var matches: [CopyMatch] = []
        for pairKey in overlaps.keys.sorted() {
            let a = pairKey / count, b = pairKey % count
            // Part of a run that started on an earlier pair.
            if a > 0, b > 0, follows(a, a - 1), follows(b, b - 1), overlaps[key(a - 1, b - 1)] != nil { continue }
            var length = 1
            var total = overlaps[pairKey]!
            while follows(a + length, a + length - 1), follows(b + length, b + length - 1),
                  a + length < b, let next = overlaps[key(a + length, b + length)] {
                total += next
                length += 1
            }
            matches.append(CopyMatch(
                first: (units[a], units[a + length - 1]),
                second: (units[b], units[b + length - 1]),
                overlap: total / Double(length),
                paragraphs: length
            ))
        }
        return matches.sorted { $0.paragraphs != $1.paragraphs ? $0.paragraphs > $1.paragraphs : $0.overlap > $1.overlap }
    }

    // MARK: Same meaning

    struct MeaningMatch: Equatable, Sendable {
        let first: Unit
        let second: Unit
        let similarity: Double
    }

    /// The similarity two paragraphs must reach to count as saying the same
    /// thing: most of the way from the model's noise floor (unrelated texts)
    /// to identical. With nomic-embed-text (floor ≈ 0.42) that is ≈ 0.86.
    static func meaningThreshold(noiseFloor: Double?) -> Double {
        let floor = noiseFloor ?? 0.3
        return floor + (1 - floor) * 0.75
    }

    /// Paragraph pairs above `threshold`, best first. Neighbouring
    /// paragraphs (which naturally share a topic) and pairs already
    /// reported as copies are skipped.
    static func meaningMatches(
        _ units: [Unit],
        vectors: [[Float]?],
        threshold: Double,
        excluding copies: [CopyMatch],
        limit: Int = 15
    ) -> [MeaningMatch] {
        // Normalize once, so each pair is one dot product.
        let normalized: [[Float]?] = vectors.map { vector in
            guard let vector, !vector.isEmpty else { return nil }
            var norm: Float = 0
            vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
            guard norm > 0 else { return nil }
            var scale = 1 / norm.squareRoot()
            var result = [Float](repeating: 0, count: vector.count)
            vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
            return result
        }
        func covered(_ a: Unit, _ b: Unit) -> Bool {
            copies.contains { match in
                let inFirst = { (unit: Unit) in unit.path == match.first.start.path && unit.order >= match.first.start.order && unit.order <= match.first.end.order }
                let inSecond = { (unit: Unit) in unit.path == match.second.start.path && unit.order >= match.second.start.order && unit.order <= match.second.end.order }
                return (inFirst(a) && inSecond(b)) || (inFirst(b) && inSecond(a))
            }
        }
        var matches: [MeaningMatch] = []
        for i in units.indices {
            guard let a = normalized[i] else { continue }
            for j in units.indices where j > i {
                guard let b = normalized[j], a.count == b.count else { continue }
                if units[i].path == units[j].path, abs(units[i].order - units[j].order) <= 1 { continue }
                var dot: Float = 0
                vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
                if Double(dot) >= threshold, !covered(units[i], units[j]) {
                    matches.append(MeaningMatch(first: units[i], second: units[j], similarity: Double(dot)))
                }
            }
        }
        return Array(matches.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    // MARK: Small repeats

    struct RepeatedSentence: Equatable, Sendable {
        let text: String
        let locations: [(path: String, line: Int)]

        static func == (lhs: RepeatedSentence, rhs: RepeatedSentence) -> Bool {
            lhs.text == rhs.text && lhs.locations.map(\.line) == rhs.locations.map(\.line)
        }
    }

    /// Sentences of 6+ words that occur more than once (ignoring case and
    /// punctuation).
    static func repeatedSentences(in files: [(path: String, text: String)]) -> [RepeatedSentence] {
        var seen: [String: (text: String, locations: [(path: String, line: Int)])] = [:]
        var order: [String] = []
        for file in files {
            let lines = ProseText.lines(in: file.text, isMarkdown: ProseText.isMarkdown(file.path), inline: .keep)
            let paragraphs = ProseText.paragraphs(from: lines).filter { $0.kind != .heading }
            for sentence in ProseText.sentences(in: paragraphs) {
                let words = normalizedWords(sentence.text)
                guard words.count >= 6 else { continue }
                let key = words.joined(separator: " ")
                if seen[key] == nil { order.append(key); seen[key] = (sentence.text, []) }
                seen[key]?.locations.append((file.path, sentence.line))
            }
        }
        return order.compactMap { key in
            guard let entry = seen[key], entry.locations.count > 1 else { return nil }
            return RepeatedSentence(text: entry.text, locations: entry.locations)
        }
    }

    /// Headings with the same title more than once in one file.
    static func repeatedHeadings(in source: String) -> [[DocumentOutline.Entry]] {
        var groups: [String: [DocumentOutline.Entry]] = [:]
        var order: [String] = []
        for entry in DocumentOutline.entries(in: source) where entry.endLine != nil {
            let key = DocumentOutline.normalizedTitle(entry.text)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.compactMap { groups[$0]!.count > 1 ? groups[$0] : nil }
    }

    /// "the the", "is is": the same word twice in a row (numbers excepted).
    /// Words written with spaces only; in Chinese a repeated character is
    /// often correct grammar.
    static func doubledWords(in source: String, isMarkdown: Bool) -> [(line: Int, text: String)] {
        let regex = try! NSRegularExpression(pattern: "\\b(\\p{L}+)\\s+\\1\\b", options: [.caseInsensitive])
        var found: [(line: Int, text: String)] = []
        for line in ProseText.lines(in: source, isMarkdown: isMarkdown, inline: .placeholder) {
            let text = line.text as NSString
            for match in regex.matches(in: line.text, range: NSRange(location: 0, length: text.length)) {
                let word = text.substring(with: match.range(at: 1)).lowercased()
                // Grammatical doubles: "had had", "die die Tür", "nous nous levons".
                guard !["had", "that", "bye", "ha", "die", "der", "das", "nous", "vous"].contains(word) else { continue }
                found.append((line.number, text.substring(with: match.range)))
            }
        }
        return found
    }

    // MARK: Rendering

    enum MeaningStatus: Equatable, Sendable {
        case checked(model: String, threshold: Double)
        case skippedWeakModel
        case unavailable
    }

    struct Report: Sendable {
        var copies: [CopyMatch] = []
        var meaning: [MeaningMatch] = []
        var meaningStatus: MeaningStatus = .unavailable
        var sentences: [RepeatedSentence] = []
        var headings: [(path: String, entries: [DocumentOutline.Entry])] = []
        var doubled: [(path: String, line: Int, text: String)] = []
        var paragraphCount = 0
        var fileCount = 0
    }

    static let maxListed = 15

    static func render(_ report: Report, scopeLabel: String) -> String {
        func place(_ start: Unit, _ end: Unit) -> String {
            let section = start.section.map { " in \($0)" } ?? ""
            return "\(start.path):\(start.startLine)-\(end.endLine)\(section)"
        }
        var output = "[repetition check of \(scopeLabel) — \(report.paragraphCount) paragraphs in \(report.fileCount) file\(report.fileCount == 1 ? "" : "s")]"
        var any = false

        if !report.copies.isEmpty {
            any = true
            output += "\n\nCopied passages (\(report.copies.count)) — the same wording twice, maybe with small changes:"
            for match in report.copies.prefix(maxListed) {
                let size = match.paragraphs > 1 ? ", \(match.paragraphs) paragraphs in a row" : ""
                output += "\n  \(place(match.first.start, match.first.end)) ≈ \(place(match.second.start, match.second.end)) (\(Int((match.overlap * 100).rounded()))% same wording\(size))"
            }
            if report.copies.count > maxListed { output += "\n  … \(report.copies.count - maxListed) more" }
        }

        switch report.meaningStatus {
        case .checked(let model, let threshold):
            if !report.meaning.isEmpty {
                any = true
                output += "\n\nSame meaning, different words (\(report.meaning.count)) — by \(model), similarity ≥ \(String(format: "%.2f", threshold)); read both before merging, the details may differ:"
                for match in report.meaning {
                    output += "\n  \(place(match.first, match.first)) ~ \(place(match.second, match.second)) (similarity \(String(format: "%.2f", match.similarity)))"
                }
            }
        case .skippedWeakModel:
            output += "\n\n(Same-meaning check skipped: Apple's built-in embedding can't tell paraphrases from related text. Set an embedding model in Settings to enable it.)"
        case .unavailable:
            output += "\n\n(Same-meaning check skipped: no embedding model reachable.)"
        }

        if !report.sentences.isEmpty {
            any = true
            output += "\n\nRepeated sentences (\(report.sentences.count)):"
            for sentence in report.sentences.prefix(maxListed) {
                let clipped = sentence.text.count > 80 ? String(sentence.text.prefix(80)) + "…" : sentence.text
                let at = sentence.locations.prefix(4).map { "\($0.path):\($0.line)" }.joined(separator: ", ")
                output += "\n  \"\(clipped)\" at \(at)"
            }
            if report.sentences.count > maxListed { output += "\n  … \(report.sentences.count - maxListed) more" }
        }
        if !report.headings.isEmpty {
            any = true
            output += "\n\nRepeated headings (\(report.headings.count)) — fine under different parents, otherwise likely duplicate sections:"
            for group in report.headings.prefix(maxListed) {
                output += "\n  " + group.entries.map { "\(group.path):\($0.line)-\($0.endLine ?? $0.line): \($0.text)" }.joined(separator: " | ")
            }
        }
        if !report.doubled.isEmpty {
            any = true
            output += "\n\nDoubled words (\(report.doubled.count)):"
            for hit in report.doubled.prefix(maxListed) {
                output += "\n  \(hit.path):\(hit.line): \"\(hit.text)\""
            }
        }

        if !any { return output + "\n\nNo repeated content found." }
        output += "\n\nTo combine two sections, call merge_sections with keep: and remove: (it aligns their sentences and checks that no fact is lost). To drop a pure copy, delete it with edit_file."
        return output
    }
}
