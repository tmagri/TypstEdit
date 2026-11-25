import Foundation
import Markdown

// Ported from TypstEdit's `AICompletionService.swift`, trimmed to what the
// Clippy agent needs: one streaming tool-calling loop with the same loop
// safety machinery (stall watchdog, repetition guard, repeat-call guard,
// auto-continue, token-limit ceiling), speaking OpenAI-compatible
// (OpenAI/OpenRouter/Portkey/local), Anthropic, and Gemini (one-shot,
// tool-less) wire formats.

@MainActor
final class AICompletionService: ObservableObject {
    static let shared = AICompletionService()

    /// Characters per token used by every character-based context estimate.
    static let charsPerToken = 4

    /// Rounds of "the model keeps calling tools but nothing changes" before
    /// the loop sends a no-progress redirect note.
    nonisolated static let defaultNoProgressRoundThreshold = 8
    /// How many turns remain before the turn budget ends when the loop
    /// starts warning the model to wrap up.
    nonisolated static let defaultTurnBudgetWarningRemaining = 3

    /// MCP concurrency answer the active chat agent installs
    /// (`MCPManager.mayRunConcurrently(qualifiedName:)`). TypstEdit keeps one
    /// MCPManager per chat, so there is no shared manager to ask; `nil`
    /// (no active agent) means MCP tools are simply not grouped.
    nonisolated(unsafe) static var mcpConcurrencyCheck: ((String) -> Bool)? = nil

    /// Whether tool arguments are a JSON object (or empty, which some models
    /// send for a no-argument call).
    ///
    /// A call whose arguments were cut off by the reply cap is not valid JSON.
    /// The batch and the sequential loop both check this, so an unparseable
    /// call is never admitted to a batch where its failure would be harder to
    /// attribute.
    nonisolated static func isValidToolArguments(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// The note attached to a tool result when the user sends steering input
    /// while a turn is running. Ported from TypstEdit: the model must adjust
    /// course without restarting completed work and without dropping the
    /// instruction.
    nonisolated static func steerNote(_ text: String) -> String {
        "[STEERING — the user sent this while you were working. Finish your current step, then adjust course to include it. Don't restart what is already done, and don't drop it:]\n\n\(text)"
    }

    /// Appends a harness note (a steer, a turn-budget warning, a loop hint)
    /// to the newest tool result in a request's history, so the model reads
    /// it in the same turn that is already running rather than only at the
    /// next user message. When the history ends in something else — the very
    /// first round, or after a final answer — there is nothing to attach to
    /// and the note is dropped; the caller decides what that means.
    nonisolated static func appendHarnessNote(_ note: String, to messages: inout [AIChatMessage]) {
        guard case .toolResult(var result) = messages.last else { return }
        result.output += (result.output.isEmpty ? "" : "\n\n") + note
        messages[messages.count - 1] = .toolResult(result)
    }

    @Published var isFetching: Bool = false

    private init() {}

    /// Whether an error is really the user cancelling, whatever shape it
    /// arrived in. `URLSession` throws `URLError.cancelled` when a request is
    /// cancelled, and some providers' streams fail with a bare
    /// `NSURLErrorCancelled` wrapped in a plain error. Neither is a
    /// `CancellationError`, so neither reaches the cancellation catches that
    /// keep a stopped run from being continued automatically.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? AIError, error.isCancellation { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError { return true }
        return false
    }

    /// Default per-request output budget, in tokens.
    static let defaultMaxTokens = 4_096
    /// The widest output budget a request may widen itself to when a reply is
    /// cut off by `max_tokens`.
    ///
    /// This is deliberately the same number `AISettingsManager` clamps a
    /// learned budget to, and it used to be a smaller one (16,384). That made
    /// widening impossible for exactly the models that need it most: a
    /// reasoning model already learned up to 32,768 started *above* 16,384, so
    /// the `currentMaxTokens < maxTokensCeiling` guard was false on its very
    /// first cut-off and the reply was never retried with room to write an
    /// answer. One ceiling, shared, is what keeps "the budget can grow" and
    /// "the budget can be remembered at that size" from disagreeing.
    nonisolated static var maxTokensCeiling: Int { AISettingsManager.learnedMaxTokensCeiling }

    /// The failure to report when a reply came back with no visible text.
    ///
    /// A reply cut off at the widest allowed budget gets named for what it is:
    /// the model spent the whole budget on hidden reasoning, and retrying it
    /// identically would spend the same tokens on the same thinking. Anything
    /// else is the ordinary empty reply, which a fresh request can plausibly
    /// clear.
    nonisolated static func emptyReplyError(
        meta: AIChatStepMeta,
        budget: Int,
        attempts: Int
    ) -> AIError {
        if meta.hitTokenLimit, budget >= AISettingsManager.learnedMaxTokensCeiling {
            return .reasoningAteTheBudget(
                reasoningTokens: meta.usage?.reasoning ?? 0,
                budget: budget
            )
        }
        return .emptyReply(attempts: attempts)
    }

    /// The wider cap to retry a cut-off reply with, or `nil` when it already
    /// sits at the shared ceiling and cannot grow.
    ///
    /// Pure, so the rule is testable without sending a request: `budget` is
    /// what the cut-off response ran under, and the answer comes from what the
    /// provider reported rather than a blind doubling.
    ///
    /// **A widening must actually widen.** `suggestedBudgetAfterCutoff` floors
    /// its answer at the cap that just failed, so a response whose reasoning fit
    /// comfortably inside the cap suggests the identical budget — and retrying
    /// at that number would re-spend the same tokens and cut off the same way.
    /// When the evidence gives no better number, doubling is the fallback (the
    /// old behaviour, used only when there is nothing better to go on); nudging
    /// the cap up by one token to force progress is worse, because it turns one
    /// honest error into a cascade of requests that each end the same way.
    nonisolated static func widenedBudgetAfterCutoff(
        meta: AIChatStepMeta,
        budget: Int
    ) -> Int? {
        guard meta.hitTokenLimit, budget < maxTokensCeiling else { return nil }
        let suggested = meta.suggestedBudgetAfterCutoff(currentBudget: budget)
        let target = suggested > budget ? suggested : budget * 2
        let widened = min(maxTokensCeiling, target)
        return widened > budget ? widened : nil
    }

    /// Strips `<think>`/`<thought>` tags some local/open models emit inline
    /// in their content, and returns what was inside them separately rather
    /// than discarding it.
    private func extractThinking(from text: String) -> (clean: String, reasoning: String?) {
        var cleanText = text
        let thinkTag = try! NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.caseInsensitive])
        let thoughtTag = try! NSRegularExpression(pattern: "<thought>[\\s\\S]*?</thought>", options: [.caseInsensitive])
        let regexes = [thinkTag, thoughtTag]

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

    // MARK: - One-shot completion

    /// A single request/response round trip (no streaming, no tools).
    /// Used for Gemini and as the tool-less fallback.
    func fetchCompletion(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int? = nil,
        model: ModelContext
    ) async throws -> String {
        let ctx = model
        if !ctx.isLocal && ctx.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(ctx.source.rawValue)")
        }

        let body = try Self.makeOneShotBody(ctx: ctx, systemPrompt: systemPrompt, prompt: prompt, maxTokens: maxTokens ?? Self.defaultMaxTokens)
        let (data, _) = try await Self.postJSON(endpoint: ctx.chatEndpoint, headers: ctx.authHeaders, body: body)
        let root = try Self.jsonObject(from: data, endpoint: ctx.chatEndpoint)

        switch ctx.source {
        case .gemini:
            let text = Self.geminiText(from: root)
            guard !text.isEmpty else { throw AIError.noData }
            let (clean, _) = extractThinking(from: text)
            return clean
        case .anthropic:
            let blocks = root["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            guard !text.isEmpty else { throw AIError.noData }
            let (clean, _) = extractThinking(from: text)
            return clean
        default:
            let choices = root["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            let raw = (message?["content"] as? String) ?? ""
            let (clean, _) = extractThinking(from: raw)
            guard !clean.isEmpty else { throw AIError.noData }
            return clean
        }
    }

    // MARK: - Tool-calling loop

    /// Runs a full agentic turn: streams a reply, executes any tool calls it
    /// asks for, feeds the results back, and repeats until the model produces
    /// a final answer, the turn budget runs out, or the caller cancels.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system prompt for the whole request.
    ///   - systemTail: The volatile half of the system prompt (plan
    ///     checklist, Plan-mode reminder, per-turn hints). Sent after the
    ///     stable half so a prompt-cache breakpoint between the two keeps the
    ///     stable prefix cacheable. `nil` = none, as in the subagent call.
    ///   - prompt: The user turn (the folded transcript, for chat sends).
    ///   - maxTokens: The starting output budget; a reply cut off by
    ///     `max_tokens` is retried with a doubled cap up to `maxTokensCeiling`.
    ///   - maxTurns: Maximum number of model turns (a turn = one model
    ///     request plus any tool calls it makes). `nil` = unlimited.
    ///   - autoContinueUnlimited: Keep auto-continuing stalled/empty replies
    ///     until there is an answer or Stop, ignoring the attempt count.
    ///   - autoContinueAttemptsUsed: Attempts this *run* has already spent in
    ///     earlier turns. A turn auto-proceed re-sends used to start its
    ///     counter at zero, so a budget of 3 with 5 rounds allowed 18
    ///     requests; the setting says "attempts", so the count belongs to the
    ///     run and is handed in rather than re-earned.
    ///   - onAutoContinueUsed: Reports the run's running total whenever an
    ///     auto-continue is taken, so the caller stays in step even when the
    ///     loop ends by throwing.
    ///   - transportRetries: Attempts for requests that fail before anything
    ///     arrives (rate limit, overloaded endpoint, connection error),
    ///     re-sent after a jittered backoff. 0 = off.
    ///   - waitForNetwork: Park a request that failed because the Mac went
    ///     offline and re-send it when macOS reports a connection again,
    ///     without consuming a retry attempt.
    ///   - repetitionGuardEnabled: Stop replies stuck in a repetition loop
    ///     and continue them via the auto-continue budget.
    ///   - onToolCall: Called as each tool call starts (qualified name,
    ///     arguments JSON) so the caller can show live activity.
    ///   - onToolRefused: A call the loop did not run — an identical repeat
    ///     the repeat guard refused, or arguments that were invalid.
    ///   - onReasoningDelta: Streaming reasoning fragments, as they arrive.
    ///   - onTextDelta: Every visible answer fragment, as it arrives.
    ///   - onStatus: Live status line ("generating" row); `nil` clears it.
    ///   - onUsage: Reports each response's token accounting.
    ///   - executeTool: Runs one tool call.
    /// - Returns: The model's final answer text.
    func fetchCompletionWithTools(
        systemPrompt: String,
        systemTail: String? = nil,
        prompt: String,
        /// Images the user attached to this request's message. They ride on
        /// the opening user turn only — every later request in the loop is the
        /// model's own continuation, and re-sending the pixels would bill them
        /// again on each round.
        images: [ChatImage] = [],
        maxTokens: Int = AICompletionService.defaultMaxTokens,
        maxTurns: Int? = 8,
        tools: [MCPTool],
        repeatCallLimit: Int = 2,
        autoContinueAttempts: Int = 3,
        autoContinueUnlimited: Bool = false,
        autoContinueAttemptsUsed: Int = 0,
        onAutoContinueUsed: (@MainActor (Int) -> Void)? = nil,
        transportRetries: Int = 3,
        waitForNetwork: Bool = true,
        repetitionGuardEnabled: Bool = true,
        stallTimeoutSeconds: Int = 90,
        onToolCall: (@MainActor (String, String) -> Void)? = nil,
        onToolRefused: (@MainActor (String, String, String) -> Void)? = nil,
        /// Drains any steering input the user sent while this turn was
        /// running. Called at each tool-round boundary; the returned text is
        /// attached to the round's newest tool result as a harness note, so
        /// the model adjusts course without restarting what is already done.
        onSteer: (@MainActor () -> String?)? = nil,
        onReasoningDelta: (@MainActor (String) -> Void)? = nil,
        onTextDelta: (@MainActor (String) -> Void)? = nil,
        onStatus: (@MainActor (String?) -> Void)? = nil,
        onUsage: ((TokenUsage) -> Void)? = nil,
        model: ModelContext,
        /// Runs a round's safe read-only calls concurrently. The closure is
        /// given the calls that may overlap, each with its index in the round,
        /// and returns the output per index. `nil` (or a round with nothing
        /// eligible) runs everything on the sequential path below.
        ///
        /// It is a closure rather than something this service does itself
        /// because the caller owns the transcript rows and the tool access
        /// rules — see `ClippyAgent.runParallelReadOnlyCalls`.
        executeParallel: ParallelReadRunner? = nil,
        /// Re-pulls the declared tool list. Called after a round in which the
        /// model ran `agent__tool_search`, so the tools it loaded are declared
        /// from the next request on. `nil` (the default) keeps the opening
        /// list for the whole call, which is what every caller wants unless
        /// it declares tools lazily.
        reloadTools: (() async -> [MCPTool])? = nil,
        /// Start a finished read-only call before the reply that asks for it
        /// has finished streaming, so its work overlaps the model's own
        /// writing. Off by default: it is a latency win measured per provider,
        /// and the only shape that can honour it safely today is Anthropic's,
        /// whose stream marks each tool block's end.
        ///
        /// Unlike `executeTool`, this must do the work **without** touching the
        /// transcript: the round's own walk writes every row, in the model's
        /// order, after the assistant message that requested the calls exists.
        /// `nil` — or a result the walk never consumes — means the call simply
        /// runs normally when the round reaches it.
        preDispatch: (@MainActor (_ name: String, _ argumentsJSON: String) async -> String?)? = nil,
        /// Folds the conversation anew after the caller has compacted it, and
        /// returns the replacement for this call's opening user message — or
        /// `nil` to leave it alone. Consulted only when a request was refused
        /// as too long and eliding tool outputs could not shrink it: the mass
        /// is then the folded transcript itself, which only the caller (which
        /// owns the transcript) can shrink. OpenCode's overflow ladder does
        /// the same: after a "too long" rejection the next attempt is built
        /// over a compacted history.
        refoldPrompt: (@MainActor () async -> String?)? = nil,
        executeTool: @escaping (_ qualifiedName: String, _ argumentsJSON: String) async throws -> String
    ) async throws -> String {
        let ctx = model
        if !ctx.isLocal && ctx.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(ctx.source.rawValue)")
        }
        guard !ctx.isGemini else {
            // Gemini's function-calling schema isn't wired up here — fail
            // clearly rather than silently ignoring the tools.
            throw AIError.apiError("Tool calling isn't supported for Google Gemini. Choose a different chat source.")
        }

        isFetching = true
        defer { isFetching = false }
        var messages: [AIChatMessage] = [.system(systemPrompt)]
        if let systemTail, !systemTail.isEmpty {
            messages.append(.systemTail(systemTail))
        }
        messages.append(.user(prompt, images: images))
        // Where the folded transcript lives, so a mid-call refold (see
        // `refoldPrompt`) replaces it in place. Tool results always append
        // after it, so the index never shifts.
        let promptIndex = messages.count - 1
        // The declared tool list, which can grow mid-call when the model runs
        // `agent__tool_search` and `reloadTools` supplies the fresh list.
        var activeTools = tools
        // MCP tools that declare `readOnlyHint` (and not `destructiveHint`)
        // join the repeat guard: re-running an identical read-only server
        // call is as pure a waste as re-reading a file.
        var repeatGuard = ToolCallRepeatGuard(
            maxIdenticalRuns: repeatCallLimit,
            alsoReadOnlyNames: Set(tools
                .filter { $0.annotations.readOnlyHint && !$0.annotations.destructiveHint }
                .map(\.qualifiedName))
        )
        // Start from the largest budget this model has ever needed (learned
        // from a previous request's cut-off retry), floored at the caller's
        // setting — a reasoning model that burned 8k on hidden thinking
        // should not relearn that on every new conversation.
        let learnedMaxTokens = AISettingsManager.shared.effectiveMaxTokens(for: ctx, setting: maxTokens)
        // Ahead-of-time budgeting from the provider's own numbers: if this
        // model has been *observed* to spend N tokens on hidden reasoning,
        // the cap has to clear N before a single word of the answer fits.
        // Starting above the observed peak is what stops the first reply of
        // a new conversation from being cut off at all.
        let reasoningAware = AISettingsManager.shared.reasoningAwareMaxTokens(for: ctx, setting: maxTokens)
        var currentMaxTokens = max(learnedMaxTokens, reasoningAware ?? learnedMaxTokens)
        var turns = 0
        var autoContinues = 0
        /// Attempts spent before this turn, handed in by the caller so the
        /// setting is a budget for the run and not a fresh 3 per turn.
        let autoContinueStartingDebt = max(0, autoContinueAttemptsUsed)
        var transportAttempt = 0
        let maxTransport = ModelRetryPolicy.effectiveRetries(transportRetries)
        let maxAutoContinues = autoContinueUnlimited ? Int.max : max(0, autoContinueAttempts)
        var lastAnswer = ""
        /// Index of the newest tool result in this round, so mid-turn steering
        /// input can be attached to it (`onSteer`).
        var lastToolResultIndex: Int?

        /// Calls started before the reply finished, keyed by call id.
        ///
        /// An Anthropic stream marks each `tool_use` block's end explicitly, so
        /// a round can begin its first real work while the model is still
        /// writing. The results land here rather than being appended to the
        /// transcript: the round's own walk is what writes rows, in the model's
        /// order, after the assistant message that asked for them exists. A
        /// pre-dispatch that wrote a row itself would put a tool result ahead
        /// of the reply that requested it.
        ///
        /// Only calls with no side effect the user must see first are started
        /// early (`preDispatchEligible`): no approval card, no write.
        var dispatchedEarly: [String: Task<String?, Never>] = [:]

        /// A speculative task must not outlive the call that started it. A
        /// stream that stalls, is cancelled or dies part way may have left one
        /// running against a round that will never consume its result; the
        /// `defer` cancels them, and the walk is the only thing that ever reads
        /// one.
        func cancelUnconsumedEarlyCalls() {
            for (_, task) in dispatchedEarly where !task.isCancelled { task.cancel() }
            dispatchedEarly.removeAll()
        }
        defer { cancelUnconsumedEarlyCalls() }

        /// Starts a finished read-only call before the reply is complete.
        ///
        /// Deliberately narrow. Three conditions, all necessary:
        ///
        /// - **Anthropic only.** Its stream has a per-block terminator
        ///   (`content_block_stop`), so the arguments at that point are the
        ///   whole call. OpenAI-shaped SSE has none — the next call's argument
        ///   delta can arrive after this one looks finished — so dispatching
        ///   there would run half-written JSON.
        /// - **No side effect the user must see first.** No writer, no
        ///   approval card, no question. A speculative start of a call that
        ///   would prompt would raise a card before the model had finished
        ///   explaining why.
        /// - **Arguments already valid.** A call whose JSON does not parse is
        ///   the truncated case; starting it would run a fragment.
        ///
        /// The result is never delivered from here. It is consumed by the
        /// round's own walk, in the model's order, which is what keeps the
        /// transcript honest.
        var speculativelyStartCall: (@MainActor (String, String, String) -> Void)?
        if let preDispatch, ctx.isAnthropic {
            speculativelyStartCall = { id, name, argumentsJSON in
                guard dispatchedEarly[id] == nil else { return }
                guard Self.isValidToolArguments(argumentsJSON) else { return }
                guard Self.preDispatchEligible(name) else { return }
                guard repeatGuard.refusal(name: name, argumentsJSON: argumentsJSON) == nil else { return }
                dispatchedEarly[id] = Task { await preDispatch(name, argumentsJSON) }
            }
        }

        /// Takes one attempt from the *run's* budget and returns the running
        /// total, or `nil` when it is spent.
        ///
        /// The two places that continue a reply (a stall and an empty answer)
        /// both draw on this one budget, so a turn cannot spend the setting
        /// twice over and a re-sent turn cannot start again at zero.
        func takeAutoContinue() -> Int? {
            let spent = autoContinueStartingDebt + autoContinues
            guard spent < maxAutoContinues else { return nil }
            autoContinues += 1
            let total = spent + 1
            onAutoContinueUsed?(total)
            return total
        }

        // In-loop context control (gospel): when a verbatim compressor is
        // configured, old tool results are compressed rather than dropped;
        // anything still over the budget falls back to digests.
        // The elision target is the compaction trigger, not the whole window.
        // The tool results and the folded transcript share one request, and a
        // budget set at 100% of the window — on a 4-characters-per-token
        // guess — left nothing for the reply or for a tokenizer denser than
        // the guess: a long agentic turn of dense tool output walked up to
        // 262k of a 256k window this way and every request from then on was
        // refused. The same reserve the compaction trigger keeps for the
        // answer bounds the request here.
        let baseCharBudget = CompactionBuffer.trigger(
            budget: AISettingsManager.shared.effectiveContextBudgetTokens(for: ctx),
            bufferPercent: AISettingsManager.shared.effectiveCompactionBufferPercent
        ) * Self.charsPerToken
        // The tool definitions travel with every request but are not in
        // `messages`. An MCP server such as Atlassian's offers dozens of
        // tools with large schemas, so leaving them out under-counted the
        // prompt by a wide margin.
        var toolSchemaChars = Self.toolSchemaChars(tools)
        let compression = await ChatCompressor.resolve(
            method: AISettingsManager.shared.effectiveCompressionMethod(for: ctx)
        )
        // Shrinks each time the server still reports the prompt as too big:
        // the configured budget is an estimate (4 characters a token is
        // optimistic for JSON), and a local model may be loaded with a
        // smaller window than the budget says.
        var budgetScale = 1.0
        var contextShrinks = 0
        func currentCharBudget() -> Int {
            Self.effectiveCharBudget(base: baseCharBudget, scale: budgetScale, toolSchemaChars: toolSchemaChars)
        }

        while true {
            if Task.isCancelled { throw AIError.cancelled }

            await Self.elideOldToolOutputs(
                in: &messages,
                charBudget: currentCharBudget(),
                compressor: compression?.compressor,
                keepRate: compression?.keepRate ?? 0.5
            )

            let step: AIChatStep
            let meta: AIChatStepMeta
            do {
                (step, meta) = try await requestChatStep(
                    messages: messages,
                    ctx: ctx,
                    tools: activeTools,
                    maxTokens: currentMaxTokens,
                    stallTimeoutSeconds: stallTimeoutSeconds,
                    repetitionGuardEnabled: repetitionGuardEnabled,
                    onReasoningDelta: onReasoningDelta,
                    onTextDelta: onTextDelta,
                    // A finished read-only call starts while the rest of the
                    // reply is still streaming, so a round's first real work
                    // overlaps the model's own writing instead of waiting for
                    // it. The result is consumed by the round's walk below, in
                    // the model's order, so nothing about the transcript or the
                    // approval story changes — only the wall clock.
                    onToolCallStarted: speculativelyStartCall
                )
            } catch let error as AIError {
                switch error {
                case .stalledResponse, .repetitionLoop:
                    // A stalled or looping stream can be auto-continued: ask
                    // the model to pick up where it stopped.
                    if let attempt = takeAutoContinue() {
                        onStatus?(autoContinueUnlimited
                            ? "Connection problem — asking the model to continue…"
                            : "Connection problem — asking the model to continue (\(attempt) of \(autoContinueAttempts))…")
                        if case .repetitionLoop(_, _, _, let keptText) = error, !keptText.isEmpty {
                            lastAnswer = keptText
                        }
                        messages.append(.user("[Your last reply was interrupted before it finished. Continue exactly where you left off, without repeating what you already wrote.]"))
                        continue
                    }
                    if case .repetitionLoop(_, _, _, let keptText) = error, !keptText.isEmpty {
                        return keptText
                    }
                    throw error

                case .httpError(let status, let body, _):
                    // The prompt is over the model's window. Nothing streamed,
                    // so shrink what the loop is carrying and send it again —
                    // the same compression the budget check applies, only
                    // with less room. Retrying the identical request could
                    // never succeed, so this is not a transport retry.
                    if Self.isContextOverflow(status: status, body: body),
                       contextShrinks < Self.maxContextShrinks, !Task.isCancelled {
                        contextShrinks += 1
                        budgetScale *= Self.contextShrinkFactor
                        onStatus?("The prompt is over the model's window — compacting tool results and retrying (\(contextShrinks) of \(Self.maxContextShrinks))…")
                        let before = Self.totalChars(messages)
                        await Self.elideOldToolOutputs(
                            in: &messages,
                            charBudget: currentCharBudget(),
                            compressor: compression?.compressor,
                            keepRate: compression?.keepRate ?? 0.5
                        )
                        // Nothing left to shrink: the conversation itself is
                        // too big, and sending it again would fail the same
                        // way. Give the caller one chance to fold the
                        // transcript over a compaction before reporting the
                        // provider's error.
                        if Self.totalChars(messages) >= before {
                            guard let refoldPrompt,
                                  let refolded = await refoldPrompt(),
                                  refolded.count < prompt.count else { throw error }
                            messages[promptIndex] = .user(refolded, images: images)
                            onStatus?(nil)
                            continue
                        }
                        onStatus?(nil)
                        continue
                    }
                    // Transport-level retry, safe because nothing streamed:
                    // rate limit, timeout, or an overloaded endpoint.
                    guard ModelRetryPolicy.isRetryable(status: status), transportAttempt < maxTransport, !Task.isCancelled else {
                        // Carry the attempts already spent, so a failure that
                        // survived the whole budget reads as "the endpoint is
                        // down" rather than as a first-try error.
                        throw transportAttempt > 0
                            ? AIError.httpError(statusCode: status, body: body, retries: transportAttempt)
                            : error
                    }
                    transportAttempt += 1
                    let delay = ModelRetryPolicy.delay(forAttempt: transportAttempt)
                    onStatus?(ModelRetryPolicy.statusLine(
                        attempt: transportAttempt, retries: maxTransport,
                        delay: delay, reason: ModelRetryPolicy.reason(forStatus: status)
                    ))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    onStatus?(nil)
                    continue

                case .apiError(let message):
                    // Connection-level URLErrors arrive wrapped here. A lost
                    // network parks the request (no retry cost); other
                    // connection problems go through the backoff budget.
                    guard message.contains("Request failed"), transportAttempt < maxTransport, !Task.isCancelled else {
                        throw error
                    }
                    if waitForNetwork, !NetworkMonitor.shared.isSatisfied {
                        onStatus?("Network lost — waiting for the connection to come back…")
                        await NetworkMonitor.shared.waitForPath()
                        onStatus?(nil)
                        continue
                    }
                    transportAttempt += 1
                    let delay = ModelRetryPolicy.delay(forAttempt: transportAttempt)
                    onStatus?("Connection failed — retrying in \(max(1, Int(delay.rounded())))s (attempt \(transportAttempt + 1) of \(maxTransport + 1))…")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    onStatus?(nil)
                    continue

                default:
                    throw error
                }
            } catch is CancellationError {
                throw AIError.cancelled
            }

            if let usage = meta.usage {
                onUsage?(usage)
                // Learn this model's reasoning cost from the provider's own
                // report, so the next turn can budget for it up front.
                if usage.reasoning > 0 {
                    AISettingsManager.shared.rememberReasoningUsage(usage.reasoning, for: ctx)
                }
            }

            switch step {
            case .finalText(let text, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lastAnswer = trimmed
                    return trimmed
                }
                // Empty reply: either the model spent its budget on reasoning
                // or it just declined to answer.
                //
                // A cut-off at the widest allowed budget is the one shape not
                // worth re-asking: the cap cannot grow, and the same reasoning
                // would fill it again. Saying so immediately beats spending the
                // auto-continue budget on requests that cannot succeed — that
                // is what turned one over-budgeted review into four silent
                // requests and the misleading "the model sent no reply".
                if let widened = Self.widenedBudgetAfterCutoff(meta: meta, budget: currentMaxTokens) {
                    AISettingsManager.shared.rememberMaxTokens(widened, for: ctx)
                    currentMaxTokens = widened
                    if let reasoning = meta.usage?.reasoning, reasoning > 0 {
                        onStatus?("Reply was cut off — widening the budget to \(widened) tokens (the model used \(reasoning) on reasoning)…")
                    } else {
                        onStatus?("Reply was cut off — widening the budget to \(widened) tokens…")
                    }
                    continue
                }
                if meta.hitTokenLimit {
                    // Cut off with no room to grow: the budget is the whole
                    // problem, so report it as that rather than as an empty
                    // reply a fresh request could clear.
                    guard !lastAnswer.isEmpty else {
                        throw Self.emptyReplyError(
                            meta: meta, budget: currentMaxTokens, attempts: autoContinueStartingDebt + autoContinues
                        )
                    }
                    return lastAnswer
                }
                // `maxAutoContinues`, not the raw attempt count: the
                // "Unlimited attempts" setting is a chat preference, and
                // ignoring it here made it a half-truth — a stalled reply
                // continued forever while an empty one gave up after three.
                if let attempt = takeAutoContinue() {
                    onStatus?(autoContinueUnlimited
                        ? "Empty reply — asking again…"
                        : "Empty reply — asking again (\(attempt) of \(autoContinueAttempts))…")
                    messages.append(.user("[Your reply arrived empty. Answer the request now.]"))
                    continue
                }
                // Every retry came back empty and there is nothing to hand
                // back. Returning "" here used to look like a successful turn:
                // the agent stored a blank assistant row (rendered as "…"),
                // skipped the plan's outstanding work, and never started
                // Auto-proceed, because an empty reply is not "unfinished".
                // Throw instead, so the turn is visibly a failure and the
                // failure path can offer a continuation. A cut-off at the
                // widest budget is named for what it really is.
                guard !lastAnswer.isEmpty else {
                    throw Self.emptyReplyError(
                        meta: meta, budget: currentMaxTokens, attempts: autoContinueStartingDebt + autoContinues
                    )
                }
                return lastAnswer

            case .toolCalls(let calls, let intent, _):
                turns += 1
                lastToolResultIndex = nil
                if let maxTurns, maxTurns > 0, turns >= maxTurns {
                    // Turn budget exhausted: ask for the answer without tools.
                    onStatus?("Wrap-up — asking for the final answer…")
                    messages.append(.assistantToolCalls(calls, text: intent))
                    for call in calls {
                        messages.append(.toolResult(AIToolResult(
                            callID: call.id, name: call.name,
                            output: "Not run: the turn budget ran out. Write your final answer now."
                        )))
                    }
                    messages.append(.user("[Turn budget reached. Stop calling tools and write your final answer now.]"))
                    let (finalStep, finalMeta) = try await requestChatStep(
                        messages: messages,
                        ctx: ctx,
                        tools: [],
                        maxTokens: currentMaxTokens,
                        stallTimeoutSeconds: stallTimeoutSeconds,
                        repetitionGuardEnabled: repetitionGuardEnabled,
                        onReasoningDelta: onReasoningDelta,
                        onTextDelta: onTextDelta
                    )
                    if let usage = finalMeta.usage { onUsage?(usage) }
                    if case .finalText(let text, _) = finalStep,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return text
                    }
                    // The wrap-up request also came back empty. A non-empty
                    // answer from an earlier round is still worth keeping;
                    // with none, this is a failed turn, not a silent success.
                    // Named by the wrap-up response's own finish reason, so a
                    // budget that reasoning ate is reported as such.
                    guard !lastAnswer.isEmpty else {
                        throw Self.emptyReplyError(
                            meta: finalMeta, budget: currentMaxTokens, attempts: autoContinueStartingDebt + autoContinues
                        )
                    }
                    return lastAnswer
                }

                messages.append(.assistantToolCalls(calls, text: intent))

                // Independent lookups in one reply run at the same time. Only                // calls the harness has cleared for overlap are eligible, and
                // each is still screened by the repeat guard first, so the
                // batch sees exactly the calls a sequential round would have
                // run. Anything the caller declines to batch falls through to
                // the loop below.
                //
                // The batch is chosen by *position*, through
                // `ParallelToolCalls.parallelGroups`: a run of eligible calls
                // overlaps, and a call that will not be batched — a writer, a
                // refused repeat, a call whose arguments were cut off — splits
                // the round there. Collecting every eligible call in the round
                // regardless of position used to let a read after a write run
                // *before* it, which is the one thing batching must never do.
                //
                // A group runs when the round reaches it, not in a pre-pass:
                // running every group up front would reorder a batch that sits
                // *after* a writer past it, which is the same bug wearing the
                // other hat.
                //
                // The transcript order never changes: each call's result is
                // appended in the model's order, as the walk below reaches it.
                var batched: [Int: String] = [:]
                var groups: [ParallelToolCalls.Group] = []
                var groupStartingAt: [Int: Int] = [:]
                if let executeParallel {
                    func eligible(_ index: Int) -> Bool {
                        let call = calls[index]
                        guard Self.isValidToolArguments(call.argumentsJSON) else { return false }
                        guard repeatGuard.refusal(name: call.name, argumentsJSON: call.argumentsJSON) == nil else {
                            return false
                        }
                        // TypstEdit's own tools answer from a fixed set; an
                        // MCP tool only overlaps when the user allowed that
                        // server to and the server annotated the tool
                        // read-only. TypstEdit keeps one MCPManager per chat,
                        // so there is no shared manager to ask here — the
                        // active agent installs its manager's answer through
                        // `mcpConcurrencyCheck`, and with no chat active MCP
                        // tools simply do not group.
                        return ParallelToolCalls.isSafe(call.name)
                            || (Self.mcpConcurrencyCheck?(call.name) ?? false)
                    }
                    groups = ParallelToolCalls.parallelGroups(count: calls.count, isEligible: eligible)
                    for (position, group) in groups.enumerated() {
                        if let first = group.indices.first { groupStartingAt[first] = position }
                    }
                }

                for (index, call) in calls.enumerated() {
                    if Task.isCancelled { throw AIError.cancelled }

                    // A call already started while the reply was still
                    // streaming: take its output here, so the row is written in
                    // the model's order like every other. The task was started
                    // by id and cannot have run twice — the walk is the only
                    // place that consumes it.
                    if let early = dispatchedEarly.removeValue(forKey: call.id) {
                        // A `nil` means the pre-dispatch seam declined the call
                        // (it was not a plan it could build), so it must run
                        // normally below rather than count as an empty result.
                        if let output = await early.value {
                            let recorded = repeatGuard.record(
                                name: call.name, argumentsJSON: call.argumentsJSON, output: output
                            )
                            messages.append(.toolResult(AIToolResult(callID: call.id, name: call.name, output: recorded)))
                            lastToolResultIndex = messages.count - 1
                            continue
                        }
                    }

                    // A group runs when the walk reaches its first call, so a
                    // batch that sits after a writer still runs after it.
                    if let position = groupStartingAt[index], let executeParallel {
                        let batch = groups[position].indices.map {
                            ParallelReadCall(
                                index: $0,
                                qualifiedName: calls[$0].name,
                                argumentsJSON: calls[$0].argumentsJSON
                            )
                        }
                        let outputs = await executeParallel(batch)
                        for (callIndex, output) in outputs { batched[callIndex] = output }
                        // The guard's history has to record what ran, or the
                        // next identical call wouldn't be recognised as a repeat.
                        for entry in batch.sorted(by: { $0.index < $1.index }) {
                            guard let output = outputs[entry.index] else { continue }
                            _ = repeatGuard.record(name: entry.qualifiedName, argumentsJSON: entry.argumentsJSON, output: output)
                        }
                    }

                    // Already run as part of its group above.
                    if let output = batched[index] {
                        messages.append(.toolResult(AIToolResult(callID: call.id, name: call.name, output: output)))
                        lastToolResultIndex = messages.count - 1
                        continue
                    }

                    // The repeat guard refuses identical re-reads.
                    if let note = repeatGuard.refusal(name: call.name, argumentsJSON: call.argumentsJSON) {
                        onToolRefused?(call.name, call.argumentsJSON, note)
                        messages.append(.toolResult(AIToolResult(callID: call.id, name: call.name, output: note)))
                        continue
                    }

                    onToolCall?(call.name, call.argumentsJSON)
                    let output: String
                    do {
                        output = try await executeTool(call.name, call.argumentsJSON)
                    } catch is CancellationError {
                        throw AIError.cancelled
                    } catch {
                        output = "Error running \(call.name): \(error.localizedDescription)"
                    }
                    let recorded = repeatGuard.record(name: call.name, argumentsJSON: call.argumentsJSON, output: output)
                    messages.append(.toolResult(AIToolResult(callID: call.id, name: call.name, output: recorded)))
                    lastToolResultIndex = messages.count - 1
                }
                // A `tool_search` call this round may have loaded tools; the
                // caller's fresh list declares them from the next request on.
                // Re-pulling only after a search keeps the caller's ledger
                // (which counts "prompts offered") at one write per round the
                // way every other turn is.
                if calls.contains(where: { $0.name == AgentHarnessTools.toolSearchQualifiedName }),
                   let reloadTools {
                    activeTools = await reloadTools()
                    toolSchemaChars = Self.toolSchemaChars(activeTools)
                }
                // Steering input sent mid-turn lands on the round's newest
                // tool result, so it is the freshest instruction the model
                // reads before its next request (TypstEdit's `onSteer`).
                if let lastToolResultIndex, let steer = onSteer?(), !steer.isEmpty {
                    if case .toolResult(var result) = messages[lastToolResultIndex] {
                        result.output += "\n\n" + Self.steerNote(steer)
                        messages[lastToolResultIndex] = .toolResult(result)
                    }
                    onReasoningDelta?("\n\n[The user sent steering input while you were working — it is attached to the last tool result.]\n\n")
                }
                continue
            }
        }
    }

    /// Whether a call may be started before the reply that asks for it has
    /// finished streaming.
    ///
    /// The set is deliberately smaller than `ParallelToolCalls.safeToolNames`.
    /// That set answers "can this overlap another call?", which allows anything
    /// read-only — including tools that raise an approval card or wait for the
    /// user. A speculative start is different: it begins before the model has
    /// finished saying why, so a card appearing there would interrupt an
    /// explanation that is still being written. Only tools that read and never
    /// prompt qualify.
    nonisolated static func preDispatchEligible(_ qualifiedName: String) -> Bool {
        switch qualifiedName {
        case "reference__list_files", "reference__read_file", "reference__grep",
             "file__find", "file__read", "file__search", "file__hash", "file__hex":
            return true
        default:
            // `web__web_fetch` is excluded because it can ask for approval on a
            // signed-in request, and `skill__read_file` because it reads an
            // already-loaded body — starting it early saves nothing.
            return false
        }
    }

    // MARK: - One streamed turn

    /// Requests one model turn (streaming for OpenAI-compatible and
    /// Anthropic) and returns what it produced plus how it ended.
    private func requestChatStep(
        messages: [AIChatMessage],
        ctx: ModelContext,
        tools: [MCPTool],
        maxTokens: Int,
        stallTimeoutSeconds: Int,
        repetitionGuardEnabled: Bool = true,
        onReasoningDelta: (@MainActor (String) -> Void)?,
        onTextDelta: (@MainActor (String) -> Void)?,
        /// Called at `content_block_stop` for each finished `tool_use` block on
        /// an Anthropic stream, so a round's first call can begin before the
        /// reply is complete. `nil` disables it.
        onToolCallStarted: (@MainActor (_ id: String, _ name: String, _ argumentsJSON: String) -> Void)? = nil
    ) async throws -> (AIChatStep, AIChatStepMeta) {
        if ctx.isGemini {
            // One-shot path (tools are rejected earlier for Gemini).
            let systemPrompt = messages.compactMap {
                switch $0 {
                case .system(let text), .systemTail(let text): return text
                default: return nil
                }
            }.joined(separator: "\n\n")
            let userPrompt = messages.compactMap {
                if case .user(let text, _) = $0 { return text } else { return nil }
            }.joined(separator: "\n\n")
            let text = try await fetchCompletion(prompt: userPrompt, systemPrompt: systemPrompt, maxTokens: maxTokens, model: ctx)
            return (.finalText(text, reasoning: nil), AIChatStepMeta(finishReason: "stop", usage: nil))
        }

        let activity = StreamActivity()
        let loopGuard = StreamLoopGuard()
        let timeout = max(15, TimeInterval(stallTimeoutSeconds))

        // The watchdog races the stream: if nothing has arrived for the
        // stall window, the parse is abandoned.
        let watchdog = Task.detached { [activity] () -> TimeInterval? in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if activity.isStalled(past: timeout) {
                    return activity.secondsSinceTouch
                }
            }
            return nil
        }

        var textAccumulated = ""
        var reasoningAccumulated = ""
        var toolCalls: [AIToolCallRequest] = []
        var meta = AIChatStepMeta(finishReason: nil, usage: nil)

        func finish() -> (AIChatStep, AIChatStepMeta) {
            watchdog.cancel()
            let (clean, inlineThinking) = extractThinking(from: textAccumulated)
            let reasoning = [reasoningAccumulated, inlineThinking ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let trimmedReasoning = reasoning.isEmpty ? nil : reasoning

            if !toolCalls.isEmpty {
                // `clean`, not the raw accumulation: a local model can inline
                // <think> tags in the text stream, and the intent sentence
                // that rides the wire must not carry them.
                let intent = clean.trimmingCharacters(in: .whitespacesAndNewlines)
                return (.toolCalls(toolCalls, text: intent.isEmpty ? nil : intent, reasoning: trimmedReasoning), meta)
            }
            return (.finalText(clean, reasoning: trimmedReasoning), meta)
        }

        do {
            let request = try Self.makeStreamRequest(
                ctx: ctx, messages: messages, tools: tools, maxTokens: maxTokens
            )

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIError.noData }
            guard (200..<300).contains(http.statusCode) else {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                    errorBody += "\n"
                }
                throw AIError.httpError(statusCode: http.statusCode, body: String(errorBody.prefix(1_000)))
            }

            if ctx.isAnthropic {
                var blockTools: [Int: (id: String, name: String, json: String)] = [:]
                for try await line in bytes.lines {
                    activity.touch()
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let type = root["type"] as? String ?? ""

                    switch type {
                    case "message_start":
                        if let usageDict = (root["message"] as? [String: Any])?["usage"] as? [String: Any] {
                            meta.usage = TokenUsage.fromAnthropic(usageDict)
                        }
                    case "content_block_start":
                        if let index = root["index"] as? Int,
                           let block = root["content_block"] as? [String: Any],
                           block["type"] as? String == "tool_use" {
                            blockTools[index] = (
                                block["id"] as? String ?? "tool_\(index)",
                                block["name"] as? String ?? "unknown",
                                ""
                            )
                        }
                    case "content_block_delta":
                        if let index = root["index"] as? Int,
                           let delta = root["delta"] as? [String: Any] {
                            switch delta["type"] as? String {
                            case "text_delta":
                                let piece = delta["text"] as? String ?? ""
                                if !piece.isEmpty {
                                    textAccumulated += piece
                                    if repetitionGuardEnabled {
                                        try loopGuard.checkText(piece, accumulated: textAccumulated)
                                    }
                                    onTextDelta?(piece)
                                }
                            case "thinking_delta":
                                let piece = delta["thinking"] as? String ?? ""
                                if !piece.isEmpty {
                                    reasoningAccumulated += piece
                                    if repetitionGuardEnabled {
                                        try loopGuard.checkReasoning(piece)
                                    }
                                    onReasoningDelta?(piece)
                                }
                            case "input_json_delta":
                                let piece = delta["partial_json"] as? String ?? ""
                                if !piece.isEmpty, blockTools[index] != nil {
                                    blockTools[index]!.json += piece
                                }
                            default:
                                break
                            }
                        }
                    case "content_block_stop":
                        // Anthropic marks each block's end explicitly, and a
                        // tool_use block's arguments are complete at that
                        // point. Handing it to the caller here lets a long
                        // round start its first real work while the model is
                        // still writing the rest of the reply — the reply's
                        // preamble, or the second and third call. OpenAI-shaped
                        // streams have no per-call terminator (the next call's
                        // argument delta can still arrive after this one looks
                        // finished), so this stays Anthropic-only: dispatching
                        // partial JSON elsewhere would run a call the model
                        // never finished writing.
                        if let index = root["index"] as? Int,
                           let block = blockTools[index],
                           onToolCallStarted != nil {
                            onToolCallStarted?(block.id, block.name, block.json.isEmpty ? "{}" : block.json)
                        }
                    case "message_delta":
                        if let delta = root["delta"] as? [String: Any] {
                            let stop = delta["stop_reason"] as? String
                            switch stop {
                            case "max_tokens": meta.finishReason = "length"
                            case "tool_use": meta.finishReason = "tool_calls"
                            case "end_turn", "stop_sequence", .some: meta.finishReason = "stop"
                            case nil: break
                            }
                        }
                        if let usageDict = root["usage"] as? [String: Any] {
                            let output = (usageDict["output_tokens"] as? NSNumber)?.intValue ?? 0
                            var usage = meta.usage ?? TokenUsage()
                            usage.output = max(usage.output, output)
                            if usage.promptTotal > 0 || usage.outputTotal > 0 { meta.usage = usage }
                        }
                    default:
                        break
                    }
                }
                toolCalls = blockTools.sorted { $0.key < $1.key }.map {
                    AIToolCallRequest(id: $0.value.id, name: $0.value.name, argumentsJSON: $0.value.json.isEmpty ? "{}" : $0.value.json)
                }
                if meta.finishReason == "tool_calls" && !toolCalls.isEmpty {
                    onTextDelta?("")  // flush any streamed preamble
                }
            } else {
                // OpenAI-compatible SSE.
                var pendingCalls: [Int: (id: String, name: String, json: String)] = [:]
                for try await line in bytes.lines {
                    activity.touch()
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    if let usageDict = root["usage"] as? [String: Any] {
                        meta.usage = TokenUsage.fromOpenAI(usageDict)
                    }
                    guard let choice = (root["choices"] as? [[String: Any]])?.first else { continue }
                    if let finish = choice["finish_reason"] as? String, meta.finishReason == nil {
                        meta.finishReason = finish
                    }
                    guard let delta = choice["delta"] as? [String: Any] else { continue }

                    let reasoningPiece = (delta["reasoning_content"] as? String)
                        ?? (delta["reasoning"] as? String) ?? ""
                    if !reasoningPiece.isEmpty {
                        reasoningAccumulated += reasoningPiece
                        if repetitionGuardEnabled {
                            try loopGuard.checkReasoning(reasoningPiece)
                        }
                        onReasoningDelta?(reasoningPiece)
                    }
                    if let piece = delta["content"] as? String, !piece.isEmpty {
                        textAccumulated += piece
                        if repetitionGuardEnabled {
                            try loopGuard.checkText(piece, accumulated: textAccumulated)
                        }
                        onTextDelta?(piece)
                    }
                    if let callDeltas = delta["tool_calls"] as? [[String: Any]] {
                        meta.finishReason = "tool_calls"
                        for callDelta in callDeltas {
                            let index = (callDelta["index"] as? NSNumber)?.intValue ?? 0
                            var entry = pendingCalls[index] ?? (
                                callDelta["id"] as? String ?? "call_\(index)",
                                "unknown",
                                ""
                            )
                            if let id = callDelta["id"] as? String, !id.isEmpty { entry.id = id }
                            if let function = callDelta["function"] as? [String: Any] {
                                if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                                if let args = function["arguments"] as? String { entry.json += args }
                            }
                            pendingCalls[index] = entry
                        }
                    }
                }
                toolCalls = pendingCalls.sorted { $0.key < $1.key }.map {
                    AIToolCallRequest(id: $0.value.id, name: $0.value.name, argumentsJSON: $0.value.json.isEmpty ? "{}" : $0.value.json)
                }
            }

            return finish()
        } catch let error as AIError {
            watchdog.cancel()
            throw error
        } catch is CancellationError {
            watchdog.cancel()
            throw AIError.cancelled
        } catch {
            watchdog.cancel()
            // A cancel that reached the transport as an ordinary error is
            // still a cancel. `URLSession` reports a cancelled request as
            // `URLError.cancelled`, which is neither a `CancellationError` nor
            // a stall — and both of those paths hand the run to auto-continue.
            // Stop means the run ends here, whatever shape the transport gave
            // the ending. Checked before the stall test so that stopping a
            // *stalled* reply is not mistaken for the stall continuing.
            if Task.isCancelled || Self.isCancellation(error) {
                throw AIError.cancelled
            }
            // An aborted stream mid-reply counts as a stall, not a failure —
            // the auto-continue path can pick it up.
            if activity.secondsSinceTouch > 10 {
                throw AIError.stalledResponse(idleSeconds: Int(activity.secondsSinceTouch), timeoutSeconds: Int(timeout))
            }
            throw AIError.apiError("Request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Wire format builders
    private struct ParsedConversation {
        var system: String = ""
        var turns: [AIChatMessage] = []
    }

    private static func makeStreamRequest(
        ctx: ModelContext, messages: [AIChatMessage], tools: [MCPTool], maxTokens: Int
    ) throws -> URLRequest {
        guard let url = URL(string: ctx.chatEndpoint) else { throw AIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        for (key, value) in ctx.authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]
        if ctx.isAnthropic {
            var anthropic = anthropicBody(messages: messages, tools: tools, maxTokens: maxTokens, effort: ctx.reasoningEffort, temperature: ctx.temperature)
            anthropic["model"] = ctx.model
            body = anthropic
        } else {
            var openAI = openAIBody(messages: messages, tools: tools, maxTokens: maxTokens, effort: ctx.reasoningEffort, stream: true, temperature: ctx.temperature)
            openAI["model"] = ctx.model
            body = openAI
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Internal, not private, so tests can assert on the wire shape without
    /// standing up a server (see `PerModelHarnessTests`).
    static func openAIBody(messages: [AIChatMessage], tools: [MCPTool], maxTokens: Int, effort: ReasoningEffort, stream: Bool, temperature: Double? = nil) -> [String: Any] {
        var wire: [[String: Any]] = []
        for message in messages {
            switch message {
            case .system(let text), .systemTail(let text):
                wire.append(["role": "system", "content": text])
            case .user(let text, let images):
                if images.isEmpty {
                    wire.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty {
                        parts.append(["type": "text", "text": text])
                    }
                    for image in images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": image.dataURL]
                        ])
                    }
                    wire.append(["role": "user", "content": parts])
                }
            case .assistantText(let text):
                wire.append(["role": "assistant", "content": text])
            case .assistantToolCalls(let calls, let text):
                wire.append([
                    "role": "assistant",
                    // The intent sentence the model wrote beside its calls is
                    // replayed, not dropped: it is the working memory a small
                    // model was asked to keep, and a history the model cannot
                    // read back teaches it the sentences go nowhere.
                    "content": text ?? "",
                    "tool_calls": calls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.argumentsJSON]
                        ]
                    }
                ])
            case .toolResult(let result):
                wire.append(["role": "tool", "tool_call_id": result.callID, "content": result.output])
            }
        }

        var body: [String: Any] = [
            "model": "",  // filled by caller
            "messages": wire,
            "max_tokens": maxTokens,
        ]
        // Callers pass the model name through the closure below; keep the
        // builder pure by accepting it separately.
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.qualifiedName,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ]
                ]
            }
        }
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        if let temperature {
            body["temperature"] = temperature
        }
        applyReasoningEffort(effort, toOpenAI: &body, isOpenRouter: false)
        return body
    }

    /// Internal, not private, so tests can assert on the wire shape without
    /// standing up a server (see `PerModelHarnessTests`).
    static func anthropicBody(messages: [AIChatMessage], tools: [MCPTool], maxTokens: Int, effort: ReasoningEffort, temperature: Double? = nil) -> [String: Any] {
        var systemBlocks: [[String: Any]] = []
        // Which system blocks are volatile tails (`systemTail`): the cache
        // breakpoint goes on the last stable block, *before* any tail, so
        // a plan update invalidates nothing ahead of it.
        var systemBlockIsTail: [Bool] = []
        var wire: [[String: Any]] = []
        // Merge consecutive tool results into one user message (Anthropic
        // requires strict alternation, and a round's results arrive together).
        var pendingToolResults: [[String: Any]] = []
        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            wire.append(["role": "user", "content": pendingToolResults])
            pendingToolResults = []
        }

        for message in messages {
            switch message {
            case .system(let text):
                if !text.isEmpty {
                    systemBlocks.append(["type": "text", "text": text])
                    systemBlockIsTail.append(false)
                }
            case .systemTail(let text):
                if !text.isEmpty {
                    systemBlocks.append(["type": "text", "text": text])
                    systemBlockIsTail.append(true)
                }
            case .user(let text, let images):
                flushToolResults()
                var blocks: [[String: Any]] = []
                // Anthropic reads images placed before the text, and a text
                // block must be non-empty.
                for image in images {
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": image.mediaType,
                            "data": image.base64
                        ]
                    ])
                }
                if !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                // An empty user turn (images only, or nothing at all) would be
                // rejected; keep a placeholder rather than sending zero blocks.
                if blocks.isEmpty {
                    blocks.append(["type": "text", "text": "(no text)"])
                }
                wire.append(["role": "user", "content": blocks])
            case .assistantText(let text):
                flushToolResults()
                wire.append(["role": "assistant", "content": [[ "type": "text", "text": text ]]])
            case .assistantToolCalls(let calls, let text):
                flushToolResults()
                var blocks: [[String: Any]] = []
                // The intent sentence rides ahead of the tool_use blocks, the
                // way it was generated — see the OpenAI builder for why it is
                // replayed rather than dropped.
                if let text, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                blocks.append(contentsOf: calls.map { call in
                    [
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) ?? [:]
                    ]
                })
                if blocks.isEmpty {
                    blocks = [["type": "text", "text": ""]]
                }
                wire.append(["role": "assistant", "content": blocks])
            case .toolResult(let result):
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": result.callID,
                    "content": result.output,
                ])
            }
        }
        flushToolResults()

        let budget = effort.anthropicBudgetTokens
        var body: [String: Any] = [
            "model": "",
            "max_tokens": budget > 0 ? max(maxTokens, budget + 1_024) : maxTokens,
            "messages": wire,
            "stream": true,
        ]
        if !systemBlocks.isEmpty {
            // Prompt cache breakpoint (pi/Opus-style): the stable blocks —
            // identity, reference context, tool guidance, skills — are
            // byte-identical across turns, so marking the last of them
            // ephemeral lets the provider bill everything up to and
            // including it as a cache read from the second turn on. A
            // `systemTail` block follows the breakpoint unmarked, so a plan
            // update invalidates nothing before it. No tail → the marker
            // lands on the last block, which is what the one-shot path
            // (compaction calls) produces.
            let lastStable = Self.lastStableSystemBlock(isTails: systemBlockIsTail)
            systemBlocks[lastStable]["cache_control"] = ["type": "ephemeral"]
            body["system"] = systemBlocks
        }
        if !tools.isEmpty {
            // Second breakpoint on the last tool: the tool definitions are
            // part of the cached prefix, and Anthropic caches up to the last
            // marker it sees, so this covers the whole stable scaffolding.
            body["tools"] = tools.enumerated().map { index, tool in
                var definition: [String: Any] = [
                    "name": tool.qualifiedName,
                    "description": tool.description,
                    "input_schema": tool.inputSchema,
                ]
                if index == tools.count - 1 {
                    definition["cache_control"] = ["type": "ephemeral"]
                }
                return definition
            }
        }
        if budget > 0 {
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        }
        // Anthropic's temperature range is 0–1; clamp so a 2.0 chat setting
        // doesn't 400 the whole request.
        if let temperature {
            body["temperature"] = min(1, max(0, temperature))
        }
        return body
    }

    private static func makeOneShotBody(ctx: ModelContext, systemPrompt: String, prompt: String, maxTokens: Int) throws -> [String: Any] {
        switch ctx.source {
        case .gemini:
            var body: [String: Any] = [
                "contents": [[
                    "role": "user",
                    "parts": [["text": prompt]],
                ]],
                "generationConfig": ["maxOutputTokens": maxTokens, "temperature": ctx.temperature ?? 1.0],
            ]
            if !systemPrompt.isEmpty {
                body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
            }
            return body
        case .anthropic:
            var body = anthropicBody(messages: [.user(prompt)], tools: [], maxTokens: maxTokens, effort: ctx.reasoningEffort, temperature: ctx.temperature)
            body["model"] = ctx.model
            body["stream"] = false
            if !systemPrompt.isEmpty { body["system"] = systemPrompt }
            return body
        default:
            var body = openAIBody(messages: [.user(prompt)], tools: [], maxTokens: maxTokens, effort: ctx.reasoningEffort, stream: false, temperature: ctx.temperature)
            body["model"] = ctx.model
            return body
        }
    }

    // MARK: - Image rejection hint

    /// Appends an actionable note when a provider error reads like a rejected
    /// image payload. The usual cause after attaching images: the model can't
    /// read them. Say so in terms the user can act on, instead of leaving a
    /// raw provider message about "content parts".
    static func imageRejectionHint(for message: String) -> String {
        guard looksLikeAnImageRejection(message) else { return message }
        return message + "\n\nThis model may not accept images. Remove the attachment, or switch to an image-capable model from the chat panel's model menu."
    }

    /// Whether a provider's error text reads like a rejected image payload.
    /// Deliberately narrow: only a message that mentions images/content parts
    /// *and* a rejection word gets the extra hint.
    static func looksLikeAnImageRejection(_ message: String) -> Bool {
        let lower = message.lowercased()
        let mentionsImage = lower.contains("image") || lower.contains("vision") || lower.contains("modalit")
        let mentionsRejection = lower.contains("not support")
            || lower.contains("unsupported")
            || lower.contains("invalid")
            || lower.contains("cannot")
            || lower.contains("does not")
            || lower.contains("content part")
        return mentionsImage && mentionsRejection
    }

    private static func postJSON(endpoint: String, headers: [String: String], body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: endpoint) else { throw AIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.noData }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIError.apiError("HTTP \(http.statusCode): \(String(text.prefix(600)))")
        }
        return (data, http)
    }

    private static func jsonObject(from data: Data, endpoint: String) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIError.parsingError("Could not parse response from \(endpoint): \(String(text.prefix(300)))")
        }
        return root
    }

    private static func geminiText(from root: [String: Any]) -> String {
        let candidates = root["candidates"] as? [[String: Any]] ?? []
        let content = candidates.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - Tool Output Elision
    // Ported verbatim from TypstEdit's AICompletionService (minus the image
    // attachments this app doesn't carry).

    /// Prefix stamped onto a tool result that pass 1 of
    /// `elideOldToolOutputs` compressed verbatim. Both tells the model the
    /// text below is an information-dense extract, and lets the elision pass
    /// recognize outputs that must not be filtered a second time.
    nonisolated static let compressedToolOutputMarker = "[Extract — filler words omitted, kept wording verbatim.]\n"

    /// Characters one message adds to the prompt. Images count by their token
    /// estimate (4 characters ≈ 1 token, the rule the rest of this budget
    /// uses), not by base64 length.
    nonisolated static func charCount(_ message: AIChatMessage) -> Int {
        switch message {
        case .system(let t), .systemTail(let t), .assistantText(let t): return t.count
        case .user(let t, let images):
            return t.count + images.reduce(0) { $0 + $1.budgetChars }
        case .assistantToolCalls(let calls, let text):
            return calls.reduce(0) { $0 + $1.argumentsJSON.count + $1.name.count } + (text?.count ?? 0)
        case .toolResult(let r): return r.output.count
        }
    }

    nonisolated static func totalChars(_ messages: [AIChatMessage]) -> Int {
        messages.reduce(0) { $0 + charCount($1) }
    }

    /// What the tool definitions add to every request: name, description and
    /// the JSON Schema of each tool.
    nonisolated static func toolSchemaChars(_ tools: [MCPTool]) -> Int {
        tools.reduce(0) { sum, tool in
            let schema = JSONSerialization.isValidJSONObject(tool.inputSchema)
                ? ((try? JSONSerialization.data(withJSONObject: tool.inputSchema))?.count ?? 0)
                : 0
            return sum + tool.qualifiedName.count + tool.description.count + schema
        }
    }

    /// Never squeezed below this, however small the window: a budget that
    /// cannot hold even the fixed parts of a prompt is a configuration
    /// problem, and shrinking to nothing would hide it.
    nonisolated static let minimumCharBudget = 8_000

    /// Which system block carries the Anthropic prompt-cache breakpoint: the
    /// last block that is *not* a `systemTail`. Everything up to and
    /// including that block is byte-identical between turns, so the provider
    /// can reuse it; a tail after the breakpoint changes freely (plan
    /// updates) without invalidating the cache. With no stable block the
    /// last block wins, so a lone system message still gets its cache
    /// breakpoint (the compaction one-shot path).
    ///
    /// Pure and `nonisolated` so the breakpoint rule is testable without
    /// building a full request body.
    nonisolated static func lastStableSystemBlock(isTails: [Bool]) -> Int {
        isTails.lastIndex(where: { !$0 }) ?? isTails.count - 1
    }

    /// The message budget left once the tool definitions are paid for, after
    /// `scale` has been applied to the configured budget.
    nonisolated static func effectiveCharBudget(base: Int, scale: Double, toolSchemaChars: Int) -> Int {
        max(minimumCharBudget, Int(Double(base) * scale) - toolSchemaChars)
    }

    /// How many times one request may shrink its budget and be sent again
    /// after the server says the prompt is over the window, and by how much
    /// each time.
    nonisolated static let maxContextShrinks = 3
    nonisolated static let contextShrinkFactor = 0.6

    /// Whether an HTTP failure means "the prompt does not fit the window",
    /// as opposed to a bad key, a rate limit or a rejected image. Servers
    /// word it differently: OpenAI and LM Studio send
    /// `context_length_exceeded`, Anthropic "prompt is too long", llama.cpp
    /// mentions `n_ctx` or the context size.
    nonisolated static func isContextOverflow(status: Int, body: String) -> Bool {
        guard status == 400 || status == 413 else { return false }
        let text = body.lowercased()
        return [
            "context_length_exceeded", "context window", "context length",
            "maximum context", "context size", "n_ctx", "prompt is too long",
            "input is too long", "too many tokens",
        ].contains { text.contains($0) }
    }

    /// Whether a *rendered* failure message means "the prompt does not fit
    /// the window". The live path classifies by status + body
    /// (`isContextOverflow(status:body:)`); this is for callers that only
    /// kept the string — the chat's own status lines and the transcript.
    ///
    /// A rate limit phrased as "too many tokens" is deliberately **not** an
    /// overflow: waiting beats shrinking, and shrinking would throw context
    /// away for nothing.
    nonisolated static func isContextOverflowMessage(_ message: String) -> Bool {
        let text = message.lowercased()
        guard !text.isEmpty else { return false }
        // A 429 in the rendered text is a throttle, whatever it says about
        // tokens: waiting beats shrinking, and shrinking throws context away.
        if text.contains("429")
            || text.contains("rate limit") || text.contains("too many requests")
            || text.contains("throttl") || text.contains("per day") {
            return false
        }
        if text.contains("max_tokens must be") { return false }
        return [
            "context_length_exceeded", "context window", "context length",
            "maximum context", "context size", "n_ctx", "prompt is too long",
            "input is too long", "too many tokens", "prompt exceeds",
            "maximum input length", "exceeds maximum", "reduce the length",
            "request_too_large",
        ].contains { text.contains($0) }
    }

    /// The budget scales one request tries, largest first, when the prompt
    /// is refused as too long. The first retry aims just below the refused
    /// size so the cache prefix and most of the transcript survive; a
    /// provider that refuses a second time gets a much smaller prompt
    /// rather than a barely-there trim.
    nonisolated static var contextOverflowShrinkSteps: [Double] {
        (0..<maxContextShrinks).map { step in
            pow(contextShrinkFactor, Double(step + 1))
        }
    }

    /// The status line while a refused request is retried. Names the attempt
    /// so a long recovery does not look like a hang.
    nonisolated static func contextOverflowStatusLine(attempt: Int, total: Int) -> String {
        "The prompt is too long for the model's window — shrinking older tool output and retrying (\(attempt) of \(total))…"
    }

    /// The least a tool result is cut down to, however tight the budget.
    // MARK: - Tool Input Repair

    /// nested object, or fill an optional field with `null`; without repair
    /// each of those costs a refused call, a harness note, and a whole extra
    /// round. Only provably-safe repairs are made, mirroring opencode:
    /// - a string coerced to number/boolean where the schema declares a
    ///   plain `number`/`integer`/`boolean` type
    /// - a stringified JSON object/array parsed where the schema declares a
    ///   plain `object`/`array` type, then repaired recursively
    /// - a `null` or empty-object placeholder dropped from an optional,
    ///   plainly-typed property (only a bare single type provably rejects
    ///   those; compositions may accept them, so those are left alone)
    /// - undeclared keys dropped only where the schema sets
    ///   `additionalProperties: false`
    ///
    /// TypstEdit's schemas use none of `$ref`/`$defs`/`prefixItems`/
    /// `patternProperties`, so those opencode branches are omitted, and the
    /// recursion is depth-capped the same way. Applied by the chat manager
    /// (`AIChatManager`) when it has the called tool's input schema;
    /// unknown tools pass through untouched.
    nonisolated static func repairToolInput(_ arguments: [String: Any], schema: [String: Any]?) -> [String: Any] {
        guard let schema, !arguments.isEmpty else { return arguments }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []
        let additionalProperties = (schema["additionalProperties"] as? NSNumber)?.boolValue
        var repaired = arguments
        for (key, value) in arguments {
            // Undeclared keys are only provably unwelcome when the schema
            // closes the object; anything else may be a dynamic property.
            guard let property = properties[key] as? [String: Any] else {
                if additionalProperties == false, !required.contains(key) {
                    repaired.removeValue(forKey: key)
                }
                continue
            }
            if placeholder(value, declaredType: property["type"] as? String),
               plainOptionalType(property, required: required.contains(key)) {
                repaired.removeValue(forKey: key)
                continue
            }
            let new = repairValue(value, schema: property, depth: 0)
            if !Self.valuesEquivalent(new, value) {
                repaired[key] = new
            }
        }
        return repaired
    }

    /// Repairs one value against its property schema. Returns the input
    /// unchanged whenever nothing provably applies.
    private nonisolated static func repairValue(_ value: Any, schema: [String: Any], depth: Int) -> Any {
        guard depth < 6 else { return value }
        // A `"type": ["x", "null"]` list unwraps to its single non-null type.
        var schema = schema
        if let types = schema["type"] as? [String], types.count == 2, types.contains("null") {
            schema["type"] = types.first { $0 != "null" }
        }
        guard let type = schema["type"] as? String, isPlainType(schema) else { return value }

        if type == "number" || type == "integer" {
            guard let text = value as? String else { return value }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let parsed = Double(trimmed), parsed.isFinite else { return value }
            if type == "integer", parsed != parsed.rounded() { return value }
            return parsed
        }
        if type == "boolean" {
            guard let text = value as? String else { return value }
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "true" { return true }
            if trimmed == "false" { return false }
            return value
        }
        if type == "object" {
            let parsed = (value as? String).flatMap { stringifiedJSONObject($0) } ?? value
            guard let object = parsed as? [String: Any] else { return value }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            var repaired: [String: Any] = [:]
            for (key, member) in object {
                if let memberSchema = properties[key] as? [String: Any] {
                    repaired[key] = repairValue(member, schema: memberSchema, depth: depth + 1)
                } else {
                    repaired[key] = member
                }
            }
            return repaired
        }
        if type == "array" {
            let parsed = (value as? String).flatMap { stringifiedJSONArray($0) } ?? value
            guard let array = parsed as? [Any], let items = schema["items"] as? [String: Any] else { return value }
            // Every member is repaired against the declared item schema; a
            // member whose type already matches passes through unchanged.
            return array.map { repairValue($0, schema: items, depth: depth + 1) }
        }
        return value
    }

    /// True when the schema's declared type is a bare single type with no
    /// compositions — the only case where `null`/`{}` placeholders are
    /// provably rejected, and the only case a coercion cannot be wrong.
    private nonisolated static func isPlainType(_ schema: [String: Any]) -> Bool {
        for keyword in ["anyOf", "oneOf", "allOf", "enum", "const", "$ref"] where schema[keyword] != nil {
            return false
        }
        return schema["type"] is String
    }

    private nonisolated static func plainOptionalType(_ schema: [String: Any], required: Bool) -> Bool {
        !required && isPlainType(schema)
    }

    /// `null`, or an object with no keys — what cut-off or confused calls
    /// leave in an optional field. An empty object is only a placeholder
    /// when the declared type is not itself `object`.
    private nonisolated static func placeholder(_ value: Any, declaredType: String?) -> Bool {
        if value is NSNull { return true }
        if let object = value as? [String: Any], object.isEmpty, declaredType != "object" { return true }
        return false
    }

    /// Parses a stringified JSON object (`"{\"a\":1}"` → `["a": 1]`).
    private nonisolated static func stringifiedJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }

    private nonisolated static func stringifiedJSONArray(_ text: String) -> [Any]? {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [Any]
    }

    /// JSONSerialization comparisons: NSNumber boxes both booleans and
    /// numbers, and `20` vs `20.0` compare equal, which is exactly the
    /// equivalence a repair needs — "changed" means a type or parse happened.
    private nonisolated static func valuesEquivalent(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject) == (rhs as? NSObject)
    }

    nonisolated static let minimumKeptToolOutputChars = 6_000
    /// Wording of the note left where the middle of a result was cut out.
    nonisolated static let clippedToolOutputPhrase = "omitted from the middle of this result to fit the model's context window"

    /// Cuts `text` to roughly `limit` characters by dropping its middle,
    /// keeping most of the start and some of the end (a list's paging token
    /// or a file's last lines live there). A note says what was removed, so
    /// the model asks for a narrower result instead of assuming it saw it all.
    nonisolated static func clippingMiddle(_ text: String, to limit: Int, toolName: String) -> String {
        guard text.count > limit else { return text }
        let removed = text.count - limit
        let note = "\n\n[… \(removed) characters \(clippedToolOutputPhrase). Ask \(toolName) for a smaller result — fewer fields, a lower page size, a tighter filter — if you need the rest …]\n\n"
        let room = max(0, limit - note.count)
        let head = room * 3 / 4
        let tail = room - head
        let clipped = String(text.prefix(head)) + note + String(text.suffix(tail))
        return clipped.count < text.count ? clipped : text
    }

    /// Keeps a long tool-calling conversation inside a rough character budget.
    /// Three passes, cheapest loss first. The two most recent tool results
    /// are what the model is actively working from, so the first two passes
    /// leave them alone:
    ///
    ///   1. When a compressor is configured (token filter or LLMLingua-2),
    ///      each large *older* result is compressed *verbatim* — the model
    ///      keeps roughly `keepRate` of the words, in order, instead of
    ///      losing everything. Compressed outputs carry a marker so they are
    ///      never squeezed a second time on a later turn.
    ///   2. Any remaining overflow replaces older results with a digest,
    ///      oldest first.
    ///   3. If the *newest* results alone still overflow — one large search
    ///      or file read can — the largest is compressed with the same
    ///      compressor at the rate that would make it fit, then cut down with
    ///      `clippingMiddle` if that was not enough. Without this the request
    ///      went out over the window and failed.
    ///
    /// This is the in-loop counterpart to the chat's turn-level compaction:
    /// a single request can easily rack up 20 large `read_file` results
    /// across turns.
    static func elideOldToolOutputs(
        in messages: inout [AIChatMessage],
        charBudget: Int,
        compressor: (any PromptCompressor)?,
        keepRate: Double
    ) async {
        var total = totalChars(messages)
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

        // Pass 2 — last resort: replace the whole output with a short digest
        // (read window, headings, files matched). A bare "re-run the tool"
        // placeholder made the model re-read the same file, which refilled
        // the budget and got elided again — the read loop.
        for index in toolIndices where !protected.contains(index) {
            guard case .toolResult(let result) = messages[index] else { continue }
            guard !result.output.contains(Self.elidedToolOutputPhrase) else { continue }
            let digest = Self.elisionDigest(for: result)
            guard digest.count < result.output.count else { continue }
            total -= (result.output.count - digest.count)
            messages[index] = .toolResult(AIToolResult(callID: result.callID, name: result.name, output: digest))
            if total <= charBudget { break }
        }
        guard total > charBudget else { return }

        // Pass 3 — the newest results. Largest first, so one oversized
        // result takes the cut rather than every small one.
        let newest = protected.sorted { lhs, rhs in
            guard case .toolResult(let a) = messages[lhs], case .toolResult(let b) = messages[rhs] else { return false }
            return a.output.count > b.output.count
        }
        for index in newest {
            guard total > charBudget else { break }
            guard case .toolResult(let result) = messages[index] else { continue }
            let original = result.output.count
            // What this result may keep so the whole prompt fits, but never
            // less than a readable amount.
            let target = max(minimumKeptToolOutputChars, original - (total - charBudget))
            guard target < original else { continue }

            var text = result.output
            if let compressor, original > 800, !text.hasPrefix(compressedToolOutputMarker) {
                // Aim the compressor at the size that fits, not at the
                // user's usual rate: this is the only chance to keep the
                // result whole-ish before words are simply cut away.
                // A word-level rate is only approximately a size, and the
                // marker is added on top, so aim a little under the target.
                let aim = Double(max(1, target - compressedToolOutputMarker.count)) * 0.9
                let needed = max(0.1, min(keepRate, aim / Double(original)))
                let compressed = await compressor.compress(
                    text,
                    keepRate: needed,
                    forceTokens: [],
                    isCode: PromptCompression.codeRatio(text) > 0.3
                )
                if compressed.count < text.count { text = compressedToolOutputMarker + compressed }
            }
            // Compact JSON has few spaces, so the word filter can leave most
            // of it standing. The clip is what guarantees the fit.
            if text.count > target {
                text = clippingMiddle(text, to: target, toolName: ToolCallRepeatGuard.baseName(result.name))
            }
            guard text.count < original else { continue }
            total -= original - text.count
            messages[index] = .toolResult(AIToolResult(callID: result.callID, name: result.name, output: text))
        }
    }

    /// Wording shared by every elision digest; also how pass 2 recognizes a
    /// digest so it never digests one again.
    nonisolated static let elidedToolOutputPhrase = "output elided to stay within the context budget"

    /// Most heading / file lines one digest lists.
    nonisolated static let elisionDigestMaxEntries = 40

    /// What survives when a tool result has to be dropped: enough for the
    /// model to know what it already looked at and where things are, so it
    /// only re-reads a specific range when it needs the exact text.
    static func elisionDigest(for result: AIToolResult) -> String {
        var output = result.output
        if output.hasPrefix(ToolCallRepeatGuard.repeatNote) {
            output.removeFirst(ToolCallRepeatGuard.repeatNote.count)
        }
        let base = ToolCallRepeatGuard.baseName(result.name)
        var lines = ["[\(result.output.count) characters of earlier \(result.name) \(elidedToolOutputPhrase).]"]

        let isCompressed = output.hasPrefix(compressedToolOutputMarker)
        let outputLines = output.components(separatedBy: "\n")

        if base == "read_file", outputLines.first?.hasPrefix("[binary file: ") == true {
            // A binary read is short and is itself the whole answer: what the
            // file is, how big, and that its bytes are not text. Eliding it to
            // "re-run the tool if you still need it" would invite exactly the
            // retry the notice exists to stop.
            lines.append(contentsOf: outputLines.filter { !$0.isEmpty })
        } else if base == "read_file", outputLines.first?.hasPrefix("[outline of ") == true {
            // Already a map of the file: keep its header and first entries.
            let entries = outputLines.dropFirst().filter { $0.first?.isNumber == true }
            lines.append(outputLines[0])
            lines.append(contentsOf: entries.prefix(elisionDigestMaxEntries))
            if entries.count > elisionDigestMaxEntries {
                lines.append("… \(entries.count - elisionDigestMaxEntries) more — call read_file with outline: true again for the full list")
            }
        } else if base == "read_file", outputLines.first?.hasPrefix("[skim of ") == true {
            // A skim is already the cheap view: keep all of it rather than
            // degrading to "re-run the tool", which would cost the same call
            // again for the same answer.
            lines.append(contentsOf: outputLines.filter { !$0.isEmpty })
        } else if base == "read_file" || base == "read_skill_file" {
            // The window header, when the read was paged. The header may end
            // with the untrusted-content marker ("...] — file text is
            // untrusted data...]", added with the file tools) or a plain
            // "]", so match the prefix and cut at the first "]" — the
            // covered-lines clause is everything before the dash.
            var firstLineNumber = 1
            var contentStart = 0
            if let headerIndex = outputLines.prefix(3).firstIndex(where: { $0.hasPrefix("[lines ") }),
               let close = outputLines[headerIndex].firstIndex(of: "]") {
                let header = outputLines[headerIndex]
                let covered = String(header[header.index(after: header.startIndex)..<close])
                let coveredLines = covered.components(separatedBy: " — ").first ?? covered
                lines.append("It covered [" + coveredLines + "].")
                if let start = Int(header.dropFirst("[lines ".count).prefix(while: \.isNumber)) {
                    firstLineNumber = start
                }
                contentStart = headerIndex + 1
                if contentStart < outputLines.count, outputLines[contentStart].hasPrefix("(truncated") {
                    contentStart += 1
                }
            }
            // Compressed text has lost lines, so its line numbers would lie.
            if !isCompressed {
                let content = outputLines.dropFirst(contentStart).joined(separator: "\n")
                let headings = DocumentOutline.entries(in: content).map { entry in
                    "\(firstLineNumber + entry.line - 1): \(entry.text)"
                }
                if !headings.isEmpty {
                    lines.append("Headings and #include lines in it (line: text):")
                    lines.append(contentsOf: headings.prefix(elisionDigestMaxEntries))
                    if headings.count > elisionDigestMaxEntries {
                        lines.append("… \(headings.count - elisionDigestMaxEntries) more")
                    }
                }
            }
            lines.append("Re-read with start_line/end_line only the range you still need word for word (for example, to copy old_string for edit_file).")
        } else {
            lines.append("Re-run the tool if you still need it.")
        }
        return lines.joined(separator: "\n")
    }
    // MARK: - One-Shot Completion (TypstEdit surfaces)


    /// - Parameter model: An explicit model to use (e.g. a saved model chosen
    ///   for AI Prompt or Refine). `nil` resolves the model configured for
    ///   `purpose` in Settings, as before.
    func fetchCompletion(prompt: String, systemPrompt: String = "You are a precise code completion engine. Output ONLY the code to insert at the cursor. Do NOT output any thinking, reasoning, explanations, or XML tags.", maxTokens: Int? = nil, purpose: AIRequestPurpose = .chat, model: ModelContext? = nil, onReasoning: @escaping (String) -> Void = { _ in }, sanitize: Bool = true) async throws -> String {
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
        let ctx = model ?? settings.modelContext(for: purpose.modelTask)

        // Only require API key for cloud providers
        if !ctx.isLocal && ctx.apiKey.isEmpty {
            throw AIError.apiError("API Key is missing for \(ctx.source.rawValue)")
        }

        let endpoint = ctx.chatEndpoint
        let isGemini = ctx.isGemini

        guard let url = URL(string: endpoint) else {
            throw AIError.invalidURL
        }
        // Lets other features see that this server is busy.
        let activity = ModelServerActivity.shared.begin(url)
        defer { ModelServerActivity.shared.end(activity) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Provider-specific auth/identification headers (Anthropic, Portkey,
        // OpenRouter, Bearer for OpenAI-compatible; none for Gemini).
        for (field, value) in ctx.authHeaders {
            request.addValue(value, forHTTPHeaderField: field)
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

    nonisolated static func emptyAnswerFailureMessage(nudges: Int, hadReasoning: Bool) -> String {
        var message = "The AI processed the request but returned an empty response"
        if nudges > 0 {
            message += " even after \(nudges) follow-up attempt\(nudges == 1 ? "" : "s")"
        }
        message += "."
        if hadReasoning {
            message += " It spent its reply on reasoning and left nothing for the answer — try raising Max Tokens in Settings, or lowering the model's reasoning effort if it has one."
        } else {
            message += " Try rephrasing your prompt — or, in AI Chat, raise Auto-continue attempts (or turn on Unlimited) in Settings → AI Assistant → AI Chat."
        }
        return message
    }

    /// Prefix stamped onto a tool result that pass 1 of
    /// `elideOldToolOutputs` compressed verbatim. Both tells the model the

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

}




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

// MARK: - Markdown → Typst conversion (restored from the pre-port service;
// TypstCompiler, AgentDocumentConverter and AgentCompileService call these.)
extension AICompletionService {
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

    /// Finds where live Typst code regions start and end in `text`: a region
    /// opens where `isTypstRegionOpener` holds and continues while its bracket
    /// depth is unclosed. Depth counting respects `"strings"` (with `\"`
    /// escapes), `//` line comments and `/* */` block comments. Fenced code
    /// blocks are skipped wholesale. Returns inclusive line indices.
    ///
    /// Single source of truth for region boundaries: both the hybrid
    /// sanitizer's region extraction (`extractTypstRegions`) and the `.note`
    /// operator-delimiting pre-pass (`TypstCompiler.delimitImproperOperators`)
    /// call it, so they can never disagree about what is live Typst code. Such
    /// a disagreement escaped `>=` inside a `#show` block (`\>=` is invalid in
    /// code mode), which cascaded into ~4,000 compile errors — and that
    /// diagnostic flood is what filled the stderr pipe and froze Save.
    nonisolated static func typstRegionLineSpans(in text: String) -> [(start: Int, end: Int)] {
        let lines = text.components(separatedBy: "\n")
        var spans: [(start: Int, end: Int)] = []
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
                let capped = end + 1 >= min(lines.count, index + regionLineCap)
                if depth <= 0 || capped {
                    // A trailing construct opener (`it =>`) whose block brace
                    // sits on the NEXT line continues the region: Typst itself
                    // rejects the split (a newline ends the statement) and
                    // `autoFixBrokenNoteSyntax` joins the two lines before
                    // compiling, so the region must cover the brace body too.
                    // Mirrored in `NoteTypstRegions`.
                    if depth <= 0, !capped, end + 1 < lines.count,
                       TypstCompiler.isBlockOpenerLine(lines[end].trimmingCharacters(in: .whitespaces)),
                       lines[end + 1].trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                        end += 1
                        continue
                    }
                    break
                }
                end += 1
            }

            spans.append((start: index, end: end))
            // The whole span is settled: continue scanning after its last line.
            index = end + 1
        }

        return spans
    }

    /// Lifts whole Typst code regions out of hybrid `.note` text before the
    /// CommonMark parse (step 1e). Regions — and their boundaries — come from
    /// `typstRegionLineSpans`. Extraction is idempotent: re-running on
    /// already-sanitized text re-extracts the same regions.
    nonisolated static func extractTypstRegions(_ text: String, marker: Unicode.Scalar) -> (text: String, regions: [String]) {
        let spans = typstRegionLineSpans(in: text)
        guard !spans.isEmpty else { return (text, []) }

        var lines = text.components(separatedBy: "\n")
        var regions: [String] = []

        // Replace spans last-to-first so mutations can't shift the indices of
        // the spans still to be processed. `position` is the span's document
        // order, which is the region's placeholder-token index.
        for (position, span) in spans.enumerated().reversed() {
            // cmark lazy-continues a column-0 line into a preceding list
            // item's paragraph, which pulled region tokens (and their
            // expansions — images, pagebreaks) inside the list container
            // (typst: "pagebreaks are not allowed inside of containers").
            // A blank line closes the open block so the token starts fresh.
            var regionStart = span.start
            var regionEnd = span.end
            if regionStart > 0, !lines[regionStart - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("", at: regionStart)
                regionStart += 1
                regionEnd += 1
            }
            regions.insert(lines[regionStart...regionEnd].joined(separator: "\n"), at: 0)
            lines.replaceSubrange(regionStart...regionEnd, with: [PlaceholderMarkers.token(kind: marker, index: position)])
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
