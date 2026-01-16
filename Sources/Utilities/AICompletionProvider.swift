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
        // Trigger on dots, parens, or maybe just let it trigger on typing
        return ["."]
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        
        guard AISettingsManager.shared.isEnabled else { return nil }
        
        // Cancel any pending request
        debounceTask?.cancel()
        
        let text = textView.text
        let url = controller?.currentFileURL
        
        // Debounce: Wait for user to stop typing briefly
        do {
            try await Task.sleep(nanoseconds: 700 * 1_000_000) // 700ms debounce
        } catch {
            return nil
        }
        
        if Task.isCancelled { return nil }
        
        // Prepare Prompt
        let context = AIContextManager.shared.generateContext(
            text: text,
            cursorIndex: cursorIndex(from: cursorPosition, in: text),
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
                return (windowPosition: cursorPosition, items: [item])
            }
        } catch {
            print("AI Completion Error: \(error)")
        }
        
        return nil
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        return nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        // Use text view controller's cursor positions to find selection
        if let range = textView.cursorPositions.first?.range, range.location != NSNotFound {
             textView.textView.insertText(item.label, replacementRange: range)
        } else {
             textView.textView.insertText(item.label, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
    
    // Helper to convert CursorPosition to String Index
    private func cursorIndex(from position: CursorPosition, in text: String) -> Int {
        var currentLine = 1
        var index = 0
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            if currentLine == position.start.line {
                // Determine column offset (1-based)
                let col = max(0, position.start.column - 1)
                return index + min(col, line.count)
            }
            index += line.count + 1 // +1 for newline
            currentLine += 1
        }
        return text.count
    }
}
