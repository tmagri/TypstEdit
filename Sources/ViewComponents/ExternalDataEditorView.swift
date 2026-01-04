import SwiftUI

struct ExternalDataEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.presentationMode) var presentationMode
    
    @State private var filePath: String = ""
    @State private var type: String = "JSON"
    @State private var variableName: String = "data"
    
    let types = ["JSON", "CSV", "XML", "YAML", "TOML"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Insert External Data")
                    .font(.headline)
                Spacer()
                Button(action: { controller.showExternalDataEditor = false }) {
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
                        Label("Data Type", systemImage: "square.grid.3x3")
                            .font(.subheadline.bold())
                        Picker("", selection: $type) {
                            ForEach(types, id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("File Path", systemImage: "folder")
                            .font(.subheadline.bold())
                        HStack {
                            TextField("File Path", text: $filePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = true
                                panel.allowsMultipleSelection = false
                                panel.allowedContentTypes = [.json] // Expand based on selection?
                                
                                if panel.runModal() == .OK, let url = panel.url {
                                    self.filePath = url.path
                                }
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Variable Name", systemImage: "character.cursor.ibeam")
                            .font(.subheadline.bold())
                        TextField("Variable name (e.g. data)", text: $variableName)
                            .textFieldStyle(.roundedBorder)
                        
                        Text("Snippet: #let \(variableName) = \(type.lowercased())(\"\(URL(fileURLWithPath: filePath).lastPathComponent)\")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") {
                    controller.showExternalDataEditor = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button("Insert Data") {
                    controller.insertExternalData(filePath: filePath, type: type, variableName: variableName)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(filePath.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 400)
    }
}
