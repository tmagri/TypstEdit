import Foundation

/// The compiled search pattern shared by "find in project" and its replace
/// step. Plain-text searches get the query escaped; regex searches keep it
/// as-is, so capture groups (`$1` in the replacement) work like the
/// editor's own find & replace.
struct ProjectSearchPattern {
    let regex: NSRegularExpression
    let isRegex: Bool

    /// Compiles the query. `nil` when a regex query does not compile — the
    /// caller reports "invalid regular expression" rather than silently
    /// searching for the pattern source as text.
    ///
    /// Diacritic-insensitive matching folds the query *and the searched
    /// text* (dé → de): NSRegularExpression has no diacritic flag. Folding
    /// is per-character for precomposed input (é folds to e, one UTF-16
    /// unit either way), so a match's range in folded text is also valid in
    /// the original — when the folded and original lengths are equal. When
    /// they are not (decomposed combining sequences), the file is skipped
    /// for diacritic matching rather than risking misaligned ranges. A
    /// regex query is never folded: folding its characters would change
    /// which text it can match.
    init?(query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool, ignoreDiacritics: Bool) {
        var source = query
        if ignoreDiacritics, !regex {
            source = source.folding(options: [.diacriticInsensitive], locale: nil)
        }
        var pattern = regex ? source : NSRegularExpression.escapedPattern(for: source)
        if wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])" + pattern + "(?![\\p{L}\\p{N}_])"
        }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        self.regex = compiled
        self.isRegex = regex
        self.foldsText = ignoreDiacritics && !regex
    }

    /// Whether matching runs over a diacritically-folded copy of the text.
    let foldsText: Bool

    /// Folds `text` for matching. Returns nil when folding changed the
    /// UTF-16 length (decomposed combining sequences): match ranges would
    /// not map back onto the original text, so the caller skips the file.
    func foldedText(_ text: String) -> NSString? {
        let original = (text as NSString)
        let folded = text.folding(options: [.diacriticInsensitive], locale: nil)
        guard (folded as NSString).length == original.length else { return nil }
        return folded as NSString
    }

    /// Every match in `text`, in document order.
    func matches(in text: String) -> [NSTextCheckingResult] {
        let nsText = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    }

    /// The text to insert in place of one match: the template with `$1`…
    /// capture references expanded (regex searches), or the template as
    /// written (literal searches).
    ///
    /// Expansion works by re-running the pattern over the matched
    /// substring: the substring is exactly the matched text, so the
    /// captures of this isolated run align 1:1 with the original match,
    /// and a template referencing `$1` substitutes the same group the
    /// user sees highlighted.
    func replacementText(template: String, matchedText: String, in text: String) -> String {
        guard isRegex else { return template }
        _ = text
        let isolated = matchedText as NSString
        guard let isolatedMatch = regex.firstMatch(
            in: matchedText, options: [],
            range: NSRange(location: 0, length: isolated.length)
        ) else { return template }
        return regex.stringByReplacingMatches(
            in: matchedText, options: [], range: isolatedMatch.range, withTemplate: template
        )
    }
}
