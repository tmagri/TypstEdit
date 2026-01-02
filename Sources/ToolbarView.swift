import SwiftUI

struct ToolbarView: View {
    @ObservedObject var controller: EditorController
    
    var body: some View {
        HStack(spacing: 0) {
            // Text formatting
            Group {
                ToolbarButton(icon: "bold", isActive: controller.isBoldActive, action: controller.toggleBold)
                ToolbarButton(icon: "italic", isActive: controller.isItalicActive, action: controller.toggleItalic)
                ToolbarButton(icon: "underline", isActive: controller.isUnderlineActive, action: controller.toggleUnderline)
            }
            
            Rectangle().fill(Color.clear).frame(width: 12, height: 1)
            
            // Snippets
            Group {
                ToolbarButton(icon: "tablecells", action: controller.insertTableSnippet)
                ToolbarButton(icon: "photo", action: controller.insertImageSnippet)
                ToolbarButton(icon: "chart.bar", action: controller.insertChartSnippet)
                ToolbarButton(icon: "calendar", action: controller.insertTimelineSnippet)
                ToolbarButton(icon: "sum", action: controller.openNewEquationEditor)
            }
            
            Rectangle().fill(Color.clear).frame(width: 12, height: 1)
            
            // Other formatting
            Group {
                Menu {
                    Button("Body", action: { controller.setHeadingLevel(0) })
                    Divider()
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)", action: { controller.setHeadingLevel(level) })
                    }
                } label: {
                    ToolbarButton(text: controller.currentHeadingLevel == 0 ? "Body" : "H\(controller.currentHeadingLevel)", action: {})
                        .frame(width: 48) // Wider for text
                }
                .menuStyle(.borderlessButton)
                .frame(width: 54)
                
                ToolbarButton(icon: "function", action: controller.insertMath)
                ToolbarButton(icon: "chevron.left.forwardslash.chevron.right", action: controller.toggleCode)
            }
        }
    }
}

struct ToolbarButton: View {
    var icon: String?
    var text: String?
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
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
