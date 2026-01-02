import Foundation

struct TableInfo {
    let range: NSRange
    let columns: Int
    let rows: Int
    let cells: [String]
}

struct TableDetector {
    /// Finds the range of a #table(...) block surrounding the given index.
    static func findTableRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        
        // Very basic approach: find #table( and then find matching closing parenthesis
        // This won't handle nested parentheses perfectly but it's a start.
        
        let pattern = #"#table\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: length))
        
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
                if index >= range.location && index <= (range.location + range.length) {
                    return range
                }
            }
        }
        
        return nil
    }
    
    static func parseTable(in text: String, at index: Int) -> TableInfo? {
        guard let range = findTableRange(in: text, at: index) else { return nil }
        let tableCode = (text as NSString).substring(with: range)
        
        // Extract columns
        var cols = 1
        let colRegex = try? NSRegularExpression(pattern: #"columns:\s*(\d+)"#, options: [])
        let tupleRegex = try? NSRegularExpression(pattern: #"columns:\s*\((.*?)\)"#, options: [.dotMatchesLineSeparators])
        
        if let match = colRegex?.firstMatch(in: tableCode, options: [], range: NSRange(location: 0, length: tableCode.count)) {
            if let colStr = Range(match.range(at: 1), in: tableCode).map({ String(tableCode[$0]) }) {
                cols = Int(colStr) ?? 1
            }
        } else if let match = tupleRegex?.firstMatch(in: tableCode, options: [], range: NSRange(location: 0, length: tableCode.count)) {
            if let tupleContent = Range(match.range(at: 1), in: tableCode).map({ String(tableCode[$0]) }) {
                // Split by comma, but respect nested parentheses/brackets
                cols = smartSplit(tupleContent).count
            }
        }
        
        // Let's strip the #table(...) wrapper
        let startMatch = try? NSRegularExpression(pattern: #"^#table\s*\("#).firstMatch(in: tableCode, options: [], range: NSRange(location: 0, length: tableCode.count))
        let innerStart = startMatch?.range.length ?? 0
        let innerCode = String(tableCode.dropFirst(innerStart).dropLast(1))
        
        // Split inner code by commas, respecting parentheses and brackets
        let segments = smartSplit(innerCode)
        var cells: [String] = []
        
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            // If it's a named argument (like columns:, fill:, gutter:), skip it.
            // Named arguments must start with an identifier followed by a colon.
            // Simple check: does it contain a colon that is NOT inside brackets?
            if isNamedArgument(trimmed) {
                continue
            }
            
            cells.append(trimmed)
        }
        
        let rows = Int(ceil(Double(cells.count) / Double(cols)))
        
        return TableInfo(range: range, columns: cols, rows: rows, cells: cells)
    }
    
    /// Splits a string by commas but respects nesting of (), [], {}
    private static func smartSplit(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        
        for char in text {
            if char == "(" || char == "[" || char == "{" {
                depth += 1
                current.append(char)
            } else if char == ")" || char == "]" || char == "}" {
                depth -= 1
                current.append(char)
            } else if char == "," && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
    
    private static func isNamedArgument(_ segment: String) -> Bool {
        // A named argument looks like identifier: value
        // We only want to skip it if the colon is at the top level of this segment.
        var depth = 0
        for (i, char) in segment.enumerated() {
            if char == "(" || char == "[" || char == "{" {
                depth += 1
            } else if char == ")" || char == "]" || char == "}" {
                depth -= 1
            } else if char == ":" && depth == 0 {
                // Found a top-level colon. Is it a named arg?
                // Check if what precedes it is a valid identifier (alphanumeric + _ or -)
                let prefix = segment.prefix(i).trimmingCharacters(in: .whitespaces)
                let identifierPattern = #"^[a-zA-Z0-9_-]+$"#
                if let _ = prefix.range(of: identifierPattern, options: .regularExpression) {
                    return true
                }
            }
        }
        return false
    }
}
