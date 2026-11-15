import Foundation

enum ContextRegex {
    static let label = try! NSRegularExpression(pattern: "<[a-zA-Z0-9_-]+>")
}

@MainActor
class AIContextManager {
    static let shared = AIContextManager()
    private init() {}
    
    // Change to async and require the user's prompt to perform the search
    func generateContext(userPrompt: String, text: String, cursorIndex: Int, fileURL: URL?, errors: [TypstError] = [], rag: RAGManager?) async -> String {
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
            let query = Self.retrievalQuery(prompt: userPrompt, textBeforeCursor: prefix)
            let relevantChunks = await rag?.search(query: query, topK: 3, excluding: fileURL) ?? []
            
            if !relevantChunks.isEmpty {
                context += "\n\nRELEVANT PROJECT CONTEXT (from semantic search):\n"
                for chunk in relevantChunks {
                    let section = chunk.heading.isEmpty ? "" : " · \(chunk.heading)"
                    context += "--- File: \(chunk.location)\(section) ---\n"
                    context += "\(chunk.text)\n\n"
                }
            }
        }
        return context
    }
    
    /// The semantic-search query for an AI Prompt request. Prompts such as
    /// "continue this" or "add a citation here" say little on their own, so
    /// the text just before the cursor is added: it is what the request is
    /// about.
    nonisolated static func retrievalQuery(prompt: String, textBeforeCursor: String, contextChars: Int = 600) -> String {
        let nearby = textBeforeCursor.suffix(contextChars).trimmingCharacters(in: .whitespacesAndNewlines)
        return nearby.isEmpty ? prompt : "\(prompt)\n\n\(nearby)"
    }

    /// Generates a fast, scoped prompt specifically for inline autocomplete.
    /// Does not perform workspace semantic searches (RAG) to ensure sub-millisecond prep.
    ///
    /// Works entirely in UTF-16 offsets (`NSRange`'s unit) and copies only the
    /// window it returns. The previous version resolved `cursorIndex` with
    /// `text.index(_:offsetBy:)`, which walks every grapheme cluster from the
    /// start of the document — ~50 ms at the end of a 1.6 MB file, on a path
    /// that runs as the user types. Cost here is now proportional to the
    /// handful of lines actually being quoted. The window boundaries match the
    /// Character-based version exactly, so the prompts the model receives are
    /// unchanged (`AIContextWindowTests` cross-checks them offset by offset).
    func generateCompletionContext(
        text: String,
        cursorIndex: Int,
        scope: AISettingsManager.CompletionContextScope
    ) -> String {
        let (prefix, suffix) = completionWindow(text: text, cursorIndex: cursorIndex, scope: scope)

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

    /// The prefix/suffix pair the completion prompt is built from.
    ///
    /// Split out from ``generateCompletionContext(text:cursorIndex:scope:)`` so
    /// the windowing can be compared against a Character-based reference
    /// implementation without parsing it back out of a prompt string. See
    /// `AIContextWindowTests`.
    ///
    /// Works entirely in UTF-16 offsets (`NSRange`'s unit) and copies only the
    /// window it returns. Resolving `cursorIndex` with `text.index(_:offsetBy:)`
    /// walks every grapheme cluster from the start of the document — ~50 ms at
    /// the end of a 1.6 MB file, on a path that runs as the user types. Cost
    /// here is proportional to the handful of lines actually quoted.
    func completionWindow(
        text: String,
        cursorIndex: Int,
        scope: AISettingsManager.CompletionContextScope
    ) -> (prefix: String, suffix: String) {
        let nsText = text as NSString
        let length = nsText.length
        let offset = min(max(0, cursorIndex), length)

        let prefix: String
        let suffix: String

        switch scope {
        case .currentLine:
            // `getLineStart(_:end:contentsEnd:for:)` gives the content end
            // (excluding the newline) in one pass, so the suffix never quotes a
            // line terminator.
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: offset, length: 0)
            )
            let contentEnd = max(offset, contentsEnd)

            var linePrefix = nsText.substring(with: NSRange(location: lineStart, length: offset - lineStart))
            var lineSuffix = nsText.substring(with: NSRange(location: offset, length: contentEnd - offset))

            // If the line is an unusually long paragraph, focus on the sentence / last ~300 chars.
            // The cut is in UTF-16 units but snapped outward to a whole character, so an
            // emoji or combining sequence straddling the boundary is kept intact instead
            // of being split into a lone surrogate.
            if linePrefix.utf16.count > 300 {
                let ns = linePrefix as NSString
                let cut = ns.rangeOfComposedCharacterSequence(at: ns.length - 300).location
                linePrefix = ns.substring(from: cut)
            }
            if lineSuffix.utf16.count > 150 {
                let ns = lineSuffix as NSString
                let cut = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: 149))
                lineSuffix = ns.substring(to: cut)
            }

            prefix = linePrefix
            suffix = lineSuffix

        case .surroundingLines:
            // Count five newlines backwards and forwards, exactly as the
            // Character-based version did — blank lines are newline runs, so
            // stepping by line boundaries would quote a different window.
            // Scanning code units keeps this cheap; it only ever crosses the
            // five lines being quoted.
            var windowStart = offset
            var linesBefore = 0
            while windowStart > 0 && linesBefore < 5 {
                windowStart -= 1
                if nsText.character(at: windowStart) == 0x0A { linesBefore += 1 }
            }
            if linesBefore == 5, windowStart < offset, nsText.character(at: windowStart) == 0x0A {
                windowStart += 1
            }

            var windowEnd = offset
            var linesAfter = 0
            while windowEnd < length && linesAfter < 5 {
                if nsText.character(at: windowEnd) == 0x0A { linesAfter += 1 }
                windowEnd += 1
            }

            prefix = nsText.substring(with: NSRange(location: windowStart, length: offset - windowStart))
            suffix = nsText.substring(with: NSRange(location: offset, length: windowEnd - offset))

        case .fullDocument:
            prefix = nsText.substring(to: offset)
            suffix = nsText.substring(from: offset)
        }

        return (prefix, suffix)
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
