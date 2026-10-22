import SwiftUI

struct AIPromptView: View {
    @ObservedObject var controller: EditorController
    @ObservedObject private var skillsManager = SkillsManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared
    @State private var promptText: String = ""
    @State private var generatedResult: String = ""
    @State private var errorMessage: String? = nil
    @State private var isEditorFocused: Bool = false
    @AppStorage("aiPromptForceTypst") private var forceTypstConversion: Bool = false
    @FocusState private var editorFocus: Bool
    
    private func skillBinding(_ skill: AISkill) -> Binding<Bool> {
        Binding(
            get: { controller.selectedSkillIDs.contains(skill.id) },
            set: { isOn in
                if isOn { controller.selectedSkillIDs.insert(skill.id) }
                else { controller.selectedSkillIDs.remove(skill.id) }
            }
        )
    }

    private func serverBinding(_ server: ScopedMCPServer) -> Binding<Bool> {
        Binding(
            get: { controller.selectedMCPServerIDs.contains(server.id) },
            set: { isOn in
                if isOn { controller.selectedMCPServerIDs.insert(server.id) }
                else { controller.selectedMCPServerIDs.remove(server.id) }
            }
        )
    }

    @ViewBuilder
    private var skillsAndToolsMenus: some View {
        HStack(spacing: 10) {
            Menu {
                if skillsManager.allSkills.isEmpty {
                    Text("No skills configured. Add some in Settings → AI Assistant → Skills.")
                } else {
                    ForEach(skillsManager.allSkills) { skill in
                        Toggle(isOn: skillBinding(skill)) {
                            Text("\(skill.name)  ·  \(skill.scope.label)")
                        }
                        .help(skill.description)
                    }
                }
            } label: {
                Label(controller.selectedSkillIDs.isEmpty ? "Skills" : "Skills (\(controller.selectedSkillIDs.count))", systemImage: "sparkles.square.filled.on.square")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                let servers = mcpManager.allServers.filter { $0.config.isConfigured }
                if servers.isEmpty {
                    Text("No MCP servers configured. Add some in Settings → AI Assistant → MCP Servers.")
                } else {
                    ForEach(servers) { server in
                        Toggle(isOn: serverBinding(server)) {
                            Text("\(server.config.name)  ·  \(server.scope.label)")
                        }
                        .disabled(!server.config.enabled)
                        .help(server.config.enabled ? "" : "Disabled in Settings")
                    }
                }
            } label: {
                Label(controller.selectedMCPServerIDs.isEmpty ? "Tools" : "Tools (\(controller.selectedMCPServerIDs.count))", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var toolActivityLog: some View {
        if !controller.aiToolActivityLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tool Activity")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                ForEach(Array(controller.aiToolActivityLog.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                        Text(entry)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Prompt")
                        .font(.headline)
                    Text("Describe what you want the AI to generate.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }
            .padding(.top)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.subheadline.bold())
                
                TextEditor(text: $promptText)
                    .focused($editorFocus)
                    .frame(height: 100)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .font(.system(.body, design: .monospaced))
                
                Toggle("Use Semantic Project Search (RAG)", isOn: $controller.useMCPForPrompt)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("Includes relevant project snippets and Typst patterns to improve quality.")

                Toggle("Force Convert to Typst", isOn: $forceTypstConversion)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("Converts the generated markdown or plain text into Typst before insertion.")

                skillsAndToolsMenus
            }

            toolActivityLog
            
            if !generatedResult.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Result (Preview)")
                        .font(.subheadline.bold())
                    
                    TextEditor(text: $generatedResult)
                        .frame(height: 100)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.green.opacity(0.5), lineWidth: 1)
                        )
                        .font(.system(.body, design: .monospaced))
                    
                    HStack {
                        Spacer()
                        Button("Insert Selection") {
                            controller.applyAIFix(generatedResult)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .transition(.opacity)
            }
            

            if let errorMessage = errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .foregroundColor(.red)
                .padding(10)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .transition(.opacity)
            }
            
            HStack {
                Button("Cancel") {
                    controller.showAIPromptEditor = false
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                
                Spacer()
                
                Button(action: {
                    Task {
                        await MainActor.run {
                            controller.isAIGenerating = true
                            errorMessage = nil // Clear previous errors
                        }
                        do {
                            let result = try await controller.generateAIContent(from: promptText, forceTypstConversion: forceTypstConversion)
                            await MainActor.run {
                                self.generatedResult = result
                                controller.isAIGenerating = false
                            }
                        } catch {
                            await MainActor.run {
                                print("AI Error: \(error)")
                                self.errorMessage = error.localizedDescription // Push error to the UI
                                controller.isAIGenerating = false
                            }
                        }
                    }
                }) {
                    HStack {
                        if controller.isAIGenerating {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text(controller.isAIGenerating ? "Generating..." : (generatedResult.isEmpty ? "Generate" : "Regenerate"))
                    }
                }
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isAIGenerating)
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isAIGenerating ? Color.gray : Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .padding(.bottom)
        }
        .padding(.horizontal, 24)
        .frame(width: 500)
        .onAppear {
            self.promptText = controller.aiPromptText
            self.editorFocus = true
        }
    }
}