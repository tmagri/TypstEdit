import SwiftUI

struct AppMenuCommands: Commands {
    @ObservedObject var themeManager: ThemeManager
    @Binding var selectedFile: URL?
    @ObservedObject var editorController: EditorController
    
    var body: some Commands {
        // MARK: - File Menu
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                NotificationCenter.default.post(name: .menuCommand, object: "newFile")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            
            Button("Upload File...") {
                NotificationCenter.default.post(name: .menuCommand, object: "uploadFile")
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Button("Import LyX File...") {
                NotificationCenter.default.post(name: .menuCommand, object: "importLyx")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Rename File") {
                NotificationCenter.default.post(name: .menuCommand, object: "renameFile")
            }
            // F2 shortcut not supported in SwiftUI Commands
            
            
            Divider()
            
            Button("Quick Export PDF") {
                NotificationCenter.default.post(name: .menuCommand, object: "quickExportPDF")
            }
            .keyboardShortcut("s", modifiers:[.command, .shift])
            .disabled(!editorController.isTypstFile)
            
            Menu("Export As") {
                Button("PDF") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportPDF")
                }
                .disabled(!editorController.isTypstFile)
                
                Button("PNG") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportPNG")
                }
                .disabled(!editorController.isTypstFile)
                
                Button("SVG") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportSVG")
                }
                .disabled(!editorController.isTypstFile)
            }
            
            Divider()
            
            Button("Backup Project") {
                NotificationCenter.default.post(name: .backupProject, object: nil)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }
        
        // MARK: - Edit Menu
        CommandGroup(replacing: .textEditing) {
            Button("Undo") {
                NotificationCenter.default.post(name: .menuCommand, object: "undo")
            }
            .keyboardShortcut("z", modifiers: .command)
            
            Button("Redo") {
                NotificationCenter.default.post(name: .menuCommand, object: "redo")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Cut") {
                NotificationCenter.default.post(name: .menuCommand, object: "cut")
            }
            .keyboardShortcut("x", modifiers: .command)
            
            Button("Copy") {
                NotificationCenter.default.post(name: .menuCommand, object: "copy")
            }
            .keyboardShortcut("c", modifiers: .command)
            
            Button("Paste") {
                NotificationCenter.default.post(name: .menuCommand, object: "paste")
            }
            .keyboardShortcut("v", modifiers: .command)
            
            Button("Delete") {
                NotificationCenter.default.post(name: .menuCommand, object: "delete")
            }
            .keyboardShortcut(.delete, modifiers: [])
            
            Divider()
            
            Button("Search and Replace") {
                editorController.showFindPanel()
            }
            .keyboardShortcut("f", modifiers: .command)
            
            Button("Go to Line") {
                NotificationCenter.default.post(name: .menuCommand, object: "goToLine")
            }
            .keyboardShortcut("l", modifiers: .command) // Changed G to L which is more common and was G in original but typically L
            
            Divider()
            
            Button("Select All") {
                NotificationCenter.default.post(name: .menuCommand, object: "selectAll")
            }
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
            .keyboardShortcut("=", modifiers: .command)
            
            Button("Superscript") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleSuperscript")
            }
            .keyboardShortcut("+", modifiers: .command)
            
            Divider()
            
            Button("Bullet List") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleBulletList")
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])
            
            Button("Numbered List") {
                NotificationCenter.default.post(name: .menuCommand, object: "toggleNumberList")
            }
            .keyboardShortcut("7", modifiers: [.command, .shift])
            
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
                
                Button("Chart") {
                    NotificationCenter.default.post(name: .insertSnippet, object: "chart")
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                
                Button("Figure...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openFigureEditor")
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                
                Button("Symbol...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openSymbolPicker")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                
                Button("AI Prompt...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "aiPrompt")
                }
                .keyboardShortcut("a", modifiers: [.command, .control])
                
                Button("Timeline") {
                    NotificationCenter.default.post(name: .insertSnippet, object: "timeline")
                }
                .keyboardShortcut("l", modifiers: [.command, .control])
                
                Button("Outline...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openOutlineEditor")
                }
                .keyboardShortcut("o", modifiers: [.command, .control])
                
                Button("External Data...") {
                    NotificationCenter.default.post(name: .menuCommand, object: "openExternalDataEditor")
                }
                .keyboardShortcut("d", modifiers: [.command, .control])
                
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
        CommandMenu("View") {
            Toggle("File Panel", isOn: $editorController.isSidebarVisible)
                .keyboardShortcut("0", modifiers: .command)
            
            // Search Panel toggle removed as we rely on native panel

            
            Divider()
            
            Toggle("Show Toolbar", isOn: .constant(true))
            
            Toggle("Scroll on Type", isOn: .constant(true))
            
            Toggle("Wrap Lines", isOn: $editorController.wrapLines)
            
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

