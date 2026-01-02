import SwiftUI

struct QuoteEditorView: View {
    @ObservedObject var controller: EditorController
    var onInsert: (String, String, Bool) -> Void
    var onCancel: () -> Void

    @State private var quoteText: String = ""
    @State private var attribution: String = ""
    @State private var isBlock: Bool = true

    var body: some View {
        VStack(spacing: 20) {
            Text(controller.currentQuoteRange != nil ? "Edit Quote" : "Insert Quote")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Quote Text")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $quoteText)
                    .frame(height: 100)
                    .padding(4)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
                    .border(Color.gray.opacity(0.2))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Attribution (Optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. Marcus Aurelius", text: $attribution)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            Toggle("Block Quote", isOn: $isBlock)
                .toggleStyle(.checkbox)
            
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(controller.currentQuoteRange != nil ? "Update" : "Insert") {
                    onInsert(quoteText, attribution, isBlock)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            quoteText = controller.currentQuoteContent
            attribution = controller.currentQuoteAttribution
            isBlock = controller.isQuoteBlock
        }
    }
}
