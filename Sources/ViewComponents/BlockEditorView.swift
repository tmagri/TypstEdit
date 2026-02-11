import SwiftUI

struct BlockEditorView: View {
    @ObservedObject var controller: EditorController
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "square.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentBlockRange == nil ? "Insert Block" : "Edit Block")
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
                VStack(alignment: .leading, spacing: 15) {
                    Group {
                        Label("Visuals", systemImage: "paintbrush")
                            .font(.subheadline.bold())
                        
                        VStack(spacing: 12) {
                            HStack {
                                Text("Fill:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. gray.lighten(80%) or luma(240)", text: $controller.blockFill)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            HStack {
                                Text("Stroke:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. 1pt + black", text: $controller.blockStroke)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            HStack {
                                Text("Radius:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. 4pt", text: $controller.blockRadius)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    
                    Divider()
                    
                    Group {
                        Label("Layout", systemImage: "rectangle.arrowtriangle.2.outward")
                            .font(.subheadline.bold())
                        
                        VStack(spacing: 12) {
                            HStack {
                                Text("Width:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. 100% or 5cm", text: $controller.blockWidth)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            HStack {
                                Text("Inset:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. 8pt", text: $controller.blockInset)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    
                    Divider()
                    
                    Group {
                        Label("Content", systemImage: "text.alignleft")
                            .font(.subheadline.bold())
                        
                        TextEditor(text: $controller.blockContent)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 150)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
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
                
                Button(controller.currentBlockRange == nil ? "Insert Block" : "Update Block") {
                    controller.insertBlock(
                        fill: controller.blockFill,
                        inset: controller.blockInset,
                        radius: controller.blockRadius,
                        width: controller.blockWidth,
                        stroke: controller.blockStroke,
                        content: controller.blockContent
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 600)
    }
}
