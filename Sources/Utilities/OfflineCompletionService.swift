import Foundation

@MainActor
class OfflineCompletionService {
    static let shared = OfflineCompletionService()
    
    // Common Typst Functions
    private let typstFunctions: [String] = [
        "accumulate", "align", "aqua", "array", "assert", "auto", "base", "baseline",
        "bibliography", "black", "block", "blue", "body", "bottom", "box", "break",
        "calc", "caption", "case", "center", "circle", "cmyk", "colbreak", "color",
        "columns", "content", "counter", "csv", "datetime", "direction", "document",
        "duration", "ellipse", "emoji", "emph", "enum", "eval", "figure", "fill",
        "font", "footnote", "fraction", "fuchsia", "function", "gradient", "gray",
        "green", "grid", "h", "heading", "hide", "highlight", "horizon", "image",
        "int", "json", "layout", "left", "length", "let", "lime", "line", "link",
        "list", "locate", "loop", "lorem", "lower", "ltr", "luma", "margin", "maroon",
        "max", "measure", "metadata", "min", "move", "navy", "numbering", "olive",
        "orange", "outline", "outset", "over", "pad", "page", "pagebreak", "panic",
        "par", "parbreak", "path", "pattern", "place", "plugin", "polygon", "purple",
        "query", "quote", "ratio", "read", "rect", "red", "regex", "relative", "repeat",
        "repr", "return", "rgb", "right", "rotate", "rtl", "scale", "selector", "set",
        "shading", "shape", "show", "silver", "skew", "smallcaps", "smartquote",
        "sort", "spacing", "square", "stack", "state", "str", "strike", "stroke",
        "strong", "style", "sub", "super", "symbol", "sym", "table", "teal", "text",
        "top", "ttb", "type", "underline", "upper", "v", "visualize", "white", "width",
        "xml", "yellow"
    ]
    
    // Common Typst Targets for #set and #show
    private let setTargets: [String] = [
        "page", "text", "heading", "par", "list", "enum", "table", "grid", 
        "link", "image", "math", "equation", "document", "bibliography", 
        "footnote", "outline", "cite"
    ]
    
    // Common Properties for functions like text(...)
    private let commonProperties: [String] = [
        "fill", "stroke", "radius", "inset", "outset", "caption", 
        "width", "height", "columns", "rows", "gutter", "align"
    ]
    
    // Function-specific parameters
    private let functionParameters: [String: [String]] = [
        "page": ["paper", "width", "height", "flipped", "margin", "fill", "numbering", "header", "footer", "background", "foreground", "binding"],
        "text": ["font", "size", "fill", "weight", "style", "tracking", "spacing", "baseline", "lang", "region", "features", "hyphenate", "kerning", "ligatures", "number-type", "number-width", "overhang", "slashed-zero", "stylistic-set", "weight"],
        "table": ["columns", "rows", "gutter", "fill", "align", "stroke", "inset", "column-gutter", "row-gutter", "header", "footer"],
        "grid": ["columns", "rows", "gutter", "fill", "align", "stroke", "inset", "column-gutter", "row-gutter"],
        "heading": ["level", "numbering", "outlined", "bookmarked", "supplement"],
        "image": ["path", "width", "height", "alt", "fit"],
        "align": ["alignment"],
        "block": ["fill", "stroke", "radius", "inset", "outset", "width", "height", "breakable", "spacing", "above", "below"],
        "box": ["fill", "stroke", "radius", "inset", "outset", "width", "height", "baseline"],
        "list": ["marker", "indent", "body-indent", "spacing", "tight"],
        "enum": ["numbering", "start", "indent", "body-indent", "spacing", "tight"],
        "math": ["display", "numbering", "supplement"],
        "equation": ["block", "numbering", "supplement"]
    ]
    
    private init() {}
    
    func provideCompletion(text: String, cursorIndex: Int) -> [String] {
        let prefix = getWordPrefix(text: text, cursorIndex: cursorIndex)
        print("[OfflineCompletion] Prefix found: '\(prefix)' at index \(cursorIndex)")
        
        var suggestions: [String] = []
        
        // Context Check: Are we after #set or #show?
        let prevWord = getPreviousWord(text: text, cursorIndex: cursorIndex - prefix.count)
        if prevWord == "#set" || prevWord == "#show" {
            let term = prefix.lowercased()
            let matches = setTargets.filter { $0.hasPrefix(term) }
            suggestions.append(contentsOf: matches.map { $0 + "(" })
            if !suggestions.isEmpty { return suggestions }
        }
        
        // Context Check: Are we inside an argument list?
        if let enclosingFunc = getEnclosingFunction(text: text, cursorIndex: cursorIndex) {
            let term = prefix.lowercased()
            var paramSuggestions: [String] = []
            
            // Try specific function parameters first
            if let specificParams = functionParameters[enclosingFunc] {
                paramSuggestions.append(contentsOf: specificParams.filter { $0.hasPrefix(term) })
            }
            
            // Fallback to common properties if prefix matches
            let commonMatches = commonProperties.filter { $0.hasPrefix(term) }
            for match in commonMatches {
                if !paramSuggestions.contains(match) {
                    paramSuggestions.append(match)
                }
            }
            
            if !paramSuggestions.isEmpty {
                return paramSuggestions.map { $0 + ": " }
            }
        }

        if prefix.isEmpty { return [] }
        
        // 1. Typst Functions (Triggered by #)
        if prefix.starts(with: "#") {
            let term = String(prefix.dropFirst()).lowercased()
            let matches = typstFunctions.filter { $0.hasPrefix(term) }
            
            // Keywords that should NOT have parenthesis
            let keywords = ["set", "show", "let", "import", "include", "as", "from", "return", "auto", "none"]
            
            // Functions that should be auto-closed ()
            let parameterless = ["pagebreak", "parbreak", "colbreak", "linebreak"]
            
            suggestions.append(contentsOf: matches.map { match in
                if keywords.contains(match) {
                    return "#" + match
                } else if parameterless.contains(match) {
                    return "#" + match + "()"
                } else {
                    return "#" + match + "("
                }
            })
        }
        
        // 2. Grammar: Sentence Capitalization
        if suggestions.isEmpty, let first = prefix.first, first.isLowercase {
            let startOfWordIndex = cursorIndex - prefix.count
            if isStartOfSentence(text: text, index: startOfWordIndex) {
                suggestions.append(prefix.capitalized)
            }
        }
        
        return suggestions
    }
    
    private func getPreviousWord(text: String, cursorIndex: Int) -> String {
        var curr = cursorIndex
        let nsText = text as NSString
        // Skip current whitespace
        while curr > 0 {
            let charStr = nsText.substring(with: NSRange(location: curr - 1, length: 1))
            if !charStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            curr -= 1
        }
        return getWordPrefix(text: text, cursorIndex: curr)
    }
    
    private func getEnclosingFunction(text: String, cursorIndex: Int) -> String? {
        var curr = cursorIndex
        let nsText = text as NSString
        var openParens = 0
        
        while curr > 0 {
            curr -= 1
            let charStr = nsText.substring(with: NSRange(location: curr, length: 1))
            
            if charStr == ")" || charStr == "]" {
                openParens -= 1
            } else if charStr == "(" || charStr == "[" {
                openParens += 1
                if openParens > 0 {
                    // We found the opening bracket/paren for the current scope.
                    // Now look back for the function name.
                    return getWordPrefix(text: text, cursorIndex: curr).replacingOccurrences(of: "#", with: "")
                }
            }
            
            if charStr == "\n" { break }
        }
        return nil
    }
    
    private func isInsideArguments(text: String, cursorIndex: Int) -> Bool {
        return getEnclosingFunction(text: text, cursorIndex: cursorIndex) != nil
    }
    
    private func getWordPrefix(text: String, cursorIndex: Int) -> String {
        guard cursorIndex > 0, cursorIndex <= text.count else { return "" }
        let endIndex = text.index(text.startIndex, offsetBy: cursorIndex)
        var startIndex = endIndex
        
        while startIndex > text.startIndex {
            let prevIndex = text.index(before: startIndex)
            let char = text[prevIndex]
            // Stop at whitespace or special structural chars
            if char.isWhitespace || ["(", ")", "[", "]", "{", "}", ",", ";"].contains(char) {
                break
            }
            // If we hit #, that's the start of the function, so we include it and stop going back
            if char == "#" {
                startIndex = prevIndex
                break
            }
            startIndex = prevIndex
        }
        
        return String(text[startIndex..<endIndex])
    }
    
    private func isStartOfSentence(text: String, index: Int) -> Bool {
        // Scan backwards from index
        var curr = index
        let nsText = text as NSString
        
        while curr > 0 {
            curr -= 1
            let charRange = NSRange(location: curr, length: 1)
            let charStr = nsText.substring(with: charRange)
            let char = Character(charStr)
            
            // Skip whitespace (including newlines here, but we check newlines below)
            if char.isWhitespace && char != "\n" { continue }
            
            // If we hit a sentence terminator or a newline, then yes, it's a new sentence
            if [".", "!", "?", "\n"].contains(charStr) {
                return true
            }
            
            // If we hit any other character, it's NOT a new sentence
            return false
        }
        
        // If we reached the beginning of the file, it IS start of sentence
        return true
    }
}
