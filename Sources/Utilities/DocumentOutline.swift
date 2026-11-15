import Foundation

/// The structure of a Typst or Markdown document, line by line: headings
/// and `#include` lines. Used by `read_file`'s outline mode (map a long
/// document in one small call) and by the chat's elision digests (keep
/// where things are after the text itself is dropped).
enum DocumentOutline {
    struct Entry: Equatable {
        enum Kind: Equatable {
            /// `= Title` / `# Title`, with its level (1 = top).
            case heading(level: Int)
            /// `#include "chapter.typ"` — part of the document lives elsewhere.
            case include
        }
        /// 1-based line number.
        let line: Int
        /// Last line of the section this heading starts (up to the next
        /// heading of the same or a higher level). `nil` for includes.
        let endLine: Int?
        let kind: Kind
        let text: String
    }

    /// Most entries an outline lists before it says how many it left out.
    static let maxEntries = 300

    /// A Typst (`= Title`) or Markdown (`# Title`) heading at the start of a
    /// line. Typst code such as `#set …` (no space after `#`) is not a heading.
    static func isHeadingLine(_ line: String) -> Bool {
        headingLevel(line) != nil
    }

    static func headingLevel(_ line: String) -> Int? {
        guard let first = line.first, first == "=" || first == "#" else { return nil }
        let marks = line.prefix(while: { $0 == first })
        guard marks.count <= 6 else { return nil }
        let rest = line.dropFirst(marks.count)
        guard rest.first == " ", rest.dropFirst().contains(where: { !$0.isWhitespace }) else { return nil }
        return marks.count
    }

    /// Headings and includes in `text`, skipping anything inside ``` raw /
    /// code blocks (a `# comment` in a shell snippet is not a heading).
    static func entries(in text: String) -> [Entry] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var found: [(line: Int, kind: Entry.Kind, text: String)] = []
        var inRawBlock = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inRawBlock.toggle()
                continue
            }
            guard !inRawBlock else { continue }
            if let level = headingLevel(line) {
                found.append((index + 1, .heading(level: level), clipped(line)))
            } else if trimmed.hasPrefix("#include ") || trimmed.hasPrefix("#include(") {
                found.append((index + 1, .include, clipped(trimmed)))
            }
        }

        let totalLines = lines.count
        return found.enumerated().map { position, item in
            guard case .heading(let level) = item.kind else {
                return Entry(line: item.line, endLine: nil, kind: item.kind, text: item.text)
            }
            let next = found[(position + 1)...].first { candidate in
                if case .heading(let otherLevel) = candidate.kind { return otherLevel <= level }
                return false
            }
            let end = next.map { $0.line - 1 } ?? totalLines
            return Entry(line: item.line, endLine: max(item.line, end), kind: item.kind, text: item.text)
        }
    }

    /// Entries overlapping the requested line range, plus the header text
    /// shared by the outline and skim renderings.
    private static func selection(
        _ text: String,
        startLine: Int?,
        endLine: Int?
    ) -> (lines: [String], entries: [Entry], rangeLabel: String, totalSuffix: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let all = entries(in: text)
        guard startLine != nil || endLine != nil else { return (lines, all, "", "") }
        let start = startLine ?? 1
        let end = endLine ?? lines.count
        let filtered = all.filter { entry in
            entry.line <= end && (entry.endLine ?? entry.line) >= start
        }
        return (lines, filtered, " (lines \(start)–\(end))", "total ")
    }

    private static func header(
        _ kind: String, label: String, rangeLabel: String, totalSuffix: String,
        totalLines: Int, entries: [Entry], note: String = ""
    ) -> String {
        let headingCount = entries.filter { if case .heading = $0.kind { return true } else { return false } }.count
        return "[\(kind) of '\(label)'\(rangeLabel) — \(totalLines) \(totalSuffix)line\(totalLines == 1 ? "" : "s"), \(headingCount) heading\(headingCount == 1 ? "" : "s")\(note)]"
    }

    /// The text `read_file` or `get_outline` returns in outline mode.
    static func render(_ text: String, label: String, startLine: Int? = nil, endLine: Int? = nil) -> String {
        let (lines, filtered, rangeLabel, totalSuffix) = selection(text, startLine: startLine, endLine: endLine)
        let output = header("outline", label: label, rangeLabel: rangeLabel, totalSuffix: totalSuffix,
                            totalLines: lines.count, entries: filtered)
        guard !filtered.isEmpty else {
            let note = (startLine != nil || endLine != nil) ? " in this range" : ""
            return output + "\nNo headings or #include lines found\(note). Read it with offset/limit instead."
        }
        return output + renderEntries(filtered)
    }

    private static func renderEntries(_ filtered: [Entry]) -> String {
        var output = ""
        for entry in filtered.prefix(maxEntries) {
            if let end = entry.endLine {
                output += "\n\(entry.line)-\(end): \(entry.text)"
            } else {
                output += "\n\(entry.line): \(entry.text)"
            }
        }
        if filtered.count > maxEntries {
            output += "\n… \(filtered.count - maxEntries) more entries not shown"
        }
        if let example = filtered.first(where: { $0.endLine != nil }), let end = example.endLine {
            output += "\nRead one section with read_file offset/limit from its line range — e.g. lines \(example.line)-\(end) are offset: \(example.line), limit: \(end - example.line + 1)."
            output += "\nMove a section with move_lines — e.g. start_line: \(example.line), end_line: \(end), start_text: \"\(example.text)\"."
        } else {
            output += "\nRead the parts you need with read_file offset/limit."
        }
        return output
    }

    // MARK: - Skim

    /// Lines of body text read from the top of a section to build its preview.
    static let skimLeadLineLimit = 30
    /// Total preview words in one skim. When a long document uses them up,
    /// the remaining sections are listed without previews (like
    /// `get_outline`) so the result stays a cheap map, never a re-read.
    static let skimTotalWordBudget = 2_500

    /// The prose at the top of a section: everything between its heading and
    /// the next heading of any level, without Typst code lines (`#set`,
    /// `#let`, …), comments, labels, or fenced blocks. A parent heading
    /// that goes straight into a subheading has no lead of its own; its
    /// children carry the previews.
    static func sectionLead(_ lines: [String], after headingLine: Int, through endLine: Int) -> String {
        var collected: [String] = []
        var inRawBlock = false
        var index = headingLine // 0-based index of the line after the heading
        let last = min(endLine, lines.count) // 1-based, inclusive
        while index < last, collected.count < skimLeadLineLimit {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.hasPrefix("```") { inRawBlock.toggle(); continue }
            if inRawBlock || trimmed.isEmpty { continue }
            if headingLevel(line) != nil { break }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*")
                || trimmed.hasPrefix("*/") || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) {
                continue
            }
            collected.append(trimmed)
        }
        return collected.joined(separator: " ")
    }

    /// An outline with a short preview of what each section says.
    ///
    /// `compress(text, keepRate)` shrinks a lead that is longer than
    /// `maxWordsPerSection` (LLMLingua-2 or the heuristic filter in the app).
    /// Short leads are shown verbatim — compressing an already-short
    /// sentence only makes it harder to read. Without `compress`, long leads
    /// are cut to their first words.
    static func renderSkim(
        _ text: String,
        label: String,
        startLine: Int? = nil,
        endLine: Int? = nil,
        maxWordsPerSection: Int = 40,
        compressorName: String? = nil,
        compress: (@Sendable (String, Double) async -> String)? = nil
    ) async -> String {
        let (lines, filtered, rangeLabel, totalSuffix) = selection(text, startLine: startLine, endLine: endLine)
        let maxWords = min(max(maxWordsPerSection, 5), 200)
        let note = compressorName.map { ", long previews condensed with \($0)" } ?? ""
        var output = header("skim", label: label, rangeLabel: rangeLabel, totalSuffix: totalSuffix,
                            totalLines: lines.count, entries: filtered, note: note)
        guard !filtered.isEmpty else {
            let rangeNote = (startLine != nil || endLine != nil) ? " in this range" : ""
            return output + "\nNo headings or #include lines found\(rangeNote). Read it with offset/limit instead."
        }

        var wordsLeft = skimTotalWordBudget
        var unpreviewed = 0
        for entry in filtered.prefix(maxEntries) {
            guard let end = entry.endLine else {
                output += "\n\(entry.line): \(entry.text)"
                continue
            }
            output += "\n\(entry.line)-\(end): \(entry.text)"
            let lead = sectionLead(lines, after: entry.line, through: end)
            guard !lead.isEmpty else { continue }
            guard wordsLeft > 0 else { unpreviewed += 1; continue }

            let words = lead.split(whereSeparator: \.isWhitespace)
            var preview = lead
            if words.count > maxWords {
                if let compress {
                    let rate = min(1, max(0.2, Double(maxWords) / Double(words.count)))
                    preview = await compress(lead, rate)
                }
                let kept = preview.split(whereSeparator: \.isWhitespace)
                if kept.count > maxWords {
                    preview = kept.prefix(maxWords).joined(separator: " ") + " …"
                }
            }
            preview = preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            wordsLeft -= preview.split(whereSeparator: \.isWhitespace).count
            output += "\n  Preview: \(preview)"
        }

        if filtered.count > maxEntries {
            output += "\n… \(filtered.count - maxEntries) more entries not shown"
        }
        if unpreviewed > 0 {
            output += "\n(\(unpreviewed) later section\(unpreviewed == 1 ? "" : "s") listed without a preview to keep this short — call skim_outline again with start_line/end_line for them.)"
        }
        if let example = filtered.first(where: { $0.endLine != nil }), let end = example.endLine {
            output += "\nPreviews are a quick guide, not the exact text. Read a section in full with read_file offset/limit — e.g. lines \(example.line)-\(end) are offset: \(example.line), limit: \(end - example.line + 1)."
            output += "\nMove a section with move_lines — e.g. start_line: \(example.line), end_line: \(end), start_text: \"\(example.text)\"."
        }
        return output
    }

    private static func clipped(_ line: String) -> String {
        line.count > 100 ? String(line.prefix(100)) + "…" : line
    }
}

// MARK: - Section Lookup

/// Finds a section by its heading text, so a tool can take
/// `section: "Introduction"` instead of line numbers. Line numbers are the
/// most common way a small model goes wrong after an earlier edit has
/// shifted the file; a heading name stays valid.
extension DocumentOutline {

    enum SectionLookup: Equatable {
        case found(Entry)
        /// Several headings match equally well.
        case ambiguous([Entry])
        /// Nothing matches; the closest headings, best first.
        case notFound(suggestions: [Entry])
    }

    /// A heading's title without its marks or trailing label:
    /// `"== Results <res>"` → `"Results"`.
    static func title(of headingText: String) -> String {
        var text = Substring(headingText)
        if let first = text.first, first == "=" || first == "#" {
            text = text.drop(while: { $0 == first })
        }
        var title = text.trimmingCharacters(in: .whitespaces)
        if title.hasSuffix(">"), let open = title.lastIndex(of: "<") {
            title = title[..<open].trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    /// The Typst label at the end of a heading line (`<res>` → `"res"`).
    static func label(of headingText: String) -> String? {
        let trimmed = headingText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(">"), let open = trimmed.lastIndex(of: "<") else { return nil }
        let name = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return name.isEmpty || name.contains(" ") ? nil : String(name)
    }

    /// Case-, space- and punctuation-insensitive form used for matching.
    /// Typographic quotes and dashes fold to ASCII so a name copied from the
    /// rendered PDF still matches the source.
    static func normalizedTitle(_ text: String) -> String {
        let folded = title(of: text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "[\u{2018}\u{2019}\u{201C}\u{201D}\"'`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2010}-\u{2015}]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "[*_:.,;!?()\\[\\]]", with: " ", options: .regularExpression)
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Resolves `query` to one section of `text`.
    ///
    /// Accepts a heading title (`"Introduction"`), the heading line as the
    /// outline shows it (`"== Introduction"`, which also pins the level), a
    /// Typst label (`"<intro>"`), or a path through parent headings
    /// (`"Methods > Data"`) to tell apart two sections with the same name.
    /// Matching tries an exact title first, then a unique prefix, then a
    /// unique substring.
    static func findSection(_ query: String, in text: String) -> SectionLookup {
        let headings = entries(in: text).filter { $0.endLine != nil }
        let parts = query.components(separatedBy: ">")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let targetPart = parts.last, !headings.isEmpty else { return .notFound(suggestions: []) }

        // `<label>` (the whole query) addresses a heading by its label.
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        if trimmedQuery.hasPrefix("<"), trimmedQuery.hasSuffix(">"), trimmedQuery.count > 2 {
            let wanted = String(trimmedQuery.dropFirst().dropLast())
            let byLabel = headings.filter { label(of: $0.text) == wanted }
            if byLabel.count == 1 { return .found(byLabel[0]) }
            if byLabel.count > 1 { return .ambiguous(byLabel) }
        }

        let wantedLevel = headingLevel(targetPart)
        let target = normalizedTitle(targetPart)
        let ancestorQueries = parts.dropLast().map(normalizedTitle)

        func level(_ entry: Entry) -> Int {
            if case .heading(let level) = entry.kind { return level }
            return 0
        }
        /// Titles of the headings that contain `entry`, outermost first.
        func ancestors(of entry: Entry) -> [String] {
            headings.filter { other in
                other.line < entry.line && level(other) < level(entry) && (other.endLine ?? 0) >= entry.line
            }.map { normalizedTitle($0.text) }
        }
        func matchesAncestors(_ entry: Entry) -> Bool {
            guard !ancestorQueries.isEmpty else { return true }
            var remaining = ArraySlice(ancestors(of: entry))
            for wanted in ancestorQueries {
                guard let index = remaining.firstIndex(where: { $0 == wanted || $0.contains(wanted) }) else { return false }
                remaining = remaining[(index + 1)...]
            }
            return true
        }

        let eligible = headings.filter { entry in
            (wantedLevel == nil || level(entry) == wantedLevel) && matchesAncestors(entry)
        }
        let tiers: [(Entry) -> Bool] = [
            { normalizedTitle($0.text) == target || label(of: $0.text) == targetPart },
            { normalizedTitle($0.text).hasPrefix(target) },
            { normalizedTitle($0.text).contains(target) },
        ]
        if !target.isEmpty {
            for tier in tiers {
                let matches = eligible.filter(tier)
                if matches.count == 1 { return .found(matches[0]) }
                if matches.count > 1 { return .ambiguous(matches) }
            }
        }

        // Closest by shared words, for the error message.
        let wantedWords = Set(target.split(separator: " ").map(String.init))
        var scored: [(entry: Entry, shared: Int)] = []
        for entry in headings {
            let words = Set(normalizedTitle(entry.text).split(separator: " ").map(String.init))
            let shared = words.intersection(wantedWords).count
            if shared > 0 { scored.append((entry, shared)) }
        }
        scored.sort { lhs, rhs in
            lhs.shared != rhs.shared ? lhs.shared > rhs.shared : lhs.entry.line < rhs.entry.line
        }
        return .notFound(suggestions: scored.prefix(5).map(\.entry))
    }

    /// A `findSection` result as the section itself, or an error message a
    /// model can act on (the candidates with their line ranges, and how to
    /// pick one).
    static func resolveSection(_ query: String, in text: String, path: String) -> Result<Entry, SectionLookupError> {
        func describe(_ entry: Entry) -> String {
            "\(entry.line)-\(entry.endLine ?? entry.line): \(entry.text)"
        }
        switch findSection(query, in: text) {
        case .found(let entry):
            return .success(entry)
        case .ambiguous(let entries):
            let listed = entries.prefix(8).map { "  " + describe($0) }.joined(separator: "\n")
            return .failure(SectionLookupError(message:
                "Several headings in '\(path)' match section \"\(query)\":\n\(listed)\nName the parent too (e.g. \"Parent > \(title(of: query))\"), give the heading exactly as listed (e.g. \"\(entries[0].text)\"), or use start_line/end_line."))
        case .notFound(let suggestions):
            var message = "No heading in '\(path)' matches section \"\(query)\"."
            if !suggestions.isEmpty {
                message += " Closest headings:\n" + suggestions.map { "  " + describe($0) }.joined(separator: "\n")
            } else {
                message += " Call get_outline to see the headings."
            }
            return .failure(SectionLookupError(message: message))
        }
    }

    struct SectionLookupError: Error, Equatable {
        let message: String
    }
}
