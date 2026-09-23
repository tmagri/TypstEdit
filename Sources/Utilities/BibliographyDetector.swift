import Foundation

struct BibliographyInfo {
    let range: NSRange
    let sources: String
    let title: String?
    let full: Bool
    let style: String?
}

enum BibliographyRegex {
    static let command = try! NSRegularExpression(pattern: #"#bibliography\s*\("#)
    static let sourcesNamed = try! NSRegularExpression(pattern: #"^(?:\s*sources:\s*)?([ "']?[^,]*[ "']?)"#)
    static let sourcesBracket = try! NSRegularExpression(pattern: #"^\[([^\]]*)\]"#)
    static let title = try! NSRegularExpression(pattern: #"title:\s*"([^"]*)""#)
    static let full = try! NSRegularExpression(pattern: #"full:\s*(true|false)"#)
    static let style = try! NSRegularExpression(pattern: #"style:\s*"([^"]*)""#)
}

struct BibliographyDetector {
    /// Finds the range of #bibliography surrounds the index.
    static func findBibliographyRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length

        // Find #bibliography( and then walk to the matching closing parenthesis using
        // a depth counter. The previous nested-group regex suffered catastrophic
        // backtracking (ReDoS) when the closing ")" was absent — e.g. while typing
        // "#bibliography(" — which froze the main thread.
        let matches = BibliographyRegex.command.matches(in: text, options: [], range: NSRange(location: 0, length: length))
        // Safety check: Clamp index
        let safeIndex = max(0, min(index, length))

        for match in matches {
            let start = match.range.location
            // Find matching )
            var depth = 1
            var i = match.range.location + match.range.length
            while i < length && depth > 0 {
                let char = nsText.substring(with: NSRange(location: i, length: 1))
                if char == "(" { depth += 1 }
                else if char == ")" { depth -= 1 }
                i += 1
            }

            if depth == 0 {
                let range = NSRange(location: start, length: i - start)
                if safeIndex >= range.location && safeIndex <= (range.location + range.length) {
                    return range
                }
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
            let innerUtf16Count = inner.utf16.count
            
            // Regex for sources (first string or sources: "...")
            if let match = BibliographyRegex.sourcesNamed.firstMatch(in: inner, options: [], range: NSRange(0..<innerUtf16Count)),
               let sourcesMatch = Range(match.range, in: inner) {
                sources = String(inner[sourcesMatch]).trimmingCharacters(in: .whitespaces)
                // Clean quotes
                sources = sources.trimmingCharacters(in: CharacterSet(charactersIn: "\" '"))
            } else if let match = BibliographyRegex.sourcesBracket.firstMatch(in: inner, options: [], range: NSRange(0..<innerUtf16Count)),
                      let sourcesMatch = Range(match.range, in: inner) {
                // Bracketed sources? Typst usually uses strings or arrays of strings.
                sources = String(inner[sourcesMatch]).trimmingCharacters(in: .whitespaces)
            }
            
            // Extract title: "..."
            if let match = BibliographyRegex.title.firstMatch(in: inner, options: [], range: NSRange(0..<innerUtf16Count)),
               let titleMatch = Range(match.range, in: inner) {
                let matchStr = inner[titleMatch]
                if let firstQuote = matchStr.firstIndex(of: "\""), let lastQuote = matchStr.lastIndex(of: "\"") {
                    title = String(matchStr[matchStr.index(after: firstQuote)..<lastQuote])
                }
            }
            
            // Extract full: true/false
            if let match = BibliographyRegex.full.firstMatch(in: inner, options: [], range: NSRange(0..<innerUtf16Count)),
               let fullMatch = Range(match.range, in: inner) {
                full = inner[fullMatch].contains("true")
            }
            
            // Extract style: "..."
            if let match = BibliographyRegex.style.firstMatch(in: inner, options: [], range: NSRange(0..<innerUtf16Count)),
               let styleMatch = Range(match.range, in: inner) {
                let matchStr = inner[styleMatch]
                if let firstQuote = matchStr.firstIndex(of: "\""), let lastQuote = matchStr.lastIndex(of: "\"") {
                    style = String(matchStr[matchStr.index(after: firstQuote)..<lastQuote])
                }
            }
        }
        
        return BibliographyInfo(range: range, sources: sources, title: title, full: full, style: style)
    }
}
