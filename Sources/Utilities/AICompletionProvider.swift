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
            
            debounceTask = Task {
                do {
                    // Debounce: Wait for user to stop typing briefly (Only for CLOUD AI)
                    try await Task.sleep(nanoseconds: 700 * 1_000_000)
                    
                    if Task.isCancelled { return }
                    
                    // Prepare Context
                    let context = AIContextManager.shared.generateContext(
                        text: text,
                        cursorIndex: index,
                        fileURL: url,
                        errors: errors
                    )
                    
                    let completionCode = try await AICompletionService.shared.fetchCompletion(prompt: context)
                    
                    if Task.isCancelled { return }
                    
                    if !completionCode.isEmpty {
                        let aiItem = AICompletionItem(
                            label: completionCode,
                            detail: "AI",
                            documentation: "AI Generated Suggestion"
                        )
                        
                        await MainActor.run {
                            // Only update if we're still on the same editor and potentially the same or similar prefix
                            guard let model = SuggestionController.shared.model as SuggestionViewModel?,
                                  model.activeTextView === textView else {
                                return
                            }
                            
                            // To prevent appending to a stale list, we check if the prefix is still valid
                            let currentIndex = cursorIndex(from: textView.cursorPositions.first?.start ?? pos.start, in: textView.text)
                            let currentPrefix = getWordPrefix(text: textView.text, cursorIndex: currentIndex)
                            
                            // If user is still typing the same prefix (or it's empty and we're just starting), or if the window is visible
                            // We merge the AI result.
                            if currentPrefix.hasPrefix(prefix) || prefix.hasPrefix(currentPrefix) {
                                // Add to items if not already present (based on label)
                                if !model.items.contains(where: { $0.label == aiItem.label }) {
                                    model.items.append(aiItem)
                                    print("[AICompletionProvider] AI result added to suggestions")
                                }
                            }
                        }
                    }
                } catch is CancellationError {
                    // Ignore
                } catch {
                    print("AI Completion task error: \(error)")
                }
            }
        }
        
        if !allItems.isEmpty {
            return (windowPosition: pos, items: allItems)
        } else if settings.isEnabled {
            // If only AI is enabled, we return an empty list so the window appears (or we could wait)
            // But returning nil might prevent the window from showing at all.
            // Let's return an empty list to indicate "Loading..." or just wait for the first AI result.
            // Actually, if we return nil, showCompletions might not show anything.
            // Let's return empty if AI is loading.
            return (windowPosition: pos, items: [])
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
