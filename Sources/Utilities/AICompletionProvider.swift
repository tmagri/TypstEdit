import Foundation
import CodeEditSourceEditor
import SwiftUI

struct AICompletionItem: CodeSuggestionEntry {
    var label: String
    var detail: String?
    var documentation: String?
    var pathComponents: [String]? = nil
    var targetPosition: CursorPosition? = nil
    var sourcePreview: String? = nil
    var image: Image = Image(systemName: "sparkles")
    var imageColor: Color = .purple
    var deprecated: Bool = false
}

@MainActor
class AICompletionProvider: CodeSuggestionDelegate {
    
    weak var controller: EditorController?
    
    init(controller: EditorController? = nil) {
        self.controller = controller
    }
    
    // Debounce timer
    private var debounceTask: Task<Void, Never>?
    
    func completionTriggerCharacters() -> Set<String> {
        // Restricted to explicit Typst markers to prevent hijacking the Return key during normal typing.
        let triggers = ".#@"
        return Set(triggers.map { String($0) })
    }

    @MainActor
    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        let settings = AISettingsManager.shared
        guard settings.isEnabled || settings.intellisenseEnabled else { return nil }
        
        let pos = cursorPosition.start.line != -1 ? cursorPosition : (textView.cursorPositions.first ?? cursorPosition)
        let text = textView.text
        let index = cursorIndex(from: pos.start, in: text)
        let prefix = getWordPrefix(text: text, cursorIndex: index)
        
        var allItems: [any CodeSuggestionEntry] = []
        
        // 1. Manual Intellisense (Immediate)
        if settings.intellisenseEnabled {
            let suggestions = OfflineCompletionService.shared.provideCompletion(text: text, cursorIndex: index)
            let items = suggestions.map { suggestion in
                AICompletionItem(
                    label: suggestion,
                    detail: "Offline",
                    documentation: "Manual / Autocorrect Suggestion",
                    image: Image(systemName: "text.book.closed")
                )
            }
            allItems.append(contentsOf: items)
        }
        
        // 2. AI Completion (Async)
        if settings.isEnabled {
            // Cancel any pending request
            debounceTask?.cancel()
            
            let url = controller?.currentFileURL
            let errors = controller?.errors ?? []
            
            if !allItems.isEmpty {
                // We already have local Intellisense results.
                // Return them immediately so the UI is snappy, and fetch AI in the background.
                debounceTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: 700 * 1_000_000)
                        if Task.isCancelled { return }
                        let context = await AIContextManager.shared.generateContext(
                            userPrompt: String(prefix.suffix(100)),
                            text: text,
                            cursorIndex: index,
                            fileURL: url,
                            errors: errors
                        )
                        let completionCode = try await AICompletionService.shared.fetchCompletion(prompt: context, purpose: .completion)
                        if Task.isCancelled { return }
                        
                        if !completionCode.isEmpty {
                            let aiItem = AICompletionItem(
                                label: completionCode,
                                detail: "AI",
                                documentation: "AI Generated Suggestion"
                            )
                            await MainActor.run {
                                guard let model = SuggestionController.shared.model as SuggestionViewModel?,
                                      model.activeTextView === textView else { return }
                                
                                let currentIndex = cursorIndex(from: textView.cursorPositions.first?.start ?? pos.start, in: textView.text)
                                let currentPrefix = getWordPrefix(text: textView.text, cursorIndex: currentIndex)
                                
                                if currentPrefix.hasPrefix(prefix) || prefix.hasPrefix(currentPrefix) {
                                    if !model.items.contains(where: { $0.label == aiItem.label }) {
                                        model.items.append(aiItem)
                                        print("[AICompletionProvider] AI result added to suggestions")
                                    }
                                }
                            }
                        }
                    } catch { }
                }
            } else {
                // No local results. Await the AI so we don't return an empty array prematurely,
                // which would prevent the completion window from showing.
                do {
                    try await Task.sleep(nanoseconds: 700 * 1_000_000)
                    try Task.checkCancellation()
                    
                    let context = await AIContextManager.shared.generateContext(
                        userPrompt: String(prefix.suffix(100)),
                        text: text,
                        cursorIndex: index,
                        fileURL: url,
                        errors: errors
                    )
                    
                    let completionCode = try await AICompletionService.shared.fetchCompletion(prompt: context, purpose: .completion)
                    try Task.checkCancellation()
                    
                    if !completionCode.isEmpty {
                        let aiItem = AICompletionItem(
                            label: completionCode,
                            detail: "AI",
                            documentation: "AI Generated Suggestion"
                        )
                        allItems.append(aiItem)
                        print("[AICompletionProvider] AI result fetched successfully")
                    }
                } catch is CancellationError {
                    // Ignored
                } catch {
                    print("AI Completion task error: \(error)")
                }
            }
        }
        
        if !allItems.isEmpty {
            return (windowPosition: pos, items: allItems)
        }
        
        return nil
    }

    @MainActor
    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]? {
        return nil
    }

    @MainActor
    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        let text = textView.text
        let currentPos = cursorPosition?.start ?? textView.cursorPositions.first?.start ?? .init(line: 1, column: 1)
        let utf16Offset = cursorUTF16Offset(from: currentPos, in: text)
        
        // Calculate the word prefix to replace (in UTF-16 units)
        let prefix = getWordPrefix(text: text, utf16Offset: utf16Offset)
        let prefixUTF16Len = (prefix as NSString).length
        let replacementRange = NSRange(location: utf16Offset - prefixUTF16Len, length: prefixUTF16Len)
        
        textView.textView.insertText(item.label, replacementRange: replacementRange)
    }
    
    // Helper to extract word prefix using UTF-16 offset
    private func getWordPrefix(text: String, utf16Offset: Int) -> String {
        let nsText = text as NSString
        guard utf16Offset > 0, utf16Offset <= nsText.length else { return "" }
        
        var start = utf16Offset
        while start > 0 {
            let prevStart = start - 1
            let charCode = nsText.character(at: prevStart)
            guard let scalar = Unicode.Scalar(charCode) else {
                start = prevStart
                continue
            }
            
            // Check for whitespace
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            // Check for delimiters
            if ["(", ")", "[", "]", "{", "}", ",", ";"].contains(Character(scalar)) { break }
            // Include '#' as part of the prefix (Typst function marker)
            if scalar == Unicode.Scalar("#") {
                start = prevStart
                break
            }
            start = prevStart
        }
        
        return nsText.substring(with: NSRange(location: start, length: utf16Offset - start))
    }
    
    // Helper to extract word prefix using Swift character offset (for suggestion lookups)
    private func getWordPrefix(text: String, cursorIndex: Int) -> String {
        guard cursorIndex > 0, cursorIndex <= text.count else { return "" }
        let endIndex = text.index(text.startIndex, offsetBy: cursorIndex)
        var startIndex = endIndex
        
        while startIndex > text.startIndex {
            let prevIndex = text.index(before: startIndex)
            let char = text[prevIndex]
            if char.isWhitespace || ["(", ")", "[", "]", "{", "}", ",", ";"].contains(char) {
                break
            }
            if char == "#" {
                startIndex = prevIndex
                break
            }
            startIndex = prevIndex
        }
        
        return String(text[startIndex..<endIndex])
    }
    
    // Helper to convert line/column Position to a UTF-16 offset suitable for NSRange
    private func cursorUTF16Offset(from position: CursorPosition.Position, in text: String) -> Int {
        let nsText = text as NSString
        var utf16Index = 0
        var currentLine = 1
        
        // Walk through the string character by character in UTF-16
        while utf16Index < nsText.length && currentLine < position.line {
            let ch = nsText.character(at: utf16Index)
            utf16Index += 1
            if ch == 0x0A { // \n
                currentLine += 1
            } else if ch == 0x0D { // \r
                // If \r\n, consume the \n as well
                if utf16Index < nsText.length && nsText.character(at: utf16Index) == 0x0A {
                    utf16Index += 1
                }
                currentLine += 1
            }
        }
        
        // Now utf16Index points to the start of the target line
        // Add column offset (1-based)
        let col = max(0, position.column - 1)
        // Don't go past the end of the line or the string
        var colAdded = 0
        while colAdded < col && utf16Index < nsText.length {
            let ch = nsText.character(at: utf16Index)
            if ch == 0x0A || ch == 0x0D { break } // Don't go past end of line
            utf16Index += 1
            colAdded += 1
        }
        
        return utf16Index
    }
    
    // Keep the old cursorIndex for the suggestion request logic (which uses Swift character offsets)
    private func cursorIndex(from position: CursorPosition.Position, in text: String) -> Int {
        var currentLine = 1
        var index = 0
        var i = text.startIndex
        
        while i < text.endIndex && currentLine < position.line {
            if text[i] == "\n" {
                currentLine += 1
            } else if text[i] == "\r" {
                currentLine += 1
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\n" {
                    i = next
                    index += 1
                }
            }
            i = text.index(after: i)
            index += 1
        }
        
        let col = max(0, position.column - 1)
        var colAdded = 0
        while colAdded < col && i < text.endIndex {
            if text[i] == "\n" || text[i] == "\r" { break }
            i = text.index(after: i)
            index += 1
            colAdded += 1
        }
        
        return index
    }
}
