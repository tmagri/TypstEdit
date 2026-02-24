import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate?
    
    var editorController: EditorController? {
        didSet {
            print("[DEBUG] AppDelegate: editorController assigned (nil? \(editorController == nil))")
        }
    }
    
    override init() {
        super.init()
        AppDelegate.shared = self
        print("[DEBUG] AppDelegate: init")
    }
    
    // Shared logic for save warning (Async)
    func showSaveWarningAsync(for url: URL? = nil, completion: @escaping (Bool) -> Void) {
        print("[DEBUG] showSaveWarningAsync entry: editorController is nil? \(editorController == nil), hasUnsavedChanges=\(editorController?.hasUnsavedChanges ?? false), url=\(url?.lastPathComponent ?? "nil")")
        guard let controller = editorController, controller.hasUnsavedChanges else {
            completion(true) // Proceed
            return
        }
        
        let fileName = url?.lastPathComponent ?? "the document"
        
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        
        // Find the main window
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.isKeyWindow }) ?? NSApplication.shared.mainWindow else {
            // Fallback to sync if no window found (unlikely but safe)
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                NotificationCenter.default.post(name: .requestSave, object: url)
                completion(true)
            case .alertSecondButtonReturn:
                completion(false)
            default:
                completion(true)
            }
            return
        }
        
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: // Save
                NotificationCenter.default.post(name: .requestSave, object: url)
                completion(true)
            case .alertSecondButtonReturn: // Cancel
                completion(false)
            case .alertThirdButtonReturn: // Don't Save
                if let targetURL = url ?? self.editorController?.currentFileURL {
                    AutoRecoveryManager.shared.clearRecovery(for: targetURL)
                }
                completion(true)
            default:
                completion(false)
            }
        }
    }
    
    // Legacy sync version
    func showSaveWarningIfNeeded(for url: URL? = nil) -> Bool {
        print("[DEBUG] showSaveWarningIfNeeded entry: editorController is nil? \(editorController == nil), hasUnsavedChanges=\(editorController?.hasUnsavedChanges ?? false), url=\(url?.lastPathComponent ?? "nil")")
        guard let controller = editorController, controller.hasUnsavedChanges else {
            return true // Proceed with closing/terminating/switching
        }
        
        let fileName = url?.lastPathComponent ?? "the document"
        
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn: // Save
            NotificationCenter.default.post(name: .requestSave, object: url)
            return true // Proceed (after starting save)
        case .alertSecondButtonReturn: // Cancel
            return false // Abort
        case .alertThirdButtonReturn: // Don't Save
            if let targetURL = url ?? self.editorController?.currentFileURL {
                AutoRecoveryManager.shared.clearRecovery(for: targetURL)
            }
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
                    print("[DEBUG] TypstEditApp onAppear: assigning editorController to appDelegate")
                    appDelegate.editorController = editorController
                }
                .onOpenURL { url in
                    print("[DEBUG] TypstEditApp: onOpenURL triggered for \(url.lastPathComponent)")
                    NotificationCenter.default.post(name: .openProjectAndFile, object: url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            AppMenuCommands(themeManager: themeManager, selectedFile: $selectedFile, editorController: editorController)
        }
        
        Settings {
            SettingsView()
                .environmentObject(themeManager)
        }
    }
}