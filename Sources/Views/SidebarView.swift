import SwiftUI
import UniformTypeIdentifiers

/// Explorer-style abbreviation shared by the sidebar rows: keep the head of
/// the name but always leave the file extension visible ("IT Team Meet….note")
/// so long names stay scannable in the narrow sidebar. The full name stays
/// available through the hover tooltip.
func explorerAbbreviatedName(_ name: String, pathExtension: String = "") -> String {
    guard name.count > 24 else { return name }
    return "\(name.prefix(12))…\(pathExtension.isEmpty ? "" : ".\(pathExtension)")"
}

@MainActor
class FileSystemModel: ObservableObject {
    @Published var rootNodes: [FileNode] = []
    @Published var currentFolder: URL? {
        didSet {
            guard let folder = currentFolder else {
                guard oldValue != nil else { return }
                rootNodes = []
                expandedFolders = []
                stopWatching()
                return
            }
            guard ProjectTreeLoader.canonical(folder) != oldValue.map(ProjectTreeLoader.canonical) else { return }
            // A new project means a new watch and a list that starts from the
            // top level only (the old tree belongs to another folder).
            rootNodes = []
            expandedFolders = []
            restartWatching()
            // The Notebooks view reuses `currentFolder` to mark its own root,
            // but that folder is not a project: no project tree, no index.
            guard !isNotebookFolder else { return }
            loadFiles()
        }
    }
    @Published var expandedFolders: Set<URL> = []
    @Published var isNewUnsavedFile: Bool = false
    /// Bumped when a reload actually changes the tree, and when a folder is
    /// expanded or collapsed. The List renders a flat array of rows, so it
    /// diffs by row identity and this is what makes dependent views (source
    /// control, for one) re-read state at the same moment.
    @Published var refreshGeneration: Int = 0
    /// The editor of the window this model belongs to.
    weak var documentController: EditorController?

    /// Whether the Projects list is on screen. Drives the live watch: turning
    /// it off tears the watcher down so a hidden sidebar has no cost. Change it
    /// through `setWatchActive(_:)`, never directly.
    private(set) var watchEnabled = false

    /// The rows the List renders: the tree flattened to the expanded folders.
    /// Derived state only — recomputed on read from two `@Published`s, so it
    /// adds no extra object changes of its own.
    var visibleRows: [VisibleFileRow] {
        ProjectTreeLoader.visibleRows(in: rootNodes, expanded: expandedFolders)
    }

    /// True while the sidebar is showing Notebooks. `currentFolder` doubles as
    /// "which root is open", and the notebook root is not a project.
    private var isNotebookFolder: Bool {
        guard let currentFolder else { return false }
        return ProjectTreeLoader.canonical(currentFolder)
            == ProjectTreeLoader.canonical(NotebookManager.shared.rootDirectory)
    }

    /// Live view of the project folder. One FSEvents subscription covers the
    /// whole tree, so the list keeps itself current without a poll.
    private var watcher: DirectoryWatcher?
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    /// Writes inside the project are announced with this notification so the
    /// editor can reload the open document the moment it changes, without the
    /// model needing a reference back into the view hierarchy. `object` is the
    /// batch of changed URLs.
    static let projectFilesDidChange = Notification.Name("TypstEdit.projectFilesDidChange")

    deinit {
        watcher?.stop()
        reloadTask?.cancel()
        indexTask?.cancel()
        indexRetryTask?.cancel()
    }

    // ADD THIS METHOD:
    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            AppDelegate.shared?.openDocuments(panel.urls)
        }
    }
    
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            // Projects live in the main window, wherever this was clicked.
            if let appDelegate = AppDelegate.shared {
                appDelegate.performInMainWindow(replacingDocument: true) {
                    NotificationCenter.default.post(name: .openProjectFolder, object: url)
                }
            } else {
                NotificationCenter.default.post(name: .openProjectFolder, object: url)
            }
        }
    }
    
    /// Reloads the tree now. The watcher keeps the list current on its own, so
    /// this is for the toolbar button and for explicit "something happened"
    /// notifications.
    ///
    /// Note what it deliberately does *not* do: it doesn't throw the list away
    /// and rebuild it. An unchanged scan leaves every row (and its selection
    /// and scroll position) untouched; a changed scan republishes the rows that
    /// actually changed.
    func loadFiles() {
        scheduleLoad(debounced: false)
        indexProjectIfNeeded(force: true)
    }

    /// Starts (or restarts) the live watch on `currentFolder` and re-reads the
    /// tree once, so anything that changed while the pane was hidden shows up.
    /// Safe to call repeatedly.
    func startWatching() {
        guard let folder = currentFolder, !isNotebookFolder else { return }
        let canonical = ProjectTreeLoader.canonical(folder)
        if let watcher, watcher.watchedRoot == canonical {
            scheduleLoad(debounced: false)
            return
        }
        restartWatching()
        scheduleLoad(debounced: false)
    }

    /// Stops the watcher — called when the Files panel goes away, so a hidden
    /// sidebar costs nothing at all.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
        reloadTask?.cancel()
        reloadTask = nil
    }

    /// The watcher is only started while the Projects list is on screen. Wire
    /// this from the view's lifecycle rather than from `currentFolder` alone:
    /// opening a project while the sidebar is hidden must not start watching.
    func setWatchActive(_ active: Bool) {
        guard watchEnabled != active else {
            if active, watcher == nil { restartWatching() }
            return
        }
        watchEnabled = active
        restartWatching()
    }

    private func restartWatching() {
        watcher?.stop()
        watcher = nil
        guard watchEnabled, !isNotebookFolder, let folder = currentFolder else { return }
        // The current folder may have been removed or unmounted while the
        // panel was hidden; FSEvents would fail silently then.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let observer = DirectoryWatcher(root: folder) { [weak self] changes in
            self?.handleFileSystemChanges(changes)
        }
        observer.start()
        watcher = observer
    }

    private func handleFileSystemChanges(_ changes: [DirectoryChange]) {
        guard let folder = currentFolder, !isNotebookFolder else { return }
        let root = ProjectTreeLoader.canonical(folder)

        var external: [URL] = []
        var needsScan = false
        var changedIndexableFile = false

        for change in changes {
            if ProjectTreeLoader.isIgnoredPath(change.url, inProject: folder) { continue }
            external.append(change.url)
            if RAGManager.isIndexableFile(change.url) { changedIndexableFile = true }

            if change.changesParentListing {
                // A row was created, removed or renamed: re-read the listing
                // of the folder holding it — but only if that folder is on
                // screen. A change inside a collapsed folder can't alter any
                // visible row, so it doesn't earn a scan.
                if isVisibleFolder(change.url.deletingLastPathComponent(), under: root) {
                    needsScan = true
                }
                // A folder that was renamed or removed also affects its own
                // listing (which may have followed it).
                if change.isDirectory && isVisibleFolder(change.url, under: root) {
                    needsScan = true
                }
            }
            // A folder reported as merely "modified" is deliberately ignored:
            // a folder's list of entries only changes through a create, remove
            // or rename, all of which arrive as their own flag above. FSEvents
            // also reports the parent folder whenever a file is *written* —
            // rescanning on that would re-read the project root on every
            // autosave for no visible change.
        }

        if !external.isEmpty {
            // Announced rather than stored as a callback: the editor listens,
            // so the model holds no reference into the view hierarchy.
            NotificationCenter.default.post(name: Self.projectFilesDidChange, object: external)
            if changedIndexableFile { indexProjectIfNeeded(force: false) }
        }
        if needsScan && watchEnabled { scheduleLoad(debounced: true) }
    }

    /// True when `url` is the project root or a folder the user has expanded —
    /// i.e. a folder whose listing contributes rows to the visible list.
    private func isVisibleFolder(_ url: URL, under root: URL) -> Bool {
        let canonical = ProjectTreeLoader.canonical(url)
        if canonical == root { return true }
        return expandedFolders.contains { ProjectTreeLoader.canonical($0) == canonical }
    }

    // MARK: - Reloading

    /// How long a burst of notifications is folded into one scan.
    private static let reloadDebounce: UInt64 = 250_000_000 // 0.25 s

    /// Runs a scan off the main actor, then publishes it if it still matters.
    /// The generation check drops a scan that finished after a newer one
    /// started, so a slow first pass can never overwrite fresher state.
    private func scheduleLoad(debounced: Bool) {
        guard let folder = currentFolder else { return }
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration

        reloadTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: Self.reloadDebounce)
            }
            // Read the expansion state *now*, not when the scan was queued: a
            // folder collapsed during the debounce window shouldn't be listed
            // at all, and one expanded during it should be.
            guard !Task.isCancelled, let self else { return }
            guard generation == self.reloadGeneration else { return }
            let expanded = ProjectTreeLoader.loadedDirectories(in: self.rootNodes,
                                                              expanded: self.expandedFolders)

            let tree = await Task.detached(priority: .userInitiated) {
                ProjectTreeLoader.buildTree(root: folder, reloading: expanded)
            }.value
            guard !Task.isCancelled else { return }
            guard generation == self.reloadGeneration else { return }
            guard self.currentFolder?.standardizedFileURL == folder.standardizedFileURL else { return }

            // A folder the user expanded while the detached scan was running
            // wasn't in the snapshot it reloaded, so its row would come back
            // holding the placeholder `[]`. Keep what the list already has.
            let merged = Self.keepingNewlyExpandedFolders(in: self.rootNodes,
                                                         mergedInto: tree,
                                                         scanned: expanded,
                                                         expanded: self.expandedFolders)
            self.publish(merged)
        }
    }

    /// Publishes a scan only when it differs from what's on screen.
    ///
    /// `FileNode` compares by URL, so the outline can diff rows by identity:
    /// an unchanged scan leaves the List completely alone (no flicker, no lost
    /// selection or scroll position) while a real change still rebuilds
    /// exactly the rows that moved.
    private func publish(_ tree: [FileNode]) {
        guard !tree.hasSameStructure(as: rootNodes) else { return }
        rootNodes = tree
        refreshGeneration += 1
    }

    /// Carries the contents of folders expanded after a scan started into that
    /// scan's result, so publishing it can't undo the user's expand.
    private static func keepingNewlyExpandedFolders(in current: [FileNode],
                                                   mergedInto scanned: [FileNode],
                                                   scanned scannedFolders: Set<URL>,
                                                   expanded: Set<URL>) -> [FileNode] {
        let canonicalExpanded = Set(expanded.map(ProjectTreeLoader.canonical))
        let missed = canonicalExpanded.subtracting(scannedFolders)
        guard !missed.isEmpty else { return scanned }
        return scanned.map { carry($0, from: current, missed: missed) }
    }

    private static func carry(_ node: FileNode, from current: [FileNode], missed: Set<URL>) -> FileNode {
        var updated = node
        if node.isDirectory, missed.contains(node.url), let existing = find(node.url, in: current) {
            updated.children = existing.children
            return updated
        }
        guard let children = node.children else { return updated }
        updated.children = children.map { carry($0, from: current, missed: missed) }
        return updated
    }

    private static func find(_ url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children, let hit = find(url, in: children) { return hit }
        }
        return nil
    }

    /// Called by `SidebarRow` when a folder is expanded.
    /// Lists the folder's one-level contents (always re-read, so a folder
    /// that was collapsed while files changed is fresh the moment it opens).
    func loadChildren(for node: FileNode) {
        guard node.isDirectory else { return }
        expandedFolders.insert(node.url)

        // Listing happens off the main actor: a folder with many entries
        // would otherwise stall the UI on the expand click.
        let url = node.url
        Task { [weak self] in
            let children = await Task.detached(priority: .userInitiated) {
                ProjectTreeLoader.loadDirectory(at: url)
            }.value
            guard let self else { return }
            guard self.currentFolder != nil, self.expandedFolders.contains(url) else { return }
            self.rootNodes = ProjectTreeLoader.replacingChildren(of: url, with: children, in: self.rootNodes)
        }
    }

    /// Called when a folder row is collapsed. Its contents stay cached (so the
    /// rows come back instantly) but stop being refreshed: nothing inside a
    /// collapsed subtree can be on screen.
    func noteCollapsed(_ node: FileNode) {
        expandedFolders.remove(node.url)
        let prefix = ProjectTreeLoader.canonical(node.url).path + "/"
        expandedFolders = expandedFolders.filter {
            !ProjectTreeLoader.canonical($0).path.hasPrefix(prefix)
        }
    }

    // MARK: - Semantic index

    /// The index lags the tree on purpose: re-embedding is by far the most
    /// expensive thing a file change can trigger, so watcher-driven updates
    /// wait for a quiet period (`minimumIndexInterval`) while an explicit
    /// refresh runs its own pass immediately. A change that arrives during a
    /// pass leaves `indexPending` set, so the work isn't lost.
    private static let minimumIndexInterval: TimeInterval = 15
    private var lastIndexRequest: Date = .distantPast
    private var indexTask: Task<Void, Never>?
    private var indexPending = false
    private var indexRetryTask: Task<Void, Never>?

    /// Whether this model should keep the project's semantic index up to date.
    /// Tests turn it off so they can exercise the tree without touching the
    /// embedding backend.
    var indexesProject = true

    private func indexProjectIfNeeded(force: Bool) {
        guard indexesProject else { return }
        guard let folder = currentFolder, !isNotebookFolder else { return }
        guard RAGManager.shouldUseRAG(for: folder) else { return }

        let elapsed = Date().timeIntervalSince(lastIndexRequest)
        guard force || elapsed >= Self.minimumIndexInterval else {
            // Too soon. Remember the change and come back once the throttle
            // expires — without a wake-up, a change made during the window
            // would sit unindexed until the next unrelated refresh.
            indexPending = true
            scheduleIndexRetry(after: Self.minimumIndexInterval - elapsed)
            return
        }
        guard indexTask == nil else {
            // A pass is already running and will pick this up when it ends.
            indexPending = true
            return
        }
        guard !RAGManager.shared.isIndexing else {
            // The manual "Update AI Index" button runs a pass outside this
            // model. Retry shortly instead of dropping the change.
            indexPending = true
            scheduleIndexRetry(after: Self.minimumIndexInterval)
            return
        }

        lastIndexRequest = Date()
        indexPending = false
        let project = folder
        indexTask = Task(priority: .background) { [weak self] in
            await RAGManager.shared.indexProject(at: project)
            guard let self, !Task.isCancelled else { return }
            self.indexTask = nil
            if self.indexPending { self.indexProjectIfNeeded(force: false) }
        }
    }

    private func scheduleIndexRetry(after delay: TimeInterval) {
        guard indexRetryTask == nil else { return }
        indexRetryTask = Task(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.indexRetryTask = nil
            if self.indexPending { self.indexProjectIfNeeded(force: false) }
        }
    }
    
    func createNewProject(template: ProjectTemplate) {
        let panel = NSSavePanel()
        panel.title = "Create New Project Folder"
        panel.nameFieldStringValue = "New Project"
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                let mainFile = url.appendingPathComponent("main.typ")
                let content = template.content
                try content.write(to: mainFile, atomically: true, encoding: .utf8)
                self.currentFolder = url
                self.isNewUnsavedFile = false
                loadFiles()
            } catch {
                print("Error creating project: \(error)")
            }
        }
    }
    
    func toggleExpansion(for node: FileNode) {
        if expandedFolders.contains(node.url) {
            expandedFolders.remove(node.url)
        } else {
            expandedFolders.insert(node.url)
        }
    }
    
    func createNewFile() {
        // Now "New File" starts as an unsaved buffer instead of immediate save
        self.isNewUnsavedFile = true
        // Only this model's window gets the new buffer.
        let target: Any? = documentController.map { ["target": $0] }
        NotificationCenter.default.post(name: .fileDidCreate, object: target)
    }
    
    func createProjectFile(extension fileExtension: String) -> URL? {
        guard let folder = currentFolder else { return nil }
        return createFile(in: folder, fileExtension: fileExtension)
    }

    /// Creates a uniquely-named file of `fileExtension` inside `folder`
    /// ("Untitled", "Untitled 2", …) and refreshes the tree.
    ///
    /// Used by the header "New File" menu (project root) and the folder
    /// context menu ("New File Here", any folder in the tree).
    /// `.note` files start with a heading, matching how notebook pages are
    /// created; every other kind starts empty.
    @discardableResult
    func createFile(in folder: URL, fileExtension: String) -> URL? {
        let baseName = "Untitled"
        var targetURL = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var counter = 1

        // Find a unique filename
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = folder.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }

        do {
            let initialContent = fileExtension.lowercased() == "note" ? "= Untitled\n\n" : ""
            try initialContent.write(to: targetURL, atomically: true, encoding: .utf8)
            loadFiles()
            return targetURL
        } catch {
            print("Error creating file: \(error)")
            return nil
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "typ")!, .pdf, .png, .jpeg]
        
        if panel.runModal() == .OK {
            guard let folder = currentFolder else { return }
            for url in panel.urls {
                let dest = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
            }
            loadFiles()
        }
    }
    
    func renameFile(url: URL) {
        // Renaming in macOS is often done via an alert or inline.
        // For simplicity, we'll use a NSSavePanel-like approach or just a simple input if we were in a custom view.
        // Let's use a simple prompt logic or post a notification for ContentView to handle it with an alert.
        NotificationCenter.default.post(name: .requestRename, object: url)
    }
    
    func performRename(from url: URL, to newName: String) {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            loadFiles()
            NotificationCenter.default.post(name: .fileDidRename, object: ["old": url, "new": newURL])
        } catch {
            print("Error renaming file: \(error)")
        }
    }
    
    func createBackup(to destination: URL) async -> Bool {
        guard let root = currentFolder else { return false }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // zip -r archive.zip .
        process.currentDirectoryURL = root
        process.arguments = ["-r", "-q", destination.path, "."]
        
        return await withCheckedContinuation { continuation in
            do {
                try process.run()
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus == 0)
                }
            } catch {
                print("Zip error: \(error)")
                continuation.resume(returning: false)
            }
        }
    }
    
    @discardableResult
    func deleteFile(url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            loadFiles()
            return true
        } catch {
            print("Error deleting file: \(error)")
            return false
        }
    }
}

extension Notification.Name {
    static let fileDidCreate = Notification.Name("fileDidCreate")
    static let requestRename = Notification.Name("requestRename")
    static let fileDidRename = Notification.Name("fileDidRename")
    static let refreshNotebooks = Notification.Name("refreshNotebooks")
}

struct SidebarView: View {
    @ObservedObject var model: FileSystemModel
    @Binding var selectedFile: URL?
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var compiler = TypstCompiler()
    @ObservedObject var editorController: EditorController
    /// Owned by ContentView so switching to AI Chat or Calculator keeps the
    /// repository state instead of scanning again when Files comes back.
    @ObservedObject var sourceControl: SourceControlManager
    @State private var sourceControlLoadingRoot: URL?
    @ObservedObject private var ragManager = RAGManager.shared
    @ObservedObject private var generalSettings = GeneralSettingsManager.shared

    @State private var sidebarMode: Int = 0 // 0: Projects, 1: Notebooks
    @State private var imageCleanupTarget: ImageCleanupTarget?

    private var visibility: SidebarVisibility {
        generalSettings.sidebarVisibility(chatEnabled: false)
    }

    private var browserTabs: [AccessibleTab<Int>] {
        let tabs = [
            AccessibleTab(0, title: "Projects", systemImage: "folder", selectedSystemImage: "folder.fill", color: .orange),
            AccessibleTab(1, title: "Notebooks", systemImage: "book.closed", selectedSystemImage: "book.closed.fill", color: .indigo),
        ]
        return tabs.filter { visibility.browserModes.contains($0.value) }
    }

    private var sourceControlRoot: URL? {
        guard visibility.showsSourceControl,
              let folder = model.currentFolder,
              ProjectTreeLoader.canonical(folder) != ProjectTreeLoader.canonical(NotebookManager.shared.rootDirectory)
        else { return nil }
        return folder
    }

    private func reconcileBrowserSelection() {
        if let mode = visibility.resolvedBrowserMode(sidebarMode), mode != sidebarMode {
            sidebarMode = mode
        }
    }

    /// True while the Projects file list is the thing actually on screen
    /// (not just the selected tab: the sidebar itself may be hidden). The
    /// Notebooks root is excluded — it's not a project tree.
    private var isProjectsBrowserVisible: Bool {
        guard let folder = model.currentFolder else { return false }
        return editorController.isSidebarVisible
            && visibility.resolvedPanel(editorController.sidebarContent) == .files
            && visibility.resolvedBrowserMode(sidebarMode) == 0
            && ProjectTreeLoader.canonical(folder) != ProjectTreeLoader.canonical(NotebookManager.shared.rootDirectory)
    }

    /// Starts or stops the live watch to match what is on screen.
    private func syncProjectWatch() {
        let visible = isProjectsBrowserVisible
        model.setWatchActive(visible)
        if visible {
            model.startWatching()
        } else {
            model.stopWatching()
        }
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            
            // Mode Selector — colour-coded tabs: orange for Projects,
            // indigo for Notebooks (matching the indigo book icon already
            // used throughout the notebook list below), with bold text and
            // a filled icon on the active tab so the state never relies on
            // colour alone.
            if !browserTabs.isEmpty {
                AccessibleTabStrip(tabs: browserTabs, selection: $sidebarMode)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
            
            if visibility.resolvedBrowserMode(sidebarMode) == 0 {
                // Header & File Tree
                VStack(alignment: .leading, spacing: 0) {
                    if let folderName = model.currentFolder?.lastPathComponent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            // Same squeeze rule as the "NOTEBOOKS" header:
                            // full name, then a shortened name, then nothing.
                            // Letting the row squeeze it produced a lone last
                            // letter ("s"), which reads as a glitch. The icon
                            // buttons keep their room throughout, and the
                            // full name stays available as a tooltip.
                            SidebarSectionTitle(
                                text: folderName.uppercased(),
                                fallbackText: shortFolderName(folderName)
                            )
                            .environmentObject(themeManager)
                            
                            Spacer()
                            
                            // 👉 Force Rebuild / Cancel Button
                            // 👉 Smart Resume / Cancel Button
                            Button(action: {
                                if ragManager.isIndexing {
                                    // Cancel if running
                                    ragManager.isIndexing = false 
                                    ragManager.indexStatus = "Cancelled."
                                } else if let folder = model.currentFolder {
                                    // 👉 changed to false so it resumes/updates!
                                    Task { await ragManager.indexProject(at: folder, forceReindex: false) }
                                }
                            }) {
                                Image(systemName: ragManager.isIndexing ? "xmark.circle.fill" : "cpu")
                                    .foregroundColor(ragManager.isIndexing ? .red : themeManager.textColor.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help(ragManager.isIndexing ? "Cancel Indexing" : "Update AI Index (Resume)")
                            // 👉 Add a right-click menu for a total wipe
                            .contextMenu {
                                Button("Force Rebuild Entire Index") {
                                    if !ragManager.isIndexing, let folder = model.currentFolder {
                                        Task { await ragManager.indexProject(at: folder, forceReindex: true) }
                                    }
                                }
                            }
                            
                            Button(action: { model.loadFiles() }) {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(themeManager.textColor.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Refresh Files (the list usually updates on its own)")
                            
                            Menu {
                                Button(action: {
                                    if let newFile = model.createProjectFile(extension: "typ") {
                                        selectedFile = newFile // Opens the file immediately
                                    }
                                }) {
                                    Label("New Typst File", systemImage: "doc.text")
                                }

                                Button(action: {
                                    if let newFile = model.createProjectFile(extension: "note") {
                                        selectedFile = newFile // Opens the file immediately
                                    }
                                }) {
                                    Label("New Note File", systemImage: "note.text")
                                }

                                Button(action: {
                                    if let newFile = model.createProjectFile(extension: "md") {
                                        selectedFile = newFile // Opens the file immediately
                                    }
                                }) {
                                    Label("New Markdown File", systemImage: "doc.text.fill") 
                                }

                                if generalSettings.showCalculator {
                                    Button(action: {
                                        if let newFile = model.createProjectFile(extension: "tcalc") {
                                            selectedFile = newFile // Opens in the Calculator panel
                                        }
                                    }) {
                                        Label("New Calculation", systemImage: "function")
                                    }
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .foregroundColor(themeManager.textColor.opacity(0.6))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize() // Prevents the menu button from stretching awkwardly
                            .help("New File")

                            Button(action: { model.openFolder() }) {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundColor(themeManager.textColor.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, ragManager.isIndexing ? 4 : 8)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if let window = NSApp.keyWindow {
                                window.zoom(nil)
                            }
                        }
                        .contextMenu {
                            Button("Cleanup Unused Images…") {
                                if let folder = model.currentFolder {
                                    imageCleanupTarget = ImageCleanupTarget(url: folder)
                                }
                            }
                        }
                        if ragManager.isIndexing {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ragManager.indexStatus)
                                    .font(.system(size: 10))
                                    .foregroundColor(themeManager.secondaryTextColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                ProgressView(value: ragManager.indexProgress)
                                    .progressViewStyle(.linear)
                                    .controlSize(.mini)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                        }
                    }
                }
                
                // Flat, pre-flattened rows: the list never recurses into the
                // tree, so a deep project can't trip SwiftUI's recursive row
                // diffing, and a reload only touches rows whose path changed.
                // `.id` is deliberately stable — the tree watcher keeps this
                // list current, so rebuilding it would throw away selection,
                // scroll position and any in-flight row animation.
                List(model.visibleRows) { row in
                    SidebarRow(node: row.node, depth: row.depth, isExpanded: row.isExpanded,
                               selectedFile: $selectedFile, editorController: editorController,
                               onCleanupFolder: { imageCleanupTarget = ImageCleanupTarget(url: $0) })
                        .environmentObject(model)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            selectedFile == row.node.url ? Color.accentColor.opacity(0.8) : Color.clear
                        )
                }
                // .plain rows hug their content (~22pt, VS Code-explorer
                // density); the .sidebar style forces tall ~40pt rows and
                // ignores defaultMinListRowHeight.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 22)

                if let root = sourceControlRoot {
                    Divider()
                    // `.id(root)` intentionally resets the commit message,
                    // dialogs, and collapse state when another project opens.
                    SourceControlSidebarView(
                        manager: sourceControl, editorController: editorController,
                        selectedFile: $selectedFile, projectRoot: root,
                        isLoading: sourceControlLoadingRoot == root
                            || sourceControl.projectRoot != root.standardizedFileURL,
                        availableHeight: geometry.size.height
                    )
                    .id(root)
                }
            } // Close VStack
            } else if visibility.resolvedBrowserMode(sidebarMode) == 1 {
                NotebookSidebarView(selectedFile: $selectedFile)
                    .environmentObject(themeManager)
            }
            
            if visibility.showsIssues {
                Divider()
                    .background(themeManager.secondaryTextColor.opacity(0.3))

                // Error Panel. When hidden, `compiler.errors` still updates,
                // so the panel shows current issues as soon as it returns.
                ErrorPanelView(compiler: compiler, editorController: editorController)
                    .environmentObject(themeManager)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.sidebarBackground.ignoresSafeArea())
        }
        .task(id: sourceControlRoot) {
            let root = sourceControlRoot
            sourceControlLoadingRoot = root
            await sourceControl.setProjectRoot(root)
            if sourceControlLoadingRoot == root { sourceControlLoadingRoot = nil }
        }
        // Live project view. The watcher runs only while the Projects list is
        // on screen: switching to Notebooks, hiding the sidebar or selecting
        // another panel turns it off, so an unviewed project costs nothing.
        .onAppear { syncProjectWatch() }
        .onDisappear {
            model.setWatchActive(false)
            model.stopWatching()
        }
        .onChange(of: isProjectsBrowserVisible) { _ in syncProjectWatch() }
        .onChange(of: model.refreshGeneration) { _ in
            guard sourceControlRoot != nil else { return }
            Task { await sourceControl.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard sourceControlRoot != nil else { return }
            Task { await sourceControl.refresh() }
        }
        .sheet(item: $imageCleanupTarget) { target in
            ImageCleanupView(root: target.url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .typstErrorsUpdated)) { notification in
            if let errors = notification.object as? [TypstError] {
                compiler.errors = errors
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshProjectSidebar)) { _ in
            model.loadFiles()
            NotebookManager.shared.loadNotebooks()
            if sourceControlRoot != nil {
                Task { await sourceControl.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshNotebooks)) { _ in
            NotebookManager.shared.loadNotebooks()
        }
        .onChange(of: visibility) { _ in reconcileBrowserSelection() }
        .onChange(of: sidebarMode) { newMode in
            reconcileBrowserSelection()
            if newMode == 1 {
                NotebookManager.shared.loadNotebooks()
            }
            // Coming back to Projects doesn't need a refresh: the watch is
            // restarted when the tab becomes visible and re-reads the tree.
        }
        .onChange(of: model.currentFolder) { newValue in
            if newValue == NotebookManager.shared.rootDirectory {
                sidebarMode = 1
                NotebookManager.shared.loadNotebooks()
            } else {
                sidebarMode = 0
            }
            reconcileBrowserSelection()
        }
        .onAppear {
            if model.currentFolder == NotebookManager.shared.rootDirectory {
                sidebarMode = 1
                NotebookManager.shared.loadNotebooks()
            }
            reconcileBrowserSelection()
        }
    }

    /// Head of a long folder name plus an ellipsis, used when the full name no
    /// longer fits next to the header buttons but a hint of it still does.
    private func shortFolderName(_ name: String) -> String {
        let limit = 12
        let upper = name.uppercased()
        guard upper.count > limit else { return upper }
        return String(upper.prefix(limit)) + "…"
    }
}

struct SidebarRow: View {
    let node: FileNode
    /// Nesting level in the project tree.
    var depth: Int = 0
    /// Whether this folder row is currently expanded.
    var isExpanded: Bool = false
    @Binding var selectedFile: URL?
    @ObservedObject var editorController: EditorController
    var onCleanupFolder: (URL) -> Void = { _ in }
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var fileSystemModel: FileSystemModel
    
    @State private var showDeleteAlert = false
    
    var isSelected: Bool {
        selectedFile == node.url
    }

    private var disclosureWidth: CGFloat { 14 }

    var body: some View {
        HStack(spacing: 4) {
            // Indentation replaces List's built-in outline nesting: the list
            // renders a flat array of rows, so depth is drawn explicitly.
            Color.clear.frame(width: CGFloat(depth) * 12, height: 1)

            // A fixed disclosure column for every row keeps file and folder
            // icons aligned with each other at the same depth.
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(themeManager.textColor.opacity(0.55))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: disclosureWidth)
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: disclosureWidth, height: 1)
            }

            Image(systemName: iconName(for: node))
                .foregroundColor(iconColor(for: node))
                .font(.system(size: 12))

            Text("\(explorerAbbreviatedName(node.name, pathExtension: node.url.pathExtension))\(isSelected && editorController.hasUnsavedChanges ? "*" : "")")
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : themeManager.textColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .help(node.name)
        .padding(.vertical, 2)
        .contentShape(Rectangle()) // Make full row clickable
        .onTapGesture {
            if node.isDirectory {
                toggleExpansion()
            } else {
                selectedFile = node.url
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
            }

            Button("Open in External Program") {
                NSWorkspace.shared.open(node.url)
            }

            if node.isDirectory {
                Divider()

                // Create documents directly inside this folder, the same way
                // the header "+" menu does for the project root.
                Menu {
                    Button("Typst File (.typ)") {
                        createFileHere("typ")
                    }
                    Button("Note (.note)") {
                        createFileHere("note")
                    }
                    Button("Markdown File (.md)") {
                        createFileHere("md")
                    }
                } label: {
                    Label("New File Here", systemImage: "square.and.pencil")
                }

                Button("Cleanup Unused Images…") {
                    onCleanupFolder(node.url)
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                showDeleteAlert = true
            }
        }
        .alert("Delete \(node.name)?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                // The user chose to delete the open file (or its folder):
                // its unsaved edits go with it, without a save prompt that
                // would only write the deleted file back.
                guard fileSystemModel.deleteFile(url: node.url) else { return }
                AppDelegate.shared?.discardEdits(forDeletedItemAt: node.url)
                // If the deleted file was selected, clear the selection
                if let selected = selectedFile,
                   selected == node.url || selected.path.hasPrefix(node.url.path + "/") {
                    selectedFile = nil
                }
            }
        } message: {
            Text("This item will be moved to the Trash. This action cannot be undone.")
        }
    }
    
    /// Creates a new file inside this folder and opens it immediately.
    private func createFileHere(_ fileExtension: String) {
        if let url = fileSystemModel.createFile(in: node.url, fileExtension: fileExtension) {
            selectedFile = url
        }
    }

    /// Expands or collapses this folder. Expanding loads its contents on
    /// demand; collapsing just hides the rows (their contents stay cached).
    private func toggleExpansion() {
        guard node.isDirectory else { return }
        if isExpanded {
            fileSystemModel.noteCollapsed(node)
        } else {
            fileSystemModel.loadChildren(for: node)
        }
    }

    func iconName(for node: FileNode) -> String {
        if node.isDirectory {
            return "folder.fill"
        }
        if node.name.hasSuffix(".typ") {
            return "doc.text.fill"
        }
        // `.note` = Markdown-with-Typst note; same icon as notebook pages.
        if node.name.hasSuffix(".note") {
            return "note.text"
        }
        if node.name.hasSuffix(".pdf") {
            return "doc.text" // PDF icon? 
        }
        return "doc"
    }
    
    func iconColor(for node: FileNode) -> Color {
        if node.isDirectory {
            return .blue
        }
        if node.name.hasSuffix(".typ") {
            return .orange
        }
        // Indigo matches the notebook styling used for notes elsewhere.
        if node.name.hasSuffix(".note") {
            return .indigo
        }
        return themeManager.textColor // Match text color for better visibility in light mode
    }
}
