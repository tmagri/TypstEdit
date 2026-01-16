import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        AISettingsView()
            .padding()
            .frame(width: 650, height: 500)
    }
}

struct AISettingsView: View {
    @StateObject private var settings = AISettingsManager.shared
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable AI Completion", isOn: $settings.isEnabled)
            }
            
            if settings.isEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Provider")
                            .font(.headline)
                        
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
                        TextField("Model (e.g. gpt-4o)", text: $settings.model)
                    } else if settings.provider == .openRouter {
                        SecureField("OpenRouter API Key", text: $settings.openRouterApiKey)
                            .textContentType(.password)
                        TextField("Model (e.g. anthropic/claude-3-5-sonnet)", text: $settings.model)
                    } else {
                        TextField("Endpoint URL", text: $settings.customEndpoint)
                        SecureField("API Key (Optional)", text: $settings.customApiKey)
                            .textContentType(.password)
                        TextField("Model (e.g. llama3)", text: $settings.model)
                    }
                }
                
                Section(header: Text("Context")) {
                    Toggle("Include Project Context (MCP)", isOn: $settings.includeProjectContext)
                    if settings.includeProjectContext {
                        Text("Includes open files and project structure to improve accuracy.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
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
