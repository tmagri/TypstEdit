import Foundation

@MainActor
class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()
    @Published var recentFiles: [RecentFile] = []
    
    private let key = "recentFiles"
    
    struct RecentFile: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        let url: URL
        let lastModified: Date
        /// Whether this was opened as a project (folder in sidebar) vs standalone single file.
        var isProject: Bool
        
        var name: String {
            url.lastPathComponent
        }
        
        var path: String {
            url.path
        }
    }
    
    init() {
        loadRecents()
    }
    
    func add(url: URL, isProject: Bool) {
        // Remove existing entry for this URL (regardless of previous mode)
        recentFiles.removeAll { $0.url == url }
        
        // Add to top with current mode
        let newFile = RecentFile(url: url, lastModified: Date(), isProject: isProject)
        recentFiles.insert(newFile, at: 0)
        
        // Keep max 10
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
        if let data = UserDefaults.standard.data(forKey: key) {
            // Try to decode with the new schema (isProject field)
            if let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) {
                recentFiles = decoded
                validateRecentFiles()
                return
            }
            // Migration: old entries didn't have isProject — default to true (project mode was the only mode)
            struct LegacyRecentFile: Codable {
                var id: UUID = UUID()
                let url: URL
                let lastModified: Date
            }
            if let legacy = try? JSONDecoder().decode([LegacyRecentFile].self, from: data) {
                recentFiles = legacy.map { RecentFile(id: $0.id, url: $0.url, lastModified: $0.lastModified, isProject: true) }
                saveRecents()
                validateRecentFiles()
            }
        }
    }
}
