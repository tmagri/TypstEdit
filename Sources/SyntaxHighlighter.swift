import SwiftUI
import AppKit

class SyntaxHighlighter: NSObject, NSTextStorageDelegate {
    
    // Current theme state
    var minTheme: AppTheme = .dark
    
    // Dark Theme Colors (One Dark / Atom)
    private let darkComment = NSColor(red: 0.38, green: 0.44, blue: 0.48, alpha: 1.0)
    private let darkHeading = NSColor(red: 0.38, green: 0.69, blue: 0.93, alpha: 1.0)
    private let darkFunction = NSColor(red: 0.77, green: 0.49, blue: 0.88, alpha: 1.0)
    private let darkString = NSColor(red: 0.60, green: 0.77, blue: 0.49, alpha: 1.0)
    private let darkKeyword = NSColor(red: 0.77, green: 0.40, blue: 0.38, alpha: 1.0)
    private let darkMath = NSColor(red: 0.85, green: 0.73, blue: 0.45, alpha: 1.0)
    private let darkText = NSColor(red: 0.67, green: 0.71, blue: 0.76, alpha: 1.0)
    
    // Light Theme Colors (vs light / github light inspired)
    private let lightComment = NSColor(red: 0.42, green: 0.50, blue: 0.53, alpha: 1.0)
    private let lightHeading = NSColor(red: 0.02, green: 0.27, blue: 0.68, alpha: 1.0) // Dark Blue
    private let lightFunction = NSColor(red: 0.44, green: 0.16, blue: 0.49, alpha: 1.0) // Purple
    private let lightString = NSColor(red: 0.13, green: 0.50, blue: 0.00, alpha: 1.0) // Green
    private let lightKeyword = NSColor(red: 0.82, green: 0.09, blue: 0.20, alpha: 1.0) // Red
    private let lightMath = NSColor(red: 0.75, green: 0.50, blue: 0.00, alpha: 1.0) // Gold/Brown
    private let lightText = NSColor.black.withAlphaComponent(0.85) // Almost black
    
    func updateTheme(_ theme: AppTheme) {
        self.minTheme = theme
    }
    
    override init() {
        super.init()
    }
    
    
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        // Only re-highlight if characters changed
        guard editedMask.contains(.editedCharacters) else { return }
        
        // Delegate to the main highlighting function
        applyHighlighting(to: textStorage)
    }
    
    /// Public method to apply syntax highlighting to a text storage
    /// Can be called externally to highlight text on initial load
    func applyHighlighting(to textStorage: NSTextStorage) {
        let wholeRange = NSRange(location: 0, length: textStorage.length)
        let string = textStorage.string
        
        // Pick colors based on theme
        let isLight = (minTheme == .light)
        let textColor = isLight ? lightText : darkText
        let keywordColor = isLight ? lightKeyword : darkKeyword
        let functionColor = isLight ? lightFunction : darkFunction
        let stringColor = isLight ? lightString : darkString
        let mathColor = isLight ? lightMath : darkMath
        let headingColor = isLight ? lightHeading : darkHeading
        let commentColor = isLight ? lightComment : darkComment
        
        
        // Reset to default
        textStorage.addAttributes([.foregroundColor: textColor, .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)], range: wholeRange)
        
        // Order matters for overlapping matches. 
        
        // Keywords (let, set, show, import, include)
        let keywords = ["let", "set", "show", "import", "include", "if", "else", "for", "while", "break", "continue", "return"]
        for keyword in keywords {
             highlight(pattern: "\\b\(keyword)\\b", in: string, textStorage: textStorage, color: keywordColor, bold: true)
        }
        
        // Functions: #name or just #
        highlight(pattern: "#[a-zA-Z0-9_]+", in: string, textStorage: textStorage, color: functionColor, bold: false)
        
        // Strings: "..."
        highlight(pattern: "\"[^\"]*\"", in: string, textStorage: textStorage, color: stringColor)
        
        // Math: $...$
        highlight(pattern: "\\$[^\\$]+\\$", in: string, textStorage: textStorage, color: mathColor)

        // Headings: = ...
        highlight(pattern: "^=+\\s+.*", in: string, textStorage: textStorage, color: headingColor, bold: true)

        // Comments: // ...
        highlight(pattern: "//.*", in: string, textStorage: textStorage, color: commentColor)
    }
    
    private func highlight(pattern: String, in string: String, textStorage: NSTextStorage, color: NSColor?, bold: Bool = false) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        
        let range = NSRange(location: 0, length: string.utf16.count)
        regex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range {
                if let color = color {
                    textStorage.addAttribute(.foregroundColor, value: color, range: matchRange)
                }
                if bold {
                    textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold), range: matchRange)
                }
            }
        }
    }
}
