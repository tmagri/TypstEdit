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
        return findBracketedRange(in: text, at: index, prefixPattern: "#underline\\s*[\\(\\[]")
    }
    
    /// Finds the range of highlight (#highlight[...]) surrounding the index.
    static func findHighlightRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: "#highlight\\s*[\\(\\[]")
    }
    
    /// Finds the range of strikethrough (#strike[...]) surrounding the index.
    static func findStrikeRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: "#strike\\s*[\\(\\[]")
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
        return findBracketedRange(in: text, at: index, prefixPattern: "#quote\\s*[\\(\\[]")
    }
}
