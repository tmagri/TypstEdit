import Foundation

// MARK: - Tool Definition

/// One tool as offered to the model, carrying what every provider's
/// function-calling API needs: a name, a human description, and a JSON
/// Schema describing its arguments. Shape matches the `server__tool`
/// qualified names so tools can come from anywhere: the built-in project
/// tools, the machine tools, the agent harness, code mode, and any live
/// MCP server.
struct MCPTool: Identifiable {
    let serverName: String
    let name: String
    let description: String
    let inputSchema: [String: Any]

    /// The server's own claim about what calling this tool does, from its
    /// `tools/list` entry (`annotations.readOnlyHint` / `destructiveHint`).
    ///
    /// The default is deliberately the conservative one: a server that ships
    /// no annotations (the common case today) gets a tool that is never
    /// batched. See `Annotations.mayRunConcurrently`.
    var annotations: Annotations = Annotations()

    var id: String { "\(serverName)::\(name)" }
    /// Flat name used when talking to model providers, since most
    /// function-calling APIs want a single identifier with no namespacing.
    var qualifiedName: String { "\(serverName)__\(name)" }

    /// What the MCP spec lets a server say about a tool. Only the two hints
    /// that decide whether calls may overlap are kept.
    ///
    /// The spec is explicit that these are *hints*, not guarantees: a server
    /// that declares `readOnlyHint` and then writes a file is misbehaving, not
    /// impossible. Batching therefore also requires the user to have opted in
    /// for that server.
    struct Annotations: Equatable, Sendable {
        /// The tool only reads. The spec's default when the field is absent
        /// is `false`.
        var readOnlyHint: Bool = false
        /// The tool may perform destructive updates. The spec's default when
        /// the field is absent is `true`.
        var destructiveHint: Bool = true

        /// Whether this call may share a server with another call in the same
        /// round. Both hints have to agree: a server may declare a tool
        /// non-destructive yet still mutate state (an "add a row" tool), and
        /// overlapping two of those is exactly the non-determinism that
        /// batching must not introduce.
        var mayRunConcurrently: Bool { readOnlyHint && !destructiveHint }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case invalidURL
    case noData
    case parsingError(String)
    case apiError(String)
    /// A non-2xx HTTP response. Kept apart from `apiError` so the transport
    /// retry policy can tell a rate limit (worth a retry, nothing streamed
    /// yet) from a bad key (never worth one).
    ///
    /// `retries` is how many attempts were already spent before this became
    /// the answer. A 500 that survived the whole backoff budget means the
    /// endpoint is down, not that the request was wrong, and the message says
    /// so — otherwise "Something went wrong" reads as a model fault.
    case httpError(statusCode: Int, body: String, retries: Int = 0)
    /// The stream went silent for longer than the stall window — treated as
    /// a stuck response rather than a hard failure, so the agentic loop can
    /// auto-continue.
    case stalledResponse(idleSeconds: Int, timeoutSeconds: Int)
    /// The stream was stopped because the model kept emitting the same
    /// passage. `keptText` is the answer up to the loop plus one copy of it —
    /// empty when the loop was in the reasoning.
    case repetitionLoop(inReasoning: Bool, unit: String, repeats: Int, keptText: String)
    /// Every attempt in the run came back with no visible text (the model
    /// streamed only reasoning, or nothing at all) and there was no earlier
    /// answer to fall back on. Distinct from `noData` — a 200 response that
    /// carried only hidden thinking — so the agent can name it plainly
    /// instead of storing a blank reply as a success.
    case emptyReply(attempts: Int)
    /// The reply was cut off by `max_tokens` with every token spent on hidden
    /// reasoning, and the budget was already at its ceiling so it could not be
    /// widened. A retry with the same cap would spend the same tokens on the
    /// same thinking, so this is reported by name instead of as
    /// `emptyReply` — "the model sent no reply" points at the model or the
    /// key, when the real answer is "this model's thinking does not fit".
    case reasoningAteTheBudget(reasoningTokens: Int, budget: Int)
    /// The user pressed stop.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL configuration."
        case .noData: return "No data received from the AI provider."
        case .parsingError(let details): return "Parsing Error: \(details)"
        case .apiError(let msg): return msg
        case .httpError(let statusCode, let body, let retries):
            return Self.httpFailureText(status: statusCode, body: body, retries: retries)
        case .stalledResponse(let idleSeconds, let timeoutSeconds):
            return "The model stopped sending output for \(idleSeconds)s (stall limit: \(timeoutSeconds)s) and the attempt was abandoned."
        case .repetitionLoop(let inReasoning, let unit, let repeats, _):
            return "The model got stuck repeating the same \(inReasoning ? "thought" : "passage") (“\(RepetitionDetector.preview(unit))”, \(repeats)× in a row) and the reply was stopped."
        case .emptyReply(let attempts):
            let tries = attempts > 0 ? " after \(attempts) retr\(attempts == 1 ? "y" : "ies")" : ""
            return "The model sent no reply — every attempt\(tries) came back empty, with no answer text to show. Try again, or switch models in Settings."
        case .reasoningAteTheBudget(let reasoningTokens, let budget):
            let spent = reasoningTokens > 0
                ? "used all \(budget) output tokens on hidden reasoning (\(reasoningTokens) on thinking alone)"
                : "used all \(budget) output tokens before writing any answer"
            return "The model \(spent), so no answer text was left to show. The output budget cannot grow past \(budget), so asking again would do the same. Lower the reasoning effort for this model, raise Max output tokens, or switch models in Settings."
        case .cancelled: return "Stopped."
        }
    }

    /// How an HTTP failure reads to the user.
    ///
    /// The `HTTP <status>:` prefix comes first, always: `AIChatAutoProceed`
    /// matches that wording as a fallback when only the rendered message
    /// survives, so the format is a contract, not a preference.
    ///
    /// The body is what needs the care. Providers answer a failure in one of
    /// three shapes, and only the first is written for a person:
    ///
    /// 1. **Prose** — `"Usage limit reached. Resets at …"`. Shown as-is.
    /// 2. **A structured envelope with a message** — `{"error":{"message":…}}`,
    ///    or a gateway's `{"status":"failure","message":…}`. Its `message` is
    ///    shown, because the surrounding JSON is noise to a reader.
    /// 3. **A structured envelope with nothing useful** — a bare
    ///    `{"status":"failure","message":"Something went wrong"}`. Dumping
    ///    that at the user names no cause and reads like the model broke, when
    ///    the truth is the endpoint failed and TypstEdit already retried it.
    ///    This case gets a sentence that says where the fault is.
    static func httpFailureText(status: Int, body: String, retries: Int = 0) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return httpFailureSummary(status: status, retries: retries) }

        // Prose is the provider talking to a person; keep it verbatim.
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            return "HTTP \(status): \(String(trimmed.prefix(400)))"
        }

        if let message = serverMessage(in: trimmed), !isVague(message) {
            return "HTTP \(status): \(message)"
        }

        // A body that parsed but said nothing useful is fully understood
        // already: quoting it back would only repeat the vagueness. A body
        // that did not parse may hold the only diagnostic there is, so it is
        // kept.
        let parsed = serverMessage(in: trimmed) != nil
        return httpFailureSummary(status: status, retries: retries, raw: parsed ? nil : trimmed)
    }

    /// The human message inside a structured error response, in the shapes
    /// the providers use: OpenAI/Anthropic's `error.message`, a gateway's
    /// top-level `message`, and the `error` field as a plain string.
    static func serverMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }

    /// A message that names no cause. A gateway falling back to its default
    /// text is the common one; repeating it adds nothing to the status code.
    static func isVague(_ message: String) -> Bool {
        let lowered = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let vague: Set<String> = [
            "something went wrong",
            "an error occurred",
            "internal server error",
            "internal error",
            "unknown error",
            "error",
            "bad gateway",
            "service unavailable",
            "gateway timeout"
        ]
        return vague.contains(lowered)
    }

    /// What failed, where, and what to do — the answer to "the server said
    /// something went wrong".
    ///
    /// The `HTTP <status>:` prefix is kept here too, not only on the
    /// pass-through paths: `AIChatAutoProceed` matches that wording, and a
    /// message that sometimes has it and sometimes does not is a trap for
    /// every reader that parses it.
    private static func httpFailureSummary(status: Int, retries: Int, raw: String? = nil) -> String {
        let attemptNote = retries > 0
            ? " TypstEdit retried it \(retries) \(retries == 1 ? "time" : "times") and the endpoint failed the same way each time."
            : ""
        let what = (500...599).contains(status)
            ? "the endpoint's own internal failure, with no reason given"
            : "nothing readable in the response"
        let advice = "That is a fault at the endpoint or the gateway in front of it, not in your prompt or your settings. Try again in a moment; if it keeps happening, check the provider's status page and its request log for this exact request."
        let rawNote = raw.map { "\n\nRaw response: \(String($0.prefix(300)))" } ?? ""
        return "HTTP \(status): \(what).\(attemptNote) \(advice)\(rawNote)"
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
    var output: String
}

/// Stops the tool-calling loop from re-running the same read over and over.
/// One instance lives for one `fetchCompletionWithTools` request.
///
/// Only read-only tools are tracked. A repeat still runs, so the answer is
/// never stale, but when it returns exactly what the previous identical call
/// returned the result is labelled as a repeat. Once a call has come back
/// identical `maxIdenticalRuns` times it is no longer executed: the model
/// gets a note telling it to use what it has.
struct ToolCallRepeatGuard {
    /// Tools whose identical repeats are pure waste while nothing changes.
    /// **Qualified** names (`project__read_file`, not `read_file`): base
    /// names collide across namespaces (`schedule__list` and `shortcuts__list`
    /// both reduce to `list`), and a collision would refuse a call because a
    /// *different* tool ran it first. Callers can add more via
    /// `alsoReadOnlyNames` — MCP tools that declare `readOnlyHint`.
    static let readOnlyToolNames: Set<String> = [
        // Project / notebook tools (LocalToolExecutor).
        "project__list_files", "project__read_file", "project__grep_project",
        "project__get_outline", "project__skim_outline", "project__find_section",
        "project__search_project", "project__read_skill", "project__read_skill_file",
        "project__read_pdf", "project__web_fetch", "project__look",
        // Git reads (GitToolExecutor).
        "git__status", "git__diff", "git__log",
        // Machine file tools (MachineToolExecutor).
        "file__find", "file__read", "file__search", "file__hash", "file__hex",
        // Harness reads.
        "skill__read", "skill__read_file",
        // Calculator.
        "calculator__evaluate_math",
    ]
    /// Tools that never change what a read would return, so recording one
    /// must **not** reset the guard. `agent__update_plan` runs in nearly
    /// every round; treating it as "something happened" would clear the
    /// history before any read could ever be refused. Anything not tracked
    /// and not listed here is assumed to have changed state.
    static let neutralToolNames: Set<String> = [
        "agent__update_plan", "agent__think", "agent__scratch_read",
        "agent__scratch_search", "agent__recall", "agent__delegate_task",
        "agent__delegate_parallel", "agent__job_status", "agent__tool_search",
        "calculator__evaluate_math",
    ]
    /// Identical runs allowed before a call is refused. 0 turns the guard
    /// off: nothing is labelled or refused.
    let maxIdenticalRuns: Int
    /// Extra qualified names treated as read-only, from tool metadata the
    /// guard's author cannot know (MCP `readOnlyHint` annotations).
    let alsoReadOnlyNames: Set<String>

    /// The default identical-run budget when the user has not chosen one.
    static let defaultMaxIdenticalRuns = 2

    static let repeatNote = "[Same result as your earlier identical call in this request — nothing has changed. Use what you already have instead of calling it again.]\n"

    private var history: [String: (runs: Int, output: String)] = [:]

    init(maxIdenticalRuns: Int, alsoReadOnlyNames: Set<String> = []) {
        self.maxIdenticalRuns = max(0, maxIdenticalRuns)
        self.alsoReadOnlyNames = alsoReadOnlyNames
    }

    /// `project__read_file` → `read_file`.
    static func baseName(_ qualifiedName: String) -> String {
        qualifiedName.range(of: "__").map { String(qualifiedName[$0.upperBound...]) } ?? qualifiedName
    }

    /// Whether this call is tracked: it is a known read-only tool (or an
    /// MCP tool that declares `readOnlyHint` and not `destructiveHint`).
    func isTracked(_ name: String) -> Bool {
        Self.readOnlyToolNames.contains(name) || alsoReadOnlyNames.contains(name)
    }

    /// Tool name plus arguments with sorted keys, so `{"limit":5,"path":"a"}`
    /// and `{"path":"a","limit":5}` count as the same call. The *qualified*
    /// name is part of the key: base names collide across namespaces.
    static func signature(name: String, argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical: String
        if trimmed.isEmpty {
            canonical = "{}"
        } else if let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let string = String(data: sorted, encoding: .utf8) {
            canonical = string
        } else {
            canonical = trimmed
        }
        return name + "|" + canonical
    }

    /// The note to return instead of running the call, or `nil` to run it.
    func refusal(name: String, argumentsJSON: String) -> String? {
        let base = Self.baseName(name)
        guard maxIdenticalRuns > 0,
              isTracked(name),
              let entry = history[Self.signature(name: name, argumentsJSON: argumentsJSON)],
              entry.runs >= maxIdenticalRuns else { return nil }
        let times = entry.runs == 1 ? "once" : "\(entry.runs) times, with the same result each time,"
        return "Not run: this exact \(base) call already ran \(times) in this request, and nothing has been edited since, so it would return the same thing. Use what it already returned, read a different range or search for something else, or write your answer now."
    }

    /// Records a finished call and returns the output to hand the model
    /// (labelled when it repeats the previous identical call exactly).
    mutating func record(name: String, argumentsJSON: String, output: String) -> String {
        guard maxIdenticalRuns > 0 else { return output }
        guard isTracked(name) else {
            // A neutral tool (a plan update, a scratchpad note, a calculator
            // run) leaves the reads it saw unchanged, so the history stands.
            if !Self.neutralToolNames.contains(name) {
                history.removeAll()
            }
            return output
        }
        let key = Self.signature(name: name, argumentsJSON: argumentsJSON)
        if let entry = history[key], entry.output == output {
            history[key] = (entry.runs + 1, output)
            return Self.repeatNote + output
        }
        history[key] = (1, output)
        return output
    }
}

// MARK: - Provider-neutral conversation types

/// A provider-neutral chat message used internally by the tool-calling loop
/// in `AICompletionService`. Converted to each provider's wire format
/// immediately before sending (OpenAI-compatible vs. Anthropic shapes differ
/// enough — system role, tool role vs. tool_result blocks — that a single
/// shared JSON shape isn't worth forcing).
enum AIChatMessage {
    case system(String)
    /// The volatile tail of the system prompt (plan checklist, Plan-mode
    /// reminder, per-turn hints). It is sent as a second system block *after*
    /// the prompt-cache breakpoint, so the stable half before it stays
    /// byte-identical across turns and reads from the provider's cache. For
    /// providers without explicit cache markers it is simply appended — the
    /// stable-first order is what their automatic prefix caches need anyway.
    case systemTail(String)
    /// A user turn, optionally carrying images the user attached to it. Images
    /// are sent as provider-specific content parts (`image_url` data URLs for
    /// OpenAI-compatible endpoints, base64 `image` blocks for Anthropic) —
    /// never as inline text the model can't see.
    case user(String, images: [ChatImage] = [])
    case assistantText(String)
    /// The model's tool calls plus any text it wrote alongside them (the
    /// intent sentence a model may be asked for before each call). The text
    /// is replayed in the request history, because a sentence the model
    /// cannot read back next round is a sentence it never wrote.
    case assistantToolCalls([AIToolCallRequest], text: String? = nil)
    case toolResult(AIToolResult)
}

/// What one turn of a tool-calling conversation produced. Each case carries
/// along any reasoning/"thinking" content the provider returned natively for
/// that turn (e.g. `reasoning_content`), separate from the visible text.
enum AIChatStep {
    case finalText(String, reasoning: String?)
    /// The calls plus any text the model wrote alongside them — its intent
    /// lines. Kept for the request history (see `AIChatMessage.assistantToolCalls`).
    case toolCalls([AIToolCallRequest], text: String?, reasoning: String?)
}

/// How a step ended, as the provider reported it. Kept apart from
/// `AIChatStep` so the step's shape stays the same for every caller.
struct AIChatStepMeta {
    /// `finish_reason` (OpenAI-compatible) or `stop_reason` (Anthropic), as sent.
    var finishReason: String?
    /// Normalized token accounting for this response, when the provider
    /// reported any. `nil` for servers that send no `usage` at all.
    var usage: TokenUsage?

    /// The prompt's size as the provider counted it.
    var promptTokens: Int? { usage?.promptTotal }
    var completionTokens: Int? { usage.map(\.outputTotal) }

    /// The reply was cut off by `max_tokens`. Hidden reasoning counts against
    /// the same budget, so a reasoning model can hit this with no visible
    /// text at all, or in the middle of a tool call's arguments.
    var hitTokenLimit: Bool {
        finishReason == "length" || finishReason == "max_tokens"
    }

    /// How much output budget this response actually consumed, when the
    /// provider reported it. This is the number to plan from: a reply that
    /// was cut off used *all* of its cap, and one that finished used less.
    /// `nil` when the provider sends no `usage` at all (some local servers).
    var consumedOutputTokens: Int? {
        guard let usage, !usage.isEmpty else { return nil }
        return usage.outputTotal
    }

    /// The smallest output budget that would have let this reply finish,
    /// derived from the provider's own accounting instead of a blind guess.
    ///
    /// A cut-off response reports what it spent, but the provider stops
    /// counting at the cap, so "spent" only proves the reply needs *at least*
    /// that much. Two evidence-based cases:
    ///
    ///   * **Reasoning-dominated** (`reasoning > 0`): the hidden thinking is
    ///     the predictable, repeated cost — it is usually what overran the
    ///     budget on an otherwise short answer. Budgeting for the reasoning
    ///     it actually used plus room for a real answer is far closer than
    ///     doubling the whole cap.
    ///   * **No separate reasoning reported**: we cannot tell how much more
    ///     the answer needed, so fall back to doubling — the old behavior,
    ///     now used only when there is no better evidence.
    ///
    /// - Parameter currentBudget: the cap the cut-off response ran under.
    func suggestedBudgetAfterCutoff(currentBudget: Int) -> Int {
        guard let usage, usage.reasoning > 0 else {
            return currentBudget * 2
        }
        // Reasoning it actually used, plus a generous but bounded allowance
        // for the visible answer it never got to write.
        let answerAllowance = max(1_024, usage.output * 2)
        let suggested = usage.reasoning + answerAllowance
        // Never suggest less than the cap it just failed on, and never more
        // than doubling it (a single bad response shouldn't set the budget).
        return min(max(suggested, currentBudget), currentBudget * 2)
    }
}

// MARK: - Stream safety machinery

/// Thread-safe record of streaming activity for the stall watchdog. The SSE
/// parsers run on the main actor, but the watchdog polls from a detached
/// task, so the "when did we last receive anything" timestamp has to be
/// shared safely between them.
final class StreamActivity: @unchecked Sendable {
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

/// Watches one streamed reply for a repetition loop, separately in the
/// answer and in the reasoning, and throws `.repetitionLoop` to end the
/// stream once one is found. Lives for one request attempt.
@MainActor
final class StreamLoopGuard {
    private var text = RepetitionDetector()
    private var reasoning = RepetitionDetector()

    /// `accumulated` is the whole answer so far, including `piece`.
    func checkText(_ piece: String, accumulated: String) throws {
        guard let loop = text.feed(piece) else { return }
        throw AIError.repetitionLoop(
            inReasoning: false,
            unit: loop.unit,
            repeats: loop.repeats,
            keptText: RepetitionDetector.keptPrefix(of: accumulated, before: loop)
        )
    }

    func checkReasoning(_ piece: String) throws {
        guard let loop = reasoning.feed(piece) else { return }
        throw AIError.repetitionLoop(inReasoning: true, unit: loop.unit, repeats: loop.repeats, keptText: "")
    }
}
