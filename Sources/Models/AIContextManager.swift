import Foundation

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
            if let labelRange = trimmed.range(of: "<[a-zA-Z0-9_-]+>", options: .regularExpression) {
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
