import Foundation

struct EquationDetector {
    /// Finds the range of an equation block delimited by `$` or `$$` surrounding the given index.
    /// Returns the range including the delimiters.
    static func findEquationRange(in text: String, at index: Int) -> NSRange? {
        // Convert to NSString for consistent indexing with NSTextView
        let nsText = text as NSString
        let length = nsText.length
        
        // Pattern: Matches $...$ but skips escaped \$
        // Using lookbehind/lookahead for escapes or just simple match and filter
        // Typst math: $...$ for both inline and display.
        // We match anything between dollars, including nested dollars (which Typst doesn't really have 
        // in basic blocks, but might occur in strings? No, math is usually flat).
        
        // Simple regex: $(non-escaped-anything)$
        // This pattern detects $...$ while ignoring \$
        let pattern = #"(?<!\\)\$(.*?)(?<!\\)\$"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: length))
        
        // Find a match that covers the index OR is adjacent to it (within 1 char)
        // Adjacency is important for clicks at the very end or start of the line
        for match in matches {
            let range = match.range
            
            // If the cursor is inside the range (inclusive)
            if index >= range.location && index <= (range.location + range.length) {
                let content = nsText.substring(with: range)
                print("[DEBUG] EquationDetector: Match found at \(range) content: '\(content)'")
                return range
            }
            
            // Check adjacency (click just after)
            if index == range.location + range.length {
                let content = nsText.substring(with: range)
                print("[DEBUG] EquationDetector: Adjacent match found at \(range) content: '\(content)'")
                return range
            }
        }
        
        print("[DEBUG] EquationDetector: No equation found at or near index \(index)")
        return nil
    }
}
