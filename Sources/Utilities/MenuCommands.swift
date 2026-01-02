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
            
            Button("Package Project") {
                // TODO: Implement (PRO feature)
            }
            .disabled(true) // PRO feature placeholder
            
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
            
            Button("Add Suggestion/Comment") {
                // TODO: PRO feature
            }
            .disabled(true)
        }
        
        // MARK: - Insert Menu
        CommandMenu("Insert") {
            Button("Table") {
                NotificationCenter.default.post(name: .insertSnippet, object: "table")
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            
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
        }
        
        
        // MARK: - View Menu
        CommandMenu("View") {
            Toggle("File Panel", isOn: $editorController.isSidebarVisible)
                .keyboardShortcut("b", modifiers: .command)
            
            Toggle("Search Panel", isOn: $editorController.isSearchVisible)
            
            Button("Outline Panel") {
                // TODO: Show outline
            }
            
            Button("Improve Panel") {
                // TODO: Show improve panel
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            
            Button("Settings Panel") {
                NotificationCenter.default.post(name: .menuCommand, object: "showSettings")
            }
            
            Divider()
            
            Toggle("Show Collaborator Cursors", isOn: .constant(false))
                .disabled(true) // PRO feature
            
            Toggle("Show Toolbar", isOn: .constant(true))
            
            Toggle("Scroll on Type", isOn: .constant(true))
            
            Toggle("Wrap Lines", isOn: $editorController.wrapLines)
            
            Divider()
            
            Button("Split Views Vertically") {
                // TODO
            }
            
            Button("Split Views Horizontally") {
                // TODO
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
            
            Button("Show Preview in Popup") {
                // TODO
            }
            
            Divider()
            
            Menu("Simulate Color Blindness") {
                Button("None") { }
                Button("Protanopia") { }
                Button("Deuteranopia") { }
                Button("Tritanopia") { }
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
            
            Button("Fit to Width") {
                // TODO
            }
            
            Button("Fit to Height") {
                // TODO
            }
            
            Button("Fit to Page") {
                // TODO
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

