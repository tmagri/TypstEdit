import Foundation

/// How a case is worked: the names and guidance of its five stages, the
/// reviewer's brief, and which gates apply.
///
/// ## The abstraction
///
/// The stages are fixed *roles* (`CaseFile.Phase`): agree the problem,
/// propose, produce, check, conclude. Every method of arriving at a result
/// has those five, whatever it calls them — a court says discovery and
/// verdict, an engineer says requirements and release. A method names the
/// roles, says what each one asks of the model, and switches gates on or
/// off. The state machine, the evidence rules, the ratification card, the
/// review and the checkpoints are shared, so a second method costs a
/// profile instead of a second copy of the machinery.
///
/// Two methods are built in (`inquiry`, `engineering`). More can be written
/// as JSON files in `~/Library/Application Support/TypstEdit/Methods/` — see
/// `CaseMethodLibrary`. A case keeps a *copy* of its method, taken when the
/// user ratifies the charter: editing or deleting a method file later never
/// changes the rules of a case already under way.
struct CaseMethod: Codable, Equatable, Identifiable {
    struct Stage: Codable, Equatable {
        var title: String
        /// What the stage asks of the model, one line for the prompt.
        var guidance: String
    }

    struct Gates: Codable, Equatable {
        /// Alternatives that must be evaluated before leaving the proposal
        /// stage, one of them chosen. `0` = no trade study required.
        var minimumOptions: Int = 0
        /// A verdict needs every claim supported, refuted or withdrawn.
        var claimsMustBeTested: Bool = true
        /// A verdict needs every high risk mitigated or accepted by the user.
        var highRisksMustBeClosed: Bool = false
        /// Where a failed verification sends the case.
        var failedVerificationReturnsTo: CaseFile.Phase = .hypothesis

        init(
            minimumOptions: Int = 0,
            claimsMustBeTested: Bool = true,
            highRisksMustBeClosed: Bool = false,
            failedVerificationReturnsTo: CaseFile.Phase = .hypothesis
        ) {
            self.minimumOptions = minimumOptions
            self.claimsMustBeTested = claimsMustBeTested
            self.highRisksMustBeClosed = highRisksMustBeClosed
            self.failedVerificationReturnsTo = failedVerificationReturnsTo
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            minimumOptions = try container.decodeIfPresent(Int.self, forKey: .minimumOptions) ?? 0
            claimsMustBeTested = try container.decodeIfPresent(Bool.self, forKey: .claimsMustBeTested) ?? true
            highRisksMustBeClosed = try container.decodeIfPresent(Bool.self, forKey: .highRisksMustBeClosed) ?? false
            let back = try container.decodeIfPresent(CaseFile.Phase.self, forKey: .failedVerificationReturnsTo) ?? .hypothesis
            // A failure cannot send the case forward, or to the stage that
            // failed: anything later than build would skip the rework.
            failedVerificationReturnsTo = back.index <= CaseFile.Phase.build.index ? back : .build
        }
    }

    /// Short, lowercase, unique: `engineering`, `incident-review`.
    var id: String
    var name: String
    /// One line on when to choose it, for the tool description and the card.
    var summary: String
    /// Keyed by `CaseFile.Phase` raw value. A missing stage falls back to the
    /// inquiry wording, so a method file may rename only what it cares about.
    var stages: [String: Stage]
    /// The reviewer's job, in the method's terms. The objection format is
    /// appended by `CaseFile.reviewSystemPrompt`, so a custom method cannot
    /// break the parser by leaving it out.
    var review: String
    /// What the method asks of the model across all stages, one paragraph
    /// for the stable half of the system prompt.
    var guidance: String
    var gates: Gates

    func stage(_ phase: CaseFile.Phase) -> Stage {
        stages[phase.rawValue]
            ?? Self.inquiry.stages[phase.rawValue]
            ?? Stage(title: phase.rawValue.capitalized, guidance: "")
    }

    func title(for phase: CaseFile.Phase) -> String { stage(phase).title }

    /// Problems with a method file, for Settings. Empty means it loads.
    var problems: [String] {
        var problems: [String] = []
        if id.isEmpty || id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            problems.append("id must be letters, digits, - or _")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name is empty") }
        let known = Set(CaseFile.Phase.allCases.map(\.rawValue))
        let unknown = stages.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty {
            problems.append("unknown stage keys: \(unknown.joined(separator: ", ")) (use \(CaseFile.Phase.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        if gates.minimumOptions < 0 { problems.append("gates.minimumOptions cannot be negative") }
        return problems
    }

    // MARK: - Built in

    /// The legal and philosophical method: a question is pinned down, an
    /// answer argued, and the argument tested until it survives.
    static let inquiry = CaseMethod(
        id: "inquiry",
        name: "Inquiry",
        summary: "For arriving at a conclusion or an answer that has to hold up: research, analysis, a position, a diagnosis.",
        stages: [
            "discovery": Stage(title: "Discovery", guidance: "Pin down the question before answering it: agree the objective, the meaning of its key terms, the constraints and the standard (done-when criteria) with the user, then propose the charter."),
            "hypothesis": Stage(title: "Hypothesis", guidance: "Propose the approach or answer as claims, each with its grounds and with what would refute it. Prefer the explanation that would be easiest to prove wrong."),
            "build": Stage(title: "Build", guidance: "Produce the artifact. Record each decision you make as settled with its reason, and mark a criterion met only with evidence (a path and lines, a test result, a tool output)."),
            "verify": Stage(title: "Verify", guidance: "Try to refute the result instead of defending it: check every criterion against the evidence, test each claim's rebuttal, and run agent__review_case so opposing counsel can object. Answer every objection."),
            "verdict": Stage(title: "Verdict", guidance: "The standard is met and every objection is answered. State the conclusion with its evidence. Any further change to the evidence reopens the case."),
        ],
        review: "You are opposing counsel. Another assistant claims its work meets the standard in your brief. Your job is to find where it does not — not to praise it, not to fix it. For each criterion, check that the evidence really shows it. For each claim, try its rebuttal: look for the thing that would refute it. Check the constraints and the settled decisions are respected, and that nothing out of scope was done instead of the objective.",
        guidance: "Work it like a careful court: in discovery, agree what the key terms mean and what counts as done, then propose the charter and its criteria. State hypotheses as claims with their grounds and with what would refute them, record each decision as settled with its reason, and mark a criterion met only with evidence. In verify, try to break the result instead of defending it, and run agent__review_case so opposing counsel can object.",
        gates: Gates(minimumOptions: 0, claimsMustBeTested: true, highRisksMustBeClosed: false, failedVerificationReturnsTo: .hypothesis)
    )

    /// The engineering method: the best change in a poorly understood
    /// situation within the resources available (Koen). Requirements traced
    /// to verification, alternatives compared before one is chosen, risks
    /// managed, and iteration expected rather than treated as failure.
    static let engineering = CaseMethod(
        id: "engineering",
        name: "Engineering",
        summary: "For building or changing something that has to work: software, a system, a document to a spec, a process.",
        stages: [
            "discovery": Stage(title: "Requirements", guidance: "Agree the problem with the user before solving it: the objective, functional and non-functional requirements as testable criteria, constraints, what is out of scope, and the budget (turns, iterations). Then propose the charter."),
            "hypothesis": Stage(title: "Design", guidance: "Generate at least two genuinely different options and compare them against the criteria (scores 0–5) and the constraints, with their pros, cons and risks. Choose one with choose_option and say why the others lost. Record the main risks with likelihood, impact and mitigation."),
            "build": Stage(title: "Build", guidance: "Implement the chosen option in small, checkable steps. Record each design decision as settled with its reason. Prefer the simplest thing that meets the requirements; do not gold-plate."),
            "verify": Stage(title: "Verify", guidance: "Verify each requirement with a test or a measurement and mark it met with that evidence. Run agent__review_case for a design review. If verification fails, report it with failed_verification: the case goes back to Build for another iteration."),
            "verdict": Stage(title: "Release", guidance: "Every requirement is verified, every objection answered, every high risk mitigated or accepted. Summarise what was built, how it was verified, and the residual risks."),
        ],
        review: "You are the design reviewer. Another assistant claims its work meets the requirements in your brief. Find where it does not: a requirement without real verification, an untested edge case or failure mode, a constraint broken, a risk that was not mitigated, a simpler option that was dismissed without reason, or work outside the scope.",
        guidance: "Work it like an engineer: agree testable requirements and a budget first, compare at least two options before committing to one, record the risks and how each is handled, build in small verified steps, and iterate when verification fails instead of lowering the requirements.",
        gates: Gates(minimumOptions: 2, claimsMustBeTested: false, highRisksMustBeClosed: true, failedVerificationReturnsTo: .build)
    )

    static let builtIn: [CaseMethod] = [inquiry, engineering]
}

extension CaseMethod {
    /// A method file needs only `id` and `name`; everything else falls back
    /// to the inquiry method, so a short file is a valid one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CaseMethod.inquiry
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            stages: try container.decodeIfPresent([String: Stage].self, forKey: .stages) ?? [:],
            review: try container.decodeIfPresent(String.self, forKey: .review) ?? fallback.review,
            guidance: try container.decodeIfPresent(String.self, forKey: .guidance) ?? fallback.guidance,
            gates: try container.decodeIfPresent(Gates.self, forKey: .gates) ?? fallback.gates
        )
    }
}

/// The methods a case can use: the built-in ones plus any JSON files in the
/// user's Methods folder. Decodes the files only when one of them changes,
/// because the tool list (which names the methods) is rebuilt for every
/// request.
@MainActor
final class CaseMethodLibrary {
    static let shared = CaseMethodLibrary()

    struct LoadProblem: Equatable {
        var file: String
        var message: String
    }

    let directory: URL
    private var cache: (stamp: String, methods: [CaseMethod], problems: [LoadProblem])?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypstEdit/Methods", isDirectory: true)
    }

    /// Built-ins first, then user methods by name. A user file whose id
    /// matches a built-in replaces it, so the built-ins can be tuned.
    var methods: [CaseMethod] { load().methods }

    /// Files that did not load, and why.
    var problems: [LoadProblem] { load().problems }

    func method(id: String) -> CaseMethod? {
        methods.first { $0.id == id.lowercased() }
    }

    /// Writes the engineering method as a starting point for a custom one.
    @discardableResult
    func writeExample() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var example = CaseMethod.engineering
        example.id = "my-method"
        example.name = "My method"
        example.summary = "Describe when this method should be used."
        let url = directory.appendingPathComponent("my-method.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(example).write(to: url, options: .atomic)
        cache = nil
        return url
    }

    func invalidate() { cache = nil }

    private func load() -> (methods: [CaseMethod], problems: [LoadProblem]) {
        // Listing a folder of a few files is cheap; decoding them on every
        // request is not. The stamp is every file's name and modification
        // date, because an editor that saves in place does not touch the
        // folder's own date.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ))?
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        let stamp = files.map { file -> String in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(file.lastPathComponent)@\(date?.timeIntervalSinceReferenceDate ?? 0)"
        }.joined(separator: "|")
        if let cache, cache.stamp == stamp { return (cache.methods, cache.problems) }

        var methods = CaseMethod.builtIn
        var problems: [LoadProblem] = []
        var custom: [CaseMethod] = []
        for file in files {
            do {
                var method = try JSONDecoder().decode(CaseMethod.self, from: Data(contentsOf: file))
                method.id = method.id.lowercased()
                let issues = method.problems
                guard issues.isEmpty else {
                    problems.append(LoadProblem(file: file.lastPathComponent, message: issues.joined(separator: "; ")))
                    continue
                }
                custom.removeAll { $0.id == method.id }
                custom.append(method)
            } catch {
                problems.append(LoadProblem(file: file.lastPathComponent, message: "not a valid method file: \(error.localizedDescription)"))
            }
        }
        for method in custom {
            if let index = methods.firstIndex(where: { $0.id == method.id }) {
                methods[index] = method
            } else {
                methods.append(method)
            }
        }
        let builtInCount = CaseMethod.builtIn.count
        let tail = methods.dropFirst(builtInCount).sorted { $0.name < $1.name }
        methods = Array(methods.prefix(builtInCount)) + tail
        cache = (stamp, methods, problems)
        return (methods, problems)
    }
}
