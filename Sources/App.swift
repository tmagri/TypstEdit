import SwiftUI
import AppKit

@MainActor
private struct ExternalDocumentWindowRoot: View {
    @State private var selectedFile: URL?
    /// `nil` starts the window with a new, untitled buffer.
    let initialFile: URL?
    @StateObject private var themeManager = ThemeManager()
    @ObservedObject var editorController: EditorController

    init(initialFile: URL?, editorController: EditorController) {
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
                if initialFile == nil {
                    // Give ContentView's subscriptions a moment to go live.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(name: .fileDidCreate, object: ["target": self.editorController])
                    }
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
            flushPendingMainWindowActions()
        }
    }
    var externalDelegates: [NSWindow: ExternalWindowDelegate] = [:]

    /// Files that arrived from Finder before the main window connected its
    /// EditorController (i.e. the app was launched by opening a file).
    private var pendingExternalOpens: [URL] = []

    /// The SwiftUI `WindowGroup(id: "main")` window. Weak: SwiftUI owns it
    /// and destroys it on close.
    private weak var mainWindow: NSWindow?

    /// Work waiting for the main window to (re)appear after it was closed.
    private var pendingMainWindowActions: [() -> Void] = []

    /// Another TypstEdit copy (different bundle path) that was already
    /// running when this one launched. Files go to it; this copy then quits,
    /// so the user always works in one app instance.
    private var forwardingTarget: NSRunningApplication?

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
            forwardingTarget = Self.otherRunningInstance()
            if let other = forwardingTarget {
                Self.debugLog("another instance is running (pid \(other.processIdentifier)): forwarding and quitting")
            }
            Self.debugLog("willFinishLaunching done")
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let other = forwardingTarget {
                NSApp.windows.forEach { $0.orderOut(nil) }
                other.activate(options: [.activateAllWindows])
                // Late odoc events still get forwarded during this delay.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.windows.forEach { $0.orderOut(nil) }
                    NSApp.terminate(nil)
                }
                return
            }
            // Backstop only — the launch odoc event is delivered BEFORE this
            // (see applicationWillFinishLaunching above).
            installOpenDocumentsHandler()
            flushPendingExternalOpens()
            // macOS does not promptly purge NSTemporaryDirectory() itself, so
            // TypstEdit prunes its own stale OS-temp mirrors (used when a
            // project opts out of in-project temp/vectorcache storage) here.
            AppTempDirectoryManager.pruneStale()
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

    /// Clicking the Dock icon with no visible windows does nothing by default
    /// for a SwiftUI `WindowGroup` app. Reopen the main window and flag the
    /// controller to land on the welcome screen. The `selectedFile` `@State` in
    /// `TypstEditApp` persists the last file URL across close/reopen, and the
    /// close-time `.resetToWelcome` `onReceive` is lost (the view is torn down
    /// first), so `ContentView.onAppear` honors `pendingWelcomeReset` to clear
    /// it and show the welcome screen.
    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            // Minimized windows don't count as visible, so the Dock click on a
            // minimized app would otherwise fall through to the "reopen" path
            // below (which does nothing useful). Restore the minimized window.
            let minimized = NSApp.windows.filter { $0.isMiniaturized }
            if !minimized.isEmpty {
                let target = minimized.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) ?? minimized[0]
                Self.debugLog("Dock click: restoring minimized window")
                NSApp.activate(ignoringOtherApps: true)
                target.deminiaturize(nil)
                target.makeKeyAndOrderFront(nil)
                return false
            }
            guard !hasVisibleWindows else { return false }
            Self.debugLog("Dock click with no visible windows: reopening main window")
            self.editorController?.pendingWelcomeReset = true
            self.withMainWindow {}
            return true
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
        if let target = forwardingTarget {
            Self.forward([url], to: target)
            return
        }
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

    func setupTitleBarDoubleClick() {
        guard titleBarDoubleClickMonitor == nil else { return }

        // Resolves the window per event (not at install time) so the monitor
        // keeps working after the NSWindow is closed and SwiftUI recreates it.
        titleBarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            guard let window = event.window, event.clickCount >= 2 else { return event }
            // Only document windows: SwiftUI assigns "main-AppWindow-N"
            // (older macOS: "main") to WindowGroup(id: "main") windows.
            guard window.identifier?.rawValue.hasPrefix("main") == true else { return event }

            let titleBarHeight: CGFloat = 60
            let p = event.locationInWindow
            let frame = window.frame

            if p.y > frame.height - titleBarHeight && p.x >= 0 && p.x <= frame.width {
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
    
    private func makeSaveWarning(for controller: EditorController, url: URL?) -> NSAlert {
        let fileURL = url ?? controller.currentFileURL
        let fileName = fileURL?.lastPathComponent ?? "Untitled"
        let alert = NSAlert()
        if let fileURL, !FileManager.default.fileExists(atPath: fileURL.path) {
            alert.messageText = "“\(fileName)” was deleted or moved. Do you want to save your changes?"
            alert.informativeText = "Save writes the file again. Don't Save discards your changes."
        } else {
            alert.messageText = "Do you want to save the changes made to “\(fileName)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        return alert
    }

    /// Applies the user's answer. Returns true when the caller may go on
    /// (close, quit, switch file).
    private func resolveSaveWarning(_ response: NSApplication.ModalResponse, controller: EditorController, url: URL?) -> Bool {
        switch response {
        case .alertFirstButtonReturn:
            var payload: [String: Any] = ["target": controller]
            if let url { payload["url"] = url }
            NotificationCenter.default.post(name: .requestSave, object: payload)
            // Saving is synchronous. Edits that are still unsaved mean the
            // write failed or the Save panel was cancelled: stop here, so
            // the edits are neither lost nor asked about in a loop.
            return !controller.hasUnsavedChanges
        case .alertThirdButtonReturn:
            controller.discardUnsavedChanges()
            return true
        default:
            return false
        }
    }

    func showSaveWarningAsync(for controller: EditorController? = nil, url: URL? = nil, completion: @escaping (Bool) -> Void) {
        guard let controllerRef = controller ?? self.editorController, controllerRef.hasUnsavedChanges else {
            completion(true)
            return
        }
        let alert = makeSaveWarning(for: controllerRef, url: url)
        guard let window = self.window(for: controllerRef) ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            completion(resolveSaveWarning(alert.runModal(), controller: controllerRef, url: url))
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(self.resolveSaveWarning(response, controller: controllerRef, url: url))
        }
    }
    
    func showSaveWarningIfNeeded(for controller: EditorController? = nil, url: URL? = nil) -> Bool {
        guard let controllerRef = controller ?? self.editorController, controllerRef.hasUnsavedChanges else {
            return true
        }
        let alert = makeSaveWarning(for: controllerRef, url: url)
        return resolveSaveWarning(alert.runModal(), controller: controllerRef, url: url)
    }
    
    /// True when a window shows nothing worth keeping (no file, no project
    /// or notebooks folder, no unsaved edits), so a newly opened file can
    /// replace it instead of getting its own window.
    @MainActor
    static func isIdle(_ controller: EditorController) -> Bool {
        controller.currentFileURL == nil && controller.projectRootURL == nil && !controller.hasUnsavedChanges
    }

    @MainActor
    static func shouldOpenExternalFileInSeparateWindow(editorController: EditorController?) -> Bool {
        guard let controller = editorController else { return false }
        return !isIdle(controller)
    }

    // MARK: - Document windows

    /// Called by the main window's `WindowAccessor` each time SwiftUI
    /// (re)creates it.
    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.tabbingMode = .disallowed
    }

    private var isMainWindowOpen: Bool {
        guard let mainWindow else { return false }
        return mainWindow.isVisible || mainWindow.isMiniaturized
    }

    private struct DocumentWindow {
        let window: NSWindow?
        let controller: EditorController
        let isMain: Bool
    }

    /// Every open document window: the main window (when open) first, then
    /// the extra document windows in the order they were created.
    private func documentWindows() -> [DocumentWindow] {
        var result: [DocumentWindow] = []
        if isMainWindowOpen, let controller = editorController {
            result.append(DocumentWindow(window: mainWindow, controller: controller, isMain: true))
        }
        let external = externalDelegates
            .filter { $0.key.isVisible || $0.key.isMiniaturized }
            .sorted { $0.key.windowNumber < $1.key.windowNumber }
        for (window, delegate) in external {
            result.append(DocumentWindow(window: window, controller: delegate.editorController, isMain: false))
        }
        return result
    }

    /// The window that shows `controller`, if it is open.
    func window(for controller: EditorController) -> NSWindow? {
        if controller === editorController, isMainWindowOpen { return mainWindow }
        return externalDelegates.first { $0.value.editorController === controller }?.key
    }

    private func bringToFront(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Runs `action` once the main window exists, reopening it (never a
    /// second copy) when it was closed.
    func withMainWindow(_ action: @escaping () -> Void) {
        if isMainWindowOpen {
            bringToFront(mainWindow)
            action()
            return
        }
        let alreadyOpening = !pendingMainWindowActions.isEmpty
        pendingMainWindowActions.append(action)
        guard !alreadyOpening else { return }
        editorController?.pendingWelcomeReset = true
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.shared.open?(id: "main")
    }

    private func flushPendingMainWindowActions() {
        guard !pendingMainWindowActions.isEmpty else { return }
        let actions = pendingMainWindowActions
        pendingMainWindowActions.removeAll()
        // Same settle delay as external opens: ContentView's subscriptions
        // must be live before the actions post to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            actions.forEach { $0() }
        }
    }

    /// Projects and notebooks live in the main window. Runs `action` there,
    /// first asking about unsaved edits in the main window when
    /// `replacingDocument` is set (the action replaces what it shows).
    func performInMainWindow(replacingDocument: Bool = false, _ action: @escaping () -> Void) {
        withMainWindow { [weak self] in
            guard let self, let controller = self.editorController else { return }
            guard replacingDocument, controller.hasUnsavedChanges else {
                action()
                return
            }
            self.showSaveWarningAsync(for: controller) { proceed in
                if proceed { action() }
            }
        }
    }

    @MainActor
    private func openExternalFileInNewWindow(_ url: URL?) {
        let externalEditorController = EditorController()
        let content = ExternalDocumentWindowRoot(initialFile: url, editorController: externalEditorController)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url?.lastPathComponent ?? "Untitled"
        window.representedURL = url
        window.identifier = NSUserInterfaceItemIdentifier("external-document-\(UUID().uuidString)")
        window.tabbingMode = .disallowed 
        window.isReleasedWhenClosed = false
        
        let delegate = ExternalWindowDelegate(editorController: externalEditorController)
        window.delegate = delegate
        self.externalDelegates[window] = delegate
        
        window.contentView = NSHostingView(rootView: content)
        // Cascade from the front document window so new windows never stack
        // exactly on top of each other.
        if let anchor = NSApp.keyWindow ?? documentWindows().last?.window, anchor !== window,
           !anchor.styleMask.contains(.fullScreen) {
            window.setContentSize(anchor.contentLayoutRect.size)
            window.cascadeTopLeft(from: anchor.cascadeTopLeft(from: .zero))
        } else {
            window.center()
        }
        bringToFront(window)
    }

    @MainActor
    func handleExternalOpen(_ urls: [URL]) {
        Self.debugLog("handleExternalOpen: \(urls.map(\.lastPathComponent)) editorConnected=\(editorController != nil) visibleWindows=\(NSApp.windows.filter(\.isVisible).count)")
        openDocuments(urls)
    }

    /// The one entry point for opening files as documents (Finder, File ▸
    /// Open, Open Recent, the welcome screen, drag and drop, the CLI). A
    /// file already open somewhere is brought forward; otherwise it goes to
    /// an idle window, or a new window when every window is in use.
    func openDocuments(_ urls: [URL]) {
        // Cold-launch case: queue until the editor controller is connected,
        // then flush from editorController's didSet.
        guard let mainController = editorController else {
            pendingExternalOpens.append(contentsOf: urls)
            Self.debugLog("openDocuments: queued for cold launch (\(pendingExternalOpens.count) pending)")
            return
        }

        let windows = documentWindows()
        var claimed = Set<Int>()
        var mainReopenClaimed = false

        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                performInMainWindow(replacingDocument: true) {
                    NotificationCenter.default.post(name: .openProjectFolder, object: url)
                }
                continue
            }

            let slots = windows.map {
                DocumentWindowRouter.Slot(
                    fileURL: $0.controller.currentFileURL,
                    isIdle: Self.isIdle($0.controller),
                    isKey: $0.window?.isKeyWindow == true,
                    isMain: $0.isMain
                )
            }
            switch DocumentWindowRouter.destination(for: url, in: slots, claimed: claimed) {
            case .focus(let index):
                Self.debugLog("openDocuments: '\(url.lastPathComponent)' is already open, focusing its window")
                bringToFront(windows[index].window)
            case .load(let index):
                claimed.insert(index)
                Self.debugLog("openDocuments: '\(url.lastPathComponent)' -> idle \(windows[index].isMain ? "main" : "document") window")
                NotificationCenter.default.post(name: .openStandaloneFile, object: [
                    "url": url,
                    "target": windows[index].controller
                ])
                bringToFront(windows[index].window)
            case .newWindow:
                if !isMainWindowOpen, !mainReopenClaimed, Self.isIdle(mainController) {
                    // The main window was closed: bring it back for this file
                    // rather than leaving it closed and adding another window.
                    mainReopenClaimed = true
                    withMainWindow {
                        NotificationCenter.default.post(name: .openStandaloneFile, object: [
                            "url": url,
                            "target": mainController
                        ])
                    }
                } else {
                    openExternalFileInNewWindow(url)
                }
            }
        }
    }

    /// The user deleted `url` (a file or a folder) inside the app. Every
    /// window showing it, or a file inside it, drops its unsaved edits: they
    /// were deleted on purpose, and a save prompt would only write the
    /// deleted file back.
    func discardEdits(forDeletedItemAt url: URL) {
        let deleted = DocumentWindowRouter.canonicalPath(url)
        let controllers = [editorController].compactMap { $0 } + externalDelegates.values.map(\.editorController)
        for controller in controllers {
            guard let open = controller.currentFileURL else { continue }
            let path = DocumentWindowRouter.canonicalPath(open)
            guard path == deleted || path.hasPrefix(deleted + "/") else { continue }
            controller.discardUnsavedChanges()
            controller.isFileDeletedOnDisk = true
        }
    }

    /// File ▸ New File: an untitled buffer in an idle window, else in a new
    /// window — never on top of another document.
    func newDocument() {
        let windows = documentWindows()
        let target = windows.firstIndex { $0.window?.isKeyWindow == true && Self.isIdle($0.controller) }
            ?? windows.firstIndex { Self.isIdle($0.controller) }
        if let target {
            NotificationCenter.default.post(name: .fileDidCreate, object: ["target": windows[target].controller])
            bringToFront(windows[target].window)
        } else if !isMainWindowOpen, let mainController = editorController, Self.isIdle(mainController) {
            withMainWindow {
                NotificationCenter.default.post(name: .fileDidCreate, object: ["target": mainController])
            }
        } else {
            openExternalFileInNewWindow(nil)
        }
    }

    // MARK: - Single instance

    /// Another running TypstEdit with the same bundle identifier but a
    /// different bundle location (e.g. the copy in /Applications and a
    /// development build). LaunchServices would otherwise run both.
    nonisolated static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownPath = Bundle.main.bundleURL.standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            $0.processIdentifier != ownPID
                && !$0.isTerminated
                // Headless `typstedit compile`/`mcp` runs share the bundle ID.
                && $0.activationPolicy == .regular
                // Same path means the user asked for a new instance (`open -n`);
                // forwarding there could loop back to this process.
                && $0.bundleURL?.standardizedFileURL.path != ownPath
        }
    }

    private static func forward(_ urls: [URL], to app: NSRunningApplication) {
        guard let bundleURL = app.bundleURL, !urls.isEmpty else { return }
        debugLog("forwarding \(urls.map(\.lastPathComponent)) to pid \(app.processIdentifier)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: configuration, completionHandler: nil)
    }

    // MARK: - Closing and quitting

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return MainActor.assumeIsolated {
            let allControllers = [self.editorController] + self.externalDelegates.values.map { $0.editorController }
            
            for controller in allControllers.compactMap({ $0 }) where controller.hasUnsavedChanges {
                // Show which window the question is about.
                self.bringToFront(self.window(for: controller))
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
            // MCP servers are local subprocesses spawned on demand — never
            // leave one running after the app itself has quit.
            MCPManager.shared.stopAll()
            return .terminateNow
        }
    }
    
    @MainActor
    func handleWindowClose(for window: NSWindow, editorController: EditorController?, isMain: Bool) -> Bool {
        guard showSaveWarningIfNeeded(for: editorController) else { return false }
        if let projectRoot = editorController?.projectRootURL {
            TypstCompiler.cleanUpTempDirectory(in: projectRoot)
        } else if let fileURL = editorController?.currentFileURL {
            TypstCompiler.cleanUpTempDirectory(in: fileURL.deletingLastPathComponent())
        }
        // Forget the document now. The main window's controller outlives
        // its window, and a stale file (possibly deleted, possibly marked
        // dirty) would otherwise trigger save prompts on quit or reopen.
        editorController?.closeDocument()
        if isMain {
            editorController?.projectRootURL = nil
            editorController?.pendingWelcomeReset = true
            NotificationCenter.default.post(name: .resetToWelcome, object: nil)
        }
        return true
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

/// Holds the SwiftUI `openWindow` action so AppKit-level entry points (a
/// Dock-icon click with no visible windows) can reopen the main window. The
/// action is scene-level, so it stays valid even after the window that
/// captured it is closed.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: OpenWindowAction?
    private init() {}
}

/// Invisible view that captures the main window's `openWindow` action and
/// hands it to `WindowOpener.shared`.
private struct WindowOpenerInstaller: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowOpener.shared.open = openWindow }
    }
}

// Entry point is `TypstEditMain` (Integration/TypstEditCLI.swift), which runs
// headless CLI/MCP subcommands and otherwise starts this app.
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
                    // Current macOS assigns "main-AppWindow-N" to
                    // WindowGroup(id: "main") windows, older ones "main".
                    let isMainWindow = window.identifier?.rawValue.hasPrefix("main") == true
                    if isMainWindow, window.delegate !== appDelegate {
                        window.delegate = appDelegate
                        if let screen = window.screen {
                            let isLandscape = screen.frame.width > screen.frame.height
                            editorController.isVerticalSplit = isLandscape
                        }
                    }
                    if isMainWindow {
                        appDelegate.registerMainWindow(window)
                        appDelegate.setupTitleBarDoubleClick()
                    }
                })
                .background(WindowOpenerInstaller())
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
