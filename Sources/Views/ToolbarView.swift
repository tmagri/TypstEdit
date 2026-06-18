import SwiftUI

struct ToolbarView: View {
    @ObservedObject var controller: EditorController
    @State private var availableWidth: CGFloat = 800
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            
            // Granular collapsing thresholds based on priority
            // Collapsing order: Insert -> Font -> Paragraph -> Layout -> All
            let collapseInsert = width < 550
            let collapseFont = width < 480
            let collapseParagraph = width < 420
            let collapseLayout = width < 360
            
            HStack(alignment: .top, spacing: 4) {
                // --- Group 1: Document ---
                ToolbarGroup(title: "Document", icon: "doc.text", isCompact: collapseLayout) {
                     VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Menu {
                                 Button("Title", action: { controller.setTitle() })
                                Divider()
                                Button("Body", action: { controller.setHeadingLevel(0) })
                                Divider()
                                ForEach(1...6, id: \.self) { level in
                                    Button("Heading \(level)", action: { controller.setHeadingLevel(level) })
                                }
                            } label: {
                                let labelText: String = {
                                    if controller.isTitleActive { return "Title" }
                                    if controller.currentHeadingLevel == 0 { return "Body" }
                                    return "H\(controller.currentHeadingLevel)"
                                }()
                                ToolbarButton(text: labelText, tooltip: "Heading Level", action: {})
                                    .frame(width: 56)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 56)
                            
                            ToolbarButton(icon: "doc.badge.gearshape", tooltip: "Document Styles", action: controller.openLayoutEditor)
                        }
                    }
                }
                
                Divider().frame(height: 32)
                
                // --- Group 2: Font ---
                ToolbarGroup(title: "Font", icon: "textformat", isCompact: collapseFont) {
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ToolbarButton(icon: "bold", tooltip: "Bold (Cmd+B)", isActive: controller.isBoldActive, action: controller.toggleBold)
                            ToolbarButton(icon: "italic", tooltip: "Italic (Cmd+I)", isActive: controller.isItalicActive, action: controller.toggleItalic)
                            ToolbarButton(icon: "underline", tooltip: "Underline (Cmd+U)", isActive: controller.isUnderlineActive, action: controller.toggleUnderline)
                            ToolbarButton(icon: "strikethrough", tooltip: "Strikethrough (Cmd+Shift+S)", isActive: controller.isStrikeActive, action: controller.toggleStrike)
                        }
                        HStack(spacing: 2) {
                             ToolbarButton(icon: "pencil.tip", tooltip: "Highlight (Cmd+Shift+H)", isActive: controller.isHighlightActive, action: controller.toggleHighlight)
                             ToolbarButton(icon: "textformat.subscript", tooltip: "Subscript (Cmd+=)", isActive: controller.isSubscriptActive, action: controller.toggleSubscript)
                             ToolbarButton(icon: "textformat.superscript", tooltip: "Superscript (Cmd++, Shift for +)", isActive: controller.isSuperscriptActive, action: controller.toggleSuperscript)
                             
                             // Color Picker
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
                             .frame(width: 26)
                        }
                    }
                }
                
                Divider().frame(height: 32)
                
                // --- Group 3: Paragraph ---
                ToolbarGroup(title: "Paragraph", icon: "paragraphsign", isCompact: collapseParagraph) {
                     VStack(spacing: 2) {
                         HStack(spacing: 2) {
                             ToolbarButton(icon: "list.bullet", tooltip: "Bullet List (Cmd+Shift+8)", isActive: controller.isBulletListActive, action: controller.toggleBulletList)
                             ToolbarButton(icon: "list.number", tooltip: "Number List (Cmd+Shift+7)", isActive: controller.isNumberListActive, action: controller.toggleNumberList)
                             ToolbarButton(icon: "list.dash", tooltip: "Description List (Cmd+Shift+9)", isActive: controller.isDescriptionListActive, action: controller.toggleDescriptionList)
                             ToolbarButton(icon: "text.quote", tooltip: "Block Quote (Cmd+Shift+.)", isActive: controller.isQuoteActive, action: controller.toggleQuote)
                         }
                         HStack(spacing: 2) {
                             ToolbarButton(icon: "curlybraces", tooltip: "Code Block (Cmd+Shift+C)", isActive: controller.isCodeBlockActive, action: controller.toggleCodeBlock)
                             ToolbarButton(icon: "chevron.left.forwardslash.chevron.right", tooltip: "Inline Code (Cmd+`)", isActive: controller.isCodeActive, action: controller.toggleCode)
                         }
                     }
                }
                
                Divider().frame(height: 32)

                // --- Group 4: Insert ---
                ToolbarGroup(title: "Insert", icon: "plus.square", isCompact: collapseInsert) {
                     VStack(spacing: 2) {
                         HStack(spacing: 2) {
                             ToolbarButton(icon: "photo", tooltip: "Insert Image (Cmd+Ctrl+I)", isActive: controller.isImageActive, action: controller.insertImageSnippet)
                             ToolbarButton(icon: "tablecells", tooltip: "Insert Table (Cmd+Ctrl+T)", isActive: controller.isTableActive, action: controller.insertTableSnippet)
                             ToolbarButton(icon: "sum", tooltip: "Insert Equation (Cmd+Ctrl+E)", isActive: controller.isEquationActive, action: controller.openNewEquationEditor)
                             ToolbarButton(icon: "sparkles", tooltip: "AI Prompt (Cmd+Ctrl+A)", isActive: controller.showAIPromptEditor, action: controller.openAIPromptEditor) // Added AI Prompt
                             ToolbarButton(icon: "link", tooltip: "Link (Cmd+K)", isActive: controller.isLinkActive, action: controller.toggleLink)
                         }
                         HStack(spacing: 2) {
                             ToolbarButton(icon: "function", tooltip: "Insert Symbol (Cmd+Ctrl+S)", isActive: controller.showSymbolPicker) { controller.showSymbolPicker.toggle() }
                             ToolbarButton(icon: "photo.artframe", tooltip: "Insert Figure (Cmd+Ctrl+F)", isActive: controller.isFigureActive, action: controller.openFigureEditor)
                             ToolbarButton(icon: "list.bullet.rectangle", tooltip: "Insert Outline (Cmd+Ctrl+O)", isActive: controller.isOutlineActive, action: controller.openOutlineEditor)
                             ToolbarButton(icon: "server.rack", tooltip: "External Data (Cmd+Ctrl+D)", action: controller.openExternalDataEditor)
                             ToolbarButton(icon: "text.redaction", tooltip: "Scoped Block (Cmd+Ctrl+B)", isActive: controller.isScopedBlockActive, action: controller.toggleScopedBlock)
                             ToolbarButton(icon: "shippingbox", tooltip: "Insert Foundation (Cmd+Ctrl+I)", isActive: controller.showFoundationEditor, action: controller.openFoundationEditor)
                         }
                         HStack(spacing: 2) {
                             ToolbarButton(icon: "minus", tooltip: "Horizontal Line (Cmd+Opt+-)", isActive: controller.isHorizontalLineActive, action: controller.insertHorizontalLine)
                             ToolbarButton(icon: "doc.plaintext", tooltip: "Page Break (Cmd+Return)", isActive: controller.isPageBreakActive, action: controller.insertPageBreak)
                             ToolbarButton(icon: "square", tooltip: "Block (Cmd+Ctrl+B)", isActive: controller.isBlockActive, action: controller.openBlockEditor)
                             ToolbarButton(icon: "grid", tooltip: "Grid (Cmd+Ctrl+G)", isActive: controller.isGridActive, action: controller.openGridEditor)
                             ToolbarButton(icon: "chart.bar", tooltip: "Insert Chart (Cmd+Ctrl+C)", action: controller.insertChartSnippet)
                             ToolbarButton(icon: "calendar", tooltip: "Insert Timeline (Cmd+Ctrl+L)", action: controller.insertTimelineSnippet)
                         }
                     }
                }
                
                Divider().frame(height: 32)
                
                // --- Group 5: References (Always check space or always compact if Insert is compact?)
                // Let's make References collapse with Insert for now as they are both "extras", or give it its own status.
                // Given the user request, let's allow it to stay if space permits, or collapse last.
                // Actually References is small (2 buttons stacked). It can stay longer.
                // Let's collapse it with Paragraph for simplicity or Font.
                ToolbarGroup(title: "References", icon: "text.book.closed", isCompact: collapseInsert) {
                    VStack(spacing: 2) {
                        ToolbarButton(icon: "text.book.closed", tooltip: "Bibliography", isActive: controller.isBibliographyActive, action: controller.toggleBibliography)
                        ToolbarButton(icon: "character.textbox", tooltip: "Footnote", isActive: controller.isFootnoteActive, action: controller.openFootnoteEditor)
                    }
                }
            }
            .padding(4)
        }
        .frame(height: 100) // Allow sufficient height for the ribbon
    }
}

struct ToolbarGroup<Content: View>: View {
    let title: String
    let icon: String // Icon for collapsed state
    let isCompact: Bool
    let content: Content
    
    @State private var isHovering = false
    @State private var showPopover = false
    
    init(title: String, icon: String, isCompact: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.isCompact = isCompact
        self.content = content()
    }
    
    var body: some View {
        if isCompact {
            // Collapsed State
            VStack(alignment: .center, spacing: 3) {
                 Button(action: { showPopover.toggle() }) {
                     Image(systemName: icon)
                         .font(.title3)
                         .padding(8)
                         .background(isHovering ? Color.primary.opacity(0.1) : Color.clear)
                         .cornerRadius(6)
                 }
                 .buttonStyle(.plain)
                 .popover(isPresented: $showPopover) {
                     VStack(spacing: 4) {
                         Text(title).font(.headline).padding(.top, 4)
                         content.padding()
                     }
                 }
                 .onHover { isHovering = $0 }
                
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                    .opacity(0.8)
            }
            .frame(minWidth: 50)
            
        } else {
            // Expanded State
            VStack(alignment: .center, spacing: 3) {
                HStack(spacing: 2) {
                    content
                }
                // Ribbon Title
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                    .opacity(0.8)
            }
            .padding(.horizontal, 2)
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
                        .imageScale(.medium)
                } else if let text = text {
                    Text(text)
                        .font(.callout.weight(.semibold)) 
                }
            }
            .padding(6)
            .frame(minWidth: 28, minHeight: 28) // Keeps a consistent hit target but allows scaling
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