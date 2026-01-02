import SwiftUI

struct AppMenuCommands: Commands {
    @ObservedObject var themeManager: ThemeManager
    @Binding var selectedFile: URL?
    
    var body: some Commands {
        // MARK: - File Menu
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                // TODO: Implement new file
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            
            Button("Upload File...") {
                // TODO: Implement file picker  
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Divider()
            
            Button("Rename File") {
                // TODO: Implement rename
            }
            // F2 shortcut not supported in SwiftUI Commands
            
            Button("Package Project") {
                // TODO: Implement (PRO feature)
            }
            .disabled(true) // PRO feature placeholder
            
            Divider()
            
            Button("Quick Export PDF") {
                // TODO: Implement quick export
            }
            .keyboardShortcut("s", modifiers:[.command, .shift])
            
            Menu("Export As") {
                Button("PDF") {
                    // TODO
                }
                Button("PNG") {
                    // TODO
                }
                Button("SVG") {
                    // TODO
                }
            }
            
            Divider()
            
            Button("Backup Project") {
                // TODO: Implement backup
            }
        }
        
        // MARK: - Edit Menu
        CommandGroup(replacing: .textEditing) {
            Button("Undo") {
                if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager {
                    undoManager.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            
            Button("Redo") {
                if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager {
                    undoManager.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Search and Replace") {
                // TODO: Implement search/replace
            }
            .keyboardShortcut("f", modifiers: .command)
            
            Button("Go to Line") {
                // TODO: Implement go to line
            }
            .keyboardShortcut("g", modifiers: .command)
            
            Divider()
            
            Button("Select All") {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("a", modifiers: .command)
            
            Divider()
            
            Button("Toggle Line Comment") {
                // TODO: Implement
            }
            .keyboardShortcut("/", modifiers: .command)
            
            Button("Toggle Block Comment") {
                // TODO: Implement
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
            Button("File Panel") {
                // TODO: Toggle sidebar
            }
            
            Button("Search Panel") {
                // TODO: Show search panel
            }
            
            Button("Outline Panel") {
                // TODO: Show outline
            }
            
            Button("Improve Panel") {
                // TODO: Show improve panel
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            
            Button("Settings Panel") {
                // TODO: Show settings
            }
            
            Divider()
            
            Toggle("Show Collaborator Cursors", isOn: .constant(false))
                .disabled(true) // PRO feature
            
            Toggle("Show Toolbar", isOn: .constant(true))
            
            Toggle("Scroll on Type", isOn: .constant(true))
            
            Toggle("Wrap Lines", isOn: .constant(false))
            
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
                // TODO
            }
            
            Button("Only Show Preview") {
                // TODO
            }
            
            Toggle("Show Both Panels", isOn: .constant(true))
            
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
                // TODO
            }
            .keyboardShortcut("+", modifiers: .command)
            
            Button("Zoom Out") {
                // TODO
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
}

