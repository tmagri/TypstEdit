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
        ),
        "chart": TypstSnippet(
            name: "Chart",
            template: """
            #import "@preview/cetz:0.2.0"
            
            #cetz.canvas({
              import cetz.draw: *
              
              // Your chart code here
              line((0, 0), (1, 1))
            })
            """,
            cursorOffset: nil
        ),
        "timeline": TypstSnippet(
            name: "Timeline",
            template: """
            #import "@preview/cetz:0.2.0"
            
            #cetz.canvas({
              import cetz.draw: *
              
              // Draw the main line
              line((0, 0), (10, 0), mark: (end: ">"))
              
              // Helper to draw an event
              let event(x, label, sublabel) = {
                circle((x, 0), radius: 0.1, fill: black)
                content((x, 0.5), label)
                content((x, -0.5), text(size: 8pt, gray, sublabel))
              }
              
              // Add events
              event(0, "Project Start", "2024-01-01")
              event(5, "Milestone", "2024-06-01")
              event(10, "Completion", "2024-12-31")
            })
            """,
            cursorOffset: nil
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
