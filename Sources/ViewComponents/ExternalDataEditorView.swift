import SwiftUI

struct ExternalDataEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.presentationMode) var presentationMode
    
    @State private var filePath: String = ""
    @State private var type: String = "JSON"
    @State private var variableName: String = "data"
    
    let types = ["JSON", "CSV", "XML", "YAML", "TOML"]
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Insert External Data")
                .font(.headline)
            
            Form {
                Picker("Type", selection: $type) {
                    ForEach(types, id: \.self) {
                        Text($0)
                    }
                }
                
                HStack {
                    TextField("File Path", text: $filePath)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [.json] // Expand based on selection?
                        // For simplicity, allow all or filter later
                        
                        // Simple setting of types based on selection
                        // This might be better as a computed property or update dynamically
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            self.filePath = url.path
                        }
                    }
                }
                
                TextField("Variable Name (Optional)", text: $variableName)
                Text("Will generate: #let \(variableName) = \(type.lowercased())(\"\(URL(fileURLWithPath: filePath).lastPathComponent)\")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            
            HStack {
                Button("Cancel") {
                    controller.showExternalDataEditor = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Insert") {
                    controller.insertExternalData(filePath: filePath, type: type, variableName: variableName)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(filePath.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
