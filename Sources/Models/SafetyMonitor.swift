import Foundation

/// A safety rule that can veto YOLO auto-approval.
///
/// It shares the `AttackDetector` shape but carries everything a rule needs
/// once it fires: a severity, and the stable id the user sees in Settings.
/// A user-authored rule (Settings → AI Chat → Safety) is the same value,
/// built from `UserSafetyRule` instead of code.
struct SafetyRule: Sendable, Identifiable, Equatable {
    enum Severity: String, Codable, CaseIterable, Sendable {
        case watch
        case alert

        var title: String {
            switch self {
            case .watch: return "Watch"
            case .alert: return "Alert"
            }
        }

        /// How the rule reads in a settings row.
        var symbol: String {
            switch self {
            case .watch: return "exclamationmark.circle"
            case .alert: return "exclamationmark.triangle.fill"
            }
        }
    }

    /// Stable identifier, persisted in nothing but used for de-duplication.
    let id: String
    let title: String
    let severity: Severity
    /// One sentence shown on the approval card and in Settings.
    let explanation: String
    let detector: AttackDetector

    init(
        id: String,
        title: String,
        severity: Severity,
        explanation: String,
        detector: AttackDetector
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.explanation = explanation
        self.detector = detector
    }

    static func == (lhs: SafetyRule, rhs: SafetyRule) -> Bool {
        lhs.id == rhs.id
    }
}

/// A rule the user wrote in Settings. Stored as JSON in `UserDefaults`, so it
/// has to be `Codable` and forgiving: an unknown matcher or an invalid regex
/// must not make the whole rule set undecodable.
struct UserSafetyRule: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// A tool ran at all.
        case toolCalled
        /// A tool ran more than `threshold` times.
        case toolCalledOften
        /// A tool ran with an argument matching `matcher`.
        case toolCalledWithArgument
        /// Any tool output matched `pattern`.
        case outputMatched

        var title: String {
            switch self {
            case .toolCalled: return "A tool is called"
            case .toolCalledOften: return "A tool is called more than N times"
            case .toolCalledWithArgument: return "A tool is called with an argument that matches"
            case .outputMatched: return "A tool's output matches"
            }
        }
    }

    var id = UUID()
    var isEnabled = true
    /// The sentence shown when the rule fires.
    var title: String
    var kind: Kind
    /// Qualified tool name, e.g. `python__run`. Empty for `.outputMatched`,
    /// which scans every call's output.
    var toolName: String
    /// Argument name for `.toolCalledWithArgument`, e.g. `path`.
    var argumentName: String
    /// Matcher for `.toolCalledWithArgument`.
    var matcher: ArgumentMatcher
    /// Threshold for `.toolCalledOften`.
    var threshold: Int
    /// Regular expression for `.outputMatched`.
    var pattern: String

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        title: String,
        kind: Kind,
        toolName: String = "",
        argumentName: String = "",
        matcher: ArgumentMatcher = .contains(""),
        threshold: Int = 3,
        pattern: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.title = title
        self.kind = kind
        self.toolName = toolName
        self.argumentName = argumentName
        self.matcher = matcher
        self.threshold = threshold
        self.pattern = pattern
    }

    /// The rule as a detector, or `nil` when the rule is incomplete enough
    /// that it would match everything (an empty tool name, a blank pattern).
    /// A half-written rule must never silently veto every call.
    func makeRule() -> SafetyRule? {
        let trimmedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let detector: AttackDetector

        switch kind {
        case .toolCalled:
            guard !trimmedTool.isEmpty else { return nil }
            detector = .toolsCalled([trimmedTool])

        case .toolCalledOften:
            guard !trimmedTool.isEmpty else { return nil }
            detector = .countToolCalls(trimmedTool, threshold: max(1, threshold))

        case .toolCalledWithArgument:
            let name = argumentName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTool.isEmpty, !name.isEmpty else { return nil }
            if case .matches(let pattern) = matcher, pattern.isEmpty { return nil }
            detector = .toolCalledWithArgs(trimmedTool, [name: matcher])

        case .outputMatched:
            guard !trimmedPattern.isEmpty,
                  Self.isValidRegex(trimmedPattern)
            else { return nil }
            detector = .logContains(trimmedPattern, caseSensitive: false)
        }

        let displayTitle = title.isEmpty ? kind.title : title
        return SafetyRule(
            id: id.uuidString,
            title: displayTitle,
            severity: .alert,
            explanation: "Your rule “\(displayTitle)” matched this call.",
            detector: detector
        )
    }

    /// Whether `pattern` compiles, so a typo in Settings cannot silently
    /// disable a detector (or crash the match).
    static func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }
}

// MARK: - Built-in rules

/// The rules TypstEdit ships with, and the single place that decides whether
/// a trace may skip an approval card.
///
/// These are the preventive reading of SafeAgents' attack detection. Upstream
/// asks "did a dangerous tool get called?" after the run; TypstEdit has real
/// reach on a real Mac, so the same predicates run *before* YOLO can wave a
/// call through. A hit never blocks a tool — it only forces the approval
/// card that YOLO would otherwise have skipped. The human is still the gate.
///
/// Tool names are TypstEdit's own qualified names (`project__`,
/// `python__`, `git__`), not Clippy's (`reference__`, `web__`).
///
/// The prefixes are written out rather than read from `LocalToolExecutor`'s
/// and `GitTools`' `namespace` constants: those are main-actor isolated, and
/// the detectors have to be usable from a nonisolated context. `Self.assertNamespaces`
/// in the tests checks they still agree.
enum SafetyMonitor {

    /// The `project`/`python`/`git` namespace prefixes, spelled out.
    static let projectPrefix = "project__"
    static let pythonPrefix = "python__"
    static let gitPrefix = "git__"

    /// File-mutating tools the harness offers.
    static let fileWriteTools = [
        projectPrefix + "write_file",
        projectPrefix + "edit_file",
        projectPrefix + "apply_patch",
        projectPrefix + "move_lines",
        projectPrefix + "merge_sections",
        projectPrefix + "copy_files",
    ]

    /// The network-egress tools: a web fetch, and a Python run that is not
    /// sandboxed (the sandbox has no network, so the detector would be a
    /// false alarm for it — the tool name alone cannot tell, so both forms
    /// of the check live in the explanation instead).
    static let networkTools = [
        projectPrefix + "web_fetch",
    ]

    /// A file name that looks like it holds a credential.
    private static let secretPathPattern =
        "(id_rsa|id_ed25519|\\.ssh|credentials|\\.env$|secret|token|password|\\.pem$|keychain)"

    /// Built-in rules. Each one names a combination that a person should see
    /// before it happens, even in YOLO mode.
    static var builtInRules: [SafetyRule] {
        [
            SafetyRule(
                id: "overwriting_write_sweep",
                title: "Sweep of file writes",
                severity: .watch,
                explanation: "This turn is writing files over and over. YOLO can automate one write, not a sweep.",
                detector: .countToolCalls(projectPrefix + "write_file", threshold: 4)
            ),
            SafetyRule(
                id: "credential_read_then_egress",
                title: "Secret-looking file, then a network call",
                severity: .alert,
                explanation: "A file whose name looks like it holds credentials was read, and this turn also reached the network. That is the shape of an exfiltration.",
                detector: .allOf(
                    .toolCalledWithArgs(projectPrefix + "read_file", [
                        "path": .matches(secretPathPattern)
                    ]),
                    .toolsCalled(networkTools)
                )
            ),
            SafetyRule(
                id: "python_then_egress",
                title: "Script run, then a network call",
                severity: .watch,
                explanation: "A Python script ran and this turn also reached the network. Worth a look before YOLO runs the next one.",
                detector: .allOf(
                    .toolsCalled([pythonPrefix + "run"]),
                    .toolsCalled(networkTools)
                )
            ),
            SafetyRule(
                id: "secret_read_then_git_push",
                title: "Secret-looking file read, then a Git push",
                severity: .alert,
                explanation: "A file that looks like it holds credentials was read, and this turn tried to push. Publishing is the one place that must never carry a secret out.",
                detector: .allOf(
                    .toolCalledWithArgs(projectPrefix + "read_file", [
                        "path": .matches(secretPathPattern)
                    ]),
                    .toolsCalled([gitPrefix + "git_push"])
                )
            ),
            SafetyRule(
                id: "repeated_script_runs",
                title: "Many script runs in one turn",
                severity: .watch,
                explanation: "This turn has run more scripts than a person usually reviews. YOLO should hand the next one back to you.",
                detector: .countToolCalls(pythonPrefix + "run", threshold: 5)
            ),
            SafetyRule(
                id: "secret_contents_in_output",
                title: "Tool output looks like a private key",
                severity: .alert,
                explanation: "A tool returned what looks like a private key or a password line. Check what the assistant is about to do with it.",
                detector: .logContains("(-----BEGIN [A-Z ]*PRIVATE KEY-----|password\\s*[:=]\\s*\\S+)", caseSensitive: false)
            ),
        ]
    }

    /// Every rule that applies, built-ins first, with the user's enabled and
    /// well-formed rules after them.
    static func rules(userRules: [UserSafetyRule]) -> [SafetyRule] {
        let custom = userRules
            .filter(\.isEnabled)
            .compactMap { $0.makeRule() }
        return builtInRules + custom
    }

    /// The rules that fired for `trace`.
    static func hits(for trace: SafetyTrace, userRules: [UserSafetyRule]) -> [SafetyRule] {
        rules(userRules: userRules).filter { $0.detector(trace) }
    }

    /// Whether `kind` may skip its approval card.
    ///
    /// This is the whole point of the feature, so the rule is deliberately
    /// blunt: a trace match can only ever *remove* an auto-approval, never
    /// add one. `canAutoApprove` keeps the final say on kinds that are
    /// always manual, and this can only narrow it further.
    ///
    /// `monitorEnabled` is the Settings toggle. Off, the monitor stands down
    /// entirely — YOLO and saved allow rules decide on their own, which is
    /// what "off" has to mean for the switch to be worth having.
    static func canAutoApprove(
        kind: PendingApprovalKind,
        yoloMode: Bool,
        rules: [PermissionRule],
        trace: SafetyTrace,
        userRules: [UserSafetyRule],
        monitorEnabled: Bool = true
    ) -> Bool {
        // A fetch that carries a saved site sign-in is a credentialed request,
        // so it is never automated on the strength of the cookies alone: the
        // user has to approve that host by hand in this conversation first.
        // Without this, YOLO would turn a one-off sign-in into standing
        // permission to act as the user on that site. Checked before the
        // rules, because no allow rule can supply that human decision.
        if case .webFetch(_, let siteHost) = kind, let siteHost {
            guard humanApprovedWebHosts.contains(siteHost.lowercased()) else { return false }
        }
        // Deny rules refuse outright — that is the executor's call, checked
        // before this one. Here we only decide whether the card may be skipped.
        if case .deny = PermissionRules.decision(for: kind, rules: rules) { return false }
        guard PermissionRules.mayAutoApprove(kind, yoloMode: yoloMode, rules: rules) else { return false }
        guard monitorEnabled else { return true }
        return hits(for: trace, userRules: userRules).isEmpty
    }

    /// The signed-in web hosts this conversation's transcript says the user
    /// approved by hand. Rebuilt once per approval check by the chat, which
    /// owns the transcript.
    ///
    /// Kept here as a plain static so `canAutoApprove` stays a pure function
    /// of (kind, mode, rules, trace, hosts) and can be tested without a chat.
    nonisolated(unsafe) static var humanApprovedWebHosts: Set<String> = []

    /// The signed-in hosts a transcript says the user approved by hand.
    ///
    /// Only `.succeeded` rows count, and that is deliberate: the loop records
    /// every thrown refusal as `.failed`, so a status test like "was not
    /// denied" would read a refusal as permission. A signed-in fetch that
    /// succeeded can only have run after a human approved it, so success is
    /// the one honest signal. A call the user approved and that then failed
    /// at the network is not remembered — the closed direction to fail in.
    static func humanApprovedWebHosts(in messages: [ChatMessage]) -> Set<String> {
        var hosts: Set<String> = []
        for message in messages where message.role == .toolCall && !message.isSubagent {
            guard message.toolName == projectPrefix + "web_fetch",
                  message.toolStatus == .succeeded else { continue }
            guard let json = message.toolArgumentsJSON,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawURL = object["url"] as? String,
                  let host = URL(string: rawURL)?.host?.lowercased() else { continue }
            hosts.insert(host)
        }
        return hosts
    }
}

/// Where the user's custom safety rules live — one JSON array in
/// `UserDefaults`, next to the permission rules. A rule this build cannot
/// decode is dropped rather than disabling every other rule with it.
@MainActor
final class SafetyRuleStore: ObservableObject {
    static let shared = SafetyRuleStore()

    @Published private(set) var userRules: [UserSafetyRule] = []

    private let defaults: UserDefaults
    private let key = "aiChatSafetyRules"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        userRules = (try? JSONDecoder().decode([UserSafetyRule].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(userRules) else { return }
        defaults.set(data, forKey: key)
    }

    func add(_ rule: UserSafetyRule) {
        userRules.append(rule)
        persist()
    }

    func update(_ rule: UserSafetyRule) {
        guard let index = userRules.firstIndex(where: { $0.id == rule.id }) else { return }
        userRules[index] = rule
        persist()
    }

    func remove(id: UUID) {
        userRules.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        userRules.removeAll()
        persist()
    }

    /// The enabled, well-formed rules, in a form the monitor can evaluate
    /// without touching the singleton (tests, background turns).
    var effectiveRules: [UserSafetyRule] {
        userRules.filter(\.isEnabled)
    }
}
