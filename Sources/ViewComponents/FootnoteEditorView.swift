import SwiftUI

struct FootnoteEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.dismiss) var dismiss
    
    @State private var bodyText: String = ""
    @State private var numbering: String = "1"
    
    let numberingStyles = ["1", "a", "A", "i", "I", "①", "a."]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "character.textbox")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentFootnoteRange != nil ? "Edit Footnote" : "Insert Footnote")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
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
                    // Body
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Footnote Content", systemImage: "text.alignleft")
                            .font(.subheadline.bold())
                        TextEditor(text: $bodyText)
                            .frame(height: 100)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2)))
                    }
                    
                    // Numbering
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Numbering Style", systemImage: "list.number")
                            .font(.subheadline.bold())
                        HStack {
                            Picker("Style", selection: $numbering) {
                                ForEach(numberingStyles, id: \.self) { s in
                                    Text(s).tag(s)
                                }
                                Text("Custom").tag("custom")
                            }
                            .frame(width: 150)
                            
                            if numbering == "custom" {
                                TextField("Style", text: $numbering)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(controller.currentFootnoteRange != nil ? "Update Footnote" : "Insert Footnote") {
                    controller.insertFootnote(body: bodyText, numbering: numbering)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 400)
        .onAppear {
            bodyText = controller.footnoteBody
            numbering = controller.footnoteNumbering
            
            if numbering.isEmpty { numbering = "1" }
        }
    }
}
