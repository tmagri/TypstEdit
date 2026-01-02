import SwiftUI

struct LinkEditorView: View {
    @ObservedObject var controller: EditorController
    var onInsert: (String, String) -> Void
    var onCancel: () -> Void
    
    @State private var url: String = ""
    @State private var text: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text(controller.currentLinkRange == nil ? "Insert Link" : "Edit Link")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://example.com", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if !url.isEmpty {
                                onInsert(url, text)
                            }
                        }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display Text (optional):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("My Link", text: $text)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(controller.currentLinkRange == nil ? "Insert" : "Update") {
                    onInsert(url, text)
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            self.url = controller.currentLinkURL
            self.text = controller.currentLinkText
        }
    }
}
