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
            .background(Color.black.opacity(0.1))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // File Selection
                    VStack(alignment: .leading, spacing: 10) {
                        Text("IMAGE FILE")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
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
                    .padding(12)
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(8)
                    
                    HStack(spacing: 20) {
                        // Width
                        VStack(alignment: .leading, spacing: 5) {
                            Text("WIDTH")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("auto, 100%, 200pt", text: $controller.imageWidth)
                                .textFieldStyle(.roundedBorder)
                            Text("Units: %, pt, mm, cm, in")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        
                        // Height
                        VStack(alignment: .leading, spacing: 5) {
                            Text("HEIGHT")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("auto, 100%, 200pt", text: $controller.imageHeight)
                                .textFieldStyle(.roundedBorder)
                            Text("Units: %, pt, mm, cm, in, fr")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Alt Text
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ALT TEXT")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Description for screen readers", text: $controller.imageAlt)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    // Fit
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FIT")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        Text("CODE PREVIEW")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                    .keyboardShortcut(.cancelAction)
                
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
                .keyboardShortcut(.defaultAction)
                .disabled(controller.imageValidationError != nil)
            }
            .padding()
        }
        .frame(width: 400, height: 450)
    }
}
