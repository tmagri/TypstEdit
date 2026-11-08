import SwiftUI
import AppKit

/// What a new document window starts with.
enum DocumentWindowContent {
    /// A single file, without a project.
    case file(URL)
    /// A new, untitled buffer.
    case untitled
    /// The welcome screen (File ▸ New Window).
    case welcome
    /// Work that needs the window's `ContentView` to be listening, such as
    /// opening a project folder in it.
    case action((EditorController) -> Void)
}

@MainActor
private struct ExternalDocumentWindowRoot: View {
    @State private var selectedFile: URL?
    let content: DocumentWindowContent
    @StateObject private var themeManager = ThemeManager()
    @ObservedObject var editorController: EditorController

    init(content: DocumentWindowContent, editorController: EditorController) {
        self.content = content
        // Inject the file directly into state. 
        // This avoids broadcasting a global notification that overwrites other windows.
        if case .file(let url) = content {
            self._selectedFile = State(initialValue: url)
        }
        self.editorController = editorController
    }

    var body: some View {
        ContentView(selectedFile: $selectedFile, editorController: editorController)
            .environmentObject(themeManager)
            .background(VisualEffectView().ignoresSafeArea())
            .onAppear {
                // Every window starts without a project. A project is only
                // ever opened through `AppDelegate.openProject`, which keeps
                // each folder in one window.
                DispatchQueue.main.async {
                    self.editorController.isSidebarVisible = false
                    self.editorController.projectRootURL = nil
                }
                // Give ContentView's subscriptions a moment to go live.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    switch content {
                    case .file, .welcome:
                        break
                    case .untitled:
                        NotificationCenter.default.post(name: .fileDidCreate, object: ["target": self.editorController])
                    case .action(let action):
                        action(self.editorController)
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
            // Child processes never outlive the app: a watchdog covers Force
            // Quit and crashes, and leftovers from earlier runs are stopped.
            ChildProcessGuard.startWatchdog()
            ChildProcessGuard.sweepOrphanedPreviewCompilers(managedBinaryPrefixes: Self.managedTypstLocations)
            Self.debugLog("didFinishLaunching done")
        }
    }

    /// Where TypstEdit's own typst binaries live: the downloaded toolchain
    /// in Application Support, and this app bundle.
    private static var managedTypstLocations: [String] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TypstEdit", isDirectory: true).path
        return [appSupport, Bundle.main.bundleURL.path].compactMap { $0 }
    }

    /// Every way of quitting ends here (⌘Q, the menu, logout, restart): stop
    /// every process the app started, children included.
    nonisolated func applicationWillTerminate(_ notification: Notification) {
        ChildProcessGuard.terminateDescendants()
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
            // Handled here. Returning true would make AppKit reopen as well,
            // and SwiftUI would add a second main window that shares this
            // controller (both windows then react to everything it is sent).
            return false
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

    /// True between the user clicking minimize and the miniaturize
    /// animation finishing. During the animation the window is neither
    /// visible nor miniaturized yet, which every window-state check here
    /// would read as "closed" — opening a second main window.
    private var isMainMiniaturizing = false

    /// Called by the main window's `WindowAccessor` each time SwiftUI
    /// (re)creates it.
    ///
    /// The main controller is shown by one window only. A second window of
    /// the group (from any path) is closed again, and the existing one comes
    /// forward: two views on one controller would both handle every
    /// notification sent to it.
    /// Re-created main windows that `registerMainWindow` turned away. Weak,
    /// so a window that SwiftUI finally frees drops out by itself.
    private let rejectedMainWindows = NSHashTable<NSWindow>.weakObjects()

    /// True for a duplicate main window. Its view must not compile, save or
    /// otherwise act for the shared controller.
    func isRejectedDuplicate(_ window: NSWindow) -> Bool {
        rejectedMainWindows.contains(window)
    }

    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        if isMainWindowOpen, let existing = mainWindow {
            Self.debugLog("registerMainWindow: duplicate main window closed")
            // The duplicate shares the main window's EditorController, so its
            // ContentView would compile the same document into the same
            // shadow file: a second `typst watch` for every re-created window.
            // Mark it so that view stays inert, before and after it appears.
            rejectedMainWindows.add(window)
            NotificationCenter.default.post(name: .duplicateMainWindowRejected, object: window)
            window.orderOut(nil)
            DispatchQueue.main.async { window.close() }
            // Only bring the existing window forward when it is on screen,
            // not on its way into the Dock, and the app is already active.
            // A minimized window sits there on purpose, and SwiftUI
            // re-creates the group's window the moment the minimize starts:
            // restoring the original here cancelled the animation and made
            // it pop back open. When the app is in the background, the user
            // is working in another app — closing the re-created copy is
            // enough, and activating here would steal their focus (the chat
            // completing a reply re-renders the document, which re-creates
            // this window; that must never bring TypstEdit forward).
            if existing.isVisible, !isMainMiniaturizing, NSApp.isActive {
                bringToFront(existing)
            } else {
                Self.debugLog("registerMainWindow: duplicate closed without activating")
            }
            return
        }
        mainWindow = window
        window.tabbingMode = .disallowed
    }

    /// While the app is hidden (⌘H) no window is visible, yet the main
    /// window is still open: treating it as closed would open a second one.
    /// A window mid-minimize reads the same way, so the miniaturizing flag
    /// counts as open too.
    private var isMainWindowOpen: Bool {
        guard let mainWindow else { return false }
        if mainWindow.isVisible || mainWindow.isMiniaturized || isMainMiniaturizing { return true }
        return NSApp.isHidden && NSApp.windows.contains(mainWindow)
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
        if NSApp.isHidden { NSApp.unhide(nil) }
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

    @MainActor
    private func openExternalFileInNewWindow(_ url: URL?) {
        openDocumentWindow(url.map { .file($0) } ?? .untitled)
    }

    @MainActor
    private func openDocumentWindow(_ windowContent: DocumentWindowContent) {
        let externalEditorController = EditorController()
        let content = ExternalDocumentWindowRoot(content: windowContent, editorController: externalEditorController)
        let url: URL? = if case .file(let fileURL) = windowContent { fileURL } else { nil }

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
                openProject(at: url)
                continue
            }
            // A note goes to the Notes window, unless some window already
            // shows that exact file (the router below focuses it).
            if Self.isNote(url),
               !windows.contains(where: { $0.controller.currentFileURL.map { DocumentWindowRouter.isSameFile($0, url) } ?? false }) {
                openNotebooks(showing: url)
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
                } else if urls.count == 1 {
                    // One file: ask (or apply the setting). A batch from
                    // Finder opens one window per file, as before.
                    chooseWindow(forOpening: url.lastPathComponent, in: windows) { [weak self] choice in
                        switch choice {
                        case .newWindow:
                            self?.openExternalFileInNewWindow(url)
                        case .replace(let target):
                            // The load itself asks about unsaved edits.
                            self?.bringToFront(target.window)
                            NotificationCenter.default.post(name: .openStandaloneFile, object: [
                                "url": url,
                                "target": target.controller,
                            ])
                        case .cancel:
                            break
                        }
                    }
                } else {
                    openExternalFileInNewWindow(url)
                }
            }
        }
    }

    // MARK: - Projects

    /// The one entry point for opening a project folder (File ▸ Open Folder,
    /// Open Recent, Finder, the sidebar, the welcome screen, imports). A
    /// folder is open in at most one window: when it already is, that window
    /// comes forward (and shows `file`, when given). Otherwise the folder
    /// goes to `preferred` (an import replacing its own window), an idle
    /// window, or a new window.
    ///
    /// `notebookAsProject` keeps a notebook folder (inside the Notes folder)
    /// as a project of its own even when `file` is one of its pages: Open
    /// Recent passes it for a page last used in a notebook opened with "Open
    /// as Project" (for example, a notebook under Git).
    func openProject(
        at root: URL,
        file: URL? = nil,
        preferring preferred: EditorController? = nil,
        forceNewWindow: Bool = false,
        notebookAsProject: Bool = false
    ) {
        // The Notes folder, and notes opened through a notebook folder, belong
        // to the Notes window. "Open as Project" on a notebook passes no file,
        // and Open Recent passes `notebookAsProject`, so both still open that
        // notebook as a project of its own.
        let notesRoot = NotebookManager.shared.rootDirectory
        if ProjectWindowRouter.isSameFolder(root, notesRoot)
            || !notebookAsProject && (file.map(Self.isNote) ?? false) && ProjectWindowRouter.contains(notesRoot, root) {
            openNotebooks(showing: file)
            return
        }
        // A notebook opened as a project must not be taken over by the Notes
        // window just because the Notes folder contains the file.
        let ignoredOwner = ProjectWindowRouter.contains(notesRoot, root) ? notesRoot : nil
        routeProject(root: root, file: file, preferring: preferred, forceNewWindow: forceNewWindow, ignoringOwner: ignoredOwner) { controller in
            NotificationCenter.default.post(name: .openProjectFolder, object: [
                "target": controller,
                "url": root,
                "file": file as Any,
            ])
        }
    }

    /// Reopens an Open Recent entry (the welcome screen or File ▸ Open
    /// Recent) the way it was last used: in its project, in the Notes
    /// window, or on its own with no project (no index, no vectorcaches/).
    func openRecent(_ entry: RecentFilesManager.RecentFile, preferring preferred: EditorController? = nil) {
        switch entry.openTarget(notebooksRoot: NotebookManager.shared.rootDirectory) {
        case .project(let root, let file):
            // A stored root inside the Notes folder is a notebook that was
            // opened as a project: keep it one.
            openProject(at: root, file: file, preferring: preferred, notebookAsProject: true)
        case .notebook(let note):
            openNotebooks(showing: note)
        case .standalone(let file):
            openDocuments([file])
        case .missing:
            RecentFilesManager.shared.remove(url: entry.url)
            let alert = NSAlert()
            alert.messageText = "“\(entry.name)” can’t be opened"
            alert.informativeText = "The folder no longer exists. It was removed from Open Recent."
            alert.runModal()
        }
    }

    /// File ▸ Open Notes: the notebooks folder is routed like a project, so
    /// it too is open in one window only. With `note`, that window shows it.
    ///
    /// Notes never open in a window of their own: two windows on the same
    /// notebook would share one chat history folder and overwrite each
    /// other's session list.
    func openNotebooks(showing note: URL? = nil) {
        routeProject(root: NotebookManager.shared.rootDirectory, file: note, preferring: nil, forceNewWindow: false) { controller in
            NotificationCenter.default.post(name: .openNotebooks, object: [
                "target": controller,
                "file": note as Any,
            ])
        }
    }

    /// True for a file inside the Notes folder.
    static func isNote(_ url: URL) -> Bool {
        ProjectWindowRouter.contains(NotebookManager.shared.rootDirectory, url)
    }

    /// File ▸ New Window: an empty window on the welcome screen.
    func newWindow() {
        if !isMainWindowOpen, let mainController = editorController, Self.isIdle(mainController) {
            withMainWindow {}
        } else {
            openDocumentWindow(.welcome)
        }
    }

    /// True when some open window shows `root` as its project.
    func isProjectOpen(_ root: URL) -> Bool {
        documentWindows().contains { $0.controller.projectRootURL.map { ProjectWindowRouter.isSameFolder($0, root) } ?? false }
    }

    private func routeProject(
        root: URL,
        file: URL?,
        preferring preferred: EditorController?,
        forceNewWindow: Bool,
        ignoringOwner ignoredOwner: URL? = nil,
        open: @escaping (EditorController) -> Void
    ) {
        guard let mainController = editorController else {
            // Cold launch: the main window is not connected yet.
            pendingExternalOpens.append(file ?? root)
            return
        }
        let windows = documentWindows()
        let slots = windows.map {
            ProjectWindowRouter.Slot(
                projectRoot: $0.controller.projectRootURL,
                isIdle: Self.isIdle($0.controller),
                isKey: $0.window?.isKeyWindow == true,
                isMain: $0.isMain,
                isPreferred: $0.controller === preferred
            )
        }
        switch ProjectWindowRouter.destination(for: root, file: file, in: slots, forceNewWindow: forceNewWindow, ignoringOwner: ignoredOwner) {
        case .focus(let index):
            let target = windows[index]
            Self.debugLog("openProject: '\(root.lastPathComponent)' is already open, focusing its window")
            bringToFront(target.window)
            guard let file, target.controller.currentFileURL.map({ !DocumentWindowRouter.isSameFile($0, file) }) ?? true else { return }
            showSaveWarningAsync(for: target.controller) { proceed in
                guard proceed else { return }
                NotificationCenter.default.post(name: .openProjectAndFile, object: [
                    "target": target.controller,
                    "url": file,
                ])
            }
        case .load(let index):
            let target = windows[index]
            bringToFront(target.window)
            showSaveWarningAsync(for: target.controller) { proceed in
                if proceed { open(target.controller) }
            }
        case .newWindow:
            let openInNewWindow = { [weak self] in
                guard let self else { return }
                if !self.isMainWindowOpen, Self.isIdle(mainController) {
                    // The main window was closed: bring it back instead.
                    self.withMainWindow { open(mainController) }
                } else {
                    self.openDocumentWindow(.action(open))
                }
            }
            guard !forceNewWindow else {
                openInNewWindow()
                return
            }
            chooseWindow(forOpening: root.lastPathComponent, in: windows) { [weak self] choice in
                switch choice {
                case .newWindow:
                    openInNewWindow()
                case .replace(let target):
                    self?.replaceContent(of: target) { open(target.controller) }
                case .cancel:
                    break
                }
            }
        }
    }

    // MARK: - New Window or Replace

    private enum WindowChoice {
        case newWindow
        case replace(DocumentWindow)
        case cancel
    }

    /// Every window is in use and something needs one. Applies the setting
    /// (Settings ▸ General ▸ Files & Backups), or asks: open a new window,
    /// or replace what the front window shows. Nothing to replace means a
    /// new window, without a question.
    private func chooseWindow(forOpening name: String, in windows: [DocumentWindow], completion: @escaping (WindowChoice) -> Void) {
        guard let front = frontmostDocumentWindow(in: windows) else {
            completion(.newWindow)
            return
        }
        switch GeneralSettingsManager.shared.windowOpenBehavior {
        case .newWindow:
            completion(.newWindow)
            return
        case .replace:
            completion(.replace(front))
            return
        case .ask:
            break
        }

        let current = Self.describe(front.controller)
        let alert = NSAlert()
        alert.messageText = "Open “\(name)” in a new window?"
        var info = "“\(current)” is open in this window. You can open “\(name)” in a new window next to it, or close “\(current)” and open “\(name)” in this window."
        if front.controller.projectContext.chat.hasRunningWork {
            info += "\n\nAn AI chat is still working in this window. If you replace the window, the chat stops."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "New Window")
        alert.addButton(withTitle: "This Window")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always do this (change it in Settings ▸ General)"

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let remember = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn:
                if remember { GeneralSettingsManager.shared.windowOpenBehavior = .newWindow }
                completion(.newWindow)
            case .alertSecondButtonReturn:
                if remember { GeneralSettingsManager.shared.windowOpenBehavior = .replace }
                completion(.replace(front))
            default:
                completion(.cancel)
            }
        }
        if let window = front.window {
            bringToFront(window)
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// The window the user is working in: the key document window, else
    /// the frontmost one.
    private func frontmostDocumentWindow(in windows: [DocumentWindow]) -> DocumentWindow? {
        if let key = windows.first(where: { $0.window?.isKeyWindow == true }) { return key }
        for window in NSApp.orderedWindows {
            if let match = windows.first(where: { $0.window === window }) { return match }
        }
        return windows.first
    }

    /// What a window shows, for the question: its project, else its file.
    private static func describe(_ controller: EditorController) -> String {
        if let root = controller.projectRootURL {
            return ProjectWindowRouter.isSameFolder(root, NotebookManager.shared.rootDirectory) ? "Notes" : root.lastPathComponent
        }
        return controller.currentFileURL?.lastPathComponent ?? "Untitled"
    }

    /// Closes what `target` shows (asking to save first) and runs `open`
    /// in it. Its old project's chats, MCP servers and index close with it.
    private func replaceContent(of target: DocumentWindow, then open: @escaping () -> Void) {
        bringToFront(target.window)
        showSaveWarningAsync(for: target.controller) { [weak self] proceed in
            guard proceed else { return }
            self?.cleanUpTemp(for: target.controller)
            open()
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
            for controller in allControllers.compactMap({ $0 }) {
                controller.projectContext.close()
            }
            return .terminateNow
        }
    }
    
    @MainActor
    func handleWindowClose(for window: NSWindow, editorController: EditorController?, isMain: Bool) -> Bool {
        guard showSaveWarningIfNeeded(for: editorController) else { return false }
        if let editorController {
            cleanUpTemp(for: editorController)
        }
        // Forget the document now. The main window's controller outlives
        // its window, and a stale file (possibly deleted, possibly marked
        // dirty) would otherwise trigger save prompts on quit or reopen.
        editorController?.closeDocument()
        // The window's project closes with it: its chats stop, its MCP
        // servers quit, and its index is closed. Other windows are untouched.
        if let editorController {
            editorController.projectContext.close()
            ActiveProjectContext.shared.deactivate(editorController)
            // The preview's `typst watch` belongs to the window too. Stopping
            // it here does not depend on the window (and its compiler) being
            // deallocated promptly.
            NotificationCenter.default.post(name: .stopPreviewCompiler, object: ["target": editorController])
        }
        if isMain, let editorController {
            editorController.projectRootURL = nil
            editorController.pendingWelcomeReset = true
            NotificationCenter.default.post(name: .resetToWelcome, object: ["target": editorController])
        }
        return true
    }
    
    /// Removes a closing window's compiler scratch files. The whole temp
    /// folder goes only when no other open window works in it; otherwise
    /// only this window's own shadow files are removed.
    private func cleanUpTemp(for controller: EditorController) {
        let folders = Self.scratchFolders(of: controller)
        guard !folders.isEmpty else { return }
        let others = documentWindows().map(\.controller).filter { $0 !== controller }
        let otherFolders = Set(others.flatMap { Self.scratchFolders(of: $0) }.map(ProjectWindowRouter.canonicalFolder))
        for folder in folders {
            let tempDir = SafeDirectoryManager.safeTempDirectory(in: folder)
            if otherFolders.contains(ProjectWindowRouter.canonicalFolder(folder)) {
                TypstCompiler.cleanUpScratchFiles(in: tempDir, namespace: controller.projectContext.instanceID)
            } else {
                TypstCompiler.cleanUpTempDirectory(in: folder)
            }
        }
    }

    /// The folders whose `temp/` this window's compiler writes to: the
    /// project root, and the open file's own folder.
    private static func scratchFolders(of controller: EditorController) -> [URL] {
        var folders: [URL] = []
        if let root = controller.projectRootURL { folders.append(root) }
        if let fileFolder = controller.currentFileURL?.deletingLastPathComponent(),
           !folders.contains(where: { ProjectWindowRouter.isSameFolder($0, fileFolder) }) {
            folders.append(fileFolder)
        }
        return folders
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

    /// Marks the miniaturize animation window (see `isMainMiniaturizing`).
    /// `isVisible` drops before `isMiniaturized` rises, so state checks made
    /// in between — a reopen event, a SwiftUI window re-registration — would
    /// otherwise see "no window" and open a duplicate.
    func windowWillMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        isMainMiniaturizing = true
        // Don't let a stale flag linger if the animation never completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isMainMiniaturizing = false
        }
    }
}

extension Notification.Name {
    static let requestSave = Notification.Name("requestSave")
    static let resetToWelcome = Notification.Name("resetToWelcome") 
    /// A document window is closing: its preview compiler must stop.
    /// `object` is `["target": EditorController]`.
    static let stopPreviewCompiler = Notification.Name("stopPreviewCompiler")
    /// `object` is the duplicate main `NSWindow` that was just turned away.
    static let duplicateMainWindowRejected = Notification.Name("duplicateMainWindowRejected")
    /// A duplicate window let go of the shared controller: the real window
    /// re-attaches its compiler. `object` is `["target": EditorController]`.
    static let reclaimPreviewCompiler = Notification.Name("reclaimPreviewCompiler")
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
    /// The menu bar follows the frontmost document window.
    @ObservedObject private var activeWindow = ActiveProjectContext.shared
    
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
            AppMenuCommands(
                themeManager: themeManager,
                selectedFile: $selectedFile,
                editorController: activeWindow.controller ?? editorController
            )
        }
        
        Settings {
            SettingsView()
                .environmentObject(themeManager)
        }
    }
}
