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

// MARK: - Reasoning Effort

/// How much "thinking" a reasoning-capable model should spend on a request.
///
/// Mapped to each provider's native control when the request is built:
/// - OpenAI / OpenRouter / local OpenAI-compatible: `reasoning_effort`
///   (`none`/`low`/`medium`/`high`/`xhigh`; `.auto` omits the parameter)
/// - Anthropic: a `thinking` budget derived from the effort level
/// - Google Gemini: `thinkingLevel` / `thinkingBudget` in `generationConfig`
///
/// `.auto` means "don't send anything" — the model or provider decides.
enum ReasoningEffort: String, CaseIterable, Identifiable {
    case auto
    case none
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (model default)"
        case .none: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Let the model or provider decide."
        case .none: return "No reasoning. Fastest and cheapest; a few models reject this and will return an error."
        case .low: return "Minimal reasoning. Good for simple, latency-sensitive tasks."
        case .medium: return "Balanced reasoning effort."
        case .high: return "More thorough reasoning for complex problems."
        case .xhigh: return "Maximum reasoning effort. Slowest and most expensive."
        }
    }

    /// Anthropic `thinking.budget_tokens` for this effort (0 = not enabled).
    /// The budget counts toward the request's `max_tokens`, so the request
    /// builder raises `max_tokens` when the budget would exceed it.
    var anthropicBudgetTokens: Int {
        switch self {
        case .auto, .none: return 0
        case .low: return 1_024
        case .medium: return 4_096
        case .high: return 8_192
        case .xhigh: return 16_384
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
    let reasoningEffort: ReasoningEffort

    var isGemini: Bool { source == .gemini }
    var isAnthropic: Bool { source == .anthropic }
    var isLocal: Bool { source.isLocal }
    var isOpenRouter: Bool { source == .openRouter }

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

    @AppStorage("aiCompletionEnabled") var completionEnabled: Bool = false
    @AppStorage("aiAssistantEnabled") var assistantEnabled: Bool = false

    /// Convenience: true when at least one AI feature is active.
    var isEnabled: Bool { completionEnabled || assistantEnabled }
    @AppStorage("intellisenseEnabled") var intellisenseEnabled: Bool = true

    // MARK: - AI Chat (opt-in, like every other AI feature here)
    //
    // The chat panel itself is a separate switch from "is a project/notebook
    // scope available" — it's off for every new install until explicitly
    // turned on in Settings, same as `completionEnabled`/`assistantEnabled`.
    @AppStorage("aiChatEnabled") var chatEnabled: Bool = false
    /// Separate, extra opt-in for the sandboxed Python execution tool — off
    /// by default even when chat itself is on, since it's a materially
    /// different risk (arbitrary code execution) from read/search/write.
    @AppStorage("aiChatPythonToolEnabled") var chatPythonToolEnabled: Bool = false
    /// Default starting state for Chat's built-in semantic project search
    /// tool (`search_project`, the same RAG index AI Prompt uses). On by
    /// default, same risk tier as read_file — but the user can still flip it
    /// off per session from the chat panel itself; this only controls where
    /// each new session starts from.
    @AppStorage("aiChatRAGToolEnabledDefault") var chatRAGToolEnabledDefault: Bool = true
    /// Run the Python tool under macOS `sandbox-exec` (no network, writes
    /// limited to a scratch folder). On by default — turning it off is the
    /// "full user permissions" behavior the tool used to have.
    @AppStorage("aiChatPythonSandboxEnabled") var chatPythonSandboxEnabled: Bool = true
    /// Whether edit_file/write_file automatically compile the `.typ` file
    /// they just touched and report the result inline. On by default — it's
    /// read-only (compiles to a throwaway temp file) and is the main defense
    /// against a model leaving behind a document with mismatched delimiters.
    @AppStorage("aiChatAutoValidateTypstEdits") var chatAutoValidateTypstEdits: Bool = true
    /// Extra opt-in for the `web_fetch` tool — network egress is a meaningfully
    /// higher-risk tier than local file access (a fetch is also a request the
    /// destination server sees), so it's off by default like the Python tool,
    /// with a per-call URL approval on every fetch.
    @AppStorage("aiChatWebFetchEnabled") var chatWebFetchEnabled: Bool = false
    /// Optional comma-separated allowlist for `web_fetch` (`"typst.app,
    /// *.wikipedia.org"`), mirroring Claude Code's `WebFetch(domain:…)` rules.
    /// Empty = any public domain; the SSRF guard (private/loopback addresses
    /// refused) applies regardless and can't be opted out of.
    @AppStorage("aiChatWebFetchAllowedDomains") var chatWebFetchAllowedDomains: String = ""
    /// Rough token budget for one chat request before old turns get summarized
    /// into a compaction summary. Bigger models/local models with long
    /// contexts can raise this.
    @AppStorage("aiChatContextBudgetTokens") var chatContextBudgetTokens: Int = 16_000
    /// Seconds of total silence (no new output arriving at all) before an
    /// in-flight chat response is treated as stalled. Some local reasoning
    /// models (large Qwen/DeepSeek distills on slow hardware) simply stop
    /// emitting tokens mid-reply without closing the stream, which would
    /// otherwise leave "Thinking…" on screen forever.
    @AppStorage("aiChatStallTimeoutSeconds") var chatStallTimeoutSeconds: Double = 150.0
    /// How many times a stuck turn is automatically continued before the
    /// error is surfaced. Covers both triggers: a response that went silent
    /// past the stall timeout, and a response that ended empty because the
    /// model spent its whole reply budget on reasoning. 0 turns auto-continue
    /// off; the service clamps the stored value to a sane range.
    @AppStorage("aiChatAutoContinueAttempts") var chatAutoContinueAttempts: Int = 2

    /// Thought re-seeding: when a reply is interrupted (stall) or ends empty
    /// after a long thinking run, the abandoned reasoning is compressed
    /// verbatim (LLMLingua-2 model if installed, else the heuristic filter)
    /// and handed back to the model as notes to continue from, instead of
    /// discarding it. Off = the previous behavior: retries start cold.
    @AppStorage("aiChatThinkingReseedEnabled") var chatThinkingReseedEnabled: Bool = true
    /// Tolerance for re-seeding: the maximum number of characters of
    /// compressed thinking notes injected into a retry prompt (roughly 4
    /// characters per token). When the compressed notes exceed this, the
    /// *tail* is kept — the latest reasoning state is what a continuation
    /// needs; the task restatement at the head is already in the prompt.
    @AppStorage("aiChatThinkingReseedMaxChars") var chatThinkingReseedMaxChars: Double = 6_000

    /// Clamped tolerance actually enforced (a fat-fingered 0 or 500,000
    /// shouldn't empty the retry or flood the context).
    var effectiveChatThinkingReseedMaxChars: Int {
        Int(min(max(chatThinkingReseedMaxChars, 500), 20_000))
    }
    /// How many model turns (one model request + the tool calls it makes) a
    /// single chat message may take before the run fails with an error. Much
    /// higher than the old 6 because a real editing job (read → search → plan
    /// → several edits → verify) is routinely more than a dozen steps.
    /// 0 = unlimited.
    @AppStorage("aiChatMaxTurns") var chatMaxTurns: Int = 24
    /// The same limit for the read-only `delegate_task` subagent, which does
    /// less per turn and so needs fewer. 0 = unlimited.
    @AppStorage("aiChatSubagentMaxTurns") var chatSubagentMaxTurns: Int = 12

    /// Resolved limit for the main chat loop: 0 → `nil` (unlimited); positive
    /// values clamped so a fat-fingered 10⁶ can't turn a stuck model into an
    /// unbounded request loop.
    var effectiveChatMaxTurns: Int? {
        chatMaxTurns <= 0 ? nil : min(chatMaxTurns, 500)
    }

    /// Resolved limit for the read-only subagent (same 0 = unlimited rule).
    var effectiveChatSubagentMaxTurns: Int? {
        chatSubagentMaxTurns <= 0 ? nil : min(chatSubagentMaxTurns, 500)
    }

    // MARK: - Context Compression (LLMLingua-style token filtering)

    /// How older context is squeezed back under the budget: the original
    /// LLM-written summary, a rule-based verbatim token filter, or the
    /// LLMLingua-2 Core ML classifier (optional download; falls back to the
    /// token filter until installed). Stored as a raw string for the same
    /// reason as the reasoning-effort keys above.
    @AppStorage("aiChatCompressionMethod") private var chatCompressionMethodRaw: String = ChatCompressionMethod.llmSummary.rawValue
    /// Fraction of words to KEEP when token filtering (LLMLingua-2's `rate`
    /// semantics). 0.5 keeps the better half; small local models do well
    /// around 0.3–0.5.
    @AppStorage("aiChatCompressionKeepRate") var chatCompressionKeepRate: Double = 0.5

    var chatCompressionMethod: ChatCompressionMethod {
        get { ChatCompressionMethod(rawValue: chatCompressionMethodRaw) ?? .llmSummary }
        set { chatCompressionMethodRaw = newValue.rawValue }
    }

    /// Clamped rate actually used by the compressors (a fat-fingered 0 or 1.5
    /// shouldn't empty or inflate the prompt).
    var effectiveChatCompressionKeepRate: Double {
        min(max(chatCompressionKeepRate, 0.1), 0.9)
    }

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

    // MARK: - Per-Task Reasoning Effort

    @AppStorage("aiReasoningEffort.generation") private var generationReasoningEffortRaw: String = ReasoningEffort.auto.rawValue
    @AppStorage("aiReasoningEffort.completion") private var completionReasoningEffortRaw: String = ReasoningEffort.auto.rawValue

    var generationReasoningEffort: ReasoningEffort {
        get { ReasoningEffort(rawValue: generationReasoningEffortRaw) ?? .auto }
        set { generationReasoningEffortRaw = newValue.rawValue }
    }

    var completionReasoningEffort: ReasoningEffort {
        get { ReasoningEffort(rawValue: completionReasoningEffortRaw) ?? .auto }
        set { completionReasoningEffortRaw = newValue.rawValue }
    }

    func reasoningEffort(for task: ModelTask) -> ReasoningEffort {
        switch task {
        case .generation:
            return generationReasoningEffort
        case .completion:
            // Mirror the model fallback: an empty completion model reuses the
            // generation context, so reuse its reasoning effort too.
            let trimmed = completionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? generationReasoningEffort : completionReasoningEffort
        case .embedding:
            // Embeddings have no reasoning.
            return .auto
        }
    }

    // MARK: - Shared API Keys (per cloud source)

    @AppStorage("openAIApiKey") var openAIApiKey: String = ""
    @AppStorage("openRouterApiKey") var openRouterApiKey: String = ""
    @AppStorage("anthropicApiKey") var anthropicApiKey: String = ""
    @AppStorage("geminiApiKey") var geminiApiKey: String = ""
    @AppStorage("customApiKey") var customApiKey: String = ""

    // MARK: - General AI Settings
    @AppStorage("aiContinuousCompletion") var isContinuousCompletionEnabled: Bool = false 
    @AppStorage("aiForceCodeOutput") var forceCodeOutput: Bool = false
    @AppStorage("aiMaxContextWindow") var maxContextWindow: Int = 4096
    @AppStorage("aiIncludeProjectContext") var includeProjectContext: Bool = true
    @AppStorage("aiMaxTokens") var maxTokens: Int = 2048
    @AppStorage("aiCacheEmbeddingsToDisk") var cacheEmbeddingsToDisk: Bool = true
    @AppStorage("aiTimeoutSeconds") var timeoutSeconds: Double = 120.0

    // MARK: - Temp & Vector Cache Storage Location (Global Defaults)
    //
    // Projects may override these in `.typstedit/config.json`
    // (see `ProjectConfig.storeTempInProject` / `storeVectorCacheInProject`).
    // When a given toggle is off, TypstEdit stores that folder's contents
    // under the OS temp directory instead of inside the project — see
    // `AppTempDirectoryManager`, which also owns cleaning it up since macOS
    // does not promptly purge its own temp directory.
    @AppStorage("aiStoreTempInProjectDefault") var storeTempInProjectDefault: Bool = true
    @AppStorage("aiStoreVectorCacheInProjectDefault") var storeVectorCacheInProjectDefault: Bool = true

    // MARK: - Autocomplete Context Scope
    enum CompletionContextScope: String, CaseIterable, Identifiable {
        case currentLine = "Current Line (Fastest)"
        case surroundingLines = "Surrounding Lines (±5 lines)"
        case fullDocument = "Full Document"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .currentLine:
                return "Passes only the active line/sentence. Fastest response and minimal prompt overhead — ideal for local models (Ollama/LM Studio)."
            case .surroundingLines:
                return "Passes a small window of 5 lines above and below the cursor for balanced local context."
            case .fullDocument:
                return "Passes the entire document to the model. Higher prefill latency on local models."
            }
        }
    }

    // MARK: - Autocomplete Tuning (Optimized for fast inline suggestions & slow local models)
    @AppStorage("aiCompletionContextScope") var completionContextScopeRaw: String = CompletionContextScope.currentLine.rawValue
    @AppStorage("aiCompletionMaxTokens") var completionMaxTokens: Int = 32
    @AppStorage("aiCompletionTimeoutSeconds") var completionTimeoutSeconds: Double = 4.0
    @AppStorage("aiCompletionDebounceMs") var completionDebounceMs: Double = 800.0

    var completionContextScope: CompletionContextScope {
        get { CompletionContextScope(rawValue: completionContextScopeRaw) ?? .currentLine }
        set { completionContextScopeRaw = newValue.rawValue }
    }

    /// Resolved debounce interval for autocomplete (in nanoseconds).
    var effectiveCompletionDebounceNanoseconds: UInt64 {
        let ms = max(100.0, completionDebounceMs)
        return UInt64(ms * 1_000_000)
    }

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
            apiKey: apiKey(for: src),
            reasoningEffort: reasoningEffort(for: task)
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
