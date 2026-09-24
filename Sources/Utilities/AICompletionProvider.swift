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

    // Read the setting from your app's settings manager
    var isContinuousCompletionEnabled: Bool {
        AISettingsManager.shared.isContinuousCompletionEnabled
    }
    
    init(controller: EditorController? = nil) {
        self.controller = controller
    }
    
    // Debounce timer
    private var debounceTask: Task<Void, Never>?
    
    func completionTriggerCharacters() -> Set<String> {
        // Trigger on explicit Typst markers
        var triggers = Set([".", "#", "@", ":", "=", "/"])
        
        let settings = AISettingsManager.shared
        // If continuous completion is enabled, trigger on any letter
        if (settings.isEnabled || settings.intellisenseEnabled) && settings.isContinuousCompletionEnabled {
            let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            triggers.formUnion(alphabet.map { String($0) })
        }
        
        return triggers
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
        
        // 1. Offline Intellisense (Immediate, 0ms latency)
        if settings.intellisenseEnabled {
            let suggestions = OfflineCompletionService.shared.provideCompletion(
                text: text,
                cursorIndex: index,
                manualTrigger: prefix.isEmpty
            )
            let items = suggestions.map { suggestion in
                AICompletionItem(
                    label: suggestion,
                    detail: "Offline",
                    documentation: "Typst Syntax / Suggestion",
                    image: Image(systemName: "text.book.closed")
                )
            }
            allItems.append(contentsOf: items)
        }
        
        // 2. AI Completion (Async in background, never blocking the editor)
        if settings.isEnabled {
            // Cancel any in-flight AI task immediately when new keystroke arrives
            debounceTask?.cancel()
            debounceTask = nil
            
            let url = controller?.currentFileURL
            let errors = controller?.errors ?? []
            
            // Dispatch background AI task with configurable "stop to think" pause
            // and a configurable timeout (default 4.0s for local models, fully customizable in Settings)
            let debounceNanos = settings.effectiveCompletionDebounceNanoseconds
            let timeoutSeconds = max(1.0, settings.completionTimeoutSeconds)
            let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)

            debounceTask = Task {
                do {
                    // Stop to think pause: wait configured idle time before sending request
                    try await Task.sleep(nanoseconds: debounceNanos)
                    try Task.checkCancellation()
                    
                    let context = AIContextManager.shared.generateCompletionContext(
                        text: text,
                        cursorIndex: index,
                        scope: settings.completionContextScope
                    )
                    try Task.checkCancellation()
                    
                    // Strict timeout on network request: abort if model is unresponsive
                    let completionCode = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            return try await AICompletionService.shared.fetchCompletion(prompt: context, purpose: .completion)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: timeoutNanos)
                            throw CancellationError()
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                    try Task.checkCancellation()
                    
                    let cleanedCode = Self.cleanedInsertionText(completionCode)
                    if !cleanedCode.isEmpty {
                        let aiItem = AICompletionItem(
                            label: cleanedCode,
                            detail: "AI",
                            documentation: "AI Generated Suggestion"
                        )
                        await MainActor.run {
                            guard let model = SuggestionController.shared.model as SuggestionViewModel? else { return }
                            guard model.activeTextView === textView || SuggestionController.shared.window?.isVisible != true else { return }
                            
                            let currentIndex = cursorIndex(from: textView.cursorPositions.first?.start ?? pos.start, in: textView.text)
                            let currentPrefix = getWordPrefix(text: textView.text, cursorIndex: currentIndex)
                            
                            // Ensure the user hasn't typed something completely different
                            if currentPrefix.hasPrefix(prefix) || prefix.hasPrefix(currentPrefix) {
                                if SuggestionController.shared.window?.isVisible == true {
                                    if !model.items.contains(where: { $0.label == aiItem.label }) {
                                        model.items.append(aiItem)
                                        print("[AICompletionProvider] AI suggestion appended to existing list")
                                    }
                                } else {
                                    // If the suggestion window wasn't open yet (e.g. offline intellisense had no results for this word),
                                    // open it now so the user can see and accept the AI suggestion!
                                    SuggestionController.shared.showCompletions(
                                        items: [aiItem],
                                        textView: textView,
                                        cursorPosition: pos
                                    )
                                    print("[AICompletionProvider] AI suggestion opened new completion window")
                                }
                            }
                        }
                    }
                } catch is CancellationError {
                    // Task cancelled or timed out cleanly
                } catch {
                    print("[AICompletionProvider] Completion error: \(error)")
                }
            }
        }
        
        // Return local offline suggestions immediately so the window pops up with 0ms UI lag
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
        let settings = AISettingsManager.shared
        guard settings.isEnabled || settings.intellisenseEnabled else { return nil }

        let text = textView.text
        let index = cursorIndex(from: cursorPosition.start, in: text)
        let prefix = getWordPrefix(text: text, cursorIndex: index)

        // Cancel previous pending AI query on cursor move
        debounceTask?.cancel()

        if settings.intellisenseEnabled {
            let suggestions = OfflineCompletionService.shared.provideCompletion(
                text: text,
                cursorIndex: index,
                manualTrigger: prefix.isEmpty
            )
            if !suggestions.isEmpty {
                return suggestions.map { suggestion in
                    AICompletionItem(
                        label: suggestion,
                        detail: "Offline",
                        documentation: "Typst Syntax / Suggestion",
                        image: Image(systemName: "text.book.closed")
                    )
                }
            }
        }

        return nil
    }

    @MainActor
    func completionWindowDidClose() {
        // Immediately abort any background AI task when the completion popup is closed
        debounceTask?.cancel()
        debounceTask = nil
    }

    @MainActor
    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        let text = textView.text
        let nsText = text as NSString

        // 1. Authoritative cursor offset in UTF-16: prefer live selection range over line/column math
        let liveSelection = textView.textView.selectedRange()
        let utf16Offset: Int
        if liveSelection.location != NSNotFound && liveSelection.location <= nsText.length {
            utf16Offset = liveSelection.location
        } else if let range = cursorPosition?.range, range.location != NSNotFound && range.location <= nsText.length {
            utf16Offset = range.location
        } else {
            let currentPos = cursorPosition?.start ?? textView.cursorPositions.first?.start ?? .init(line: 1, column: 1)
            utf16Offset = max(0, min(cursorUTF16Offset(from: currentPos, in: text), nsText.length))
        }

        let label = Self.cleanedInsertionText(item.label)

        // Find the typed word prefix at cursor (including any leading '#')
        let typedPrefix = getWordPrefix(text: text, utf16Offset: utf16Offset)
        
        let replaceCount: Int
        if !typedPrefix.isEmpty && label.hasPrefix(typedPrefix) {
            // Perfect prefix match (e.g. typed "#al", picked "#align(" -> replace "#al" with "#align(")
            replaceCount = (typedPrefix as NSString).length
        } else {
            // Suffix overlap match (e.g. for AI completions or partial matches)
            var lineStart = utf16Offset
            while lineStart > 0 {
                let ch = nsText.character(at: lineStart - 1)
                if ch == 0x0A || ch == 0x0D { break }
                lineStart -= 1
            }
            let linePrefix = nsText.substring(with: NSRange(location: lineStart, length: utf16Offset - lineStart))
            replaceCount = Self.overlapLength(label: label, typedPrefix: linePrefix)
        }

        // Strictly clamp the replacement range within current document bounds
        let startLoc = max(0, min(utf16Offset - replaceCount, nsText.length))
        let length = max(0, min(replaceCount, nsText.length - startLoc))
        let replacementRange = NSRange(location: startLoc, length: length)

        // Wrap in an explicit undo group so the suggestion insertion is treated as a clean,
        // atomic undo action instead of conjoining with previous typed keystrokes.
        // Also suppress markdown auto-format and wrap side-effects from the bridge callback
        // during the insertion — re-entrant mutations corrupt the undo stack and crash on undo.
        let undoManager = textView.textView.undoManager
        undoManager?.beginUndoGrouping()
        controller?.isApplyingProgrammaticChange = true
        textView.textView.insertText(label, replacementRange: replacementRange)
        controller?.isApplyingProgrammaticChange = false
        undoManager?.endUndoGrouping()
    }

    /// Finds the longest suffix of `typedPrefix` that prefixes `label`.
    /// Returns how many UTF-16 units before the cursor to replace.
    static func overlapLength(label: String, typedPrefix: String) -> Int {
        let maxK = min(typedPrefix.count, label.count, 2000)
        if maxK > 0 {
            for candidate in stride(from: maxK, through: 1, by: -1) {
                let suffix = typedPrefix.suffix(candidate)
                if suffix == label.prefix(candidate) {
                    // Return the UTF-16 length of the overlap to safely use with NSRange
                    return (String(suffix) as NSString).length
                }
            }
        }
        return 0
    }

    /// Normalizes model output into insertable text.
    /// Handles code fences, thinking tags, <CURSOR> markers, and conversational preambles
    /// that smaller or cheaper local models often generate.
    static func cleanedInsertionText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip reasoning / thinking tags (DeepSeek R1, Qwen reasoning models, etc.)
        for tag in ["think", "thought"] {
            if let start = text.range(of: "<\(tag)>", options: .caseInsensitive) {
                if let end = text.range(of: "</\(tag)>", options: .caseInsensitive) {
                    text.removeSubrange(start.lowerBound..<end.upperBound)
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // Output was cut off while still in thinking phase
                    return ""
                }
            }
        }

        // 2. Unwrap markdown code blocks (```typst ... ```)
        if text.hasPrefix("```") {
            let withoutOpeningFence = text.dropFirst(3)
            if let firstNewline = withoutOpeningFence.firstIndex(of: "\n") {
                let body = withoutOpeningFence[withoutOpeningFence.index(after: firstNewline)...]
                if let closingFence = body.range(of: "```", options: .backwards) {
                    text = String(body[..<closingFence.lowerBound])
                } else {
                    text = String(body)
                }
            } else {
                let content = withoutOpeningFence.trimmingCharacters(in: .whitespacesAndNewlines)
                if let closing = content.range(of: "```") {
                    text = String(content[..<closing.lowerBound])
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Robust <CURSOR> marker handling:
        // Cheap models may echo "<CURSOR>new_code", "prefix<CURSOR>new_code",
        // or "<CURSOR>new_code<CURSOR>".
        // Never trim before <CURSOR> if that would erase the generated completion!
        let markers = ["<CURSOR>", "<cursor>", "<|cursor|>", "[CURSOR]"]
        for marker in markers {
            if let firstRange = text.range(of: marker) {
                let afterMarker = text[firstRange.upperBound...]
                if let secondRange = afterMarker.range(of: marker) {
                    // Content between two markers: <CURSOR>code<CURSOR>
                    text = String(afterMarker[..<secondRange.lowerBound])
                } else if !afterMarker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Content was emitted after the marker: <CURSOR>code or prefix<CURSOR>code
                    text = String(afterMarker)
                } else {
                    // Marker was at the end: code<CURSOR>
                    text = String(text[..<firstRange.lowerBound])
                }
                break
            }
        }

        // 4. Strip common conversational preambles from small models
        let lines = text.components(separatedBy: .newlines)
        var filteredLines: [String] = []
        var skippingPreamble = true
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if skippingPreamble {
                let lower = trimmed.lowercased()
                if lower.hasPrefix("here is") ||
                   lower.hasPrefix("here's") ||
                   lower.hasPrefix("sure") ||
                   lower.hasPrefix("certainly") ||
                   lower.hasPrefix("completion:") ||
                   lower.hasPrefix("output:") ||
                   lower.hasPrefix("result:") ||
                   lower.hasPrefix("typst:") {
                    continue
                }
                skippingPreamble = false
            }
            filteredLines.append(line)
        }
        text = filteredLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return text
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
