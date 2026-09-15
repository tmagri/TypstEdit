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
            // Every request that reaches us is an explicit user invocation
            // (Escape / Ctrl+Space) — typing never opens the suggestion window.
            let suggestions = OfflineCompletionService.shared.provideCompletion(text: text, cursorIndex: index, manualTrigger: true)
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
                        
                        let cleanedCode = Self.cleanedInsertionText(completionCode)
                        if !cleanedCode.isEmpty {
                            let aiItem = AICompletionItem(
                                label: cleanedCode,
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
                    
                    let cleanedCode = Self.cleanedInsertionText(completionCode)
                    if !cleanedCode.isEmpty {
                        let aiItem = AICompletionItem(
                            label: cleanedCode,
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

        let nsText = text as NSString
        let label = Self.cleanedInsertionText(item.label)

        // Merge instead of insert: suggestions frequently repeat what the user
        // already typed ("The quick brown" → "The quick brown fox …"). Replace
        // only the overlapping tail of the current line, inserting just the
        // remainder, so applying can never duplicate existing text.
        var lineStart = utf16Offset
        while lineStart > 0 {
            let ch = nsText.character(at: lineStart - 1)
            if ch == 0x0A || ch == 0x0D { break }
            lineStart -= 1
        }
        let typedPrefix = nsText.substring(with: NSRange(location: lineStart, length: utf16Offset - lineStart))
        let (replaceCount, insertion) = Self.mergeInsertion(label: label, typedPrefix: typedPrefix)

        let replacementRange = NSRange(location: utf16Offset - replaceCount, length: replaceCount)
        textView.textView.insertText(insertion, replacementRange: replacementRange)
    }

    /// Finds the longest suffix of `typedPrefix` that prefixes `label`.
    /// Returns how many UTF-16 units before the cursor to replace and the text
    /// to insert there (the unmatched remainder of `label`).
    static func mergeInsertion(label: String, typedPrefix: String) -> (replaceCount: Int, insertion: String) {
        var overlap = ""
        let maxK = min(typedPrefix.count, label.count, 2000)
        if maxK > 0 {
            for candidate in stride(from: maxK, through: 1, by: -1) {
                let suffix = typedPrefix.suffix(candidate)
                if suffix == label.prefix(candidate) {
                    overlap = String(suffix)
                    break
                }
            }
        }
        let insertion = String(label.dropFirst(overlap.count))
        return ((overlap as NSString).length, insertion)
    }

    /// Normalizes model output into insertable text: unwraps a fenced code
    /// block and drops everything from a cursor marker onward (that part
    /// belongs after the caret, and inserting it would duplicate text).
    static func cleanedInsertionText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            let withoutOpeningFence = text.dropFirst(3)
            if let firstNewline = withoutOpeningFence.firstIndex(of: "\n") {
                let body = withoutOpeningFence[withoutOpeningFence.index(after: firstNewline)...]
                if let closingFence = body.range(of: "```", options: .backwards) {
                    text = String(body[..<closingFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        for marker in ["<CURSOR>", "<cursor>", "<|cursor|>"] where text.range(of: marker) != nil {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
