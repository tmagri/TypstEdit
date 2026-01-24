import Foundation

struct TypstFix: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let replacement: String
    let range: NSRange? // If nil, use the error range effectively
}

struct TypstSuggestionEngine {
    static let shared = TypstSuggestionEngine()
    
    func suggestFixes(for error: TypstError, in code: String) -> [TypstFix] {
        var fixes: [TypstFix] = []
        let msg = error.message.lowercased()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Missing Semicolon
        if msg.contains("expected semicolon") || msg.contains("expected ';'") {
            // Check if already has semicolon
            if !trimmed.hasSuffix(";") {
                fixes.append(TypstFix(title: "Add semicolon", replacement: code + ";", range: nil))
            }
        }
        
        // 2. Unclosed Delimiters
        if msg.contains("unclosed parentheses") || msg.contains("expected ')'") {
             fixes.append(TypstFix(title: "Add closing ')'", replacement: code + ")", range: nil))
        }
        if msg.contains("unclosed brace") || msg.contains("expected '}'") {
             fixes.append(TypstFix(title: "Add closing '}'", replacement: code + "}", range: nil))
        }
        if msg.contains("unclosed bracket") || msg.contains("expected ']'") {
             fixes.append(TypstFix(title: "Add closing ']'", replacement: code + "]", range: nil))
        }
        
        // 3. Expected Token
        if msg.contains("expected equals sign") || msg.contains("expected '='") {
             // Only append if it looks like a variable decl? simplistic approach
             fixes.append(TypstFix(title: "Insert '='", replacement: code + " = ", range: nil))
        }
        
        // 4. Unknown Variable
        if msg.contains("unknown variable") {
            // Use original message for extraction to preserve case
            let originalMsg = error.message
            // Matches "unknown variable: <name>" and ignores trailing punctuation (like '.')
            if let range = originalMsg.range(of: "(?<=unknown variable: )[a-zA-Z0-9_\\-]+", options: .regularExpression) {
                let varName = String(originalMsg[range])
                
                // Use regex replacement to match whole words only
                // Escape varName for regex safety just in case, though standard vars are safe
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: varName))\\b"
                
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(code.startIndex..<code.endIndex, in: code)
                    let replaced = regex.stringByReplacingMatches(in: code, options: [], range: range, withTemplate: "\"\(varName)\"")
                    
                    // Only suggest if replacement actually changed something
                    if replaced != code {
                        fixes.append(TypstFix(title: "Quote '\(varName)'", replacement: replaced, range: nil))
                    }
                }
            }
        }
        
        return fixes
    }
}
