import SwiftUI
import Combine

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case gemini = "Google Gemini"
    case custom = "Custom (Ollama/LMStudio)"
    
    var id: String { self.rawValue }
}

@MainActor
class AISettingsManager: ObservableObject {
    static let shared = AISettingsManager()
    
    @AppStorage("aiEnabled") var isEnabled: Bool = false
    @AppStorage("intellisenseEnabled") var intellisenseEnabled: Bool = true
    @AppStorage("aiProvider") var providerString: String = AIProvider.openAI.rawValue
    
    var provider: AIProvider {
        get {
            AIProvider(rawValue: providerString) ?? .openAI
        }
        set {
            providerString = newValue.rawValue
        }
    }
    
    @AppStorage("openAIApiKey") var openAIApiKey: String = ""
    @AppStorage("openRouterApiKey") var openRouterApiKey: String = ""
    @AppStorage("geminiApiKey") var geminiApiKey: String = ""
    @AppStorage("customApiKey") var customApiKey: String = ""
    @AppStorage("customEndpoint") var customEndpoint: String = "http://localhost:11434/v1/chat/completions"
    @AppStorage("customEmbeddingEndpoint") var customEmbeddingEndpoint: String = "http://localhost:11434/v1/embeddings"
    @AppStorage("customEmbeddingModel") var customEmbeddingModel: String = "nomic-embed-text"
    @AppStorage("openAIEmbeddingModel") var openAIEmbeddingModel: String = "text-embedding-3-small"
    @AppStorage("aiModel") var model: String = "gpt-4o"
    @AppStorage("aiCompletionModel") var completionModel: String = ""
    @AppStorage("aiForceCodeOutput") var forceCodeOutput: Bool = false
    @AppStorage("aiMaxContextWindow") var maxContextWindow: Int = 4096
    @AppStorage("aiIncludeProjectContext") var includeProjectContext: Bool = true
    @AppStorage("aiMaxTokens") var maxTokens: Int = 2048
    @AppStorage("aiCacheEmbeddingsToDisk") var cacheEmbeddingsToDisk: Bool = true
    @AppStorage("aiTimeoutSeconds") var timeoutSeconds: Double = 120.0
    var apiKey: String {
        switch provider {
        case .openAI: return openAIApiKey
        case .openRouter: return openRouterApiKey
        case .gemini: return geminiApiKey
        case .custom: return customApiKey
        }
    }
    
    /// Returns the completion model if set, otherwise falls back to the chat model.
    /// This lets users pick a cheaper/faster model for inline autocomplete while
    /// keeping a more capable model for chat-based features (AI Prompt, Refine, etc.).
    var effectiveCompletionModel: String {
        let trimmed = completionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model : trimmed
    }
}
