//
//  NoteTypstRegions.swift
//  CodeEditSourceEditor
//
//  Finds multi-line Typst code regions in hybrid `.note` documents so the
//  Typst highlight overlay can treat each region as ONE parse unit.
//

import Foundation

/// The `.note` Typst overlay is injected per Markdown `(paragraph)`. A Typst
/// code construct that contains a blank line — e.g. a `#set page(footer: context { … })`
/// whose body has an empty line — is split by Markdown into several blocks:
/// each paragraph is parsed by Typst in isolation (so `text(a * b)` after the
/// blank line reads as markup with an unclosed `*strong*`), and 4+-space
/// indented lines after a blank line become an `indented_code_block` (rendered
/// as a green literal).
///
/// The compiler avoids that split with `AICompletionService.extractTypstRegions`:
/// a line whose first non-space character is a Typst `#` opener starts a region
/// that continues while its bracket depth is unclosed. This type mirrors that
/// rule (keep the two in sync) so the highlighter sees exactly the regions the
/// compiler treats as Typst code.
enum NoteTypstRegions {
    /// Same safety cap as the compiler: one unbalanced bracket must not
    /// swallow the rest of the document.
    static let regionLineCap = 500

    /// Returns the UTF-16 ranges of every multi- or single-line Typst code
    /// region in `text`. Each range starts at the opener's `#` and ends at the
    /// end of the line on which its bracket depth returns to zero (excluding
    /// the trailing newline).
    static func regions(in text: String) -> [NSRange] {
        // Lines with their UTF-16 start offsets.
        var lines: [Substring] = []
        var starts: [Int] = []
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(line)
            starts.append(offset)
            offset += line.utf16.count + 1
        }

        var regions: [NSRange] = []
        var index = 0
        var insideFence = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks are Markdown, not live Typst — skip wholesale.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                index += 1
                continue
            }
            guard !insideFence, isRegionOpener(line), let hashIndex = line.firstIndex(of: "#") else {
                index += 1
                continue
            }

            var depth = 0
            var inString = false
            var inBlockComment = false
            var end = index
            while true {
                let lineText = lines[end]
                var pos = (end == index) ? hashIndex : lineText.startIndex
                var inLineComment = false
                while pos < lineText.endIndex, !inLineComment {
                    let ch = lineText[pos]
                    let next = lineText.index(after: pos)
                    let nextChar: Character? = next < lineText.endIndex ? lineText[next] : nil
                    if inString {
                        if ch == "\\" {
                            pos = next  // skip the escaped character
                        } else if ch == "\"" {
                            inString = false
                        }
                    } else if inBlockComment {
                        if ch == "*", nextChar == "/" {
                            inBlockComment = false
                            pos = next
                        }
                    } else {
                        switch ch {
                        case "\"":
                            inString = true
                        case "/":
                            if nextChar == "/" {
                                // Only a comment at line start or after whitespace —
                                // `https://` must not hide a line's closing brackets.
                                let isCommentStart = pos == lineText.startIndex
                                    || lineText[lineText.index(before: pos)] == " "
                                    || lineText[lineText.index(before: pos)] == "\t"
                                if isCommentStart { inLineComment = true }
                            } else if nextChar == "*" {
                                inBlockComment = true
                                pos = next
                            }
                        case "(", "[", "{":
                            depth += 1
                        case ")", "]", "}":
                            depth -= 1
                        default:
                            break
                        }
                    }
                    if pos < lineText.endIndex { pos = lineText.index(after: pos) }
                }
                if depth <= 0 || end + 1 >= min(lines.count, index + regionLineCap) {
                    break
                }
                end += 1
            }

            let location = starts[index] + line[line.startIndex..<hashIndex].utf16.count
            let upperBound = starts[end] + lines[end].utf16.count
            regions.append(NSRange(location: location, length: upperBound - location))
            index = end + 1
        }

        return regions
    }

    /// True when `line`'s leading `#` is Typst code (`#let`, `#show`, `#{…}`,
    /// `#table(`, `#obj.field`) rather than an ATX heading (`## h2`), a stray
    /// hash (`# note`) or hashtag-shaped text (`#refs,`). Mirrors
    /// `AICompletionService.isTypstRegionOpener`.
    static func isRegionOpener(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.first == "#" else { return false }
        let after = trimmed.dropFirst()
        guard let next = after.first else { return false }
        if next == " " || next == "\t" || next == "#" { return false }
        guard next.isLetter else { return true }
        var rest = after
        while let c = rest.first, c.isLetter || c.isNumber || c == "_" {
            rest = rest.dropFirst()
        }
        guard let follower = rest.first else { return true }
        if ",!?;:".contains(follower) { return false }
        if follower == "." {
            let afterDot = rest.dropFirst().first
            if afterDot == nil || afterDot == " " || afterDot == "\t" { return false }
            return true
        }
        return true
    }

    /// Unions `paragraphs` with `regions`: every paragraph that overlaps a
    /// region is widened to cover the whole region (and any other paragraph the
    /// region spans), so a Typst construct split by blank lines is parsed as a
    /// single unit. Paragraphs that merely touch stay separate.
    static func merge(paragraphs: [NSRange], regions: [NSRange]) -> [NSRange] {
        let all = (paragraphs + regions)
            .filter { $0.length > 0 }
            .sorted { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        var merged: [NSRange] = []
        for range in all {
            if let last = merged.last, range.location < last.upperBound {
                let upper = max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = NSRange(location: last.location, length: upper - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
