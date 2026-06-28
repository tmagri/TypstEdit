import Foundation

struct FormatDetector {
    /// Finds the range of bold text surrounding the index (Typst: *...* | Markdown: **...** or __...__).
    static func findBoldRange(in text: String, at index: Int) -> NSRange? {
        if let mdRange = findRegexRange(in: text, at: index, pattern: #"(?s)\*\*(.*?)\*\*|__(.*?)__"#) { return mdRange }
        return findSymmetricRange(in: text, at: index, marker: "*")
    }
    
    /// Finds the range of italic text surrounding the index (Typst: _..._ | Markdown: *...*).
    static func findItalicRange(in text: String, at index: Int) -> NSRange? {
        if let typstRange = findSymmetricRange(in: text, at: index, marker: "_") { return typstRange }
        // Markdown Italic: matches *text* but strictly ignores **text**
        if let mdRange = findRegexRange(in: text, at: index, pattern: #"(?s)(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)"#) { return mdRange }
        return nil
    }
    
    /// Finds the range of underline (#underline[...] or <u>...</u>) surrounding the index.
    static func findUnderlineRange(in text: String, at index: Int) -> NSRange? {
        if let typst = findBracketedRange(in: text, at: index, prefixPattern: #"#underline(?:\s*\([^)]*\))?\s*[\[(]"#) { return typst }
        return findHTMLTagRange(in: text, at: index, tag: "u")
    }
    
    /// Finds the range of highlight (#highlight[...] or <mark>...</mark> or ==...==) surrounding the index.
    static func findHighlightRange(in text: String, at index: Int) -> NSRange? {
        if let typst = findBracketedRange(in: text, at: index, prefixPattern: #"#highlight(?:\s*\([^)]*\))?\s*[\[(]"#) { return typst }
        if let mark = findHTMLTagRange(in: text, at: index, tag: "mark") { return mark }
        return findRegexRange(in: text, at: index, pattern: #"(?s)==(.*?)=="#)
    }
    
    /// Finds the range of a text color block (#text(fill: ...)[...]) surrounding the index.
    static func findTextColorRange(in text: String, at index: Int) -> NSRange? {
        // Matches standard colors like "red" or hex colors like "rgb(\"#ff0000\")"
        return findBracketedRange(in: text, at: index, prefixPattern: #"#text\s*\(\s*fill\s*:\s*(?:[a-zA-Z0-9]+|rgb\([^)]+\))\s*\)\s*[\[(]"#)
    }
    
    /// Finds the range of strikethrough (#strike[...] or ~~...~~) surrounding the index.
    static func findStrikeRange(in text: String, at index: Int) -> NSRange? {
        if let typst = findBracketedRange(in: text, at: index, prefixPattern: #"#strike(?:\s*\([^)]*\))?\s*[\[(]"#) { return typst }
        return findRegexRange(in: text, at: index, pattern: #"(?s)~~(.*?)~~"#)
    }

    /// Finds the range of subscript (#sub[...] or <sub>...</sub>) surrounding the index.
    static func findSubscriptRange(in text: String, at index: Int) -> NSRange? {
        if let typst = findBracketedRange(in: text, at: index, prefixPattern: #"#sub(?:\s*\([^)]*\))?\s*[\[(]"#) { return typst }
        return findHTMLTagRange(in: text, at: index, tag: "sub")
    }

    /// Finds the range of superscript (#sup[...] or <sup>...</sup>) surrounding the index.
    static func findSuperscriptRange(in text: String, at index: Int) -> NSRange? {
        if let typst = findBracketedRange(in: text, at: index, prefixPattern: #"#super(?:\s*\([^)]*\))?\s*[\[(]"#) { return typst }
        return findHTMLTagRange(in: text, at: index, tag: "sup")
    }

    /// Finds the range of title (#title[...]) surrounding the index.
    static func findTitleRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#title(?:\s*\([^)]*\))?\s*[\[(]"#)
    }
    
    private static func getSearchRange(around index: Int, in length: Int, windowSize: Int = 5000) -> NSRange {
        let start = max(0, index - windowSize)
        let end = min(length, index + windowSize)
        return NSRange(location: start, length: end - start)
    }

    private static func findBracketedRange(in text: String, at index: Int, prefixPattern: String) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))
        guard let regex = try? NSRegularExpression(pattern: prefixPattern, options: []) else { return nil }
        
        let searchRange = getSearchRange(around: safeIndex, in: length, windowSize: 5000)
        let matches = regex.matches(in: text, options: [], range: searchRange)
        
        for match in matches.reversed() {
            if match.range.location <= safeIndex {
                let opener = nsText.substring(with: NSRange(location: match.range.location + match.range.length - 1, length: 1))
                let closer = opener == "[" ? "]" : ")"
                
                if let contentRange = findClosingMarker(in: text, startingAt: match.range.location + match.range.length, opener: opener, closer: closer) {
                    let fullRange = NSRange(location: match.range.location, length: contentRange.upperBound - match.range.location)
                    // Be inclusive of boundaries (safeIndex == fullRange.upperBound should also match)
                    if safeIndex >= fullRange.location && safeIndex <= fullRange.upperBound {
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
        let safeIndex = max(0, min(index, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = nsText.substring(with: lineRange)
        
        // Match both Typst (=) and Markdown (#)
        let pattern = #"^(=+|#+)\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return 0 }
        
        if let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.count)) {
            if let markerRange = Range(match.range(at: 1), in: line) {
                return min(String(line[markerRange]).count, 6)
            }
        }
        return 0
    }

    /// Detects if the cursor is inside a #title[...] block.
    static func detectIsTitle(in text: String, at index: Int) -> Bool {
        return findTitleRange(in: text, at: index) != nil
    }
    
    /// Detects if the cursor at the given index is on a bullet list line.
    static func isBulletListActive(in text: String, at index: Int) -> Bool {
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("- ")
    }

    /// Detects if the cursor at the given index is on a numerical list line.
    static func isNumberListActive(in text: String, at index: Int) -> Bool {
        let nsText = text as NSString
        let safeIndex = max(0, min(index, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
        
        let mdNumberRegex = try? NSRegularExpression(pattern: #"^\d+\.\s"#)
        let isMdNumber = mdNumberRegex?.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) != nil
        
        return line.hasPrefix("+ ") || isMdNumber
    }
    
    /// Detects if the cursor at the given index is on a description list line.
    static func isDescriptionListActive(in text: String, at index: Int) -> Bool {
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("/ ")
    }
    
    /// Finds the range of the heading prefix (e.g., "== " or "## ") for the line at the given index.
    static func findHeadingRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let safeIndex = max(0, min(index, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = nsText.substring(with: lineRange)
        
        let pattern = #"^(=+|#+)\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        if let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.count)) {
            return NSRange(location: lineRange.location, length: match.range.length)
        }
        return nil
    }
    
    private static func findSymmetricRange(in text: String, at index: Int, marker: String) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        
        // Safety check: Clamped index
        let safeIndex = max(0, min(index, length))
        
        // Search backwards for the opener
        var openerIndex = -1
        var i = safeIndex - 1
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
        i = max(openerIndex + marker.count, safeIndex)
        while i < length {
            // Check if not escaped
            if i > 0 && nsText.substring(with: NSRange(location: i - 1, length: 1)) == "\\" {
                i += 1
                continue
            }
            
            let char = nsText.substring(with: NSRange(location: i, length: 1))
            if char == marker {
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
        let safeIndex = max(0, min(index, length))
        
        // Matches any identical sequence of backticks (handles `...`, ``...``, ```...```)
        let searchRange = getSearchRange(around: safeIndex, in: length, windowSize: 5000)
        let patterns = [#"(?s)(`+).*?(?<!`)\1(?!`)"#]
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let matches = regex.matches(in: text, options: [], range: searchRange)
            
            for match in matches {
                if safeIndex >= match.range.location && safeIndex <= match.range.upperBound {
                    return match.range
                }
            }
        }
        return nil
    }

    static func findLinkRange(in text: String, at index: Int) -> NSRange? {
        let patterns = [
            #"#link\("([^"]+)"\)(?:\[(.*?)\])?"#, // Typst link
            #"(?<!!)\[([^\]]+)\]\([^)]+\)"#      // Markdown link (negative lookbehind ensures it's not an image)
        ]
        
        let nsText = text as NSString
        let safeIndex = max(0, min(index, nsText.length))
        let searchRange = getSearchRange(around: safeIndex, in: nsText.length, windowSize: 2000)
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let matches = regex.matches(in: text, options: [], range: searchRange)
            for match in matches {
                if safeIndex >= match.range.location && safeIndex <= match.range.upperBound {
                    return match.range
                }
            }
        }
        return nil
    }
    
    static func findCodeBlockRange(in text: String, at index: Int) -> NSRange? {
        // Simple detection for triple backticks
        // This is a naive implementation and might need robustness for nested blocks if supported
        let pattern = #"```[\s\S]*?```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))
        
        let searchRange = getSearchRange(around: safeIndex, in: length, windowSize: 10000)
        let matches = regex.matches(in: text, options: [], range: searchRange)
        
        for match in matches {
            if safeIndex >= match.range.location && safeIndex <= match.range.upperBound {
                return match.range
            }
        }
        return nil
    }
    
    static func findQuoteRange(in text: String, at index: Int) -> NSRange? {
        if let typstRange = findBracketedRange(in: text, at: index, prefixPattern: #"#quote(?:\s*\([^)]*\))?\s*[\[(]"#) {
            return typstRange
        }
        
        // Markdown blockquote
        let nsText = text as NSString
        let safeIndex = max(0, min(index, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        if nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            return lineRange 
        }
        return nil
    }

    static func findFootnoteRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#footnote\s*[\[(]"#)
    }

    /// Finds the range of a scoped block (#[...]) surrounding the index.
    static func findScopedBlockRange(in text: String, at index: Int) -> NSRange? {
        // We look specifically for #[...]
        // Note: findBracketedRange handles nesting.
        return findBracketedRange(in: text, at: index, prefixPattern: #"#\["#)
    }

    static func findPageBreakRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
        if line.contains("#pagebreak()") {
            return lineRange
        }
        return nil
    }

    static func findFigureRange(in text: String, at index: Int) -> NSRange? {
        guard let range = findBracketedRange(in: text, at: index, prefixPattern: #"#figure(?:\s*\([^)]*\))?\s*[\[(]"#) else { return nil }
        
        // Try to include trailing label <label>
        let nsText = text as NSString
        var currentEnd = range.upperBound
        let length = nsText.length
        
        // Skip whitespace
        while currentEnd < length {
            let char = nsText.substring(with: NSRange(location: currentEnd, length: 1))
            if char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentEnd += 1
            } else {
                break
            }
        }
        
        if currentEnd < length && nsText.substring(with: NSRange(location: currentEnd, length: 1)) == "<" {
            var labelEnd = currentEnd + 1
            while labelEnd < length {
                let char = nsText.substring(with: NSRange(location: labelEnd, length: 1))
                if char == ">" {
                    return NSRange(location: range.location, length: labelEnd + 1 - range.location)
                }
                if char == "\n" { break } // Labels don't usually span lines
                labelEnd += 1
            }
        }
        
        return range
    }

    static func findHorizontalLineRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let safeIndex = max(0, min(index, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
        
        if line.contains("#line(length: 100%)") || line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
            return lineRange
        }
        return nil
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
    
    struct FigureInfo {
        let range: NSRange
        let content: String
        let caption: String
        let label: String
        let kind: String?
        let supplement: String?
    }

    static func parseFigure(in text: String, at index: Int) -> FigureInfo? {
        guard let range = findFigureRange(in: text, at: index) else { return nil }
        let nsText = text as NSString
        let snippet = nsText.substring(with: range)
        
        var content = ""
        var caption = ""
        var label = ""
        var kind: String? = nil
        var supplement: String? = nil
        
        // Extract content: it's the first argument in #figure(...) or the content in #figure[...]
        if snippet.hasPrefix("#figure[") {
            if let start = snippet.firstIndex(of: "["), let end = snippet.lastIndex(of: "]") {
                content = String(snippet[snippet.index(after: start)..<end])
            }
        } else if snippet.hasPrefix("#figure(") {
            // Find the end of the first argument (comma or closing paren)
            // This is naive and won't handle nested parens perfectly without a stack, 
            // but let's try a decent regex for common cases.
            if let start = snippet.firstIndex(of: "(") {
                let afterStart = snippet[snippet.index(after: start)...]
                // Look for first comma that isn't inside nested parens/brackets
                var depth = 0
                var firstArgEnd = afterStart.endIndex
                for (idx, char) in afterStart.enumerated() {
                    let stringIdx = afterStart.index(afterStart.startIndex, offsetBy: idx)
                    if char == "(" || char == "[" { depth += 1 }
                    else if char == ")" || char == "]" { 
                        if depth == 0 { firstArgEnd = stringIdx; break }
                        depth -= 1 
                    }
                    else if char == "," && depth == 0 { firstArgEnd = stringIdx; break }
                }
                content = String(afterStart[..<firstArgEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Extract metadata from () params
        if let parenStart = snippet.firstIndex(of: "("), let parenEnd = snippet.lastIndex(of: ")") {
            let params = String(snippet[snippet.index(after: parenStart)..<parenEnd])
            
            // Caption: [...] or "..."
            let captionPattern = #"caption:\s*(?:\[(.*?)\]|"(.*?)")"#
            if let regex = try? NSRegularExpression(pattern: captionPattern, options: [.dotMatchesLineSeparators]) {
                if let match = regex.firstMatch(in: params, options: [], range: NSRange(location: 0, length: params.count)) {
                    if let r1 = Range(match.range(at: 1), in: params) { caption = String(params[r1]) }
                    else if let r2 = Range(match.range(at: 2), in: params) { caption = String(params[r2]) }
                }
            }
            
            // Kind: "..."
            let kindPattern = #"kind:\s*"([^"]*)""#
            if let regex = try? NSRegularExpression(pattern: kindPattern, options: []) {
                if let match = regex.firstMatch(in: params, options: [], range: NSRange(location: 0, length: params.count)) {
                    if let r = Range(match.range(at: 1), in: params) { kind = String(params[r]) }
                }
            }
            
            // Supplement: [...] or "..."
            let supplementPattern = #"supplement:\s*(?:\[(.*?)\]|"(.*?)")"#
            if let regex = try? NSRegularExpression(pattern: supplementPattern, options: [.dotMatchesLineSeparators]) {
                if let match = regex.firstMatch(in: params, options: [], range: NSRange(location: 0, length: params.count)) {
                    if let r1 = Range(match.range(at: 1), in: params) { supplement = String(params[r1]) }
                    else if let r2 = Range(match.range(at: 2), in: params) { supplement = String(params[r2]) }
                }
            }
        }
        
        // Extract label: either label: <tag> inside or <tag> outside
        let labelPattern = #"<([^>]+)>"#
        if let regex = try? NSRegularExpression(pattern: labelPattern, options: []) {
            let matches = regex.matches(in: snippet, options: [], range: NSRange(location: 0, length: snippet.count))
            if let lastMatch = matches.last {
                if let r = Range(lastMatch.range(at: 1), in: snippet) {
                    label = String(snippet[r])
                }
            }
        }
        
        return FigureInfo(range: range, content: content, caption: caption, label: label, kind: kind, supplement: supplement)
    }

    /// Detects if the cursor at the given index is likely inside a Typst math block ($ ... $).
    /// This uses a heuristic of counting unescaped dollar signs from the beginning of text.
    static func isMathMode(in text: String, at index: Int) -> Bool {
        let nsText = text as NSString
        let length = nsText.length
        let safeIndex = max(0, min(index, length))
        var dollarCount = 0
        var i = 0
        
        while i < safeIndex && i < length {
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

    // --- Block Range & Parsing ---

    static func findBlockRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#block(?:\s*\([^)]*\))?\s*[\[(]"#)
    }

    struct BlockInfo {
        let range: NSRange
        let content: String
        let fill: String?
        let inset: String?
        let radius: String?
        let width: String?
        let stroke: String?
    }

    static func parseBlock(in text: String, at index: Int) -> BlockInfo? {
        guard let range = findBlockRange(in: text, at: index) else { return nil }
        let nsText = text as NSString
        let snippet = nsText.substring(with: range)
        
        var content = ""
        var fill: String?
        var inset: String?
        var radius: String?
        var width: String?
        var stroke: String?
        
        // Extract content between []
        // Note: We use lastIndex for the closer to handle nested blocks, but this is still slightly naive.
        // For TypstEdit, it's usually sufficient since snippet is already the matched block.
        if let bracketStart = snippet.firstIndex(of: "["), let bracketEnd = snippet.lastIndex(of: "]") {
            let start = snippet.index(after: bracketStart)
            content = String(snippet[start..<bracketEnd])
        }
        
        // Extract params from () using proper nesting check
        if snippet.contains("(") {
            let nsSnippet = snippet as NSString
            let startIdx = nsSnippet.range(of: "(").location + 1
            if let paramsRange = findClosingMarker(in: snippet, startingAt: startIdx, opener: "(", closer: ")") {
                // Exclude the closing paren
                let internalRange = NSRange(location: paramsRange.location, length: paramsRange.length - 1)
                let params = nsSnippet.substring(with: internalRange)
                fill = extractParam(from: params, name: "fill")
                inset = extractParam(from: params, name: "inset")
                radius = extractParam(from: params, name: "radius")
                width = extractParam(from: params, name: "width")
                stroke = extractParam(from: params, name: "stroke")
            }
        }
        
        return BlockInfo(range: range, content: content, fill: fill, inset: inset, radius: radius, width: width, stroke: stroke)
    }

    // --- Grid Range & Parsing ---

    static func findGridRange(in text: String, at index: Int) -> NSRange? {
        return findBracketedRange(in: text, at: index, prefixPattern: #"#grid\s*\("#)
    }

    struct GridInfo {
        let range: NSRange
        let columns: String?
        let gutter: String?
        let cells: [String]
    }

    static func parseGrid(in text: String, at index: Int) -> GridInfo? {
        guard let range = findGridRange(in: text, at: index) else { return nil }
        let nsText = text as NSString
        let snippet = nsText.substring(with: range)
        
        var columns: String?
        var gutter: String?
        var cells: [String] = []
        
        if snippet.contains("(") {
            let nsSnippet = snippet as NSString
            let startIdx = nsSnippet.range(of: "(").location + 1
            if let paramsRange = findClosingMarker(in: snippet, startingAt: startIdx, opener: "(", closer: ")") {
                // Exclude closing paren
                let internalRange = NSRange(location: paramsRange.location, length: paramsRange.length - 1)
                let params = nsSnippet.substring(with: internalRange)
                
                columns = extractParam(from: params, name: "columns")
                gutter = extractParam(from: params, name: "gutter")
                
                // Extract cells (everything else)
                cells = splitParamsIgnoringNesting(params)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { cell in
                        !cell.hasPrefix("columns:") && !cell.hasPrefix("gutter:") && !cell.isEmpty
                    }
            }
        }
        
        return GridInfo(range: range, columns: columns, gutter: gutter, cells: cells)
    }

    private static func extractParam(from params: String, name: String) -> String? {
        let segments = splitParamsIgnoringNesting(params)
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(name + ":") {
                let val = trimmed.dropFirst((name + ":").count).trimmingCharacters(in: .whitespacesAndNewlines)
                return val
            }
        }
        return nil
    }

    private static func splitParamsIgnoringNesting(_ params: String) -> [String] {
        var results: [String] = []
        var current = ""
        var depth = 0
        
        for char in params {
            if char == "(" || char == "[" || char == "{" {
                depth += 1
                current.append(char)
            } else if char == ")" || char == "]" || char == "}" {
                depth -= 1
                current.append(char)
            } else if char == "," && depth == 0 {
                results.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(current)
        }
        return results
    }

    private static func findRegexRange(in text: String, at index: Int, pattern: String, windowSize: Int = 2000) -> NSRange? {
        let nsText = text as NSString
        let safeIndex = max(0, min(index, nsText.length))
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let searchRange = getSearchRange(around: safeIndex, in: nsText.length, windowSize: windowSize)
        let matches = regex.matches(in: text, options: [], range: searchRange)
        for match in matches {
            // Check if cursor is inside the matched pattern
            if safeIndex >= match.range.location && safeIndex <= match.range.upperBound {
                return match.range
            }
        }
        return nil
    }
    
    static func findHTMLTagRange(in text: String, at index: Int, tag: String) -> NSRange? {
        let pattern = "(?s)<\(tag)>.*?</\(tag)>"
        return findRegexRange(in: text, at: index, pattern: pattern)
    }
}