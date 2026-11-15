import Foundation
import NaturalLanguage

/// Merges two sections that repeat each other into one — extractively, so
/// no language model is needed and no word is invented.
///
/// The kept section's text stays as written. Each sentence of the removed
/// section is aligned against it:
/// - **covered** — already said, with the same facts → dropped;
/// - **conflict** — the same statement with different facts ("3.8" vs
///   "3.9", a lost "not") → kept next to its counterpart, and the merge
///   won't apply until someone decides;
/// - **new** — inserted word for word after the most related kept sentence.
/// Figures, tables, code and lists move as whole blocks. Sentences that open
/// with a word referring back ("This", "However") are flagged, since their
/// context may have been dropped. A model can still polish the result, but
/// the merge itself is exact and repeatable.
enum SectionMerger {

    struct Sentence: Equatable, Sendable {
        /// As written in the source (markup kept).
        let source: String
        /// What a reader sees, for comparison.
        let prose: String
        /// Character offset of the sentence's end in its block's source.
        let endOffset: Int
        let line: Int
    }

    /// A run of non-blank source lines inside a section body.
    struct Block: Equatable, Sendable {
        let startLine: Int
        let endLine: Int
        let source: String
        let prose: String
        /// Plain prose paragraphs only; empty for figures, code, lists.
        let sentences: [Sentence]
        var isProse: Bool { !sentences.isEmpty }
    }

    /// Where a sentence of the kept section sits: block, sentence.
    struct Anchor: Equatable, Hashable, Sendable {
        let block: Int
        let sentence: Int
    }

    enum Decision: Equatable, Sendable {
        case covered(by: Anchor?)
        case conflict(with: Anchor, differences: [String])
        case new(after: Anchor?)
    }

    enum BlockDecision: Equatable, Sendable {
        /// One decision per sentence of a prose block.
        case sentences([Decision])
        /// A non-prose block identical to one in the kept section.
        case duplicateBlock
        /// A non-prose block carried over whole, after kept block `near`.
        case carry(near: Int?)
    }

    struct Plan: Sendable {
        let keep: DocumentOutline.Entry
        let remove: DocumentOutline.Entry
        let keepBlocks: [Block]
        let removeBlocks: [Block]
        let decisions: [BlockDecision]
        let keepLabel: String?
        let removeLabel: String?
        let removeLabelUses: Int
        /// Lines of carried-over sentences that open with a referring word.
        let danglingStarts: [(line: Int, word: String)]
        let isMarkdown: Bool

        var conflictCount: Int {
            decisions.reduce(0) { total, decision in
                guard case .sentences(let items) = decision else { return total }
                return total + items.filter { if case .conflict = $0 { return true }; return false }.count
            }
        }
    }

    enum MergeError: Error, Equatable {
        case sameSection
        case nested
        var message: String {
            switch self {
            case .sameSection: return "keep and remove name the same section."
            case .nested: return "One section contains the other. Merge two sections side by side (move a subsection out first with move_lines)."
            }
        }
    }

    // MARK: Blocks

    /// Blocks of lines `first...last` (1-based) of `lines`.
    static func blocks(_ lines: [String], from first: Int, through last: Int, isMarkdown: Bool) -> [Block] {
        guard first >= 1, first <= min(last, lines.count) else { return [] }
        var result: [Block] = []
        var current: [String] = []
        var start = first
        var inFence = false
        func flush(endingAt end: Int) {
            defer { current = [] }
            guard !current.isEmpty else { return }
            let source = current.joined(separator: "\n")
            let proseLines = ProseText.lines(in: source, isMarkdown: isMarkdown, inline: .keep)
            let prose = proseLines.map(\.text).joined(separator: " ")
            // Sentence surgery only on plain paragraphs: every line is prose
            // (no code line, list item, heading or table).
            let plain = !proseLines.isEmpty && proseLines.count == current.count
                && proseLines.allSatisfy { $0.kind == .paragraph }
            result.append(Block(startLine: start, endLine: end, source: source, prose: prose,
                                sentences: plain ? sentences(of: source, startLine: start, isMarkdown: isMarkdown) : []))
        }
        for number in first...min(last, lines.count) {
            let line = lines[number - 1]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if trimmed.isEmpty && !inFence {
                flush(endingAt: number - 1)
                start = number + 1
            } else {
                if current.isEmpty { start = number }
                current.append(line)
            }
        }
        flush(endingAt: min(last, lines.count))
        return result
    }

    /// Sentences of a plain paragraph, split in the *source* so they can be
    /// moved with their markup intact.
    private static func sentences(of source: String, startLine: Int, isMarkdown: Bool) -> [Sentence] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = source
        var result: [Sentence] = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            let text = source[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            let before = source[source.startIndex..<range.lowerBound]
            let line = startLine + before.filter { $0 == "\n" }.count
            // End of the sentence's last non-space character.
            var end = range.upperBound
            while end > range.lowerBound, source[source.index(before: end)].isWhitespace { end = source.index(before: end) }
            let prose = ProseText.clean(text.replacingOccurrences(of: "\n", with: " "), inline: .keep, isMarkdown: isMarkdown)
            result.append(Sentence(source: text.split(whereSeparator: \.isNewline).joined(separator: " "),
                                   prose: prose, endOffset: source.distance(from: source.startIndex, to: end), line: line))
            return true
        }
        return result
    }

    // MARK: Similarity

    /// Share of `a`'s 5-word sequences that also occur in `b`.
    static func containment(_ a: String, in b: String) -> Double {
        let shinglesA = RepetitionFinder.shingles(a)
        guard !shinglesA.isEmpty else { return 0 }
        return Double(shinglesA.intersection(RepetitionFinder.shingles(b)).count) / Double(shinglesA.count)
    }

    /// Share of `a`'s content words that also occur in `b`.
    static func termCoverage(_ a: String, in b: String) -> Double {
        let termsA = Set(SectionFinder.terms(a))
        guard !termsA.isEmpty else { return 0 }
        return Double(termsA.intersection(Set(SectionFinder.terms(b))).count) / Double(termsA.count)
    }

    /// A sentence is already said when its wording, or nearly all of its
    /// content words, appear in the kept text.
    static func isCovered(_ sentence: String, by text: String) -> Bool {
        containment(sentence, in: text) >= 0.5 || termCoverage(sentence, in: text) >= 0.8
    }

    // MARK: Plan

    static func plan(source: String, keep: DocumentOutline.Entry, remove: DocumentOutline.Entry, isMarkdown: Bool) -> Result<Plan, MergeError> {
        guard keep.line != remove.line else { return .failure(.sameSection) }
        let keepEnd = keep.endLine ?? keep.line, removeEnd = remove.endLine ?? remove.line
        if (keep.line < remove.line && keepEnd >= remove.line) || (remove.line < keep.line && removeEnd >= keep.line) {
            return .failure(.nested)
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let keepBlocks = blocks(lines, from: keep.line + 1, through: keepEnd, isMarkdown: isMarkdown)
        let removeBlocks = blocks(lines, from: remove.line + 1, through: removeEnd, isMarkdown: isMarkdown)

        let keptProse = keepBlocks.map(\.prose).joined(separator: " ")
        let keptFacts = Set(FactCheck.facts(in: keepBlocks.map(\.source).joined(separator: "\n\n"), isMarkdown: isMarkdown))
        let language = ProseLanguage.detect(keptProse + " " + removeBlocks.map(\.prose).joined(separator: " "))
        let pack = ProseLanguage.pack(for: language ?? .english)
        let anchors: [(Anchor, Sentence)] = keepBlocks.enumerated().flatMap { blockIndex, block in
            block.sentences.enumerated().map { (Anchor(block: blockIndex, sentence: $0.offset), $0.element) }
        }
        let normalizedKeepSources = Set(keepBlocks.map { normalize($0.source) })

        var decisions: [BlockDecision] = []
        var dangling: [(line: Int, word: String)] = []
        for block in removeBlocks {
            guard block.isProse else {
                if normalizedKeepSources.contains(normalize(block.source)) {
                    decisions.append(.duplicateBlock)
                } else {
                    decisions.append(.carry(near: nearestBlock(to: block.prose.isEmpty ? block.source : block.prose, in: keepBlocks)))
                }
                continue
            }
            var items: [Decision] = []
            for (index, sentence) in block.sentences.enumerated() {
                let best = anchors.map { ($0.0, max(containment(sentence.prose, in: $0.1.prose), termCoverage(sentence.prose, in: $0.1.prose))) }
                    .max { $0.1 < $1.1 }
                let bestAnchor = (best?.1 ?? 0) > 0.15 ? best?.0 : nil

                let decision: Decision
                if isCovered(sentence.prose, by: keptProse) {
                    // Said already — but only drop it if its facts are too.
                    let missing = FactCheck.facts(in: sentence.source, isMarkdown: isMarkdown)
                        .filter { !keptFacts.contains($0) }
                        .map { "\($0.kind.title) \($0.display)" }
                    var differences = missing
                    if let pack, let anchor = bestAnchor, let counterpart = anchors.first(where: { $0.0 == anchor })?.1 {
                        let ours = ProseLanguage.negations(in: sentence.prose, pack: pack).count
                        let theirs = ProseLanguage.negations(in: counterpart.prose, pack: pack).count
                        if ours != theirs { differences.append("negation (\(ours) vs \(theirs))") }
                    }
                    if differences.isEmpty {
                        decision = .covered(by: bestAnchor)
                    } else if let anchor = bestAnchor {
                        decision = .conflict(with: anchor, differences: differences)
                    } else {
                        decision = .new(after: nil)
                    }
                } else {
                    decision = .new(after: bestAnchor)
                }
                items.append(decision)

                // A carried sentence that refers back to one that was dropped.
                if case .covered = decision {} else if let pack, let first = ProseLanguage.words(sentence.prose).first,
                    pack.referringStarters.contains(first) {
                    let previousDropped = index > 0 && { if case .covered = items[index - 1] { return true }; return false }()
                    if index == 0 || previousDropped { dangling.append((sentence.line, first)) }
                }
            }
            decisions.append(.sentences(items))
        }

        let removeLabel = DocumentOutline.label(of: remove.text)
        return .success(Plan(
            keep: keep, remove: remove, keepBlocks: keepBlocks, removeBlocks: removeBlocks, decisions: decisions,
            keepLabel: DocumentOutline.label(of: keep.text), removeLabel: removeLabel,
            removeLabelUses: removeLabel.map { referenceCount(of: $0, in: source) } ?? 0,
            danglingStarts: dangling, isMarkdown: isMarkdown
        ))
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func nearestBlock(to text: String, in blocks: [Block]) -> Int? {
        let scored = blocks.indices.map { ($0, termCoverage(text, in: blocks[$0].prose)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0.15 else { return nil }
        return best.0
    }

    // MARK: Extractive body

    /// The merged body: the kept text as written, with the removed
    /// section's new (and, with `keepConflicts`, conflicting) sentences
    /// inserted after their anchor sentence, and its whole blocks after
    /// their nearest kept block. Sentences with no anchor form a closing
    /// paragraph.
    static func mergedBody(_ plan: Plan, keepConflicts: Bool) -> String {
        var insertions: [Anchor: [String]] = [:]
        var carriedAfter: [Int: [String]] = [:]
        var closing: [String] = []
        var closingParagraph: [String] = []
        for (block, decision) in zip(plan.removeBlocks, plan.decisions) {
            switch decision {
            case .duplicateBlock:
                continue
            case .carry(let near):
                if let near { carriedAfter[near, default: []].append(block.source) } else { closing.append(block.source) }
            case .sentences(let items):
                for (sentence, item) in zip(block.sentences, items) {
                    switch item {
                    case .covered:
                        continue
                    case .conflict(let anchor, _):
                        if keepConflicts { insertions[anchor, default: []].append(sentence.source) }
                    case .new(let anchor):
                        if let anchor { insertions[anchor, default: []].append(sentence.source) } else { closingParagraph.append(sentence.source) }
                    }
                }
            }
        }

        var parts: [String] = []
        for (blockIndex, block) in plan.keepBlocks.enumerated() {
            var text = block.source
            // Back to front, so earlier offsets stay valid.
            for (sentenceIndex, sentence) in block.sentences.enumerated().reversed() {
                guard let added = insertions[Anchor(block: blockIndex, sentence: sentenceIndex)], !added.isEmpty else { continue }
                let index = text.index(text.startIndex, offsetBy: sentence.endOffset)
                text.insert(contentsOf: " " + added.joined(separator: " "), at: index)
            }
            parts.append(text)
            parts += carriedAfter[blockIndex] ?? []
        }
        if !closingParagraph.isEmpty { parts.append(closingParagraph.joined(separator: " ")) }
        parts += closing
        return parts.joined(separator: "\n\n")
    }

    // MARK: Apply

    struct Applied: Equatable, Sendable {
        let text: String
        /// `@ref`/`<label>` uses changed from the removed label to the kept one.
        let retargeted: Int
        /// The removed heading's label was moved onto the kept heading.
        let movedLabel: String?
    }

    /// `source` with the kept section's body replaced by `mergedBody` and
    /// the removed section deleted. A label on the removed heading stays
    /// valid: its references are pointed at the kept heading's label, or —
    /// when the kept heading has none — the label moves to it.
    static func apply(source: String, keep: DocumentOutline.Entry, remove: DocumentOutline.Entry, mergedBody: String) -> Applied {
        let endsWithNewline = source.hasSuffix("\n")
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        let keepEnd = min(keep.endLine ?? keep.line, lines.count)
        let removeEnd = min(remove.endLine ?? remove.line, lines.count)

        var body = mergedBody.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
        // Keep the blank line that separated the section from the next one.
        if keepEnd > keep.line, lines[keepEnd - 1].trimmingCharacters(in: .whitespaces).isEmpty { body.append("") }

        var movedLabel: String?
        let keepLabel = DocumentOutline.label(of: keep.text)
        let removeLabel = DocumentOutline.label(of: remove.text)
        var keepHeading = lines[keep.line - 1]
        if let removeLabel, keepLabel == nil {
            keepHeading += " <\(removeLabel)>"
            movedLabel = removeLabel
        }

        // Bottom-up, so the earlier range's line numbers stay valid.
        let headingIndex: Int
        if remove.line > keep.line {
            lines.removeSubrange((remove.line - 1)..<removeEnd)
            lines.replaceSubrange(keep.line..<keepEnd, with: body)
            headingIndex = keep.line - 1
        } else {
            lines.replaceSubrange(keep.line..<keepEnd, with: body)
            lines.removeSubrange((remove.line - 1)..<removeEnd)
            headingIndex = keep.line - 1 - (removeEnd - remove.line + 1)
        }
        lines[headingIndex] = keepHeading

        var text = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        var retargeted = 0
        if let removeLabel, let keepLabel {
            (text, retargeted) = retarget(removeLabel, to: keepLabel, in: text)
        }
        return Applied(text: text, retargeted: retargeted, movedLabel: movedLabel)
    }

    private static func referencePattern(_ label: String) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        // Not the start of a longer name ("@results" vs "@results-2").
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_.@/])@\(escaped)(?![\\p{L}\\p{N}_]|[\\-:.][\\p{L}\\p{N}_])|<\(escaped)>")
    }

    static func referenceCount(of label: String, in text: String) -> Int {
        let matches = referencePattern(label).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        // `<label>` is the definition (or a ref() argument); count `@` uses.
        return matches.filter { (text as NSString).substring(with: $0.range).hasPrefix("@") }.count
    }

    static func retarget(_ old: String, to new: String, in text: String) -> (String, Int) {
        let regex = referencePattern(old)
        let ns = text as NSString
        var output = ""
        var cursor = 0
        var count = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += ns.substring(with: match.range).hasPrefix("@") ? "@\(new)" : "<\(new)>"
            cursor = match.range.upperBound
            count += 1
        }
        output += ns.substring(from: cursor)
        return (output, count)
    }

    // MARK: Rendering

    static let maxListed = 12

    static func render(_ plan: Plan, path: String) -> String {
        func clip(_ text: String, _ limit: Int = 90) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
        func anchorText(_ anchor: Anchor?) -> String {
            guard let anchor, plan.keepBlocks.indices.contains(anchor.block),
                  plan.keepBlocks[anchor.block].sentences.indices.contains(anchor.sentence) else { return "the end of the section" }
            let sentence = plan.keepBlocks[anchor.block].sentences[anchor.sentence]
            return "line \(sentence.line) (\"\(clip(sentence.prose, 50))\")"
        }

        var dropped: [String] = [], added: [String] = [], conflicts: [String] = [], carried: [String] = []
        var duplicates = 0
        for (block, decision) in zip(plan.removeBlocks, plan.decisions) {
            switch decision {
            case .duplicateBlock:
                duplicates += 1
            case .carry:
                let first = block.source.components(separatedBy: "\n").first ?? ""
                carried.append("  lines \(block.startLine)-\(block.endLine): \(clip(first))")
            case .sentences(let items):
                for (sentence, item) in zip(block.sentences, items) {
                    switch item {
                    case .covered(let anchor):
                        dropped.append("  line \(sentence.line): \"\(clip(sentence.prose))\"" + (anchor == nil ? "" : " ≈ \(anchorText(anchor))"))
                    case .new(let anchor):
                        added.append("  line \(sentence.line): \"\(clip(sentence.prose))\" → after \(anchorText(anchor))")
                    case .conflict(let anchor, let differences):
                        conflicts.append("  line \(sentence.line): \"\(clip(sentence.prose))\" vs \(anchorText(anchor)) — differs in: \(differences.joined(separator: ", "))")
                    }
                }
            }
        }

        var output = "[merge plan for '\(path)': keep \(plan.keep.text) (lines \(plan.keep.line)-\(plan.keep.endLine ?? plan.keep.line)), remove \(plan.remove.text) (lines \(plan.remove.line)-\(plan.remove.endLine ?? plan.remove.line)) — extractive: every word comes from one of the two sections]"
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            output += "\n\n\(title) (\(items.count)):\n" + items.prefix(maxListed).joined(separator: "\n")
            if items.count > maxListed { output += "\n  … \(items.count - maxListed) more" }
        }
        section("Dropped — already said with the same facts", dropped)
        section("Added word for word", added)
        section("Conflicts — the same statement with different facts; both versions stay side by side until you decide", conflicts)
        section("Carried over whole (figures, tables, code, lists)", carried)
        if duplicates > 0 { output += "\n\n\(duplicates) block\(duplicates == 1 ? "" : "s") identical to the kept section dropped." }
        if !plan.danglingStarts.isEmpty {
            let listed = plan.danglingStarts.prefix(maxListed).map { "line \($0.line) (\"\($0.word)\")" }.joined(separator: ", ")
            output += "\n\nCheck these joins — the sentence opens with a word that refers back, and its context may be gone: \(listed)."
        }
        if let label = plan.removeLabel {
            output += plan.keepLabel.map { "\n\nLabel <\(label)> (\(plan.removeLabelUses) reference\(plan.removeLabelUses == 1 ? "" : "s")) will point to <\($0)>." }
                ?? "\n\nLabel <\(label)> (\(plan.removeLabelUses) reference\(plan.removeLabelUses == 1 ? "" : "s")) will move to the kept heading."
        }

        let fence = plan.isMarkdown ? "markdown" : "typst"
        output += "\n\nMerged body (what apply: true writes):\n```\(fence)\n\(mergedBody(plan, keepConflicts: true))\n```"
        if plan.conflictCount > 0 {
            output += "\nThere \(plan.conflictCount == 1 ? "is 1 conflict" : "are \(plan.conflictCount) conflicts"): resolve them — pass merged_text with the right version — or call with apply: true and keep_both: true to keep both versions."
        } else {
            output += "\nNext: call merge_sections again with the same keep and remove plus apply: true to write this. To smooth the joins first, pass merged_text with your edited version instead (body only, without the heading). Either way the user approves the diff and every fact of both sections is checked."
        }
        return output
    }
}
