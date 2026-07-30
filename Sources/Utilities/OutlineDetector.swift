import Foundation

struct OutlineInfo {
    let range: NSRange
    let title: String?
    let target: String?
    let depth: Int?
    let indent: Bool?
}

struct OutlineDetector {
    /// Finds the range of #outline surrounds the index.
    static func findOutlineRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length

        // Find #outline( and then walk to the matching closing parenthesis using a
        // depth counter. The previous nested-group regex suffered catastrophic
        // backtracking (ReDoS) when the closing ")" was absent — e.g. while typing
        // "#outline(" — which froze the main thread.
        let pattern = #"#outline\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }

        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: length))
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
    
    /// Parses a #outline block to extract its properties.
    static func parseOutline(in text: String, at index: Int) -> OutlineInfo? {
        guard let range = findOutlineRange(in: text, at: index) else { return nil }
        let nsText = text as NSString
        let snippet = nsText.substring(with: range)
        
        var title: String? = nil
        var target: String? = nil
        var depth: Int? = nil
        var indent: Bool? = nil
        
        // Extract content inside parentheses
        if let startParen = snippet.firstIndex(of: "("), let endParen = snippet.lastIndex(of: ")") {
            let inner = String(snippet[snippet.index(after: startParen)..<endParen])
            
            // Extract title: [...] or title: "..."
            if let titleMatch = inner.range(of: #"title:\s*\[([^\]]*)\]"#, options: .regularExpression) {
                let matchStr = inner[titleMatch]
                if let firstBracket = matchStr.firstIndex(of: "["), let lastBracket = matchStr.lastIndex(of: "]") {
                    title = String(matchStr[matchStr.index(after: firstBracket)..<lastBracket])
                }
            } else if let titleMatch = inner.range(of: #"title:\s*"([^"]*)""#, options: .regularExpression) {
                let matchStr = inner[titleMatch]
                if let firstQuote = matchStr.firstIndex(of: "\""), let lastQuote = matchStr.lastIndex(of: "\"") {
                    title = String(matchStr[matchStr.index(after: firstQuote)..<lastQuote])
                }
            }
            
            // Extract target: ...
            // We'll simplify this to look for common targets
            if let targetMatch = inner.range(of: #"target:\s*([a-zA-Z0-9.]+)"#, options: .regularExpression) {
                let matchStr = inner[targetMatch]
                if let colon = matchStr.firstIndex(of: ":") {
                    let val = matchStr[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if val.contains("figure") {
                        if val.contains("image") {
                            target = "Image"
                        } else {
                            target = "Figure"
                        }
                    } else if val.contains("heading") {
                        target = "Heading"
                    } else {
                        target = "Custom"
                    }
                }
            }
            
            // Extract depth: ...
            if let depthMatch = inner.range(of: #"depth:\s*(\d+)"#, options: .regularExpression) {
                let matchStr = inner[depthMatch]
                if let colon = matchStr.firstIndex(of: ":") {
                    let val = matchStr[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    depth = Int(val)
                }
            }
            
            // Extract indent: true/false/none
            if let indentMatch = inner.range(of: #"indent:\s*(true|false)"#, options: .regularExpression) {
                indent = inner[indentMatch].contains("true")
            }
        }
        
        return OutlineInfo(range: range, title: title, target: target, depth: depth, indent: indent)
    }
}
