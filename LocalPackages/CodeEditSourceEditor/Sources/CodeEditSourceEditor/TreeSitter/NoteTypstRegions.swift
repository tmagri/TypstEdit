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
    ///
    /// Scans UTF-16 code units directly. This used to build `[Substring]` with
    /// `text.split(separator: "\n")` and then walk `Character`s; on a document
    /// that `NSTextStorage` owns (a foreign UTF-16 string) that measured
    /// **~166 ms per call** on a 1.6 MB note, on every keystroke, because
    /// splitting a foreign string resolves grapheme boundaries. Walking the
    /// same document with `unichar` offsets measures ~2 ms and allocates no
    /// line array at all.
    ///
    /// Everything here is ASCII-significant (`#`, quotes, brackets, `//`), and
    /// a `unichar` compares equal to its `Character` counterpart, so the
    /// behaviour matches the previous implementation exactly.
    static func regions(in text: String) -> [NSRange] {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        // Line boundaries, computed lazily as the scan advances.
        var regions: [NSRange] = []
        var cursor = 0
        var insideFence = false

        while cursor < length {
            let (lineStart, lineEnd, contentsEnd) = lineBounds(ns, at: cursor)

            // Leading whitespace only; used for fence detection (Unicode spaces count,
            // as they did for the `CharacterSet.whitespaces` trim this replaces).
            var firstNonSpace = lineStart
            while firstNonSpace < contentsEnd, isUnicodeSpace(ns.character(at: firstNonSpace)) {
                firstNonSpace += 1
            }

            if isFenceOpener(ns, from: firstNonSpace, to: contentsEnd) {
                insideFence.toggle()
                cursor = lineEnd
                continue
            }

            guard !insideFence,
                  isRegionOpener(ns, from: lineStart, to: contentsEnd),
                  let hashIndex = firstHashIndex(ns, from: firstNonSpace, to: contentsEnd) else {
                cursor = lineEnd
                continue
            }

            // Walk forward from this line while the construct's brackets stay open.
            var depth = 0
            var inString = false
            var inBlockComment = false
            var endLineStart = lineStart
            var endContentsEnd = contentsEnd
            var endLineEnd = lineEnd
            var scannedLines = 0

            var scanLineStart = lineStart
            var scanFrom = hashIndex
            scanning: while true {
                let bounds = lineBounds(ns, at: scanLineStart)
                var pos = (scanLineStart == lineStart) ? max(scanFrom, bounds.start) : bounds.start
                var inLineComment = false

                while pos < bounds.contentsEnd, !inLineComment {
                    let unit = ns.character(at: pos)
                    let nextUnit: unichar? = (pos + 1 < bounds.contentsEnd)
                        ? ns.character(at: pos + 1) : nil

                    if inString {
                        if unit == asciiBackslash {
                            pos += 2          // skip the escaped character
                            continue
                        } else if unit == asciiDoubleQuote {
                            inString = false
                        }
                    } else if inBlockComment {
                        if unit == asciiStar, nextUnit == asciiSlash {
                            inBlockComment = false
                            pos += 2
                            continue
                        }
                    } else {
                        switch unit {
                        case asciiDoubleQuote:
                            inString = true
                        case asciiSlash:
                            if nextUnit == asciiSlash {
                                // Only a comment at line start or after whitespace —
                                // `https://` must not hide a line's closing brackets.
                                let previous = pos > bounds.start ? ns.character(at: pos - 1) : nil
                                let isCommentStart = previous == nil
                                    || previous == asciiSpace || previous == asciiTab
                                if isCommentStart { inLineComment = true }
                            } else if nextUnit == asciiStar {
                                inBlockComment = true
                                pos += 2
                                continue
                            }
                        case asciiOpenParen, asciiOpenBracket, asciiOpenBrace:
                            depth += 1
                        case asciiCloseParen, asciiCloseBracket, asciiCloseBrace:
                            depth -= 1
                        default:
                            break
                        }
                    }
                    pos += 1
                }

                endLineStart = bounds.start
                endContentsEnd = bounds.contentsEnd
                endLineEnd = bounds.end
                scannedLines += 1
                let capped = scannedLines >= regionLineCap

                if depth <= 0 || capped {
                    // A trailing construct opener (`it =>`) whose block brace
                    // sits on the NEXT line continues the region: the compiler
                    // (`autoFixBrokenNoteSyntax`) joins the two lines before
                    // compiling, so the highlight overlay must cover the brace
                    // body too. Mirrors `AICompletionService.typstRegionLineSpans`.
                    if depth <= 0, !capped, endLineEnd < length {
                        let nextBounds = lineBounds(ns, at: endLineEnd)
                        var nextFirst = nextBounds.start
                        while nextFirst < nextBounds.contentsEnd, isUnicodeSpace(ns.character(at: nextFirst)) {
                            nextFirst += 1
                        }
                        if isBlockOpenerLine(ns, from: bounds.start, to: bounds.contentsEnd),
                           nextFirst < nextBounds.contentsEnd,
                           ns.character(at: nextFirst) == asciiOpenBrace {
                            scanLineStart = endLineEnd
                            scanFrom = endLineEnd
                            inLineComment = false
                            // `while true` continues onto the next line.
                            endLineStart = nextBounds.start
                            endContentsEnd = nextBounds.contentsEnd
                            endLineEnd = nextBounds.end
                            continue scanning
                        }
                    }
                    break scanning
                }

                guard endLineEnd > scanLineStart else { break scanning }
                scanLineStart = endLineEnd
                scanFrom = endLineEnd
            }

            let location = hashIndex
            let upperBound = endContentsEnd
            if upperBound > location {
                regions.append(NSRange(location: location, length: upperBound - location))
            }
            cursor = max(endLineEnd, lineEnd)
        }

        return regions
    }

    // MARK: - UTF-16 scanning helpers

    private static let asciiSpace = unichar(0x20)
    private static let asciiTab = unichar(0x09)
    private static let asciiNewline = unichar(0x0A)
    private static let asciiBackslash = unichar(0x5C)
    private static let asciiDoubleQuote = unichar(0x22)
    private static let asciiSlash = unichar(0x2F)
    private static let asciiStar = unichar(0x2A)
    private static let asciiHash = unichar(0x23)
    private static let asciiOpenParen = unichar(0x28)
    private static let asciiCloseParen = unichar(0x29)
    private static let asciiOpenBracket = unichar(0x5B)
    private static let asciiCloseBracket = unichar(0x5D)
    private static let asciiOpenBrace = unichar(0x7B)
    private static let asciiCloseBrace = unichar(0x7D)
    private static let asciiBacktick = unichar(0x60)
    private static let asciiTilde = unichar(0x7E)

    /// Start / end / content-end of the line containing `location`.
    private static func lineBounds(_ ns: NSString, at location: Int) -> (start: Int, end: Int, contentsEnd: Int) {
        var start = 0
        var end = 0
        var contentsEnd = 0
        ns.getLineStart(
            &start,
            end: &end,
            contentsEnd: &contentsEnd,
            for: NSRange(location: min(location, ns.length), length: 0)
        )
        if end <= start { end = ns.length }
        return (start, end, min(max(contentsEnd, start), end))
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == asciiSpace || unit == asciiTab
    }

    /// `CharacterSet.whitespaces`: tab plus every Unicode "Space Separator" (Zs).
    /// The original scanner trimmed with that set in a few places, so pasted
    /// non-breaking (U+00A0) and ideographic (U+3000) spaces must count there too.
    private static func isUnicodeSpace(_ unit: unichar) -> Bool {
        switch unit {
        case 0x09, 0x20, 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// True when the line begins with a ``` or ~~~ fence.
    private static func isFenceOpener(_ ns: NSString, from start: Int, to end: Int) -> Bool {
        guard start < end else { return false }
        let unit = ns.character(at: start)
        guard unit == asciiBacktick || unit == asciiTilde else { return false }
        var count = 0
        var i = start
        while i < end, ns.character(at: i) == unit {
            count += 1
            i += 1
        }
        return count >= 3
    }

    private static func firstHashIndex(_ ns: NSString, from start: Int, to end: Int) -> Int? {
        var i = start
        while i < end {
            if ns.character(at: i) == asciiHash { return i }
            i += 1
        }
        return nil
    }

    /// UTF-16 equivalent of ``isRegionOpener(_:)`` for a trimmed line.
    private static func isRegionOpener(_ ns: NSString, from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end, isSpace(ns.character(at: i)) { i += 1 }
        guard i < end, ns.character(at: i) == asciiHash else { return false }
        i += 1
        guard i < end else { return false }

        let next = ns.character(at: i)
        if next == asciiSpace || next == asciiTab || next == asciiHash { return false }
        // The identifier walk must be Unicode-aware, like the `Character.isLetter`
        // it replaces: `#été, accent` is hashtag-shaped prose, not Typst code.
        // An ASCII-only walk mis-read it as an opener and invented a region.
        guard let (first, _) = scalar(ns, at: i, end: end), isLetter(first) else { return true }

        while i < end {
            guard let (scalar, width) = scalar(ns, at: i, end: end) else { break }
            if isLetter(scalar) || isNumber(scalar) || scalar == "_" || isCombiningMark(scalar) {
                i += width
            } else {
                break
            }
        }
        guard i < end else { return true }
        let follower = ns.character(at: i)
        // ",!?;:" → not an opener
        if follower == 0x2C || follower == 0x21 || follower == 0x3F
            || follower == 0x3B || follower == 0x3A {
            return false
        }
        if follower == 0x2E /* . */ {
            guard i + 1 < end else { return false }
            let afterDot = ns.character(at: i + 1)
            if afterDot == asciiSpace || afterDot == asciiTab { return false }
            return true
        }
        return true
    }

    /// The Unicode scalar starting at UTF-16 offset `i`, and how many code
    /// units it occupies. `nil` for a lone surrogate.
    private static func scalar(_ ns: NSString, at i: Int, end: Int) -> (Unicode.Scalar, Int)? {
        let unit = ns.character(at: i)
        if UTF16.isLeadSurrogate(unit), i + 1 < end {
            let trail = ns.character(at: i + 1)
            if UTF16.isTrailSurrogate(trail) {
                let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
                return Unicode.Scalar(value).map { ($0, 2) }
            }
        }
        return Unicode.Scalar(unit).map { ($0, 1) }
    }

    /// Mirrors `Character.isLetter`, which is `_firstScalar.properties.isAlphabetic`.
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
    }

    /// Mirrors `Character.isNumber`.
    private static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType != nil
    }

    /// A combining mark belongs to the grapheme before it, so the `Character`
    /// walk this replaces would never have stopped on one.
    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isASCIILetter(_ unit: unichar) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    private static func isASCIIDigit(_ unit: unichar) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    /// UTF-16 equivalent of ``isBlockOpenerLine(_:)`` for a trimmed line.
    private static func isBlockOpenerLine(_ ns: NSString, from start: Int, to end: Int) -> Bool {
        var s = start
        var e = end
        while s < e, isUnicodeSpace(ns.character(at: s)) { s += 1 }
        while e > s, isUnicodeSpace(ns.character(at: e - 1)) { e -= 1 }
        guard s < e else { return false }
        if hasLineComment(ns, from: s, to: e) { return false }

        // "=>": the head must contain a letter or number (Unicode, like the
        // `Character.isLetter || isNumber` this mirrors).
        if e - s >= 2, ns.character(at: e - 2) == 0x3D, ns.character(at: e - 1) == 0x3E {
            var i = s
            while i < e - 2 {
                guard let (scalar, width) = scalar(ns, at: i, end: e - 2) else { i += 1; continue }
                if isLetter(scalar) || isNumber(scalar) { return true }
                i += width
            }
            return false
        }
        // "=": what precedes it (ignoring blanks) must end a value.
        if ns.character(at: e - 1) == 0x3D {
            var head = e - 1
            while head > s, isSpace(ns.character(at: head - 1)) { head -= 1 }
            guard head > s else { return false }
            let lastUnit = ns.character(at: head - 1)
            if lastUnit == asciiCloseParen || lastUnit == asciiCloseBracket
                || lastUnit == asciiDoubleQuote || lastUnit == asciiCloseBrace {
                return true
            }
            guard let base = lastBaseScalar(ns, from: s, before: head) else { return false }
            return isLetter(base) || isNumber(base)
        }
        return false
    }

    /// The scalar a `Character` ending at `end` is built on: steps back over
    /// combining marks and surrogate pairs, because `Character.isLetter` looks
    /// at a grapheme's first scalar.
    private static func lastBaseScalar(_ ns: NSString, from start: Int, before end: Int) -> Unicode.Scalar? {
        var i = end
        while i > start {
            var width = 1
            var value = UInt32(ns.character(at: i - 1))
            if UTF16.isTrailSurrogate(UInt16(value)), i - 2 >= start,
               UTF16.isLeadSurrogate(ns.character(at: i - 2)) {
                value = 0x10000 + ((UInt32(ns.character(at: i - 2)) - 0xD800) << 10) + (value - 0xDC00)
                width = 2
            }
            guard let scalar = Unicode.Scalar(value) else { return nil }
            if isCombiningMark(scalar) {
                i -= width
                continue
            }
            return scalar
        }
        return nil
    }

    /// UTF-16 equivalent of ``hasLineComment(_:)``.
    private static func hasLineComment(_ ns: NSString, from start: Int, to end: Int) -> Bool {
        var inString = false
        var previous: unichar?
        var i = start
        while i < end {
            let unit = ns.character(at: i)
            let next: unichar? = (i + 1 < end) ? ns.character(at: i + 1) : nil

            if inString {
                if unit == asciiBackslash {
                    previous = next
                    i += 2
                    continue
                }
                if unit == asciiDoubleQuote { inString = false }
            } else if unit == asciiDoubleQuote {
                inString = true
            } else if unit == asciiSlash, next == asciiSlash,
                      previous == nil || previous == asciiSpace || previous == asciiTab {
                return true
            }
            previous = unit
            i += 1
        }
        return false
    }

    /// True when `line`'s leading `#` is Typst code (`#let`, `#show`, `#{…}`,
    /// `#table(`, `#obj.field`) rather than an ATX heading (`## h2`), a stray
    /// hash (`# note`) or hashtag-shaped text (`#refs,`). Mirrors
    /// `AICompletionService.isTypstRegionOpener`.
    static func isRegionOpener(_ line: Substring) -> Bool {
        let ns = String(line) as NSString
        return isRegionOpener(ns, from: 0, to: ns.length)
    }

    /// True when `trimmed` ends with a construct opener whose block brace may
    /// sit on the next line: a closure arrow (`it =>`) or a bare assignment
    /// after a value (`#let x =`). The value head keeps a `===` setext
    /// underline, a `==` comparison tail and empty lines from joining.
    /// A line carrying a `//` comment never qualifies: the compiler will not
    /// join a brace onto it (that would comment the brace out).
    /// Mirrors `TypstCompiler.isBlockOpenerLine` in the app target.
    static func isBlockOpenerLine(_ trimmed: String) -> Bool {
        let ns = trimmed as NSString
        return isBlockOpenerLine(ns, from: 0, to: ns.length)
    }

    /// True when `line` contains a `//` line comment outside a string — at
    /// line start or after whitespace, so `https://` does not count.
    /// Mirrors `TypstCompiler.hasLineComment` in the app target.
    static func hasLineComment(_ line: String) -> Bool {
        let ns = line as NSString
        return hasLineComment(ns, from: 0, to: ns.length)
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
