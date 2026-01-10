import Foundation

struct BibliographyInfo {
    let range: NSRange
    let sources: String
    let title: String?
    let full: Bool
    let style: String?
}

struct BibliographyDetector {
    /// Finds the range of #bibliography surrounds the index.
    static func findBibliographyRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let pattern = #"#bibliography\s*\((?:[^()]*|\([^()]*\))*\)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        // Safety check: Clamp index
        let safeIndex = max(0, min(index, nsText.length))
        
        for match in matches {
            if NSLocationInRange(safeIndex, match.range) {
                return match.range
            }
        }
        return nil
    }
    
    /// Parses a #bibliography block to extract its properties.
    static func parseBibliography(in text: String, at index: Int) -> BibliographyInfo? {
        guard let range = findBibliographyRange(in: text, at: index) else { return nil }
        let nsText = text as NSString
        let snippet = nsText.substring(with: range)
        
        // Extract sources (the first positional argument or sources: ...)
        // This is a bit tricky with regex if we want to support both positional and named.
        // Typst #bibliography("works.bib", title: "Refs")
        
        var sources = ""
        var title: String? = nil
        var full = false
        var style: String? = nil
        
        // Extract content inside parentheses
        if let startParen = snippet.firstIndex(of: "("), let endParen = snippet.lastIndex(of: ")") {
            let inner = String(snippet[snippet.index(after: startParen)..<endParen])
            
            // Regex for sources (first string or sources: "...")
            if let sourcesMatch = inner.range(of: #"^(?:\s*sources:\s*)?([ "']?[^,]*[ "']?)"#, options: .regularExpression) {
                sources = inner[sourcesMatch].trimmingCharacters(in: .whitespaces)
                // Clean quotes
                sources = sources.trimmingCharacters(in: CharacterSet(charactersIn: "\" '"))
            } else if let sourcesMatch = inner.range(of: #"^\[([^\]]*)\]"#, options: .regularExpression) {
                // Bracketed sources? Typst usually uses strings or arrays of strings.
                sources = inner[sourcesMatch].trimmingCharacters(in: .whitespaces)
            }
            
            // Extract title: "..."
            if let titleMatch = inner.range(of: #"title:\s*"([^"]*)""#, options: .regularExpression) {
                let matchStr = inner[titleMatch]
                if let firstQuote = matchStr.firstIndex(of: "\""), let lastQuote = matchStr.lastIndex(of: "\"") {
                    title = String(matchStr[matchStr.index(after: firstQuote)..<lastQuote])
                }
            }
            
            // Extract full: true/false
            if let fullMatch = inner.range(of: #"full:\s*(true|false)"#, options: .regularExpression) {
                full = inner[fullMatch].contains("true")
            }
            
            // Extract style: "..."
            if let styleMatch = inner.range(of: #"style:\s*"([^"]*)""#, options: .regularExpression) {
                let matchStr = inner[styleMatch]
                if let firstQuote = matchStr.firstIndex(of: "\""), let lastQuote = matchStr.lastIndex(of: "\"") {
                    style = String(matchStr[matchStr.index(after: firstQuote)..<lastQuote])
                }
            }
        }
        
        return BibliographyInfo(range: range, sources: sources, title: title, full: full, style: style)
    }
}
