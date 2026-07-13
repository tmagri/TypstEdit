import SwiftUI

struct AIRefinePreviewView: View {
    @ObservedObject var controller: EditorController
    @State private var editedResult: String = ""
    @FocusState private var resultFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Refinement")
                        .font(.headline)
                    Text("Review the suggestion. Edit it if needed, then accept or reject.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }
            .padding(.top)

            if controller.isAIRefining {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Refining…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Original")
                        .font(.subheadline.bold())

                    TextEditor(text: .constant(controller.aiRefineOriginalText))
                        .frame(height: 100)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Refined (editable)")
                        .font(.subheadline.bold())

                    TextEditor(text: $editedResult)
                        .focused($resultFocused)
                        .frame(height: 100)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.green.opacity(0.5), lineWidth: 1)
                        )
                        .font(.system(.body, design: .monospaced))
                }

                if let errorMessage = controller.aiRefineError {
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
                    Button("Reject") {
                        controller.rejectAIRefine()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)

                    Spacer()

                    Button(action: {
                        controller.acceptAIRefine(with: editedResult)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Accept")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(editedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .disabled(editedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom)
        .frame(width: 600)
        .onAppear {
            editedResult = controller.aiRefineResultText
            resultFocused = false
        }
        .onChange(of: controller.aiRefineResultText) { newValue in
            editedResult = newValue
        }
    }
}
