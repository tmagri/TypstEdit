import Foundation
import NaturalLanguage

/// Compares the facts in a passage before and after a rewrite: numbers,
/// cross-references and labels, names and acronyms, code and math, URLs,
/// and the words that flip or weaken meaning (negations; must/always/only).
///
/// A rewrite for simpler wording is exactly where a cheap model drops "none
/// of", turns 1,240 into 1,200, or loses a `@fig` reference. This catches
/// those mechanically, the way the compile check catches broken syntax.
/// Multiset comparison: a number that appeared twice and now appears once
/// counts as missing once.
enum FactCheck {

    enum Kind: String, CaseIterable, Sendable {
        case number, reference, label, name, code, url
        var title: String {
            switch self {
            case .number: return "number"
            case .reference: return "reference"
            case .label: return "label"
            case .name: return "name"
            case .code: return "code/math"
            case .url: return "link"
            }
        }
    }

    struct Fact: Hashable, Sendable {
        let kind: Kind
        /// Normalized for comparison ("1,240" → "1240", names lowercased).
        let key: String
        /// As written in the text, for the message.
        let display: String

        static func == (lhs: Fact, rhs: Fact) -> Bool { lhs.kind == rhs.kind && lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(kind); hasher.combine(key) }
    }

    struct Report: Sendable, Equatable {
        /// Facts in the old text that the new text has fewer of.
        var missing: [Fact] = []
        /// Facts in the new text that the old text didn't have (possibly
        /// invented).
        var added: [Fact] = []
        /// Negation words, before → after (contractions count as "not").
        var negations: (before: Int, after: Int) = (0, 0)
        /// Negation words that disappeared, for the message.
        var lostNegations: [String] = []
        /// must / shall / always / only / never-style strength words that
        /// disappeared.
        var lostQualifiers: [String] = []
        var factCount = 0
        var language: NLLanguage?
        /// Whether negations and strength words could be checked (the
        /// language has a word list).
        var hasWordList = true

        var isClean: Bool { missing.isEmpty && added.isEmpty && negations.after >= negations.before && lostQualifiers.isEmpty }

        static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.missing == rhs.missing && lhs.added == rhs.added && lhs.negations == rhs.negations
                && lhs.lostNegations == rhs.lostNegations && lhs.lostQualifiers == rhs.lostQualifiers
        }
    }

    /// Fewest prose words in the old text for a change to count as a prose
    /// rewrite; below this (a code fix, a one-word typo) nothing is checked.
    static let minimumProseWords = 4

    // MARK: Extraction

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static let numberRegex = regex("(?<![\\p{L}\\p{N}_.\\-])[-−]?\\d+(?:[.,]\\d+)*(?![\\p{L}_])")
    private static let refRegex = regex("(?<![\\p{L}\\p{N}_.@/\"'\\\\])@([\\p{L}\\p{N}_][\\p{L}\\p{N}_\\-:.]*[\\p{L}\\p{N}_])")
    private static let labelRegex = regex("<([\\p{L}\\p{N}_][\\p{L}\\p{N}_\\-:.]*)>")
    private static let codeRegex = regex("`([^`]+)`|\\$([^$]+)\\$")
    private static let urlRegex = regex("https?://[^\\s)\\]>\"]+")
    private static let acronymRegex = regex("\\b[A-Z][A-Z0-9]+(?:-[A-Z0-9]+)*\\b")

    /// Every fact in `text`, with repeats (a multiset). `pack` supplies the
    /// spelled-out number words of the text's language, if it has one.
    static func facts(in text: String, isMarkdown: Bool = false, pack: ProseLanguage.Pack? = ProseLanguage.english) -> [Fact] {
        var facts: [Fact] = []
        let whole = NSRange(location: 0, length: (text as NSString).length)
        /// The whole match (group 0) or one capture group of every match.
        func strings(_ regex: NSRegularExpression, in source: String, group: Int = 0) -> [String] {
            regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)).compactMap { match in
                guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: source) else { return nil }
                return String(source[range])
            }
        }

        // Raw-text facts: references, labels, links, code — they live in
        // code lines and markup too.
        for name in strings(refRegex, in: text, group: 1) {
            facts.append(Fact(kind: .reference, key: name, display: "@" + name))
        }
        for name in strings(labelRegex, in: text, group: 1) {
            facts.append(Fact(kind: .label, key: name, display: "<\(name)>"))
        }
        for url in strings(urlRegex, in: text) {
            let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'"))
            facts.append(Fact(kind: .url, key: trimmed, display: trimmed))
        }
        for match in codeRegex.matches(in: text, range: whole) {
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let range = Range(match.range(at: group), in: text) else { continue }
            let code = text[range].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !code.isEmpty else { continue }
            facts.append(Fact(kind: .code, key: code, display: group == 1 ? "`\(code)`" : "$\(code)$"))
        }

        // Prose facts: numbers and names, from the words a reader sees
        // (code lines and inline code removed so `#set page(margin: 2cm)`
        // is not a "number").
        let prose = ProseText.lines(in: text, isMarkdown: isMarkdown, inline: .placeholder)
            .map(\.text).joined(separator: "\n")
        for number in strings(numberRegex, in: prose) {
            let key = number.replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: ",", with: "") // 1,240 == 1240
            facts.append(Fact(kind: .number, key: key, display: number))
        }
        if let numberWords = pack?.numberWords {
            for word in prose.split(whereSeparator: { !$0.isLetter }) {
                if let value = numberWords[word.lowercased()] {
                    facts.append(Fact(kind: .number, key: value, display: String(word)))
                }
            }
        }
        for acronym in strings(acronymRegex, in: prose) where acronym != "CODE" && acronym != "MATH" {
            facts.append(Fact(kind: .name, key: acronym.lowercased(), display: acronym))
        }
        facts += names(in: prose)
        return facts
    }

    /// People, places and organizations, by Apple's on-device tagger.
    private static func names(in text: String) -> [Fact] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: [Fact] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let name = String(text[range])
                // Acronyms are already counted.
                if name != name.uppercased() {
                    found.append(Fact(kind: .name, key: name.lowercased(), display: name))
                }
            }
            return true
        }
        return found
    }

    private static func lowercaseWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}")) }
    }

    // MARK: Comparison

    /// The comparison, or nil when `old` isn't prose worth checking (a code
    /// edit, an insertion into nothing, a one-word fix).
    /// `documentLanguage` is used when the old text is too short to
    /// classify on its own.
    static func compare(old: String, new: String, isMarkdown: Bool = false, documentLanguage: NLLanguage? = nil) -> Report? {
        let oldProse = ProseText.lines(in: old, isMarkdown: isMarkdown).map(\.text).joined(separator: " ")
        guard ProseText.wordCount(oldProse) >= minimumProseWords else { return nil }
        let newProse = ProseText.lines(in: new, isMarkdown: isMarkdown).map(\.text).joined(separator: " ")
        // Prose untouched (a code-only change): not this check's job.
        guard oldProse != newProse else { return nil }

        var report = Report()
        // The old text's language decides the word lists (a rewrite keeps
        // the language; a translation is not a rewrite this checks).
        let language = ProseLanguage.detect(oldProse, fallback: documentLanguage)
        let pack = ProseLanguage.pack(for: language)
        report.language = language
        report.hasWordList = pack != nil

        let before = facts(in: old, isMarkdown: isMarkdown, pack: pack)
        let after = facts(in: new, isMarkdown: isMarkdown, pack: pack)
        report.factCount = before.count
        report.missing = multisetDifference(before, after)
        report.added = multisetDifference(after, before)

        guard let pack else { return report }
        let oldNegations = ProseLanguage.negations(in: oldProse, pack: pack)
        let newNegations = ProseLanguage.negations(in: newProse, pack: pack)
        report.negations = (oldNegations.count, newNegations.count)
        if newNegations.count < oldNegations.count {
            report.lostNegations = multisetDifference(oldNegations, newNegations)
        }
        let oldQualifiers = lowercaseWords(oldProse).filter(pack.qualifiers.contains)
        let newQualifiers = lowercaseWords(newProse).filter(pack.qualifiers.contains)
        report.lostQualifiers = multisetDifference(oldQualifiers, newQualifiers)
        return report
    }

    /// The check after merging several passages into one. A merge drops
    /// repeats on purpose, so counts can't be compared: every distinct fact
    /// of *any* part must still appear at least once, and the merged text
    /// needs at least as many negations as the most negative part.
    static func compareMerge(parts: [String], merged: String, isMarkdown: Bool = false) -> Report? {
        let partProse = parts.map { ProseText.lines(in: $0, isMarkdown: isMarkdown).map(\.text).joined(separator: " ") }
        let allProse = partProse.joined(separator: " ")
        guard ProseText.wordCount(allProse) >= minimumProseWords else { return nil }
        let mergedProse = ProseText.lines(in: merged, isMarkdown: isMarkdown).map(\.text).joined(separator: " ")

        var report = Report()
        let language = ProseLanguage.detect(allProse)
        let pack = ProseLanguage.pack(for: language)
        report.language = language
        report.hasWordList = pack != nil

        let before = parts.flatMap { facts(in: $0, isMarkdown: isMarkdown, pack: pack) }
        let after = facts(in: merged, isMarkdown: isMarkdown, pack: pack)
        let afterSet = Set(after), beforeSet = Set(before)
        var seen = Set<Fact>()
        report.factCount = beforeSet.count
        report.missing = before.filter { !afterSet.contains($0) && seen.insert($0).inserted }
        seen = []
        report.added = after.filter { !beforeSet.contains($0) && seen.insert($0).inserted }

        guard let pack else { return report }
        let partNegations = partProse.map { ProseLanguage.negations(in: $0, pack: pack) }
        let mergedNegations = ProseLanguage.negations(in: mergedProse, pack: pack)
        let most = partNegations.max { $0.count < $1.count } ?? []
        report.negations = (most.count, mergedNegations.count)
        if mergedNegations.count < most.count {
            report.lostNegations = multisetDifference(most, mergedNegations)
        }
        let mergedWords = Set(lowercaseWords(mergedProse))
        report.lostQualifiers = Array(Set(lowercaseWords(allProse).filter(pack.qualifiers.contains)))
            .filter { !mergedWords.contains($0) }
            .sorted()
        return report
    }

    /// Elements of `a` beyond their count in `b`, in `a`'s order.
    static func multisetDifference<T: Hashable>(_ a: [T], _ b: [T]) -> [T] {
        var remaining: [T: Int] = [:]
        for item in b { remaining[item, default: 0] += 1 }
        var result: [T] = []
        for item in a {
            if let count = remaining[item], count > 0 {
                remaining[item] = count - 1
            } else {
                result.append(item)
            }
        }
        return result
    }

    // MARK: Rendering

    /// The note appended to an edit's result.
    static func note(_ report: Report) -> String {
        let unchecked = report.hasWordList ? "" : " (Negations not checked: no word list for \(ProseLanguage.name(report.language)).)"
        guard !report.isClean else {
            return report.hasWordList
                ? "✓ Fact check: numbers, references, names and negations unchanged."
                : "✓ Fact check: numbers, references and names unchanged." + unchecked
        }
        var parts: [String] = []
        if report.negations.after < report.negations.before {
            let lost = report.lostNegations.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("fewer negations (\(report.negations.before) → \(report.negations.after)\(lost.isEmpty ? "" : ": \(lost) gone")) — check the meaning did not flip")
        }
        if !report.lostQualifiers.isEmpty {
            parts.append("weaker wording: \(report.lostQualifiers.map { "\"\($0)\"" }.joined(separator: ", ")) gone")
        }
        if !report.missing.isEmpty {
            parts.append("missing " + describe(report.missing))
        }
        if !report.added.isEmpty {
            parts.append("new " + describe(report.added) + " (not in the old text — make sure it is not invented)")
        }
        return "⚠️ Fact check (old text → new text): " + parts.joined(separator: "; ")
            + ". If a change is not intended, restore it from the old text." + unchecked
    }

    private static func describe(_ facts: [Fact]) -> String {
        let limit = 8
        let shown = facts.prefix(limit).map { "\($0.kind.title) \($0.display)" }.joined(separator: ", ")
        return facts.count > limit ? shown + ", … \(facts.count - limit) more" : shown
    }
}
