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
        // Trigger on all letters, dots, #, space, (, and , to make it feel like real Intellisense
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.# (,"
        return Set(letters.map { String($0) })
    }

    @MainActor
    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        guard AISettingsManager.shared.isEnabled else { return nil }
        
        // Fallback: If passed position is invalid (-1, -1), use text view's current selection
        let pos = cursorPosition.start.line != -1 ? cursorPosition : (textView.cursorPositions.first ?? cursorPosition)
        print("[AICompletionProvider] Request for \(pos.start) (original was \(cursorPosition.start))")
        
        let settings = AISettingsManager.shared
        
        // Offline / Manual Mode
        if settings.provider == .offline {
            let text = textView.text
            let index = cursorIndex(from: pos.start, in: text)
            print("[AICompletionProvider] Offline request at index \(index)")
            
            // OfflineCompletionService is @MainActor, so we can call it directly as we are on @MainActor
            let suggestions = OfflineCompletionService.shared.provideCompletion(text: text, cursorIndex: index)
            
            if !suggestions.isEmpty {
                let items = suggestions.map { suggestion in
                    AICompletionItem(
                        label: suggestion,
                        detail: "Offline",
                        documentation: "Manual / Autocorrect Suggestion",
                        image: Image(systemName: "text.book.closed")
                    )
                }
                return (windowPosition: pos, items: items)
            }
            return nil
        }
        
        // Cancel any pending request
        debounceTask?.cancel()
        
        let text = textView.text
        let url = controller?.currentFileURL
        
        // Debounce: Wait for user to stop typing briefly (Only for CLOUD AI)
        do {
            try await Task.sleep(nanoseconds: 700 * 1_000_000) // 700ms debounce
        } catch {
            return nil
        }
        
        if Task.isCancelled { return nil }
        
        // Prepare Prompt
        let context = AIContextManager.shared.generateContext(
            text: text,
            cursorIndex: cursorIndex(from: pos.start, in: text),
            fileURL: url,
            errors: controller?.errors ?? []
        )
        
        do {
            let completionCode = try await AICompletionService.shared.fetchCompletion(prompt: context)
            
            if !completionCode.isEmpty {
                let item = AICompletionItem(
                    label: completionCode,
                    detail: "AI",
                    documentation: "AI Generated Suggestion"
                )
                return (windowPosition: pos, items: [item])
            }
        } catch {
            print("AI Completion Error: \(error)")
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
        let index = cursorIndex(from: currentPos, in: text)
        
        // Calculate the word prefix to replace
        let prefix = getWordPrefix(text: text, cursorIndex: index)
        let replacementRange = NSRange(location: index - prefix.count, length: prefix.count)
        
        textView.textView.insertText(item.label, replacementRange: replacementRange)
    }
    
    // Helper to extract word prefix (shared logic with OfflineCompletionService)
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
    
    // Helper to convert Position to String Index
    private func cursorIndex(from position: CursorPosition.Position, in text: String) -> Int {
        var currentLine = 1
        var index = 0
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            if currentLine == position.line {
                // Determine column offset (1-based)
                let col = max(0, position.column - 1)
                return index + min(col, line.count)
            }
            index += line.count + 1 // +1 for newline
            currentLine += 1
        }
        return text.count
    }
}
