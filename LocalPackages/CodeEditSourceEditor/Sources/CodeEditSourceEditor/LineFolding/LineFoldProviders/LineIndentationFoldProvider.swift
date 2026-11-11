//
//  LineIndentationFoldProvider.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/8/25.
//

import AppKit
import CodeEditTextView

/// A basic fold provider that uses line indentation to determine fold regions.
final class LineIndentationFoldProvider: LineFoldProvider {
    /// Lines ending with one of these tokens continue onto a `{` that opens on
    /// the NEXT line (`#show x: it =>` ⏎ `{`). The fold then starts at the
    /// opener line instead of the bare `{` line, so collapsing hides the whole
    /// construct and the closing `}` line stays visible.
    private static let constructOpenerSuffixes = ["=>", "=", ":", "("]
    private static let openBrace: unichar = unichar(UnicodeScalar("{").value)

    func indentLevelAtLine(substring: NSString) -> Int? {
        for idx in 0..<substring.length {
            let character = UnicodeScalar(substring.character(at: idx))
            if character?.properties.isWhitespace == false {
                return idx
            }
        }
        return nil
    }

    func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        controller: TextViewController
    ) -> [LineFoldProviderLineInfo] {
        let text = controller.textView.textStorage.string as NSString
        guard let leadingIndent = text.leadingRange(in: lineRange, within: .whitespacesAndNewlines)?.length,
              leadingIndent != lineRange.length else {
            return []
        }
        var foldIndicators: [LineFoldProviderLineInfo] = []

        // A `{` that opens on its own line, right after a construct opener,
        // belongs to the fold the opener started: don't close the opener's
        // fold here and don't start a second, shallower-body one.
        let isConstructBrace = trimmedFirstCharacter(in: lineRange, leadingIndent: leadingIndent, text: text) == Self.openBrace
            && previousLineEndsWithOpener(above: lineRange.location, text: text)

        // Depths are the raw leading-indent lengths, not indent-unit counts.
        // The fold algorithm only compares depths (this line vs. the previous),
        // so any monotonic measure works — but dividing by the configured
        // indent width does not: a file indented with tabs (1 character each)
        // or with a different space width than the editor inserts would have
        // every depth truncated toward 0, so folds never opened for the
        // deeper line and never closed when the indent returned (a
        // `#show … { … }` block in a tab-indented Typst file, for one).
        let leadingDepth = leadingIndent
        if leadingDepth < previousDepth, !isConstructBrace {
            // End the fold at the start of whitespace
            foldIndicators.append(
                .endFold(
                    rangeEnd: lineRange.location + leadingIndent,
                    newDepth: leadingDepth
                )
            )
        }

        let maxRange = NSRange(start: lineRange.max, end: text.length)
        let nextIndent = text.leadingRange(in: maxRange, within: .whitespacesWithoutNewlines)?.length

        // A construct opener whose `{` lands on the next line: start the fold
        // on the opener line, one level below it, so the matching `}` closes it.
        if let nextIndent,
           trimmedFirstCharacter(in: maxRange, leadingIndent: nextIndent, text: text) == Self.openBrace,
           !isConstructBrace,
           lineEndsWithOpener(lineRange: lineRange, leadingIndent: leadingIndent, text: text),
           let trailingWhitespace = text.trailingWhitespaceRange(in: lineRange) {
            foldIndicators.append(
                .startFold(rangeStart: trailingWhitespace.location, newDepth: leadingDepth + 1)
            )
        }

        guard let nextIndent, nextIndent > 0 else {
            return foldIndicators
        }

        if nextIndent > leadingIndent, !isConstructBrace, let trailingWhitespace = text.trailingWhitespaceRange(in: lineRange) {
            foldIndicators.append(
                .startFold(
                    rangeStart: trailingWhitespace.location,
                    newDepth: nextIndent
                )
            )
        }

        return foldIndicators
    }

    // MARK: - Brace-on-next-line construct detection

    /// First non-whitespace character of the line covering `range`, given its
    /// already-computed leading whitespace length.
    private func trimmedFirstCharacter(in range: NSRange, leadingIndent: Int?, text: NSString) -> unichar? {
        guard let leadingIndent, range.length != leadingIndent else { return nil }
        let idx = range.location + leadingIndent
        guard idx < text.length, idx < range.location + range.length else { return nil }
        let character = text.character(at: idx)
        guard UnicodeScalar(character)?.properties.isWhitespace == false else { return nil }
        return character
    }

    /// True if the trimmed content of the line at `lineRange` ends with a
    /// construct opener token (`=>`, `=`, `:`, `(`).
    private func lineEndsWithOpener(lineRange: NSRange, leadingIndent: Int, text: NSString) -> Bool {
        var end = lineRange.location + lineRange.length
        while end > lineRange.location + leadingIndent,
              UnicodeScalar(text.character(at: end - 1))?.properties.isWhitespace == true {
            end -= 1
        }
        guard end > lineRange.location + leadingIndent else { return false }
        let line = text.substring(with: NSRange(location: lineRange.location, length: end - lineRange.location))
        return Self.constructOpenerSuffixes.contains { line.hasSuffix($0) }
    }

    /// True if the nearest non-blank line above `location` ends with a
    /// construct opener token (e.g. `it =>`, `#let f =`, `#set page(`).
    private func previousLineEndsWithOpener(above location: Int, text: NSString) -> Bool {
        guard location > 0 else { return false }
        var end = location
        while end > 0, isLineBreak(text.character(at: end - 1)) { end -= 1 }
        guard end > 0 else { return false }
        var start = end
        while start > 0, !isLineBreak(text.character(at: start - 1)) { start -= 1 }
        let previousRange = NSRange(location: start, length: end - start)
        guard let previousIndent = text.leadingRange(in: previousRange, within: .whitespacesAndNewlines)?.length,
              previousIndent != previousRange.length else {
            return false
        }
        return lineEndsWithOpener(lineRange: previousRange, leadingIndent: previousIndent, text: text)
    }

    private func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }
}
