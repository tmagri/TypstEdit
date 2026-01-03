import SwiftUI

struct BibliographyEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.dismiss) var dismiss
    
    @State private var sources: String = ""
    @State private var title: String = ""
    @State private var full: Bool = false
    @State private var style: String = "apa"
    
    // Some common styles for the picker
    let commonStyles = ["apa", "ieee", "mla", "chicago-author-date", "vancouver"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "text.book.closed")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Bibliography Editor")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
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
                    // Sources
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Sources (e.g., works.bib, refs.yml)", systemImage: "doc.text")
                            .font(.subheadline.bold())
                        TextField("works.bib", text: $sources)
                            .textFieldStyle(.roundedBorder)
                        Text("Separate multiple files with commas.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Title
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Title", systemImage: "text.alignleft")
                            .font(.subheadline.bold())
                        TextField("Optional title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    // Style
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Citation Style", systemImage: "list.bullet")
                            .font(.subheadline.bold())
                        HStack {
                            Picker("Presets", selection: $style) {
                                ForEach(commonStyles, id: \.self) { s in
                                    Text(s).tag(s)
                                }
                                Text("Custom").tag("custom")
                            }
                            .frame(width: 150)
                            
                            if style == "custom" {
                                TextField("Style name", text: $style)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    
                    // Full references toggle
                    Toggle(isOn: $full) {
                        VStack(alignment: .leading) {
                            Text("Include All Entries")
                                .font(.subheadline.bold())
                            Text("Show all entries in the bibliography, even those not cited.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button("Update Bibliography") {
                    controller.insertBibliography(sources: sources, title: title, full: full, style: style)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 500)
        .onAppear {
            sources = controller.bibSources
            title = controller.bibTitle
            full = controller.bibFull
            style = controller.bibStyle
            
            if sources.isEmpty { sources = "works.bib" }
        }
    }
}
