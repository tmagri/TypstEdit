import Foundation

/// Matching rules for `edit_file`, modelled on opencode's `edit` tool.
///
/// A model asked to change a sentence will retype it from what it *saw*,
/// not from the file's bytes: a PDF preview or its own chat reply has already
/// turned `--` into `—`, `"` into `“”`, and a non-breaking space into
/// something indistinguishable on screen. A byte-exact search then misses a
/// region the model is looking straight at. Two extra tiers fix that:
///
///   1. **Exact** — the original behaviour, byte for byte (after the caller's
///      CRLF normalisation).
///   2. **Line-based** — compare line by line with trailing whitespace and
///      typographic variants ignored, then splice the replacement back in
///      with the *file's own* line endings, so a mixed-ending file keeps its
///      bytes everywhere outside the edit.
///
/// Everything here is pure and synchronous so the rules are unit-testable
/// without a project, a model, or an approval prompt.
enum TolerantTextMatch {

    // MARK: - Normalisation

    /// Typographic variants folded to their ASCII counterparts, so a quote
    /// copied out of rendered text matches the source it came from.
    ///
    /// Whitespace is folded too, but a *different* space is still a space:
    /// NBSP and the various thin/en spaces all become U+0020. Mapped
    /// explicitly (rather than with a character set) so a full-width space in
    /// CJK text, which is meaningful, is left alone.
    static func normalizeForMatch(_ value: String) -> String {
        var out = String()
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}": out.append("\"")
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}": out.append("-")
            case "\u{00A0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
                 "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}":
                out.append(" ")
            default: out.append(character)
            }
        }
        return out
    }

    /// Trailing whitespace removed, then normalised. Trailing whitespace is
    /// invisible, so a model omitting it is not making a mistake worth
    /// refusing.
    static func normalizedLine(_ line: String) -> String {
        normalizeForMatch(line.replacingOccurrences(of: "\r", with: "")).trimmingTrailingWhitespace()
    }

    // MARK: - Finding matches

    /// Every non-overlapping occurrence of `needle`, byte for byte.
    static func findExact(_ needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }

    /// One line of a file, with the range it occupies in the original text
    /// and where its content stops (just before the line ending).
    struct LineSlice {
        /// The line's content, without its ending.
        let content: String
        /// The whole line including its ending.
        let range: Range<String.Index>
        /// End of the content, before `\r`/`\n`.
        let contentEnd: String.Index
        /// `\n` or `\r\n`, or "" for a final line with no ending.
        let ending: String
    }

    static func lines(of text: String) -> [LineSlice] {
        var result: [LineSlice] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            // Swift treats "\r\n" as one grapheme, so a CRLF file never
            // matches a bare "\n" comparison. Both spellings are checked.
            if character == "\n" || character == "\r\n" {
                let lineEnd = text.index(after: index)
                let ending = character == "\r\n" ? "\r\n" : "\n"
                let contentEnd = index
                result.append(LineSlice(
                    content: String(text[lineStart..<contentEnd]),
                    range: lineStart..<lineEnd,
                    contentEnd: contentEnd,
                    ending: ending
                ))
                lineStart = lineEnd
            }
            index = text.index(after: index)
        }
        if lineStart < text.endIndex {
            result.append(LineSlice(
                content: String(text[lineStart..<text.endIndex]),
                range: lineStart..<text.endIndex,
                contentEnd: text.endIndex,
                ending: ""
            ))
        }
        return result
    }

    /// Line-by-line match that ignores trailing whitespace and typographic
    /// variants. Ranges are in the original `haystack`, so the caller can
    /// splice a replacement in without rebuilding the whole file.
    ///
    /// A `needle` ending in a newline must match through the last line's
    /// ending; one that doesn't stops at the last line's content, so a
    /// replacement can't silently swallow the line break after it.
    static func findLineBased(_ needle: String, in haystack: String) -> [Range<String.Index>] {
        let trailingNewline = needle.hasSuffix("\n")
        var expected = needle
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if trailingNewline { expected.removeLast() }
        guard !expected.isEmpty else { return [] }
        let expectedKeys = expected.map(normalizedLine)
        // An all-empty needle would match at every position; there is nothing
        // meaningful to splice, and the exact tier has already refused it.
        guard expectedKeys.contains(where: { !$0.isEmpty }) else { return [] }

        let slices = lines(of: haystack)
        guard slices.count >= expectedKeys.count else { return [] }

        var candidates: [Range<String.Index>] = []
        for start in 0...(slices.count - expectedKeys.count) {
            var matches = true
            for offset in 0..<expectedKeys.count where normalizedLine(slices[start + offset].content) != expectedKeys[offset] {
                matches = false
                break
            }
            guard matches else { continue }
            let last = slices[start + expectedKeys.count - 1]
            if trailingNewline, last.ending.isEmpty { continue }
            let upper = trailingNewline ? last.range.upperBound : last.contentEnd
            candidates.append(slices[start].range.lowerBound..<upper)
        }
        return candidates
    }

    // MARK: - Line endings

    /// The file's dominant line ending, or `fallback` when it has none or
    /// uses both styles equally. Used only for *new* lines a replacement
    /// introduces; lines the replacement keeps inherit their own.
    static func lineEnding(in text: String, fallback: String) -> String {
        var crlf = 0
        var lf = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\r\n" { crlf += 1 } else if character == "\n" { lf += 1 }
            index = text.index(after: index)
        }
        if crlf == lf { return fallback }
        return crlf > lf ? "\r\n" : "\n"
    }

    /// Rebuilds `replacement` (which the model almost always wrote with bare
    /// `\n` and ASCII punctuation) from the `region` it replaces, line by
    /// line:
    ///
    ///   * a line the replacement *keeps* is taken from the region verbatim,
    ///     so typography and line endings the model never meant to touch
    ///     survive — editing one word in a paragraph doesn't flatten every
    ///     curly quote and em dash around it;
    ///   * a line that changed in place takes the model's text but the region
    ///     line's own ending;
    ///   * a line with no counterpart takes the model's text and `fallback`.
    ///
    /// This is what makes a loose match safe: only the lines the model
    /// actually rewrote are rewritten.
    static func mergeReplacement(region: String, replacement: String, fallback: String) -> String {
        let before = lines(of: region)
        let afterLines = replacement
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard before.count > 1 || afterLines.count > 1 else { return replacement }

        let alignment = alignLines(
            before: before.map { normalizedLine($0.content) },
            after: afterLines.map { normalizedLine($0) }
        )

        var out = String()
        for (index, line) in afterLines.enumerated() {
            let source = alignment[index].flatMap { $0 < before.count ? before[$0] : nil }
            // Kept verbatim only when the text really is the same line.
            if let source, normalizedLine(source.content) == normalizedLine(line) {
                out.append(source.content)
            } else {
                out.append(line)
            }
            guard index < afterLines.count - 1 else { break }
            out.append(source.map { $0.ending.isEmpty ? fallback : $0.ending } ?? fallback)
        }
        return out
    }

    /// The line-ending rule behind `mergeReplacement`, kept separate for the
    /// cases that only need the endings. Every line the replacement keeps is
    /// already in the file, so this is exactly "the file's own endings".
    static func reconcileEndings(region: String, replacement: String, fallback: String) -> String {
        mergeReplacement(region: region, replacement: replacement, fallback: fallback)
    }

    /// For each line of `after`, the index of the `before` line it keeps
    /// (longest common subsequence), or, between kept lines, the line it
    /// takes the place of. `nil` where there is no counterpart.
    static func alignLines(before: [String], after: [String]) -> [Int?] {
        let width = after.count + 1
        guard !before.isEmpty, !after.isEmpty else { return Array(repeating: nil, count: after.count) }
        var table = [UInt32](repeating: 0, count: (before.count + 1) * width)
        func at(_ i: Int, _ j: Int) -> UInt32 { table[i * width + j] }
        func set(_ i: Int, _ j: Int, _ value: UInt32) { table[i * width + j] = value }

        var i = before.count - 1
        while i >= 0 {
            var j = after.count - 1
            while j >= 0 {
                set(i, j, before[i] == after[j]
                    ? at(i + 1, j + 1) + 1
                    : max(at(i + 1, j), at(i, j + 1)))
                j -= 1
            }
            i -= 1
        }

        var result: [Int?] = Array(repeating: nil, count: after.count)
        var gapBefore: [Int] = []
        var gapAfter: [Int] = []
        func flushGap() {
            // Pair the gap's lines positionally: the first replaced line takes
            // the first replaced line's ending, and so on.
            for (offset, afterIndex) in gapAfter.enumerated() {
                result[afterIndex] = offset < gapBefore.count ? gapBefore[offset] : gapBefore.last
            }
            gapBefore = []
            gapAfter = []
        }

        i = 0
        var j = 0
        while i < before.count && j < after.count {
            if before[i] == after[j] {
                flushGap()
                result[j] = i
                i += 1
                j += 1
                continue
            }
            if at(i + 1, j) >= at(i, j + 1) {
                gapBefore.append(i)
                i += 1
            } else {
                gapAfter.append(j)
                j += 1
            }
        }
        flushGap()
        return result
    }

    // MARK: - Failure hints

    /// Lines of `text` most similar to the first substantial line of
    /// `needle`, as `"42: <line>"`, so a failed edit points at the place the
    /// model meant instead of only saying "not found".
    static func closestLines(to needle: String, in text: String, limit: Int = 3) -> [String] {
        let wanted = needle
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(normalizedLine)
            .first { !$0.isEmpty }
        guard let wanted else { return [] }

        var scored: [(score: Int, number: Int, content: String)] = []
        // A line has to resemble the needle substantially, or "closest" would
        // list every line that merely shares a trailing period.
        let floor = max(3, wanted.count / 2)
        for (index, slice) in lines(of: text).enumerated() {
            let candidate = normalizedLine(slice.content)
            guard !candidate.isEmpty else { continue }
            let score = similarity(wanted, candidate)
            guard score >= floor else { continue }
            scored.append((score, index + 1, slice.content))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.number < $1.number }
            .prefix(limit)
            .map { "\($0.number): \($0.content.count > 160 ? String($0.content.prefix(160)) + "…" : $0.content)" }
    }

    /// Length of the common prefix plus the common suffix, so a line that
    /// differs only inside a word still scores well.
    private static func similarity(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.lowercased())
        let b = Array(rhs.lowercased())
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return prefix + suffix
    }

    /// True when the file already contains the replacement's own text — the
    /// usual reason an edit is re-sent after it already landed.
    static func alreadyPresent(replacementFirstLines needle: String, in text: String) -> Bool {
        let wanted = needle
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(normalizedLine)
            .filter { !$0.isEmpty }
            .prefix(3)
        guard !wanted.isEmpty else { return false }
        let haystack = Set(lines(of: text).map { normalizedLine($0.content) })
        return wanted.allSatisfy { haystack.contains($0) }
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            let character = self[previous]
            guard character == " " || character == "\t" || character == "\r" else { break }
            end = previous
        }
        return String(self[startIndex..<end])
    }
}
