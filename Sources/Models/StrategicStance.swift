import Foundation

/// How the harness should work a chat, chosen from a list beside the composer.
///
/// ## What a strategy is, and is not
///
/// A strategy is a *process* setting, never a subject. "Coding" is not one:
/// the model already detects a code fence. "Engineering" is, because it says
/// how the answer is reached — testable requirements, alternatives compared
/// before one is chosen, a risk register, another iteration when verification
/// fails. Topic belongs in the message; the process belongs here.
///
/// ## The three levers
///
/// A strategy that only adds a sentence to the prompt is a suggestion. These
/// three make it a setting:
///
/// 1. `systemNote` — a few sentences for the **stable** half of the system
///    prompt, so it sits behind the Anthropic cache breakpoint and costs
///    nothing to repeat every turn. Never the volatile half (see
///    `AIChatManager.buildSystemPromptHalves`).
/// 2. `method` — the `CaseMethod` a case opens with, and therefore its gates.
///    This is where strategy gets its teeth: `engineering` requires a trade
///    study, `incident` requires a closed risk register. Prose cannot enforce
///    that; a gate can.
/// 3. `planMode` — whether the chat starts read-only. `Direct` and `Critique`
///    start read-only because they should look, not touch.
///
/// ## Auto
///
/// `auto` carries no note of its own. It reads the draft with a local
/// heuristic (`StrategicStance.heuristicStance(for:)`) and adopts another
/// strategy for that message. No model call, no latency, no cost — a
/// classifier call before every Auto message would be a tax on every turn to
/// save one click on some turns.
///
/// ## Extensibility
///
/// The built-ins are a starting set. A JSON file in the same
/// `~/Library/Application Support/TypstEdit/Methods/` folder as case methods,
/// carrying a `strategy` (or just the strategy fields), appears in the chip.
/// See `StrategyLibrary`.
struct StrategicStance: Codable, Equatable, Identifiable {
    /// Short, lowercase, unique: `engineering`, `incident-review`.
    var id: String
    var name: String
    /// The chip's one-word label; the full name may be longer.
    var shortName: String
    /// One line on when to choose it, for the menu and the tooltip.
    var summary: String
    /// A symbol from SF Symbols, so the chip reads at a glance.
    var icon: String
    /// The guidance for the stable half of the system prompt. Empty for
    /// `auto`, which borrows another strategy's note instead.
    var systemNote: String
    /// The case method a goal-directed case opens with. Empty = no case is
    /// offered, and the model stays free to propose one itself.
    var methodID: String
    /// Start the chat read-only (Plan mode).
    var planMode: Bool
    /// The literal `auto` stance: infer, do not instruct.
    var isAuto: Bool

    init(
        id: String,
        name: String,
        shortName: String = "",
        summary: String = "",
        icon: String = "sparkles",
        systemNote: String = "",
        methodID: String = "",
        planMode: Bool = false,
        isAuto: Bool = false
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName.isEmpty ? name : shortName
        self.summary = summary
        self.icon = icon
        self.systemNote = systemNote
        self.methodID = methodID
        self.planMode = planMode
        self.isAuto = isAuto
    }

    /// Problems with a strategy file, for Settings. Empty means it loads.
    var problems: [String] {
        var problems: [String] = []
        if id.isEmpty || id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            problems.append("id must be letters, digits, - or _")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name is empty") }
        if !methodID.isEmpty, !CaseMethod.builtIn.contains(where: { $0.id == methodID }) {
            // A user method file may legitimately supply it, so this is a
            // warning about the built-ins, not a load failure.
            problems.append("method \"\(methodID)\" is not built in (a method file may still provide it)")
        }
        return problems
    }

    // MARK: - Built in

    /// Infer from the draft. The chip shows what it picked.
    static let auto = StrategicStance(
        id: "auto",
        name: "Auto",
        summary: "Read the draft and adopt the strategy that fits it.",
        icon: "wand.and.stars",
        isAuto: true
    )

    /// Today's behaviour: no steering, no case, no gates.
    static let general = StrategicStance(
        id: "general",
        name: "General",
        shortName: "General",
        summary: "Ordinary conversation. No charter, no gates, fastest path.",
        icon: "bubble.left",
        systemNote: "",
        methodID: ""
    )

    /// One-turn answers: no preamble, no plan, no hedging.
    static let direct = StrategicStance(
        id: "direct",
        name: "Direct",
        shortName: "Direct",
        summary: "Answer or do it in one turn. No preamble, no plan, no hedging.",
        icon: "arrow.right.circle",
        systemNote: "Answer directly. Skip the preamble, the plan and the caveats: say the thing, or make the change, and stop. If the request is a lookup or a single edit, do it and report the result in one or two sentences. Do not narrate what you are about to do — the user can see the tool calls.",
        methodID: ""
    )

    /// Divergent options, no commitment. Replaces "Creative".
    static let exploratory = StrategicStance(
        id: "exploratory",
        name: "Exploratory",
        shortName: "Explore",
        summary: "Several genuinely different options, no premature commitment.",
        icon: "square.stack.3d.up",
        systemNote: "Explore before converging. Offer several genuinely different approaches or directions rather than one safe answer, and say what each one gives up. Do not commit to one until the user steers you, or until the request plainly names it. Reach for concrete, specific ideas over generic ones; do not pad the list to look thorough.",
        methodID: "inquiry"
    )

    /// Definitions first, claims with their refutations, adversarial review.
    static let analytical = StrategicStance(
        id: "analytical",
        name: "Analytical",
        shortName: "Analyse",
        summary: "Pin down the terms, state claims with what would refute them.",
        icon: "scalemass",
        systemNote: "Work analytically. Before answering, pin down what the key terms mean in this context and say so briefly. State each substantive claim with the grounds for it and with what would count as refuting it. Prefer the explanation that would be easiest to prove wrong. Separate what is established from what is inferred, and name the inference.",
        methodID: "inquiry"
    )

    /// Every claim carries a source or an explicit "unverified".
    static let research = StrategicStance(
        id: "research",
        name: "Research",
        shortName: "Research",
        summary: "Every claim cited or marked unverified. Look before concluding.",
        icon: "text.magnifyingglass",
        systemNote: "Research what you do not already know instead of answering from memory. Every factual claim must either carry its source (a fetched page, a file and line, a tool output) or be marked plainly as unverified, with your confidence. Never present a recalled fact and a checked fact in the same voice. Say when the sources disagree.",
        methodID: "inquiry"
    )

    /// The engineering method: requirements, a trade study, risks, iteration.
    static let engineering = StrategicStance(
        id: "engineering",
        name: "Engineering",
        shortName: "Engineer",
        summary: "Testable requirements, options compared, risks registered, iterate on failure.",
        icon: "hammer",
        systemNote: "Work like an engineer. Agree testable requirements and a budget before building, compare at least two real options before committing to one, record the risks and how each is handled, build in small verified steps, and iterate when verification fails instead of lowering the standard.",
        methodID: "engineering"
    )

    /// Do the thing, verify the state, report. Minimal talk.
    static let operations = StrategicStance(
        id: "operations",
        name: "Operations",
        shortName: "Operate",
        summary: "Run it, check the resulting state, report. Minimum talk.",
        icon: "terminal",
        systemNote: "Operate. The deliverable is a changed or verified system state, not an explanation. Make the change or run the command, then check the state you actually left behind (read the file back, run the test, query the service) and report what is true now. Prefer the reversible, least destructive route; say what you changed and how to undo it. Keep prose to what the user needs to act on.",
        methodID: ""
    )

    /// Timeline, containment, cause, prevention.
    static let incident = StrategicStance(
        id: "incident",
        name: "Incident",
        shortName: "Incident",
        summary: "Contain first, then cause, then prevention. Blameless.",
        icon: "exclamationmark.triangle",
        systemNote: "Treat this as an incident. Separate what is happening from what you believe caused it. Establish a timeline from evidence, not recollection. Contain or mitigate first if the damage is ongoing; then find the cause; then say what prevents a repeat. Stay blameless — name conditions and mechanisms, never people or motives unless the evidence demands it.",
        methodID: "inquiry"
    )

    /// Recover the design of something that already exists and cannot be read.
    static let reverse = StrategicStance(
        id: "reverse",
        name: "Reverse",
        shortName: "Reverse",
        summary: "Work out how an opaque thing works, from evidence and experiments.",
        icon: "magnifyingglass.circle",
        systemNote: """
        Work backwards from something you cannot read the design of. Never assume the internal structure: every claim about how it works must come from observable evidence — a file, a header, a call site, a byte pattern, a measured response. Run the cheapest experiment that would disprove your current model before refining it. Keep a working model separate from confirmed findings, mark each as such, and say which observation would overturn it. Reproduce the observed behaviour before explaining it, and say plainly where the evidence runs out and you are inferring.
        """,
        methodID: "inquiry"
    )

    /// Convert between formats, languages or representations without losing meaning.
    static let translate = StrategicStance(
        id: "translate",
        name: "Translate",
        shortName: "Translate",
        summary: "Carry meaning across a language, format or representation intact.",
        icon: "character.bubble",
        systemNote: """
        Preserve meaning, not shape. First pin down what the source actually conveys — its intent, its register, its implied constraint — and only then write the target. Idioms, names and idioms of the domain are not translated literally; say what you did when a choice was not obvious. Preserve comments, ordering, error behaviour and any empty-value semantics exactly, and flag any construct the target cannot express instead of silently dropping it. Check the result back against the source before presenting it.
        """,
        methodID: "inquiry"
    )

    /// Adversarial from the first turn.
    static let critique = StrategicStance(
        id: "critique",
        name: "Critique",
        shortName: "Critique",
        summary: "Find what is wrong with it. Adversarial from the first turn.",
        icon: "eye.trianglebadge.exclamationmark",
        systemNote: "Your job is to find the problems, not to praise the work and not to fix it. For each part, ask what would make it fail, what it assumes without saying, and what the author would most want not to be asked. Rank the findings by how much harm they would do. Say plainly when something is fine — a critique that invents faults is as useless as one that misses them.",
        methodID: "inquiry",
        planMode: true
    )

    static let builtIn: [StrategicStance] = [
        auto, general, direct, exploratory,
        analytical, research, engineering, reverse,
        translate, operations, incident, critique,
    ]

    /// The stances Auto may adopt. `general` is the fallback, so it is
    /// reachable but never needed as a scored candidate.
    static var inferable: [StrategicStance] {
        builtIn.filter { !$0.isAuto && $0.id != general.id }
    }

    // MARK: - Decoding

    /// A strategy file needs only `id` and `name`; everything else defaults,
    /// so a two-line file is a valid strategy.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            shortName: try container.decodeIfPresent(String.self, forKey: .shortName) ?? "",
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            icon: try container.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles",
            systemNote: try container.decodeIfPresent(String.self, forKey: .systemNote) ?? "",
            methodID: try container.decodeIfPresent(String.self, forKey: .methodID) ?? "",
            planMode: try container.decodeIfPresent(Bool.self, forKey: .planMode) ?? false,
            isAuto: try container.decodeIfPresent(Bool.self, forKey: .isAuto) ?? false
        )
    }
}

// MARK: - Auto: the local heuristic

extension StrategicStance {
    /// What Auto picks for a draft, with no model call and no latency.
    ///
    /// This is deliberately shallow. It reads the shape of the request, not
    /// its meaning, because a wrong guess is cheap — the chip shows the pick
    /// as grey text, the user overrides it with one click, and a `general`
    /// fallback is never wrong so much as unhelpful. A real classifier would
    /// cost a round trip on every Auto message to save a click on a few.
    ///
    /// The order matters: a request that both breaks and builds is an
    /// incident, and one that both asks and builds is engineering.
    static func heuristicStance(for draft: String) -> StrategicStance {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .general }
        let lower = text.lowercased()

        func hasAny(_ needles: [String]) -> Bool {
            needles.contains { lower.contains($0) }
        }
        /// Whole-word match, so "postgres" does not read as "post".
        func hasWord(_ words: [String]) -> Bool {
            let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return words.contains { tokens.contains($0) }
        }

        // 1. Something is broken or down: contain before anything else.
        if hasAny(["not working", "broken", "is down", "went down", "is failing",
                   "failing in production", "outage", "incident", "crashed",
                   "regression", "stopped working"]) {
            return .incident
        }

        // 2. Review of existing work.
        if hasAny(["review this", "review my", "what's wrong with", "what is wrong with",
                   "pick apart", "critique", "tear apart", "find the bugs",
                   "code review", "audit"]) {
            return .critique
        }

        // 2b. Recovering the design of something opaque. Ranks above a build
        // because "why does this binary do X" is a question about existing
        // code, not a request to write new code.
        if hasAny(["reverse engineer", "reverse-engineer", "figure out how",
                   "how does this work", "what does this binary", "disassemble",
                   "decompile", "how is this implemented", "trace how"]) {
            return .reverse
        }

        // 2c. Carrying meaning across a boundary: a language, a format, a
        // representation. Ranked above the build verbs so "port this Python
        // to Rust" is a translation, not a fresh implementation.
        if hasAny(["translate", "translation", "port this", "port it",
                   "convert this", "convert it to", "rewrite in", "rewrite it in",
                   "to python", "to swift", "to rust", "to typescript",
                   "to javascript", "to go", "to java", "in iambic", "into spanish",
                   "into french", "into german", "from yaml to", "from json to",
                   "from xml to"])
            // "rewrite this in X" and "rewrite the parser in X" are the same
            // request as "rewrite it in X", so the verb and the preposition
            // are matched rather than the exact phrase.
            || (hasWord(["rewrite", "resay"]) && hasAny([" in swift", " in rust",
                                                          " in python", " in go",
                                                          " in java", " in c++",
                                                          " in typescript", " in javascript"])) {
            return .translate
        }

        // 3. Build, change or fix something.
        //
        // A language name is *subject matter*, never a process signal: "what
        // is the latest Swift guidance" is research, not a build. Only a code
        // fence or a file extension shows that code is in hand. Matching bare
        // "sql" as a substring also read "SQLite" as a build, so the tokens
        // are whole-word matched.
        let buildVerbs = ["build", "implement", "add", "create", "refactor",
                          "migrate", "fix", "write", "set up", "install",
                          "configure", "deploy", "optimi", "rename"]
        let codeExtensions = [".py", ".ts", ".swift", ".js", ".rs", ".go",
                              ".java", ".kt", ".rb", ".cs", ".sql", ".json",
                              ".yaml", ".yml", ".toml"]
        if hasWord(buildVerbs) || hasAny(["make it", "change the", "update the", "port it to", "port this to"])
            || text.contains("```") || hasAny(codeExtensions) {
            return .engineering
        }

        // 4. Run something and check the result.
        if hasWord(["run", "execute", "restart", "stop", "start", "status",
                    "logs", "kill", "backup", "restore"])
            || hasAny(["on my machine", "in the terminal", "command line"]) {
            return .operations
        }

        // 5. A factual question that wants looking up.
        if hasAny(["how does", "how do", "what is", "who is", "when did",
                   "according to", "latest", "current", "source", "cite",
                   "look up", "search for", "documentation"]) {
            return .research
        }

        // 6. Ideation and open-ended exploration.
        if hasAny(["ideas", "brainstorm", "options", "alternatives", "suggest",
                   "explore", "possible", "approaches", "which way"])
            || text.contains("?") && text.split(separator: " ").count > 25 {
            return .exploratory
        }

        // 7. An argument, explanation or decision that has to hold up.
        if hasAny(["why", "should i", "should we", "trade-off", "tradeoff",
                   "compare", "better", "worse", "argue", "justify",
                   "reason", "philosoph", "ethical", "assume", "assumption"]) {
            return .analytical
        }

        // 8. Short lookups and one-line edits need no ceremony.
        if lower.split(separator: " ").count <= 6 {
            return .direct
        }

        return .general
    }
}

// MARK: - Library

/// The strategies the chip offers: the built-ins plus any JSON files in the
/// user's Methods folder. Shares that folder with `CaseMethodLibrary`, so one
/// file can define either or both — a strategy file and a method file are
/// told apart by which keys they carry.
///
/// Decodes only when a file changes, because the chip reads `stances` on
/// every layout pass.
@MainActor
final class StrategyLibrary {
    static let shared = StrategyLibrary()

    /// Posted after `invalidate()`, so the chip reloads when a file changes
    /// rather than only at the next launch. The raw name keeps Clippy's
    /// spelling so ported call sites stay in sync.
    static let didChangeNotification = Notification.Name("ClippyStrategyLibraryDidChange")

    struct LoadProblem: Equatable {
        var file: String
        var message: String
    }

    let directory: URL
    private var cache: (stamp: String, stances: [StrategicStance], problems: [LoadProblem])?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypstEdit/Methods", isDirectory: true)
    }

    var stances: [StrategicStance] { load().stances }

    var problems: [LoadProblem] { load().problems }

    func stance(id: String) -> StrategicStance? {
        stances.first { $0.id == id.lowercased() }
    }

    /// The stance to use for a stored id, falling back to `general` when the
    /// file that defined it has gone. A chat must not lose its behaviour
    /// because a settings file was renamed.
    func resolved(id: String) -> StrategicStance {
        stance(id: id) ?? .general
    }

    /// Writes the analytical strategy as a starting point for a custom one.
    @discardableResult
    func writeExample() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var example = StrategicStance.analytical
        example.id = "my-strategy"
        example.name = "My strategy"
        example.summary = "Describe when this strategy should be used."
        let url = directory.appendingPathComponent("my-strategy.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(example).write(to: url, options: .atomic)
        cache = nil
        return url
    }

    func invalidate() {
        cache = nil
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func load() -> (stances: [StrategicStance], problems: [LoadProblem]) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ))?
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        let stamp = files.map { file -> String in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(file.lastPathComponent)@\(date?.timeIntervalSinceReferenceDate ?? 0)"
        }.joined(separator: "|")
        if let cache, cache.stamp == stamp { return (cache.stances, cache.problems) }

        var stances = StrategicStance.builtIn
        var problems: [LoadProblem] = []
        var custom: [StrategicStance] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            // A method file carries `stages`/`gates` or a `strategy` wrapper;
            // a strategy file carries `systemNote`/`methodID`. Anything else
            // in the folder belongs to the case-method library, so it is not
            // a problem here.
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var payload = object
            if let nested = object["strategy"] as? [String: Any] { payload = nested }
            let isStrategy = payload["systemNote"] != nil
                || payload["methodID"] != nil
                || payload["isAuto"] != nil
                || payload["shortName"] != nil
            guard isStrategy, let id = payload["id"] as? String else { continue }

            do {
                var stance = try JSONDecoder().decode(
                    StrategicStance.self,
                    from: JSONSerialization.data(withJSONObject: payload)
                )
                stance.id = stance.id.lowercased()
                // A user file may not hijack `auto`: the inference is code.
                if stance.isAuto || stance.id == StrategicStance.auto.id { continue }
                let issues = stance.problems.filter { !$0.contains("is not built in") }
                guard issues.isEmpty else {
                    problems.append(LoadProblem(file: file.lastPathComponent, message: issues.joined(separator: "; ")))
                    continue
                }
                custom.removeAll { $0.id == stance.id }
                custom.append(stance)
            } catch {
                problems.append(LoadProblem(file: file.lastPathComponent, message: "not a valid strategy file: \(error.localizedDescription)"))
            }
        }
        for stance in custom {
            if let index = stances.firstIndex(where: { $0.id == stance.id }) {
                stances[index] = stance
            } else {
                stances.append(stance)
            }
        }
        // Built-ins keep their order; user strategies follow, by name.
        let builtInCount = StrategicStance.builtIn.count
        let tail = stances.dropFirst(builtInCount).sorted { $0.name < $1.name }
        stances = Array(stances.prefix(builtInCount)) + tail
        cache = (stamp, stances, problems)
        return (stances, problems)
    }
}
