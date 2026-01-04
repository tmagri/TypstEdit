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
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.indent")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentOutlineRange != nil ? "Edit Outline" : "Insert Outline")
                    .font(.headline)
                Spacer()
                Button(action: { controller.showOutlineEditor = false }) {
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
                        Label("Configuration", systemImage: "gearshape")
                            .font(.subheadline.bold())
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Title (Optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Table of Contents", text: $title)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Target")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("", selection: $target) {
                                ForEach(targets, id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Depth (Optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. 3", text: $depthString)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: depthString) { newValue in
                                    let filtered = newValue.filter { "0123456789".contains($0) }
                                    if filtered != newValue {
                                        self.depthString = filtered
                                    }
                                }
                        }
                        
                        Toggle("Indent Entries", isOn: $indent)
                            .toggleStyle(.checkbox)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") {
                    controller.showOutlineEditor = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(controller.currentOutlineRange != nil ? "Update Outline" : "Insert Outline") {
                    let depth = Int(depthString)
                    controller.insertOutline(title: title, target: target, depth: depth, indent: indent ? true : nil)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 400, height: 400)
        .onAppear {
            self.title = controller.outlineTitle
            self.target = controller.outlineTarget
            self.depthString = controller.outlineDepthString
            self.indent = controller.outlineIndent
        }
    }
}
