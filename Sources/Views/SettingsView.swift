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

// Add this structural View right below SettingsView
struct GeneralSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var notebookManager = NotebookManager.shared
    @AppStorage("maxBackups") private var maxBackups: Int = 3
    
    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("Theme").fontWeight(.semibold)) {
                    Picker(selection: $themeManager.appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    } label: {
                        Text("Appearance").fontWeight(.semibold)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section(header: Text("Default Folder").fontWeight(.semibold)) {
                    HStack {
                        Text("Notebook Location:")
                            .fontWeight(.regular)
                        Spacer()
                        Text(notebookManager.rootDirectory.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(notebookManager.rootDirectory.path)
                    }
                    
                    HStack {
                        Button("Choose...") {
                            chooseFolder()
                        }
                        
                        if notebookManager.isUsingCustomRoot {
                            Button("Reset to Default") {
                                notebookManager.resetRootDirectory()
                            }
                        }
                    }
                    
                    Text("Change where notebooks are stored. Useful for syncing via iCloud Drive, Dropbox, or other cloud services.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Backups").fontWeight(.semibold)) {
                    Stepper(value: $maxBackups, in: 0...20) {
                        Text("Max Backups Per File").fontWeight(.semibold)
                    }
                    Text("Keeps the last \(maxBackups) saved versions per file. A rotating backup is captured each time you press Save. Set to 0 to disable. Stored in a local backups/ folder; excluded from RAG indexing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
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

struct TypstSettingsView: View {
    @StateObject private var settings = GeneralSettingsManager.shared
    @ObservedObject private var updater = TypstUpdater.shared
    
    @State private var hasGit: Bool = false
    @State private var hasCargo: Bool = false
    @State private var checkingDependencies: Bool = false
    
    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("Configuration").fontWeight(.semibold)) {
                    Toggle("Use Custom Typst (compiled or downloaded)", isOn: $settings.useCustomTypst)
                        .font(.body.weight(.regular))
                    
                    Toggle("Check for Typst engine updates on launch", isOn: $settings.checkForTypstUpdatesOnLaunch)
                        .font(.body.weight(.regular))
                    Text("When enabled, TypstEdit will check for new stable versions of the Typst compiler each time the app loads. You can re-enable this if you previously chose 'Don't Ask Again'.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker(selection: $settings.updateMode) {
                        ForEach(TypstUpdateMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    } label: {
                        Text("Update Mode").fontWeight(.semibold)
                    }
                    .pickerStyle(.inline)
                    
                    if !settings.customTypstPath.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Path:")
                                .font(.caption.weight(.regular))
                                .foregroundColor(.secondary)
                            Text(settings.customTypstPath)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section(header: Text("Typst Engine Version").fontWeight(.semibold)) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Installed Version:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(updater.currentVersion ?? "Detecting...")
                                .font(.system(.subheadline, design: .monospaced))
                                .fontWeight(.medium)
                            Spacer()
                            if let activePath = updater.resolveActiveTypstPath() {
                                Text(activePath.contains("stable_bin") ? "Downloaded" : (activePath.contains("bin/typst") ? "Bundled" : "System"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }

                        HStack {
                            Text("Latest Stable:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if updater.isCheckingForUpdate {
                                ProgressView()
                                    .controlSize(.small)
                            } else if let release = updater.availableRelease {
                                Text(release.tag_name)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .fontWeight(.medium)
                            } else {
                                Text("Not checked")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Check for Updates") {
                                Task {
                                    await updater.checkForUpdates(userInitiated: true)
                                }
                            }
                            .disabled(updater.isCheckingForUpdate || updater.isUpdating)
                        }

                        if let checkErr = updater.checkError {
                            Text(checkErr)
                                .font(.caption)
                                .foregroundColor(.red)
                        } else if let release = updater.availableRelease,
                                  let current = updater.currentVersion,
                                  TypstUpdater.isVersion(current, strictlyOlderThan: release.tag_name) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.blue)
                                Text("A new stable version (\(release.tag_name)) is available!")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Update Typst").fontWeight(.semibold)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(settings.updateMode == .bleedingEdgeSource ? 
                            "This will clone the latest source from Git and compile it using Cargo." :
                            "This will download the latest official pre-compiled binary from GitHub.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if updater.isUpdating {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(updater.status)
                                    .font(.caption)
                                ProgressView(value: updater.progress)
                                    .progressViewStyle(.linear)
                            }
                        } else {
                            if let error = updater.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else if updater.status != "Ready" {
                                Text(updater.status)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            
                            Button(action: {
                                updater.update()
                            }) {
                                Label(settings.updateMode == .bleedingEdgeSource ? "Build from Source" : "Download Latest Binary", 
                                      systemImage: settings.updateMode == .bleedingEdgeSource ? "hammer.fill" : "arrow.down.circle")
                            }
                            .disabled(settings.updateMode == .bleedingEdgeSource && (!hasGit || !hasCargo))
                        }
                    }
                    .padding(.vertical, 5)
                }
            
            if settings.updateMode == .bleedingEdgeSource {
                Section(header: Text("Source Dependencies").fontWeight(.semibold)) {
                    HStack {
                        Image(systemName: hasGit ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(hasGit ? .green : .red)
                        Text("Git")
                        Spacer()
                        if !hasGit {
                            Text("Missing")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    HStack {
                        Image(systemName: hasCargo ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(hasCargo ? .green : .red)
                        Text("Rust (Cargo)")
                        Spacer()
                        if !hasCargo {
                            Text("Missing")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    if !hasGit || !hasCargo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Dependencies are required for source builds.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Link("Install Rust & Cargo", destination: URL(string: "https://rustup.rs")!)
                                .font(.caption)
                            
                            Text("Git is usually included with Xcode Command Line Tools.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
            } else {
                Section(header: Text("Info").fontWeight(.semibold)) {
                    HStack {
                        Image(systemName: "info.circle")
                        Text("Binary downloads are recommended and do not require Git or Rust.")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        }
        .onAppear {
            checkDependencies()
            Task {
                await updater.detectCurrentVersion()
            }
        }
    }
    
    private func checkDependencies() {
        checkingDependencies = true
        Task {
            let git = await checkCommand("git")
            let cargo = await checkCommand("cargo")
            await MainActor.run {
                self.hasGit = git
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
        if resolveCommandPath(command) != nil {
            return true
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}