import SwiftUI

struct ToolbarView: View {
    @ObservedObject var controller: EditorController
    
    var body: some View {
        HStack(spacing: 0) {
            // Text formatting
            Group {
                Menu {
                    Button("Body", action: { controller.setHeadingLevel(0) })
                    Divider()
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)", action: { controller.setHeadingLevel(level) })
                    }
                } label: {
                ToolbarButton(text: controller.currentHeadingLevel == 0 ? "Body" : "H\(controller.currentHeadingLevel)", tooltip: "Heading Level", action: {})
                        .frame(width: 48) // Wider for text
                }
                .menuStyle(.borderlessButton)
                .frame(width: 54)
                ToolbarButton(icon: "bold", tooltip: "Bold (Cmd+B)", isActive: controller.isBoldActive, action: controller.toggleBold)
                ToolbarButton(icon: "italic", tooltip: "Italic (Cmd+I)", isActive: controller.isItalicActive, action: controller.toggleItalic)
                ToolbarButton(icon: "underline", tooltip: "Underline (Cmd+U)", isActive: controller.isUnderlineActive, action: controller.toggleUnderline)
                ToolbarButton(icon: "pencil.tip", tooltip: "Highlight (Cmd+Shift+H)", isActive: controller.isHighlightActive, action: controller.toggleHighlight)
                ToolbarButton(icon: "strikethrough", tooltip: "Strikethrough (Cmd+Shift+S)", isActive: controller.isStrikeActive) {
                    controller.toggleStrike()
                }
                
                ToolbarButton(icon: "link", tooltip: "Link (Cmd+K)", isActive: controller.isLinkActive) {
                    controller.toggleLink()
                }
                
                // Essentials Pack
                ToolbarButton(icon: "text.quote", tooltip: "Block Quote", isActive: controller.isQuoteActive, action: controller.toggleQuote)
                ToolbarButton(icon: "curlybraces", tooltip: "Code Block", isActive: controller.isCodeBlockActive, action: controller.toggleCodeBlock)
                
                // Color Picker - Simple Menu for now
                Menu {
                    Button(action: { controller.applyTextColor("red") }) { Label("Red", systemImage: "circle.fill").foregroundColor(.red) }
                    Button(action: { controller.applyTextColor("blue") }) { Label("Blue", systemImage: "circle.fill").foregroundColor(.blue) }
                    Button(action: { controller.applyTextColor("green") }) { Label("Green", systemImage: "circle.fill").foregroundColor(.green) }
                    Button(action: { controller.applyTextColor("orange") }) { Label("Orange", systemImage: "circle.fill").foregroundColor(.orange) }
                    Button(action: { controller.applyTextColor("purple") }) { Label("Purple", systemImage: "circle.fill").foregroundColor(.purple) }
                    Button(action: { controller.applyTextColor("black") }) { Label("Black", systemImage: "circle.fill").foregroundColor(.black) }
                } label: {
                    ToolbarButton(icon: "paintpalette", tooltip: "Text Color", action: {})
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)

                Divider()
                    .frame(height: 20)
            }
            
            Rectangle().fill(Color.clear).frame(width: 12, height: 1)
            
            // Snippets
            Group {
                ToolbarButton(icon: "tablecells", tooltip: "Insert Table", isActive: controller.isTableActive, action: controller.insertTableSnippet)
                ToolbarButton(icon: "photo", tooltip: "Insert Image", isActive: controller.isImageActive, action: controller.insertImageSnippet)
                ToolbarButton(icon: "chart.bar", tooltip: "Insert Chart", action: controller.insertChartSnippet)
                ToolbarButton(icon: "calendar", tooltip: "Insert Timeline", action: controller.insertTimelineSnippet)
                ToolbarButton(icon: "sum", tooltip: "Insert Equation", isActive: controller.isEquationActive, action: controller.openNewEquationEditor)
            }
            
            Rectangle().fill(Color.clear).frame(width: 12, height: 1)
            
            // Other formatting
            Group {
                ToolbarButton(icon: "doc.plaintext", tooltip: "Page Break (Cmd+Return)", action: controller.insertPageBreak)
                // .help modifier on the button itself is redundant if ToolbarButton handles it, but keep consistency
                
                ToolbarButton(icon: "minus", tooltip: "Horizontal Line", action: controller.insertHorizontalLine)
                
                ToolbarButton(icon: "chevron.left.forwardslash.chevron.right", tooltip: "Inline Code (Cmd+`)", isActive: controller.isCodeActive, action: controller.toggleCode)
            }
        }
    }
}

struct ToolbarButton: View {
    var icon: String?
    var text: String?
    var tooltip: String?
    var isActive: Bool = false
    var action: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                } else if let text = text {
                    Text(text)
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .frame(width: 28, height: 28)
            .background(isActive ? Color.accentColor : (isHovering ? Color.primary.opacity(0.1) : Color.clear))
            .foregroundColor(isActive ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(tooltip ?? (text ?? ""))
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
