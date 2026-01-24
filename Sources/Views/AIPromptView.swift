import SwiftUI

struct AIPromptView: View {
    @ObservedObject var controller: EditorController
    @State private var promptText: String = ""
    @State private var generatedResult: String = ""
    @State private var isEditorFocused: Bool = false
    @FocusState private var editorFocus: Bool
    
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
                
                Toggle("Use Project Context (MCP)", isOn: $controller.useMCPForPrompt)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("Includes relevant project snippets and Typst patterns to improve quality.")
            }
            
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
                        controller.isAIGenerating = true
                        do {
                            let result = try await controller.generateAIContent(from: promptText)
                            await MainActor.run {
                                self.generatedResult = result
                                controller.isAIGenerating = false
                            }
                        } catch {
                            await MainActor.run {
                                print("AI Error: \(error)")
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


