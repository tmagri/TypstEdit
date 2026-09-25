import SwiftUI
import AppKit

@MainActor
private struct ExternalDocumentWindowRoot: View {
    @State private var selectedFile: URL?
    let initialFile: URL
    @StateObject private var themeManager = ThemeManager()
    @ObservedObject var editorController: EditorController

    init(initialFile: URL, editorController: EditorController) {
        self.initialFile = initialFile
        // Inject the file directly into state. 
        // This avoids broadcasting a global notification that overwrites other windows.
        self._selectedFile = State(initialValue: initialFile)
        self.editorController = editorController
    }

    var body: some View {
        ContentView(selectedFile: $selectedFile, editorController: editorController)
            .environmentObject(themeManager)
            .background(VisualEffectView().ignoresSafeArea())
            .onAppear {
                // Initialize standalone UI locally without global broadcasts
                DispatchQueue.main.async {
                    self.editorController.isSidebarVisible = false
                    self.editorController.projectRootURL = nil
                    RAGManager.shared.disableForStandaloneMode()
                }
            }
    }
}

class ExternalWindowDelegate: NSObject, NSWindowDelegate {
    let editorController: EditorController
    
    init(editorController: EditorController) {
        self.editorController = editorController
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return AppDelegate.shared?.handleWindowClose(for: sender, editorController: editorController, isMain: false) ?? true
    }
    
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            AppDelegate.shared?.externalDelegates.removeValue(forKey: window)
        }
    }
    
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        
        let isLandscape = screen.frame.width > screen.frame.height
        if editorController.isVerticalSplit != isLandscape {
            editorController.isVerticalSplit = isLandscape
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate?

    var editorController: EditorController?
    var externalDelegates: [NSWindow: ExternalWindowDelegate] = [:]
    
    private var titleBarDoubleClickMonitor: Any?
    
    override init() {
        super.init()
        AppDelegate.shared = self
        print("[DEBUG] AppDelegate: init")
    }

    // Replace the openDebounceTimer variable with a Task
    private var pendingURLs: Set<URL> = []
    private var debounceTask: Task<Void, Never>?

    @MainActor
    func queueExternalOpen(_ url: URL) {
        pendingURLs.insert(url)
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            // Wait for 100 milliseconds (0.1 seconds)
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self = self else { return }
            
            let urls = Array(self.pendingURLs)
            self.pendingURLs.removeAll()
            guard !urls.isEmpty else { return }
            
            self.handleExternalOpen(urls)
        }
    }

    func setupTitleBarDoubleClick(for window: NSWindow) {
        guard titleBarDoubleClickMonitor == nil else { return }

        titleBarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak window] event in
            guard let window = window, event.window === window, event.clickCount >= 2 else { return event }

            let mouseLocation = NSEvent.mouseLocation
            let titleBarHeight: CGFloat = 60

            if mouseLocation.y > window.frame.maxY - titleBarHeight &&
               mouseLocation.x >= window.frame.minX && mouseLocation.x <= window.frame.maxX {
                MainActor.assumeIsolated {
                    AppDelegate.toggleWindowZoom(preferred: window)
                }
            }
            return event
        }
    }

    private static var lastZoomToggle: CFAbsoluteTime = 0

    @MainActor
    static func toggleWindowZoom(preferred window: NSWindow? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastZoomToggle > 0.3 else { return }
        lastZoomToggle = now

        let target = window
            ?? NSApp.windows.first(where: { $0.isKeyWindow })
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
        guard let target else { return }

        if target.styleMask.contains(.fullScreen) {
            target.toggleFullScreen(nil)
        } else {
            target.zoom(nil)
        }
    }
    
    func showSaveWarningAsync(for controller: EditorController? = nil, url: URL? = nil, completion: @escaping (Bool) -> Void) {
        let activeController = controller ?? self.editorController
        guard let controllerRef = activeController, controllerRef.hasUnsavedChanges else {
            completion(true)
            return
        }
        
        let fileName = url?.lastPathComponent ?? controllerRef.currentFileURL?.lastPathComponent ?? "the document"
        
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.isKeyWindow }) ?? NSApplication.shared.mainWindow else {
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                var payload: [String: Any] = ["target": controllerRef]
                if let u = url { payload["url"] = u }
                NotificationCenter.default.post(name: .requestSave, object: payload)
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
            case .alertFirstButtonReturn:
                var payload: [String: Any] = ["target": controllerRef]
                if let u = url { payload["url"] = u }
                NotificationCenter.default.post(name: .requestSave, object: payload)
                completion(true)
            case .alertSecondButtonReturn:
                completion(false)
            case .alertThirdButtonReturn:
                if let targetURL = url ?? activeController?.currentFileURL {
                    AutoRecoveryManager.shared.clearRecovery(for: targetURL)
                }
                completion(true)
            default:
                completion(false)
            }
        }
    }
    
    func showSaveWarningIfNeeded(for controller: EditorController? = nil, url: URL? = nil) -> Bool {
        let activeController = controller ?? self.editorController
        guard let controllerRef = activeController, controllerRef.hasUnsavedChanges else {
            return true
        }
        
        let fileName = url?.lastPathComponent ?? controllerRef.currentFileURL?.lastPathComponent ?? "the document"
        
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            var payload: [String: Any] = ["target": controllerRef]
            if let u = url { payload["url"] = u }
            NotificationCenter.default.post(name: .requestSave, object: payload)
            return true
        case .alertSecondButtonReturn:
            return false
        case .alertThirdButtonReturn:
            if let targetURL = url ?? activeController?.currentFileURL {
                AutoRecoveryManager.shared.clearRecovery(for: targetURL)
            }
            return true
        default:
            return false
        }
    }
    
    @MainActor
    static func shouldOpenExternalFileInSeparateWindow(editorController: EditorController?) -> Bool {
        guard let controller = editorController else { return false }
        return controller.currentFileURL != nil || controller.projectRootURL != nil || controller.hasUnsavedChanges
    }

    @MainActor
    private func openExternalFileInNewWindow(_ url: URL) {
        let externalEditorController = EditorController()
        let content = ExternalDocumentWindowRoot(initialFile: url, editorController: externalEditorController)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.identifier = NSUserInterfaceItemIdentifier("external-document-\(UUID().uuidString)")
        window.tabbingMode = .disallowed 
        window.isReleasedWhenClosed = false
        
        let delegate = ExternalWindowDelegate(editorController: externalEditorController)
        window.delegate = delegate
        self.externalDelegates[window] = delegate
        
        window.center()
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @MainActor
    func handleExternalOpen(_ urls: [URL]) {
        var urlsToProcess = urls
        
        // Target the main window specifically if it is completely idle
        if !Self.shouldOpenExternalFileInSeparateWindow(editorController: editorController) {
            if let firstURL = urlsToProcess.first, let mainController = self.editorController {
                NotificationCenter.default.post(name: .openStandaloneFile, object: [
                    "url": firstURL,
                    "target": mainController
                ])
                urlsToProcess.removeFirst()
            }
        }
        
        for url in urlsToProcess {
            openExternalFileInNewWindow(url)
        }

        if let mainWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            mainWindow.makeKeyAndOrderFront(nil)
            mainWindow.orderFrontRegardless()
        }
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return MainActor.assumeIsolated {
            let allControllers = [self.editorController] + self.externalDelegates.values.map { $0.editorController }
            
            for controller in allControllers.compactMap({ $0 }) {
                if !self.showSaveWarningIfNeeded(for: controller) {
                    return .terminateCancel
                }
            }
            
            for controller in allControllers.compactMap({ $0 }) {
                if let projectRoot = controller.projectRootURL {
                    TypstCompiler.cleanUpTempDirectory(in: projectRoot)
                } else if let fileURL = controller.currentFileURL {
                    TypstCompiler.cleanUpTempDirectory(in: fileURL.deletingLastPathComponent())
                }
            }
            return .terminateNow
        }
    }
    
    @MainActor
    func handleWindowClose(for window: NSWindow, editorController: EditorController?, isMain: Bool) -> Bool {
        if showSaveWarningIfNeeded(for: editorController) {
            if let projectRoot = editorController?.projectRootURL {
                TypstCompiler.cleanUpTempDirectory(in: projectRoot)
            } else if let fileURL = editorController?.currentFileURL {
                TypstCompiler.cleanUpTempDirectory(in: fileURL.deletingLastPathComponent())
            }
            if isMain {
                NotificationCenter.default.post(name: .resetToWelcome, object: nil)
            }
            return true
        }
        return false
    }
    
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        return MainActor.assumeIsolated {
            return self.handleWindowClose(for: sender, editorController: self.editorController, isMain: true)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        
        let isLandscape = screen.frame.width > screen.frame.height
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
                    let isMainWindow = window.identifier?.rawValue == "main"
                    if isMainWindow, window.delegate !== appDelegate {
                        window.delegate = appDelegate
                        if let screen = window.screen {
                            let isLandscape = screen.frame.width > screen.frame.height
                            editorController.isVerticalSplit = isLandscape
                        }
                    }
                    if isMainWindow {
                        appDelegate.setupTitleBarDoubleClick(for: window)
                    }
                })
                .onAppear {
                    appDelegate.editorController = editorController
                }
                // MOVED HERE: Attach directly to the view, inside the WindowGroup
                .onOpenURL { url in
                    appDelegate.queueExternalOpen(url)
                }
        }
        .handlesExternalEvents(matching: ["*"])
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