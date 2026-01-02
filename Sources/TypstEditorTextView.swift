import Cocoa

@MainActor
protocol TypstEditorTextViewDelegate: AnyObject {
    func openEquationEditor(at range: NSRange, initialContent: String)
}

class TypstEditorTextView: NSTextView {
    weak var editorDelegate: TypstEditorTextViewDelegate?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        
        // Get the insertion point from the mouse event
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = layoutManager?.glyphIndex(for: point, in: textContainer!) ?? NSNotFound
        
        print("[DEBUG] Right-click at point: \(point), charIndex: \(charIndex)")
        if charIndex != NSNotFound && charIndex < (string as NSString).length {
             let char = (string as NSString).substring(with: NSRange(location: charIndex, length: 1))
             print("[DEBUG] Character at index: '\(char)'")
        }
        
        // Also check logical selection if click is inside it
        let selectedRange = self.selectedRange()
        let isClickInsideSelection = charIndex >= selectedRange.location && charIndex < selectedRange.location + selectedRange.length
        
        // Use either the clicked index or the selection
        let effectiveIndex = isClickInsideSelection ? selectedRange.location : charIndex
        
        let equationRange = findProximityEquationRange(at: effectiveIndex)
        print("[DEBUG] findProximityEquationRange result: \(String(describing: equationRange))")
        
        if let equationRange = equationRange {
            let item = NSMenuItem(title: "Open Equation Editor", action: #selector(openEquationEditorAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSValue(range: equationRange)
            
            menu?.insertItem(NSMenuItem.separator(), at: 0)
            menu?.insertItem(item, at: 0)
        }
        
        return menu
    }
    
    @objc func openEquationEditorAction(_ sender: NSMenuItem) {
        guard let rangeValue = sender.representedObject as? NSValue else { return }
        let range = rangeValue.rangeValue
        
        if let content = (string as NSString?)?.substring(with: range) {
             // Strip the $$ markers for the editor (or keep them?) 
             // The plan said "Extract text between $$". Let's strip them here.
             // Double check lengths. $$ is 2 chars.
             if content.hasPrefix("$$") && content.hasSuffix("$$") && content.count >= 4 {
                 let innerContent = String(content.dropFirst(2).dropLast(2))
                 editorDelegate?.openEquationEditor(at: range, initialContent: innerContent)
             } else if content.hasPrefix("$") && content.hasSuffix("$") && content.count >= 2 {
                 let innerContent = String(content.dropFirst(1).dropLast(1))
                 editorDelegate?.openEquationEditor(at: range, initialContent: innerContent)
             } else {
                 // Fallback or just send whole thing
                 editorDelegate?.openEquationEditor(at: range, initialContent: content)
             }
        }
    }
    
    // Check if the index is inside a $$...$$ block
    func findProximityEquationRange(at index: Int) -> NSRange? {
        return EquationDetector.findEquationRange(in: string, at: index)
    }
}


// Extension to help with range
// Extension removed as it caused infinite recursion and NSValue.rangeValue is available in AppKit/Foundation overlay or via direct cast if needed.
// However, since we cast 'item.representedObject' to NSValue, we can use the 'rangeValue' property if available, 
// or simpler: just use UnsafePointer logic or NSValue(range:) wrapper.
// Actually, NSValue(range:) creates an ObjC value.
// The issue was: var rangeValue: NSRange { return self.rangeValue } calls itself.
// We can just rely on the standard API, or if it's missing (it IS standard but sometimes Swift overlay issues occur),
// we should just trust standard.
// Removing the extension completely.
