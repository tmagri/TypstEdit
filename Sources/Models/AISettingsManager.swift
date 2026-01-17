import SwiftUI
import Combine

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case gemini = "Google Gemini"
    case offline = "Offline / Manual"
    case custom = "Custom (Ollama/LMStudio)"
    
    var id: String { self.rawValue }
}

@MainActor
class AISettingsManager: ObservableObject {
    static let shared = AISettingsManager()
    
    @AppStorage("aiEnabled") var isEnabled: Bool = false
    @AppStorage("aiProvider") var provider: AIProvider = .openAI
    @AppStorage("openAIApiKey") var openAIApiKey: String = ""
    @AppStorage("openRouterApiKey") var openRouterApiKey: String = ""
    @AppStorage("geminiApiKey") var geminiApiKey: String = ""
    @AppStorage("customApiKey") var customApiKey: String = ""
    @AppStorage("customEndpoint") var customEndpoint: String = "http://localhost:11434/v1/chat/completions"
    @AppStorage("aiModel") var model: String = "gpt-4o"
    
    // Additional settings for context awareness
    @AppStorage("aiMaxContextWindow") var maxContextWindow: Int = 4096
    @AppStorage("aiIncludeProjectContext") var includeProjectContext: Bool = true
    
    var apiKey: String {
        switch provider {
        case .openAI: return openAIApiKey
        case .openRouter: return openRouterApiKey
        case .gemini: return geminiApiKey
        case .offline: return ""
        case .custom: return customApiKey
        }
    }
}
