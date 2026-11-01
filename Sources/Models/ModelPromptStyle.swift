import Foundation

/// Per-model adjustments to the chat request: how the system prompt is
/// phrased, and which request options save output tokens.
///
/// One prompt for every model is a compromise. The families differ in what
/// they respond to — a GPT model follows terse imperative rules well, a Claude
/// model responds better to the same content phrased as guidance — and they
/// differ in what they support. This keeps the base prompt as the single
/// source of truth and adds a short style note per family, rather than
/// maintaining several near-identical long prompts that drift apart.
enum ModelPromptStyle: Equatable {
    case gpt
    case claude
    case kimi
    case generic

    /// Detects the family from the model id. Deliberately a substring match:
    /// ids arrive as `gpt-5`, `openai/gpt-5-mini`, `claude-sonnet-4-5`,
    /// `moonshot/kimi-k2`, and vendors prefix them inconsistently.
    static func detect(model: String) -> ModelPromptStyle {
        let id = model.lowercased()
        if id.contains("claude") || id.contains("anthropic/") { return .claude }
        if id.contains("kimi") || id.contains("moonshot") { return .kimi }
        // `gpt`, `o3`, `o4`, `chatgpt` — the OpenAI reasoning and chat families.
        if id.contains("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3")
            || id.hasPrefix("o4") || id.contains("/o3") || id.contains("/o4") {
            return .gpt
        }
        return .generic
    }

    /// The style note appended to the system prompt, or `nil` for the generic
    /// case where the base prompt is already the right shape.
    var guidance: String? {
        switch self {
        case .gpt:
            // GPT models follow short, imperative rules; long prose guidance
            // tends to be skimmed.
            return """
            HOUSE STYLE (GPT): Keep tool calls small and sequential. State what you are about to change in one line, then make the call. Prefer short answers — no restating the request, no summary of what you are about to do beyond that line, and no closing offer unless something is genuinely outstanding.
            """
        case .claude:
            // Claude responds better to the same content phrased as intent and
            // constraints than as a list of orders.
            return """
            HOUSE STYLE (Claude): You may reason about the shape of the work before acting; say briefly what you intend and why when a choice is not obvious. Prefer a few larger, well-formed edits over many small ones. When something is ambiguous, pick the reading that preserves the document's existing structure and say which reading you took.
            """
        case .kimi:
            return """
            HOUSE STYLE (Kimi): Follow the tool schemas exactly; use `read_file` with `offset`/`limit` rather than re-reading a whole file. Answer directly, in the user's language, without preamble.
            """
        case .generic:
            return nil
        }
    }
}

/// Whether to ask the provider for a terser answer.
///
/// OpenAI's newer chat models accept a `verbosity` hint that trims padding
/// without changing content, which is a direct saving in output tokens on every
/// reply. It is only sent to models known to accept it — an unknown parameter
/// is a 400 on some providers, which would cost far more than it saves.
enum ModelVerbosity {

    /// Ids known to accept the hint. Kept to the OpenAI chat families that
    /// document it; a new minor version is left out until it is known to work,
    /// matching how the hint is rolled out.
    static func supports(model: String) -> Bool {
        let id = model.lowercased()
        // Image and chat-only variants do not take the hint.
        if id.contains("-chat") || id.contains("-image") || id.contains("-tts") { return false }
        if id.contains("gpt-6") { return true }
        // gpt-5.1 … gpt-5.6, and the plain gpt-5 / mini / nano ids.
        if id.range(of: #"gpt-5\.[1-6]"#, options: .regularExpression) != nil { return true }
        if id.range(of: #"gpt-5(?:-(?:mini|nano))?$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Whether this source forwards the hint. Direct OpenAI and the gateways
    /// pass it through; a local OpenAI-compatible server usually ignores
    /// unknown fields but need not, so it is not sent there.
    static func sourceSupports(_ source: ModelSource) -> Bool {
        switch source {
        case .openAI, .openRouter, .portkey: return true
        case .anthropic, .gemini, .local: return false
        }
    }

    /// The `verbosity` value to send, or `nil` to leave the request unchanged.
    static func value(model: String, source: ModelSource, enabled: Bool) -> String? {
        guard enabled, supports(model: model), sourceSupports(source) else { return nil }
        return "low"
    }
}
