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

    /// Debug trace to a file — print()/NSLog are unreliable to observe for a
    /// LS-launched GUI app on this OS (stdout discarded, unified log filtered).
    nonisolated static func debugLog(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/typstedit-debug.log")
        let ms = Int(Date().timeIntervalSince1970 * 1000) % 100_000
        let line = "[.\(ms)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    var editorController: EditorController? {
        didSet {
            // Files opened from Finder before the editor was connected
            // (cold launch) are handled now.
            flushPendingExternalOpens()
        }
    }
    var externalDelegates: [NSWindow: ExternalWindowDelegate] = [:]

    /// Files that arrived from Finder before the main window connected its
    /// EditorController (i.e. the app was launched by opening a file).
    private var pendingExternalOpens: [URL] = []

    private var titleBarDoubleClickMonitor: Any?
    
    override init() {
        super.init()
        AppDelegate.shared = self
        print("[DEBUG] AppDelegate: init")
    }

    // MARK: - Opening files from Finder

    private func installOpenDocumentsHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        Self.debugLog("AE handler installed")
    }

    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Must beat the open event itself: on modern macOS LaunchServices
            // delivers kAEOpenDocuments (as application(_:open:)) BEFORE
            // applicationDidFinishLaunching — and SwiftUI's delegate shim
            // spawns a new WindowGroup window for every open event it sees.
            // Registering here means OUR handler consumes the raw event first,
            // so the shim never sees it and no duplicate window is spawned.
            installOpenDocumentsHandler()
            Self.debugLog("willFinishLaunching done")
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Backstop only — the launch odoc event is delivered BEFORE this
            // (see applicationWillFinishLaunching above).
            installOpenDocumentsHandler()
            flushPendingExternalOpens()
            Self.debugLog("didFinishLaunching done")
        }
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Safety net: re-claim the handler in case anything re-registered
            // over ours after launch (e.g. SwiftUI scene setup), so warm opens
            // while the app is running are always intercepted.
            installOpenDocumentsHandler()
            Self.debugLog("didBecomeActive done")
        }
    }

    /// Safety net: if the raw handler above is ever bypassed, AppKit delivers the
    /// file open here instead. Only one of the two paths receives a given event.
    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        Self.debugLog("delegate application(_:open:) fired: \(urls.map(\.lastPathComponent))")
        MainActor.assumeIsolated {
            urls.forEach { self.queueExternalOpen($0) }
        }
    }

    private func flushPendingExternalOpens() {
        guard editorController != nil, !pendingExternalOpens.isEmpty else { return }
        let urls = pendingExternalOpens
        pendingExternalOpens.removeAll()
        Self.debugLog("flushing \(urls.count) pending external open(s) (cold launch)")
        // Route through the debounce: guarantees ContentView's
        // .onReceive(.openStandaloneFile) subscription is live before we post
        // (this runs from editorController's didSet, i.e. inside onAppear).
        urls.forEach { queueExternalOpen($0) }
    }

    nonisolated static func normalizedFileURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 1. Valid, percent-encoded file URL string.
        if let url = URL(string: trimmed), url.isFileURL { return url }
        // 2. "file://" string URL(string:) rejects (e.g. unescaped space):
        //    strip scheme/host and treat the rest as a plain path.
        if trimmed.hasPrefix("file://") {
            var path = String(trimmed.dropFirst("file://".count))
            if path.hasPrefix("localhost/") { path = String(path.dropFirst("localhost/".count)) }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
        }
        // 3. Bare POSIX path.
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        // 4. HFS-style path ("Macintosh HD:private:tmp:x:y.typ" — `open` CLI and
        //    some senders deliver these instead of file URLs). Map separators;
        //    the boot volume prefix becomes "/", other volumes /Volumes/<name>.
        if trimmed.contains(":") {
            let path = trimmed.replacingOccurrences(of: ":", with: "/")
            let bootVolume = (try? URL(fileURLWithPath: "/")
                .resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
            if !bootVolume.isEmpty, path.hasPrefix("\(bootVolume)/") {
                return URL(fileURLWithPath: "/" + path.dropFirst(bootVolume.count + 1))
            }
            if path.hasPrefix("/Volumes/") || path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            return URL(fileURLWithPath: "/Volumes/" + path)
        }
        // 5. Anything else (remote URLs, junk): dropped rather than turned into bogus URLs.
        return nil
    }

    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        Self.debugLog("AE handleAppleEvent received")
        guard let listDescriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }

        var urls: [URL] = []
        // Clamp: `1...0` would crash (ClosedRange requires lowerBound <= upperBound).
        let count = max(listDescriptor.numberOfItems, 1)
        for i in 1...count {
            guard let item = listDescriptor.atIndex(i) else { continue }
            // Senders differ: Finder sends aliases/file URLs, `open` CLI can
            // deliver HFS-style text. Try the typed accessors first, then
            // string parsing.
            var url = item.fileURLValue
            if url == nil, let fileDescriptor = item.coerce(toDescriptorType: typeFileURL) {
                url = fileDescriptor.stringValue.flatMap(Self.normalizedFileURL(from:))
            }
            if url == nil {
                url = item.stringValue.flatMap(Self.normalizedFileURL(from:))
            }
            guard let resolvedURL = url else {
                Self.debugLog("odoc: dropped unparseable descriptor at index \(i)")
                continue
            }
            urls.append(resolvedURL)
        }
        guard !urls.isEmpty else { return }
        Self.debugLog("odoc parsed urls: \(urls.map(\.lastPathComponent))")

        Task { @MainActor in
            urls.forEach { self.queueExternalOpen($0) }
        }
    }

    // Replace the openDebounceTimer variable with a Task
    // (array, not Set: preserves the sender's file order across a batch)
    private var pendingURLs: [URL] = []
    private var debounceTask: Task<Void, Never>?

    @MainActor
    func queueExternalOpen(_ url: URL) {
        Self.debugLog("queueExternalOpen: \(url.lastPathComponent)")
        if !pendingURLs.contains(url) {
            pendingURLs.append(url)
        }
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
        let busy = Self.shouldOpenExternalFileInSeparateWindow(editorController: editorController)
        Self.debugLog("handleExternalOpen: \(urls.map(\.lastPathComponent)) editorConnected=\(editorController != nil) busy=\(busy) visibleWindows=\(NSApp.windows.filter(\.isVisible).count)")
        // Cold-launch case: queue until the editor controller is connected,
        // then flush from editorController's didSet.
        guard editorController != nil else {
            pendingExternalOpens.append(contentsOf: urls)
            Self.debugLog("handleExternalOpen: queued for cold launch (\(pendingExternalOpens.count) pending)")
            return
        }

        var urlsToProcess = urls
        var loadedInMainWindow = false

        // Target the main window specifically if it is completely idle
        if !busy {
            if let firstURL = urlsToProcess.first, let mainController = self.editorController {
                NotificationCenter.default.post(name: .openStandaloneFile, object: [
                    "url": firstURL,
                    "target": mainController
                ])
                urlsToProcess.removeFirst()
                loadedInMainWindow = true
                Self.debugLog("handleExternalOpen: routed '\(firstURL.lastPathComponent)' to idle main window")
            }
        }

        for url in urlsToProcess {
            openExternalFileInNewWindow(url)
        }

        // Only re-front the main window when a file was routed to it; otherwise
        // the freshly opened external window stays in front, like standard apps.
        if loadedInMainWindow,
           let mainWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
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