import Foundation

/// Finds the math region (`$ … $` or `$$ … $$`) under the caret, so
/// "Send to Calculator" and the equation editor know what the user clicked.
///
/// Deliberately a character scanner rather than one regex: Typst has two
/// delimiters, `$` and `$$`, and the regex that matched `$…$` treated `$$` as
/// an empty inline pair. It also keeps escaped dollars (`\$5`) out of the
/// match and stays linear in the scanned window.
struct EquationDetector {

    private static let dollar: unichar = 0x24   // "$"
    private static let backslash: unichar = 0x5C

    /// Finds the range of the equation surrounding `index`, including the
    /// delimiters. Returns nil when the caret is not inside a closed equation.
    static func findEquationRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))

        // Window the search around the caret so a document with many stray
        // dollars stays cheap, like FormatDetector does.
        let window = getSearchRange(around: safeIndex, in: length, windowSize: 5000)
        let windowEnd = window.location + window.length
        var cursor = window.location

        while cursor < windowEnd {
            guard nsText.character(at: cursor) == dollar,
                  !isEscaped(cursor, in: nsText) else {
                cursor += 1
                continue
            }

            let openRun = dollarRunLength(at: cursor, in: nsText, limit: windowEnd)
            // A run of two dollars opens a display equation; longer runs only
            // occur in malformed input, and two is the longest real delimiter.
            let delimiterLength = openRun >= 2 ? 2 : 1
            let contentStart = cursor + delimiterLength

            guard let closeStart = closingDollar(
                from: contentStart,
                delimiterLength: delimiterLength,
                in: nsText,
                limit: windowEnd
            ) else {
                // No closer in the window: nothing to select from here on.
                return nil
            }

            let rangeEnd = closeStart + delimiterLength
            let range = NSRange(location: cursor, length: rangeEnd - cursor)

            // The caret counts as inside when it is within the delimiters, or
            // right at either edge (clicking just after `$` is a common miss).
            if safeIndex >= range.location && safeIndex <= rangeEnd {
                return range
            }
            cursor = rangeEnd
        }
        return nil
    }

    /// Length of a run of dollar signs starting at `position`.
    private static func dollarRunLength(at position: Int, in text: NSString, limit: Int) -> Int {
        var cursor = position
        while cursor < limit, text.character(at: cursor) == dollar {
            cursor += 1
        }
        return cursor - position
    }

    /// Position of the closing delimiter of the same width, or nil.
    private static func closingDollar(
        from start: Int,
        delimiterLength: Int,
        in text: NSString,
        limit: Int
    ) -> Int? {
        var cursor = start
        while cursor < limit {
            guard text.character(at: cursor) == dollar,
                  !isEscaped(cursor, in: text) else {
                cursor += 1
                continue
            }
            let run = dollarRunLength(at: cursor, in: text, limit: limit)
            if run >= delimiterLength {
                return cursor
            }
            // A lone `$` inside a display equation is literal text.
            cursor += run
        }
        return nil
    }

    /// True when the character at `position` is preceded by an odd number of
    /// backslashes, i.e. it is escaped (`\$`).
    private static func isEscaped(_ position: Int, in text: NSString) -> Bool {
        var backslashes = 0
        var cursor = position - 1
        while cursor >= 0, text.character(at: cursor) == backslash {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    private static func getSearchRange(around index: Int, in length: Int, windowSize: Int = 5000) -> NSRange {
        let start = max(0, index - windowSize)
        let end = min(length, index + windowSize)
        return NSRange(location: start, length: end - start)
    }
}
