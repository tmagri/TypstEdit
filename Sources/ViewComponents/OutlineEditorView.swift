import SwiftUI

struct OutlineEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.presentationMode) var presentationMode
    
    @State private var title: String = ""
    @State private var target: String = "Heading"
    @State private var depthString: String = ""
    @State private var indent: Bool = false
    
    let targets = ["Heading", "Figure", "Image", "Custom"]
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Insert Outline")
                .font(.headline)
            
            Form {
                TextField("Title (Optional)", text: $title)
                
                Picker("Target", selection: $target) {
                    ForEach(targets, id: \.self) {
                        Text($0)
                    }
                }
                
                TextField("Depth (Optional)", text: $depthString)
                    .onChange(of: depthString) { newValue in
                        // Only allow numbers
                        let filtered = newValue.filter { "0123456789".contains($0) }
                        if filtered != newValue {
                            self.depthString = filtered
                        }
                    }
                
                Toggle("Indent", isOn: $indent)
            }
            .padding()
            
            HStack {
                Button("Cancel") {
                    controller.showOutlineEditor = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Insert") {
                    let depth = Int(depthString)
                    // If target is "Heading", we might not pass it explicitly as it is default,
                    // but passing explicit "target: heading" or "target: figure" is safer.
                    // However, Typst default is headings.
                    controller.insertOutline(title: title, target: target, depth: depth, indent: indent ? true : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 350)
    }
}
