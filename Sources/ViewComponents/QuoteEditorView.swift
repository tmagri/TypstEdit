import SwiftUI

struct QuoteEditorView: View {
    @ObservedObject var controller: EditorController
    var onInsert: (String, String, Bool) -> Void
    var onCancel: () -> Void

    @State private var quoteText: String = ""
    @State private var attribution: String = ""
    @State private var isBlock: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "quote.opening")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentQuoteRange != nil ? "Edit Quote" : "Insert Quote")
                    .font(.headline)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Quote Text
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Quote Text", systemImage: "quote.bubble")
                            .font(.subheadline.bold())
                        TextEditor(text: $quoteText)
                            .frame(height: 100)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2)))
                    }
                    
                    Divider()
                    
                    // Options
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Options", systemImage: "slider.horizontal.3")
                            .font(.subheadline.bold())
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Attribution (Optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. Marcus Aurelius", text: $attribution)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Toggle("Block Quote", isOn: $isBlock)
                            .toggleStyle(.checkbox)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(controller.currentQuoteRange != nil ? "Update Quote" : "Insert Quote") {
                    onInsert(quoteText, attribution, isBlock)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 400)
        .onAppear {
            quoteText = controller.currentQuoteContent
            attribution = controller.currentQuoteAttribution
            isBlock = controller.isQuoteBlock
        }
    }
}
