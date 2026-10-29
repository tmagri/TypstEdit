import Foundation

struct TypstFix: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let replacement: String
    let range: NSRange? // If nil, use the error range effectively
}

enum SuggestionRegex {
    static let unknownVariable = try! NSRegularExpression(pattern: #"(?<=unknown variable: )[a-zA-Z0-9_\-]+"#)
    /// A `#` that cannot start code: followed by whitespace, closing punctuation,
    /// or the end of the line (e.g. "C# source").
    static let bareHash = try! NSRegularExpression(pattern: #"(?<!\\)#(?=[\s.,;:!?)\]}]|$)"#)
}

struct TypstSuggestionEngine {
    static let shared = TypstSuggestionEngine()
    
    func suggestFixes(for error: TypstError, in code: String) -> [TypstFix] {
        var fixes: [TypstFix] = []
        let msg = error.message.lowercased()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 0. A `#` that is meant as text ("C# source") reads as unfinished code.
        if msg.contains("expected expression") {
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            // Template `\\#` inserts a literal `\#`.
            let escaped = SuggestionRegex.bareHash.stringByReplacingMatches(in: code, options: [], range: range, withTemplate: "\\\\#")
            if escaped != code {
                fixes.append(TypstFix(title: "Escape # as \\#", replacement: escaped, range: nil))
            }
        }

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
            if let match = SuggestionRegex.unknownVariable.firstMatch(in: originalMsg, options: [], range: NSRange(0..<originalMsg.utf16.count)),
               let range = Range(match.range, in: originalMsg) {
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

                // `#name` meant as literal text: escape the hash.
                let hashPattern = #"(?<!\\)#(?="# + NSRegularExpression.escapedPattern(for: varName) + #"\b)"#
                if let regex = try? NSRegularExpression(pattern: hashPattern) {
                    let range = NSRange(code.startIndex..<code.endIndex, in: code)
                    let escaped = regex.stringByReplacingMatches(in: code, options: [], range: range, withTemplate: "\\\\#")
                    if escaped != code {
                        fixes.append(TypstFix(title: "Show '#\(varName)' as text", replacement: escaped, range: nil))
                    }
                }
            }
        }
        
        return fixes
    }
}

/// Plain-English guidance for common Typst diagnostics, shown in the error panel
/// under "How to fix". Typst's own messages are terse ("expected expression");
/// these say what usually causes the error and what to type instead.
enum TypstErrorExplainer {
    static func explanation(for error: TypstError) -> String? {
        let msg = error.message.lowercased()

        if msg.contains("source file must be contained in project root") {
            return "Typst could not find a folder it may read that contains both this document and its temporary copy. Reopen the document to restart the preview. If it keeps happening, turn on “Store Temp Files Inside Project” in Project Settings."
        }
        if msg.hasPrefix("expected expression") {
            if isNearHash(error) {
                return ##"`#` starts code in Typst, so a `#` followed by a space or punctuation (as in “C#”) is read as unfinished code. To show the character itself, write `\#`."##
            }
            return #"Typst expected a value here, for example after `#`, an operator, `=` or `:`. Finish the expression, or put `\` before the character to show it as text."#
        }
        if msg.hasPrefix("unclosed delimiter") {
            if let ch = characterAtCaret(error), ch == "_" || ch == "*" {
                let effect = ch == "_" ? "emphasis" : "strong text"
                return "`\(ch)` switches \(effect) on and off in Typst, and this one is never closed. Close it, or write `\\\(ch)` to show the character itself."
            }
            return #"Something opened here is never closed: `[`, `(`, `{`, `"`, `_` or `*`. Add the closing character, or put `\` before the opening one to show it as text."#
        }
        if msg.hasPrefix("unclosed raw text") {
            return #"A backtick starts code text and is never closed. Add the closing backtick, or put `\` before it to show a backtick as text."#
        }
        if msg.hasPrefix("unclosed string") {
            return #"A quoted string is never closed. Add the closing `"`."#
        }
        if msg.hasPrefix("unknown variable") {
            let name = error.message.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            return ##"`\##(name)` is not defined here. Check the spelling, define it with `#let`, or import it. If you meant plain text, write `\#` instead of `#`."##
        }
        if msg.hasPrefix("unexpected argument") {
            return "This function does not accept that argument. Check the argument name in the function's documentation (spelling and case matter)."
        }
        if msg.hasPrefix("missing argument") {
            return "This function needs an argument that is missing. Check the function's documentation for its required parameters."
        }
        if msg.contains("does not exist in the document") {
            return "This reference points to a label that is not defined. Add the label (for example `<intro>`) after a heading or figure, or fix the spelling."
        }
        if msg.hasPrefix("file not found") {
            return "Typst can't find this file. Relative paths start from this document's folder; paths that begin with `/` start from the project root. Check the name, extension and upper/lower case."
        }
        if msg.hasPrefix("package not found") || msg.contains("failed to download") {
            return "Check the package name and version on Typst Universe (typst.app/universe). Downloading packages needs an internet connection."
        }
        if msg.hasPrefix("unknown font family") {
            return "This font is not installed on your Mac, so Typst uses a fallback font. Install the font, or choose one that Font Book lists."
        }
        if msg.contains("index out of bounds") || msg.contains("does not contain key") {
            return "That index or key does not exist. Use `.at(…, default: …)` to give a fallback value."
        }
        if msg.hasPrefix("cannot add") || msg.hasPrefix("cannot join") || msg.hasPrefix("cannot subtract")
            || msg.hasPrefix("cannot multiply") || msg.hasPrefix("cannot divide") {
            return #"These two values have types that can't be combined. Convert one first, for example `str(5)` for text or `int("5")` for a number."#
        }
        if msg.hasPrefix("expected ") && msg.contains(", found ") {
            return ##"This value has the wrong type here. For example, sizes need a unit (`12pt`, `1em`) and colors use `rgb("#336699")`."##
        }
        if msg.contains("no text within underscores") || msg.contains("no text within stars") {
            return #"`_` or `*` with nothing between them. Write `\_` or `\*` to show the characters themselves."#
        }
        return nil
    }

    /// The character the caret (`^`) points at, if known.
    private static func characterAtCaret(_ error: TypstError) -> Character? {
        guard let snippet = error.snippet, let column = error.column else { return nil }
        let chars = Array(snippet)
        return column < chars.count ? chars[column] : nil
    }

    /// True when the caret points at, or directly after, a `#`.
    private static func isNearHash(_ error: TypstError) -> Bool {
        guard let snippet = error.snippet, let column = error.column else { return false }
        let chars = Array(snippet)
        if column < chars.count, chars[column] == "#" { return true }
        return column > 0 && column - 1 < chars.count && chars[column - 1] == "#"
    }
}
