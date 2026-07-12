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
    @StateObject private var notebookManager = NotebookManager.shared
    
    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("Theme")) {
                    Picker("Appearance", selection: $themeManager.appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section(header: Text("Default Folder")) {
                    HStack {
                        Text("Notebook Location:")
                            .fontWeight(.semibold)
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
    
    var body: some View {
        ScrollView {
            Form {
                Section {
                Toggle("Enable Manual Intellisense", isOn: $settings.intellisenseEnabled)
                    .font(.body.weight(.semibold))
                Toggle("Enable AI Completion", isOn: $settings.isEnabled)
                    .font(.body.weight(.semibold))
            }
            
            if settings.isEnabled {
                
                // Chat Provider Setup
                Section(header: Text("AI Provider (Chat)")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Provider", selection: $settings.provider) {
                            ForEach(AIProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.vertical, 5)
                    
                    if settings.provider == .openAI {
                        SecureField("OpenAI API Key", text: $settings.openAIApiKey)
                            .textContentType(.password)
                        TextField("Chat Model (e.g. gpt-4o)", text: $settings.model)
                    } else if settings.provider == .openRouter {
                        SecureField("OpenRouter API Key", text: $settings.openRouterApiKey)
                            .textContentType(.password)
                        TextField("Chat Model (e.g. anthropic/claude-3-5-sonnet)", text: $settings.model)
                    } else if settings.provider == .gemini {
                        SecureField("Gemini API Key", text: $settings.geminiApiKey)
                            .textContentType(.password)
                        TextField("Chat Model (e.g. gemini-1.5-flash)", text: $settings.model)
                    } else {
                        TextField("Chat Endpoint URL", text: $settings.customEndpoint)
                        SecureField("API Key (Optional)", text: $settings.customApiKey)
                            .textContentType(.password)
                        TextField("Chat Model (e.g. llama3)", text: $settings.model)
                    }
                    
                    Toggle("Force Code Output", isOn: $settings.forceCodeOutput)
                        .font(.body.weight(.semibold))
                        .padding(.top, 5)
                    Text("Extracts content from markdown code blocks in the AI response.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // MARK: - RAG & Embeddings Setup
                Section(header: Text("Project Context (RAG & Embeddings)")) {
                    Toggle("Include Semantic Project Search (RAG)", isOn: $settings.includeProjectContext)
                        .font(.body.weight(.semibold))
                    
                    if settings.includeProjectContext {
                        Text("Searches your project files to provide highly relevant context.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                        Toggle("Cache Embeddings to Disk", isOn: $settings.cacheEmbeddingsToDisk)
                            .font(.body.weight(.semibold))
                        Text("If disabled, saves disk space but increases API costs and indexing time by regenerating embeddings on every launch.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Divider()
                        
                        if settings.provider == .custom {
                            TextField("Embedding URL", text: $settings.customEmbeddingEndpoint)
                            TextField("Embedding Model (e.g. nomic-embed-text)", text: $settings.customEmbeddingModel)
                                .onChange(of: settings.customEmbeddingModel) { _ in
                                    // TODO: Trigger RAGManager to wipe the vector cache here
                                }
                        } else if settings.provider == .openAI {
                            TextField("Embedding Model", text: $settings.openAIEmbeddingModel)
                                .onChange(of: settings.openAIEmbeddingModel) { _ in
                                    // TODO: Trigger RAGManager to wipe the vector cache here
                                }
                        } else {
                            Text("Using Apple Native Embeddings (Fast, Free & On-Device)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // --- Request Configuration Section ---
                Section(header: Text("Request Configuration")) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Timeout:")
                                .fontWeight(.semibold)
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
                                .fontWeight(.semibold)
                            TextField("2048", value: $settings.maxTokens, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        Text("The maximum number of tokens to generate in the response.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - Test Connection
                Section {
                    Button(action: {
                        testConnection()
                    }) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 5)
                        }
                        Text(isTesting ? "Testing..." : "Test Connection")
                    }
                    .disabled(isTesting)
                    
                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(testSuccess ? .green : .red)
                    }
                }
            }
        }
        .padding()
        }
    }
    
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false
    
    private func testConnection() {
        isTesting = true
        testResult = "Connecting..."
        testSuccess = false
        
        Task {
            do {
                let response = try await AICompletionService.shared.testConnection()
                testResult = "Success: Received response '\(response)'"
                testSuccess = true
            } catch {
                testResult = "Error: \(error.localizedDescription)"
                testSuccess = false
            }
            isTesting = false
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
                Section(header: Text("Configuration")) {
                Toggle("Use Custom Typst (compiled or downloaded)", isOn: $settings.useCustomTypst)
                    .font(.body.weight(.semibold))
                
                Picker("Update Mode", selection: $settings.updateMode) {
                    ForEach(TypstUpdateMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                
                if !settings.customTypstPath.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Path:")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(settings.customTypstPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section(header: Text("Update Typst")) {
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
                Section(header: Text("Source Dependencies")) {
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
                Section(header: Text("Info")) {
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