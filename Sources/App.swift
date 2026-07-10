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

    private var titleBarDoubleClickMonitor: Any?

    override init() {
        super.init()
        AppDelegate.shared = self
        print("[DEBUG] AppDelegate: init")
    }

    func setupTitleBarDoubleClick(for window: NSWindow) {
        guard titleBarDoubleClickMonitor == nil else { return }

        titleBarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak window] event in
            guard let window = window, event.window === window, event.clickCount >= 2 else { return event }

            let mouseLocation = NSEvent.mouseLocation
            let titleBarHeight: CGFloat = 60

            if mouseLocation.y > window.frame.maxY - titleBarHeight &&
               mouseLocation.x >= window.frame.minX && mouseLocation.x <= window.frame.maxX {
                DispatchQueue.main.async { window.zoom(nil) }
            }

            return event
        }
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
        return MainActor.assumeIsolated {
            if showSaveWarningIfNeeded() {
                // Clean up temp files for the current project before quitting
                if let projectRoot = editorController?.projectRootURL {
                    TypstCompiler.cleanUpTempDirectory(in: projectRoot)
                } else if let fileURL = editorController?.currentFileURL {
                    // Standalone file: clean temp/ next to the file
                    TypstCompiler.cleanUpTempDirectory(in: fileURL.deletingLastPathComponent())
                }
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
            if showSaveWarningIfNeeded() {
                // Clean up temp files when the window (project) closes
                if let projectRoot = editorController?.projectRootURL {
                    TypstCompiler.cleanUpTempDirectory(in: projectRoot)
                } else if let fileURL = editorController?.currentFileURL {
                    TypstCompiler.cleanUpTempDirectory(in: fileURL.deletingLastPathComponent())
                }
                // Reset the app state so the Welcome Screen appears on next launch
                NotificationCenter.default.post(name: .resetToWelcome, object: nil)
                
                return true
            }
            return false
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        
        // If width > height, it's a landscape monitor (side-by-side panels)
        // If height > width, it's a portrait monitor (top-and-bottom panels)
        let isLandscape = screen.frame.width > screen.frame.height
        
        // Only update if it actually needs changing
        if editorController?.isVerticalSplit != isLandscape {
            editorController?.isVerticalSplit = isLandscape
        }
    }
}

extension Notification.Name {
    static let requestSave = Notification.Name("requestSave")
    static let resetToWelcome = Notification.Name("resetToWelcome") 
}

@main
struct TypstEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var editorController = EditorController()
    @State private var selectedFile: URL?
    
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(selectedFile: $selectedFile, editorController: editorController)
                .environmentObject(themeManager)
                .background(VisualEffectView().ignoresSafeArea())
                .background(WindowAccessor { window in
                    if window.delegate !== appDelegate {
                        print("[DEBUG] App: Assigning window delegate to appDelegate")
                        window.delegate = appDelegate
                        // Set the initial split based on the screen it opened on
                        if let screen = window.screen {
                            let isLandscape = screen.frame.width > screen.frame.height
                            editorController.isVerticalSplit = isLandscape
                        }
                    }
                    appDelegate.setupTitleBarDoubleClick(for: window)
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