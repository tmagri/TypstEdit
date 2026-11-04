import Foundation

/// Shared lookup for Typst function calls such as `#table(...)` that surround a cursor.
///
/// These detectors run on every cursor move. They only scan for openers up to the cursor,
/// and they walk raw UTF-16 code units, so no substring is allocated for each character.
enum CallRangeFinder {
    /// Returns the range of a `regex` call whose balanced parentheses contain `index`.
    /// - Parameter fromEnd: Prefer the call that starts closest to `index` instead of the first one.
    static func enclosingCall(
        matching regex: NSRegularExpression,
        in text: String,
        at index: Int,
        fromEnd: Bool = false
    ) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))

        // An opener can only contain the cursor if it starts at or before it. The small
        // slack lets the cursor sit inside the opener itself (e.g. "#tab|le(").
        let searchEnd = min(length, safeIndex + 64)
        var matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: searchEnd))
        if fromEnd { matches.reverse() }

        for match in matches where match.range.location <= safeIndex {
            guard let end = closingParenthesis(in: nsText, from: NSMaxRange(match.range)) else { continue }
            let range = NSRange(location: match.range.location, length: end - match.range.location)
            if safeIndex <= NSMaxRange(range) {
                return range
            }
        }
        return nil
    }

    /// Walks forward from just after an opening "(" and returns the offset just past the matching ")".
    static func closingParenthesis(in nsText: NSString, from start: Int) -> Int? {
        let length = nsText.length
        var depth = 1
        var i = start
        while i < length {
            switch nsText.character(at: i) {
            case 0x28: depth += 1
            case 0x29:
                depth -= 1
                if depth == 0 { return i + 1 }
            default: break
            }
            i += 1
        }
        return nil
    }
}
