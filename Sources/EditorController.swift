import SwiftUI
import AppKit

@MainActor
class EditorController: NSObject, ObservableObject, TypstEditorTextViewDelegate {
    // --- Equation Editor State ---
    @Published var showEquationEditor: Bool = false
    @Published var currentEquationContent: String = ""
    var currentEquationRange: NSRange?
    
    // Delegate method
    func openEquationEditor(at range: NSRange, initialContent: String) {
        currentEquationRange = range
        currentEquationContent = initialContent
        showEquationEditor = true
    }
    
    func saveEquation(_ newContent: String) {
        guard let range = currentEquationRange, let textView = textView else { 
            print("[ERROR] saveEquation aborted: range=\(String(describing: currentEquationRange)), textView=\(textView != nil)")
            return 
        }
        
        print("[DEBUG] saveEquation: range=\(range), content length=\(newContent.count)")
        
        let replacement = "$\(newContent)$"
        
        if range.location != NSNotFound {
            print("[DEBUG] Inserting replacement: '\(replacement)' at range: \(range)")
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.insertText(replacement, replacementRange: range)
                textView.didChangeText()
                
                // For a better UX, select the newly inserted equation
                let newRange = NSRange(location: range.location, length: replacement.count)
                textView.setSelectedRange(newRange)
            }
        }
        
        showEquationEditor = false
    }
    @Published var errors: [TypstError] = []
    @Published var scrollPosition: CGFloat = 0
    
    // Référence faible vers la vue native pour manipuler le texte directement
    weak var textView: NSTextView? {
        didSet {
            setupScrollNotification()
        }
    }
    
    // Recherche
    @Published var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                performSearch()
            }
        }
    }
    @Published var searchMatches: [NSRange] = []
    @Published var currentMatchIndex: Int = -1
    
    var matchCount: Int {
        searchMatches.count
    }
    
    // Demande de redessiner la règle (numéros de ligne)
    func needsRedraw() {
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
    
    // --- Undo/Redo Functions ---
    
    func undo() {
        textView?.undoManager?.undo()
    }
    
    func redo() {
        textView?.undoManager?.redo()
    }
    
    // --- Snippet Functions ---
    
    func insertTableSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("table", into: textView)
    }
    
    func insertImageSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("image", into: textView)
    }
    
    func insertChartSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("chart", into: textView)
    }
    
    func insertTimelineSnippet() {
        guard let textView = textView else { return }
        SnippetsManager.shared.insertSnippet("timeline", into: textView)
    }
    
    // --- Search Functions ---
    
    func performSearch() {
        guard let textView = textView, !searchQuery.isEmpty else {
            clearSearch()
            return
        }
        
        let text = textView.string
        searchMatches = []
        
        // Find all matches (case-insensitive)
        let searchOptions: NSString.CompareOptions = [.caseInsensitive]
        var searchRange = NSRange(location: 0, length: text.utf16.count)
        
        while searchRange.location < text.utf16.count {
            let foundRange = (text as NSString).range(of: searchQuery, options: searchOptions, range: searchRange)
            if foundRange.location == NSNotFound {
                break
            }
            searchMatches.append(foundRange)
            searchRange = NSRange(location: foundRange.location + foundRange.length, 
                                length: text.utf16.count - (foundRange.location + foundRange.length))
        }
        
        // Highlight all matches
        if !searchMatches.isEmpty {
            currentMatchIndex = 0
            highlightMatches()
            scrollToMatch(at: 0)
        }
    }
    
    func highlightMatches() {
        guard let textView = textView, let textStorage = textView.textStorage else { return }
        
        // Remove previous highlights
        textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
        
        // Highlight all matches in yellow
        for (index, range) in searchMatches.enumerated() {
            let isCurrentMatch = (index == currentMatchIndex)
            let highlightColor = isCurrentMatch ? 
                NSColor.systemYellow : // Current match
                NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.0, alpha: 0.3) // Other matches
            textStorage.addAttribute(.backgroundColor, value: highlightColor, range: range)
        }
    }
    
    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        highlightMatches()
        scrollToMatch(at: currentMatchIndex)
    }
    
    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightMatches()
        scrollToMatch(at: currentMatchIndex)
    }
    
    func scrollToMatch(at index: Int) {
        guard let textView = textView, index >= 0, index < searchMatches.count else { return }
        let range = searchMatches[index]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
    
    func clearSearch() {
        searchMatches = []
        currentMatchIndex = -1
        if let textView = textView, let textStorage = textView.textStorage {
            textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
        }
    }
    
    // --- Commandes d'édition de texte ---
    
    // Insère du texte à la position du curseur
    func insertText(_ text: String) {
        guard let textView = textView else { return }
        
        let range = textView.selectedRange()
        if range.location != NSNotFound {
            textView.insertText(text, replacementRange: range)
        } else {
            // Fallback: ajout à la fin si pas de sélection valide
            let endRange = NSRange(location: textView.string.count, length: 0)
            textView.insertText(text, replacementRange: endRange)
        }
    }
    
    // Entoure la sélection actuelle avec un préfixe et un suffixe
    func wrapSelection(prefix: String, suffix: String) {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        if range.length == 0 {
            // Si rien n'est sélectionné : on insère les marqueurs et on place le curseur au milieu
            textView.insertText(prefix + suffix, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + prefix.count, length: 0))
        } else {
            // Si du texte est sélectionné : on l'entoure
            if let string = textView.string as NSString? {
                let selectedText = string.substring(with: range)
                let newText = prefix + selectedText + suffix
                textView.insertText(newText, replacementRange: range)
            }
        }
    }
    
    // --- Raccourcis de formatage Typst ---
    
    func toggleBold() { wrapSelection(prefix: "*", suffix: "*") }
    
    func toggleItalic() { wrapSelection(prefix: "_", suffix: "_") }
    
    func toggleCode() { wrapSelection(prefix: "`", suffix: "`") }
    
    func insertHeading() { insertText("= ") }
    
    func insertMath() { wrapSelection(prefix: "$", suffix: "$") }
    
    // Opens the visual equation editor for a new equation at the cursor
    func openNewEquationEditor() {
        guard let textView = textView else { return }
        let range = textView.selectedRange()
        
        // Priority: Check if cursor or selection is inside an existing equation
        if let equationRange = EquationDetector.findEquationRange(in: textView.string, at: range.location) {
            let fullText = textView.string as NSString
            let content = fullText.substring(with: equationRange)
            var innerContent = content
            
            if content.hasPrefix("$$") && content.hasSuffix("$$") && content.count >= 4 {
                innerContent = String(content.dropFirst(2).dropLast(2))
            } else if content.hasPrefix("$") && content.hasSuffix("$") && content.count >= 2 {
                innerContent = String(content.dropFirst(1).dropLast(1))
            }
            
            currentEquationRange = equationRange
            currentEquationContent = innerContent
            showEquationEditor = true
            return
        }
        
        // Fallback: If there is a selection, use it as initial content (stripping $ if present)
        var initialContent = ""
        if range.length > 0 {
             let selectedText = (textView.string as NSString).substring(with: range)
             // Simple strip of surrounding $
             initialContent = selectedText.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        }
        
        currentEquationRange = range
        currentEquationContent = initialContent
        showEquationEditor = true
    }
    
    // --- Navigation ---
    
    @MainActor
    func goToLine(_ lineNumber: Int) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager else { return }
        
        let text = textView.string as NSString
        var currentLine = 1
        var charIndex = 0
        
        while currentLine < lineNumber && charIndex < text.length {
            if text.character(at: charIndex) == 10 { // newline
                currentLine += 1
            }
            charIndex += 1
        }
        
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textView.textContainer!)
        textView.scrollToVisible(rect)
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
    }
    
    @MainActor
    private func setupScrollNotification() {
        guard let scrollView = textView?.enclosingScrollView else { return }
        
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}