import SwiftUI
import AppKit

struct AppMenuCommands: Commands {
    @ObservedObject var themeManager: ThemeManager
    @Binding var selectedFile: URL?
    /// The frontmost document window's controller (see
    /// `ActiveProjectContext`), so menu items act on the window in front.
    @ObservedObject var editorController: EditorController
    @ObservedObject private var recentFilesManager = RecentFilesManager.shared
    @AppStorage("aiAssistantEnabled") private var aiEnabled = false
    @AppStorage("aiChatEnabled") private var chatEnabled = false
    @ObservedObject private var generalSettings = GeneralSettingsManager.shared
    
    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    var body: some Commands {
        // MARK: - File Menu
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                AppDelegate.shared?.newDocument()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Window") {
                AppDelegate.shared?.newWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            
            Button("Open File...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = true
                
                if panel.runModal() == .OK, !panel.urls.isEmpty {
                    AppDelegate.shared?.openDocuments(panel.urls)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            
            // A folder that is already open brings its window forward.
            // Otherwise it opens in an idle window, or a new window.
            Button("Open Folder...") {
                if let url = chooseFolder() {
                    AppDelegate.shared?.openProject(at: url)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Open Folder in New Window...") {
                if let url = chooseFolder() {
                    AppDelegate.shared?.openProject(at: url, forceNewWindow: true)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift, .option])

            Menu("Open Recent") {
                if recentFilesManager.recentFiles.isEmpty {
                    Button("No Recent Items", action: {})
                        .disabled(true)
                } else {
                    ForEach(recentFilesManager.recentFiles) { file in
                        Button(action: {
                            AppDelegate.shared?.openRecent(file)
                        }) {
                            HStack {
                                Image(systemName: file.iconName)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                    Text(file.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(file.kindLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    Button("Clear Menu") {
                        recentFilesManager.clearAll()
                    }
                }
            }

            Button("Open Notes") {
                AppDelegate.shared?.openNotebooks()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            
            Menu("Import") {
                Button("PDF...") {
                    editorController.importPDF()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift, .option])

                Button("PDF (Force OCR)...") {
                    editorController.importPDF(forceOCR: true)
                }
                .help("Ignores the PDF's own text and reads every page from its image. Use it when imported text comes out garbled.")

                Divider()

                Button("LyX File...") {
                    editorController.importLyx()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            
            Divider()
            
            Button("Rename File") {
                NotificationCenter.default.post(name: .menuCommand, object: "renameFile")
            }
            // F2 shortcut not supported in SwiftUI Commands
            
            
            Divider()
            
            Menu("Export As") {
                Button("PDF") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportPDF")
                }
                .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)

                Button("PNG") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportPNG")
                }
                .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)

                Button("SVG") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportSVG")
                }
                .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)

                Divider()

                Button("Markdown") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportAsMarkdown")
                }
                .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)

                Button("Standard Typst (.typ)…") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportStandardTypst")
                }
                .help("Writes a .typ that compiles in stock Typst: calculator values are inlined and the calculator core is bundled next to it.")
                .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)
            }

            Menu("Share As") {
                Button("PDF...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "shareAsPDF")
                }
                .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)

                Button("Markdown...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "shareAsMarkdown")
                }
                .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)
            }

            Divider()
            
            Button("Backup Project") {
                NotificationCenter.default.post(name: .backupProject, object: nil)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            
            Button("Restore Backup...") {
                NotificationCenter.default.post(name: .menuCommand, object: "restoreBackup")
            }
            
            Divider()
            
            Button("Refresh Notebooks") {
                NotificationCenter.default.post(name: .menuCommand, object: "refreshNotebooks")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            if editorController.projectRootURL != nil {
                Divider()

                Button("Project AI Settings…") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openProjectSettings")
                }
            }
        }
        
        // MARK: - Edit Menu
        // Replace each system group individually to avoid duplicate items.
        
        // These groups replace AppKit's standard items so the actions can run
        // the editor's text conversion. Every action first gives a focused
        // native text view (a settings field, an alert's field editor, any
        // other window's text box) the standard AppKit behaviour — without
        // that, ⌘C in the Settings window posted a notification no document
        // window handled and nothing was copied. Only when the document
        // editor holds focus does the `.menuCommand` route run.
        let post = { (command: String) in
            NativeEditingCommand.route(command) { handled in
                NotificationCenter.default.post(name: .menuCommand, object: handled)
            }
        }

        // Replaces the system Undo / Redo pair
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { post("undo") }
            .keyboardShortcut("z", modifiers: .command)
            
            Button("Redo") { post("redo") }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        
        // Replaces the system Cut / Copy / Paste trio
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { post("cut") }
            .keyboardShortcut("x", modifiers: .command)
            
            Button("Copy") { post("copy") }
            .keyboardShortcut("c", modifiers: .command)

            Button("Copy and Convert as Markdown") {
                NotificationCenter.default.post(name: .menuCommand, object: "copyAsMarkdown")
            }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(!editorController.isTypstFile && !editorController.isMarkdownFile)
            
            Button("Paste") { post("paste") }
            .keyboardShortcut("v", modifiers: .command)
            
            Button("Paste as Plain Text") { post("pasteAsPlainText") }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Paste and Convert to Typst") { post("pasteForceTypst") }
            .keyboardShortcut("v", modifiers: [.command, .option])
            
            Button("Delete") { post("delete") }
            .keyboardShortcut(.delete, modifiers: [])
        }
        
        // Replaces the system Select All / text-editing group; also carries formatting shortcuts
        CommandGroup(replacing: .textEditing) {
            Button("Promote Heading") {
                NotificationCenter.default.post(name: .menuCommand, object: "promoteHeading")
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Demote Heading") {
                NotificationCenter.default.post(name: .menuCommand, object: "demoteHeading")
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Search and Replace") {
                editorController.showFindPanel()
            }
            .keyboardShortcut("f", modifiers: .command)
            
            Button("Go to Line") {
                NotificationCenter.default.post(name: .menuCommand, object: "goToLine")
            }
            .keyboardShortcut("l", modifiers: .command)
            
            Divider()
            
            Button("Select All") { post("selectAll") }
            .keyboardShortcut("a", modifiers: .command)
            
            Divider()
            
            Button("Bold") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleBold")
            }
            .keyboardShortcut("b", modifiers: .command)
            
            Button("Italic") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleItalic")
            }
            .keyboardShortcut("i", modifiers: .command)
            
            Button("Underline") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleUnderline")
            }
            .keyboardShortcut("u", modifiers: .command)
            
            Divider()
            
            Button("Toggle Line Comment") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleLineComment")
            }
            .keyboardShortcut("/", modifiers: .command)
            
            Button("Toggle Block Comment") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleBlockComment")
            }
            .keyboardShortcut("/", modifiers: [.command, .option])
            
            Divider()
            
            Button("Toggle Highlight") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleHighlight")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            
            Button("Toggle Strikethrough") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleStrike")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Subscript") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleSubscript")
            }
            .keyboardShortcut("-", modifiers: [.command, .control])
            
            Button("Superscript") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleSuperscript")
            }
            .keyboardShortcut("+", modifiers: [.command, .control])
            
            Divider()
            
            Button("Bullet List") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleBulletList")
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])
            
            Button("Numbered List") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleNumberList")
            }
            .keyboardShortcut("7", modifiers: [.command, .shift])
            
            Button("Description List") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleDescriptionList")
            }
            .keyboardShortcut("9", modifiers: [.command, .shift])
            
            Button("Inline Code") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleCode")
            }
            .keyboardShortcut("`", modifiers: .command)
            
            Button("Code Block") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleCodeBlock")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            
            Button("Block Quote") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleQuote")
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }



        
        // MARK: - Insert Menu
        CommandMenu("Insert") {
            Group {
                Button("Edit at Cursor...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openContextualEditor")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Table...") {
                    NotificationCenter.default.post(name: NSNotification.Name("insertTable"), object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .control])
                
                Button("Link...") {
                    NotificationCenter.default.post(name: NSNotification.Name("insertLink"), object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
                
                Button("Equation") {
                    NotificationCenter.default.post(name: .insertSnippet, object: "equation")
                }
                .keyboardShortcut("e", modifiers: [.command, .control])
                
                Button("Image") {
                    NotificationCenter.default.post(name: .insertSnippet, object: "image")
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                
                Button("Figure...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openFigureEditor")
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                
                Button("Symbol...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openSymbolPicker")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                
                if aiEnabled {
                    Button("AI Prompt...") {
                        NotificationCenter.default.post(name: .menuCommand, object: "aiPrompt")
                    }
                    .keyboardShortcut("a", modifiers: [.command, .control])
                }
                    
                Button("Outline...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openOutlineEditor")
                }
                .keyboardShortcut("o", modifiers: [.command, .control])
                
                Button("External Data...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openExternalDataEditor")
                }
                .keyboardShortcut("d", modifiers: [.command, .control])
                
                Button("Scoped Block") {
                    NotificationCenter.default.post(name: .menuCommand, object: "toggleScopedBlock")
                }
                .keyboardShortcut("b", modifiers: [.command, .control])
                
                Button("Block...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openBlockEditor")
                }
                .keyboardShortcut("b", modifiers: [.command, .option]) // block can't be cmd+ctrl+b because that's scoped block. Let's use option or something else.
                
                Button("Grid...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openGridEditor")
                }
                .keyboardShortcut("g", modifiers: [.command, .control])
                
                Button("Insert Foundation...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openFoundationEditor")
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                
                Divider()
                
                Button("Document Styles...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openLayoutEditor")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                }
            .disabled(!editorController.isTypstFile)
            
            Divider()
            
            Group {
                Button("Page Break") {
                    NotificationCenter.default.post(name: .menuCommand, object: "insertPageBreak")
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Horizontal Line") {
                    NotificationCenter.default.post(name: .menuCommand, object: "insertHorizontalLine")
                }
                .keyboardShortcut("-", modifiers: [.command, .option])
                
                Button("Block Quote") {
                    NotificationCenter.default.post(name: .menuCommand, object: "toggleQuote")
                }
                
                Button("Code Block") {
                    NotificationCenter.default.post(name: .menuCommand, object: "toggleCodeBlock")
                }
                
                Divider()
                
                Button("Bullet List") {
                    NotificationCenter.default.post(name: .menuCommand, object: "toggleBulletList")
                }
                
                Button("Numbered List") {
                    NotificationCenter.default.post(name: .menuCommand, object: "toggleNumberList")
                }
                
                Button("Description List") {
                    NotificationCenter.default.post(name: .menuCommand, object: "toggleDescriptionList")
                }

                Divider()

                Button("Label/Tag...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openTagEditor")
                }
                
                Button("Footnote") {
                    NotificationCenter.default.post(name: .menuCommand, object: "insertFootnote")
                }
                
                Button("Bibliography") {
                    NotificationCenter.default.post(name: .menuCommand, object: "insertBibliography")
                }
            }
            .disabled(!editorController.isTypstFile)
        }
        
        
        // MARK: - View Menu
        CommandGroup(after: .sidebar) {
            Toggle("Show Sidebar", isOn: $editorController.isSidebarVisible)
                .keyboardShortcut("0", modifiers: .command)
                .disabled(generalSettings.sidebarVisibility(chatEnabled: chatEnabled).panels.isEmpty)
            Menu("Sidebar Features") {
                SidebarVisibilityToggles()
            }
        }

        CommandMenu("Editor") {
            // "File Panel" moved to View → Show Sidebar (same state, ⌘0).

            // Search Panel toggle removed as we rely on native panel

            
            Divider()
            
            Toggle("Show Toolbar", isOn: .constant(true))
            
            Toggle("Scroll on Type", isOn: .constant(true))
            
            Toggle("Wrap Lines", isOn: $editorController.wrapLines)

            if chatEnabled {
                Button(editorController.isSidebarVisible && editorController.sidebarContent == .aiChat ? "Switch from AI Chat" : "Open AI Chat") {
                    editorController.toggleAIChatPanel()
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }

            if generalSettings.showCalculator {
                Button(editorController.isSidebarVisible && editorController.sidebarContent == .calculator ? "Switch from Calculator" : "Open Calculator") {
                    editorController.toggleCalculatorPanel()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            
            Toggle("Preview Dark Mode", isOn: $editorController.isPreviewDarkMode)
            
            Divider()
            
            Button("Split Views Vertically") {
                NotificationCenter.default.post(name: .menuCommand, object: "splitVertical")
            }
            
            Button("Split Views Horizontally") {
                NotificationCenter.default.post(name: .menuCommand, object: "splitHorizontal")
            }
            
            Divider()
            
            Menu("Cursor Size") {
                Button("Small") { editorController.cursorSize = 1.0 }
                Button("Medium") { editorController.cursorSize = 2.0 }
                Button("Large") { editorController.cursorSize = 4.0 }
                Button("Extra Large") { editorController.cursorSize = 6.0 }
            }
            
            Divider()
            
            Button("Only Show Editor") {
                NotificationCenter.default.post(name: .menuCommand, object: "viewEditorOnly")
            }
            
            Button("Only Show Preview") {
                NotificationCenter.default.post(name: .menuCommand, object: "viewPreviewOnly")
            }
            
            Button("Show Both Panels") {
                NotificationCenter.default.post(name: .menuCommand, object: "viewBothPanels")
            }
            
            
            Divider()
            
            Menu("Simulate Color Blindness") {
                Button("None") {
                    editorController.colorBlindnessMode = .none
                }
                .keyboardShortcut(editorController.colorBlindnessMode == .none ? .defaultAction : .cancelAction) // Visual hack or just rely on state
                
                Button("Protanopia") {
                    editorController.colorBlindnessMode = .protanopia
                }
                
                Button("Deuteranopia") {
                    editorController.colorBlindnessMode = .deuteranopia
                }
                
                Button("Tritanopia") {
                    editorController.colorBlindnessMode = .tritanopia
                }
            }
            
            Divider()

            
            Button("Zoom In") {
                NotificationCenter.default.post(name: .menuCommand, object: "zoomIn")
            }
            .keyboardShortcut("+", modifiers: .command)
            
            Button("Zoom Out") {
                NotificationCenter.default.post(name: .menuCommand, object: "zoomOut")
            }
            .keyboardShortcut("-", modifiers: .command)

            Menu("Preview Zoom") {
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .menuCommand, object: "previewZoomIn")
                }

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .menuCommand, object: "previewZoomOut")
                }

                Divider()

                Button("Fit to Window") {
                    NotificationCenter.default.post(name: .menuCommand, object: "previewZoomFit")
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            }
            
            Divider()
            
            Button("Refresh Preview") {
                NotificationCenter.default.post(name: .menuCommand, object: "refreshPreview")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        
        CommandGroup(replacing: .help) {
            Button("TypstEdit Help") {
                NotificationCenter.default.post(name: .menuCommand, object: "showHelp")
            }
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let insertSnippet = Notification.Name("insertSnippet")
    static let menuCommand = Notification.Name("menuCommand")
    static let backupProject = Notification.Name("backupProject")
}

