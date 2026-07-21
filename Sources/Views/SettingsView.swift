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
struct AISettingsView: View {
    @StateObject private var settings = AISettingsManager.shared

    private func sourceBinding(for task: ModelTask) -> Binding<ModelSource> {
        Binding(
            get: { settings.source(for: task) },
            set: { settings.setSource($0, for: task) }
        )
    }

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Toggle("Enable Manual Intellisense", isOn: $settings.intellisenseEnabled)
                        .font(.body.weight(.regular))
                    Toggle("Enable AI Completion", isOn: $settings.isEnabled)
                        .font(.body.weight(.regular))
                }

                if settings.isEnabled {

                    // MARK: - Generation / Chat
                    Section(header: Text("AI Generation / Chat").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)) {
                        Picker(selection: sourceBinding(for: .generation)) {
                            ForEach(ModelSource.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        } label: {
                            Text("Source").fontWeight(.semibold)
                        }
                        .pickerStyle(.menu)

                        generationSourceFields

                        Toggle("Force Code Output", isOn: $settings.forceCodeOutput)
                            .font(.body.weight(.regular))
                            .padding(.top, 5)
                        Text("Extracts content from markdown code blocks in the AI response.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        testButton(for: .generation)
                    }

                    Divider().padding(.vertical, 4)

                    // MARK: - Completion / Autocomplete
                    Section(header: Text("Autocomplete").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)) {
                        Picker(selection: sourceBinding(for: .completion)) {
                            ForEach(ModelSource.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        } label: {
                            Text("Source").fontWeight(.semibold)
                        }
                        .pickerStyle(.menu)

                        completionSourceFields

                        Text("Uses a separate, cheaper/faster model for inline autocomplete. Leave the model blank to fall back to the generation model.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        testButton(for: .completion)
                    }

                    Divider().padding(.vertical, 4)

                    // MARK: - Embeddings (RAG)
                    Section(header: Text("Embeddings (RAG)").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)) {
                        Toggle("Include Semantic Project Search (RAG)", isOn: $settings.includeProjectContext)
                            .font(.body.weight(.regular))

                        if settings.includeProjectContext {
                            Picker(selection: sourceBinding(for: .embedding)) {
                                ForEach(ModelSource.allCases) { source in
                                    Text(source.rawValue).tag(source)
                                }
                            } label: {
                                Text("Source").fontWeight(.semibold)
                            }
                            .pickerStyle(.menu)

                            embeddingSourceFields

                            Toggle("Cache Embeddings to Disk", isOn: $settings.cacheEmbeddingsToDisk)
                                .font(.body.weight(.regular))
                            Text("If disabled, saves disk space but increases API costs and indexing time by regenerating embeddings on every launch.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            testButton(for: .embedding)
                        }
                    }

                    Divider().padding(.vertical, 4)

                    // MARK: - Request Configuration
                    Section(header: Text("Request Configuration").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Timeout:")
                                    .fontWeight(.regular)
                                Slider(value: $settings.timeoutSeconds, in: 5...1200, step: 5)
                                Text("\(Int(settings.timeoutSeconds))s")
                                    .monospacedDigit()
                                    .frame(width: 35, alignment: .trailing)
                            }
                            Text("Maximum time to wait for a response from the AI provider.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Max Tokens:")
                                    .fontWeight(.regular)
                                TextField("2048", value: $settings.maxTokens, formatter: NumberFormatter())
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                            }
                            Text("The maximum number of tokens to generate in the response.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Per-Source Field Builders

    @ViewBuilder
    private var generationSourceFields: some View {
        switch settings.source(for: .generation) {
        case .openAI:
            SecureField(text: $settings.openAIApiKey) { Text("OpenAI API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.generationModel) { Text("Model (e.g. gpt-4o)").fontWeight(.semibold) }
        case .openRouter:
            SecureField(text: $settings.openRouterApiKey) { Text("OpenRouter API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.generationModel) { Text("Model (e.g. anthropic/claude-3-5-sonnet)").fontWeight(.semibold) }
        case .anthropic:
            SecureField(text: $settings.anthropicApiKey) { Text("Anthropic API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.generationModel) { Text("Model (e.g. claude-sonnet-4-20250514)").fontWeight(.semibold) }
        case .gemini:
            SecureField(text: $settings.geminiApiKey) { Text("Gemini API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.generationModel) { Text("Model (e.g. gemini-1.5-flash)").fontWeight(.semibold) }
        case .local:
            TextField(text: $settings.generationEndpoint) { Text("Endpoint URL").fontWeight(.semibold) }
            SecureField(text: $settings.customApiKey) { Text("API Key (Optional)").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.generationModel) { Text("Model (e.g. llama3)").fontWeight(.semibold) }
        }
    }

    @ViewBuilder
    private var completionSourceFields: some View {
        let src = settings.source(for: .completion)
        switch src {
        case .openAI:
            SecureField(text: $settings.openAIApiKey) { Text("OpenAI API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.completionModel) { Text("Model (e.g. gpt-4o-mini)").fontWeight(.semibold) }
        case .openRouter:
            SecureField(text: $settings.openRouterApiKey) { Text("OpenRouter API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.completionModel) { Text("Model (e.g. anthropic/claude-3-5-haiku)").fontWeight(.semibold) }
        case .anthropic:
            SecureField(text: $settings.anthropicApiKey) { Text("Anthropic API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.completionModel) { Text("Model (e.g. claude-3-5-haiku-20241022)").fontWeight(.semibold) }
        case .gemini:
            SecureField(text: $settings.geminiApiKey) { Text("Gemini API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.completionModel) { Text("Model (e.g. gemini-1.5-flash)").fontWeight(.semibold) }
        case .local:
            TextField(text: $settings.completionEndpoint) { Text("Endpoint URL").fontWeight(.semibold) }
            SecureField(text: $settings.customApiKey) { Text("API Key (Optional)").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.completionModel) { Text("Model (e.g. qwen2.5-coder:1.5b)").fontWeight(.semibold) }
        }

        if settings.completionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Falling back to generation model: \(settings.generationModel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Using: \(settings.completionModel.trimmingCharacters(in: .whitespacesAndNewlines)) via \(src.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var embeddingSourceFields: some View {
        switch settings.source(for: .embedding) {
        case .openAI:
            SecureField(text: $settings.openAIApiKey) { Text("OpenAI API Key").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.openAIEmbeddingModel) { Text("Embedding Model (e.g. text-embedding-3-small)").fontWeight(.semibold) }
                .onChange(of: settings.openAIEmbeddingModel) { _ in
                    // TODO: Trigger RAGManager to wipe the vector cache here
                }
        case .local:
            TextField(text: $settings.embeddingEndpoint) { Text("Embedding URL").fontWeight(.semibold) }
            SecureField(text: $settings.customApiKey) { Text("API Key (Optional)").fontWeight(.semibold) }
                .textContentType(.password)
            TextField(text: $settings.embeddingModel) { Text("Embedding Model (e.g. nomic-embed-text)").fontWeight(.semibold) }
                .onChange(of: settings.embeddingModel) { _ in
                    // TODO: Trigger RAGManager to wipe the vector cache here
                }
        default:
            Text("Using Apple Native Embeddings (Fast, Free & On-Device)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @State private var testingTask: ModelTask?
    @State private var testResults: [ModelTask: (success: Bool, message: String)] = [:]

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
        HStack(spacing: 8) {
            Button(action: { testConnection(for: task) }) {
                if testingTask == task {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Test Connection")
                }
            }
            .disabled(testingTask != nil)

            if let result = testResults[task] {
                Text(result.message)
                    .font(.caption)
                    .foregroundColor(result.success ? .green : .red)
                    .lineLimit(1)
            }
        }
    }
}

struct TypstSettingsView: View {
    @StateObject private var settings = GeneralSettingsManager.shared
    @StateObject private var updater = TypstUpdater()
    
    @State private var hasGit: Bool = false
    @State private var hasCargo: Bool = false
    @State private var checkingDependencies: Bool = false
    
    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("Configuration").fontWeight(.semibold)) {
                Toggle("Use Custom Typst (compiled or downloaded)", isOn: $settings.useCustomTypst)
                    .font(.body.weight(.regular))
                
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