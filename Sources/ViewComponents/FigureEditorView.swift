import SwiftUI

struct FigureEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.presentationMode) var presentationMode
    
    @State private var content: String = ""
    @State private var caption: String = ""
    @State private var label: String = ""
    @State private var kind: String = ""
    @State private var supplement: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo.artframe")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Insert Figure")
                    .font(.headline)
                Spacer()
                Button(action: { controller.showFigureEditor = false }) {
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
                    // Content
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Content", systemImage: "paintbrush")
                            .font(.subheadline.bold())
                        TextEditor(text: $content)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 100)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2)))
                    }
                    
                    Divider()
                    
                    // Metadata
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Metadata", systemImage: "info.circle")
                            .font(.subheadline.bold())
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Caption")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Figure caption", text: $caption)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Label (no @ markers)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. my-figure", text: $label)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Kind (Optional)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("e.g. image", text: $kind)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Supplement (Optional)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("e.g. Figure", text: $supplement)
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
                    controller.showFigureEditor = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button("Insert Figure") {
                    controller.insertFigure(content: content, caption: caption, label: label, kind: kind, supplement: supplement)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 500)
        .onAppear {
            self.content = controller.currentFigureContent
        }
    }
}
