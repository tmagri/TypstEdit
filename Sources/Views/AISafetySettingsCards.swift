import SwiftUI

// MARK: - Signed-in sites

/// The sites the user signed in to for `web_fetch`, and the button that opens
/// a site's own login page in an isolated browser window. TypstEdit never sees
/// a password: only the session cookies the site sets are kept, in the
/// Keychain.
struct SignedInSitesSettingsCard: View {
    let enabled: Bool
    @ObservedObject private var store = WebSessionStore.shared

    @State private var typedAddress: String = ""
    @State private var pendingRemoval: WebSiteSession?
    @State private var showRemoveAll = false

    var body: some View {
        SettingsCard(
            title: "Signed-in Sites",
            icon: "person.badge.key",
            description: "A page behind a login can be fetched once you sign in to that site here. The sign-in opens the site in its own browser window with an empty cookie jar: you type the password into the site's own form, exactly as in Safari, so SSO and two-factor prompts work. TypstEdit keeps only the session cookies the site set — never the password — in the Keychain, one entry per host. A fetch sends a site's cookies only to that host and its subdomains, only over https for Secure cookies."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !enabled {
                    Label("Turn on the Web Fetch Tool above first — a sign-in is only useful once fetching is allowed.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                let sessions = store.allSessions()
                if sessions.isEmpty {
                    Text("No signed-in sites yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sessions, id: \.host) { session in
                        sessionRow(session)
                        if session.host != sessions.last?.host { Divider() }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Site to sign in to — e.g. jira.example.com", text: $typedAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { beginSignIn() }
                    Button("Sign in…") { beginSignIn() }
                        .disabled(typedAddress.trimmingCharacters(in: .whitespaces).isEmpty || !enabled)
                }
                .padding(.top, 4)

                if !sessions.isEmpty {
                    Button("Sign out of all sites", role: .destructive) { showRemoveAll = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .alert("Sign out of every site?", isPresented: $showRemoveAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { store.removeAll() }
        } message: {
            Text("Every saved sign-in is deleted from the Keychain. Fetches to those sites will need a fresh sign-in.")
        }
        .alert("Remove this sign-in?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let host = pendingRemoval?.host { store.remove(host: host) }
                pendingRemoval = nil
            }
        } message: {
            Text("Fetches to \(pendingRemoval?.host ?? "this site") will need a fresh sign-in.")
        }
    }

    private func sessionRow(_ session: WebSiteSession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.host).font(.body.weight(.medium))
                Text("\(session.cookies.count) cookie\(session.cookies.count == 1 ? "" : "s") · signed in \(session.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let label = session.accountLabel, !label.isEmpty {
                    Text(label).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Sign in again…") { signIn(host: session.host) }
                .buttonStyle(.link)
                .font(.caption)
            Button {
                pendingRemoval = session
            } label: {
                Image(systemName: "trash").foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private func beginSignIn() {
        let raw = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        signIn(host: raw)
        typedAddress = ""
    }

    /// The site's root gets https by default; a typed scheme is honoured.
    private func signIn(host: String) {
        guard let url = WebSignInAddress.resolve(host) else { return }
        WebSignInController.shared.present(url: url) { _ in }
    }
}

// MARK: - Screen capture

/// Settings for the agent's eyes: the `screen__look` tool, which captures the
/// screen and OCRs it. Off by default, region-only by default, and every
/// capture always needs its own approval — even under YOLO.
struct ScreenCaptureSettingsCard: View {
    @StateObject private var settings = AISettingsManager.shared

    var body: some View {
        SettingsCard(
            title: "Screen Capture",
            icon: "eye",
            description: "Lets the assistant capture your screen and read the text in it (OCR, on this Mac only — nothing is uploaded), so it can act on what you are looking at. Off by default. Every capture shows its own approval card with the reason the model gave, even in YOLO mode. macOS also requires Screen Recording permission (System Settings → Privacy & Security); a newly granted permission takes effect after the app relaunches."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow the assistant to look at the screen", isOn: $settings.chatScreenToolEnabled)
                    .font(.body.weight(.medium))

                if settings.chatScreenToolEnabled {
                    Toggle("Allow whole-screen captures (off = region only)", isOn: $settings.chatScreenFullScreenEnabled)
                        .padding(.leading, 20)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OCR languages (Vision tags, most preferred first)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("en-US, de-DE", text: $settings.chatScreenOCRLanguages)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.leading, 20)

                    HStack(spacing: 8) {
                        Image(systemName: ScreenOCR.hasScreenRecordingPermission()
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(ScreenOCR.hasScreenRecordingPermission() ? .green : .orange)
                        Text(ScreenOCR.hasScreenRecordingPermission()
                             ? "Screen Recording permission is granted."
                             : "Screen Recording permission is not granted yet. The first capture asks for it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !ScreenOCR.hasScreenRecordingPermission() {
                            Button("Request…") {
                                _ = ScreenOCR.requestScreenRecordingPermission()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }
}

// MARK: - Permission rules

/// The saved "Always allow…" and "Deny" rules. A rule can only allow what
/// YOLO can automate; a deny refuses a call without asking, even under YOLO.
struct PermissionRulesSettingsCard: View {
    @ObservedObject private var store = PermissionRuleStore.shared
    @State private var newAction: PermissionRule.Action = .edit
    @State private var newEffect: PermissionRule.Effect = .allow
    @State private var newPattern: String = ""

    var body: some View {
        SettingsCard(
            title: "Permissions",
            icon: "checklist.checked",
            description: "Saved answers to approval cards. A rule matches one kind of action against a wildcard pattern (`*` is any run of characters, `?` one character, `\\` makes the next character literal). An Allow rule only covers what YOLO can already automate — file writes and edits, web fetches, non-sudo scripts, and local Git calls — so screen captures, elevated scripts and Git push always ask. A Deny rule refuses the call without a card, even under YOLO, and beats any allow. Paths are normalized first, so `./secrets/../secrets/key.md` cannot step around a deny on `secrets/*`."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if store.rules.isEmpty {
                    Text("No rules yet. Answer an approval card with “Always allow…” — or add one below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.rules) { rule in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: rule.effect == .allow ? "checkmark.circle.fill" : "nosign")
                                .foregroundColor(rule.effect == .allow ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.action.title).font(.body.weight(.medium))
                                Text(rule.pattern)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                store.remove(id: rule.id)
                            } label: {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        if rule.id != store.rules.last?.id { Divider() }
                    }
                }

                Divider().padding(.vertical, 4)

                HStack(spacing: 8) {
                    Picker("", selection: $newEffect) {
                        ForEach(PermissionRule.Effect.allCases, id: \.self) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)

                    Picker("", selection: $newAction) {
                        ForEach(PermissionRule.Action.allCases, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)

                    TextField(newAction.patternHint, text: $newPattern)
                        .textFieldStyle(.roundedBorder)

                    Button("Add") {
                        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.add(PermissionRule(action: newAction, pattern: trimmed, effect: newEffect))
                        newPattern = ""
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !store.rules.isEmpty {
                    Button("Remove all rules", role: .destructive) { store.removeAll() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - Safety rules

/// The built-in safety rules and the user's own. A hit can only add an
/// approval card that YOLO would have skipped — never remove one.
struct SafetyRulesSettingsCard: View {
    @ObservedObject private var store = SafetyRuleStore.shared
    @StateObject private var settings = AISettingsManager.shared
    @State private var newTitle: String = ""
    @State private var newKind: UserSafetyRule.Kind = .toolCalled
    @State private var newToolName: String = "python__run"
    @State private var newArgumentName: String = "path"
    @State private var newMatcherText: String = ""
    @State private var newThreshold: Int = 3
    @State private var newPattern: String = ""
    @State private var addError: String?

    var body: some View {
        SettingsCard(
            title: "Safety Rules",
            icon: "exclamationmark.shield",
            description: "A monitor that watches a turn's tool calls and hands a call back to you when a rule matches — even in YOLO mode. It can only add an approval card, never remove one, so turning it on cannot make the assistant more permissive. It reads the actual values, not just file names: a key pasted into a script, or a `.env` renamed `notes.txt`, is caught by its shape. Strict runs every rule; Safe keeps only the credential and exfiltration rules; Off disables the monitor. The approval card names the rule that fired, so a re-approval never looks like YOLO forgot. A half-written rule of your own is skipped rather than treated as “match everything”, and your own rules run in Strict and Safe alike."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Safety mode", selection: Binding(
                    get: { settings.chatSafetyMode },
                    set: { settings.chatSafetyMode = $0 }
                )) {
                    ForEach(SafetyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.chatSafetyMode.explanation)
                    .font(.caption2)
                    .foregroundColor(settings.chatSafetyMode.isActive ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Built-in rules").font(.caption.bold()).foregroundColor(.secondary)
                ForEach(SafetyMonitor.builtInRules) { rule in
                    let runs = settings.chatSafetyMode.enabledBuiltInRuleIDs.contains(rule.id)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: rule.severity.symbol)
                            .foregroundColor(rule.severity == .alert ? .red : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.title).font(.caption.weight(.medium))
                            Text(rule.explanation).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if runs {
                            Text("on")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("off")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                    .opacity(runs ? 1 : 0.5)
                }

                Divider().padding(.vertical, 4)

                Text("Your rules").font(.caption.bold()).foregroundColor(.secondary)
                if store.userRules.isEmpty {
                    Text("No rules of your own yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.userRules) { rule in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { value in
                                    var updated = rule
                                    updated.isEnabled = value
                                    store.update(updated)
                                }
                            ))
                            .labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.title.isEmpty ? rule.kind.title : rule.title)
                                    .font(.caption.weight(.medium))
                                Text(ruleSummary(rule)).font(.caption2).foregroundColor(.secondary)
                                if rule.makeRule() == nil {
                                    Text("Incomplete — this rule matches nothing until it is filled in.")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            Spacer()
                            Button { store.remove(id: rule.id) } label: {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        if rule.id != store.userRules.last?.id { Divider() }
                    }
                }

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Rule title — e.g. “Never read .env with a script”", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                    Picker("When", selection: $newKind) {
                        ForEach(UserSafetyRule.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .frame(maxWidth: 360)

                    switch newKind {
                    case .toolCalled, .toolCalledOften:
                        TextField("Qualified tool name — e.g. python__run, project__write_file", text: $newToolName)
                            .textFieldStyle(.roundedBorder)
                        if newKind == .toolCalledOften {
                            Stepper("More than \(newThreshold) call\(newThreshold == 1 ? "" : "s")", value: $newThreshold, in: 1...100)
                        }
                    case .toolCalledWithArgument:
                        TextField("Qualified tool name — e.g. project__read_file", text: $newToolName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Argument name — e.g. path", text: $newArgumentName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Regular expression the argument must match — e.g. \\.env$", text: $newMatcherText)
                            .textFieldStyle(.roundedBorder)
                    case .outputMatched:
                        TextField("Regular expression the tool output must match", text: $newPattern)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let addError {
                        Text(addError).font(.caption2).foregroundColor(.red)
                    }

                    Button("Add rule") { addRule() }
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func ruleSummary(_ rule: UserSafetyRule) -> String {
        switch rule.kind {
        case .toolCalled:
            return "\(rule.toolName) is called"
        case .toolCalledOften:
            return "\(rule.toolName) is called more than \(rule.threshold) times"
        case .toolCalledWithArgument:
            return "\(rule.toolName) is called with \(rule.argumentName) matching \(newMatcherDescription(rule))"
        case .outputMatched:
            return "Output matches /\(rule.pattern)/"
        }
    }

    private func newMatcherDescription(_ rule: UserSafetyRule) -> String {
        switch rule.matcher {
        case .equals(let value): return "“\(value)”"
        case .contains(let value): return "containing “\(value)”"
        case .matches(let value): return "/\(value)/"
        }
    }

    private func addRule() {
        addError = nil
        var matcher: ArgumentMatcher = .contains("")
        if newKind == .toolCalledWithArgument {
            let pattern = newMatcherText.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else {
                addError = "Enter a regular expression for the argument to match."
                return
            }
            guard UserSafetyRule.isValidRegex(pattern) else {
                addError = "That regular expression isn't valid."
                return
            }
            matcher = .matches(pattern)
        }
        if newKind == .outputMatched {
            let pattern = newPattern.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else {
                addError = "Enter a regular expression for the output to match."
                return
            }
            guard UserSafetyRule.isValidRegex(pattern) else {
                addError = "That regular expression isn't valid."
                return
            }
        }
        let rule = UserSafetyRule(
            title: newTitle.trimmingCharacters(in: .whitespaces),
            kind: newKind,
            toolName: newToolName.trimmingCharacters(in: .whitespaces),
            argumentName: newArgumentName.trimmingCharacters(in: .whitespaces),
            matcher: matcher,
            threshold: newThreshold,
            pattern: newPattern.trimmingCharacters(in: .whitespaces)
        )
        guard rule.makeRule() != nil else {
            addError = "This rule is incomplete (an empty tool name or pattern would match everything)."
            return
        }
        store.add(rule)
        newTitle = ""
        newMatcherText = ""
        newPattern = ""
    }
}
