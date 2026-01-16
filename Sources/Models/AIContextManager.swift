import Foundation

@MainActor
class AIContextManager {
    static let shared = AIContextManager()
    
    private init() {}
    
    /// Generates a prompt context based on the current file state and cursor position.
    /// - Parameters:
    ///   - text: The entire content of the current file.
    ///   - cursor: The current cursor position (1-indexed line, column).
    ///   - fileURL: The URL of the current file.
    ///   - otherFiles: Optional list of other relevant file URLs in the project.
    /// - Returns: A formatted string containing the system instructions and context.
    /// Generates a prompt context based on the current file state, cursor position, and project context.
    func generateContext(text: String, cursorIndex: Int, fileURL: URL?, errors: [TypstError] = []) -> String {
        let settings = AISettingsManager.shared
        
        let safeIndex = min(max(0, cursorIndex), text.count)
        let prefixIndex = text.index(text.startIndex, offsetBy: safeIndex)
        let prefix = String(text[..<prefixIndex])
        let suffix = String(text[prefixIndex...])
        
        // 1. System Instructions & Guidelines
        var context = """
        You are an intelligent coding and writing assistant for Typst.
        Your task is to provide seamless completion for both code and natural language text.
        
        TYPST GUIDELINES:
        - Math mode uses '$' delimiters: '$ x^2 $'.
        - Functions start with '#': '#set text(...)', '#let myfunc(...)'.
        - Content blocks use '[]', code blocks use '{}'.
        - Labels are defined with '<label>' and referenced with '@label'.
        - For natural language, maintain the tone and style of the existing text.
        - Correct obvious grammar or spelling errors in the suggested completion.
        
        CRITICAL INSTRUCTIONS:
        1. Return ONLY the text/code to be inserted at the cursor position.
        2. Do NOT wrap the code in markdown code blocks (no ```).
        3. Do NOT provide explanations, comments, or conversational text.
        4. If completing a word, only provide the suffix.
        5. If defining a function or block, complete the structure.
        
        """
        
        // 2. Error Feedback
        if !errors.isEmpty {
            context += "CURRENT COMPILATION ERRORS (Fix these if possible):\n"
            for error in errors.prefix(3) {
                context += "- Line \(error.line): \(error.message)\n"
            }
            context += "\n"
        }
        
        // 3. Document Symbols (Headings/Labels)
        let symbols = scanSymbols(in: text)
        if !symbols.isEmpty {
            context += "DOCUMENT SYMBOLS (Headings/Labels):\n"
            for sym in symbols.prefix(10) {
                context += "- \(sym)\n"
            }
            context += "\n"
        }
        
        context += """
        Current File: \(fileURL?.lastPathComponent ?? "Untitled.typ")
        Language: Typst
        
        CODE CONTEXT:
        \(prefix)<CURSOR>\(suffix)
        """
        
        // 4. MCP-style Project Context (Snippets)
        if settings.includeProjectContext, let currentURL = fileURL {
            let projectDir = currentURL.deletingLastPathComponent()
            let snippets = gatherProjectSnippets(around: currentURL, projectDir: projectDir)
            if !snippets.isEmpty {
                context += "\n\nRELATED PROJECT SNIPPETS:\n"
                context += snippets
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
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                let snippet = String(content.prefix(300)) // First 300 chars
                result += "--- File: \(file.lastPathComponent) ---\n"
                result += snippet + (content.count > 300 ? "..." : "") + "\n\n"
            }
        }
        return result
    }
}
