import Foundation

enum EquationRegex {
    static let equation = try! NSRegularExpression(pattern: #"(?<!\\)\$(.*?)(?<!\\)\$"#, options: [.dotMatchesLineSeparators])
}

struct EquationDetector {
    /// Finds the range of an equation block delimited by `$` or `$$` surrounding the given index.
    /// Returns the range including the delimiters.
    static func findEquationRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length

        // Safety check: Clamp index
        let safeIndex = max(0, min(index, length))

        // Pattern: matches $...$ while ignoring escaped \$. The lazy quantifier
        // keeps matching linear, and the precompiled regex avoids recompiling or
        // cache lookups on every keystroke / cursor move.
        let regex = EquationRegex.equation

        // Window the search around the cursor so a document with many stray '$'
        // signs stays cheap. Mirrors FormatDetector's approach.
        let searchRange = getSearchRange(around: safeIndex, in: length, windowSize: 5000)
        let matches = regex.matches(in: text, options: [], range: searchRange)

        // Find a match that covers the index OR is adjacent to it (within 1 char)
        // Adjacency is important for clicks at the very end or start of the line
        for match in matches {
            let range = match.range

            // If the cursor is inside the range (inclusive)
            if safeIndex >= range.location && safeIndex <= (range.location + range.length) {
                return range
            }

            // Check adjacency (click just after)
            if safeIndex == range.location + range.length {
                return range
            }
        }

        return nil
    }

    private static func getSearchRange(around index: Int, in length: Int, windowSize: Int = 5000) -> NSRange {
        let start = max(0, index - windowSize)
        let end = min(length, index + windowSize)
        return NSRange(location: start, length: end - start)
    }
}
