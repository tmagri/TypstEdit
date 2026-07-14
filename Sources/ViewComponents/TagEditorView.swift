import SwiftUI

struct TagEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.dismiss) var dismiss
    
    @State private var labelText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "tag")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentTagRange != nil ? "Edit Tag/Label" : "Insert Tag/Label")
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
            
            VStack(alignment: .leading, spacing: 16) {
                // Body
                VStack(alignment: .leading, spacing: 8) {
                    Label("Label Name", systemImage: "text.cursor")
                        .font(.subheadline.bold())
                    
                    TextField("e.g. intro, figure-1, my_tag", text: $labelText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    
                    Text("Tags can only contain alphanumeric characters, hyphens, and underscores. No spaces allowed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(controller.currentTagRange != nil ? "Update Tag" : "Insert Tag") {
                    // Basic validation to remove spaces
                    let sanitized = labelText.replacingOccurrences(of: " ", with: "-")
                    controller.insertTag(label: sanitized)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(labelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 400)
        .onAppear {
            labelText = controller.tagLabel
        }
    }
}
