import Foundation
import Markdown

// MARK: - Precompiled Regexes
//
// The Markdown→Typst conversion itself is AST-based (see `TypstMarkupVisitor`
// below): the document is parsed once with swift-markdown and walked by a
// visitor that serializes it straight into a single output buffer. The regexes
// that remain are confined to well-scoped jobs:
//
//   * response cleanup (thinking tags, force-code-output extraction)
//   * the pre-parse extraction pass — code spans, math, backslash escapes and
//     footnote definitions must be identified BEFORE cmark parses the text,
//     because cmark either mangles them (smart quotes, emphasis inside math)
//     or consumes them outright (backslash escapes, reference definitions)
//   * leaf-level conversion/escaping of plain text runs
//   * HTML fragments (tag soup has no grammar worth parsing)
//   * whole-document post-passes carried over from the old pipeline

enum AICompletionRegex {
    // Response cleanup
    static let thinkTag = try! NSRegularExpression(pattern: "<think>[\\s\\S]*?<\\/think>", options: [.caseInsensitive])
    static let thoughtTag = try! NSRegularExpression(pattern: "<thought>[\\s\\S]*?<\\/thought>", options: [.caseInsensitive])
    static let extractCode = try! NSRegularExpression(pattern: "```(?:[a-zA-Z]*\\n)?([\\s\\S]*?)```")

    // Pre-parse extraction
    // Fenced + inline code: a backtick run, content, and the same run back.
    static let codeBlock = try! NSRegularExpression(pattern: "(?s)(`+).*?(?<!`)\\1(?!`)")
    // Math: $$…$$, $…$, \[…\] or \(…\). The (?<!\\) guards skip escaped dollars,
    // and the closing `$` must not be glued to an alphanumeric so two
    // register-style tokens (`$DC10–$DC4F`, `$3DF8/$3E50`, `$FE00–$FE9F`) are
    // not mis-paired into one math region and run through the LaTeX converter.
    static let mathBlock = try! NSRegularExpression(pattern: "(?s)\\$\\$.+?\\$\\$|(?<!\\\\)\\$(?!\\s)[^\\$\\n]+?(?<!\\s)(?<!\\\\)\\$(?![A-Za-z0-9])|(?s)\\\\\\[.+?\\\\\\]|(?s)\\\\\\([^\\n]+?\\\\\\)")
    // Backslash-escaped ASCII punctuation (the CommonMark escape set). Restored
    // verbatim so user- or delimitImproperOperators-written escapes like \$ or
    // \# keep exactly the meaning they had under the old string pipeline.
    static let backslashEscape = try! NSRegularExpression(pattern: "\\\\[!-/:-@\\[-`{-~]")
    // Footnote definitions must be pulled out pre-parse: cmark would otherwise
    // consume `[^id]: text` as a link reference definition and turn every
    // `[^id]` reference into a plain link instead of a footnote.
    static let fnDef = try! NSRegularExpression(pattern: "(?m)^\\[\\^([^\\]]+)\\]:[ \\t]*(.*?)(?=\\n\\[\\^|\n\\z|\\z)", options: [.dotMatchesLineSeparators])

    // Leaf-level conversions
    static let fnRef = try! NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]")
    static let fnInline = try! NSRegularExpression(pattern: "(?<!!)\\^\\[([^\\]]+)\\]")
    static let bareVideo = try! NSRegularExpression(pattern: #"(?m)^[ \t]*(https?://(?:www\.|m\.)?(?:youtube\.com/(?:watch|embed|v|shorts|live)|youtu\.be/|vimeo\.com/)[^\s]+)[ \t]*$"#, options: [.caseInsensitive])

    // Leaf-level escaping
    static let escapeHtmlTags = try! NSRegularExpression(pattern: "(?i)\\\\?<(?!(?:[a-z0-9_-]+)>)(/?[a-z][a-z0-9]*\\b[^>]*)>")
    static let strayBacktick = try! NSRegularExpression(pattern: "(?<!\\\\)`")
    static let literalDollar = try! NSRegularExpression(pattern: "(?<!\\\\)\\$")
    static let literalHash = try! NSRegularExpression(pattern: "(?<!\\\\)#(?!link\\(|image\\(|strike\\[|line\\(|table\\(|figure\\(|align\\(|kbd\\[|super\\[|sub\\[|underline\\[|highlight\\[|footnote\\[|quote\\[)")
    static let literalAt = try! NSRegularExpression(pattern: "(?<!\\\\)@")
    static let technicalUnderscore = try! NSRegularExpression(pattern: "(?<=[a-zA-Z0-9])_(?=[a-zA-Z0-9])")
    static let hybridDollarDigit = try! NSRegularExpression(pattern: "(?<!\\\\)\\$(?=\\d)")
    static let hybridAt = try! NSRegularExpression(pattern: "(?<!\\\\)(?<=[a-zA-Z0-9])@|(?<!\\\\)@(?=\\s)")
    static let hybridHash = try! NSRegularExpression(pattern: "(?<!\\\\)#(?!import\\b|include\\b|let\\b|set\\b|show\\b|return\\b|if\\b|else\\b|for\\b|while\\b|context\\b)([A-Za-z][A-Za-z0-9_]*)(?=[,!?;:]|\\.\\s|\\.$)")
    // A `#` followed by whitespace or end-of-text can't start a Typst expression,
    // so it's escaped (delimitImproperOperators used to emit these already
    // escaped and the old pipeline preserved them verbatim).
    static let hybridStrayHash = try! NSRegularExpression(pattern: "(?<!\\\\)#(?=\\s|$)")
    static let stringLiteral = try! NSRegularExpression(pattern: "\"[^\"]*\"")

    // Whole-document post-passes
    static let docDot = try! NSRegularExpression(pattern: "(?m)^([ \\t]*)[⋅·]+")
    static let markdownAbbr = try! NSRegularExpression(pattern: "(?m)^\\*\\[([^\\]]+)\\]:")

    // HTML fragments. One tokenizer finds comments/tags; `htmlAttr` pulls
    // individual attribute values out of a tag's raw text.
    static let htmlToken = try! NSRegularExpression(pattern: "(?s)<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*>")
    static let htmlAttr = try! NSRegularExpression(pattern: "(?i)\\b(href|align|src|alt|width|height)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")

    // Video IDs
    static let youtubeID = try! NSRegularExpression(pattern: #"(?:youtube\.com/(?:watch\?(?:.*&)?v=|embed/|v/|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})"#, options: [.caseInsensitive])
    static let vimeoID = try! NSRegularExpression(pattern: #"(?:player\.)?vimeo\.com/(?:video/)?(\d{6,})"#, options: [.caseInsensitive])
}

enum AIError: LocalizedError {
    case invalidURL
    case noData
    case parsingError(String)
    case apiError(String)
    /// The stream went silent for longer than the stall window — treated as
    /// a stuck response rather than a hard failure, so the agentic loop can
    /// auto-continue (see `fetchCompletionWithTools`).
    case stalledResponse(idleSeconds: Int, timeoutSeconds: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL configuration."
        case .noData: return "No data received from the AI provider."
        case .parsingError(let details): return "Parsing Error: \(details)"
        case .apiError(let msg): return msg
        case .stalledResponse(let idleSeconds, let timeoutSeconds):
            return "The model stopped sending output for \(idleSeconds)s (stall limit: \(timeoutSeconds)s) and the attempt was abandoned."
        }
    }
}

/// Distinguishes between chat-based requests (AI Prompt, Refine, test connection)
/// and inline completion requests (autocomplete). Maps to the corresponding
/// ModelTask so each purpose can use its own model source and configuration.
enum AIRequestPurpose {
    case chat
    case completion

    var modelTask: ModelTask {
        switch self {
        case .chat: return .generation
        case .completion: return .completion
        }
    }
}

// MARK: - Agentic Tool Calling Types

/// One tool call the model asked to execute, in a provider-neutral shape.
struct AIToolCallRequest {
    let id: String
    /// The tool's `qualifiedName` (`server__tool`), as sent to the provider.
    let name: String
    let argumentsJSON: String
}

/// The result of executing one tool call, fed back to the model.
struct AIToolResult {
    let callID: String
    let name: String
    let output: String
}

/// A provider-neutral chat message used internally by the tool-calling loop
/// in `AICompletionService`. Converted to each provider's wire format
/// immediately before sending (OpenAI-compatible vs. Anthropic shapes differ
/// enough — system role, tool role vs. tool_result blocks — that a single
/// shared JSON shape isn't worth forcing).
enum AIChatMessage {
    case system(String)
    case user(String)
    case assistantText(String)
    case assistantToolCalls([AIToolCallRequest])
    case toolResult(AIToolResult)
}

/// What one turn of a tool-calling conversation produced. Each case carries
/// along any reasoning/"thinking" content the provider returned natively
/// for that turn (e.g. `reasoning_content`), separate from the visible
/// text/tool calls — `fetchCompletionWithTools` collects these across turns
/// so the whole exchange's thinking can be shown, not just the last turn's.
enum AIChatStep {
    case finalText(String, reasoning: String?)
    case toolCalls([AIToolCallRequest], reasoning: String?)
}

/// Thread-safe record of streaming activity for the stall watchdog. The SSE
/// parsers run on the main actor, but the watchdog polls from a detached
/// task, so the "when did we last receive anything" timestamp has to be
/// shared safely between them.
private final class StreamActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTouch = Date()

    func touch() {
        lock.lock()
        lastTouch = Date()
        lock.unlock()
    }

    /// True when nothing has arrived for longer than `timeout` seconds.
    func isStalled(past timeout: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastTouch) >= timeout
    }

    var secondsSinceTouch: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastTouch)
    }
}

@MainActor
class AICompletionService: ObservableObject {
    static let shared = AICompletionService()

    @Published var isFetching: Bool = false

    private init() {}

    /// Strips `<think>`/`<thought>` tags some local/open models emit inline
    /// in their content, and returns what was inside them separately rather
    /// than discarding it — callers surface that as the model's visible
    /// "thinking" instead of silently dropping it.
    private func extractThinking(from text: String) -> (clean: String, reasoning: String?) {
        var cleanText = text
        let regexes = [AICompletionRegex.thinkTag, AICompletionRegex.thoughtTag]

        var captured: [String] = []
        for regex in regexes {
            let range = NSRange(cleanText.startIndex..<cleanText.endIndex, in: cleanText)
            for match in regex.matches(in: cleanText, options: [], range: range) {
                guard let r = Range(match.range, in: cleanText) else { continue }
                let inner = String(cleanText[r])
                    .replacingOccurrences(of: "<think>", with: "", options: [.caseInsensitive])
                    .replacingOccurrences(of: "</think>", with: "", options: [.caseInsensitive])
                    .replacingOccurrences(of: "<thought>", with: "", options: [.caseInsensitive])
                    .replacingOccurrences(of: "</thought>", with: "", options: [.caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { captured.append(inner) }
            }
        }

        for regex in regexes {
            let range = NSRange(cleanText.startIndex..<cleanText.endIndex, in: cleanText)
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: range, withTemplate: "")
        }

        return (cleanText.trimmingCharacters(in: .whitespacesAndNewlines), captured.isEmpty ? nil : captured.joined(separator: "\n\n"))
    }

    func fetchCompletion(prompt: String, systemPrompt: String = "You are a precise code completion engine. Output ONLY the code to insert at the cursor. Do NOT output any thinking, reasoning, explanations, or XML tags.", maxTokens: Int? = nil, purpose: AIRequestPurpose = .chat, onReasoning: @escaping (String) -> Void = { _ in }, sanitize: Bool = true) async throws -> String {
        isFetching = true
        defer { isFetching = false }

        let settings = AISettingsManager.shared

        // Determine appropriate token ceiling: autocomplete only needs a few tokens
        let effectiveMaxTokens: Int
        if let explicitTokens = maxTokens {
            effectiveMaxTokens = explicitTokens
        } else if purpose == .completion {
            effectiveMaxTokens = settings.completionMaxTokens
        } else {
            effectiveMaxTokens = 128
        }

        // Resolve the full model context for this task (source, model, endpoint, key).
        let ctx = settings.modelContext(for: purpose.modelTask)

        // Only require API key for cloud providers
        if !ctx.isLocal && ctx.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(ctx.source.rawValue)")
        }

        let endpoint = ctx.chatEndpoint
        let isGemini = ctx.isGemini

        guard let url = URL(string: endpoint) else {
            throw AIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Provider-specific auth headers
        if ctx.isAnthropic {
            request.addValue(ctx.apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !isGemini {
            request.addValue("Bearer \(ctx.apiKey)", forHTTPHeaderField: "Authorization")
        }

        // OpenRouter specific headers
        if ctx.source == .openRouter {
            request.addValue("TypstEdit", forHTTPHeaderField: "HTTP-Referer")
            request.addValue("TypstEdit", forHTTPHeaderField: "X-Title")
        }

        // Gemini Body Format
        if isGemini {
            var body: [String: Any] = [
                "contents": [
                    [
                        "parts": [
                            ["text": systemPrompt + "\n\n" + prompt]
                        ]
                    ]
                ],
                "generationConfig": [
                    "maxOutputTokens": effectiveMaxTokens,
                    "temperature": 0.2
                ]
            ]
            Self.applyReasoningEffort(ctx.reasoningEffort, model: ctx.model, toGemini: &body)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Anthropic Messages API Format
        else if ctx.isAnthropic {
            var body: [String: Any] = [
                "model": ctx.model,
                "max_tokens": effectiveMaxTokens,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ]
            Self.applyReasoningEffort(ctx.reasoningEffort, toAnthropic: &body)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // OpenAI / Standard Format
        else {
            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ]

            var body: [String: Any] = [
                "model": ctx.model,
                "messages": messages,
                "max_tokens": effectiveMaxTokens,
                "temperature": 0.2, // Deterministic
                "stream": false
            ]
            Self.applyReasoningEffort(ctx.reasoningEffort, toOpenAI: &body, isOpenRouter: ctx.isOpenRouter)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.noData
        }

        guard httpResponse.statusCode == 200 else {
            var parsedErrorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"

            // Attempt to extract a clean error message from the standard AI API formats
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                    parsedErrorMsg = msg
                } else if let errorArray = json["error"] as? [[String: Any]], let first = errorArray.first, let msg = first["message"] as? String {
                    parsedErrorMsg = msg
                }
            }

            throw AIError.apiError("API Error (\(httpResponse.statusCode)): \(parsedErrorMsg)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parsingError("Invalid JSON structure returned by provider.")
        }

        let rawResult: String
        // Native reasoning the provider returned as a separate field, e.g.
        // DeepSeek/Qwen-reasoner-style `reasoning_content`, or OpenRouter's
        // `reasoning` — distinct from `<think>` tags embedded in `content`,
        // which `extractThinking` handles further down.
        var nativeReasoning: String?

        // Parse Gemini Response
        if isGemini {
            if let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let contentObj = firstCandidate["content"] as? [String: Any],
               let parts = contentObj["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                rawResult = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let promptFeedback = json["promptFeedback"] as? [String: Any],
                      let blockReason = promptFeedback["blockReason"] as? String {
                throw AIError.apiError("Request blocked by safety filters. Reason: \(blockReason)")
            } else {
                throw AIError.parsingError("Gemini response missing text. Keys returned: \(json.keys.joined(separator: ", "))")
            }
        }
        // Parse Anthropic Response
        else if ctx.isAnthropic {
            if let contentArray = json["content"] as? [[String: Any]],
               let textBlock = contentArray.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                rawResult = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let thinkingBlocks = contentArray.filter { ($0["type"] as? String) == "thinking" }
                if !thinkingBlocks.isEmpty {
                    nativeReasoning = thinkingBlocks.compactMap { $0["thinking"] as? String }.joined(separator: "\n\n")
                }
            } else if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw AIError.apiError("API Error: \(msg)")
            } else {
                throw AIError.parsingError("Anthropic response missing text. Keys returned: \(json.keys.joined(separator: ", "))")
            }
        }
        // Parse OpenAI / OpenRouter Response
        else {
            if let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                rawResult = content.trimmingCharacters(in: .whitespacesAndNewlines)
                nativeReasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String)
            } else if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw AIError.apiError("API Error: \(msg)")
            } else {
                throw AIError.parsingError("OpenAI response missing text. Keys returned: \(json.keys.joined(separator: ", "))")
            }
        }

        var finalResult = rawResult

        // Strip out any <think> tags that models might output, but surface
        // what was inside them (and any natively-returned reasoning field)
        // rather than throwing it away.
        let (cleaned, tagReasoning) = extractThinking(from: finalResult)
        finalResult = cleaned
        let combinedReasoning = [nativeReasoning, tagReasoning].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !combinedReasoning.isEmpty {
            onReasoning(combinedReasoning.joined(separator: "\n\n"))
        }

        if settings.forceCodeOutput {
            let extracted = extractCode(from: finalResult)
            // Fallback to the raw text if the AI didn't format it as a code block
            finalResult = extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? finalResult : extracted
        }

        // Completion requests return code to insert at the caret, not markdown
        // prose — running the Markdown→Typst sanitizer over it mangles the very
        // syntax it should insert (e.g. `#page` becomes `\#page`).
        let sanitizedResult = (purpose == .completion || !sanitize) ? finalResult : sanitizeMarkdownToTypst(finalResult)

        print("RAW AI RESULT: '\(rawResult)'")
        print("SANITIZED RESULT: '\(sanitizedResult)'")

        // Trap completely empty responses so the UI doesn't silently reset
        if sanitizedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIError.apiError(Self.emptyAnswerFailureMessage(nudges: 0, hadReasoning: !combinedReasoning.isEmpty))
        }

        return sanitizedResult
    }

    private func extractCode(from text: String) -> String {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = AICompletionRegex.extractCode.firstMatch(in: text, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    /// Verifies the connection to the AI provider by sending a minimal prompt.
    func testConnection() async throws -> String {
        return try await fetchCompletion(prompt: "Hello. Respond with exactly the word 'OK'.")
    }

    // MARK: - Agentic Tool Calling (MCP)
    //
    // Only reached when the caller explicitly passes `tools` (AI Prompt with
    // one or more MCP servers enabled) — `fetchCompletion` above is
    // completely untouched, so autocomplete, Refine, and every other
    // existing caller behaves exactly as before.

    func fetchCompletionWithTools(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        tools: [MCPTool],
        /// Maximum number of model turns (a turn = one model request plus any
        /// tool calls it makes). `nil` = unlimited — the loop then ends only
        /// when the model produces a final answer or the task is cancelled.
        maxTurns: Int? = 6,
        onToolCall: @escaping (String, String) -> Void = { _, _ in },
        onReasoning: @escaping (String) -> Void = { _ in },
        /// When non-nil, each turn is requested with streaming enabled and
        /// every reasoning/"thinking" fragment is forwarded here as it
        /// arrives — letting the caller show the model's live thinking while
        /// it works. Passing nil keeps the one-shot request/response behavior.
        /// Main-actor isolated (and therefore implicitly Sendable) so the
        /// stall watchdog can race the streaming parse in a child task.
        onReasoningDelta: (@MainActor (String) -> Void)? = nil,
        sanitize: Bool = true,
        contextCharBudget: Int? = nil,
        executeTool: @escaping (_ qualifiedName: String, _ argumentsJSON: String) async throws -> String
    ) async throws -> String {
        guard !tools.isEmpty else {
            return try await fetchCompletion(prompt: prompt, systemPrompt: systemPrompt, maxTokens: maxTokens, purpose: .chat, onReasoning: onReasoning, sanitize: sanitize)
        }

        isFetching = true
        defer { isFetching = false }

        let settings = AISettingsManager.shared
        let ctx = settings.modelContext(for: .generation)

        if !ctx.isLocal && ctx.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(ctx.source.rawValue)")
        }
        guard !ctx.isGemini else {
            // Gemini's function-calling schema isn't wired up yet — fail
            // clearly rather than silently ignoring the tools the user picked.
            throw AIError.apiError("Tool calling (MCP) isn't supported yet for Google Gemini. Choose a different Chat source, or disable MCP tools for this request.")
        }

        var messages: [AIChatMessage] = [.system(systemPrompt), .user(prompt)]
        // Reasoning collected across every turn (including turns that only
        // made tool calls), so the whole exchange's thinking is available
        // once a final answer lands — not just whatever the last turn said.
        var collectedReasoning: [String] = []
        // Auto-continue budget, shared by both "the turn got stuck" triggers:
        // a response that went silent mid-stream past the stall timeout
        // (detected by `requestChatStep` and thrown as `.stalledResponse`),
        // and a response that ended empty because the model spent its whole
        // reply budget on reasoning. One counter bounds the total wasted
        // time — a pathological model can't get a fresh budget from each
        // trigger. Configured in Settings; 0 turns auto-continue off.
        let maxAutoContinues = Self.clampedAutoContinueAttempts(settings.chatAutoContinueAttempts)
        var autoContinues = 0

        // Thought re-seeding (optional): abandoned reasoning is compressed
        // and handed back as notes on the retry. The compressor is resolved
        // lazily on first use so a trouble-free turn never loads the model.
        let reseedEnabled = settings.chatThinkingReseedEnabled
        let reseedMaxChars = settings.effectiveChatThinkingReseedMaxChars
        var reseedCompressor: (any PromptCompressor)?
        // Streaming reasoning deltas of the attempt in flight — what a
        // stall-time re-seed has to work with (non-streaming requests
        // deliver reasoning via the step, which lands in collectedReasoning).
        var attemptReasoning = ""

        // Resolved once per request: nil for the LLM-summary method (no
        // in-loop compression wanted), otherwise the token filter or the
        // LLMLingua-2 engine — with the filter as the automatic fallback
        // when the model isn't installed.
        let compression = await ChatCompressor.resolve(method: settings.chatCompressionMethod)

        var turn = 0
        while true {
            // A cancelled task (the chat's Stop button) unwinds here instead
            // of burning another model request.
            try Task.checkCancellation()
            if let contextCharBudget {
                await Self.elideOldToolOutputs(
                    in: &messages,
                    charBudget: contextCharBudget,
                    compressor: compression?.compressor,
                    keepRate: compression?.keepRate ?? 0.5
                )
            }
            let step: AIChatStep
            while true {
                attemptReasoning = ""
                do {
                    step = try await requestChatStep(ctx: ctx, messages: messages, tools: tools, maxTokens: maxTokens, reasoningDelta: { text in
                        attemptReasoning += text
                        onReasoningDelta?(text)
                    })
                    break
                } catch AIError.stalledResponse(let idleSeconds, let timeoutSeconds) {
                    // The stream went silent past the stall window and the
                    // attempt was abandoned. Rather than failing the whole
                    // exchange, tell the model to pick up where it left off
                    // — bounded by the configured auto-continue budget.
                    guard autoContinues < maxAutoContinues else {
                        throw AIError.apiError(Self.stallFailureMessage(attempts: autoContinues, idleSeconds: idleSeconds, timeoutSeconds: timeoutSeconds))
                    }
                    autoContinues += 1
                    // Streaming chat shows a live thinking box — surface why
                    // it just went quiet and restarted. The note is
                    // deliberately transient: the saved reasoning comes from
                    // `onReasoning`, not these deltas.
                    onReasoningDelta?(Self.stallContinueStatusNote(attempt: autoContinues, maxAttempts: maxAutoContinues, idleSeconds: idleSeconds))
                    // A placeholder keeps strict user/assistant alternation
                    // intact for providers, like Anthropic, that require it —
                    // the interrupted attempt produced nothing usable.
                    messages.append(.assistantText(Self.interruptedReplyPlaceholder))
                    // Optional re-seed: compress the abandoned attempt's own
                    // thinking and hand it back as continuation notes.
                    var continueMessage = Self.stallContinueMessage(idleSeconds: idleSeconds, timeoutSeconds: timeoutSeconds)
                    if reseedEnabled, !attemptReasoning.isEmpty {
                        if reseedCompressor == nil {
                            reseedCompressor = await ChatCompressor.bestAvailable()
                        }
                        if let notes = await Self.thinkingReseedNotes(
                            from: attemptReasoning,
                            compressor: reseedCompressor!,
                            maxChars: reseedMaxChars
                        ) {
                            continueMessage = Self.reseedStallContinueMessage(idleSeconds: idleSeconds, timeoutSeconds: timeoutSeconds, notes: notes)
                        }
                    }
                    messages.append(.user(continueMessage))
                }
            }

            switch step {
            case .finalText(let text, let stepReasoning):
                if let stepReasoning, !stepReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    collectedReasoning.append(stepReasoning)
                }
                let (cleaned, tagReasoning) = extractThinking(from: text)
                if let tagReasoning { collectedReasoning.append(tagReasoning) }
                var finalResult = cleaned
                if settings.forceCodeOutput {
                    let extracted = extractCode(from: finalResult)
                    finalResult = extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? finalResult : extracted
                }
                let sanitized = sanitize ? sanitizeMarkdownToTypst(finalResult) : finalResult

                if sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let hadReasoning = (stepReasoning?.isEmpty == false) || (tagReasoning?.isEmpty == false)
                    // The model stopped without writing anything — often after
                    // a long run of tool calls that didn't pan out, or (with a
                    // reasoning model) after spending its whole reply budget on
                    // invisible "thinking" tokens. Discarding every tool call
                    // it already made and failing outright would be wasteful:
                    // nudge it to use what it has instead, a few times, before
                    // giving up. This is the fix for empty responses landing
                    // after a visible trail of successful tool calls.
                    guard autoContinues < maxAutoContinues,
                          maxTurns.map { turn < $0 - 1 } ?? true else {
                        throw AIError.apiError(Self.emptyAnswerFailureMessage(nudges: autoContinues, hadReasoning: hadReasoning))
                    }
                    autoContinues += 1
                    // A placeholder (never literally empty) keeps strict
                    // user/assistant alternation intact for providers, like
                    // Anthropic, that require it.
                    messages.append(.assistantText("(no response)"))
                    // Optional re-seed: the abandoned thinking — streamed
                    // deltas if any, otherwise this step's returned reasoning
                    // — comes back as compressed notes to answer from.
                    var nudgeMessage = Self.emptyAnswerNudgeMessage(hadReasoning: hadReasoning)
                    if reseedEnabled {
                        let source = attemptReasoning.isEmpty ? (collectedReasoning.last ?? "") : attemptReasoning
                        if !source.isEmpty {
                            if reseedCompressor == nil {
                                reseedCompressor = await ChatCompressor.bestAvailable()
                            }
                            if let notes = await Self.thinkingReseedNotes(
                                from: source,
                                compressor: reseedCompressor!,
                                maxChars: reseedMaxChars
                            ) {
                                nudgeMessage = Self.reseedEmptyAnswerNudgeMessage(notes: notes)
                            }
                        }
                    }
                    messages.append(.user(nudgeMessage))
                    turn += 1
                    continue
                }

                if !collectedReasoning.isEmpty {
                    onReasoning(collectedReasoning.joined(separator: "\n\n"))
                }
                return sanitized

            case .toolCalls(let calls, let stepReasoning):
                if let stepReasoning, !stepReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    collectedReasoning.append(stepReasoning)
                }
                messages.append(.assistantToolCalls(calls))
                for call in calls {
                    try Task.checkCancellation()
                    onToolCall(call.name, call.argumentsJSON)
                    let output: String
                    do {
                        output = try await executeTool(call.name, call.argumentsJSON)
                    } catch {
                        // A cancelled task must unwind the whole loop, not be
                        // folded into an "Error: …" result the model would
                        // just keep working around.
                        if Task.isCancelled { throw CancellationError() }
                        output = "Error: \(error.localizedDescription)"
                    }
                    messages.append(.toolResult(AIToolResult(callID: call.id, name: call.name, output: output)))
                }
                if let maxTurns, turn == maxTurns - 1 {
                    throw AIError.apiError("The AI kept calling tools without producing a final answer after \(maxTurns) turns.")
                }
                turn += 1
            }
        }
    }

    /// Upper bound for the Settings-configured auto-continue attempts, so a
    /// fat-fingered value can't make a stuck model burn dozens of requests —
    /// bounded well below `maxTurns` for the same reason. `nonisolated` (and
    /// not private): pure value, no instance state, and directly
    /// unit-testable without hopping onto the main actor.
    nonisolated static func clampedAutoContinueAttempts(_ raw: Int) -> Int {
        min(max(raw, 0), 5)
    }

    nonisolated static func emptyAnswerNudgeMessage(hadReasoning: Bool) -> String {
        hadReasoning
            ? "You thought that through but didn't write an answer — the reply was empty. Using what you already found above, write the actual answer now in plain text."
            : "That reply came back empty. Using what you've already found above, write the actual answer now in plain text — even if the answer is that you couldn't find anything."
    }

    /// Transcript message sent after a stalled attempt was abandoned: tells
    /// the model its previous reply was cut off mid-stream so it resumes
    /// instead of starting over as if nothing happened.
    nonisolated static func stallContinueMessage(idleSeconds: Int, timeoutSeconds: Int) -> String {
        "Your previous reply stalled — no output arrived for \(idleSeconds)s (limit: \(timeoutSeconds)s) — and nothing from it was kept. Pick up where you left off: re-issue any tool call you were making, or write your final answer now."
    }

    /// Placeholder for the abandoned attempt in the transcript, mirroring the
    /// "(no response)" placeholder used by the empty-answer nudge.
    nonisolated static let interruptedReplyPlaceholder = "(reply interrupted)"

    /// Note pushed into the live thinking box when a stalled attempt is
    /// abandoned, so an automatically continued turn doesn't look like the
    /// model merely started over for no reason. Never persisted — the saved
    /// reasoning is collected separately.
    nonisolated static func stallContinueStatusNote(attempt: Int, maxAttempts: Int, idleSeconds: Int) -> String {
        "\n\n[No output for \(idleSeconds)s — the stalled attempt was abandoned and automatically continued (\(attempt) of \(maxAttempts)).]\n\n"
    }

    // MARK: Thinking Re-Seeding (interrupted/empty replies)

    /// Keep-rate for compressed thinking notes. Deliberately much higher
    /// than context compression: reasoning is dense — dropping a negation
    /// inverts a conclusion — while meeting-style prose tolerates 0.3-0.5.
    /// `thinkingForceTokens` guards the pivots regardless.
    nonisolated static let thinkingReseedKeepRate = 0.6

    /// Minimum size of abandoned thinking worth re-seeding. Below this the
    /// plain nudge/continue message is just as good and costs less.
    nonisolated static let thinkingReseedMinimumChars = 400

    /// Compresses an abandoned attempt's reasoning into continuation notes.
    /// Returns nil when there isn't enough thinking to be worth it. The
    /// tolerance (`maxChars`) is enforced on the tail: the latest reasoning
    /// state is what a continuation needs, and the task restatement at the
    /// head is already in the original prompt.
    nonisolated static func thinkingReseedNotes(
        from raw: String,
        compressor: any PromptCompressor,
        maxChars: Int
    ) async -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= thinkingReseedMinimumChars else { return nil }
        let isCode = PromptCompression.codeRatio(trimmed) > 0.35
        var notes = await compressor.compress(
            trimmed,
            keepRate: thinkingReseedKeepRate,
            forceTokens: PromptCompression.thinkingForceTokens,
            isCode: isCode
        )
        if notes.count > maxChars {
            notes = "…(earlier notes truncated)\n" + notes.suffix(maxChars)
        }
        return notes
    }

    /// Stall-continue message carrying compressed thinking notes from the
    /// abandoned attempt — the model resumes from its own (filtered) words
    /// instead of starting cold.
    nonisolated static func reseedStallContinueMessage(idleSeconds: Int, timeoutSeconds: Int, notes: String) -> String {
        """
        Your previous reply stalled — no output arrived for \(idleSeconds)s (limit: \(timeoutSeconds)s) — and was abandoned. Your compressed thinking notes from that attempt follow below. Treat them as notes: continue from where they leave off, don't repeat them, and re-issue any tool call you were making or write your final answer now.

        \(notes)
        """
    }

    /// Empty-answer nudge carrying compressed thinking notes — the model
    /// spent its whole reply budget on reasoning and never answered; the
    /// notes let it answer from its own conclusions instead of re-deriving.
    nonisolated static func reseedEmptyAnswerNudgeMessage(notes: String) -> String {
        """
        Your previous reply spent itself on thinking and never wrote an answer. Your compressed thinking notes follow below. Using them, write the actual answer now in plain text — even if the answer is that you couldn't find anything. Don't repeat the notes.

        \(notes)
        """
    }

    /// Shown when every auto-continue attempt stalled too. Points at the
    /// local server rather than the prompt — a stream that keeps going
    /// silent is a server problem, not a wording problem.
    nonisolated static func stallFailureMessage(attempts: Int, idleSeconds: Int, timeoutSeconds: Int) -> String {
        var message = "The model went silent for \(idleSeconds)s (stall limit: \(timeoutSeconds)s)"
        if attempts > 0 {
            message += " and \(attempts) automatic continue attempt\(attempts == 1 ? "" : "s") also stalled"
        }
        message += ". The AI server may be overloaded or hung — check it, retry, or raise the stall timeout in Settings → AI Assistant → AI Chat."
        return message
    }

    nonisolated static func emptyAnswerFailureMessage(nudges: Int, hadReasoning: Bool) -> String {
        var message = "The AI processed the request but returned an empty response"
        if nudges > 0 {
            message += " even after \(nudges) follow-up attempt\(nudges == 1 ? "" : "s")"
        }
        message += "."
        if hadReasoning {
            message += " It spent its reply on reasoning and left nothing for the answer — try raising Max Tokens in Settings, or lowering the model's reasoning effort if it has one."
        } else {
            message += " Try rephrasing your prompt."
        }
        return message
    }

    /// Prefix stamped onto a tool result that pass 1 of
    /// `elideOldToolOutputs` compressed verbatim. Both tells the model the
    /// text below is an information-dense extract, and lets the elision pass
    /// recognize outputs that must not be filtered a second time.
    static let compressedToolOutputMarker = "[Extract — filler words omitted, kept wording verbatim.]\n"

    /// Keeps a long tool-calling conversation inside a rough character budget.
    /// Two passes over the *oldest* tool results (the two most recent are
    /// always kept — those are what the model is actively working from):
    ///
    ///   1. When a compressor is configured (token filter or LLMLingua-2),
    ///      each large result is compressed *verbatim* — the model keeps
    ///      roughly `keepRate` of the words, in order, instead of losing
    ///      everything. Compressed outputs carry a marker so they are never
    ///      squeezed a second time on a later turn.
    ///   2. Any remaining overflow falls back to the original blunt
    ///      placeholder, oldest first.
    ///
    /// This is the in-loop counterpart to the chat's turn-level compaction:
    /// a single request can easily rack up 20 large `read_file` results
    /// across turns.
    /// Internal (not private) so the compression-first elision rules are
    /// directly testable, like the transcript-shaping helpers above.
    static func elideOldToolOutputs(
        in messages: inout [AIChatMessage],
        charBudget: Int,
        compressor: (any PromptCompressor)?,
        keepRate: Double
    ) async {
        func charCount(_ message: AIChatMessage) -> Int {
            switch message {
            case .system(let t), .user(let t), .assistantText(let t): return t.count
            case .assistantToolCalls(let calls): return calls.reduce(0) { $0 + $1.argumentsJSON.count + $1.name.count }
            case .toolResult(let r): return r.output.count
            }
        }

        var total = messages.reduce(0) { $0 + charCount($1) }
        guard total > charBudget else { return }

        let toolIndices = messages.indices.filter {
            if case .toolResult = messages[$0] { return true }
            return false
        }
        let protected = Set(toolIndices.suffix(2))

        // Pass 1 — verbatim compression, only while still over budget, so
        // later (fresher) results keep as much of their content as possible.
        if let compressor {
            for index in toolIndices where !protected.contains(index) {
                guard total > charBudget else { break }
                guard case .toolResult(let result) = messages[index] else { continue }
                // Tiny results aren't worth a pass; already-compressed ones
                // are never squeezed again (repeated filtering would degrade
                // them turn after turn).
                guard result.output.count > 800,
                      !result.output.hasPrefix(Self.compressedToolOutputMarker) else { continue }
                let isCode = PromptCompression.codeRatio(result.output) > 0.3
                let compressed = await compressor.compress(
                    result.output,
                    keepRate: keepRate,
                    forceTokens: [],
                    isCode: isCode
                )
                guard compressed.count < result.output.count else { continue }
                let replacement = Self.compressedToolOutputMarker + compressed
                total -= (result.output.count - replacement.count)
                messages[index] = .toolResult(AIToolResult(callID: result.callID, name: result.name, output: replacement))
            }
            guard total > charBudget else { return }
        }

        // Pass 2 — last resort: drop the whole output to a placeholder.
        for index in toolIndices where !protected.contains(index) {
            guard case .toolResult(let result) = messages[index] else { continue }
            let placeholder = "[\(result.output.count) characters of earlier \(result.name) output elided to stay within the context budget. Re-run the tool if you still need it.]"
            total -= (result.output.count - placeholder.count)
            messages[index] = .toolResult(AIToolResult(callID: result.callID, name: result.name, output: placeholder))
            if total <= charBudget { break }
        }
    }

    /// Sends one turn of a tool-calling conversation and returns either the
    /// model's final text or the tool calls it wants executed next. When
    /// `reasoningDelta` is non-nil the request is made with `"stream": true`
    /// and parsed event-by-event, forwarding reasoning fragments as they
    /// arrive; the returned step is the same either way.
    private func requestChatStep(ctx: ModelContext, messages: [AIChatMessage], tools: [MCPTool], maxTokens: Int, reasoningDelta: (@MainActor (String) -> Void)? = nil) async throws -> AIChatStep {
        let settings = AISettingsManager.shared
        guard let url = URL(string: ctx.chatEndpoint) else { throw AIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if ctx.isAnthropic {
            request.addValue(ctx.apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.addValue("Bearer \(ctx.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if ctx.source == .openRouter {
            request.addValue("TypstEdit", forHTTPHeaderField: "HTTP-Referer")
            request.addValue("TypstEdit", forHTTPHeaderField: "X-Title")
        }

        let streaming = reasoningDelta != nil
        request.httpBody = ctx.isAnthropic
            ? try Self.buildAnthropicBody(model: ctx.model, maxTokens: maxTokens, messages: messages, tools: tools, stream: streaming, reasoningEffort: ctx.reasoningEffort)
            : try Self.buildOpenAIBody(model: ctx.model, maxTokens: maxTokens, messages: messages, tools: tools, stream: streaming, includeReasoning: ctx.source == .openRouter, reasoningEffort: ctx.reasoningEffort)

        if !streaming {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                // No complete reply within the request timeout — funnel into
                // the same stall recovery as the streaming path below, so a
                // hung server costs a continue attempt instead of the turn.
                throw AIError.stalledResponse(
                    idleSeconds: Int(settings.timeoutSeconds),
                    timeoutSeconds: Int(Self.effectiveStallTimeout(from: settings.chatStallTimeoutSeconds))
                )
            } catch {
                // A cancelled task can surface as an arbitrary URLSession
                // error; normalize it so callers can tell a user-initiated
                // stop apart from a real failure.
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            guard let httpResponse = response as? HTTPURLResponse else { throw AIError.noData }

            guard httpResponse.statusCode == 200 else {
                var parsedErrorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                    parsedErrorMsg = msg
                }
                throw AIError.apiError("API Error (\(httpResponse.statusCode)): \(parsedErrorMsg)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError.parsingError("Invalid JSON structure returned by provider.")
            }

            return ctx.isAnthropic ? try Self.parseAnthropicStep(json) : try Self.parseOpenAIStep(json)
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError where error.code == .timedOut {
            // The server never even started responding within the request
            // timeout — same stall recovery as a mid-stream hang.
            throw AIError.stalledResponse(
                idleSeconds: Int(settings.timeoutSeconds),
                timeoutSeconds: Int(Self.effectiveStallTimeout(from: settings.chatStallTimeoutSeconds))
            )
        } catch {
            // Same normalization as the non-streaming path above.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw AIError.noData }

        guard httpResponse.statusCode == 200 else {
            // Read the (small) error body so streamed failures report the
            // same clean message the non-streaming path produces.
            let data = await Self.collectBytes(bytes, upTo: 1 << 20)
            var parsedErrorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                parsedErrorMsg = msg
            }
            throw AIError.apiError("API Error (\(httpResponse.statusCode)): \(parsedErrorMsg)")
        }

        // Streaming parse under a stall watchdog. Some local servers stop
        // emitting tokens mid-reply without ever closing the stream (seen
        // with large reasoning models like Qwen on slow hardware), which
        // would otherwise leave the chat panel on "Thinking…" forever. The
        // parse races a watchdog child task that polls a thread-safe
        // activity clock — touched on every received SSE line — and throws
        // `.stalledResponse` once the silence passes the configured stall
        // window. Losing the race cancels the parse (and with it the
        // underlying URLSession transfer), and `fetchCompletionWithTools`
        // can auto-continue from there.
        let stallTimeout = Self.effectiveStallTimeout(from: settings.chatStallTimeoutSeconds)
        let pollNanoseconds: UInt64 = 1_000_000_000
        let isAnthropic = ctx.isAnthropic
        let activity = StreamActivity()
        return try await withThrowingTaskGroup(of: AIChatStep.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: pollNanoseconds)
                    } catch {
                        // Cancelled because the parse won the race — exit
                        // quietly so the group can return its result.
                        return .finalText("", reasoning: nil)
                    }
                    if activity.isStalled(past: stallTimeout) {
                        throw AIError.stalledResponse(
                            idleSeconds: Int(activity.secondsSinceTouch),
                            timeoutSeconds: Int(stallTimeout)
                        )
                    }
                }
                return .finalText("", reasoning: nil)
            }
            group.addTask {
                try await isAnthropic
                    ? Self.parseAnthropicStreamingStep(bytes: bytes, onReasoningDelta: reasoningDelta!, onActivity: { activity.touch() })
                    : Self.parseOpenAIStreamingStep(bytes: bytes, onReasoningDelta: reasoningDelta!, onActivity: { activity.touch() })
            }
            guard let first = try await group.next() else { throw AIError.noData }
            group.cancelAll()
            return first
        }
    }

    /// The stall window actually enforced, with a floor so a zero/negative
    /// Settings value can't cancel every request the moment it starts.
    nonisolated private static func effectiveStallTimeout(from configured: Double) -> TimeInterval {
        max(5.0, configured)
    }

    // MARK: Reasoning effort (provider-specific request parameters)

    /// Applies the configured reasoning effort to an OpenAI-compatible body.
    ///
    /// - OpenAI: `reasoning_effort` (`none`/`low`/`medium`/`high`/`xhigh`).
    ///   A few models reject some values (e.g. `none` on certain GPT-6
    ///   models) — the API error surfaces to the user as usual.
    /// - OpenRouter: the `reasoning` object — `{enabled: false}` for off,
    ///   `{effort: ...}` otherwise.
    /// - Local OpenAI-compatible servers: best effort; most ignore unknown
    ///   parameters, so this is harmless for non-reasoning models.
    static func applyReasoningEffort(_ effort: ReasoningEffort, toOpenAI body: inout [String: Any], isOpenRouter: Bool) {
        guard effort != .auto else { return }
        if isOpenRouter {
            body["reasoning"] = effort == .none ? ["enabled": false] : ["effort": effort.rawValue]
        } else {
            body["reasoning_effort"] = effort.rawValue
        }
    }

    /// Applies the configured reasoning effort to an Anthropic body.
    ///
    /// Claude has no effort enum; the closest control is the extended
    /// thinking budget. `.none` sends `thinking: {type: disabled}`.
    /// Anthropic requires `budget_tokens < max_tokens`, so `max_tokens` is
    /// raised when the budget would exceed it.
    static func applyReasoningEffort(_ effort: ReasoningEffort, toAnthropic body: inout [String: Any]) {
        switch effort {
        case .auto:
            return
        case .none:
            body["thinking"] = ["type": "disabled"]
        default:
            let budget = effort.anthropicBudgetTokens
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            let currentMax = body["max_tokens"] as? Int ?? 0
            if currentMax <= budget {
                body["max_tokens"] = budget + 1024
            }
        }
    }

    /// Applies the configured reasoning effort to a Gemini body.
    ///
    /// - Gemini 2.5 and earlier: `thinkingBudget` (0 disables, a number caps).
    /// - Gemini 3/4: `thinkingLevel` (`low`/`medium`/`high`). Thinking cannot
    ///   be fully disabled there, so `.none` maps to `low`; `xhigh` maps to
    ///   `high` (the maximum level).
    static func applyReasoningEffort(_ effort: ReasoningEffort, model: String, toGemini body: inout [String: Any]) {
        guard effort != .auto else { return }
        let lowered = model.lowercased()
        let isLegacy = lowered.contains("gemini-2.") || lowered.contains("gemini-1.")
        var generationConfig = body["generationConfig"] as? [String: Any] ?? [:]
        switch effort {
        case .auto:
            return // unreachable — the guard above already returned
        case .none, .low, .medium, .high, .xhigh:
            if isLegacy {
                let budget: Int
                switch effort {
                case .none: budget = 0
                case .low: budget = 1_024
                case .medium: budget = 4_096
                case .high: budget = 8_192
                case .xhigh: budget = 16_384
                case .auto: budget = -1
                }
                generationConfig["thinkingBudget"] = budget
            } else {
                let level: String
                switch effort {
                case .none, .low: level = "low"
                case .medium: level = "medium"
                case .high, .xhigh: level = "high"
                case .auto: level = ""
                }
                generationConfig["thinkingLevel"] = level
            }
        }
        body["generationConfig"] = generationConfig
    }

    // MARK: Provider wire-format conversion (OpenAI-compatible)

    private static func buildOpenAIBody(model: String, maxTokens: Int, messages: [AIChatMessage], tools: [MCPTool], stream: Bool = false, includeReasoning: Bool = false, reasoningEffort: ReasoningEffort = .auto) throws -> Data {
        var wireMessages: [[String: Any]] = []
        for message in messages {
            switch message {
            case .system(let text):
                wireMessages.append(["role": "system", "content": text])
            case .user(let text):
                wireMessages.append(["role": "user", "content": text])
            case .assistantText(let text):
                wireMessages.append(["role": "assistant", "content": text])
            case .assistantToolCalls(let calls):
                wireMessages.append([
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": calls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.argumentsJSON]
                        ] as [String: Any]
                    }
                ])
            case .toolResult(let result):
                wireMessages.append([
                    "role": "tool",
                    "tool_call_id": result.callID,
                    "content": result.output
                ])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": wireMessages,
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "stream": stream
        ]
        // OpenRouter hides reasoning tokens behind an opt-in; without this its
        // models stream answers but never the thinking. Most other
        // OpenAI-compatible providers emit `reasoning_content` by default.
        if stream && includeReasoning {
            body["reasoning"] = ["enabled": true]
        }
        // A configured effort overrides the blanket opt-in above.
        Self.applyReasoningEffort(reasoningEffort, toOpenAI: &body, isOpenRouter: includeReasoning)
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.qualifiedName,
                        "description": tool.description,
                        "parameters": tool.inputSchema
                    ]
                ] as [String: Any]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func parseOpenAIStep(_ json: [String: Any]) throws -> AIChatStep {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw AIError.apiError(msg)
            }
            throw AIError.parsingError("OpenAI-compatible response missing message.")
        }

        let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String)

        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            let parsed: [AIToolCallRequest] = toolCalls.compactMap { call in
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { return nil }
                let arguments = function["arguments"] as? String ?? "{}"
                return AIToolCallRequest(id: id, name: name, argumentsJSON: arguments)
            }
            if !parsed.isEmpty { return .toolCalls(parsed, reasoning: reasoning) }
        }

        return .finalText(message["content"] as? String ?? "", reasoning: reasoning)
    }

    // MARK: Provider wire-format conversion (Anthropic)

    private static func buildAnthropicBody(model: String, maxTokens: Int, messages: [AIChatMessage], tools: [MCPTool], stream: Bool = false, reasoningEffort: ReasoningEffort = .auto) throws -> Data {
        var systemText = ""
        var wireMessages: [[String: Any]] = []

        for message in messages {
            switch message {
            case .system(let text):
                systemText = text
            case .user(let text):
                wireMessages.append(["role": "user", "content": [["type": "text", "text": text]]])
            case .assistantText(let text):
                wireMessages.append(["role": "assistant", "content": [["type": "text", "text": text]]])
            case .assistantToolCalls(let calls):
                wireMessages.append([
                    "role": "assistant",
                    "content": calls.map { call -> [String: Any] in
                        let argData = Data(call.argumentsJSON.utf8)
                        let input = (try? JSONSerialization.jsonObject(with: argData)) as? [String: Any] ?? [:]
                        return ["type": "tool_use", "id": call.id, "name": call.name, "input": input]
                    }
                ])
            case .toolResult(let result):
                wireMessages.append([
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": result.callID, "content": result.output]]
                ])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemText,
            "messages": wireMessages
        ]
        if stream {
            body["stream"] = true
        }
        Self.applyReasoningEffort(reasoningEffort, toAnthropic: &body)
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                ["name": tool.qualifiedName, "description": tool.description, "input_schema": tool.inputSchema]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func parseAnthropicStep(_ json: [String: Any]) throws -> AIChatStep {
        guard let contentArray = json["content"] as? [[String: Any]] else {
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw AIError.apiError(msg)
            }
            throw AIError.parsingError("Anthropic response missing content.")
        }

        let thinkingBlocks = contentArray.filter { ($0["type"] as? String) == "thinking" }
        let reasoning = thinkingBlocks.isEmpty ? nil : thinkingBlocks.compactMap { $0["thinking"] as? String }.joined(separator: "\n\n")

        let toolUses = contentArray.filter { ($0["type"] as? String) == "tool_use" }
        if !toolUses.isEmpty {
            let calls: [AIToolCallRequest] = toolUses.compactMap { block in
                guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                let input = block["input"] as? [String: Any] ?? [:]
                let argumentsJSON = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return AIToolCallRequest(id: id, name: name, argumentsJSON: argumentsJSON)
            }
            return .toolCalls(calls, reasoning: reasoning)
        }

        let text = contentArray.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String ?? ""
        return .finalText(text, reasoning: reasoning)
    }

    /// Reads up to `limit` bytes from a streamed response — used only to
    /// recover the (small) error body when a streaming request comes back
    /// with a non-200 status, since the main SSE parsers below assume a
    /// successful stream of `data:` lines.
    private static func collectBytes(_ bytes: URLSession.AsyncBytes, upTo limit: Int) async -> Data {
        var collected = Data()
        do {
            for try await byte in bytes {
                collected.append(byte)
                if collected.count >= limit { break }
            }
        } catch {
            // Whatever was read before the error is still useful for the message.
        }
        return collected
    }

    // MARK: Provider wire-format conversion (streaming / SSE)
    //
    // Only reached when the caller supplies `onReasoningDelta` (currently
    // just AI Chat): same request the non-streaming path above makes, but
    // with `"stream": true`, parsed event-by-event so reasoning fragments
    // reach the UI while the model is still working. Each function
    // accumulates fragments across the whole response and returns the same
    // `AIChatStep` shape its non-streaming counterpart does.

    private static func parseOpenAIStreamingStep(bytes: URLSession.AsyncBytes, onReasoningDelta: @MainActor (String) -> Void, onActivity: @Sendable () -> Void = {}) async throws -> AIChatStep {
        var text = ""
        var reasoning = ""
        // Tool-call deltas arrive as fragments keyed by `index`, with id,
        // name, and argument string each possibly split across many chunks.
        var fragments: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            onActivity()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw AIError.apiError(msg)
            }

            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }

            if let piece = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !piece.isEmpty {
                reasoning += piece
                onReasoningDelta(piece)
            }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
            }
            if let deltas = delta["tool_calls"] as? [[String: Any]] {
                for fragment in deltas {
                    let index = fragment["index"] as? Int ?? 0
                    var entry = fragments[index] ?? ("", "", "")
                    if let id = fragment["id"] as? String, !id.isEmpty { entry.id = id }
                    if let function = fragment["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                        if let piece = function["arguments"] as? String { entry.arguments += piece }
                    }
                    fragments[index] = entry
                }
            }
        }

        let calls: [AIToolCallRequest] = fragments.sorted { $0.key < $1.key }.compactMap { _, entry in
            guard !entry.id.isEmpty, !entry.name.isEmpty else { return nil }
            return AIToolCallRequest(id: entry.id, name: entry.name, argumentsJSON: entry.arguments.isEmpty ? "{}" : entry.arguments)
        }
        let stepReasoning = reasoning.isEmpty ? nil : reasoning
        if !calls.isEmpty { return .toolCalls(calls, reasoning: stepReasoning) }
        return .finalText(text, reasoning: stepReasoning)
    }

    private static func parseAnthropicStreamingStep(bytes: URLSession.AsyncBytes, onReasoningDelta: @MainActor (String) -> Void, onActivity: @Sendable () -> Void = {}) async throws -> AIChatStep {
        var text = ""
        var reasoning = ""
        var fragments: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            onActivity()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }

            switch json["type"] as? String {
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use",
                   let id = block["id"] as? String,
                   let name = block["name"] as? String,
                   let index = json["index"] as? Int {
                    fragments[index] = (id, name, "")
                }
            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "thinking_delta":
                    if let piece = delta["thinking"] as? String, !piece.isEmpty {
                        reasoning += piece
                        onReasoningDelta(piece)
                    }
                case "text_delta":
                    if let piece = delta["text"] as? String, !piece.isEmpty { text += piece }
                case "input_json_delta":
                    if let piece = delta["partial_json"] as? String, let index = json["index"] as? Int {
                        fragments[index]?.arguments += piece
                    }
                default:
                    break
                }
            case "error":
                if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                    throw AIError.apiError(msg)
                }
            default:
                break
            }
        }

        let calls: [AIToolCallRequest] = fragments.sorted { $0.key < $1.key }.compactMap { _, entry in
            guard !entry.id.isEmpty, !entry.name.isEmpty else { return nil }
            return AIToolCallRequest(id: entry.id, name: entry.name, argumentsJSON: entry.arguments.isEmpty ? "{}" : entry.arguments)
        }
        let stepReasoning = reasoning.isEmpty ? nil : reasoning
        if !calls.isEmpty { return .toolCalls(calls, reasoning: stepReasoning) }
        return .finalText(text, reasoning: stepReasoning)
    }

    // MARK: - Markdown → Typst conversion (AST pipeline)

    /// Converts Markdown (from AI output or pasted text) into Typst markup.
    ///
    /// Pipeline:
    ///   1. Pre-parse extraction — code spans, math, backslash escapes and
    ///      footnote definitions are lifted out of the raw text and replaced
    ///      with placeholder tokens, so cmark can neither mangle nor consume
    ///      them.
    ///   2. `Document(parsing:)` — a single CommonMark parse (smart punctuation
    ///      disabled so Typst strings and `--` survive verbatim).
    ///   3. `TypstMarkupVisitor` — one traversal serializes the AST into Typst.
    ///   4. Document-level post-passes carried over from the old pipeline.
    nonisolated func sanitizeMarkdownToTypst(_ text: String, isHybrid: Bool = false) -> String {
        var work = text.replacingOccurrences(of: "\r\n", with: "\n")

        // Translate literal documentation space characters (⋅ or ·) at line
        // starts into real spaces BEFORE parsing — several Markdown fixtures use
        // them as visible indentation for nested list items, and they must be
        // real indentation by the time cmark builds the list structure. (The old
        // pipeline ran this pass before its list-marker rewrites for the same
        // reason.)
        do {
            let processed = NSMutableString(string: work)
            for match in AICompletionRegex.docDot.matches(in: work, options: [], range: NSRange(0..<processed.length)).reversed() {
                let replaced = processed.substring(with: match.range)
                    .replacingOccurrences(of: "⋅", with: " ")
                    .replacingOccurrences(of: "·", with: " ")
                processed.replaceCharacters(in: match.range, with: replaced)
            }
            work = processed as String
        }

        // --- 1. PRE-PARSE EXTRACTION ---
        //
        // Each extracted region is replaced by a placeholder token built from
        // private-use Unicode scalars: cmark treats them as ordinary text that
        // no Markdown syntax (emphasis, tables, fences…) can bind to, and the
        // AST walk expands them back at the exact leaf position they came from.

        // Pick marker scalars guaranteed absent from the input so real text can
        // never be mistaken for a token.
        let markers = PlaceholderMarkers(for: work)
        // Indices are base-15 digits, so a token's VS digit run can be longer
        // than one — the scan must consume ALL of it (`+`), or a multi-digit
        // token would decode as its low digit and strand the rest in the text.
        let scan = try! NSRegularExpression(
            pattern: "[\(markers.codeText)\(markers.mathText)\(markers.escapeText)\(markers.typstText)][\(PlaceholderMarkers.vsStartText)-\(PlaceholderMarkers.vsEndText)]+"
        )

        // 1e (first, so its regions stay whole): hybrid `.note` Typst regions.
        //     A line whose first non-space character is `#` opens a Typst code
        //     region that continues while bracket depth is unclosed. cmark's
        //     indented-code-block rule otherwise shreds any 4+-space-indented
        //     line following a blank line, breaking multi-line function bodies
        //     inside the generated `.typ`. Runs before the other extractions so
        //     backticks, `$math$` and `\escapes` inside Typst code stay intact.
        var typstRegions: [String] = []
        if isHybrid {
            let extracted = Self.extractTypstRegions(work, marker: markers.typst)
            typstRegions = extracted.regions
            if !typstRegions.isEmpty {
                work = extracted.text
            }
        }

        // 1a. Fenced + inline code. Must be extracted before math so `$`-pairing
        //     can never see (or pair) dollars inside code spans.
        var codeRegions: [String] = []
        do {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.codeBlock.matches(in: work, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                codeRegions.append(processed.substring(with: match.range))
                processed.replaceCharacters(in: match.range, with: PlaceholderMarkers.token(kind: markers.code, index: codeRegions.count - 1))
            }
            work = processed as String
        }

        // 1b. Math ($$…$$, $…$, \[…\], \(…\)). The LaTeX payload is converted to
        //     Typst math up front; expansion wraps it in `$ … $`.
        var mathRegions: [(raw: String, typst: String)] = []
        do {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.mathBlock.matches(in: work, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let raw = processed.substring(with: match.range)
                let latex = Self.strippedMathDelimiters(raw)
                mathRegions.append((raw, LyxToTypstConverter.convertLatexMathToTypst(latex)))
                processed.replaceCharacters(in: match.range, with: PlaceholderMarkers.token(kind: markers.math, index: mathRegions.count - 1))
            }
            work = processed as String
        }

        // 1c. Backslash-escaped punctuation (\$, \#, \{…). cmark consumes these
        //     escapes, but the old pipeline preserved them verbatim — and the
        //     `.note` pre-pass (`delimitImproperOperators`) relies on that. Lift
        //     them out and restore them verbatim at their leaf position.
        var escapeRegions: [String] = []
        do {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.backslashEscape.matches(in: work, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                escapeRegions.append(processed.substring(with: match.range))
                processed.replaceCharacters(in: match.range, with: PlaceholderMarkers.token(kind: markers.escape, index: escapeRegions.count - 1))
            }
            work = processed as String
        }

        // 1d. Footnote definitions (`[^id]: text`). cmark would eat these as
        //     link reference definitions; removing them up front leaves the
        //     `[^id]` references as literal text that the leaf converter turns
        //     into `#footnote[…]` carrying the stored body.
        var footnoteDefs: [String: String] = [:]
        do {
            let processed = NSMutableString(string: work)
            let matches = AICompletionRegex.fnDef.matches(in: work, options: [], range: NSRange(0..<processed.length))
            for match in matches.reversed() {
                let id = processed.substring(with: match.range(at: 1))
                let body = processed.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                footnoteDefs[id] = body
                processed.replaceCharacters(in: match.range, with: "")
            }
            work = processed as String
        }

        // --- 2. PARSE ---
        // Smart punctuation must stay off: it would rewrite "…" into curly
        // quotes and `--` into dashes, corrupting Typst strings in `.note` files.
        let document = Document(parsing: work, options: [.disableSmartOpts, .disableSourcePosOpts])

        // --- 3. WALK ---
        var visitor = TypstMarkupVisitor(
            isHybrid: isHybrid,
            codeRegions: codeRegions,
            mathRegions: mathRegions,
            escapeRegions: escapeRegions,
            typstRegions: typstRegions,
            footnoteDefs: footnoteDefs,
            markers: markers,
            placeholderScan: scan
        )
        var result = visitor.visit(document)

        // --- 4. POST-PASSES (document level, carried over from the old pipeline) ---

        // Escape Markdown abbreviation definitions (`*[Abbr]: …`).
        result = Self.replace(AICompletionRegex.markdownAbbr, in: result, template: "\\\\*[$1]:")

        // Un-escape characters inside Typst string parameters — string literals
        // don't process markup escapes, so `\_` there is a literal backslash.
        do {
            let processed = NSMutableString(string: result)
            for match in AICompletionRegex.stringLiteral.matches(in: result, options: [], range: NSRange(0..<processed.length)).reversed() {
                let unescaped = processed.substring(with: match.range)
                    .replacingOccurrences(of: "\\_", with: "_")
                    .replacingOccurrences(of: "\\*", with: "*")
                    .replacingOccurrences(of: "\\#", with: "#")
                    .replacingOccurrences(of: "\\`", with: "`")
                processed.replaceCharacters(in: match.range, with: unescaped)
            }
            result = processed as String
        }

        return result
    }

    /// Strips the surrounding math delimiters ($$, $, \[…\], \(…\)) from an
    /// extracted math region, leaving the raw LaTeX payload.
    nonisolated private static func strippedMathDelimiters(_ raw: String) -> String {
        if raw.hasPrefix("$$") && raw.hasSuffix("$$") && raw.count >= 4 {
            return String(raw.dropFirst(2).dropLast(2))
        }
        if raw.hasPrefix("\\[") && raw.hasSuffix("\\]") && raw.count >= 4 {
            return String(raw.dropFirst(2).dropLast(2))
        }
        if raw.hasPrefix("\\(") && raw.hasSuffix("\\)") && raw.count >= 4 {
            return String(raw.dropFirst(2).dropLast(2))
        }
        if raw.hasPrefix("$") && raw.hasSuffix("$") && raw.count >= 2 {
            return String(raw.dropFirst(1).dropLast(1))
        }
        return raw
    }

    /// Helper to safely apply a precompiled regex replacement.
    nonisolated private static func replace(_ regex: NSRegularExpression, in s: String, template: String) -> String {
        regex.stringByReplacingMatches(in: s, options: [], range: NSRange(0..<(s as NSString).length), withTemplate: template)
    }

    // MARK: - Video Link Helpers

    /// Extracts the 11-character video ID from any common YouTube URL shape:
    /// `youtube.com/watch?v=ID`, `youtu.be/ID`, `youtube.com/embed/ID`,
    /// `youtube.com/shorts/ID`, `m.youtube.com/...`, etc.
    /// Returns nil if `url` doesn't look like a YouTube link.
    /// True when `line`'s leading `#` is Typst code the hybrid escaper would
    /// preserve (so the line can open an extraction region): `#let`, `#show`,
    /// `#{…}`, `#table(`, `#obj.field`. False for ATX headings (`## h2`),
    /// stray hashes (`# note`) and hashtag-shaped text (`#refs,`) — those the
    /// hybrid escaper escapes, so they stay Markdown. Mirrors
    /// `AICompletionRegex.hybridHash`'s punctuation lookahead.
    nonisolated static func isTypstRegionOpener(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.first == "#" else { return false }
        let after = trimmed.dropFirst()
        guard let next = after.first else { return false }  // lone "#" → stray
        if next == " " || next == "\t" || next == "#" { return false }  // stray / ATX
        guard next.isLetter else { return true }  // `#{`, `#(`, `#3`, `#"` → code
        // Ident run; inspect what follows it (hybridHash's lookahead set).
        var rest = after
        while let c = rest.first, c.isLetter || c.isNumber || c == "_" {
            rest = rest.dropFirst()
        }
        guard let follower = rest.first else { return true }  // `#ident` → kept
        if ",!?;:".contains(follower) { return false }  // hashtag punctuation
        if follower == "." {
            let afterDot = rest.dropFirst().first
            if afterDot == nil || afterDot == " " || afterDot == "\t" { return false }
            return true  // `#obj.field` → code
        }
        return true
    }

    /// Lifts whole Typst code regions out of hybrid `.note` text before the
    /// CommonMark parse (step 1e). A region opens where `isTypstRegionOpener`
    /// holds and continues while its bracket depth is unclosed. Depth counting
    /// respects `"strings"` (with `\"` escapes), `//` line comments and
    /// `/* */` block comments. Extraction is idempotent: re-running on
    /// already-sanitized text re-extracts the same regions.
    nonisolated static func extractTypstRegions(_ text: String, marker: Unicode.Scalar) -> (text: String, regions: [String]) {
        var lines = text.components(separatedBy: "\n")
        var regions: [String] = []
        var index = 0
        var insideFence = false
        let regionLineCap = 500

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks are Markdown, not live Typst — skip wholesale.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                index += 1
                continue
            }
            guard !insideFence else {
                index += 1
                continue
            }

            // Region opener: the complement of the hybrid escaper's escape set.
            guard isTypstRegionOpener(line) else {
                index += 1
                continue
            }
            let hashIndex = line.firstIndex(of: "#")!

            // Walk forward line by line, tracking depth until it returns to zero
            // (or the 500-line safety cap so one unbalanced brace can't swallow
            // the document).
            var depth = 0
            var inString = false
            var inBlockComment = false
            var end = index
            while true {
                let lineText = lines[end]
                var pos = (end == index) ? hashIndex : lineText.startIndex
                var inLineComment = false
                while pos < lineText.endIndex {
                    let ch = lineText[pos]
                    if inLineComment { break }
                    if inString {
                        if ch == "\\" {
                            pos = lineText.index(after: pos)   // skip escaped char
                        } else if ch == "\"" {
                            inString = false
                        }
                    } else if inBlockComment {
                        if ch == "/" {
                            // possible "*/"; the next loop iteration sees the "/"
                            // as a normal char — handle explicitly:
                            let next = lineText.index(after: pos)
                            if next < lineText.endIndex, lineText[next] == "*" {
                                // this "/" belongs to an opener; fall through
                            }
                        }
                        if ch == "*" {
                            let next = lineText.index(after: pos)
                            if next < lineText.endIndex, lineText[next] == "/" {
                                inBlockComment = false
                                pos = lineText.index(after: pos)
                            }
                        }
                    } else {
                        switch ch {
                        case "\"":
                            inString = true
                        case "/":
                            let next = lineText.index(after: pos)
                            if next < lineText.endIndex, lineText[next] == "/" {
                                // Only a comment when it starts the line or
                                // follows whitespace — `https://` in link text
                                // must not hide the line's closing brackets
                                // (an unclosed `[` made the region swallow the
                                // rest of the note, landing pagebreaks inside
                                // the link's container).
                                let isCommentStart = pos == lineText.startIndex
                                    || lineText[lineText.index(before: pos)] == " "
                                    || lineText[lineText.index(before: pos)] == "\t"
                                if isCommentStart {
                                    inLineComment = true
                                }
                            } else if next < lineText.endIndex, lineText[next] == "*" {
                                inBlockComment = true
                                pos = lineText.index(after: pos)
                            }
                        case "(", "[", "{":
                            depth += 1
                        case ")", "]", "}":
                            depth -= 1
                        default:
                            break
                        }
                    }
                    pos = lineText.index(after: pos)
                }
                if depth <= 0 || end + 1 >= min(lines.count, index + regionLineCap) {
                    break
                }
                end += 1
            }

            // cmark lazy-continues a column-0 line into a preceding list
            // item's paragraph, which pulled region tokens (and their
            // expansions — images, pagebreaks) inside the list container
            // (typst: "pagebreaks are not allowed inside of containers").
            // A blank line closes the open block so the token starts fresh.
            if index > 0, !lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("", at: index)
                index += 1
                end += 1
            }
            regions.append(lines[index...end].joined(separator: "\n"))
            lines.replaceSubrange(
                index...end,
                with: [PlaceholderMarkers.token(kind: marker, index: regions.count - 1)]
            )
            // The region's lines collapsed into one token, so `index` now names
            // the token itself in the shortened array — the next candidate line
            // is `index + 1`. Advancing to the OLD `end + 1` would skip
            // (region line count − 1) real lines, dropping openers that follow
            // a multi-line region (a layout function swallowed every `#if`
            // block after it).
            index += 1
        }

        return (lines.joined(separator: "\n"), regions)
    }

    nonisolated static func extractYouTubeID(from url: String) -> String? {
        // Normalise HTML entities so `&amp;v=` works the same as `&v=`.
        let cleaned = url.replacingOccurrences(of: "&amp;", with: "&")
        let nsText = cleaned as NSString
        guard let match = AICompletionRegex.youtubeID.firstMatch(in: cleaned, options: [], range: NSRange(0..<nsText.length)) else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    /// Extracts the numeric video ID from a Vimeo URL (`vimeo.com/123456`,
    /// `player.vimeo.com/video/123456`). Returns nil otherwise.
    nonisolated static func extractVimeoID(from url: String) -> String? {
        let nsText = url as NSString
        guard let match = AICompletionRegex.vimeoID.firstMatch(in: url, options: [], range: NSRange(0..<nsText.length)) else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    /// Escapes a string for safe inclusion inside a Typst string literal `"..."`.
    nonisolated static func escapeTypstString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Wraps a video URL in a Typst clickable thumbnail embed.
    /// For YouTube we can derive a free thumbnail from `img.youtube.com`; for other hosts
    /// we just produce a styled text link with a play marker so the link is still obvious.
    nonisolated static func videoEmbed(for url: String, alt: String) -> String {
        let escapedAlt = escapeTypstString(alt)
        if let ytID = extractYouTubeID(from: url) {
            let thumb = "https://img.youtube.com/vi/\(ytID)/hqdefault.jpg"
            return "#link(\"\(url)\")[#image(\"\(thumb)\", alt: \"\(escapedAlt)\")]"
        }
        // Vimeo doesn't expose a free public thumbnail URL, so render a clearly-clickable
        // text link instead. The user can swap in their own image if desired.
        return "#link(\"\(url)\")[▶ \(alt)]"
    }
}

// MARK: - Placeholder Tokens

/// Placeholder tokens mark the spots where pre-extracted regions (code, math,
/// backslash escapes) used to live. A token is one marker scalar from a
/// private-use block plus base-15 index digits encoded in variation selectors —
/// whitespace-free, punctuation-free characters that cmark passes through as
/// plain text and that no Markdown syntax can bind to.
struct PlaceholderMarkers: Sendable {
    let code: Unicode.Scalar
    let math: Unicode.Scalar
    let escape: Unicode.Scalar
    let typst: Unicode.Scalar

    static let vsStart: UInt32 = 0xFE00
    static let vsEnd: UInt32 = 0xFE0E   // inclusive; 15 usable selectors

    static var vsStartText: String { String(Unicode.Scalar(vsStart)!) }
    static var vsEndText: String { String(Unicode.Scalar(vsEnd)!) }

    /// Picks four marker scalars that don't occur anywhere in `text`.
    init(for text: String) {
        var base: UInt32 = 0xE000
        while true {
            let inUse = text.unicodeScalars.contains { $0.value >= base && $0.value < base + 4 }
            if !inUse {
                code = Unicode.Scalar(base)!
                math = Unicode.Scalar(base + 1)!
                escape = Unicode.Scalar(base + 2)!
                typst = Unicode.Scalar(base + 3)!
                return
            }
            base += 4
        }
    }

    var codeText: String { String(code) }
    var mathText: String { String(math) }
    var escapeText: String { String(escape) }
    var typstText: String { String(typst) }

    /// Builds a token of `kind` carrying `index`.
    static func token(kind: Unicode.Scalar, index: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(kind)
        var i = UInt32(index)
        repeat {
            scalars.append(Unicode.Scalar(Self.vsStart + i % 15)!)
            i /= 15
        } while i > 0
        return String(scalars)
    }

    /// Decodes a token back into its kind and index. Returns nil for anything
    /// that isn't a well-formed token.
    func decode(_ token: String) -> (kind: Unicode.Scalar, index: Int)? {
        var it = token.unicodeScalars.makeIterator()
        guard let first = it.next(), first == code || first == math || first == escape || first == typst else { return nil }
        // `token(_ index:)` writes digits least-significant first, so the
        // positional weight grows with each further selector.
        var index: UInt32 = 0
        var weight: UInt32 = 1
        var digits = 0
        while let s = it.next() {
            guard s.value >= Self.vsStart, s.value <= Self.vsEnd else { return nil }
            index += (s.value - Self.vsStart) * weight
            weight *= 15
            digits += 1
        }
        guard digits > 0 else { return nil }
        return (first, Int(index))
    }
}

// MARK: - TypstMarkupVisitor

/// Serializes a swift-markdown AST into Typst markup in a single traversal.
///
/// Every method returns a freshly-built fragment; block-level containers join
/// their children with blank lines and inline containers concatenate, so the
/// whole document is produced in O(N) without intermediate string rewrites.
///
/// Escaping happens only at `Text` leaves, and only on the plain-text segments
/// of those leaves — Typst syntax this visitor emits (links, tables, footnotes,
/// placeholder expansions) is assembled after escaping and can never be
/// damaged by it.
struct TypstMarkupVisitor: MarkupVisitor {
    typealias Result = String

    let isHybrid: Bool
    let codeRegions: [String]
    let mathRegions: [(raw: String, typst: String)]
    let escapeRegions: [String]
    /// Hybrid-only: whole Typst code regions lifted pre-parse so cmark can
    /// neither shred their indentation nor bind to their punctuation.
    let typstRegions: [String]
    let footnoteDefs: [String: String]
    let markers: PlaceholderMarkers
    let placeholderScan: NSRegularExpression

    /// Guards footnote-body / HTML-inner recursive conversions.
    var recursionDepth = 0

    /// Bracket-wrapping HTML tags (`<mark>`, `<a href>`, …) whose closer hasn't
    /// arrived yet. Saved/restored per inline container so a tag opened inside
    /// one paragraph can never leak into the next.
    struct PendingHTMLClose {
        let tag: String
        let closer: String
    }
    var openHTMLTags: [PendingHTMLClose] = []

    /// Marker used for the list item currently being rendered.
    private var listMarker = "- "

    private static let parseOptions: ParseOptions = [.disableSmartOpts, .disableSourcePosOpts]

    // MARK: Fallback

    /// Unhandled nodes concatenate their children inline.
    mutating func defaultVisit(_ markup: Markup) -> String {
        var out = ""
        for child in markup.children { out += visit(child) }
        return out
    }

    // MARK: Blocks

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined(separator: "\n\n")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        renderInline(paragraph.children)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        String(repeating: "=", count: heading.level) + " " + renderInline(heading.children)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        let inner = blockQuote.children.map { visit($0) }.joined(separator: "\n\n")
        return "#quote[\n" + inner + "\n]"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "#line(length: 100%)"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let code = expandRaw(codeBlock.code)
        // Only keep safe characters in the fence info so the raw block can't be
        // broken open by a crafted language string.
        let lang = String((codeBlock.language ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: code) + 1))
        return fence + lang + "\n" + code + (code.hasSuffix("\n") || code.isEmpty ? "" : "\n") + fence
    }

    // MARK: Lists

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        let saved = listMarker
        listMarker = "- "
        // `listItems` is a lazy sequence whose `map` is escaping — materialize
        // into an Array so the eager (non-escaping) map can mutate self.
        let out = Array(list.listItems).map { visit($0) }.joined(separator: "\n")
        listMarker = saved
        return out
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let saved = listMarker
        listMarker = "+ "
        let out = Array(list.listItems).map { visit($0) }.joined(separator: "\n")
        listMarker = saved
        return out
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        // Task-list items override the marker with a native checkbox glyph.
        var marker = listMarker
        if let checkbox = listItem.checkbox {
            marker = checkbox == .checked ? "- ☑ " : "- ☐ "
        }
        let inner = listItem.children.map { visit($0) }.joined(separator: "\n")
        // Indent continuation lines (loose items, nested lists) to the marker
        // width so Typst keeps them inside the item's lazy continuation.
        let pad = String(repeating: " ", count: marker.count)
        let lines = inner.components(separatedBy: "\n")
        let indented = lines.enumerated().map { line -> String in
            line.offset == 0 || line.element.isEmpty ? line.element : pad + line.element
        }.joined(separator: "\n")
        return marker + indented
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) -> String {
        // `cells` is a lazy sequence — materialize before the eager map/count.
        let headerCells = Array(table.head.cells).map { renderInline($0.children) }
        let columns = max(headerCells.count, 1)

        var out = "#table(\n"
        out += "  columns: \(columns),\n"

        let alignments = table.columnAlignments
        if alignments.contains(where: { $0 != nil }) {
            let names = (0..<columns).map { idx -> String in
                guard idx < alignments.count, let alignment = alignments[idx] else { return "auto" }
                switch alignment {
                case .left: return "left"
                case .center: return "center"
                case .right: return "right"
                }
            }
            out += "  align: (\(names.joined(separator: ", "))),\n"
        }

        out += "  table.header(\n"
        for cell in headerCells.prefix(columns) {
            out += "    \(Self.cellBlock(cell)),\n"
        }
        out += "  ),\n"

        for row in table.body.children {
            var rendered = (row as? Table.Row)?.cells.prefix(columns).map { renderInline($0.children) } ?? [String]()
            while rendered.count < columns { rendered.append("") }
            for cell in rendered {
                out += "  \(Self.cellBlock(cell)),\n"
            }
        }

        out += ")"
        return out
    }

    /// Wraps a rendered cell in a content block. Typst tracks `[...]` depth, so
    /// nested literal brackets render correctly; only a dangling trailing
    /// backslash needs doubling so it can't escape the closing bracket.
    private static func cellBlock(_ content: String) -> String {
        var result = content
        while result.hasSuffix("\\") && !result.hasSuffix("\\\\") {
            result += "\\"
        }
        return "[" + result + "]"
    }

    // MARK: Inline containers

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        // `_*x*_` parses as emphasis-in-emphasis. Emitting `__x__` is a Typst
        // warning (no text within underscores) that does nothing, so the inner
        // level becomes strong, which is what Typst's `_*x*_` means.
        let inner = emphasis.children.map { $0 as? Emphasis }
        if emphasis.childCount == 1, let nested = inner.first ?? nil {
            return "_*" + renderInline(nested.children) + "*_"
        }
        return "_" + renderInline(emphasis.children) + "_"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "*" + renderInline(strong.children) + "*"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "#strike[" + renderInline(strikethrough.children) + "]"
    }

    mutating func visitLink(_ link: Link) -> String {
        let destination = link.destination ?? ""
        let inner = renderInline(link.children)

        // `[text]()` — an explicitly empty destination — must not become
        // `#link("")[text]`: Typst rejects an empty URL outright ("URL must
        // not be empty"). The text alone is the faithful rendering.
        guard !destination.isEmpty else {
            return inner
        }
        let escapedDestination = AICompletionService.escapeTypstString(destination)

        // Links to known video hosts become clickable thumbnail embeds so a
        // single Markdown link renders as a full video preview. If the body is
        // already an image (e.g. `[![thumb](…)](url)`), keep it as-is instead of
        // injecting a second one.
        if AICompletionService.extractYouTubeID(from: destination) != nil {
            if inner.contains("#image(") {
                return "#link(\"\(escapedDestination)\")[\(inner)]"
            }
            return AICompletionService.videoEmbed(for: destination, alt: inner)
        }

        // Angle-bracket autolinks (`<https://…>`) render as bare links — except
        // video hosts, which get the embed treatment like the old pipeline did.
        if link.isAutolink {
            let host = destination.lowercased()
            if host.contains("youtube.com") || host.contains("youtu.be") {
                return AICompletionService.videoEmbed(for: destination, alt: "YouTube video")
            }
            if host.contains("vimeo.com") {
                return AICompletionService.videoEmbed(for: destination, alt: "Vimeo video")
            }
            return "#link(\"\(escapedDestination)\")"
        }

        return "#link(\"\(escapedDestination)\")[\(inner)]"
    }

    mutating func visitImage(_ image: Image) -> String {
        guard let source = image.source, !source.isEmpty else {
            return renderInline(image.children)
        }
        // Alt text stays plain, exactly like the old raw attribute handling.
        let alt = Self.plainText(of: image)
        let formatted = source.lowercased().hasPrefix("http") || source.hasPrefix("/") || source.hasPrefix("data:")
            ? source
            : "/" + source
        return "#image(\"\(AICompletionService.escapeTypstString(formatted))\", alt: \"\(AICompletionService.escapeTypstString(alt))\")"
    }

    // MARK: Leaves

    mutating func visitText(_ text: Text) -> String {
        var out = ""
        let s = text.string
        let ns = s as NSString
        var cursor = 0
        for match in placeholderScan.matches(in: s, options: [], range: NSRange(0..<ns.length)) {
            if match.range.location > cursor {
                out += convertPlainInline(ns.substring(with: NSRange(cursor..<match.range.location)))
            }
            let token = ns.substring(with: match.range)
            if let expansion = expandToken(token) {
                out += expansion
            } else {
                // Unknown token (shouldn't happen) — treat it as plain text.
                out += convertPlainInline(token)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += convertPlainInline(ns.substring(from: cursor))
        }
        return out
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        Self.rawSpan(expandRaw(inlineCode.code))
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "\\\n"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        emitHTMLTag(inlineHTML.rawHTML)
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> String {
        let raw = htmlBlock.rawHTML
        let savedTags = openHTMLTags
        openHTMLTags = []

        var out = ""
        let ns = raw as NSString
        var cursor = 0
        for match in AICompletionRegex.htmlToken.matches(in: raw, options: [], range: NSRange(0..<ns.length)) {
            if match.range.location > cursor {
                out += convertHTMLInnerText(ns.substring(with: NSRange(cursor..<match.range.location)))
            }
            out += emitHTMLTag(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += convertHTMLInnerText(ns.substring(from: cursor))
        }
        // Close anything the fragment left open, then restore the outer stack.
        while let pending = openHTMLTags.popLast() {
            out += pending.closer
        }
        openHTMLTags = savedTags
        return out
    }

    // MARK: Placeholder expansion

    /// Expands a token at an inline (markup) position: code comes back
    /// verbatim, math comes back converted and wrapped in `$ … $`, backslash
    /// escapes come back verbatim.
    private func expandToken(_ token: String) -> String? {
        guard let decoded = markers.decode(token) else { return nil }
        if decoded.kind == markers.code {
            guard decoded.index < codeRegions.count else { return nil }
            return codeRegions[decoded.index]
        }
        if decoded.kind == markers.math {
            guard decoded.index < mathRegions.count else { return nil }
            return "$ \(mathRegions[decoded.index].typst) $"
        }
        if decoded.kind == markers.typst {
            guard decoded.index < typstRegions.count else { return nil }
            return typstRegions[decoded.index]
        }
        guard decoded.index < escapeRegions.count else { return nil }
        return escapeRegions[decoded.index]
    }

    /// Expands a token inside raw contexts (code blocks/spans): everything comes
    /// back verbatim, including the original math delimiters.
    private func expandRaw(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in placeholderScan.matches(in: s, options: [], range: NSRange(0..<ns.length)) {
            if match.range.location > cursor {
                out += ns.substring(with: NSRange(cursor..<match.range.location))
            }
            let token = ns.substring(with: match.range)
            if let decoded = markers.decode(token) {
                if decoded.kind == markers.code, decoded.index < codeRegions.count {
                    out += codeRegions[decoded.index]
                } else if decoded.kind == markers.math, decoded.index < mathRegions.count {
                    out += mathRegions[decoded.index].raw
                } else if decoded.kind == markers.typst, decoded.index < typstRegions.count {
                    out += typstRegions[decoded.index]
                } else if decoded.kind == markers.escape, decoded.index < escapeRegions.count {
                    out += escapeRegions[decoded.index]
                }
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }

    // MARK: Plain-text leaf conversion

    /// Converts one run of plain leaf text: applies the special conversions
    /// that emit Typst syntax (footnote refs, bare video URLs) as typed
    /// segments, then escapes only the remaining plain segments.
    private mutating func convertPlainInline(_ s: String) -> String {
        guard !s.isEmpty else { return s }

        var segments: [(typst: Bool, text: String)] = [(false, s)]

        // Bare video URLs on their own line → clickable thumbnail embeds, so
        // pasting a YouTube/Vimeo URL in body text renders a preview.
        segments = Self.explode(segments, regex: AICompletionRegex.bareVideo) { match, ns in
            let url = ns.substring(with: match.range(at: 1))
            let alt = url.lowercased().contains("vimeo") ? "Vimeo video" : "YouTube video"
            return AICompletionService.videoEmbed(for: url, alt: alt)
        }

        // Footnote references `[^id]` → `#footnote[body]`. References without a
        // definition are escaped so they can't be mistaken for Typst content.
        if !footnoteDefs.isEmpty {
            var mutableSelf = self
            segments = Self.explode(segments, regex: AICompletionRegex.fnRef) { match, ns in
                let id = ns.substring(with: match.range(at: 1))
                if let body = mutableSelf.footnoteDefs[id] {
                    return "#footnote[\(mutableSelf.convertedFootnoteBody(body))]"
                }
                return "\\\\[\\\\^\(id)\\\\]"
            }
        }

        // Inline footnotes `^[text]` → `#footnote[text]`.
        segments = Self.explode(segments, regex: AICompletionRegex.fnInline) { match, ns in
            let inner = ns.substring(with: match.range(at: 1))
            return "#footnote[\(self.escapeText(inner))]"
        }

        var out = ""
        for segment in segments {
            out += segment.typst ? segment.text : escapeText(segment.text)
        }
        return out
    }

    /// Splits plain segments on `regex`, replacing each match via `transform`.
    /// A nil transform result keeps the match as plain text. Typst segments are
    /// never re-scanned.
    private static func explode(
        _ segments: [(typst: Bool, text: String)],
        regex: NSRegularExpression,
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> [(typst: Bool, text: String)] {
        var out: [(typst: Bool, text: String)] = []
        for segment in segments {
            if segment.typst {
                out.append(segment)
                continue
            }
            let ns = segment.text as NSString
            let matches = regex.matches(in: segment.text, options: [], range: NSRange(0..<ns.length))
            if matches.isEmpty {
                out.append(segment)
                continue
            }
            var cursor = 0
            for match in matches {
                if match.range.location > cursor {
                    out.append((false, ns.substring(with: NSRange(cursor..<match.range.location))))
                }
                if let replacement = transform(match, ns) {
                    out.append((true, replacement))
                } else {
                    out.append((false, ns.substring(with: match.range)))
                }
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                out.append((false, ns.substring(from: cursor)))
            }
        }
        return out
    }

    /// Recursively converts a footnote body so markdown inside definitions
    /// (bold, links, math placeholders…) is formatted like the old pipeline's
    /// inline insertion was. Depth-limited against self-referencing footnotes.
    private mutating func convertedFootnoteBody(_ raw: String) -> String {
        guard recursionDepth < 3 else { return escapeText(raw) }
        var sub = self
        sub.recursionDepth += 1
        let document = Document(parsing: raw, options: Self.parseOptions)
        var out = sub.visit(document)
        while let pending = sub.openHTMLTags.popLast() {
            out += pending.closer
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Escaping

    /// Escapes plain text so it renders literally under Typst.
    ///
    /// Pure Markdown mode (AI completions, .md files) escapes `$`, `#` and `@`
    /// wholesale so Typst features can't fire accidentally. Hybrid mode (.note)
    /// leaves isolated `#`/`@`/`$` alone so legitimate Typst (`#let`, `$math$`,
    /// `@ref`) executes, and only escapes the patterns that look like pasted
    /// Markdown (`$1600`, `user@email.com`, `#refs,`). The `(?<!\\)` guards keep
    /// this idempotent with `TypstCompiler.delimitImproperOperators`.
    ///
    /// Precondition: `s` contains no pre-extracted tokens — callers split those
    /// out first so this can never escape generated Typst syntax.
    func escapeText(_ s: String) -> String {
        // A stray backtick ALWAYS crashes Typst as an unclosed raw block; valid
        // code was already extracted pre-parse, so any backtick here is stray.
        var out = Self.replace(AICompletionRegex.strayBacktick, in: s, template: "\\\\`")
        // Escape leftover HTML tags so they can't parse as Typst labels. The
        // negative lookahead preserves valid Typst labels `<label>`.
        out = Self.replace(AICompletionRegex.escapeHtmlTags, in: out, template: "\\\\<$1\\\\>")
        if !isHybrid {
            // Escape underscores in technical terms/filenames. In hybrid mode
            // Typst handles `my_variable` natively and `_italics_` is native
            // italic, so escaping there would break valid Typst syntax.
            out = Self.replace(AICompletionRegex.technicalUnderscore, in: out, template: "\\\\_")
            out = Self.replace(AICompletionRegex.literalDollar, in: out, template: "\\\\$")
            out = Self.replace(AICompletionRegex.literalHash, in: out, template: "\\\\#")
            out = Self.replace(AICompletionRegex.literalAt, in: out, template: "\\\\@")
        } else {
            // Escape dollars followed by a digit (`$1600`) to prevent unclosed
            // math, but leave real math (`$E=mc^2$`) alone.
            out = Self.replace(AICompletionRegex.hybridDollarDigit, in: out, template: "\\\\$")
            // Escape `@` glued to a word (email addresses) or followed by space;
            // Typst references (`@fig1`) have a space before and letters after.
            out = Self.replace(AICompletionRegex.hybridAt, in: out, template: "\\\\@")
            // `#word` followed by sentence punctuation isn't a Typst call (no
            // `(` / `[` / `.` continuation) — escape it so it renders literally
            // instead of erroring on an unknown variable. Real Typst
            // continuations are preserved by the negative lookahead.
            out = Self.replace(AICompletionRegex.hybridHash, in: out, template: "\\\\#$1")
            out = Self.replace(AICompletionRegex.hybridStrayHash, in: out, template: "\\\\#")
        }
        return out
    }

    // MARK: HTML fragments

    /// Emits Typst for one HTML token (comment, open tag, close tag).
    /// Bracket wrappers push onto `openHTMLTags`; their closers are emitted
    /// when the matching close arrives, or flushed at the end of the enclosing
    /// container so a stray opener can never leave an unbalanced `[` behind.
    private mutating func emitHTMLTag(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let ns = trimmed as NSString
        guard let match = AICompletionRegex.htmlToken.firstMatch(in: trimmed, options: [], range: NSRange(0..<ns.length)),
              match.range.location == 0, match.range.length == ns.length else {
            return trimmed.hasPrefix("<!--") ? "" : Self.escapeHTMLTagText(trimmed)
        }

        // Comments disappear.
        guard match.range(at: 2).location != NSNotFound else { return "" }

        // `(/?)` matches the empty string at position 0 for opening tags, so
        // test the group's LENGTH, not its location (location is only
        // NSNotFound for non-participating groups).
        let isClosing = match.range(at: 1).length > 0
        let name = ns.substring(with: match.range(at: 2)).lowercased()

        if isClosing {
            switch name {
            case "a", "p", "mark", "sub", "sup", "u", "del", "s", "strike":
                // Pop through to the matching opener, closing anything left open
                // in between, so malformed nesting still yields balanced output.
                if let idx = openHTMLTags.lastIndex(where: { $0.tag == name }) {
                    var out = ""
                    while openHTMLTags.count > idx {
                        out += openHTMLTags.removeLast().closer
                    }
                    return out
                }
                return Self.escapeHTMLTagText(trimmed)
            case "b", "strong":
                return "*"
            case "em", "i":
                return "_"
            case "dt":
                return ": "
            case "dd":
                return "\n"
            case "dl":
                return "\n"
            default:
                return Self.escapeHTMLTagText(trimmed)
            }
        }

        switch name {
        case "br":
            return "\\\\"
        case "hr":
            return "\n#line(length: 100%)\n"
        case "img":
            return Self.imageFromHTMLTag(trimmed) ?? ""
        case "a":
            guard let href = Self.attr("href", in: trimmed), !href.isEmpty else { return "" }
            openHTMLTags.append(PendingHTMLClose(tag: "a", closer: "]"))
            return "#link(\"\(AICompletionService.escapeTypstString(href))\")["
        case "p":
            if let alignment = Self.attr("align", in: trimmed) {
                openHTMLTags.append(PendingHTMLClose(tag: "p", closer: "\n]"))
                return "\n#align(\(alignment))[\n"
            }
            return "\n"
        case "mark":
            openHTMLTags.append(PendingHTMLClose(tag: "mark", closer: "]"))
            return "#highlight["
        case "sub":
            openHTMLTags.append(PendingHTMLClose(tag: "sub", closer: "]"))
            return "#sub["
        case "sup":
            openHTMLTags.append(PendingHTMLClose(tag: "sup", closer: "]"))
            return "#super["
        case "u":
            openHTMLTags.append(PendingHTMLClose(tag: "u", closer: "]"))
            return "#underline["
        case "del", "s", "strike":
            openHTMLTags.append(PendingHTMLClose(tag: name, closer: "]"))
            return "#strike["
        case "dt":
            return "\n/ "
        case "dd":
            return " "
        case "dl":
            return "\n"
        case "b", "strong":
            return "*"
        case "em", "i":
            return "_"
        default:
            // Unknown tag — escape it so it can't parse as a Typst label.
            return Self.escapeHTMLTagText(trimmed)
        }
    }

    /// Converts the raw text between HTML tags: whitespace passes through, real
    /// content is converted as a Markdown fragment so inline formatting, links
    /// and math placeholders inside HTML blocks keep working. The edge
    /// whitespace is kept verbatim — cmark strips a paragraph's trailing spaces,
    /// and losing one here would glue the fragment to the next token's output
    /// (e.g. `HTML` + `_tags_`, which Typst reads as a literal snake_case
    /// underscore followed by an unclosed emph).
    private mutating func convertHTMLInnerText(_ text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let leadingCount = text.prefix(while: { $0.isWhitespace }).count
        let trailingCount = text.reversed().prefix(while: { $0.isWhitespace }).count
        let start = text.index(text.startIndex, offsetBy: leadingCount)
        let end = text.index(text.endIndex, offsetBy: -trailingCount)
        let middle = String(text[start..<end])
        return String(text.prefix(leadingCount)) + convertedMarkdownFragment(middle) + String(text.suffix(trailingCount))
    }

    /// Recursively converts a Markdown fragment (HTML tag bodies, footnote
    /// definitions). Depth-limited so pathological nesting can't loop. Trailing
    /// whitespace is preserved — trimming it would glue the fragment to whatever
    /// Typst syntax the next HTML token emits (e.g. `HTML` + `_tags_`, where
    /// Typst reads the word-internal `_` as literal and the closing `_` as an
    /// unclosed emph).
    private mutating func convertedMarkdownFragment(_ raw: String) -> String {
        guard recursionDepth < 3 else { return escapeText(raw) }
        var sub = self
        sub.recursionDepth += 1
        let document = Document(parsing: raw, options: Self.parseOptions)
        var out = sub.visit(document)
        while let pending = sub.openHTMLTags.popLast() {
            out += pending.closer
        }
        return out
    }

    private static func escapeHTMLTagText(_ tag: String) -> String {
        Self.replace(AICompletionRegex.escapeHtmlTags, in: tag, template: "\\\\<$1\\\\>")
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, template: String) -> String {
        regex.stringByReplacingMatches(in: s, options: [], range: NSRange(0..<(s as NSString).length), withTemplate: template)
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        let ns = tag as NSString
        for match in AICompletionRegex.htmlAttr.matches(in: tag, options: [], range: NSRange(0..<ns.length)) {
            guard ns.substring(with: match.range(at: 1)).lowercased() == name.lowercased() else { continue }
            for group in [3, 4, 5] where match.range(at: group).location != NSNotFound {
                return ns.substring(with: match.range(at: group))
            }
        }
        return nil
    }

    /// Builds a Typst `#image(...)` from an HTML `<img>` tag, mirroring the old
    /// pipeline's attribute handling (relative-path prefixing, pixel units,
    /// fallback to a link for formats Typst can't decode).
    private static func imageFromHTMLTag(_ tag: String) -> String? {
        guard let src = attr("src", in: tag), !src.isEmpty else { return nil }
        let alt = attr("alt", in: tag) ?? ""
        let width = attr("width", in: tag) ?? ""
        let height = attr("height", in: tag) ?? ""

        let formattedSrc = src.lowercased().hasPrefix("http") || src.hasPrefix("/") || src.hasPrefix("data:") ? src : "/\(src)"
        var params: [String] = ["\"\(AICompletionService.escapeTypstString(formattedSrc))\""]
        if !alt.isEmpty { params.append("alt: \"\(AICompletionService.escapeTypstString(alt))\"") }

        // HTML width/height are typically pixels; Typst wants an explicit unit.
        for (label, value) in [("width", width), ("height", height)] where !value.isEmpty {
            if value.allSatisfy({ $0.isNumber }) {
                params.append("\(label): \(value)pt")
            } else {
                params.append("\(label): \(value)")
            }
        }

        let ext = (src as NSString).pathExtension.lowercased()
        let isWeb = src.lowercased().hasPrefix("http")
        let supportedExts = ["png", "jpg", "jpeg", "gif", "svg"]

        if !isWeb && !ext.isEmpty && !supportedExts.contains(ext) {
            // Fallback to a link if the format is entirely unsupported (like .icns).
            let displayAlt = alt.trimmingCharacters(in: .whitespaces).isEmpty ? "Image" : alt
            return "#link(\"\(AICompletionService.escapeTypstString(src))\")[🖼️ \(displayAlt)]"
        }
        return "#image(\(params.joined(separator: ", ")))"
    }

    // MARK: Inline rendering helper

    /// Renders a run of inline children with per-container HTML-tag state.
    ///
    /// If the source left a bracket-wrapping tag open, its closer is appended
    /// here — at the exact end of the inline run — so a stray `<mark>` can
    /// never leave an unclosed `#highlight[` behind. Also neutralises a
    /// trailing `_` glued to a following emphasis marker (`word_*bold*`),
    /// which the old pipeline handled with its `underscoreBeforeAsterisk`
    /// regex.
    mutating func renderInline(_ children: MarkupChildren) -> String {
        let savedTags = openHTMLTags
        openHTMLTags = []

        let array = Array(children)
        var parts: [String] = []
        parts.reserveCapacity(array.count)

        for (index, child) in array.enumerated() {
            var chunk = visit(child)
            if chunk.hasSuffix("_"), index + 1 < array.count,
               array[index + 1] is Strong || array[index + 1] is Emphasis {
                chunk = String(chunk.dropLast()) + "\\_"
            }
            parts.append(chunk)
        }

        while let pending = openHTMLTags.popLast() {
            parts.append(pending.closer)
        }
        openHTMLTags = savedTags
        return parts.joined()
    }

    // MARK: Small helpers

    /// Concatenates all `Text` descendants — used for image alt text, which
    /// must stay plain (the old pipeline used the raw attribute value).
    private static func plainText(of markup: Markup) -> String {
        var out = ""
        for child in markup.children {
            if let text = child as? Text {
                out += text.string
            } else {
                out += plainText(of: child)
            }
        }
        return out
    }

    private static func longestBacktickRun(in s: String) -> Int {
        var longest = 0
        var run = 0
        for ch in s {
            if ch == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }

    /// Wraps raw content in a Typst inline raw span, growing the backtick run
    /// past anything the content contains and padding if the edges are ticks.
    private static func rawSpan(_ code: String) -> String {
        let ticks = String(repeating: "`", count: max(1, longestBacktickRun(in: code) + 1))
        var inner = code
        if inner.hasPrefix("`") || inner.hasSuffix("`") {
            inner = " " + inner + " "
        }
        return ticks + inner + ticks
    }
}
