//
//  TextViewController+EmphasizeBracket.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/26/23.
//

import AppKit
import CodeEditTextView

extension TextViewController {
    /// Emphasizes bracket pairs using the current selection.
    internal func emphasizeSelectionPairs() {
        guard let bracketPairEmphasis = configuration.appearance.bracketPairEmphasis else { return }
        textView.emphasisManager?.removeEmphases(for: EmphasisGroup.brackets)
        let docLen = textView.textStorage.length
        guard docLen > 0 else { return }

        for range in textView.selectionManager.textSelections.map({ $0.range }) {
            if range.isEmpty,
               range.location > 0, // Range is not the beginning of the document
               range.location <= docLen,
               let precedingCharacter = textView.textStorage.substring(
                from: NSRange(location: range.location - 1, length: 1) // The preceding character exists
               ) {
                for pair in BracketPairs.emphasisValues {
                    if precedingCharacter == pair.0 {
                        // Walk forwards
                        emphasizeForwards(pair, range: range, emphasisType: bracketPairEmphasis)
                    } else if precedingCharacter == pair.1 && range.location - 1 > 0 {
                        // Walk backwards
                        emphasizeBackwards(pair, range: range, emphasisType: bracketPairEmphasis)
                    }
                }
            }
        }
    }

    private func emphasizeForwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        let documentLength = textView.textStorage.length
        guard let searchWindow = bracketSearchWindow(
            from: range.location,
            direction: .forwards,
            documentLength: documentLength
        ) else { return }

        if let characterIndex = findClosingPair(
            pair.0,
            pair.1,
            from: searchWindow.lowerBound,
            limit: searchWindow.upperBound,
            reverse: false
        ) {
            emphasizeCharacter(characterIndex)
            if emphasisType.emphasizesSourceBracket {
                emphasizeCharacter(searchWindow.lowerBound - 1)
            }
        }
    }

    private func emphasizeBackwards(_ pair: (String, String), range: NSRange, emphasisType: BracketPairEmphasis) {
        let documentLength = textView.textStorage.length
        guard let searchWindow = bracketSearchWindow(
            from: range.location - 1,
            direction: .backwards,
            documentLength: documentLength
        ) else { return }

        if let characterIndex = findClosingPair(
            pair.1,
            pair.0,
            from: searchWindow.upperBound,
            limit: searchWindow.lowerBound,
            reverse: true
        ) {
            emphasizeCharacter(characterIndex)
            if emphasisType.emphasizesSourceBracket {
                emphasizeCharacter(range.location - 1)
            }
        }
    }

    private enum BracketSearchDirection {
        case forwards
        case backwards
    }

    /// Maximum number of characters to scan beyond the viewport when looking for a matching bracket.
    private static let bracketSearchPadding = 4096

    /// Computes the half-open range of document indices to scan for a matching bracket.
    ///
    /// The window is anchored at the caret and extends beyond the visible viewport so pairs just
    /// off-screen are still found. Anchoring at the caret is essential: deriving the window only
    /// from `visibleTextRange` produced a window *behind* the caret whenever the caret was scrolled
    /// off-screen (eg after a large edit), and the resulting inverted `NSRange` raised
    /// `NSRangeException` inside `enumerateSubstrings(in:options:)`.
    ///
    /// - Parameters:
    ///   - index: The caret index the search is anchored to.
    ///   - direction: Which way the search walks.
    ///   - documentLength: The current length of the document, in UTF-16 units.
    /// - Returns: A valid half-open window, or `nil` when there is nothing to scan.
    private func bracketSearchWindow(
        from index: Int,
        direction: BracketSearchDirection,
        documentLength: Int
    ) -> Range<Int>? {
        guard documentLength > 0, index >= 0, index <= documentLength else { return nil }
        let visible = textView.visibleTextRange ?? NSRange(location: index, length: 0)

        switch direction {
        case .forwards:
            guard index < documentLength else { return nil }
            let visibleMax = max(index, visible.max)
            let upperBound = min(visibleMax + Self.bracketSearchPadding, documentLength)
            guard upperBound > index else { return nil }
            return index..<upperBound
        case .backwards:
            guard index > 0 else { return nil }
            let visibleMin = min(index, max(visible.location, 0))
            let lowerBound = max(visibleMin - Self.bracketSearchPadding, 0)
            guard lowerBound < index else { return nil }
            return lowerBound..<index
        }
    }

    /// # Dev Note
    /// It's interesting to note that this problem could trivially be turned into a monoid, and the locations of each
    /// pair start/end location determined when the view is loaded. It could then be parallelized for initial speed
    /// and this lookup would be much faster.

    /// Finds a closing character given a pair of characters, ignores pairs inside the given pair.
    ///
    /// ```pseudocode
    /// { -- Start
    ///   {
    ///   } -- A naive algorithm may find this character as the closing pair, which would be incorrect.
    /// } -- Found
    /// ```
    ///
    /// - Parameters:
    ///   - open: The opening pair to look for.
    ///   - close: The closing pair to look for.
    ///   - from: The index to start from. This should not include the start character. Eg given `"{ }"` looking forward
    ///           the index should be `1`
    ///   - limit: A limiting index to stop at. When `reverse` is `true`, this is the minimum index. When `false` this
    ///            is the maximum index.
    ///   - reverse: Set to `true` to walk backwards from `from`.
    /// - Returns: The index of the found closing pair, if any.
    internal func findClosingPair(_ close: String, _ open: String, from: Int, limit: Int, reverse: Bool) -> Int? {
        let documentLength = textView.textStorage.length
        guard documentLength > 0 else { return nil }

        // Build the scan range defensively. Callers have historically derived `from`/`limit` from
        // layout state that can lag behind the document, which previously produced an inverted or
        // out-of-bounds `NSRange` and crashed Foundation. A non-positive window means "nothing to
        // scan" rather than an error.
        let searchRange: NSRange
        if reverse {
            guard from <= documentLength, limit >= 0, limit < from else { return nil }
            searchRange = NSRange(location: limit, length: from - limit)
        } else {
            guard from >= 0, limit <= documentLength, from < limit else { return nil }
            searchRange = NSRange(location: from, length: limit - from)
        }

        guard searchRange.isValid(inDocumentOfLength: documentLength), searchRange.length > 0 else {
            return nil
        }

        // Walk the text, counting each close. When we find an open that makes closeCount < 0, return that index.
        var options: NSString.EnumerationOptions = .byCaretPositions
        if reverse {
            options = options.union(.reverse)
        }
        var closeCount = 0
        var index: Int?
        textView.textStorage.mutableString.enumerateSubstrings(
            in: searchRange,
            options: options,
            using: { substring, range, _, stop in
                if substring == close {
                    closeCount += 1
                } else if substring == open {
                    closeCount -= 1
                }

                if closeCount < 0 {
                    index = range.location
                    stop.pointee = true
                }
            }
        )
        return index
    }

    /// Adds a temporary emphasis effect to the character at the given location.
    /// - Parameters:
    ///   - location: The location of the character to emphasize
    ///   - scrollToRange: Set to true to scroll to the given range when emphasizing. Defaults to `false`.
    private func emphasizeCharacter(_ location: Int, scrollToRange: Bool = false) {
        guard let bracketPairEmphasis = configuration.appearance.bracketPairEmphasis else {
            return
        }
        guard location >= 0, location < textView.textStorage.length else { return }

        let range = NSRange(location: location, length: 1)

        switch bracketPairEmphasis {
        case .flash:
            textView.emphasisManager?.addEmphasis(
                Emphasis(
                    range: range,
                    style: .standard,
                    flash: true,
                    inactive: false
                ),
                for: EmphasisGroup.brackets
            )
        case .bordered(let borderColor):
            textView.emphasisManager?.addEmphasis(
                Emphasis(
                    range: range,
                    style: .outline(color: borderColor),
                    flash: false,
                    inactive: false
                ),
                for: EmphasisGroup.brackets
            )
        case .underline(let underlineColor):
            textView.emphasisManager?.addEmphasis(
                Emphasis(
                    range: range,
                    style: .underline(color: underlineColor),
                    flash: false,
                    inactive: false
                ),
                for: EmphasisGroup.brackets
            )
        }
    }
}
