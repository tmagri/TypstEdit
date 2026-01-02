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
            
            Divider()
            
            Button("Rename File") {
                NotificationCenter.default.post(name: .menuCommand, object: "renameFile")
            }
            // F2 shortcut not supported in SwiftUI Commands
            
            
            Divider()
            
            Button("Quick Export PDF") {
                NotificationCenter.default.post(name: .menuCommand, object: "exportPDF")
            }
            .keyboardShortcut("s", modifiers:[.command, .shift])
            
            Menu("Export As") {
                Button("PDF") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportPDF")
                }
                Button("PNG") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportPNG")
                }
                Button("SVG") {
                    NotificationCenter.default.post(name: .menuCommand, object: "exportSVG")
                }
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
            
            Button("Search and Replace") {
                withAnimation {
                    editorController.isSearchVisible.toggle()
                }
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
            
            Divider()
            
            Button("Add Suggestion/Comment") {
                // TODO: PRO feature
            }
            .disabled(true)
        }
        
        // MARK: - Insert Menu
        CommandMenu("Insert") {
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
            
            Divider()
            
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
        }
        
        
        // MARK: - View Menu
        CommandMenu("View") {
            Toggle("File Panel", isOn: $editorController.isSidebarVisible)
                .keyboardShortcut("b", modifiers: .command)
            
            Toggle("Search Panel", isOn: $editorController.isSearchVisible)
                    
            Button("Settings Panel") {
                NotificationCenter.default.post(name: .menuCommand, object: "showSettings")
            }
            
            Divider()
            
            Toggle("Show Toolbar", isOn: .constant(true))
            
            Toggle("Scroll on Type", isOn: .constant(true))
            
            Toggle("Wrap Lines", isOn: $editorController.wrapLines)
            
            Divider()
            
            Button("Split Views Vertically") {
                NotificationCenter.default.post(name: .menuCommand, object: "splitVertical")
            }
            
            Button("Split Views Horizontally") {
                NotificationCenter.default.post(name: .menuCommand, object: "splitHorizontal")
            }
            
            Divider()
            
            Menu("Cursor Size") {
                Button("Small") { }
                Button("Medium") { }
                Button("Large") { }
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
            
            Button("Present") {
                // TODO: PRO
            }
            .disabled(true)
            
            Button("Speaker Mode") {
                // TODO: PRO
            }
            .disabled(true)
            
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
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let insertSnippet = Notification.Name("insertSnippet")
    static let menuCommand = Notification.Name("menuCommand")
    static let backupProject = Notification.Name("backupProject")
}

