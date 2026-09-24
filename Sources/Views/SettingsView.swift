import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            AISettingsView()
                .tabItem {
                    Label("AI Assistant", systemImage: "sparkles")
                }
            
            TypstSettingsView()
                .tabItem {
                    Label("Typst Compiler", systemImage: "terminal")
                }
                
            PackageManagerView()
                .tabItem {
                    Label("Packages", systemImage: "shippingbox")
                }
        }
        .padding()
        .frame(width: 1024, height: 768)
    }
}

// MARK: - General Settings Section Nav

enum GeneralSettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case files = "Files & Backups"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .files:      return "folder"
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var notebookManager = NotebookManager.shared
    @AppStorage("maxBackups") private var maxBackups: Int = 3
    @State private var selectedSection: GeneralSettingsSection = .appearance

    var body: some View {
        VStack(spacing: 0) {
            // Segmented Top Navigation
            Picker("Section", selection: $selectedSection) {
                ForEach(GeneralSettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    switch selectedSection {
                    case .appearance: appearanceSection
                    case .files:      filesSection
                    }
                }
                .padding(24)
                .frame(maxWidth: 820)
            }
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsCard(
            title: "Theme",
            icon: "paintbrush",
            description: "Choose how TypstEdit looks across all windows."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $themeManager.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Files & Backups

    @ViewBuilder
    private var filesSection: some View {
        SettingsCard(
            title: "Notebook Location",
            icon: "folder",
            description: "Where your notebooks are stored on disk. Useful for syncing via iCloud Drive, Dropbox, or other cloud services."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Current Path:") {
                    Text(notebookManager.rootDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(notebookManager.rootDirectory.path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Spacer().frame(width: 140)
                    Button("Choose Folder…") { chooseFolder() }
                    if notebookManager.isUsingCustomRoot {
                        Button("Reset to Default") { notebookManager.resetRootDirectory() }
                    }
                }
            }
        }

        SettingsCard(
            title: "Automatic Backups",
            icon: "clock.arrow.2.circlepath",
            description: "TypstEdit keeps rotating snapshots each time you save. Backups are stored in a local backups/ folder and excluded from AI indexing."
        ) {
            SettingsRow(
                label: "Max Backups:",
                caption: "Keeps the last N saved versions per file. Set to 0 to disable backups entirely."
            ) {
                HStack(spacing: 8) {
                    Stepper("", value: $maxBackups, in: 0...20)
                        .labelsHidden()
                    Text(maxBackups == 0 ? "Disabled" : "\(maxBackups) per file")
                        .font(.body)
                        .foregroundColor(maxBackups == 0 ? .secondary : .primary)
                        .frame(width: 100, alignment: .leading)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Default Notebook Folder"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            notebookManager.setRootDirectory(url)
        }
    }
}
// MARK: - Reusable Settings UI Components

struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var description: String? = nil
    @ViewBuilder var content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = title {
                HStack(spacing: 8) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    Text(title)
                        .font(.headline)
                    Spacer()
                }
                if let description = description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
}

struct SettingsRow<Control: View>: View {
    var label: String
    var caption: String? = nil
    @ViewBuilder var control: Control
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .frame(width: 140, alignment: .trailing)
                    .font(.body)
                    .foregroundColor(.secondary)
                control
            }
            if let caption = caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 152)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct KeyboardShortcutBadge: View {
    let key: String
    
    var body: some View {
        Text(key)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - AI Settings Sub-sections

enum AISettingsSection: String, CaseIterable, Identifiable {
    case autocomplete = "Autocomplete"
    case generation = "Chat & Actions"
    case rag = "Project Context (RAG)"
    case apiKeys = "API Keys & Limits"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .autocomplete: return "sparkles"
        case .generation: return "bubble.left.and.bubble.right"
        case .rag: return "books.vertical"
        case .apiKeys: return "key.horizontal"
        }
    }
}

// MARK: - AI Assistant Settings View

struct AISettingsView: View {
    @StateObject private var settings = AISettingsManager.shared
    @State private var selectedSection: AISettingsSection = .autocomplete
    
    @State private var testingTask: ModelTask?
    @State private var testResults: [ModelTask: (success: Bool, message: String)] = [:]

    private func sourceBinding(for task: ModelTask) -> Binding<ModelSource> {
        Binding(
            get: { settings.source(for: task) },
            set: { settings.setSource($0, for: task) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented Top Navigation
            Picker("Section", selection: $selectedSection) {
                ForEach(AISettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    switch selectedSection {
                    case .autocomplete:
                        autocompleteSection
                    case .generation:
                        generationSection
                    case .rag:
                        ragSection
                    case .apiKeys:
                        apiKeysSection
                    }
                }
                .padding(24)
                .frame(maxWidth: 820)
            }
        }
    }

    // MARK: - 1. Autocomplete Section

    @ViewBuilder
    private var autocompleteSection: some View {
        // Activation & Modes
        SettingsCard(
            title: "Suggestions & Modes",
            icon: "sparkles",
            description: "Control how inline completions and syntax intellisense behave while editing."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable AI Completion", isOn: $settings.isEnabled)
                    .font(.body.weight(.medium))

                Toggle("Auto-suggest As You Type", isOn: $settings.isContinuousCompletionEnabled)
                    .font(.body.weight(.regular))
                    .padding(.leading, 18)

                Text("Automatically requests completions when you pause typing, without requiring manual shortcut triggers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 38)

                Divider()

                Toggle("Enable Manual & Offline Typst Intellisense", isOn: $settings.intellisenseEnabled)
                    .font(.body.weight(.medium))

                Text("Instant 0ms completions for Typst # functions, symbols, and labels even with no AI model active.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
            }
        }

        // Model & Provider
        SettingsCard(
            title: "Autocomplete Model",
            icon: "cpu",
            description: "Use a fast, dedicated model for inline completions (e.g. 0.5B–3B compact local models)."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Source:") {
                    Picker("", selection: sourceBinding(for: .completion)) {
                        ForEach(ModelSource.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                }

                completionSourceFields

                if settings.completionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text("Falling back to chat model: \(settings.generationModel)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 152)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Active: \(settings.completionModel.trimmingCharacters(in: .whitespacesAndNewlines)) via \(settings.source(for: .completion).rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 152)
                }

                HStack {
                    Spacer().frame(width: 140)
                    testButton(for: .completion)
                }
            }
        }

        // Performance & Latency Tuning
        SettingsCard(
            title: "Performance & Latency Tuning",
            icon: "gauge.with.needle",
            description: "Fine-tune suggestion speed and token context. Essential for smooth local model performance."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsRow(label: "Context Scope:", caption: settings.completionContextScope.description) {
                    Picker("", selection: Binding(
                        get: { settings.completionContextScope },
                        set: { settings.completionContextScope = $0 }
                    )) {
                        ForEach(AISettingsManager.CompletionContextScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                }

                SettingsRow(label: "Thinking Pause:", caption: "Idle time after typing before querying the model (increase for slower local models).") {
                    HStack {
                        Slider(value: $settings.completionDebounceMs, in: 200...2000, step: 50)
                        Text("\(Int(settings.completionDebounceMs))ms")
                            .monospacedDigit()
                            .frame(width: 55, alignment: .trailing)
                    }
                }

                SettingsRow(label: "Suggestion Timeout:", caption: "Maximum duration to wait for an AI completion before silently aborting so the editor never lags.") {
                    HStack {
                        Slider(value: $settings.completionTimeoutSeconds, in: 1...15, step: 0.5)
                        Text(String(format: "%.1fs", settings.completionTimeoutSeconds))
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }
                }

                SettingsRow(label: "Max Tokens:", caption: "Shorter suggestions (16–48 tokens) generate exponentially faster on local hardware.") {
                    HStack {
                        TextField("32", value: $settings.completionMaxTokens, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("tokens")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }

        // Keyboard Shortcuts Guide
        SettingsCard(
            title: "Keyboard Shortcuts",
            icon: "keyboard",
            description: "Quick reference for navigating and accepting suggestions without breaking writing flow."
        ) {
            VStack(spacing: 8) {
                shortcutRow(keys: ["Tab"], description: "Accept the highlighted suggestion")
                Divider()
                shortcutRow(keys: ["⌥", "↓", "/", "⌥", "↑"], description: "Cycle through suggestions without moving text cursor")
                Divider()
                shortcutRow(keys: ["⌥", "]", "/", "⌥", "["], description: "Alternative suggestion cycling hotkeys")
                Divider()
                shortcutRow(keys: ["⌃", "Space", "/", "Esc"], description: "Manually trigger or dismiss suggestions")
                Divider()
                shortcutRow(keys: ["↑", "/", "↓"], description: "Move text cursor across lines in document (dismisses popup)")
            }
        }
    }

    private func shortcutRow(keys: [String], description: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys.indices, id: \.self) { i in
                    let k = keys[i]
                    if k == "/" {
                        Text("/").foregroundColor(.secondary).font(.caption)
                    } else {
                        KeyboardShortcutBadge(key: k)
                    }
                }
            }
            .frame(width: 140, alignment: .leading)

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - 2. Chat & Generation Section

    @ViewBuilder
    private var generationSection: some View {
        SettingsCard(
            title: "Chat & Actions Status",
            icon: "bubble.left.and.bubble.right",
            description: "Configure the engine used for the AI Prompt panel, text refinement, and document generation."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable AI Assistant Features", isOn: $settings.isEnabled)
                    .font(.body.weight(.medium))

                Toggle("Force Code Output", isOn: $settings.forceCodeOutput)
                    .font(.body.weight(.regular))
                    .padding(.leading, 18)

                Text("Automatically extracts code from markdown code blocks in AI responses.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 38)
            }
        }

        SettingsCard(
            title: "Chat Model & Provider",
            icon: "server.rack",
            description: "Select the AI service for general text generation and rewriting."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Source:") {
                    Picker("", selection: sourceBinding(for: .generation)) {
                        ForEach(ModelSource.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                }

                generationSourceFields

                HStack {
                    Spacer().frame(width: 140)
                    testButton(for: .generation)
                }
            }
        }
    }

    // MARK: - 3. Project Context (RAG) Section

    @ViewBuilder
    private var ragSection: some View {
        SettingsCard(
            title: "Semantic Project Search (RAG)",
            icon: "books.vertical",
            description: "Enriches AI chat requests with relevant context found across your project files."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Include Semantic Project Search", isOn: $settings.includeProjectContext)
                    .font(.body.weight(.medium))

                if settings.includeProjectContext {
                    Toggle("Cache Embeddings to Disk", isOn: $settings.cacheEmbeddingsToDisk)
                        .font(.body.weight(.regular))
                        .padding(.leading, 18)

                    Text("Saves generated embeddings locally to eliminate re-indexing time and reduce API costs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 38)
                }
            }
        }

        if settings.includeProjectContext {
            SettingsCard(
                title: "Embedding Provider & Model",
                icon: "brain",
                description: "Choose how vector embeddings are generated for project indexing."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Source:") {
                        Picker("", selection: sourceBinding(for: .embedding)) {
                            ForEach(ModelSource.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    embeddingSourceFields

                    HStack {
                        Spacer().frame(width: 140)
                        testButton(for: .embedding)
                    }
                }
            }
        }
    }

    // MARK: - 4. API Keys & Limits Section

    @ViewBuilder
    private var apiKeysSection: some View {
        SettingsCard(
            title: "Cloud Provider API Keys",
            icon: "key.horizontal",
            description: "API keys configured here are shared across all tasks (Chat, Autocomplete, and Embeddings)."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "OpenAI:") {
                    SecureField("sk-...", text: $settings.openAIApiKey)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsRow(label: "OpenRouter:") {
                    SecureField("sk-or-...", text: $settings.openRouterApiKey)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsRow(label: "Anthropic:") {
                    SecureField("sk-ant-...", text: $settings.anthropicApiKey)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsRow(label: "Google Gemini:") {
                    SecureField("AIzaSy...", text: $settings.geminiApiKey)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsRow(label: "Local Server:") {
                    SecureField("Optional for Ollama / LM Studio", text: $settings.customApiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }

        SettingsCard(
            title: "Global Request Limits",
            icon: "slider.horizontal.3",
            description: "Global timeouts and token ceilings for AI generation requests."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsRow(label: "Request Timeout:", caption: "Maximum duration to wait for chat or generation responses.") {
                    HStack {
                        Slider(value: $settings.timeoutSeconds, in: 5...1200, step: 5)
                        Text("\(Int(settings.timeoutSeconds))s")
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }
                }

                SettingsRow(label: "Max Generation Tokens:", caption: "The maximum number of tokens to generate in chat responses.") {
                    TextField("2048", value: $settings.maxTokens, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                SettingsRow(label: "Context Window:", caption: "Maximum token context sent in prompts.") {
                    TextField("4096", value: $settings.maxContextWindow, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
        }
    }

    // MARK: - Per-Source Field Builders

    @ViewBuilder
    private var generationSourceFields: some View {
        switch settings.source(for: .generation) {
        case .openAI:
            SettingsRow(label: "API Key:") {
                SecureField("OpenAI API Key (or set in API Keys tab)", text: $settings.openAIApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. gpt-4o", text: $settings.generationModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .openRouter:
            SettingsRow(label: "API Key:") {
                SecureField("OpenRouter API Key (or set in API Keys tab)", text: $settings.openRouterApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. anthropic/claude-3-5-sonnet", text: $settings.generationModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .anthropic:
            SettingsRow(label: "API Key:") {
                SecureField("Anthropic API Key (or set in API Keys tab)", text: $settings.anthropicApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. claude-sonnet-4-20250514", text: $settings.generationModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .gemini:
            SettingsRow(label: "API Key:") {
                SecureField("Gemini API Key (or set in API Keys tab)", text: $settings.geminiApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. gemini-1.5-flash", text: $settings.generationModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .local:
            SettingsRow(label: "Endpoint URL:") {
                TextField("http://localhost:11434/v1/chat/completions", text: $settings.generationEndpoint)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "API Key:") {
                SecureField("Optional for local servers", text: $settings.customApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. llama3", text: $settings.generationModel)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var completionSourceFields: some View {
        let src = settings.source(for: .completion)
        switch src {
        case .openAI:
            SettingsRow(label: "API Key:") {
                SecureField("OpenAI API Key (or set in API Keys tab)", text: $settings.openAIApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. gpt-4o-mini", text: $settings.completionModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .openRouter:
            SettingsRow(label: "API Key:") {
                SecureField("OpenRouter API Key (or set in API Keys tab)", text: $settings.openRouterApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. anthropic/claude-3-5-haiku", text: $settings.completionModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .anthropic:
            SettingsRow(label: "API Key:") {
                SecureField("Anthropic API Key (or set in API Keys tab)", text: $settings.anthropicApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. claude-3-5-haiku-20241022", text: $settings.completionModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .gemini:
            SettingsRow(label: "API Key:") {
                SecureField("Gemini API Key (or set in API Keys tab)", text: $settings.geminiApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. gemini-1.5-flash", text: $settings.completionModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .local:
            SettingsRow(label: "Endpoint URL:") {
                TextField("http://localhost:11434/v1/chat/completions", text: $settings.completionEndpoint)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "API Key:") {
                SecureField("Optional for local servers", text: $settings.customApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. qwen2.5-coder:1.5b", text: $settings.completionModel)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var embeddingSourceFields: some View {
        switch settings.source(for: .embedding) {
        case .openAI:
            SettingsRow(label: "API Key:") {
                SecureField("OpenAI API Key (or set in API Keys tab)", text: $settings.openAIApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. text-embedding-3-small", text: $settings.openAIEmbeddingModel)
                    .textFieldStyle(.roundedBorder)
            }
        case .local:
            SettingsRow(label: "Endpoint URL:") {
                TextField("http://localhost:11434/v1/embeddings", text: $settings.embeddingEndpoint)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "API Key:") {
                SecureField("Optional for local servers", text: $settings.customApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Model:") {
                TextField("e.g. nomic-embed-text", text: $settings.embeddingModel)
                    .textFieldStyle(.roundedBorder)
            }
        default:
            HStack(spacing: 8) {
                Spacer().frame(width: 140)
                Image(systemName: "applelogo")
                    .foregroundColor(.secondary)
                Text("Using Apple Native Embeddings (Fast, Free & On-Device)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Test Connection Logic

    private func testConnection(for task: ModelTask) {
        testingTask = task
        testResults[task] = nil

        Task {
            do {
                if task == .embedding {
                    let ctx = settings.modelContext(for: .embedding)
                    if ctx.isLocal || ctx.source == .openAI {
                        let provider = GenericAPIEmbeddingProvider(
                            dimensions: 768,
                            endpointURL: URL(string: ctx.embeddingEndpoint)!,
                            apiKey: ctx.apiKey,
                            modelName: ctx.model
                        )
                        _ = try await provider.getEmbedding(for: "test")
                    }
                    testResults[task] = (true, "Success: Embedding endpoint reachable")
                } else {
                    let purpose: AIRequestPurpose = (task == .completion) ? .completion : .chat
                    let response = try await AICompletionService.shared.fetchCompletion(
                        prompt: "Hello. Respond with exactly the word 'OK'.",
                        purpose: purpose
                    )
                    testResults[task] = (true, "Success: '\(response)'")
                }
            } catch {
                testResults[task] = (false, error.localizedDescription)
            }
            testingTask = nil
        }
    }

    @ViewBuilder
    private func testButton(for task: ModelTask) -> some View {
        HStack(spacing: 12) {
            Button(action: { testConnection(for: task) }) {
                HStack(spacing: 6) {
                    if testingTask == task {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text("Test Connection")
                }
            }
            .disabled(testingTask != nil)

            if let result = testResults[task] {
                HStack(spacing: 4) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(result.success ? .green : .red)
                    Text(result.message)
                        .font(.caption)
                        .foregroundColor(result.success ? .green : .red)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Typst Settings Section Nav

enum TypstSettingsSection: String, CaseIterable, Identifiable {
    case engine  = "Engine"
    case updates = "Updates"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .engine:  return "terminal"
        case .updates: return "arrow.down.circle"
        }
    }
}

struct TypstSettingsView: View {
    @StateObject private var settings = GeneralSettingsManager.shared
    @ObservedObject private var updater = TypstUpdater.shared

    @State private var selectedSection: TypstSettingsSection = .engine
    @State private var hasGit: Bool = false
    @State private var hasCargo: Bool = false
    @State private var checkingDependencies: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Segmented Top Navigation
            Picker("Section", selection: $selectedSection) {
                ForEach(TypstSettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    switch selectedSection {
                    case .engine:  engineSection
                    case .updates: updatesSection
                    }
                }
                .padding(24)
                .frame(maxWidth: 820)
            }
        }
        .onAppear {
            checkDependencies()
            Task { await updater.detectCurrentVersion() }
        }
    }

    // MARK: - Engine Section

    @ViewBuilder
    private var engineSection: some View {
        // Installed version status
        SettingsCard(
            title: "Typst Engine",
            icon: "terminal",
            description: "The Typst compiler version currently active in TypstEdit."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Installed Version:") {
                    HStack(spacing: 8) {
                        Text(updater.currentVersion ?? "Detecting…")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        if let activePath = updater.resolveActiveTypstPath() {
                            let origin = activePath.contains("stable_bin") ? "Downloaded"
                                       : activePath.contains("bin/typst")  ? "Bundled"
                                       : "System"
                            Text(origin)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                        }
                    }
                }

                if !settings.customTypstPath.isEmpty {
                    SettingsRow(label: "Custom Path:") {
                        Text(settings.customTypstPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }

        // Configuration toggles
        SettingsCard(
            title: "Configuration",
            icon: "gearshape",
            description: "Control which Typst binary is used and how updates are handled."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Use Custom Typst Binary", isOn: $settings.useCustomTypst)
                        .font(.body.weight(.medium))
                    Text("When on, TypstEdit uses the path specified above instead of the bundled engine.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Check for Updates on Launch", isOn: $settings.checkForTypstUpdatesOnLaunch)
                        .font(.body.weight(.medium))
                    Text("Checks for new stable Typst releases each time the app starts. You can re-enable this after choosing \"Don't Ask Again\".")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }

                Divider()

                SettingsRow(label: "Update Mode:") {
                    Picker("", selection: $settings.updateMode) {
                        ForEach(TypstUpdateMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Updates Section

    @ViewBuilder
    private var updatesSection: some View {
        // Version check status
        SettingsCard(
            title: "Version Status",
            icon: "arrow.triangle.2.circlepath",
            description: "Compare the active Typst engine against the latest official release."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsRow(label: "Installed:") {
                    Text(updater.currentVersion ?? "Detecting…")
                        .font(.system(.body, design: .monospaced))
                }

                SettingsRow(label: "Latest Stable:") {
                    if updater.isCheckingForUpdate {
                        ProgressView().controlSize(.small)
                    } else if let release = updater.availableRelease {
                        HStack(spacing: 8) {
                            Text(release.tag_name)
                                .font(.system(.body, design: .monospaced))
                            if let current = updater.currentVersion,
                               TypstUpdater.isVersion(current, strictlyOlderThan: release.tag_name) {
                                Label("Update available", systemImage: "arrow.down.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundColor(.blue)
                                    .font(.callout)
                            }
                        }
                    } else {
                        Text("Not checked")
                            .foregroundColor(.secondary)
                    }
                }

                if let checkErr = updater.checkError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                        Text(checkErr).font(.caption).foregroundColor(.red)
                    }
                } else if let release = updater.availableRelease,
                          let current = updater.currentVersion,
                          TypstUpdater.isVersion(current, strictlyOlderThan: release.tag_name) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill").foregroundColor(.blue)
                        Text("Version \(release.tag_name) is available.")
                            .font(.caption).foregroundColor(.blue)
                    }
                }

                HStack {
                    Spacer().frame(width: 140)
                    Button("Check for Updates") {
                        Task { await updater.checkForUpdates(userInitiated: true) }
                    }
                    .disabled(updater.isCheckingForUpdate || updater.isUpdating)
                }
            }
        }

        // Download / build action
        SettingsCard(
            title: settings.updateMode == .bleedingEdgeSource ? "Build from Source" : "Download Latest Binary",
            icon: settings.updateMode == .bleedingEdgeSource ? "hammer" : "arrow.down.circle",
            description: settings.updateMode == .bleedingEdgeSource
                ? "Clones the latest Typst source from GitHub and compiles it locally with Cargo. Requires Git and Rust."
                : "Downloads the latest official pre-compiled Typst binary directly from GitHub Releases."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if updater.isUpdating {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(updater.status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ProgressView(value: updater.progress)
                            .progressViewStyle(.linear)
                    }
                } else {
                    if let error = updater.lastError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text(error).font(.caption).foregroundColor(.red)
                        }
                    } else if updater.status != "Ready" {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text(updater.status).font(.caption).foregroundColor(.green)
                        }
                    }

                    HStack {
                        Spacer().frame(width: 140)
                        Button {
                            updater.update()
                        } label: {
                            Label(
                                settings.updateMode == .bleedingEdgeSource ? "Build from Source" : "Download Latest Binary",
                                systemImage: settings.updateMode == .bleedingEdgeSource ? "hammer.fill" : "arrow.down.circle"
                            )
                        }
                        .disabled(settings.updateMode == .bleedingEdgeSource && (!hasGit || !hasCargo))
                    }
                }
            }
        }

        // Source-build dependencies (only shown for bleeding-edge mode)
        if settings.updateMode == .bleedingEdgeSource {
            SettingsCard(
                title: "Source Build Dependencies",
                icon: "shippingbox",
                description: "Both Git and Rust (Cargo) must be installed to compile Typst from source."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    dependencyRow(name: "Git", available: hasGit)
                    Divider()
                    dependencyRow(name: "Rust (Cargo)", available: hasCargo)

                    if !hasGit || !hasCargo {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Link(destination: URL(string: "https://rustup.rs")!) {
                                Label("Install Rust & Cargo via rustup.rs", systemImage: "link")
                                    .font(.caption)
                            }
                            Text("Git is usually included with Xcode Command Line Tools.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } else {
            SettingsCard(
                title: "No Extra Dependencies Needed",
                icon: "checkmark.circle",
                description: nil
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Binary downloads are self-contained and do not require Git or Rust.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func dependencyRow(name: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(available ? .green : .red)
                .font(.body)
            Text(name)
                .font(.body)
            Spacer()
            if !available {
                Text("Not found")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func checkDependencies() {
        checkingDependencies = true
        Task {
            let git   = await checkCommand("git")
            let cargo = await checkCommand("cargo")
            await MainActor.run {
                self.hasGit   = git
                self.hasCargo = cargo
                self.checkingDependencies = false
            }
        }
    }

    private func resolveCommandPath(_ command: String) -> String? {
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            NSString(string: "~/.cargo/bin").expandingTildeInPath,
            NSString(string: "~/bin").expandingTildeInPath
        ]
        for dir in commonPaths {
            let fullPath = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    private func checkCommand(_ command: String) async -> Bool {
        if resolveCommandPath(command) != nil { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do { try process.run() } catch {
                continuation.resume(returning: false)
            }
        }
    }
}