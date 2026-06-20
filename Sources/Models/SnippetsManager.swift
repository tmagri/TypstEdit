import Foundation
import AppKit

/// Represents a Typst code snippet template
struct TypstSnippet {
    let name: String
    let template: String
    let cursorOffset: Int? // Offset from insertion point where cursor should be placed
}

/// Manages Typst snippet templates and insertion logic
class SnippetsManager {
    @MainActor
    static let shared = SnippetsManager()
    
    private init() {}
    
    /// Available snippets
    let snippets: [String: TypstSnippet] = [
        "table": TypstSnippet(
            name: "Table",
            template: """
            #table(
              columns: (1fr, 1fr),
              [Header 1], [Header 2],
              [Row 1], [Data 1],
              [Row 2], [Data 2]
            )
            """,
            cursorOffset: nil
        ),
        "image": TypstSnippet(
            name: "Image",
            template: "#figure(image(\"path/to/image.png\"), caption: [Caption])",
            cursorOffset: 15 // Position cursor at "path/to/image.png"
        )
    ]
    
    /// Insert a snippet into the text view
    @MainActor
    func insertSnippet(_ key: String, into textView: NSTextView) {
        guard let snippet = snippets[key] else { return }
        
        let selectedRange = textView.selectedRange()
        
        // Insert the template
        if textView.shouldChangeText(in: selectedRange, replacementString: snippet.template) {
            textView.insertText(snippet.template, replacementRange: selectedRange)
            textView.didChangeText()
            
            // Position cursor if offset specified
            if let offset = snippet.cursorOffset {
                let newPosition = selectedRange.location + offset
                let newRange = NSRange(location: newPosition, length: 0)
                textView.setSelectedRange(newRange)
            }
        }
    }
}
