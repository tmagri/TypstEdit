import Foundation
import Combine

/// Everything about the chat reference folder (ported from Clippy's settings
/// model, which the ported `ReferenceFolderManager` reads). TypstEdit does not
/// surface the reference-folder feature yet — the project itself is the
/// chat's folder — so this resolves to "off" unless a future build turns it
/// on. Kept as settings-shaped values so the ported machinery compiles and
/// behaves identically.
struct ReferenceFolderSettings: Codable, Equatable {
    /// Whether chats may read the folder (and the model gets its contents).
    var useReferenceFolder: Bool = false
    /// Absolute path. Empty = the default (`~/TypstEditReferences`).
    var referenceFolderPath: String = ""
}

// Engine-facing settings surface.
//
// The AI engine was ported from Clippy, whose `AISettingsManager` exposes its
// knobs under different member names than TypstEdit's. Rather than renaming
// across the ported engine files (and diverging from upstream every time a
// file is re-checked), the engine's names are provided here as an adapter:
//
//   * Where TypstEdit already has the setting, the adapter is a thin alias
//     over the existing `@AppStorage` property — one source of truth, and the
//     existing Settings UI keeps working unchanged.
//   * Where the concept is new (parallel reads, shell/file tools, case file,
//     learned budgets, …), the adapter owns the value in `UserDefaults`
//     directly. Settings UI for these lands with the engine UI pass.

extension AISettingsManager {

    private enum EngineKeys {
        static let chatParallelReadsEnabled = "aiChatParallelReadsEnabled"
        static let chatRecallToolEnabled = "aiChatRecallToolEnabled"
        static let chatEmbeddingsEnabled = "aiChatEmbeddingsEnabled"
        static let chatScratchpadEnabled = "aiChatScratchpadEnabled"
        static let chatCaseFileEnabled = "aiChatCaseFileEnabled"
        static let chatCaseReviewRequired = "aiChatCaseReviewRequired"
        static let chatCaseDriftInterval = "aiChatCaseDriftInterval"
        static let chatCaseDefaultMethodID = "aiChatCaseDefaultMethodID"
        static let toolPruningEnabled = "aiChatToolPruningEnabled"
        static let chatSubagentConcurrency = "aiChatSubagentConcurrency"
        static let chatProviderSlots = "aiChatProviderSlots"
        static let fileToolEnabled = "aiChatFileToolEnabled"
        static let fileToolNetworkVolumesEnabled = "aiChatFileToolNetworkVolumesEnabled"
        static let shellToolEnabled = "aiChatShellToolEnabled"
        static let shellSandboxEnabled = "aiChatShellSandboxEnabled"
        static let bypassPermissionsUnlocked = "aiChatBypassPermissionsUnlocked"
        static let skillAuthoringEnabled = "aiChatSkillAuthoringEnabled"
        static let mcpAuthoringEnabled = "aiChatMCPAuthoringEnabled"
        static let mcpToolsDeferred = "aiChatMCPToolsDeferred"
        static let retryFailedScheduledRuns = "aiChatRetryFailedScheduledRuns"
        static let screenCaptureAllowed = "aiChatScreenCaptureAllowed"
    static let calculatorToolEnabled = "aiChatCalculatorToolEnabled"
        static let systemPrompt = "aiChatSystemPrompt"
        static let learnedMaxTokens = "learnedMaxTokens"
        static let observedReasoningPeak = "observedReasoningPeak"
    }

    private func engineBool(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    private func setEngineBool(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        objectWillChange.send()
    }

    private func engineInt(_ key: String, default defaultValue: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? defaultValue
    }

    private func setEngineInt(_ key: String, _ value: Int) {
        UserDefaults.standard.set(value, forKey: key)
        objectWillChange.send()
    }

    // MARK: Reference folder (infrastructure for the ported read machinery)

    /// The chat reference folder settings. Off in TypstEdit for now — the
    /// ported file tools read the open project (or the whole machine, via
    /// `file__*`) instead.
    var reference: ReferenceFolderSettings {
        ReferenceFolderSettings(
            useReferenceFolder: false,
            referenceFolderPath: UserDefaults.standard.string(forKey: "aiChatReferenceFolderPath") ?? ""
        )
    }

    // MARK: Tool toggles (aliases over TypstEdit's existing opt-ins)

    /// Whether the Python tool exists. Every run is approved per call.
    var pythonToolEnabled: Bool { chatPythonToolEnabled }
    /// Run scripts under macOS `sandbox-exec`: no network, writes limited to
    /// a per-run scratch folder. Setuid binaries (sudo) cannot run inside.
    var pythonSandboxEnabled: Bool { chatPythonSandboxEnabled }
    /// Allow scripts to run `sudo -A` through the askpass helper. Elevated
    /// runs always need explicit human approval, even in YOLO mode.
    var pythonSudoEnabled: Bool { chatPythonSudoEnabled }
    /// Whether the `web_fetch` tool exists (public internet only, approved
    /// per call). Off until opted in.
    var webFetchEnabled: Bool { chatWebFetchEnabled }
    /// Whether the agent may ask to look at the screen.
    var screenToolEnabled: Bool { chatScreenToolEnabled }
    /// Allow the agent to capture the whole screen, not just a region.
    var screenToolAllowsFullScreen: Bool { chatScreenFullScreenEnabled }

    // MARK: Loop knobs (aliases)

    /// Maximum model turns per user message. `0` = unlimited.
    var maxTurns: Int { chatMaxTurns }
    /// How many times an empty/stalled reply is automatically retried. `0` = off.
    var autoContinueAttempts: Int { chatAutoContinueAttempts }
    /// Keep asking until the model answers or Stop is pressed.
    var autoContinueUnlimited: Bool { chatAutoContinueUnlimited }
    /// Identical read-only tool calls allowed before the repeat guard refuses.
    /// `0` = off.
    var repeatCallLimit: Int { chatRepeatCallLimit }
    /// Streaming stall window, in seconds, before a request is abandoned.
    var stallTimeoutSeconds: Int { Int(chatStallTimeoutSeconds) }

    // MARK: Safety (aliases over the dedicated stores)

    /// The saved permission rules (deny beats allow; see `PermissionRules`).
    var permissionRules: [PermissionRule] { PermissionRuleStore.shared.rules }
    /// The user-authored safety rules (see `SafetyMonitor`).
    var userSafetyRules: [UserSafetyRule] { SafetyRuleStore.shared.userRules }
    /// How much the safety monitor checks: `strict`, `safe`, or `off`.
    var safetyMode: SafetyMode {
        get { chatSafetyMode }
        set { chatSafetyMode = newValue }
    }

    // MARK: Harness features new to the engine

    /// Run independent read-only tool calls from one reply at the same time
    /// instead of one after another. Only reads that never prompt for approval
    /// are batched; writes, Python, fetches and MCP tools stay sequential.
    var chatParallelReadsEnabled: Bool {
        get { engineBool(EngineKeys.chatParallelReadsEnabled, default: true) }
        set { setEngineBool(EngineKeys.chatParallelReadsEnabled, newValue) }
    }
    /// Offer the `agent__recall` tool, which searches the parts of the
    /// conversation that compaction folded out of context.
    var chatRecallToolEnabled: Bool {
        get { engineBool(EngineKeys.chatRecallToolEnabled, default: true) }
        set { setEngineBool(EngineKeys.chatRecallToolEnabled, newValue) }
    }
    /// Let recall use semantic embeddings when an embedding endpoint is set.
    var chatEmbeddingsEnabled: Bool {
        get { engineBool(EngineKeys.chatEmbeddingsEnabled, default: false) }
        set { setEngineBool(EngineKeys.chatEmbeddingsEnabled, newValue) }
    }
    /// Offer the `agent__think` scratchpad: a place for the model to write a
    /// note that survives the context window. On by default — the tool only
    /// writes inside the app's own per-chat folder, and a note to itself is
    /// the cheapest context engineering there is.
    var chatScratchpadEnabled: Bool {
        get { engineBool(EngineKeys.chatScratchpadEnabled, default: true) }
        set { setEngineBool(EngineKeys.chatScratchpadEnabled, newValue) }
    }
    /// Offer the case file (`agent__update_case`, `agent__review_case`): a
    /// user-ratified charter and done-when standard for goal-directed chats.
    /// On by default — a chat has no case until the model opens one, and
    /// opening one shows the user a ratification card first.
    var chatCaseFileEnabled: Bool {
        get { engineBool(EngineKeys.chatCaseFileEnabled, default: true) }
        set { setEngineBool(EngineKeys.chatCaseFileEnabled, newValue) }
    }
    /// A verdict needs an adversarial review of the current evidence.
    var chatCaseReviewRequired: Bool {
        get { engineBool(EngineKeys.chatCaseReviewRequired, default: true) }
        set { setEngineBool(EngineKeys.chatCaseReviewRequired, newValue) }
    }
    /// Run the drift check after every this many finished turns of an open
    /// case. `0` = off.
    var chatCaseDriftInterval: Int {
        get { engineInt(EngineKeys.chatCaseDriftInterval, default: 4) }
        set { setEngineInt(EngineKeys.chatCaseDriftInterval, newValue) }
    }
    /// The method a new case starts on (`CaseMethod.id`). Empty = inquiry,
    /// with the assistant free to propose another with the charter.
    var chatCaseDefaultMethodID: String {
        get { UserDefaults.standard.string(forKey: EngineKeys.chatCaseDefaultMethodID) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: EngineKeys.chatCaseDefaultMethodID)
            objectWillChange.send()
        }
    }
    /// Whether chronically unused tools are pruned from prompts based on
    /// historical usage (see `ToolUsageLedger`).
    var toolPruningEnabled: Bool {
        get { engineBool(EngineKeys.toolPruningEnabled, default: false) }
        set { setEngineBool(EngineKeys.toolPruningEnabled, newValue) }
    }
    /// How many `delegate_parallel` workers run at once by default. `0` = off,
    /// and off is the default: this is the one delegation mode that costs the
    /// provider several requests per turn, so it is opt-in. A saved model's
    /// `maxConcurrentSubagents` overrides it.
    var chatSubagentConcurrency: Int {
        get { engineInt(EngineKeys.chatSubagentConcurrency, default: 0) }
        set { setEngineInt(EngineKeys.chatSubagentConcurrency, newValue) }
    }
    /// Request slots the chat model's server serves at once. `0` = unknown.
    /// A local runtime started with four parallel slots reports four here, and
    /// one slot is always kept for the parent chat — see
    /// `ParallelDelegation.effectiveWorkers`.
    var chatProviderSlots: Int {
        get { engineInt(EngineKeys.chatProviderSlots, default: 0) }
        set { setEngineInt(EngineKeys.chatProviderSlots, newValue) }
    }
    /// The read-only `file__*` tools (find/read/search/hash/hex). On by
    /// default: every one of them only reads — strictly narrower than the
    /// Python tool, which is also opt-in — and they replace ~1,400
    /// hand-coded shell/python snippets in a long project chat.
    var fileToolEnabled: Bool {
        get { engineBool(EngineKeys.fileToolEnabled, default: true) }
        set { setEngineBool(EngineKeys.fileToolEnabled, newValue) }
    }
    /// Whether `file__find` / `file__search` may descend into a **network
    /// volume** (SMB, NFS, AFP, WebDAV, the automounter). Off by default: a
    /// walk that reaches a dead share can sit in the kernel for minutes, so
    /// allowing it at all is opt-in — and every walk it allows is still
    /// bounded by `FileToolbox.walkTimeoutSeconds`.
    var fileToolNetworkVolumesEnabled: Bool {
        get { engineBool(EngineKeys.fileToolNetworkVolumesEnabled, default: false) }
        set { setEngineBool(EngineKeys.fileToolNetworkVolumesEnabled, newValue) }
    }
    /// Whether the `shell__run` tool exists. Off by default: a shell command
    /// is opaque in a way a script is not (`ls` and `rm -rf ~/Documents` look
    /// equally short on a card), so offering it at all is a deliberate
    /// choice. Every run is approved per call and YOLO never automates one;
    /// only an explicit "Always allow" rule for that command can skip a card.
    var shellToolEnabled: Bool {
        get { engineBool(EngineKeys.shellToolEnabled, default: false) }
        set { setEngineBool(EngineKeys.shellToolEnabled, newValue) }
    }
    /// Run shell commands under macOS `sandbox-exec`: no network, writes
    /// limited to a per-run scratch folder. Setuid binaries (sudo) cannot run
    /// inside, which is why elevated shell commands are refused outright.
    var shellSandboxEnabled: Bool {
        get { engineBool(EngineKeys.shellSandboxEnabled, default: true) }
        set { setEngineBool(EngineKeys.shellSandboxEnabled, newValue) }
    }
    /// The master opt-in for Bypass Permissions (see `BypassPermissions`).
    /// Off by default, and it is only ever the *first* of two switches: the
    /// mode itself is a per-conversation flag on the agent, and this one only
    /// decides whether that flag may take effect.
    var bypassPermissionsUnlocked: Bool {
        get { engineBool(EngineKeys.bypassPermissionsUnlocked, default: false) }
        set { setEngineBool(EngineKeys.bypassPermissionsUnlocked, newValue) }
    }
    /// Whether the mode is in force for a conversation: the per-chat flag is
    /// set *and* the master opt-in is on. One place for the rule, so the
    /// agent, the executor and the chat chrome can never disagree.
    func bypassPermissionsActive(chatBypass: Bool) -> Bool {
        chatBypass && bypassPermissionsUnlocked
    }
    /// Whether the model may author skills (`skill__create`, `skill__update`,
    /// `skill__add_attachment`, `skill__delete`). Creates and writes are
    /// approved per call; deletes are always manual.
    var skillAuthoringEnabled: Bool {
        get { engineBool(EngineKeys.skillAuthoringEnabled, default: true) }
        set { setEngineBool(EngineKeys.skillAuthoringEnabled, newValue) }
    }
    /// Whether the model may configure MCP servers (`mcp__add_server`,
    /// `mcp__remove_server`, `mcp__set_server_enabled`). Every call is
    /// approved: adding a server is a standing grant of new tools to every
    /// future chat, which is exactly the kind of decision that must not be
    /// made silently.
    var mcpAuthoringEnabled: Bool {
        get { engineBool(EngineKeys.mcpAuthoringEnabled, default: false) }
        set { setEngineBool(EngineKeys.mcpAuthoringEnabled, newValue) }
    }
    /// Lazy MCP tools: server tools are not declared with every request.
    /// They are callable through `code__execute` scripts as always, and the
    /// `agent__tool_search` tool loads the matches so they can be called
    /// directly. Off by default — it changes what the model can see, so it
    /// is an opt-in trade: a much smaller prompt against a discovery round
    /// before a server tool's first use.
    var mcpToolsDeferred: Bool {
        get { engineBool(EngineKeys.mcpToolsDeferred, default: false) }
        set { setEngineBool(EngineKeys.mcpToolsDeferred, newValue) }
    }
    /// Whether an unattended run may retry after a failure. Off by default:
    /// an unattended run makes one attempt and a failure ends it. Chats are
    /// unaffected either way (see `RequestRetries`).
    var retryFailedScheduledRuns: Bool {
        get { engineBool(EngineKeys.retryFailedScheduledRuns, default: false) }
        set { setEngineBool(EngineKeys.retryFailedScheduledRuns, newValue) }
    }
    /// The master switch for screen capture and OCR. Off means the screen
    /// tool is not offered at all, whatever the per-tool toggle says.
    var screenCaptureAllowed: Bool {
        get { engineBool(EngineKeys.screenCaptureAllowed, default: true) }
        set { setEngineBool(EngineKeys.screenCaptureAllowed, newValue) }
    }
    /// Whether the calculator tool (`calculator__evaluate_math`) is offered.
    /// On by default: exact math is the one thing language models reliably
    /// get wrong, and the tool is read-only.
    var calculatorToolEnabled: Bool {
        get { engineBool(EngineKeys.calculatorToolEnabled, default: true) }
        set { setEngineBool(EngineKeys.calculatorToolEnabled, newValue) }
    }
    /// The user's standing extra instructions for the chat system prompt.
    /// (Project-level instructions live in `.typstedit` guidelines and are
    /// injected separately.)
    var systemPrompt: String {
        get { UserDefaults.standard.string(forKey: EngineKeys.systemPrompt) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: EngineKeys.systemPrompt)
            objectWillChange.send()
        }
    }

    // MARK: Per-model overrides resolved for a request

    /// The turn budget a chat request actually runs with: the model's
    /// override, else the global setting. `nil` = unlimited.
    func effectiveMaxTurns(for ctx: ModelContext) -> Int? {
        if let override = ctx.maxTurns { return override > 0 ? override : nil }
        return maxTurns > 0 ? maxTurns : nil
    }

    /// The repeat-guard limit a chat request actually runs with: the
    /// model's override, else the global setting. `0` = off.
    func effectiveRepeatCallLimit(for ctx: ModelContext) -> Int {
        ctx.repeatCallLimit ?? repeatCallLimit
    }

    /// How many subagents `delegate_parallel` may run at once: the model's
    /// override, else the global setting, then capped by the server's real
    /// slot count so the parent chat always keeps one. `0` = off.
    ///
    /// Resolved through `ParallelDelegation` rather than read directly,
    /// because the cap is arithmetic — `slots - 1` — and a caller that did
    /// its own subtraction would sooner or later disagree with the gate
    /// about how many permits exist.
    func effectiveSubagentConcurrency(for ctx: ModelContext) -> Int {
        let requested = ctx.maxConcurrentSubagents ?? chatSubagentConcurrency
        let slots = ctx.providerSlots > 0 ? ctx.providerSlots : chatProviderSlots
        return ParallelDelegation.workers(for: requested, slots: slots)
    }

    /// The server's slot count a chat request runs with: the model's own
    /// figure, else the global one. `0` = unknown.
    func effectiveProviderSlots(for ctx: ModelContext) -> Int {
        ctx.providerSlots > 0 ? ctx.providerSlots : chatProviderSlots
    }

    /// Whether the model is asked to name its intent in one sentence before
    /// each tool call: the model's override, else off.
    func effectiveToolIntentNotesEnabled(for ctx: ModelContext) -> Bool {
        ctx.toolIntentNotesEnabled ?? false
    }

    // MARK: Learned output budget

    /// Output budgets a request had to widen to finish, remembered per model
    /// so the next conversation starts at the size that already worked
    /// instead of burning a failed request relearning it.
    ///
    /// Without this, the doubling that rescues a cut-off reply lives only in
    /// that one request's loop — every new conversation starts back at
    /// `chatMaxTokens`, and a reasoning model whose hidden thinking alone
    /// exceeds it hits "Reply was cut off — retrying" on the first reply,
    /// every time. The remembered value is a floor, not a cap: the in-loop
    /// doubling still applies on top of it, and the user's own
    /// `chatMaxTokens` change re-seeds it.
    var learnedMaxTokens: [String: Int] {
        get {
            guard let data = UserDefaults.standard.data(forKey: EngineKeys.learnedMaxTokens),
                  let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: EngineKeys.learnedMaxTokens)
            }
            objectWillChange.send()
        }
    }

    /// The largest output budget that can be learned for a model. The
    /// service's widening ceiling is the same number, so "the budget can
    /// grow" and "the budget can be remembered at that size" never disagree.
    nonisolated static let learnedMaxTokensCeiling = 32_768

    /// A stable key for a model configuration: provider + model + endpoint
    /// + reasoning effort — the parts that change how long a reply runs.
    /// The API key is deliberately not part of it (rotating a key should not
    /// forget the budget).
    static func learnedBudgetKey(for ctx: ModelContext) -> String {
        "\(ctx.source.rawValue)|\(ctx.model)|\(ctx.endpoint)|\(ctx.reasoningEffort.rawValue)"
    }

    /// The starting output budget for a request: the largest budget this
    /// model ever needed, floored at the user's setting. The in-loop
    /// doubling can still raise it within a request.
    func effectiveMaxTokens(for ctx: ModelContext, setting: Int) -> Int {
        let key = Self.learnedBudgetKey(for: ctx)
        if let learned = learnedMaxTokens[key], learned > setting {
            return min(learned, Self.learnedMaxTokensCeiling)
        }
        return setting
    }

    /// Records that this model needed `tokens` of output budget to finish a
    /// reply, so future requests start there instead of retrying up to it.
    func rememberMaxTokens(_ tokens: Int, for ctx: ModelContext) {
        let key = Self.learnedBudgetKey(for: ctx)
        let clamped = min(tokens, Self.learnedMaxTokensCeiling)
        guard clamped > (learnedMaxTokens[key] ?? 0) else { return }
        var updated = learnedMaxTokens
        updated[key] = clamped
        learnedMaxTokens = updated
    }

    // MARK: Observed reasoning cost

    /// The most hidden-reasoning tokens this model has been observed to spend
    /// on a single request. Reported by the provider in `usage`, not guessed.
    ///
    /// This is what makes budgeting ahead-of-time possible: a reasoning
    /// model's thinking is a large, repeatable cost that lands *before* any
    /// visible answer, so an output cap below it guarantees a cut-off reply
    /// no matter how short the answer would have been. Knowing the observed
    /// peak lets the first request of a turn start above it.
    var observedReasoningPeak: [String: Int] {
        get {
            guard let data = UserDefaults.standard.data(forKey: EngineKeys.observedReasoningPeak),
                  let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: EngineKeys.observedReasoningPeak)
            }
            objectWillChange.send()
        }
    }

    /// Records a response's reasoning cost for a model, keeping the peak.
    /// Only a non-zero, provider-reported value counts — servers that report
    /// nothing must not set a floor of zero that looks like evidence.
    func rememberReasoningUsage(_ reasoningTokens: Int, for ctx: ModelContext) {
        guard reasoningTokens > 0 else { return }
        let key = Self.learnedBudgetKey(for: ctx)
        guard reasoningTokens > (observedReasoningPeak[key] ?? 0) else { return }
        var updated = observedReasoningPeak
        updated[key] = min(reasoningTokens, Self.learnedMaxTokensCeiling)
        observedReasoningPeak = updated
    }

    /// A starting budget derived from observed reasoning, when there is any:
    /// the reasoning peak plus the user's configured budget for the visible
    /// answer. `nil` when no reasoning has been observed (a non-reasoning
    /// model, or a provider that does not report it) — the caller then keeps
    /// the plain setting.
    func reasoningAwareMaxTokens(for ctx: ModelContext, setting: Int) -> Int? {
        guard let peak = observedReasoningPeak[Self.learnedBudgetKey(for: ctx)], peak > 0 else {
            return nil
        }
        // Reasoning has to fit *inside* the cap, and a cut-off at `setting`
        // means the thinking alone can exceed it. Give the thinking its own
        // headroom on top of the answer budget the user chose.
        let suggested = peak + setting
        guard suggested > setting else { return nil }
        return min(suggested, Self.learnedMaxTokensCeiling)
    }

    /// Forgets the learned budgets (Settings' "Reset" for these values).
    func clearLearnedMaxTokens() {
        learnedMaxTokens = [:]
        observedReasoningPeak = [:]
    }

    /// How little of the output ceiling is left for a written answer once
    /// this model's observed hidden reasoning is accounted for.
    ///
    /// The output cap covers thinking *and* answer, and the provider stops
    /// counting at the cap. So a model observed spending 30,000 tokens on
    /// reasoning inside a 32,768 ceiling can answer, but only for ~2,700
    /// tokens — which is fine for a sentence and not for a review. Past this
    /// point the honest fix is a lower reasoning effort or a bigger ceiling,
    /// not another retry.
    struct ReasoningHeadroom: Equatable {
        /// The most hidden reasoning this model has been seen to spend.
        var peak: Int
        /// `ceiling - peak`, floored at zero.
        var remaining: Int
        /// How much of a written answer is assumed to be needed.
        var answerRoom: Int

        /// False when the observed reasoning alone eats the ceiling, or the
        /// remaining room cannot hold a real answer.
        var isSufficient: Bool { remaining >= answerRoom }
    }

    /// The headroom for a model, or `nil` when no reasoning has been
    /// observed for it.
    func reasoningHeadroom(for ctx: ModelContext, answerRoom: Int = 1_024) -> ReasoningHeadroom? {
        guard let peak = observedReasoningPeak[Self.learnedBudgetKey(for: ctx)], peak > 0 else { return nil }
        let remaining = max(0, Self.learnedMaxTokensCeiling - peak)
        return ReasoningHeadroom(peak: peak, remaining: remaining, answerRoom: answerRoom)
    }
}
