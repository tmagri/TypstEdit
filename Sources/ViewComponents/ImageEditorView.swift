import SwiftUI

struct ImageEditorView: View {
    @ObservedObject var controller: EditorController
    var onInsert: () -> Void
    var onCancel: () -> Void
    
    let fitOptions = ["contain", "cover", "stretch"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(controller.currentImageRange != nil ? "Edit Image Properties" : "Image Properties")
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
                VStack(alignment: .leading, spacing: 20) {
                    // File Selection
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Image File", systemImage: "photo.on.rectangle")
                            .font(.subheadline.bold())
                        
                        HStack {
                            Button("Choose Image...") {
                                controller.browseForImage()
                            }
                            
                            if let url = controller.selectedImageURL {
                                Text(url.lastPathComponent)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(4)
                            } else {
                                Text("No file selected")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Toggle("Copy to project directory", isOn: $controller.shouldCopyImages)
                            .font(.subheadline)
                    }
                    
                    HStack(spacing: 20) {
                        // Width
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Width", systemImage: "arrow.left.and.right")
                                .font(.subheadline.bold())
                            TextField("auto, 100%, 200pt", text: $controller.imageWidth)
                                .textFieldStyle(.roundedBorder)
                            Text("Units: %, pt, mm, cm, in")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        
                        // Height
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Height", systemImage: "arrow.up.and.down")
                                .font(.subheadline.bold())
                            TextField("auto, 100%, 200pt", text: $controller.imageHeight)
                                .textFieldStyle(.roundedBorder)
                            Text("Units: %, pt, mm, cm, in, fr")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Alt Text
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Alt Text", systemImage: "text.bubble")
                            .font(.subheadline.bold())
                        TextField("Description for screen readers", text: $controller.imageAlt)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    // Fit
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Fit", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                            .font(.subheadline.bold())
                        Picker("", selection: $controller.imageFit) {
                            ForEach(fitOptions, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    if let warning = controller.imageValidationWarning {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(warning)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }
                    
                    // Code Preview
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Code Preview", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.subheadline.bold())
                        Text(controller.generateImageSnippet())
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(6)
                    }
                }
                .padding()
            }
            .onChange(of: controller.imageWidth) { _ in controller.validateImageSettings() }
            .onChange(of: controller.imageHeight) { _ in controller.validateImageSettings() }
            .onChange(of: controller.selectedImageURL) { _ in controller.validateImageSettings() }
            .onAppear { controller.validateImageSettings() }
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                if let error = controller.imageValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                }
                
                Button(controller.currentImageRange != nil ? "Update Image" : "Insert Image") {
                    onInsert()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(controller.imageValidationError != nil)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 550)
    }
}
