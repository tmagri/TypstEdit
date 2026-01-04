import Foundation

struct FormatDetector {
    /// Finds the range of bold text (*...*) surrounding the index.
    static func findBoldRange(in text: String, at index: Int) -> NSRange? {
        return findSymmetricRange(in: text, at: index, marker: "*")
    }
    
    /// Finds the range of italic text (_..._) surrounding the index.
    static func findItalicRange(in text: String, at index: Int) -> NSRange? {
        return findSymmetricRange(in: text, at: index, marker: "_")
    }
    
    /// Finds the range of underline (#underline[...]) surrounding the index.
    static func findUnderlineRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#underline(?:\s*\([^)]*\))?\s*[\[(]"#)
    }
    
    /// Finds the range of highlight (#highlight[...]) surrounding the index.
    static func findHighlightRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#highlight(?:\s*\([^)]*\))?\s*[\[(]"#)
    }
    
    /// Finds the range of strikethrough (#strike[...]) surrounding the index.
    static func findStrikeRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#strike(?:\s*\([^)]*\))?\s*[\[(]"#)
    }

    /// Finds the range of subscript (#sub[...]) surrounding the index.
    static func findSubscriptRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#sub(?:\s*\([^)]*\))?\s*[\[(]"#)
    }

    /// Finds the range of superscript (#sup[...]) surrounding the index.
    static func findSuperscriptRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#super(?:\s*\([^)]*\))?\s*[\[(]"#)
    }
    
    private static func findBracketedRange(in text: String, at index: Int, prefixPattern: String) -> NSRange? {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: prefixPattern, options: []) else { return nil }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        for match in matches.reversed() {
            if match.range.location <= index {
                let opener = nsText.substring(with: NSRange(location: match.range.location + match.range.length - 1, length: 1))
                let closer = opener == "[" ? "]" : ")"
                
                if let contentRange = findClosingMarker(in: text, startingAt: match.range.location + match.range.length, opener: opener, closer: closer) {
                    let fullRange = NSRange(location: match.range.location, length: contentRange.upperBound - match.range.location)
                    if NSLocationInRange(index, fullRange) {
                        return fullRange
                    }
                }
            }
        }
        return nil
    }
    
    /// Detects the heading level (0-6) of the line at the given index.
    static func detectHeadingLevel(in text: String, at index: Int) -> Int {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
        let line = nsText.substring(with: lineRange)
        
        // Typst headings start with some number of = followed by whitespace
        let pattern = #"^(=+)\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return 0 }
        
        if let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.count)) {
            if let eqRange = Range(match.range(at: 1), in: line) {
                let eqStr = String(line[eqRange])
                return min(eqStr.count, 6)
            }
        }
        return 0
    }
    
    /// Detects if the cursor at the given index is on a bullet list line.
    static func isBulletListActive(in text: String, at index: Int) -> Bool {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("- ")
    }

    /// Detects if the cursor at the given index is on a numerical list line.
    static func isNumberListActive(in text: String, at index: Int) -> Bool {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("+ ")
    }
    
    /// Finds the range of the heading prefix (e.g., "== ") for the line at the given index.
    static func findHeadingRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: index, length: 0))
        let line = nsText.substring(with: lineRange)
        
        let pattern = #"^(=+)\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        if let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.count)) {
            return NSRange(location: lineRange.location, length: match.range.length)
        }
        
        return nil
    }
    
    private static func findSymmetricRange(in text: String, at index: Int, marker: String) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        
        // Search backwards for the opener
        var openerIndex = -1
        var i = index - 1
        while i >= 0 {
            let char = nsText.substring(with: NSRange(location: i, length: 1))
            if char == marker {
                // Check if it's not escaped
                if i > 0 && nsText.substring(with: NSRange(location: i - 1, length: 1)) == "\\" {
                    i -= 1
                    continue
                }
                openerIndex = i
                break
            }
            // If we hit a newline or start of block, stop (Typst bold usually doesn't span paragraphs)
            if char == "\n" { break }
            i -= 1
        }
        
        if openerIndex == -1 { return nil }
        
        // Search forwards for the closer
        var closerIndex = -1
        i = index
        while i < length {
            let char = nsText.substring(with: NSRange(location: i, length: 1))
            if char == marker {
                // Check if it's not escaped
                if i > 0 && nsText.substring(with: NSRange(location: i - 1, length: 1)) == "\\" {
                    i += 1
                    continue
                }
                closerIndex = i
                break
            }
            if char == "\n" { break }
            i += 1
        }
        
        if closerIndex == -1 { return nil }
        
        return NSRange(location: openerIndex, length: closerIndex - openerIndex + 1)
    }
    
    private static func findClosingMarker(in text: String, startingAt: Int, opener: String, closer: String) -> NSRange? {
        let nsText = text as NSString
        var depth = 1
        var index = startingAt
        
        while index < nsText.length {
            let char = nsText.substring(with: NSRange(location: index, length: 1))
            if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: startingAt, length: index - startingAt + 1)
                }
            }
            index += 1
        }
        return nil
    }
    
    /// Finds the range of a code block (`...` or ```...```) surrounding the index.
    static func findCodeRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        
        // Pattern for triple backticks (multiline) and single backticks (inline)
        // Order matters: match triple first
        let patterns = [#"```[\s\S]*?```"#, #"`[^`\n]*?`"#]
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: length))
            
            for match in matches {
                if index >= match.range.location && index <= match.range.upperBound {
                    return match.range
                }
            }
        }
        return nil
    }

    static func findLinkRange(in text: String, at index: Int) -> NSRange? {
        let pattern = #"#link\("([^"]+)"\)(?:\[(.*?)\])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let range = NSRange(location: 0, length: text.utf16.count)
        let matches = regex.matches(in: text, options: [], range: range)
        
        for match in matches {
            if NSLocationInRange(index, match.range) {
                return match.range
            }
        }
        
        return nil
    }
    
    static func findCodeBlockRange(in text: String, at index: Int) -> NSRange? {
        // Simple detection for triple backticks
        // This is a naive implementation and might need robustness for nested blocks if supported
        let pattern = #"```[\s\S]*?```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let range = NSRange(location: 0, length: text.utf16.count)
        let matches = regex.matches(in: text, options: [], range: range)
        
        for match in matches {
            if NSLocationInRange(index, match.range) {
                return match.range
            }
        }
        return nil
    }
    
    static func findQuoteRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#quote(?:\s*\([^)]*\))?\s*[\[(]"#)
    }

    static func findFootnoteRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#footnote\s*[\[(]"#)
    }

    struct FootnoteInfo {
        let range: NSRange
        let body: String
        let numbering: String?
    }

    static func parseFootnote(in text: String, at index: Int) -> FootnoteInfo? {
        guard let range = findFootnoteRange(in: text, at: index) else { return nil }
        let nsText = text as NSString
        let snippet = nsText.substring(with: range)
        
        var body = ""
        var numbering: String? = nil
        
        // Extract body between []
        if let bracketStart = snippet.firstIndex(of: "["), let bracketEnd = snippet.lastIndex(of: "]") {
            let start = snippet.index(after: bracketStart)
            body = String(snippet[start..<bracketEnd])
        }
        
        // Extract numbering: "..." from ()
        if let parenStart = snippet.firstIndex(of: "("), let parenEnd = snippet.firstIndex(of: ")") {
            let params = String(snippet[snippet.index(after: parenStart)..<parenEnd])
            let numberingPattern = #"numbering:\s*"([^"]*)""#
            if let numberingMatch = params.range(of: numberingPattern, options: .regularExpression) {
                let match = params[numberingMatch]
                if let firstQuote = match.firstIndex(of: "\""), let lastQuote = match.lastIndex(of: "\"") {
                    numbering = String(match[match.index(after: firstQuote)..<lastQuote])
                }
            }
        }
        
        return FootnoteInfo(range: range, body: body, numbering: numbering)
    }

    struct QuoteInfo {
        let range: NSRange
        let content: String
        let attribution: String
        let isBlock: Bool
    }

    static func parseQuote(in text: String, at index: Int) -> QuoteInfo? {
        guard let range = findQuoteRange(in: text, at: index) else { return nil }
        let nsText = text as NSString
        let quoteStr = nsText.substring(with: range)
        
        // Extract content between []
        var content = ""
        if let bracketStart = quoteStr.firstIndex(of: "["), let bracketEnd = quoteStr.lastIndex(of: "]") {
            let start = quoteStr.index(after: bracketStart)
            content = String(quoteStr[start..<bracketEnd])
        }
        
        // Extract attribution and block status from ()
        var attribution = ""
        var isBlock = false
        if let parenStart = quoteStr.firstIndex(of: "("), let parenEnd = quoteStr.firstIndex(of: ")") {
            let params = String(quoteStr[quoteStr.index(after: parenStart)..<parenEnd])
            
            // Attribution: "..."
            let attrQuotePattern = "attribution:\\s*\"([^\"]*)\""
            if let attrRange = params.range(of: attrQuotePattern, options: .regularExpression) {
                let match = params[attrRange]
                if let firstQuote = match.firstIndex(of: "\""), let lastQuote = match.lastIndex(of: "\"") {
                    attribution = String(match[match.index(after: firstQuote)..<lastQuote])
                }
            } else {
                // Attribution: [...]
                let attrBracketPattern = "attribution:\\s*\\[(.*?)\\]"
                if let attrRange = params.range(of: attrBracketPattern, options: .regularExpression) {
                    let match = params[attrRange]
                    if let firstBracket = match.firstIndex(of: "["), let lastBracket = match.lastIndex(of: "]") {
                        attribution = String(match[match.index(after: firstBracket)..<lastBracket])
                    }
                }
            }
            
            if params.contains("block: true") {
                isBlock = true
            }
        } else {
            isBlock = quoteStr.contains("block: true")
        }
        
        return QuoteInfo(range: range, content: content, attribution: attribution, isBlock: isBlock)
    }
    
    /// Detects if the cursor at the given index is likely inside a Typst math block ($ ... $).
    /// This uses a heuristic of counting unescaped dollar signs from the beginning of text.
    static func isMathMode(in text: String, at index: Int) -> Bool {
        let nsText = text as NSString
        var dollarCount = 0
        var i = 0
        
        while i < index && i < nsText.length {
            let char = nsText.substring(with: NSRange(location: i, length: 1))
            
            if char == "\\" {
                // Skip escaped characters
                i += 2
                continue
            }
            
            if char == "$" {
                dollarCount += 1
            }
            
            i += 1
        }
        
        // If odd number of dollars, we are likely inside a math block
        return dollarCount % 2 != 0
    }
}
