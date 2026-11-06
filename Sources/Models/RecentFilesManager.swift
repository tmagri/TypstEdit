import Foundation

@MainActor
class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()
    @Published var recentFiles: [RecentFile] = []
    
    private let key = "recentFiles"
    
    struct RecentFile: Codable, Identifiable, Equatable {
        /// How the file was opened last time. This is what makes reopening
        /// faithful: a project file must come back in its project (no new
        /// project rooted at whatever subfolder holds the file), a notebook
        /// page must come back in the Notes window, and a lone file must come
        /// back without a project — and therefore without an index,
        /// `vectorcaches/` or project chat/MCP state.
        enum Kind: String, Codable {
            /// Opened inside a project window (a folder in the sidebar).
            case project
            /// Opened on its own, with no project.
            case standalone
            /// A page opened from the Notes window.
            case notebook
        }

        var id: UUID = UUID()
        let url: URL
        let lastModified: Date
        /// The project folder that was open when this file was last used.
        /// Only set for `.project` entries, so the real project root survives
        /// even when the file sits in a subfolder of it.
        var projectRoot: URL?
        var kind: Kind
        
        private enum CodingKeys: String, CodingKey {
            case id, url, lastModified, projectRoot, kind
            /// Only written/read for compatibility with older builds, which
            /// stored a single Bool instead of `kind` + `projectRoot`.
            case isProject
        }
        
        init(
            id: UUID = UUID(),
            url: URL,
            lastModified: Date,
            projectRoot: URL? = nil,
            kind: Kind
        ) {
            self.id = id
            self.url = url
            self.lastModified = lastModified
            self.projectRoot = projectRoot
            self.kind = kind
        }
        
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            url = try values.decode(URL.self, forKey: .url)
            lastModified = try values.decode(Date.self, forKey: .lastModified)
            if let kind = try values.decodeIfPresent(Kind.self, forKey: .kind) {
                self.kind = kind
                projectRoot = try values.decodeIfPresent(URL.self, forKey: .projectRoot)
            } else {
                // Older builds stored only `isProject`; the oldest stored
                // nothing and every entry was a project entry. Neither knows
                // the project root, so `openTarget` falls back to the file's
                // folder for them.
                let wasProject = try values.decodeIfPresent(Bool.self, forKey: .isProject) ?? true
                kind = wasProject ? .project : .standalone
                projectRoot = nil
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(url, forKey: .url)
            try values.encode(lastModified, forKey: .lastModified)
            try values.encode(kind, forKey: .kind)
            try values.encodeIfPresent(projectRoot, forKey: .projectRoot)
            // Keep the old key accurate too, so going back to an older build
            // still reads this list instead of dropping it.
            try values.encode(kind == .project, forKey: .isProject)
        }
        
        var name: String {
            url.lastPathComponent
        }
        
        var path: String {
            url.path
        }
        
        /// True when the file was last opened inside a project window.
        var isProject: Bool { kind == .project }
        
        /// True for a project folder opened with no file in it (for example
        /// a notebook opened with "Open as Project"). `url` is the folder.
        var isFolder: Bool {
            kind == .project && projectRoot.map { ProjectWindowRouter.isSameFolder($0, url) } ?? false
        }
        
        /// Short word for the badge in the welcome screen and Open Recent.
        var kindLabel: String {
            switch kind {
            case .project: return "Project"
            case .standalone: return "File"
            case .notebook: return "Note"
            }
        }
        
        /// SF Symbol for this entry in the welcome screen and Open Recent.
        var iconName: String {
            if isFolder { return "folder.fill" }
            switch kind {
            case .project: return "folder"
            case .notebook: return "book.closed"
            case .standalone: return "doc.text"
            }
        }
        
        /// Where reopening this entry has to go.
        enum OpenTarget: Equatable {
            /// Open this folder as the project, showing `file` when given.
            case project(root: URL, file: URL?)
            /// Show this page in the Notes window.
            case notebook(URL)
            /// Load this file alone, with no project.
            case standalone(URL)
            /// A project folder entry whose folder no longer exists.
            case missing
        }
        
        /// The destination for this entry. `fileExists` is injectable so the
        /// decision can be tested without touching the file system.
        func openTarget(
            notebooksRoot: URL,
            fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        ) -> OpenTarget {
            switch kind {
            case .notebook:
                // A note that moved out of the notebooks folder can no longer
                // be shown there; open it on its own instead.
                guard ProjectWindowRouter.contains(notebooksRoot, url) else {
                    return .standalone(url)
                }
                return .notebook(url)
            case .project:
                if isFolder, let root = projectRoot {
                    return fileExists(root) ? .project(root: root, file: nil) : .missing
                }
                // Older builds stored no root, and recorded pages shown in the
                // Notes window as "project" entries. Keep sending those to
                // Notes. A stored root inside the Notes folder is a notebook
                // that was opened as a project (e.g. under Git): it stays one.
                if projectRoot == nil, ProjectWindowRouter.contains(notebooksRoot, url) {
                    return .notebook(url)
                }
                // A stored root is authoritative. Entries from older builds
                // only knew the file's folder, which is the project root for
                // files at the top of a project.
                let root = projectRoot ?? url.deletingLastPathComponent()
                guard fileExists(root), ProjectWindowRouter.contains(root, url) else {
                    // The project folder is gone, or the file was moved out of
                    // it: do not attach the file to some other project. A lone
                    // file needs no project index or `vectorcaches/`.
                    return .standalone(url)
                }
                return .project(root: root, file: url)
            case .standalone:
                return .standalone(url)
            }
        }
    }
    
    init() {
        loadRecents()
    }
    
    /// Records `url` as the most recent file, together with the mode it was
    /// opened in. Pass the real project folder (not merely the file's parent)
    /// and set `inNotebook` when the Notes window was showing it.
    ///
    /// A Project entry is never downgraded: when the file is later used from
    /// the Notes window or on its own, the entry keeps its project (and only
    /// moves to the top), so Open Recent still brings the project back. A
    /// different project replaces it. If the project folder is gone by the
    /// time it is reopened, `openTarget` falls back to a standalone open.
    func add(url: URL, projectRoot: URL? = nil, inNotebook: Bool = false) {
        var projectRoot = projectRoot
        var inNotebook = inNotebook
        if projectRoot == nil || inNotebook,
           let existing = recentFiles.first(where: { $0.url == url }),
           existing.kind == .project, !existing.isFolder,
           let existingRoot = existing.projectRoot,
           ProjectWindowRouter.contains(existingRoot, url) {
            projectRoot = existingRoot
            inNotebook = false
        }
        // Remove existing entry for this URL (regardless of previous mode)
        recentFiles.removeAll { $0.url == url }
        // A file entry reopens its project, so the project's folder-only
        // entry is no longer needed.
        if let projectRoot, !inNotebook {
            recentFiles.removeAll { $0.isFolder && ProjectWindowRouter.isSameFolder($0.url, projectRoot) }
        }
        
        // Add to top with current mode
        let kind: RecentFile.Kind
        if inNotebook {
            kind = .notebook
        } else if projectRoot != nil {
            kind = .project
        } else {
            kind = .standalone
        }
        let newFile = RecentFile(
            url: url,
            lastModified: Date(),
            projectRoot: kind == .project ? projectRoot : nil,
            kind: kind
        )
        recentFiles.insert(newFile, at: 0)
        
        // Keep max 10
        if recentFiles.count > 10 {
            recentFiles = Array(recentFiles.prefix(10))
        }
        
        saveRecents()
    }
    
    /// Records a project folder that was opened with no file in it, so it
    /// can be reopened as a project from Open Recent. When a file of the
    /// project is opened later, `add` replaces this entry with the file's.
    func addProjectFolder(_ root: URL) {
        recentFiles.removeAll { $0.isFolder && ProjectWindowRouter.isSameFolder($0.url, root) }
        recentFiles.insert(
            RecentFile(url: root, lastModified: Date(), projectRoot: root, kind: .project),
            at: 0
        )
        if recentFiles.count > 10 {
            recentFiles = Array(recentFiles.prefix(10))
        }
        saveRecents()
    }
    
    func remove(url: URL) {
        recentFiles.removeAll { $0.url == url }
        saveRecents()
    }
    
    func clearAll() {
        recentFiles = []
        saveRecents()
    }
    
    func validateRecentFiles() {
        let fileManager = FileManager.default
        let existingFiles = recentFiles.filter { file in
            fileManager.fileExists(atPath: file.url.path)
        }
        
        if existingFiles.count != recentFiles.count {
            recentFiles = existingFiles
            saveRecents()
        }
    }
    
    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentFiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        // `RecentFile.init(from:)` understands the current schema and both
        // older ones (`isProject` Bool, and no mode at all).
        guard let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        recentFiles = decoded
        validateRecentFiles()
    }
}
