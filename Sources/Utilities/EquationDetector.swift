import Foundation

struct EquationDetector {
    /// Finds the range of an equation block delimited by `$` or `$$` surrounding the given index.
    /// Returns the range including the delimiters.
    static func findEquationRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length

        // Safety check: Clamp index
        let safeIndex = max(0, min(index, length))

        // Pattern: matches $...$ while ignoring escaped \$. The lazy quantifier
        // keeps matching linear, and the cached regex avoids recompiling on every
        // keystroke / cursor move.
        guard let regex = cachedRegex(#"(?<!\\)\$(.*?)(?<!\\)\$"#, options: [.dotMatchesLineSeparators]) else {
            return nil
        }

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

    // MARK: - Regex cache & windowing
    // This detector runs on every cursor move, and compiling an
    // NSRegularExpression is far more expensive than running it. Cache the
    // compiled expression keyed by pattern + options (mirrors FormatDetector).
    // NSCache is thread-safe and evicts automatically under memory pressure.
    nonisolated(unsafe) private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(pattern)|\(options.rawValue)" as NSString
        if let existing = regexCache.object(forKey: key) { return existing }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    private static func getSearchRange(around index: Int, in length: Int, windowSize: Int = 5000) -> NSRange {
        let start = max(0, index - windowSize)
        let end = min(length, index + windowSize)
        return NSRange(location: start, length: end - start)
    }
}
