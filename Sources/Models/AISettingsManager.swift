import SwiftUI
import Combine

// MARK: - Model Source

/// Represents where a model runs — either a cloud provider or a local server.
enum ModelSource: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case anthropic = "Anthropic"
    case gemini = "Google Gemini"
    case local = "Local (Ollama/LMStudio)"

    var id: String { self.rawValue }

    var isLocal: Bool { self == .local }
}

// MARK: - Model Task

/// The distinct AI tasks that can each be assigned a different model source.
enum ModelTask: String, CaseIterable, Identifiable {
    case generation = "Generation"
    case completion = "Completion"
    case embedding = "Embedding"

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .generation: return "AI Generation / Chat"
        case .completion: return "Autocomplete"
        case .embedding: return "Embeddings (RAG)"
        }
    }

    var description: String {
        switch self {
        case .generation: return "Used for AI Prompt, Refine, and chat-based features."
        case .completion: return "Used for inline autocomplete suggestions."
        case .embedding: return "Used for semantic project search (RAG)."
        }
    }
}

// MARK: - Model Context

/// A fully-resolved configuration for a specific model task.
/// Combines the source, model name, endpoint, and API key into a single
/// value that services can consume without knowing about settings internals.
struct ModelContext {
    let task: ModelTask
    let source: ModelSource
    let model: String
    let endpoint: String
    let apiKey: String

    var isGemini: Bool { source == .gemini }
    var isAnthropic: Bool { source == .anthropic }
    var isLocal: Bool { source.isLocal }

    /// The chat completions endpoint for this context.
    var chatEndpoint: String {
        switch source {
        case .openAI: return "https://api.openai.com/v1/chat/completions"
        case .openRouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        case .local: return endpoint
        }
    }

    /// The embeddings endpoint for this context (only relevant for .embedding task).
    var embeddingEndpoint: String {
        switch source {
        case .openAI: return "https://api.openai.com/v1/embeddings"
        case .local: return endpoint
        default: return endpoint
        }
    }
}

// MARK: - Backward-compatible typealias
typealias AIProvider = ModelSource

// MARK: - Settings Manager

@MainActor
class AISettingsManager: ObservableObject {
    static let shared = AISettingsManager()

    @AppStorage("aiEnabled") var isEnabled: Bool = false
    @AppStorage("intellisenseEnabled") var intellisenseEnabled: Bool = true

    // MARK: - Per-Task Source Assignment

    @AppStorage("generationSource") private var generationSourceString: String = ModelSource.openAI.rawValue
    @AppStorage("completionSource") private var completionSourceString: String = ModelSource.local.rawValue
    @AppStorage("embeddingSource") private var embeddingSourceString: String = ModelSource.local.rawValue

    /// Legacy key for backward compatibility — migrated into generationSource on first access.
    @AppStorage("aiProvider") private var legacyProviderString: String = ""

    // MARK: - Per-Task Model Names

    @AppStorage("aiModel") var generationModel: String = "gpt-4o"
    @AppStorage("aiCompletionModel") var completionModel: String = ""
    @AppStorage("customEmbeddingModel") var embeddingModel: String = "nomic-embed-text"
    @AppStorage("openAIEmbeddingModel") var openAIEmbeddingModel: String = "text-embedding-3-small"

    // MARK: - Per-Task Endpoints (for local sources)

    @AppStorage("customEndpoint") var generationEndpoint: String = "http://localhost:11434/v1/chat/completions"
    @AppStorage("completionEndpoint") var completionEndpoint: String = "http://localhost:11434/v1/chat/completions"
    @AppStorage("customEmbeddingEndpoint") var embeddingEndpoint: String = "http://localhost:11434/v1/embeddings"

    // MARK: - Shared API Keys (per cloud source)

    @AppStorage("openAIApiKey") var openAIApiKey: String = ""
    @AppStorage("openRouterApiKey") var openRouterApiKey: String = ""
    @AppStorage("anthropicApiKey") var anthropicApiKey: String = ""
    @AppStorage("geminiApiKey") var geminiApiKey: String = ""
    @AppStorage("customApiKey") var customApiKey: String = ""

    // MARK: - General AI Settings

    @AppStorage("aiForceCodeOutput") var forceCodeOutput: Bool = false
    @AppStorage("aiMaxContextWindow") var maxContextWindow: Int = 4096
    @AppStorage("aiIncludeProjectContext") var includeProjectContext: Bool = true
    @AppStorage("aiMaxTokens") var maxTokens: Int = 2048
    @AppStorage("aiCacheEmbeddingsToDisk") var cacheEmbeddingsToDisk: Bool = true
    @AppStorage("aiTimeoutSeconds") var timeoutSeconds: Double = 120.0

    // MARK: - Source Accessors

    func source(for task: ModelTask) -> ModelSource {
        let raw: String
        switch task {
        case .generation:
            // Migrate legacy "aiProvider" key on first access
            if !legacyProviderString.isEmpty, generationSourceString == ModelSource.openAI.rawValue {
                let migrated: ModelSource
                switch legacyProviderString {
                case "Custom (Ollama/LMStudio)": migrated = .local
                default: migrated = ModelSource(rawValue: legacyProviderString) ?? .openAI
                }
                generationSourceString = migrated.rawValue
                legacyProviderString = ""
                return migrated
            }
            raw = generationSourceString
        case .completion: raw = completionSourceString
        case .embedding: raw = embeddingSourceString
        }
        return ModelSource(rawValue: raw) ?? .openAI
    }

    func setSource(_ source: ModelSource, for task: ModelTask) {
        switch task {
        case .generation: generationSourceString = source.rawValue
        case .completion: completionSourceString = source.rawValue
        case .embedding: embeddingSourceString = source.rawValue
        }
    }

    // MARK: - Backward-compatible provider property (maps to generation source)

    var provider: ModelSource {
        get { source(for: .generation) }
        set { setSource(newValue, for: .generation) }
    }

    /// Backward-compatible alias: the generation model.
    var model: String {
        get { generationModel }
        set { generationModel = newValue }
    }

    // MARK: - API Key Resolution

    func apiKey(for source: ModelSource) -> String {
        switch source {
        case .openAI: return openAIApiKey
        case .openRouter: return openRouterApiKey
        case .anthropic: return anthropicApiKey
        case .gemini: return geminiApiKey
        case .local: return customApiKey
        }
    }

    /// Backward-compatible: returns the API key for the generation source.
    var apiKey: String {
        apiKey(for: source(for: .generation))
    }

    // MARK: - Model Context Resolution

    /// Resolves the full ModelContext for a given task.
    func modelContext(for task: ModelTask) -> ModelContext {
        let src = source(for: task)

        let modelName: String
        let endpoint: String

        switch task {
        case .generation:
            modelName = generationModel
            endpoint = generationEndpoint

        case .completion:
            let trimmed = completionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Fall back to generation context entirely
                return modelContext(for: .generation)
            }
            modelName = trimmed
            endpoint = completionEndpoint

        case .embedding:
            switch src {
            case .openAI:
                modelName = openAIEmbeddingModel
            default:
                modelName = embeddingModel
            }
            endpoint = embeddingEndpoint
        }

        return ModelContext(
            task: task,
            source: src,
            model: modelName,
            endpoint: endpoint,
            apiKey: apiKey(for: src)
        )
    }

    /// Returns the completion model if set, otherwise falls back to the chat model.
    /// This lets users pick a cheaper/faster model for inline autocomplete while
    /// keeping a more capable model for chat-based features (AI Prompt, Refine, etc.).
    var effectiveCompletionModel: String {
        let trimmed = completionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? generationModel : trimmed
    }

    /// The effective embedding model name based on the embedding source.
    var effectiveEmbeddingModel: String {
        let src = source(for: .embedding)
        switch src {
        case .openAI: return openAIEmbeddingModel
        default: return embeddingModel
        }
    }
}
