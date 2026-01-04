import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var editorController: EditorController?
    
    // Shared logic for save warning
    func showSaveWarningIfNeeded() -> Bool {
        guard let controller = editorController, controller.hasUnsavedChanges else {
            return true // Proceed with closing/terminating
        }
        
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to the document?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn: // Save
            NotificationCenter.default.post(name: .requestSave, object: nil)
            return true // Proceed (after starting save)
        case .alertSecondButtonReturn: // Cancel
            return false // Abort
        case .alertThirdButtonReturn: // Don't Save
            return true // Proceed without saving
        default:
            return false
        }
    }
    
    // NSApplicationDelegate
    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // We need to bridge from nonisolated back to MainActor for runModal
        // Since runModal is synchronous, we can't easily wait for a Task.
        // However, in macOS apps, these delegate methods are called on the main thread.
        // We can use MainActor.assumeIsolated if we are sure, or just mark the delegate as @MainActor.
        
        return MainActor.assumeIsolated {
            if showSaveWarningIfNeeded() {
                return .terminateNow
            } else {
                return .terminateCancel
            }
        }
    }
    
    // NSWindowDelegate
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        print("[DEBUG] AppDelegate: windowShouldClose triggered")
        return MainActor.assumeIsolated {
            return showSaveWarningIfNeeded()
        }
    }
}

extension Notification.Name {
    static let requestSave = Notification.Name("requestSave")
}

@main
struct TypstEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var editorController = EditorController()
    @State private var selectedFile: URL?
    
    var body: some Scene {
        WindowGroup {
            ContentView(selectedFile: $selectedFile, editorController: editorController)
                .environmentObject(themeManager)
                .background(VisualEffectView().ignoresSafeArea())
                .background(WindowAccessor { window in
                    if window.delegate !== appDelegate {
                        print("[DEBUG] App: Assigning window delegate to appDelegate")
                        window.delegate = appDelegate
                    }
                })
                .onAppear {
                    appDelegate.editorController = editorController
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            AppMenuCommands(themeManager: themeManager, selectedFile: $selectedFile, editorController: editorController)
        }
    }
}