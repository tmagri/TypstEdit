import Foundation

enum AIError: LocalizedError {
    case invalidURL
    case noData
    case parsingError
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .noData: return "No data received from provider"
        case .parsingError: return "Failed to parse AI response"
        case .apiError(let msg): return msg
        }
    }
}

@MainActor
class AICompletionService: ObservableObject {
    static let shared = AICompletionService()
    
    @Published var isFetching: Bool = false
    
    private init() {}
    
    func fetchCompletion(prompt: String, systemPrompt: String = "You are a precise code completion engine. Output only the code to insert at the cursor.", maxTokens: Int = 128) async throws -> String {
        isFetching = true
        defer { isFetching = false }
        
        let settings = AISettingsManager.shared
        
        // Only require API key for non-custom providers, or if custom provider is not localhost
        if settings.provider != .custom && settings.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(settings.provider.rawValue)")
        }
        
        let endpoint: String
        let isGemini = settings.provider == .gemini
        
        switch settings.provider {
        case .openAI: endpoint = "https://api.openai.com/v1/chat/completions"
        case .openRouter: endpoint = "https://openrouter.ai/api/v1/chat/completions"
        case .gemini: endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(settings.model):generateContent?key=\(settings.apiKey)"
        case .custom: endpoint = settings.customEndpoint
        }
        
        guard let url = URL(string: endpoint) else {
            throw AIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // Gemini API key is in URL query parameter, not header
        if !isGemini {
            request.addValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // OpenRouter specific headers
        if settings.provider == .openRouter {
            request.addValue("TypstEdit", forHTTPHeaderField: "HTTP-Referer")
            request.addValue("TypstEdit", forHTTPHeaderField: "X-Title")
        }
        
        // Gemini Body Format
        if isGemini {
            let body: [String: Any] = [
                "contents": [
                    [
                        "parts": [
                            ["text": systemPrompt + "\n\n" + prompt]
                        ]
                    ]
                ],
                "generationConfig": [
                    "maxOutputTokens": maxTokens,
                    "temperature": 0.2
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } 
        // OpenAI / Standard Format
        else {
            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ]
            
            let body: [String: Any] = [
                "model": settings.model,
                "messages": messages,
                "max_tokens": maxTokens,
                "temperature": 0.2, // Deterministic
                "stream": false
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.noData
        }
        
        guard httpResponse.statusCode == 200 else {
            var parsedErrorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            
            // Attempt to extract a clean, human-readable error message from the JSON payload
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Standard OpenAI / OpenRouter format
                if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                    parsedErrorMsg = msg
                } 
                // Gemini format (sometimes wraps errors in an array or different structure)
                else if let errorArray = json["error"] as? [[String: Any]], let first = errorArray.first, let msg = first["message"] as? String {
                    parsedErrorMsg = msg
                }
            }
            
            throw AIError.apiError("API Error (\(httpResponse.statusCode)): \(parsedErrorMsg)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parsingError
        }
        
        let rawResult: String
        // Parse Gemini Response
        if isGemini {
            if let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let contentObj = firstCandidate["content"] as? [String: Any],
               let parts = contentObj["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                rawResult = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                throw AIError.parsingError
            }
        } 
        // Parse OpenAI Response
        else if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            rawResult = content.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw AIError.parsingError
        }
        
       var finalResult = rawResult
        if settings.forceCodeOutput {
            finalResult = extractCode(from: rawResult)
        }
        
        // Pass the result through our Markdown-to-Typst safety net
        return sanitizeMarkdownToTypst(finalResult)
    }
    
    private func extractCode(from text: String) -> String {
        // Look for content between ``` and ```
        let pattern = "```(?:[a-zA-Z]*\\n)?([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return text
    }
    
    /// Verifies the connection to the AI provider by sending a minimal prompt.
    func testConnection() async throws -> String {
        return try await fetchCompletion(prompt: "Hello. Respond with exactly the word 'OK'.")
    }

    private func sanitizeMarkdownToTypst(_ text: String) -> String {
        var processed = text
        
        do {
            // 1. Headings: "# Heading" -> "= Heading"
            let h3 = try NSRegularExpression(pattern: "(?m)^###\\s+(.*)$")
            processed = h3.stringByReplacingMatches(in: processed, range: NSRange(0..<processed.utf16.count), withTemplate: "=== $1")
            
            let h2 = try NSRegularExpression(pattern: "(?m)^##\\s+(.*)$")
            processed = h2.stringByReplacingMatches(in: processed, range: NSRange(0..<processed.utf16.count), withTemplate: "== $1")
            
            let h1 = try NSRegularExpression(pattern: "(?m)^#\\s+(.*)$")
            processed = h1.stringByReplacingMatches(in: processed, range: NSRange(0..<processed.utf16.count), withTemplate: "= $1")
            
            // 2. Bold: **text** -> *text*
            let bold = try NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
            processed = bold.stringByReplacingMatches(in: processed, range: NSRange(0..<processed.utf16.count), withTemplate: "*$1*")
            
            // 3. Links: [text](url) -> #link("url")[text]
            let link = try NSRegularExpression(pattern: "(?<!\\!)\\[([^\\]]+)\\]\\(([^\\)]+)\\)")
            processed = link.stringByReplacingMatches(in: processed, range: NSRange(0..<processed.utf16.count), withTemplate: "#link(\"$2\")[$1]")
            
            // 4. Images: ![alt](url) -> #image("url", alt: "alt")
            let img = try NSRegularExpression(pattern: "\\!\\[([^\\]]*)\\]\\(([^\\)]+)\\)")
            processed = img.stringByReplacingMatches(in: processed, range: NSRange(0..<processed.utf16.count), withTemplate: "#image(\"$2\", alt: \"$1\")")
            
            // 5. Equations: Convert LaTeX math to Typst math using our internal Lyx converter
            // (?s) allows the dot (.) to match newlines for multiline math blocks
            let mathPatterns = [
                "(?s)\\$\\$(.+?)\\$\\$",              // $$...$$
                "(?<!\\\\)\\$([^\\$]+?)(?<!\\\\)\\$", // $...$
                "(?s)\\\\\\[(.+?)\\\\\\]",            // \[...\]
                "(?s)\\\\\\((.+?)\\\\\\)"             // \(...\)
            ]
            
            for pattern in mathPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let matches = regex.matches(in: processed, range: NSRange(0..<processed.utf16.count))
                    
                    // Iterate in reverse so modifying the string doesn't mess up the ranges of upcoming matches
                    for match in matches.reversed() {
                        if let contentRange = Range(match.range(at: 1), in: processed),
                           let fullRange = Range(match.range, in: processed) {
                            
                            let latexMath = String(processed[contentRange])
                            let typstMath = LyxToTypstConverter.convertLatexMathToTypst(latexMath)
                            
                            // Wrap the clean Typst math in the standard Typst $ $ delimiters
                            processed.replaceSubrange(fullRange, with: "$ \(typstMath) $")
                        }
                    }
                }
            }
            
        } catch {
            print("Regex error in sanitization: \(error)")
        }
        
        return processed
    }
}
