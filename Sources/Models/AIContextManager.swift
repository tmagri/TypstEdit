import Foundation

enum ContextRegex {
    static let label = try! NSRegularExpression(pattern: "<[a-zA-Z0-9_-]+>")
}

@MainActor
class AIContextManager {
    static let shared = AIContextManager()
    private init() {}
    
    // Change to async and require the user's prompt to perform the search
    func generateContext(userPrompt: String, text: String, cursorIndex: Int, fileURL: URL?, errors: [TypstError] = []) async -> String {
        let settings = AISettingsManager.shared
        
        let safeIndex = min(max(0, cursorIndex), text.count)
        let prefixIndex = text.index(text.startIndex, offsetBy: safeIndex)
        let prefix = String(text[..<prefixIndex])
        let suffix = String(text[prefixIndex...])
        
        var context = """
        You are an intelligent coding and writing assistant for Typst.
        ... (keep your existing guidelines here) ...
        
        """
        
        // Error Feedback and Document Symbols (Keep your existing logic here)
        // ...
        
        context += """
        Current File: \(fileURL?.lastPathComponent ?? "Untitled.typ")
        Language: Typst
        
        CODE CONTEXT:
        \(prefix)<CURSOR>\(suffix)
        """
        
        if settings.includeProjectContext {
            // Pass the current fileURL to be excluded from the semantic search
            let relevantChunks = await RAGManager.shared.search(query: userPrompt, topK: 3, excluding: fileURL)
            
            if !relevantChunks.isEmpty {
                context += "\n\nRELEVANT PROJECT CONTEXT (from semantic search):\n"
                for chunk in relevantChunks {
                    context += "--- File: \(chunk.fileURL.lastPathComponent) ---\n"
                    context += "\(chunk.text)\n\n"
                }
            }
        }
        return context
    }
    
    /// Generates a fast, scoped prompt specifically for inline autocomplete.
    /// Does not perform workspace semantic searches (RAG) to ensure sub-millisecond prep.
    func generateCompletionContext(
        text: String,
        cursorIndex: Int,
        scope: AISettingsManager.CompletionContextScope
    ) -> String {
        let safeIndex = min(max(0, cursorIndex), text.count)
        let cursorIdx = text.index(text.startIndex, offsetBy: safeIndex)
        
        let prefix: String
        let suffix: String
        
        switch scope {
        case .currentLine:
            // Find start of current line
            var lineStart = cursorIdx
            while lineStart > text.startIndex {
                let prev = text.index(before: lineStart)
                if text[prev] == "\n" || text[prev] == "\r" {
                    break
                }
                lineStart = prev
            }
            // Find end of current line
            var lineEnd = cursorIdx
            while lineEnd < text.endIndex {
                if text[lineEnd] == "\n" || text[lineEnd] == "\r" {
                    break
                }
                lineEnd = text.index(after: lineEnd)
            }
            
            var linePrefix = String(text[lineStart..<cursorIdx])
            var lineSuffix = String(text[cursorIdx..<lineEnd])
            
            // If the line is an unusually long paragraph, focus on the sentence / last ~300 chars
            if linePrefix.count > 300 {
                linePrefix = String(linePrefix.suffix(300))
            }
            if lineSuffix.count > 150 {
                lineSuffix = String(lineSuffix.prefix(150))
            }
            
            prefix = linePrefix
            suffix = lineSuffix
            
        case .surroundingLines:
            // Window of up to 5 lines before
            var windowStart = cursorIdx
            var linesBefore = 0
            while windowStart > text.startIndex && linesBefore < 5 {
                let prev = text.index(before: windowStart)
                if text[prev] == "\n" {
                    linesBefore += 1
                }
                windowStart = prev
            }
            if linesBefore == 5 && windowStart < cursorIdx && text[windowStart] == "\n" {
                windowStart = text.index(after: windowStart)
            }
            
            // Window of up to 5 lines after
            var windowEnd = cursorIdx
            var linesAfter = 0
            while windowEnd < text.endIndex && linesAfter < 5 {
                if text[windowEnd] == "\n" {
                    linesAfter += 1
                }
                windowEnd = text.index(after: windowEnd)
            }
            
            prefix = String(text[windowStart..<cursorIdx])
            suffix = String(text[cursorIdx..<windowEnd])
            
        case .fullDocument:
            prefix = String(text[..<cursorIdx])
            suffix = String(text[cursorIdx...])
        }
        
        if suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return """
            Continue the following Typst code immediately after the text. Output ONLY the continuation characters or words to insert at the end. Do not repeat the prefix, do not include markdown fences, and do not provide explanations:
            \(prefix)
            """
        } else {
            return """
            Complete the Typst code between Prefix and Suffix. Output ONLY the code to insert between them without repeating prefix or suffix:
            Prefix: \(prefix)
            Suffix: \(suffix)
            """
        }
    }
    
    /// Scans for headings and labels in the text
    private func scanSymbols(in text: String) -> [String] {
        var symbols: [String] = []
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Headings: = Heading, == Subheading
            if trimmed.hasPrefix("=") {
                symbols.append("Heading: \(trimmed)")
            }
            // Labels: <mylabel>
            if let match = ContextRegex.label.firstMatch(in: trimmed, options: [], range: NSRange(0..<trimmed.utf16.count)),
               let labelRange = Range(match.range, in: trimmed) {
                symbols.append("Label: \(trimmed[labelRange])")
            }
            // Variables/Functions: #let x = ...
            if trimmed.hasPrefix("#let ") {
                symbols.append("Definition: \(trimmed)")
            }
        }
        return symbols
    }
    
    /// Gathers small snippets from sibling files
    private func gatherProjectSnippets(around currentURL: URL, projectDir: URL) -> String {
        var result = ""
        guard let files = try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return ""
        }
        
        let candidates = files.filter { $0.pathExtension == "typ" && $0 != currentURL }.prefix(3)
        for file in candidates {
            if let data = try? Data(contentsOf: file) {
                let content = TextFileEncoding.decode(data).text
                let snippet = String(content.prefix(300)) // First 300 chars
                result += "--- File: \(file.lastPathComponent) ---\n"
                result += snippet + (content.count > 300 ? "..." : "") + "\n\n"
            }
        }
        return result
    }
}
