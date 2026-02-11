import SwiftUI

struct GridEditorView: View {
    @ObservedObject var controller: EditorController
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "grid")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentGridRange == nil ? "Insert Grid" : "Edit Grid")
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
                        Label("Grid Setup", systemImage: "rectangle.split.3x3")
                            .font(.subheadline.bold())
                        
                        VStack(spacing: 12) {
                            HStack {
                                Text("Columns:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. (1fr, auto) or 3", text: $controller.gridColumns)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            HStack {
                                Text("Gutter:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. 10pt", text: $controller.gridGutter)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    
                    Divider()
                    
                    Group {
                        HStack {
                            Label("Cells", systemImage: "square.grid.2x2")
                                .font(.subheadline.bold())
                            Spacer()
                            Button(action: {
                                controller.gridCells.append("")
                            }) {
                                Label("Add Cell", systemImage: "plus")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                        
                        VStack(spacing: 8) {
                            if controller.gridCells.isEmpty {
                                Text("No cells added yet.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding()
                            }
                            
                            ForEach(0..<controller.gridCells.count, id: \.self) { index in
                                HStack {
                                    Text("\(index + 1):")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(width: 30, alignment: .leading)
                                    
                                    TextField("Cell content...", text: $controller.gridCells[index])
                                        .textFieldStyle(.roundedBorder)
                                    
                                    Button(action: {
                                        controller.gridCells.remove(at: index)
                                    }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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
                
                Button(controller.currentGridRange == nil ? "Insert Grid" : "Update Grid") {
                    controller.insertGrid(
                        columns: controller.gridColumns,
                        gutter: controller.gridGutter,
                        cells: controller.gridCells
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
