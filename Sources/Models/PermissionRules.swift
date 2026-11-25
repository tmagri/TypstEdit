import Foundation

/// A saved answer to an approval card: "always allow this", or "never".
///
/// TypstEdit used to have two settings for an approvable call: ask every time,
/// or YOLO for everything. A rule sits between them, the way opencode's
/// `permissions` do: it names one kind of action and a wildcard pattern for
/// what it acts on — a file, a URL, a script — and the effect.
///
/// The limits that matter, all enforced in `PermissionRules`:
///
/// - **Allow covers exactly what YOLO may automate.** File writes and edits
///   in the project, `web_fetch`, and Python that does not ask for sudo, plus
///   the local Git calls YOLO may already repeat. Kinds YOLO always sends back
///   to a human (elevated scripts, screen captures, Git push) can never be
///   allowed by a rule either.
/// - **Deny beats allow.** If any matching rule denies, the call is refused
///   without a card, whatever else matches and whether or not YOLO is on.
/// - **The safety monitor still applies.** An allow rule skips the card the
///   same way YOLO does, so a safety rule that fires sends the call back to
///   the user exactly as it would under YOLO.
struct PermissionRule: Codable, Identifiable, Equatable, Sendable {
    /// What a rule governs. Each maps to one approval kind and one resource.
    enum Action: String, Codable, CaseIterable, Sendable {
        /// `write_file`, `edit_file` and the other file-mutating tools.
        /// Resource: the file's path relative to the project/notebook root.
        case edit
        /// `web_fetch`. Resource: the URL.
        case webfetch
        /// `run` (the Python tool). Resource: the script's code.
        case python
        /// Local Git operations that take a per-call approval. Resource:
        /// `stage:<paths>`, `commit:<branch>` or `<operation>:<branch>`.
        case git
        /// `shell__run`. Resource: the command line exactly as the model
        /// wrote it, so a rule names one command and nothing else.
        case shell

        var title: String {
            switch self {
            case .edit: return "Write or edit a file"
            case .webfetch: return "Fetch a web page"
            case .python: return "Run a Python script"
            case .git: return "Change the Git index or history"
            case .shell: return "Run a shell command"
            }
        }

        /// Placeholder for the pattern field in Settings.
        var patternHint: String {
            switch self {
            case .edit: return "notes/*  (path in the project)"
            case .webfetch: return "https://en.wikipedia.org/*"
            case .python: return "*  (matches the script's code)"
            case .git: return "stage:*  (or commit:main)"
            case .shell: return "git status  (matches the command line)"
            }
        }
    }

    enum Effect: String, Codable, CaseIterable, Sendable {
        case allow
        case deny

        var title: String {
            switch self {
            case .allow: return "Allow"
            case .deny: return "Deny"
            }
        }
    }

    var id = UUID()
    var action: Action
    /// Whole-value wildcard pattern: `*` is any run of characters (including
    /// `/`), `?` one character, `\` makes the next character literal.
    var pattern: String
    var effect: Effect
    var createdAt = Date()

    /// The rule as one line, for the approval card and the model's error.
    var summary: String {
        "\(effect.title) “\(action.title.lowercased())” for \(pattern)"
    }

    /// A rule with a blank pattern matches nothing, so a half-typed rule in
    /// Settings never silently allows (or blocks) every call.
    var isUsable: Bool {
        !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the saved rules say about one call.
enum PermissionDecision: Equatable {
    /// No rule decides: show the card (or let YOLO decide).
    case ask
    case allow(PermissionRule)
    case deny(PermissionRule)
}

/// One way to answer "Always allow…" on a card: a ready-made rule, and how
/// it reads in the menu.
struct PermissionSuggestion: Identifiable, Equatable {
    var title: String
    var rule: PermissionRule
    var id: String { rule.pattern }
}

enum PermissionRules {

    // MARK: - Requests

    /// The action and resource a card's call is checked against, or nil
    /// for kinds rules do not govern (document exports, PDF imports, copies).
    static func request(for kind: PendingApprovalKind) -> (action: PermissionRule.Action, resource: String)? {
        switch kind {
        case .fileWrite(let path, _, _, _), .fileEdit(let path, _, _, _),
             .fileMoveLines(let path, _, _, _, _):
            return (.edit, normalizedPath(path))
        case .batchPatch(let changes):
            // A batch patch touches several files; the rule has to cover the
            // batch, so the resource is the first (canonical) path and every
            // path is checked separately by `batchDenied`.
            guard let first = changes.first else { return nil }
            return (.edit, normalizedPath(first.path))
        case .webFetch(let url, _):
            return (.webfetch, normalizedURL(url))
        case .runPython(let code, _, _):
            return (.python, code)
        case .runShell(let command):
            return (.shell, command)
        case .gitStage, .gitCommit, .gitNetwork:
            return (.git, gitResource(for: kind))
        default:
            return nil
        }
    }

    /// The Git resource string a rule matches: the operation plus what it
    /// acts on, so `commit:main` and `push:main` are different rules.
    static func gitResource(for kind: PendingApprovalKind) -> String {
        switch kind {
        case .gitStage(_, let stage):
            return stage ? "stage:*" : "unstage:*"
        case .gitCommit(_, _, let branch, _):
            return "commit:\(branch)"
        case .gitNetwork(let operation, let branch, _):
            return "\(operation.rawValue.lowercased()):\(branch)"
        default:
            return ""
        }
    }

    // MARK: - Decisions

    static func decision(for kind: PendingApprovalKind, rules: [PermissionRule]) -> PermissionDecision {
        guard let request = request(for: kind) else { return .ask }
        // A batch patch is only allowed when every file in it matches. The
        // deny side is stricter: one denied path refuses the whole batch.
        if case .batchPatch(let changes) = kind {
            for change in changes {
                let path = normalizedPath(change.path)
                if let deny = rules.first(where: {
                    $0.action == .edit && $0.effect == .deny && $0.isUsable
                        && matches(pattern: $0.pattern, value: path, caseInsensitive: true)
                }) {
                    return .deny(deny)
                }
            }
        }
        let matching = rules.filter { rule in
            rule.action == request.action && rule.isUsable
                && matches(pattern: rule.pattern, value: request.resource,
                           caseInsensitive: request.action == .edit)
        }
        if let deny = matching.first(where: { $0.effect == .deny }) {
            return .deny(deny)
        }
        // A rule can only allow what YOLO could: this is the line that keeps
        // an elevated script or a screen capture manual.
        guard kind.canAutoApprove(yoloMode: true) else { return .ask }
        if case .batchPatch(let changes) = kind {
            let allows = matching.filter { $0.effect == .allow }
            guard !allows.isEmpty else { return .ask }
            let everyFileCovered = changes.allSatisfy { change in
                let path = normalizedPath(change.path)
                return allows.contains { matches(pattern: $0.pattern, value: path, caseInsensitive: true) }
            }
            if everyFileCovered, let first = allows.first { return .allow(first) }
            return .ask
        }
        if let allow = matching.first(where: { $0.effect == .allow }) {
            return .allow(allow)
        }
        return .ask
    }

    /// A deny rule refuses the call outright, before any card is shown. This
    /// is checked by the executor separately so a denied call never even
    /// reaches the approval queue.
    static func denial(for kind: PendingApprovalKind, rules: [PermissionRule]) -> PermissionRule? {
        if case .deny(let rule) = decision(for: kind, rules: rules) { return rule }
        return nil
    }

    /// Whether `kind` may skip its card before the safety monitor has its
    /// say: YOLO allows it, or a saved rule does. Deny rules are checked
    /// separately, earlier, by the executor (they refuse the call outright).
    static func mayAutoApprove(_ kind: PendingApprovalKind, yoloMode: Bool, rules: [PermissionRule]) -> Bool {
        if kind.canAutoApprove(yoloMode: yoloMode) { return true }
        if case .allow = decision(for: kind, rules: rules) { return true }
        return false
    }

    // MARK: - Suggestions

    /// The "Always allow…" choices for a card, narrowest first. Empty for
    /// kinds a rule may never allow.
    @MainActor
    static func suggestions(for kind: PendingApprovalKind) -> [PermissionSuggestion] {
        guard kind.canAutoApprove(yoloMode: true),
              let request = request(for: kind) else { return [] }
        func rule(_ pattern: String) -> PermissionRule {
            PermissionRule(action: request.action, pattern: pattern, effect: .allow)
        }
        switch request.action {
        case .edit:
            let path = request.resource
            guard !path.isEmpty else { return [] }
            var options = [PermissionSuggestion(title: "This file (\(path))", rule: rule(escaped(path)))]
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                options.append(PermissionSuggestion(title: "Files in \(folder)/", rule: rule(escaped(folder) + "/*")))
            }
            options.append(PermissionSuggestion(title: "Any file in the \(scopeNoun)", rule: rule("*")))
            return options
        case .webfetch:
            let url = request.resource
            var options = [PermissionSuggestion(title: "This URL", rule: rule(escaped(url)))]
            if let site = siteRoot(of: url) {
                options.append(PermissionSuggestion(title: "Anything on \(URL(string: site)?.host ?? site)", rule: rule(escaped(site) + "*")))
            }
            options.append(PermissionSuggestion(title: "Any web page", rule: rule("*")))
            return options
        case .python:
            // A rule for one exact script is never useful: the next script
            // differs. The meaningful choice is all of them — which, like
            // YOLO, still excludes anything that asks for sudo.
            return [PermissionSuggestion(title: "Any script that doesn't use sudo", rule: rule("*"))]
        case .git:
            let resource = request.resource
            var options = [PermissionSuggestion(title: "This \(resource)", rule: rule(escaped(resource)))]
            if let colon = resource.firstIndex(of: ":") {
                let operation = String(resource[..<colon])
                options.append(PermissionSuggestion(title: "Any \(operation)", rule: rule(escaped(operation) + ":*")))
            }
            return options
        case .shell:
            // Never a bare `*`: a rule that allows every command is a
            // root-capable terminal handed to the model, and it is the one
            // pattern a person writes without thinking. The exact command is
            // the narrow choice; the program's own name is the broad one
            // (`git *` still cannot run `rm`).
            let command = request.resource
            let program = command.split(separator: " ").first.map(String.init) ?? command
            var options = [PermissionSuggestion(title: "This exact command", rule: rule(escaped(command)))]
            if !program.isEmpty, program != command {
                options.append(PermissionSuggestion(title: "Any `\(program)` command", rule: rule(escaped(program) + " *")))
            }
            return options
        }
    }

    /// The word the "Any file in the …" suggestion uses. Set by the caller to
    /// the active scope ("project" or "notebook"); the default is neutral.
    @MainActor static var scopeNoun = "project"

    // MARK: - Normalization

    /// A project path as rules see it: relative, `/`-separated, with `.`,
    /// `..`, and doubled slashes resolved — so `./notes//a.md` and
    /// `notes/x/../a.md` are both `notes/a.md` and a deny on `notes/*` cannot
    /// be stepped around.
    static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let standardized = ("/" + trimmed as NSString).standardizingPath
        return standardized.hasPrefix("/") ? String(standardized.dropFirst()) : standardized
    }

    /// A URL as rules see it: scheme and host lowercased (they are
    /// case-insensitive, so `EXAMPLE.com` must not slip past a deny on
    /// `example.com`), no fragment, and `/` for an empty path.
    static func normalizedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? raw
    }

    /// `scheme://host[:port]/` for a URL.
    static func siteRoot(of url: String) -> String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme, let host = components.host, !host.isEmpty else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/"
    }

    // MARK: - Wildcards

    /// Makes every character of `literal` match only itself.
    static func escaped(_ literal: String) -> String {
        var out = ""
        for character in literal {
            if character == "*" || character == "?" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Whole-value wildcard match. `*` matches any run of characters
    /// (including none, and including `/`), `?` exactly one, and `\x` the
    /// character `x` literally.
    static func matches(pattern: String, value: String, caseInsensitive: Bool = false) -> Bool {
        enum Token: Equatable { case literal(Character), one, any }
        var tokens: [Token] = []
        var iterator = pattern.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\\": tokens.append(.literal(iterator.next() ?? "\\"))
            case "*": if tokens.last != .any { tokens.append(.any) }
            case "?": tokens.append(.one)
            default: tokens.append(.literal(character))
            }
        }
        let text = Array(value)

        func same(_ a: Character, _ b: Character) -> Bool {
            caseInsensitive ? a.lowercased() == b.lowercased() : a == b
        }

        // Greedy match with one backtrack point per `*` — linear in practice
        // and never exponential, unlike naive recursion.
        var t = 0, p = 0
        var starToken = -1, starText = 0
        while t < text.count {
            if p < tokens.count {
                switch tokens[p] {
                case .any:
                    starToken = p
                    starText = t
                    p += 1
                    continue
                case .one:
                    t += 1; p += 1
                    continue
                case .literal(let c) where same(c, text[t]):
                    t += 1; p += 1
                    continue
                default:
                    break
                }
            }
            guard starToken >= 0 else { return false }
            p = starToken + 1
            starText += 1
            t = starText
        }
        while p < tokens.count, tokens[p] == .any { p += 1 }
        return p == tokens.count
    }
}

/// Where the saved rules live. One JSON array in `UserDefaults`, so a rule
/// saved from an approval card is in force on the next launch too. A rule
/// this build cannot decode is dropped rather than making the whole set
/// unreadable — a corrupt entry must not silently widen permissions.
@MainActor
final class PermissionRuleStore: ObservableObject {
    static let shared = PermissionRuleStore()

    @Published private(set) var rules: [PermissionRule] = []

    private let defaults: UserDefaults
    private let key = "aiChatPermissionRules"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        rules = (try? JSONDecoder().decode([PermissionRule].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }

    func add(_ rule: PermissionRule) {
        // The same action+pattern twice would be ambiguous, so replacing keeps
        // "Always allow" idempotent when the card is answered twice.
        if let index = rules.firstIndex(where: { $0.action == rule.action && $0.pattern == rule.pattern }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        persist()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        rules.removeAll()
        persist()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        // "Enabled" is modelled as presence: a disabled rule is just removed,
        // so there is no third state to reason about in the matcher.
        if !enabled { rules.remove(at: index) }
        persist()
    }

    /// The current rules, for a matcher that cannot reach the singleton.
    var currentRules: [PermissionRule] { rules }
}
