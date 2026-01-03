import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TypstEdit Help")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.black.opacity(0.1))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    HelpSection(title: "Getting Started") {
                        Text("TypstEdit is a modern editor for the Typst typesetting system. Create professional documents, reports, and resumes with ease.")
                        Text("To start, open a folder containing your Typst project or create a new one from the Welcome screen.")
                    }
                    
                    HelpSection(title: "Keyboard Shortcuts") {
                        ShortcutRow(keys: "⌘ N", description: "New File")
                        ShortcutRow(keys: "⌘ O", description: "Open Folder")
                        ShortcutRow(keys: "⌘ S", description: "Save")
                        ShortcutRow(keys: "⌘ ⇧ S", description: "Quick Export PDF")
                        ShortcutRow(keys: "⌘ B", description: "Toggle Sidebar")
                        ShortcutRow(keys: "⌘ F", description: "Search")
                        ShortcutRow(keys: "⌘ /", description: "Toggle Line Comment")
                        ShortcutRow(keys: "⌘ ]", description: "Indent")
                        ShortcutRow(keys: "⌘ [", description: "Outdent")
                    }
                    
                    HelpSection(title: "Typst Basics") {
                        VStack(alignment: .leading, spacing: 10) {
                            CodeSnippet(code: "= Heading", description: "Create a heading")
                            CodeSnippet(code: "*Bold Text*", description: "Make text bold")
                            CodeSnippet(code: "_Italic Text_", description: "Make text italic")
                            CodeSnippet(code: "- Bullet point", description: "Create a list")
                            CodeSnippet(code: "+ Numbered point", description: "Create a numbered list")
                            CodeSnippet(code: "$ x^2 + y^2 = r^2 $", description: "Inline equation")
                        }
                    }
                    
                    HelpSection(title: "Useful Links") {
                        LinkCard(title: "Official Typst Documentation", url: "https://typst.app/docs")
                        LinkCard(title: "Typst Tutorial", url: "https://typst.app/docs/tutorial/")
                        LinkCard(title: "Typst Reference", url: "https://typst.app/docs/reference/")
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 600)
        .background(themeManager.mainBackground)
        .foregroundColor(themeManager.textColor)
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.accentColor)
            content
        }
    }
}

struct ShortcutRow: View {
    let keys: String
    let description: String
    
    var body: some View {
        HStack {
            Text(description)
            Spacer()
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
        }
    }
}

struct CodeSnippet: View {
    let code: String
    let description: String
    
    var body: some View {
        HStack {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Text(description)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }
}

struct LinkCard: View {
    let title: String
    let url: String
    
    var body: some View {
        Button(action: {
            if let nsURL = URL(string: url) {
                NSWorkspace.shared.open(nsURL)
            }
        }) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right.square")
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
