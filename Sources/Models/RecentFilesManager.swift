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
    
    func add(url: URL) {
        // Remove if exists
        recentFiles.removeAll { $0.url == url }
        
        // Add to top
        let newFile = RecentFile(url: url, lastModified: Date())
        recentFiles.insert(newFile, at: 0)
        
        // Keep max 10
        if recentFiles.count > 10 {
            recentFiles = Array(recentFiles.prefix(10))
        }
        
        saveRecents()
    }
    
    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentFiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    private func loadRecents() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) {
            recentFiles = decoded
        }
    }
}
