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
    
    func fetchCompletion(prompt: String) async throws -> String {
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
        case .offline: throw AIError.apiError("Offline mode selected")
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
                            ["text": "You are a precise code completion engine. Output only the code to insert at the cursor. \n\n" + prompt]
                        ]
                    ]
                ],
                "generationConfig": [
                    "maxOutputTokens": 64,
                    "temperature": 0.2
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } 
        // OpenAI / Standard Format
        else {
            let messages: [[String: String]] = [
                ["role": "system", "content": "You are a precise code completion engine. Output only the code to insert at the cursor."],
                ["role": "user", "content": prompt]
            ]
            
            let body: [String: Any] = [
                "model": settings.model,
                "messages": messages,
                "max_tokens": 64, // Short completion
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
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw AIError.apiError("Status \(httpResponse.statusCode): \(errorMsg)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parsingError
        }
        
        // Parse Gemini Response
        if isGemini {
            if let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let contentObj = firstCandidate["content"] as? [String: Any],
               let parts = contentObj["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw AIError.parsingError
        }
        
        // Parse OpenAI Response
        if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        throw AIError.parsingError
    }
    
    /// Verifies the connection to the AI provider by sending a minimal prompt.
    func testConnection() async throws -> String {
        return try await fetchCompletion(prompt: "Hello. Respond with exactly the word 'OK'.")
    }
}
