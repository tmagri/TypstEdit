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
        VStack(spacing: 20) {
            Text("Insert Figure")
                .font(.headline)
            
            Form {
                Section(header: Text("Content")) {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                }
                
                Section(header: Text("Metadata")) {
                    TextField("Caption", text: $caption)
                    TextField("Label (no markers)", text: $label)
                    TextField("Kind (Optional)", text: $kind)
                    TextField("Supplement (Optional)", text: $supplement)
                }
            }
            .padding()
            
            HStack {
                Button("Cancel") {
                    controller.showFigureEditor = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Insert") {
                    controller.insertFigure(content: content, caption: caption, label: label, kind: kind, supplement: supplement)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, height: 400)
        .onAppear {
            self.content = controller.currentFigureContent
        }
    }
}
