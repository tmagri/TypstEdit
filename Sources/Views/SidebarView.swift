import SwiftUI
import UniformTypeIdentifiers

struct FileNode: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
}

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
    @Published var currentFolder: URL?
    @Published var expandedFolders: Set<URL> = []
    @Published var isNewUnsavedFile: Bool = false
    /// Bumped whenever a reload observes an actual change in the tree. The
    /// file List uses it as its identity so SwiftUI rebuilds rows outright.
    /// Without it, `List(_:children:)` sometimes diffs the new data to "no
    /// visual change" and keeps stale rows — the glitch where a refresh only
    /// took effect after switching to Notebooks and back (which recreated the
    /// List, and is exactly what this rebuild mimics).
    @Published var refreshGeneration: Int = 0
    /// The editor of the window this model belongs to.
    weak var documentController: EditorController?
    
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
    
    /// The toolbar Refresh button: rescans and always rebuilds the List, even
    /// when the scan comes back identical — an identical result can't be
    /// trusted to undo a List that's already showing stale rows, which is
    /// exactly the glitch this is meant to recover from.
    func forceRefresh() {
        refreshGeneration += 1
        loadFiles()
    }

    func loadFiles() {
        guard let folder = currentFolder else { return }
        let fresh = refreshedTree(at: folder)

        // Only touch state when the tree really changed: no flicker on
        // no-op refreshes, and a guaranteed rebuild when files appeared,
        // disappeared, or moved.
        if fresh != rootNodes {
            self.rootNodes = fresh
            refreshGeneration += 1
        }

        Task(priority: .background) {
            print("[DEBUG] Triggering RAG Indexer for folder: \(folder.lastPathComponent)")
            await RAGManager.shared.indexProject(at: folder)
        }
    }

    /// Loads the top level of `folder` and re-fills every folder the user
    /// already expanded, so nested changes show up in the same pass instead
    /// of lingering stale until the user collapses and re-expands.
    ///
    /// URLs are processed shallowest-first: a subfolder only becomes visible
    /// in the tree after its parent has been refilled, so parents must be
    /// handled before their children.
    private func refreshedTree(at folder: URL) -> [FileNode] {
        var tree = loadDirectory(at: folder)
        let expanded = expandedFolders.sorted {
            $0.pathComponents.count < $1.pathComponents.count
        }
        for url in expanded {
            guard findNode(with: url, in: tree) != nil else { continue }
            let children = loadDirectory(at: url)
            tree = tree.map { updateChildren(in: $0, target: url, children: children) }
        }
        return tree
    }

    /// Depth-first search for the node with `url` in the (lazily loaded) tree.
    private func findNode(with url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children, let hit = findNode(with: url, in: children) {
                return hit
            }
        }
        return nil
    }
    
    // Auto-generated directories that shouldn't clutter the project sidebar.
    private static let hiddenFolders: Set<String> = ["backups", "temp", "vectorcaches"]

    /// Loads **one level** of a directory. Subdirectories are given an empty
    /// `children` array (so SwiftUI renders the disclosure chevron) but their
    /// contents are NOT loaded yet — they are fetched lazily via
    /// `loadChildren(for:)` when the user first expands the row.
    ///
    /// This breaks the deep recursion that caused the
    /// `OutlineListCoordinator.recursivelyDiffRows` crash (RECURSION LEVEL 11).
    private func loadDirectory(at url: URL) -> [FileNode] {
        var nodes: [FileNode] = []
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            let sortedContents = contents.sorted { lhs, rhs in
                let lhsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rhsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if lhsDir != rhsDir { return lhsDir } // Directories first
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }

            for file in sortedContents {
                let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir && Self.hiddenFolders.contains(file.lastPathComponent) { continue }

                // Directories start with an empty (not nil) children array so
                // SwiftUI shows the disclosure triangle, but the contents are
                // loaded on demand — never recursively here.
                let children: [FileNode]? = isDir ? [] : nil

                nodes.append(FileNode(url: file, name: file.lastPathComponent, isDirectory: isDir, children: children))
            }
        } catch {
            print("Error listing directory: \(error)")
        }
        return nodes
    }

    /// Called by `SidebarRow` the first time a folder is expanded.
    /// Replaces the placeholder `[]` with the actual one-level contents.
    func loadChildren(for node: FileNode) {
        guard node.isDirectory else { return }
        let children = loadDirectory(at: node.url)
        // Walk the tree and replace the matching node in-place.
        rootNodes = rootNodes.map { updateChildren(in: $0, target: node.url, children: children) }
    }

    private func updateChildren(in node: FileNode, target: URL, children: [FileNode]) -> FileNode {
        if node.url == target {
            var updated = node
            updated.children = children
            return updated
        }
        guard let existing = node.children else { return node }
        var updated = node
        updated.children = existing.map { updateChildren(in: $0, target: target, children: children) }
        return updated
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
              model.currentFolder != NotebookManager.shared.rootDirectory else { return nil }
        return model.currentFolder
    }

    private func reconcileBrowserSelection() {
        if let mode = visibility.resolvedBrowserMode(sidebarMode), mode != sidebarMode {
            sidebarMode = mode
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
                            
                            Button(action: { model.forceRefresh() }) {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(themeManager.textColor.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Refresh Files")
                            
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
                
                // 👉 RESTORED: The actual file list!
                List(model.rootNodes, children: \.children) { node in
                    SidebarRow(node: node, selectedFile: $selectedFile, editorController: editorController,
                               onCleanupFolder: { imageCleanupTarget = ImageCleanupTarget(url: $0) })
                        .environmentObject(model)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            selectedFile == node.url ? Color.accentColor.opacity(0.8) : Color.clear
                        )
                }
                // .plain rows hug their content (~22pt, VS Code-explorer
                // density); the .sidebar style forces tall ~40pt rows and
                // ignores defaultMinListRowHeight.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 22)
                // Rebuilding the List on generation changes is the reliable
                // fix for the stale-refresh glitch; identity-diffing alone
                // can leave old rows on screen (see FileSystemModel).
                .id(model.refreshGeneration)

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
            } else {
                // Coming back from Notebooks used to be the only way to fix
                // a stale file list — keep that recovery, but make it
                // explicit: switch rebuilds the List through forceRefresh.
                model.forceRefresh()
            }
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
    @Binding var selectedFile: URL?
    @ObservedObject var editorController: EditorController
    var onCleanupFolder: (URL) -> Void = { _ in }
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var fileSystemModel: FileSystemModel
    
    @State private var showDeleteAlert = false
    
    var isSelected: Bool {
        selectedFile == node.url
    }

    var body: some View {
        HStack(spacing: 4) {
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
        .onAppear {
            // Lazily load this directory's children the first time the row
            // becomes visible (i.e. after the user expands the disclosure
            // chevron). The model only stores a placeholder [] at load time;
            // this call replaces it with the real one-level contents.
            if node.isDirectory {
                fileSystemModel.loadChildren(for: node)
            }
        }
        .onTapGesture {
            if !node.isDirectory {
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
