import SwiftUI
import Combine

// MARK: - Model Source

/// Represents where a model runs — either a cloud provider or a local server.
enum ModelSource: String, CaseIterable, Identifiable, Codable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case anthropic = "Anthropic"
    case gemini = "Google Gemini"
    case portkey = "Portkey AI Gateway"
    case local = "Local (Ollama/LMStudio)"

    var id: String { self.rawValue }

    var isLocal: Bool { self == .local }
}

// MARK: - Portkey

/// Portkey AI Gateway (https://portkey.ai): an OpenAI-compatible gateway in
/// front of many providers. Requests go to `<base URL>/chat/completions` with
/// the Portkey key in `x-portkey-api-key`; the upstream provider is chosen by
/// a Model Catalog model string (`@openai-prod/gpt-4o`), or optionally by a
/// default provider slug / saved config sent as headers.
enum PortkeyGateway {
    static let defaultBaseURL = "https://api.portkey.ai/v1"

    /// Accepts a base URL (`https://api.portkey.ai/v1`) or a full chat
    /// completions URL, with or without a trailing slash, and returns the chat
    /// completions URL. Empty → Portkey's hosted gateway.
    static func chatEndpoint(fromBaseURL base: String) -> String {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.isEmpty { trimmed = defaultBaseURL }
        if trimmed.hasSuffix("/chat/completions") { return trimmed }
        return trimmed + "/chat/completions"
    }

    /// Routing headers besides the API key. Empty values are omitted.
    static func routingHeaders(provider: String, config: String) -> [String: String] {
        var headers: [String: String] = [:]
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = config.trimmingCharacters(in: .whitespacesAndNewlines)
        if !provider.isEmpty { headers["x-portkey-provider"] = provider }
        if !config.isEmpty { headers["x-portkey-config"] = config }
        return headers
    }
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
enum ReasoningEffort: String, CaseIterable, Identifiable, Codable {
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

    /// Provider-generic estimate of how many tokens the thinking/reasoning
    /// chain will consume for this effort level (0 = thinking off or
    /// provider-decided). Used by callers that need to widen their
    /// `max_tokens` budget to leave room for the actual answer, regardless
    /// of whether the provider is Anthropic, OpenAI, a local model, or
    /// anything else with a `reasoning_effort`/`<think>` mechanism.
    /// The numbers match `anthropicBudgetTokens`; both live here so the
    /// Anthropic-specific builder can stay named clearly while shared code
    /// uses the generic name.
    var thinkingTokenBudget: Int { anthropicBudgetTokens }
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
    /// Extra provider-specific request headers (e.g. Portkey routing headers).
    var extraHeaders: [String: String] = [:]
    /// Chat compaction override from a saved model; `nil` = the global
    /// setting. Resolve with `AISettingsManager.effectiveCompressionMethod(for:)`.
    var compressionMethod: ChatCompressionMethod? = nil
    /// Context budget override from a saved model, in tokens; `nil` = the
    /// global AI Chat → Context Budget setting. Resolve with
    /// `AISettingsManager.effectiveContextBudgetTokens(for:)`.
    var contextBudgetTokens: Int? = nil

    var isGemini: Bool { source == .gemini }
    var isAnthropic: Bool { source == .anthropic }
    var isLocal: Bool { source.isLocal }
    var isOpenRouter: Bool { source == .openRouter }
    var isPortkey: Bool { source == .portkey }

    /// The chat completions endpoint for this context.
    var chatEndpoint: String {
        switch source {
        case .openAI: return "https://api.openai.com/v1/chat/completions"
        case .openRouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        case .portkey: return PortkeyGateway.chatEndpoint(fromBaseURL: endpoint)
        case .local: return endpoint
        }
    }

    /// Provider authentication and identification headers for a chat request.
    /// (Gemini authenticates through the URL's `key` query parameter.)
    var authHeaders: [String: String] {
        var headers: [String: String]
        switch source {
        case .gemini:
            headers = [:]
        case .anthropic:
            headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        case .portkey:
            // The Portkey key authenticates with the gateway; upstream
            // provider credentials live in Portkey (Model Catalog/config).
            headers = ["x-portkey-api-key": apiKey]
        case .openRouter:
            headers = [
                "Authorization": "Bearer \(apiKey)",
                "HTTP-Referer": "TypstEdit",
                "X-Title": "TypstEdit",
            ]
        case .openAI, .local:
            headers = ["Authorization": "Bearer \(apiKey)"]
        }
        headers.merge(extraHeaders) { current, _ in current }
        return headers
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

// MARK: - Saved Model Profiles

/// A named, user-saved model configuration (source + model + endpoint +
/// reasoning effort). Users can save as many as they like in Settings →
/// AI Assistant → Chat & Actions and then pick one per feature (AI Chat,
/// AI Prompt, Refine) or switch on the fly from the chat panel / prompt sheet.
///
/// API keys stay shared per provider by default (Settings → API Keys &
/// Limits), so adding a second OpenAI model doesn't mean pasting the key
/// twice. A profile can override that key (`apiKey`), which matters when
/// several local servers each require their own token.
struct AIModelProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    /// Optional friendly label ("Fast drafts", "Claude for review"). Empty →
    /// the model name is shown instead.
    var name: String
    var source: ModelSource
    var model: String
    /// Only used for `.local` sources (OpenAI-compatible chat endpoint).
    var endpoint: String
    /// Optional key for this model only. Empty (the default) = use the shared
    /// per-provider key from API Keys & Limits. Set it when two local servers
    /// behind the same source need different tokens.
    var apiKey: String
    var reasoningEffort: ReasoningEffort
    /// How AI Chat compacts long conversations while this model is in use.
    /// `nil` = follow the global setting (AI Chat → Context Compression).
    var compressionMethod: ChatCompressionMethod?
    /// Context budget for AI Chat while this model is in use, in tokens.
    /// `nil` = follow the global setting (AI Chat → Context Budget). Paid
    /// long-context models can use their real window here (e.g. 200,000)
    /// without raising the global budget for every model.
    var contextBudgetTokens: Int?

    static let defaultLocalEndpoint = "http://localhost:11434/v1/chat/completions"

    init(
        id: UUID = UUID(),
        name: String = "",
        source: ModelSource = .openAI,
        model: String = "",
        endpoint: String = AIModelProfile.defaultLocalEndpoint,
        apiKey: String = "",
        reasoningEffort: ReasoningEffort = .auto,
        compressionMethod: ChatCompressionMethod? = nil,
        contextBudgetTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.model = model
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.compressionMethod = compressionMethod
        self.contextBudgetTokens = contextBudgetTokens
    }

    /// Lenient decoding: an unknown source/effort raw value (e.g. from a
    /// future version) falls back to a sane default instead of discarding the
    /// whole saved list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        let sourceRaw = (try? c.decode(String.self, forKey: .source)) ?? ""
        source = ModelSource(rawValue: sourceRaw) ?? .openAI
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        endpoint = (try? c.decode(String.self, forKey: .endpoint)) ?? Self.defaultLocalEndpoint
        // Missing (older saved models) → use the shared provider key.
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? ""
        let effortRaw = (try? c.decode(String.self, forKey: .reasoningEffort)) ?? ""
        reasoningEffort = ReasoningEffort(rawValue: effortRaw) ?? .auto
        // Missing (older saved models) or unknown → follow the global setting.
        compressionMethod = (try? c.decode(String.self, forKey: .compressionMethod)).flatMap(ChatCompressionMethod.init(rawValue:))
        // Missing (older saved models) → follow the global budget.
        contextBudgetTokens = try? c.decode(Int.self, forKey: .contextBudgetTokens)
    }

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedApiKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Label used in pickers: the friendly name if set, else the model name.
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        return trimmedModel.isEmpty ? "Untitled model" : trimmedModel
    }

    /// `displayName · source` (plus the model when a friendly name hides it).
    var detailedName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, !trimmedModel.isEmpty {
            return "\(trimmedName) — \(trimmedModel) · \(source.rawValue)"
        }
        return "\(displayName) · \(source.rawValue)"
    }
}

/// Features that can each be pointed at a different saved model. Anything
/// without an explicit choice uses the default Chat & Actions model.
enum AIFeature: String, CaseIterable, Identifiable {
    case chat
    case prompt
    case refine
    case calculator

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat: return "AI Chat"
        case .prompt: return "AI Prompt (Insert)"
        case .refine: return "Refine & Grammar"
        case .calculator: return "Calculator AI Fallback"
        }
    }

    var description: String {
        switch self {
        case .chat: return "The chat panel, its delegate_task subagent, and history compaction."
        case .prompt: return "The AI Prompt sheet that generates content to insert at the cursor (including Fix with AI)."
        case .refine: return "Refine Writing and Fix Grammar on a selection."
        case .calculator: return "Questions the calculator's math engine cannot evaluate, answered instead of an error."
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
    @AppStorage("aiChatEnabled") var chatEnabled: Bool = false {
        willSet { objectWillChange.send() }
    }
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
    /// Whether conversations are saved to disk at all, keyed to where the
    /// chat's scope lives: project chats go to `.typstedit/chat/sessions/`
    /// inside the project (so they travel with it and can be committed),
    /// notebook chats to the app's library folder. Off = conversations live
    /// in memory for this app run only.
    @AppStorage("aiChatSessionsEnabled") var chatSessionsEnabled: Bool = true
    /// After the first reply, one small request asks the chat model for a
    /// short conversation title (until then the first message names it).
    /// A manual rename always wins and is never overwritten.
    @AppStorage("aiChatAutoTitleEnabled") var chatAutoTitleEnabled: Bool = true
    /// Wolfram|Alpha-style fallback for the calculator: when the CAS can't
    /// evaluate an entry that reads like a natural-language question, one
    /// one-shot request asks the chat model for the answer. Off by default —
    /// a calculator that silently makes network calls would be a surprise —
    /// and it additionally requires AI Chat itself to be switched on.
    @AppStorage("calcAIFallbackEnabled") var calcAIFallbackEnabled: Bool = false {
        willSet { objectWillChange.send() }
    }
    /// Maximum output tokens for a single AI Fallback request in the
    /// calculator. This is the answer-side ceiling; when the configured model
    /// has an active reasoning/thinking effort the thinking budget is added on
    /// top automatically (it counts against `max_tokens` on most providers).
    /// 800 is enough for any EXPR/ANSWER reply; raise it if a verbose model
    /// or a complex question consistently hits the ceiling.
    @AppStorage("calcAIFallbackMaxTokens") var calcAIFallbackMaxTokens: Int = 800

    /// Skills that start enabled in new AI chats. Persisted as a
    /// comma-separated list of skill IDs (`scope:folderName`). Empty by
    /// default — new chats start with no skills enabled until the user
    /// turns one on. The AI Chat re-seeds its skill selection from this
    /// list whenever a new session begins (see `AIChatManager`).
    @AppStorage("aiChatDefaultSkillIDs") private var chatDefaultSkillIDsRaw: String = ""
    var chatDefaultSkillIDs: [String] {
        get {
            chatDefaultSkillIDsRaw
                .split(separator: ",")
                .map { String($0) }
                .filter { !$0.isEmpty }
        }
        set {
            chatDefaultSkillIDsRaw = newValue.joined(separator: ",")
        }
    }

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
    /// Extra opt-in for the Git tools. Off by default: many people don't want
    /// an assistant touching their repository at all. When on, AI Chat can
    /// read Git state (status/diff/log) and — with a per-call approval —
    /// stage and commit. Every tool works only when the open project folder
    /// is the repository root, and nothing here force-pushes, rebases or
    /// rewrites history.
    @AppStorage("aiChatGitToolsEnabled") var chatGitToolsEnabled: Bool = false {
        willSet { objectWillChange.send() }
    }
    /// Remote actions have independent, off-by-default permissions. The old
    /// combined network preference never grants these new permissions.
    @AppStorage("aiChatGitFetchEnabled") var chatGitFetchEnabled: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiChatGitPullEnabled") var chatGitPullEnabled: Bool = false {
        willSet { objectWillChange.send() }
    }
    /// Enabling Push lets the AI request it, not publish automatically.
    /// Every push requires explicit approval, even in YOLO mode.
    @AppStorage("aiChatGitPushEnabled") var chatGitPushEnabled: Bool = false {
        willSet { objectWillChange.send() }
    }

    var chatGitPermissions: GitToolPermissions {
        GitToolPermissions(enabled: chatGitToolsEnabled,
                           fetchEnabled: chatGitFetchEnabled,
                           pullEnabled: chatGitPullEnabled,
                           pushEnabled: chatGitPushEnabled)
    }
    /// Optional comma-separated allowlist for `web_fetch` (`"typst.app,
    /// *.wikipedia.org"`), mirroring Claude Code's `WebFetch(domain:…)` rules.
    /// Empty = any public domain; the SSRF guard (private/loopback addresses
    /// refused) applies regardless and can't be opted out of.
    @AppStorage("aiChatWebFetchAllowedDomains") var chatWebFetchAllowedDomains: String = ""
    /// Rough token budget for one chat request before old turns get summarized
    /// into a compaction summary. Bigger models/local models with long
    /// contexts can raise this; individual saved models can override it
    /// (`AIModelProfile.contextBudgetTokens`), so a paid long-context model
    /// doesn't need one global, conservative number.
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
    /// off; `chatAutoContinueUnlimited` removes the cap entirely.
    @AppStorage("aiChatAutoContinueAttempts") var chatAutoContinueAttempts: Int = 2
    /// Keep auto-continuing instead of giving up after `chatAutoContinueAttempts`
    /// retries. The chat shows every attempt in its live status line, and the
    /// Stop button still ends the run, so an endless empty-reply loop stays
    /// visible and interruptible. Off by default.
    @AppStorage("aiChatAutoContinueUnlimited") var chatAutoContinueUnlimited: Bool = false {
        willSet { objectWillChange.send() }
    }

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

    // MARK: - AI Chat Reply Size

    /// Output-token cap for each AI Chat (and subagent) reply. Hidden
    /// reasoning counts against the same cap, so the 2,048 that suits an AI
    /// Prompt insertion leaves an agent nothing to answer or call tools
    /// with. 0 = automatic: 16,384, or the global Max Tokens if higher.
    @AppStorage("aiChatMaxTokens") var chatMaxTokens: Int = 0 {
        willSet { objectWillChange.send() }
    }
    /// When a reply is cut off by the cap, retry it with a doubled cap (up to
    /// four times the starting cap), instead of treating it as empty or
    /// running a half-written tool call.
    @AppStorage("aiChatTokenLimitRetry") var chatTokenLimitRetryEnabled: Bool = true {
        willSet { objectWillChange.send() }
    }

    static let automaticChatMaxTokens = 16_384
    /// Upper bound for the cap and its retries.
    static let maxChatReplyTokens = 131_072

    var effectiveChatMaxTokens: Int {
        if chatMaxTokens > 0 {
            return min(max(chatMaxTokens, 1_024), Self.maxChatReplyTokens)
        }
        return min(max(Self.automaticChatMaxTokens, maxTokens), Self.maxChatReplyTokens)
    }

    /// Largest cap a cut-off reply may be retried with, or `nil` when
    /// retrying is off.
    var chatMaxTokensCeiling: Int? {
        guard chatTokenLimitRetryEnabled else { return nil }
        return min(effectiveChatMaxTokens * 4, Self.maxChatReplyTokens)
    }

    // MARK: - Loop Protection

    /// How many times an identical read or search may run, with nothing
    /// edited in between, before further repeats are refused. 0 = off.
    @AppStorage("aiChatRepeatCallLimit") var chatRepeatCallLimit: Int = ToolCallRepeatGuard.defaultMaxIdenticalRuns
    /// Rounds in a row of only reading and searching before the model is
    /// told to act or answer (repeats every this many rounds). 0 = off.
    @AppStorage("aiChatNoProgressRounds") var chatNoProgressRounds: Int = AICompletionService.defaultNoProgressRoundThreshold
    /// Replies left at which the model is warned that the turn limit is
    /// near. 0 = no warnings; 1 = only the final-reply notice; 2 or more =
    /// an early heads-up as well. Has no effect with unlimited turns.
    @AppStorage("aiChatTurnLimitWarningReplies") var chatTurnLimitWarningReplies: Int = AICompletionService.defaultTurnBudgetWarningRemaining

    var effectiveChatRepeatCallLimit: Int { min(max(chatRepeatCallLimit, 0), 20) }
    var effectiveChatNoProgressRounds: Int { min(max(chatNoProgressRounds, 0), 100) }
    var effectiveChatTurnLimitWarningReplies: Int { min(max(chatTurnLimitWarningReplies, 0), 20) }

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
    /// Shared key for local servers. Autocomplete and Embeddings can each
    /// override it (they often run on different servers than chat), and a
    /// saved model can override it per model.
    @AppStorage("customApiKey") var customApiKey: String = ""
    /// Optional keys for local servers used only by these tasks. Empty = use
    /// the shared `customApiKey`.
    @AppStorage("completionApiKey") var completionApiKey: String = ""
    @AppStorage("embeddingApiKey") var embeddingApiKey: String = ""
    @AppStorage("portkeyApiKey") var portkeyApiKey: String = ""

    // MARK: - Portkey AI Gateway

    /// Gateway base URL — Portkey's hosted gateway by default; change it for a
    /// self-hosted gateway.
    @AppStorage("portkeyBaseURL") var portkeyBaseURL: String = PortkeyGateway.defaultBaseURL
    /// Optional default provider slug (`@openai-prod`), sent as
    /// `x-portkey-provider`. Not needed when model names use the Model
    /// Catalog form `@provider-slug/model`.
    @AppStorage("portkeyProvider") var portkeyProvider: String = ""
    /// Optional saved config ID (or config JSON), sent as `x-portkey-config`
    /// for fallbacks, load balancing, caching, etc.
    @AppStorage("portkeyConfig") var portkeyConfig: String = ""

    private var portkeyRoutingHeaders: [String: String] {
        PortkeyGateway.routingHeaders(provider: portkeyProvider, config: portkeyConfig)
    }

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
        case .portkey: return portkeyApiKey
        case .local: return customApiKey
        }
    }

    /// Backward-compatible: returns the API key for the generation source.
    var apiKey: String {
        apiKey(for: source(for: .generation))
    }

    /// The key a task actually sends to a local server: its own override when
    /// set, else the shared Local Server key. Non-local sources always use
    /// their single provider key.
    func apiKey(for source: ModelSource, task: ModelTask) -> String {
        guard source == .local else { return apiKey(for: source) }
        let override: String
        switch task {
        case .generation: return customApiKey
        case .completion: override = completionApiKey
        case .embedding: override = embeddingApiKey
        }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? customApiKey : trimmed
    }

    /// The key a saved model actually sends: for local models, its own
    /// override when set, else the shared Local Server key. Cloud sources
    /// always use their single shared provider key.
    func apiKey(for profile: AIModelProfile) -> String {
        guard profile.source.isLocal else { return apiKey(for: profile.source) }
        let own = profile.trimmedApiKey
        return own.isEmpty ? customApiKey : own
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

        if src == .portkey && task != .embedding {
            return portkeyContext(task: task, model: modelName, reasoningEffort: reasoningEffort(for: task))
        }

        return ModelContext(
            task: task,
            source: src,
            model: modelName,
            endpoint: endpoint,
            apiKey: apiKey(for: src, task: task),
            reasoningEffort: reasoningEffort(for: task)
        )
    }

    /// A Portkey request context: the shared gateway URL, Portkey key, and
    /// optional default provider/config routing headers.
    private func portkeyContext(task: ModelTask, model: String, reasoningEffort: ReasoningEffort, apiKey: String? = nil, compressionMethod: ChatCompressionMethod? = nil, contextBudgetTokens: Int? = nil) -> ModelContext {
        ModelContext(
            task: task,
            source: .portkey,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: portkeyBaseURL,
            apiKey: apiKey ?? portkeyApiKey,
            reasoningEffort: reasoningEffort,
            extraHeaders: portkeyRoutingHeaders,
            compressionMethod: compressionMethod,
            contextBudgetTokens: contextBudgetTokens
        )
    }

    /// The concrete compaction method to use with a model: its saved-model
    /// override, else the global setting — with `automatic` resolved to LLM
    /// summary for cloud (paid) models and offline filtering for local ones.
    func effectiveCompressionMethod(for ctx: ModelContext) -> ChatCompressionMethod {
        (ctx.compressionMethod ?? chatCompressionMethod).resolved(isLocal: ctx.isLocal)
    }

    /// The concrete chat context budget for a model, in tokens: its
    /// saved-model override, else the global setting. The override is clamped
    /// to 2,000...1,000,000 so a typo can't disable compaction (too small) or
    /// overflow the model's real window (too large).
    func effectiveContextBudgetTokens(for ctx: ModelContext) -> Int {
        if let override = ctx.contextBudgetTokens, override > 0 {
            return min(max(override, 2_000), 1_000_000)
        }
        return max(2_000, chatContextBudgetTokens)
    }

    // MARK: - Saved Model Profiles

    /// JSON-encoded `[AIModelProfile]`. Stored as a string (like the other
    /// raw-backed settings here) so it lives alongside them in UserDefaults.
    @AppStorage("aiModelProfiles") private var modelProfilesRaw: String = ""

    /// Per-feature model choice: a profile UUID string, or "" for the default
    /// Chat & Actions model.
    @AppStorage("aiFeatureModel.chat") private var chatModelProfileIDRaw: String = ""
    @AppStorage("aiFeatureModel.prompt") private var promptModelProfileIDRaw: String = ""
    @AppStorage("aiFeatureModel.refine") private var refineModelProfileIDRaw: String = ""
    @AppStorage("aiFeatureModel.calculator") private var calculatorModelProfileIDRaw: String = ""

    /// Every saved model, in the order the user added them.
    var modelProfiles: [AIModelProfile] {
        get { Self.decodeProfiles(modelProfilesRaw) }
        set {
            objectWillChange.send()
            modelProfilesRaw = Self.encodeProfiles(newValue)
        }
    }

    static func decodeProfiles(_ raw: String) -> [AIModelProfile] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AIModelProfile].self, from: data)) ?? []
    }

    static func encodeProfiles(_ profiles: [AIModelProfile]) -> String {
        guard !profiles.isEmpty,
              let data = try? JSONEncoder().encode(profiles),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    func modelProfile(id: UUID) -> AIModelProfile? {
        modelProfiles.first { $0.id == id }
    }

    /// Adds a new saved model, seeded from the current default Chat & Actions
    /// model so the common "same provider, different model" case is one edit.
    @discardableResult
    func addModelProfile() -> AIModelProfile {
        let src = source(for: .generation)
        let profile = AIModelProfile(
            source: src,
            model: "",
            endpoint: src.isLocal ? generationEndpoint : AIModelProfile.defaultLocalEndpoint,
            reasoningEffort: generationReasoningEffort
        )
        modelProfiles.append(profile)
        return profile
    }

    func updateModelProfile(_ profile: AIModelProfile) {
        var profiles = modelProfiles
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard profiles[index] != profile else { return }
        profiles[index] = profile
        modelProfiles = profiles
    }

    /// Removes a saved model. Features that pointed at it fall back to the
    /// default model.
    func removeModelProfile(id: UUID) {
        modelProfiles.removeAll { $0.id == id }
        for feature in AIFeature.allCases where storedModelProfileIDRaw(for: feature) == id.uuidString {
            setModelProfileID(nil, for: feature)
        }
    }

    private func storedModelProfileIDRaw(for feature: AIFeature) -> String {
        switch feature {
        case .chat: return chatModelProfileIDRaw
        case .prompt: return promptModelProfileIDRaw
        case .refine: return refineModelProfileIDRaw
        case .calculator: return calculatorModelProfileIDRaw
        }
    }

    /// The saved model chosen for a feature, or `nil` for the default model.
    /// A stale ID (profile since deleted) also resolves to `nil`.
    func modelProfileID(for feature: AIFeature) -> UUID? {
        guard let id = UUID(uuidString: storedModelProfileIDRaw(for: feature)),
              modelProfile(id: id) != nil else { return nil }
        return id
    }

    func setModelProfileID(_ id: UUID?, for feature: AIFeature) {
        objectWillChange.send()
        let raw = id?.uuidString ?? ""
        switch feature {
        case .chat: chatModelProfileIDRaw = raw
        case .prompt: promptModelProfileIDRaw = raw
        case .refine: refineModelProfileIDRaw = raw
        case .calculator: calculatorModelProfileIDRaw = raw
        }
    }

    func modelProfile(for feature: AIFeature) -> AIModelProfile? {
        modelProfileID(for: feature).flatMap { modelProfile(id: $0) }
    }

    /// Resolves a saved model into a request-ready context. The API key is the
    /// profile's own override when set, else the shared per-provider key.
    func modelContext(for profile: AIModelProfile) -> ModelContext {
        let resolvedKey = apiKey(for: profile)
        if profile.source == .portkey {
            return portkeyContext(task: .generation, model: profile.trimmedModel, reasoningEffort: profile.reasoningEffort, apiKey: resolvedKey, compressionMethod: profile.compressionMethod, contextBudgetTokens: profile.contextBudgetTokens)
        }
        return ModelContext(
            task: .generation,
            source: profile.source,
            model: profile.trimmedModel,
            endpoint: profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: resolvedKey,
            reasoningEffort: profile.reasoningEffort,
            compressionMethod: profile.compressionMethod,
            contextBudgetTokens: profile.contextBudgetTokens
        )
    }

    /// The context a feature should send its requests with: its chosen saved
    /// model, or the default Chat & Actions model.
    func modelContext(for feature: AIFeature) -> ModelContext {
        if let profile = modelProfile(for: feature) {
            return modelContext(for: profile)
        }
        return modelContext(for: .generation)
    }

    /// Short label for the default Chat & Actions model, e.g. `gpt-4o · OpenAI`.
    var defaultModelDisplayName: String {
        let trimmed = generationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed.isEmpty ? "No model set" : trimmed) · \(source(for: .generation).rawValue)"
    }

    /// Compact label for the model a feature currently uses (for menu buttons).
    func activeModelShortName(for feature: AIFeature) -> String {
        if let profile = modelProfile(for: feature) {
            return profile.displayName
        }
        let trimmed = generationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Default model" : trimmed
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
