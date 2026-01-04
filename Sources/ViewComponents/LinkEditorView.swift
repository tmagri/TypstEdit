import SwiftUI

struct LinkEditorView: View {
    @ObservedObject var controller: EditorController
    var onInsert: (String, String) -> Void
    var onCancel: () -> Void
    
    @State private var url: String = ""
    @State private var text: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "link")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentLinkRange == nil ? "Insert Link" : "Edit Link")
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
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Link Details", systemImage: "link.badge.plus")
                            .font(.subheadline.bold())
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("URL:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("https://example.com", text: $url)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Display Text (optional):")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("My Link", text: $text)
                                .textFieldStyle(.roundedBorder)
                        }
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
                
                Button(controller.currentLinkRange == nil ? "Insert Link" : "Update Link") {
                    onInsert(url, text)
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 400, height: 300)
        .onAppear {
            self.url = controller.currentLinkURL
            self.text = controller.currentLinkText
        }
    }
}
