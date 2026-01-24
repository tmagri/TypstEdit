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
            if let range = msg.range(of: "(?<=unknown variable: )\\S+", options: .regularExpression) {
                let varName = String(msg[range])
                // Suggest defining it before? Hard to do with just line replacement.
                // Maybe replace with a definition?
                // "x" -> "#let x = 0; x" ? No that's messy.
                // Let's suggest changing it to "content" or wrapping strings?
                // If it looks like text, maybe wrap in quotes?
                fixes.append(TypstFix(title: "Quote '\(varName)'", replacement: code.replacingOccurrences(of: varName, with: "\"\(varName)\""), range: nil))
            }
        }
        
        return fixes
    }
}
